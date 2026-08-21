# Runbook: Ship the firewall's logs to Loki

**Target:** `morpheus` (pfSense) → Alloy on `prometheus`
**Time:** ten minutes, plus a careful first restart of Alloy
**You will need:** the pfSense web UI and a shell on the monitoring host

Every VLAN in this lab terminates on `morpheus`, which makes it the only device
that sees inter-VLAN and egress traffic for the whole house. It is also a
FreeBSD appliance that cannot run Alloy. So the log store held `auth.log` from
two Linux hosts and nothing at all from the firewall — eight LogQL security
rules watching the quietest surface in the estate.

This connects them.

---

## 1. Deploy the receiver first

The listener has to exist before pfSense starts sending, or the first packets
are silently dropped.

> [!CAUTION]
> `config.alloy` is the single agent config used on **every** monitored host. A
> syntax or schema error takes down all log collection, not just the new
> listener. CI runs `alloy fmt --test`, which parses the file but does **not**
> validate component arguments. Bring Alloy up on its own and read its logs
> before assuming this worked.

The two commands run from **different directories**. `make render` needs the
repository root, where the only Makefile lives; `docker compose` needs
`stacks/observability`, where `compose.yaml` lives. Running either from the
other's directory fails — `docker compose` with
`no configuration file provided: not found`.

```bash
cd ~/HomeLab
make render                        # Makefile is at the repo root

cd stacks/observability            # compose.yaml is here
docker compose up -d alloy
docker compose logs --tail=50 alloy
```

What you want to see: no `Error` lines, and the component registering. What
tells you it failed: Alloy exiting immediately, or complaining about an unknown
argument in `loki.source.syslog`.

Confirm the port is actually listening on the management address:

```bash
docker compose ps alloy          # expect 0.0.0.0:1514->1514/udp
ss -ulnp | grep 1514
```

---

## 2. Point pfSense at it

**Status → System Logs → Settings**, then:

| Field | Value |
| --- | --- |
| Enable Remote Logging | ✔ |
| Remote log servers | `10.0.99.20:1514` |
| Remote Syslog Contents | **Firewall Events** |

Leave the other content classes off to begin with. Firewall events alone are
the reason for doing this; DHCP, DNS resolver and the rest can be added once
the volume is understood — this is a 30-day retention Loki on a 2012 MacBook,
and turning everything on at once is how you find out what its ingest ceiling
is the hard way.

No firewall rule is needed. `morpheus` already has an interface on VLAN 99
(`10.0.99.1`) and `prometheus` is on the same segment.

---

## 3. Verify

From the monitoring host — within a minute:

```bash
# Is anything arriving at all, and is it labelled with the SENDER's hostname?
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={host="morpheus"}' | jq -r '.data.result[].stream' | head

# Are filterlog lines being parsed into labels?
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={app="filterlog"} | line_format "{{.action}} {{.direction}} {{.interface}}"' \
  | jq -r '.data.result[].values[][1]' | head
```

You should see `host="morpheus"`, and `action` as `pass`/`block`.

> [!NOTE]
> If logs arrive but are labelled `host="prometheus"`, the network syslog stream
> is being written through the wrong client. `loki.write.grafana_loki` stamps
> `host = constants.hostname` on everything it sends, which is right for logs
> this machine produces and wrong for logs it relays. That is the entire reason
> `loki.write.network_syslog` exists as a separate component with no
> `external_labels`.

Then confirm the rules loaded:

```bash
curl -s http://localhost:3100/loki/api/v1/rules | grep -o 'name: firewall' || echo "firewall group not loaded"
```

---

## 4. Prove the segmentation rules mean something

`TerminalSegmentReachedInternalNetwork` fires on a PASS from VLAN 10, 20 or 40
toward 30, 50 or 99. It should never fire. Confirm the *inverse* is being
logged — that blocks from those segments are visible:

```bash
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum(count_over_time({app="filterlog",action="block"}[1h]))' \
  | jq '.data.result'
```

A non-zero count means the pipeline carries the evidence those rules depend on.
**A zero count means the alerts cannot fire** — and an alert that cannot fire
looks exactly like an alert that has nothing to report. This lab has been caught
by that distinction before; see the header of
[`ups.rules.yaml`](../../stacks/observability/prometheus/rules/ups.rules.yaml).

---

## 5. Watch the volume for a day

```bash
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum(count_over_time({app="filterlog"}[24h]))' | jq '.data.result'
df -h /
```

A busy home firewall logging blocks can produce hundreds of thousands of lines
a day. If retention starts biting, narrow what pfSense logs rather than what
Loki keeps — dropping the default-deny log on the guest VLAN removes most of the
volume and little of the signal.

---

## Rollback

Untick **Enable Remote Logging** on pfSense. That stops the source instantly and
needs no change on the monitoring host.

`FirewallLogsStopped` will fire 30 minutes later, which is correct — it exists
precisely so that a silent pipeline is distinguishable from a quiet network.
Silence it if the stop was deliberate.
