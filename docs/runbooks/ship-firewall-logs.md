# Runbook: Ship the firewall's logs to Loki

**Target:** `morpheus` (pfSense) → Alloy on `prometheus`
**Time:** ten minutes, plus a careful first restart of Alloy
**You will need:** the pfSense web UI, and a shell on the monitoring host with
`sudo` for tcpdump

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

> [!IMPORTANT]
> **Saving this page does not reliably restart `syslogd`.** Observed here: the
> settings saved, the page redisplayed with every field correct, and pfSense sent
> **nothing at all** — no packets on any port, for as long as anyone cared to
> watch. Editing the server list a second time and saving again forced the
> reload, and traffic started in the same second.
>
> So make a second, deliberate save before concluding anything is broken. If you
> would rather be certain than superstitious, **Diagnostics → Command Prompt** →
> `/etc/rc.restart_webgui` is heavy-handed but reloads the logging daemon along
> with everything else.
>
> The consequence for debugging is the reason §3 exists: a correct-looking
> settings page is not evidence that the daemon is sending, and an empty Loki
> query cannot tell you which of the two it is.

Use the **full `host:port`** form. A bare `10.0.99.20` sends to syslog's default
port 514, where nothing is listening — the packets are simply discarded and the
symptom is identical to not sending at all.

---

## 3. Confirm it is actually sending

Do this **before** querying Loki. It reads the wire rather than a UI, and it is
the only step that separates *pfSense is not sending* from *the packets arrive
and something downstream drops them*. Those two faults look the same from
Loki and have completely different fixes.

```bash
sudo tcpdump -ni any 'udp port 1514 or udp port 514' -c 10
```

Generate something the firewall will log while this runs — browsing from a phone
on the IoT VLAN is enough.

| What you see | What it means |
| --- | --- |
| Nothing on either port | pfSense is not sending. Go back to §2 and save a second time. |
| Traffic to port **514** | A bare IP was entered in the server list. Nothing listens there. Fix it to `10.0.99.20:1514`. |
| Traffic to **1514** on the physical NIC only | It is arriving but not reaching the container. Recheck the port publish in §1. |
| Traffic to **1514** on both the NIC and a `br-`/`veth` interface | Correct. Docker is forwarding it to Alloy. Continue to §4. |

That last case looks like this — the same packet twice, once inbound on the NIC
and once outbound to the container's address on the bridge:

```text
enx0005…    In  IP 10.0.99.1.514 > 10.0.99.20.1514: SYSLOG local0.info, length: 166
br-faa4ed…  Out IP 10.0.99.1.514 > 172.18.0.7.1514: SYSLOG local0.info, length: 166
```

Source port 514 is normal and not a misconfiguration — that is syslogd's
outbound port. Only the **destination** port matters.

Then read the payload, not just the headers. `-A` prints it as ASCII:

```bash
sudo tcpdump -ni any -A -c 3 'udp port 1514'
```

```text
<134>Aug 20 20:25:28 filterlog[97178]: 4,,,1000000103,em0,match,block,in,4,...
```

Two things in that line cost an evening, and both are invisible from Loki:

**There is no hostname.** RFC 3164 is `<PRI>TIMESTAMP HOSTNAME TAG:` — pfSense
goes straight from timestamp to tag. `__syslog_message_hostname` is therefore
empty, Loki drops empty labels, and the streams carry no `host` at all. This is
why `config.alloy` derives `host` from the connection address instead.

**The timestamp is local, and says so nowhere.** Compare it against the capture
time in the left column. Above, `20:25:28` was captured at `03:25:28` UTC —
morpheus runs seven hours behind and RFC 3164 has no timezone field. This is why
`use_incoming_timestamp` is `false`; see the comment in `config.alloy` for what
happens when it is not.

If packets are arriving but nothing lands in Loki, Alloy's own counters settle it
in one command:

```bash
curl -s localhost:12345/metrics | grep -E \
  'loki_source_syslog_(entries|parsing_errors|empty_messages)_total|loki_write_(sent|dropped)_entries_total'
```

| Reading | Fault |
| --- | --- |
| `entries_total` 0 | Nothing reached the listener. Not an Alloy problem — go back to tcpdump. |
| `entries_total` climbing, `parsing_errors_total` climbing | Received but unparseable. The sender is not emitting RFC 3164. |
| `entries_total` climbing, `write_sent_entries_total` flat | Parsed but not shipped. Check `loki_write_dropped_entries_total` for the reason label, and that Loki is up. |
| Both climbing together | Working. The problem is your query, not the pipeline. |

> [!NOTE]
> `loki_relabel_entries_processed{component_id="loki.relabel.network_syslog"}`
> reads **0 forever, and that is correct.** That component exists only to hand
> its `.rules` to `loki.source.syslog`; the relabelling happens inside the
> listener, so the component itself never sees an entry. It looks like a dead
> component and is not one.

---

## 4. Verify

From the monitoring host, a minute or so after the reload — not instantly:

> [!NOTE]
> `/loki/api/v1/query` is the **instant** endpoint and accepts metric queries
> only. A bare log selector like `{host="morpheus"}` returns *"log queries are
> not supported as an instant query type"*. Either wrap it in
> `count_over_time(...)` as below, or use `/loki/api/v1/query_range` with
> `start` and `end`. The checks here use the metric form because it answers the
> question more directly anyway.

```bash
# Which hosts is Loki seeing at all? morpheus should appear once logs arrive.
curl -s 'http://localhost:3100/loki/api/v1/label/host/values' | jq -r '.data[]'

# Is it labelled with the SENDER's hostname, and which apps are arriving?
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (host,app) (count_over_time({host="morpheus"}[10m]))' \
  | jq -r '.data.result[] | "\(.metric.host)\t\(.metric.app)\t\(.value[1])"'

# Are filterlog lines being parsed into labels? Empty action/interface here
# means the regex did not match your log format.
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (action,direction,interface) (count_over_time({app="filterlog"}[10m]))' \
  | jq -r '.data.result[] | "\(.metric.action)\t\(.metric.direction)\t\(.metric.interface)\t\(.value[1])"'
```

You should see `host="morpheus"`, and `action` as `pass`/`block`.

That name does not come from the log line. pfSense sends no hostname (§3), so
`config.alloy` maps it from the connection address `10.0.99.1`. A second syslog
sender needs its own rule, or it arrives with no `host` label at all — and a
stream with no `host` is invisible to every `{host="..."}` query, which reads
exactly like nothing being sent.

> [!CAUTION]
> **An empty result is not evidence of absence.** Check
> `loki_source_syslog_entries_total` from §3 before believing one. Alloy
> receiving and Loki storing are not the same thing as a query matching: entries
> written with a bad timestamp are accepted with a `204`, are never counted in
> `loki_discarded_samples_total`, and cannot be reached by any range you would
> think to try. That combination — every counter green, every query empty — is
> what the `use_incoming_timestamp` comment in `config.alloy` exists to prevent
> recurring.

One more label trap, on the other path:

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

## 5. Prove the segmentation rules mean something

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

## 6. Watch the volume for a day

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
