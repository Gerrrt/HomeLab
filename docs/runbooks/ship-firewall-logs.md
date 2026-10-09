# Runbook: Ship the firewall's logs to Loki

**Target:** `morpheus` (pfSense) → Alloy on `prometheus`, over TLS
**Time:** about an hour, most of it the syslog-ng setup on morpheus, plus a
careful first restart of Alloy
**You will need:** the pfSense web UI and its console or shell, and a shell on
the monitoring host with `sudo` for tcpdump

Every VLAN in this lab terminates on `morpheus`, which makes it the only device
that sees inter-VLAN and egress traffic for the whole house. It is also a
FreeBSD appliance that cannot run Alloy. So the log store held `auth.log` from
two Linux hosts and nothing at all from the firewall — eight LogQL security
rules watching the quietest surface in the estate.

This connects them, along this path:

```text
pfSense syslogd ──udp──▶ 127.0.0.1:5140 syslog-ng (on morpheus)
                                   │
                                   └──TLS, morpheus's client certificate──▶ 10.0.99.20:6514 Alloy ──▶ Loki
```

pfSense's own syslogd sends UDP only, and only to a remote server. So it sends
to a **syslog-ng** on the firewall itself, on loopback, and syslog-ng relays
every line over TLS. The receiver requires morpheus's own client certificate,
pinned, and drops any sender address `syslog.alloy` does not name. A UDP
receiver would accept a forged `10.0.99.1` from anywhere on VLAN 99; §9 says why
there is not one any more.

---

## 1. Issue both certificates, before the receiver is deployed

The listener mounts two files that do not exist until this step: its own
server leaf and morpheus's client certificate. compose refuses to start Alloy
without them, and that Alloy is the one collecting **everything** on this
host. So run this on the monitoring host, which holds the estate CA, before
the first `make up` that carries the listener:

```bash
scripts/gen-certs.sh --host syslog.matrix.elysium --ip 10.0.99.20
scripts/gen-certs.sh --host morpheus.matrix.elysium --ip 10.0.99.1 --client
```

The first is the listener's own leaf. Its key is mounted into nothing else,
so it is not the ingest proxy's. The second reports `EKU clientAuth`, and
`syslog.alloy` pins that exact certificate. Re-issuing it later means
restarting Alloy, which reads the pin at start, and copying the new files to
morpheus (§3).

---

## 2. Deploy the receiver

The listener has to exist before morpheus starts sending, or the first lines
are lost: syslog-ng retries, but pfSense's syslogd does not, and nothing can be
replayed.

> [!CAUTION]
> The listener lives in `alloy/syslog.alloy`, which only the monitoring host
> loads — but Alloy loads the whole directory as one config, so a syntax or
> schema error in it takes down all of this host's collection, not just the new
> listener. CI runs `alloy fmt --test`, which parses the files but does **not**
> validate component arguments. Bring Alloy up on its own and read its logs
> before assuming this worked — **with `LOKI_URL` and
> `PROMETHEUS_REMOTE_WRITE_URL` pointed at `http://127.0.0.1:1/`**. A
> throwaway container on the default bridge resolves `prometheus` through the
> host's DNS, which is this very host, and pushes a `host="<container id>"`
> series into the live stores; #88 found that out by tripping
> `RemoteWriteJobStale` on itself.

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

What you want to see: no `Error` lines, and the listener starting with TLS. What
tells you it failed: Alloy exiting immediately, complaining about an unknown
argument in `loki.source.syslog`, or naming a certificate file it cannot open.

```bash
docker logs alloy 2>&1 | grep 'protocol=tcp tls=true'     # the 6514 listener, with TLS
docker compose ps alloy                                    # expect 10.0.99.20:6514->6514/tcp
ss -ltn | grep ':6514 '                                    # 10.0.99.20:6514, not 0.0.0.0
```

A connection with no client certificate has to be refused. This one should
end in `alert certificate required`:

```bash
openssl s_client -connect 10.0.99.20:6514 -CAfile certificates/ca.pem </dev/null 2>&1 | tail -3
```

> [!IMPORTANT]
> **Confirm the running process is actually using the config you just edited.**
> `config.alloy` is a bind mount, and `docker compose up -d` recreates a
> container only when its *service definition* changes — image, command, ports,
> environment. An edited mounted file is invisible to that comparison, so
> compose leaves the container running and **exits 0 reporting success** while
> Alloy carries on with what it parsed at boot.
>
> `scripts/reload-config.sh` now restarts Alloy as part of `make up`, so this
> should take care of itself. Verify it anyway — the check is one line, and this
> failure looks identical to the config being wrong:
>
> ```bash
> docker inspect -f '{{.State.StartedAt}}' alloy
> stat -c '%y  %n' alloy/syslog.alloy
> ```
>
> **If the file is newer than the process, the running agent has never seen it.**
> `docker compose restart alloy` fixes it. This cost an evening of debugging a
> config that was correct and simply not loaded.

---

## 3. Install and configure syslog-ng on morpheus

1. **System → Package Manager → Available Packages**, install `syslog-ng`.
2. Copy `certificates/ca.pem`, `certificates/morpheus.matrix.elysium.pem` and
   `certificates/morpheus.matrix.elysium-key.pem` to
   `/usr/local/etc/syslog-ng/tls/` on morpheus, as `ca.pem`, `morpheus.pem`
   and `morpheus-key.pem`. The key must be `0600`, owned by root.
3. In **Services → Syslog-ng**, under Advanced, add these objects. They
   receive pfSense's own syslog on loopback and relay it over TLS. Check the
   field names against the package's form on the box, since this was written
   before the first install:

   ```text
   source s_pfsense {
     network(ip("127.0.0.1") port(5140) transport("udp") flags(no-hostname));
   };
   destination d_alloy_tls {
     syslog("10.0.99.20" port(6514) transport("tls")
       tls(ca-file("/usr/local/etc/syslog-ng/tls/ca.pem")
           cert-file("/usr/local/etc/syslog-ng/tls/morpheus.pem")
           key-file("/usr/local/etc/syslog-ng/tls/morpheus-key.pem")
           peer-verify(required-trusted)));
   };
   log { source(s_pfsense); destination(d_alloy_tls); };
   ```

   `flags(no-hostname)` matters. pfSense's lines carry no hostname
   (`<134>Oct  7 18:00:00 filterlog[4242]: …`), and without the flag syslog-ng
   can read the tag as one. `peer-verify(required-trusted)` makes morpheus
   check the listener's certificate as well, against the same CA.

The loopback hop is UDP, and that is fine: `127.0.0.1` cannot be reached, let
alone forged, from another host. The TLS hop is the one that crosses VLAN 99.

The certificate files sit outside `config.xml`, so a config restore does not
bring them back. After [`restore-the-firewall.md`](restore-the-firewall.md),
repeat step 2.

---

## 4. Point pfSense at syslog-ng

**Status → System Logs → Settings**, then:

| Field | Value |
| --- | --- |
| Enable Remote Logging | ✔ |
| Remote log servers | `127.0.0.1:5140` |
| Remote Syslog Contents | **Firewall Events** |

Leave the other content classes off to begin with. Firewall events alone are
the reason for doing this; DNS resolver and the rest can be added once the
volume is understood — this is a 30-day retention Loki on a 2012 MacBook, and
turning everything on at once is how you find out what its ingest ceiling is
the hard way.

Two more classes have been added since, each by the change that needed it and
each with a number behind it. **Ticking one is still an edit to this page**, so
it is the same unreliable save (below) and the same risk of trading one stream
for another:

| Class | Added by | Carries | Volume |
| --- | --- | --- | --- |
| Firewall Events | this runbook | `filterlog` | ~3,798 lines/hour (#83) |
| System Events | [`enable-suricata.md`](enable-suricata.md) §4 | `suricata`, and the rest of the system log | Varies with the ruleset |
| DHCP Events | [ADR-0019](../adr/0019-read-device-joins-from-the-dhcp-server.md) | `kea-dhcp4` | ~1,200 lines/day, measured on `morpheus` |

The DHCP class is shipped by **program name** — `/var/etc/syslog.d/pfSense.conf`
matches `kea-dhcp4,kea-dhcp6` and forwards every severity — so unlike Suricata
it does not depend on a facility surviving the System Events selector. It also
means System Events does *not* carry it: Kea is on that selector's exclusion
list, which is why the class has to be ticked separately.

> [!IMPORTANT]
> **Tick DHCP Events before the ADR-0019 rules are deployed, not after.**
> `DhcpLeaseLogsStopped` is an `absent_over_time` rule, and a stream that has
> never existed is absent — verified against a real Loki, the expression
> returns 1 for a stream nobody has ever pushed. Deploy the rules first and it
> fires truthfully, immediately and permanently.
>
> **Then expect one alert per device for the first week.** The two
> unknown-device rules compare the last ten minutes against the previous seven
> days, so until seven days of lease history exist every device on Hicks and
> Winterfell announces itself once — about twenty and three respectively. That
> is a one-off inventory, and each line is a claim worth checking against
> [`network.md`](../network.md). Silencing it is a choice; reading it is the
> better one.

No firewall rule is needed. `morpheus` already has an interface on VLAN 99
(`10.0.99.1`) and `prometheus` is on the same segment.

> [!IMPORTANT]
> **Saving this page does not reliably restart `syslogd`.** Observed here: the
> settings saved, the page redisplayed with every field correct, and pfSense sent
> **nothing at all** — no packets on any port, for as long as anyone cared to
> watch. Editing the server list a second time and saving again forced the
> reload, and traffic started in the same second.
>
> Observed **twice** in one evening, the second time after nothing more than
> removing a stale entry from the server list. Assume the reload does not stick.
>
> **The sequence that works:** untick *Enable Remote Logging* → **Save** →
> re-tick it → **Save**. Taking the daemon down and back up is reliable in a way
> that a single save is not. If it still will not send, **Diagnostics → Command
> Prompt** → *Execute PHP Command* → `system_syslogd_start();` restarts it
> directly.
>
> The consequence for debugging is the reason §5 exists: a correct-looking
> settings page is not evidence that the daemon is sending, and an empty Loki
> query cannot tell you which of the two it is.

Use the **full `host:port`** form. A bare `127.0.0.1` sends to syslog's default
port 514, where nothing listens — the packets are simply discarded and the
symptom is identical to not sending at all.

---

## 5. Confirm it is actually sending

Do this **before** querying Loki. It reads the wire rather than a UI, and it is
the only step that separates *pfSense is not sending*, *syslog-ng is not
relaying*, and *the lines arrive and something downstream drops them*. Those
faults look the same from Loki and have completely different fixes. There are
two hops, so look at both.

**The loopback hop, on morpheus** (its shell, or **Diagnostics → Command
Prompt**). This is the one place the payload is still readable, since the next
hop is encrypted:

```bash
tcpdump -ni lo0 -A -c 3 'udp port 5140'
```

Generate something the firewall will log while this runs — browsing from a phone
on the IoT VLAN is enough.

```text
<134>Aug 20 20:25:28 filterlog[97178]: 4,,,1000000103,em0,match,block,in,4,...
```

Two things in that line cost an evening, and both are invisible from Loki:

**There is no hostname.** RFC 3164 is `<PRI>TIMESTAMP HOSTNAME TAG:` — pfSense
goes straight from timestamp to tag. That is why syslog-ng needs
`flags(no-hostname)` (§3), and why `syslog.alloy` derives `host` from the
connection address rather than from anything in the line.

**The timestamp is local, and says so nowhere.** Compare it against the capture
time. Above, `20:25:28` was captured at `03:25:28` UTC — morpheus runs seven
hours behind and RFC 3164 has no timezone field. That is why the listener
stamps receive time (`use_incoming_timestamp = false`); the comment in
`syslog.alloy` says what happened the one time it did not.

| What you see on `lo0` | What it means |
| --- | --- |
| Nothing | pfSense is not sending. Go back to §4 and save the reliable way. |
| Lines to port **514** | A bare `127.0.0.1` was entered in the server list. Fix it to `127.0.0.1:5140`. |
| Lines to **5140** | pfSense is sending. Check the TLS hop next. |

**The TLS hop, on the monitoring host:**

```bash
sudo tcpdump -ni any 'tcp port 6514' -c 10
```

| What you see | What it means |
| --- | --- |
| Nothing | syslog-ng is not relaying. Read its log on morpheus, and check the certificate paths in §3. |
| A handshake, then a reset | The TLS handshake failed. `docker logs alloy` names the reason: no client certificate, or one that is not the pinned `morpheus.pem`. |
| Traffic on the physical NIC only | It is arriving but not reaching the container. Recheck the port publish in §2. |
| Traffic on both the NIC and a `br-`/`veth` interface | Docker is forwarding it to Alloy. Continue below. |
| Forwarded to the container, never in Loki, and `loki_process_dropped_lines_total{reason="syslog_sender_not_allowed"}` rising on Alloy's `:12345/metrics` | The sender's address is not in the allowlist. Add a rule for it to `loki.relabel "network_syslog"` in `alloy/syslog.alloy` (#844). |

If lines arrive but nothing lands in Loki, Alloy's own counters settle it in
one command:

```bash
curl -s localhost:12345/metrics | grep -E \
  'loki_source_syslog_(entries|parsing_errors|empty_messages)_total|loki_write_(sent|dropped)_entries_total'
```

| Reading | Fault |
| --- | --- |
| `entries_total` 0 | Nothing reached the listener. Not an Alloy problem — go back to the TLS hop. |
| `entries_total` climbing, `parsing_errors_total` climbing | Received but unparseable. syslog-ng is not sending RFC 5424 with octet-counted framing, which its `syslog()` driver does by default. |
| `entries_total` climbing, `write_sent_entries_total` flat | Parsed but not shipped. Check `loki_write_dropped_entries_total` for the reason label, and that Loki is up. |
| Both climbing together | Working. The problem is your query, not the pipeline. |

> [!NOTE]
> `loki_relabel_entries_processed{component_id="loki.relabel.network_syslog"}`
> reads **0 forever, and that is correct.** That component exists only to hand
> its `.rules` to `loki.source.syslog`; the relabelling happens inside the
> listener, so the component itself never sees an entry. It looks like a dead
> component and is not one.

---

## 6. Verify

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

# Is it labelled with the SENDER's hostname, over TLS, and which apps are arriving?
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (host,transport,app) (count_over_time({host="morpheus"}[10m]))' \
  | jq -r '.data.result[] | "\(.metric.host)\t\(.metric.transport)\t\(.metric.app)\t\(.value[1])"'

# Are filterlog lines being parsed into labels? Empty action/interface here
# means the regex did not match your log format.
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (action,direction,interface) (count_over_time({app="filterlog"}[10m]))' \
  | jq -r '.data.result[] | "\(.metric.action)\t\(.metric.direction)\t\(.metric.interface)\t\(.value[1])"'

# Suricata's per-interface label, which comes from the syslog facility, survived
# the relay through syslog-ng.
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (interface) (count_over_time({host="morpheus", app="suricata"}[30m]))' \
  | jq '.data.result'
```

You should see `host="morpheus"`, `transport="tls"`, and `action` as
`pass`/`block`.

That name does not come from the log line. pfSense sends no hostname (§5), so
`syslog.alloy` maps it from the connection address `10.0.99.1`. A second syslog
sender needs its own rule, or it is dropped and counted — and a sender that is
dropped reads exactly like nothing being sent.

> [!CAUTION]
> **An empty result is not evidence of absence.** Check
> `loki_source_syslog_entries_total` from §5 before believing one. Alloy
> receiving and Loki storing are not the same thing as a query matching: entries
> written with a bad timestamp are accepted with a `204`, are never counted in
> `loki_discarded_samples_total`, and cannot be reached by any range you would
> think to try. That combination — every counter green, every query empty — is
> what the `use_incoming_timestamp` comment in `syslog.alloy` exists to prevent
> recurring.

One more label trap, on the other path:

> [!NOTE]
> If logs arrive but are labelled `host="prometheus"`, the network syslog stream
> is being written through the wrong client. `loki.write.grafana_loki` stamps
> `host = constants.hostname` on everything it sends, which is right for logs
> this machine produces and wrong for logs it relays. That is the entire reason
> `loki.write.network_syslog` exists as a separate component with no
> `external_labels`.

If DHCP Events is ticked, confirm the lease stream arrives and parses. `mac` is
extracted at query time rather than being a label (ADR-0019), so this is also
the check that the regex still matches what Kea emits — an empty result with
lines present means the line format moved:

```bash
# Lease lines arriving at all, by segment.
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (vlan) (count_over_time({app="kea-dhcp4"} | regexp `10\.0\.(?P<vlan>[0-9]{1,3})\.` [1h]))' \
  | jq -r '.data.result[] | "vlan \(.metric.vlan)\t\(.value[1])"'

# How many distinct devices Loki has seen on Hicks in the last day. This is the
# list the unknown-device rules compare against; if it is empty, they cannot
# fire.
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=count(sum by (mac) (count_over_time({app="kea-dhcp4"} | regexp `hwtype=1 (?P<mac>[0-9a-f:]{17}).*10\.0\.(?P<vlan>[0-9]{1,3})\.` | vlan = "50" [24h])))' \
  | jq -r '.data.result[].value[1]'
```

Then confirm the rules loaded:

```bash
curl -s http://localhost:3100/loki/api/v1/rules | grep -o 'name: firewall' || echo "firewall group not loaded"
curl -s http://localhost:3100/loki/api/v1/rules | grep -o 'name: dhcp' || echo "dhcp group not loaded"
```

---

## 7. Prove the segmentation rules mean something

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

## 8. Watch the volume for a day

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

## 9. Why TLS, and not UDP (#1049)

The first build of this runbook had pfSense's syslogd send UDP straight to
`10.0.99.20:1514`, with the standard `514` published beside it. UDP has no
handshake, so any host on VLAN 99 could send a line with a forged source of
`10.0.99.1` and have it stored as `host="morpheus"`, filterlog and Suricata lines
included. #844's sender allowlist could not tell the difference, and the Loki
security rules read those lines.

So the receiver moved to **6514/tcp with TLS, requiring morpheus's own client
certificate**, pinned: no other certificate passes, even another client leaf
from the same CA. The allowlist still applies on top, so taking over
`10.0.99.1` is not enough without morpheus's key, and the key is not enough
from another address. `stacks/observability/alloy/syslog.alloy` says why each
part is needed.

The switch-over ran both transports side by side for a day, labelled
`transport="udp"` and `transport="tls"`, because a gap in firewall logs cannot be
replayed. Then pfSense stopped sending UDP, and the UDP listener and its `1514`
and `514` publishes were removed. Nothing on the monitoring host listens for
UDP syslog now. A UDP line sent from `10.0.99.1` itself is not stored, and
`scripts/check_syslog_senders.sh` proves it.

---

## Rollback

Untick **Enable Remote Logging** on pfSense. That stops the source instantly and
needs no change on the monitoring host.

`FirewallLogsStopped` will fire 30 minutes later, `DhcpLeaseLogsStopped` two
hours later if the DHCP class was on, and `SuricataLogsStopped` nine hours later
if System Events was. All three are correct — they exist precisely so that a
silent pipeline is distinguishable from a quiet network. Silence them if the
stop was deliberate.

**There is no UDP fallback.** Pointing pfSense at `10.0.99.20:1514` reaches
nothing, and a UDP sender gets no error for it. If syslog-ng on morpheus fails,
fix it there (§3), and read §5's two hops to find which side broke;
`FirewallLogsStopped` says the logs have stopped. Bringing UDP back means
reverting the change that removed it on #1049, which reopens the forgeable
path, so treat it as a decision rather than a rollback.

Unticking **DHCP Events** alone is the narrower rollback, and it is the one
`FirewallLogsStopped` cannot see: filterlog keeps arriving while the lease
stream goes. That is the fault `DhcpLeaseLogsStopped` exists for.
