# Runbook: Enable Suricata on the firewall

**Target:** `morpheus`, the firewall (pfSense CE)
**Time:** thirty minutes to install, then **several days of watching**
**You will need:** the pfSense web UI, and the syslog pipeline from
[`ship-firewall-logs.md`](ship-firewall-logs.md) already working. For §6, the
`interface` label from `syslog.alloy` live on the monitoring host first
**Written against:** pfSense CE 2.8.1. `morpheus` now runs 2.9.0-RELEASE and
the steps below have not been re-walked on it — menu paths and field names are
the parts most likely to have moved, and where the box disagrees with this page,
the box is right. Recorded as what the page was written against rather than
pinned in *Target*, where it read `2.8.1` for a whole release after that stopped
being true

[`security.md`](../security.md) has said "There is no IDS/IPS" since this
repository began. This closes that — on the firewall rather than the
hypervisor, for the reasons in
[ADR-0006](../adr/0006-detect-at-the-chokepoint.md): `Saruman` is single-homed
on VLAN 30, so a sensor there sees `Saruman`. `morpheus` terminates every VLAN
and is the only place that sees the seven cameras, the doorbell and the Tuya
device.

> [!CAUTION]
> **This is the one item in the plan deliberately scheduled last, and the one
> most likely to break the house.** A misconfigured IDS in blocking mode will
> drop the baby monitor, the thermostat, or a work VPN, and the symptom will be
> "the internet is broken" rather than anything that points at Suricata. Every
> step below keeps blocking OFF. Do not turn it on in the same sitting.

---

## 0. Prerequisites

- Firewall logs already reaching Loki. Suricata rides the same pipe, so if this
  is not working, nothing below will be either:

  ```bash
  curl -sG http://localhost:3100/loki/api/v1/query \
    --data-urlencode 'query=sum by (host, app) (count_over_time({source="network"}[5m]))' \
    | jq -r '.data.result[] | "\(.metric.host)\t\(.metric.app)\t\(.value[1])"'
  ```

  Expect `morpheus  filterlog  <n>`. If it is empty, stop and finish
  [`ship-firewall-logs.md`](ship-firewall-logs.md) first. Note it is a **metric**
  query — a bare `{app="filterlog"}` selector is rejected by the instant
  endpoint, and the rejection looks like an absence of data if you pipe it
  straight to `jq`.
- The unconfigured Snort package removed. Two IDS packages installed, one
  dormant, is how you end up debugging the wrong one.

---

## 1. Install

**System → Package Manager → Available Packages**, search `suricata`, install.
It appears afterwards under **Services → Suricata**.

---

## 2. Configure the interfaces

> [!IMPORTANT]
> **`Services → Suricata` opens an empty Interfaces list, and none of the
> settings below exist yet.** Not hidden, not collapsed — not present. `Add` is
> what creates the interface *and* the page that holds every field in this
> section.
>
> The same applies to §3 and §4: the tab row across the top (*Categories*,
> *Rules*, *Flow/Stream*, …) only appears **after the interface has been saved
> once**. Looking for rule categories before then is looking for a tab that does
> not exist.
>
> Order for the whole runbook, therefore:
> **Add → set the fields below → Save → Categories (§3) → Rules (§4) → restart
> the interface.**

**Services → Suricata → Interfaces → Add**. Do **Skids (VLAN 20)** first, alone.

The page is long and sectioned. Only these matter:

| Section | Setting | Value | Why |
| --- | --- | --- | --- |
| General Settings | Enable | ✔ | |
| General Settings | Interface | Skids / VLAN 20 | The segment with cameras, a doorbell, an alarm hub and a $20 Tuya device |
| Logging Settings | **Send Alerts to System Log** | ✔ | **The only setting this pipeline depends on.** Nothing downstream works without it — it is what puts alerts on the syslog pipe to Loki |
| Block Settings | **Block Offenders** | **unticked** | Non-negotiable for now. See §5. With it off, *IPS Mode* below it is irrelevant |

**Everything else: leave at default.** Performance, detection engine, EVE/JSON
output, flow and stream timeouts — this stack consumes none of it, and changing
things here to look thorough is how you end up debugging Suricata instead of
using it.

> [!IMPORTANT]
> **Two fields in *Logging Settings* are load-bearing, and one of them is how
> Loki tells the interfaces apart.** `Log Facility` and `Log Priority` decide
> how these alerts appear on the syslog wire.
>
> The alert line does not say which interface saw it, and pfSense sends every
> interface's alerts with the same syslog tag, `suricata`. The facility is the
> only per-interface setting that reaches the wire, so `syslog.alloy` turns it
> into the `interface` label: `local1` is `igc0.20`, `local2` is `igc0.10`.
> **Leave Skids at the package default, `local1`.** An earlier revision of this
> note called the facility harmless; it stopped being harmless the moment a
> second interface was planned.
>
> Not every facility arrives. pfSense's remote *System Events* selector drops
> `local0`, `local3`, `local4` and `local7` on the box (they are filterlog, VPN,
> portal and DHCP, shipped by their own switches), so an interface set to one of
> those alerts locally and sends **nothing** — indistinguishable from a quiet
> interface. `local2` is safe; so are `local5` and `local6`.
>
> `Log Priority` stays at its default, `notice`. That is the severity the
> alerts measurably cross the selector at; `info` is not guaranteed to. The PRI
> looks like a discrepancy against `filterlog`'s `<134>` in a raw `tcpdump` and
> is not one — the tag still decides `app`, the facility now decides
> `interface`.

**Degens (VLAN 10) is §6**, and it waits until VLAN 20 has been quiet for a few
days. Do not add all interfaces at once — you cannot tell which one is producing
noise if they all start together.

> [!NOTE]
> Do **not** enable Suricata on the WAN interface. It sees the entire internet's
> background scan traffic and will bury real findings under thousands of daily
> alerts for packets the firewall already dropped. The value is in seeing what
> your *own* devices do.

---

## 3. Rules

**Services → Suricata → Global Settings**:

- **Install ETOpen Emerging Threats rules** — free, well-maintained, and the
  right default here.
- Leave Snort VRT and Snort GPLv2 off unless you have an Oinkcode.
- **Update Interval:** every 12 hours. **Update Start Time:** a **waking hour**.
  A ruleset update can start matching normal traffic, and you want to be around
  when it does rather than asleep at 03:00.

Save.

> [!IMPORTANT]
> **Now force an update: Suricata → Updates → Update Rules.**
>
> Ticking ET Open only records a preference. It downloads nothing. Until the
> ruleset is actually on disk **the Categories list below is empty**, which looks
> exactly like a broken runbook rather than a missing download.
>
> It is roughly 60 MB, so on a 15 Mbps line give it a minute. Wait for the tab to
> report a successful update before continuing.

Then **Interfaces → Skids → Categories** and enable, to start:

| Category | Why |
| --- | --- |
| `emerging-malware` | The big one — 16 MB. **Absorbed the retired `emerging-trojan`**, so that coverage is here, not missing |
| `emerging-botcc` | **Botnet command-and-control.** Mirai-family malware is the single largest threat to a segment of cheap cameras, and this is the category that catches one phoning home. Matches on known C2 addresses, so it is close to noiseless |
| `emerging-attack_response` | Command output flowing *back* from a host — evidence of a device already compromised rather than one being probed |
| `emerging-scan` | Probing, inbound and outbound. A camera scanning your other segments is the alarm |
| `emerging-exploit` | Exploitation attempts against the devices themselves |

`emerging-coinminer` is a cheap sixth if you want it: a small file, and mining is
classic post-compromise behaviour on a device with a CPU and no supervision.

> [!NOTE]
> **The category names here are pfSense's, not upstream Emerging Threats'.**
> The package reorganises ET Open, so this list does not match
> `rules.emergingthreats.net` file-for-file:
>
> - **`emerging-trojan` does not exist anywhere.** ET retired it and folded those
>   rules into `emerging-malware`.
> - **`emerging-policy` does not exist in pfSense**, although it does upstream.
>   Its contents are split across `emerging-remote_access`,
>   `emerging-file_sharing`, `emerging-dyn_dns`, `emerging-chat` and
>   `emerging-games`. None of those earn a slot on an IoT segment.
>
> **The list on your box is the authority.** Earlier revisions of this runbook
> named both of the above, which sent people hunting for categories that were
> never going to be there.

Ticking those five is not the whole picture, because the interface did not start
empty:

> [!IMPORTANT]
> **Suricata's own rules are already enabled, and this runbook previously claimed
> otherwise.**
>
> Everything without an `emerging-` prefix — `decoder-events`, `stream-events`,
> `app-layer-events`, `files`, and the ~24 per-protocol `*-events` files — ships
> with Suricata itself and comes **pre-ticked**. Adding the five above adds to
> them; it does not replace them.
>
> **Leave them on through the observation period.** They detect protocol
> anomalies rather than attacks, so they are the likely source of volume — but §5
> is several days of measuring exactly that, and its `topk` query will tell you
> what actually fires on *this* network. Prune on evidence, not on reputation.
>
> If Loki volume becomes a problem before you have that evidence,
> **`decoder-events` and `stream-events` are the two to cut first** — they fire
> on retransmissions and malformed packets, which a house full of cheap wireless
> devices produces constantly.

One setting on this page is worth understanding rather than accepting:

> [!IMPORTANT]
> **Leave `Resolve Flowbits` enabled.**
>
> It auto-enables rules from categories you did *not* select, when a rule you did
> select depends on a flowbit those rules set. Turn it off and a rule in
> `emerging-malware` waiting on a flowbit from, say, `emerging-web_client` simply
> never fires — and nothing anywhere reports that it cannot.
>
> That is a silently disarmed detection, which is the failure mode this whole
> stack is built to avoid. The cost is a handful of extra rules you did not pick.
> Pay it.

Save, then **restart Suricata on the interface** so the selection is loaded. A
saved category list is not a running one.

That is a deliberately narrow set. Enabling everything produces a volume of
alerts that guarantees you stop reading them, which is worse than having no IDS
at all — the same failure the `.gitleaksignore` story in
[`security.md`](../security.md) records.

---

## 4. Verify the pipeline

Suricata writes to the pfSense **system log**, so **Status → System Logs →
Settings** must include **System Events** in *Remote Syslog Contents* — the
log-shipping runbook only enabled Firewall Events.

> [!CAUTION]
> **That is the page that stops `syslogd` forwarding, and you now have a working
> firewall log stream to lose.**
>
> Editing *Remote Syslog Contents* means saving the same settings page that
> twice left the daemon not sending during the log-shipping deploy — once on
> first enable, once after merely removing a stale server entry. Both times the
> page redisplayed perfectly and **zero packets** went out. See §2 of
> [`ship-firewall-logs.md`](ship-firewall-logs.md).
>
> So save it the reliable way: tick **System Events**, **Save**, then untick
> *Enable Remote Logging* → **Save** → re-tick → **Save**.
>
> Then confirm you did not trade filterlog for suricata. Run this **before**
> going looking for Suricata alerts:
>
> ```bash
> curl -sG http://localhost:3100/loki/api/v1/query \
>   --data-urlencode 'query=sum by (app) (count_over_time({source="network"}[5m]))' \
>   | jq -r '.data.result[] | "\(.metric.app)\t\(.value[1])"'
> ```
>
> `filterlog` must still be there with a climbing count. If it has gone quiet,
> the syslog change killed the stream and nothing else in this runbook will work
> — go back and do the untick/save/re-tick/save cycle. **An empty Suricata query
> means nothing until you know filterlog survived.**

Then, from the monitoring host:

`/loki/api/v1/query` is the instant endpoint and takes metric queries only — a
bare `{app="suricata"}` selector is rejected. Wrap it, as here:

```bash
# Are alerts arriving and being parsed into labels?
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (classification,priority) (count_over_time({app="suricata"}[10m]))' \
  | jq -r '.data.result[] | "\(.metric.priority)\t\(.metric.classification)\t\(.value[1])"'

# Did the ids rule group load?
curl -s http://localhost:3100/loki/api/v1/rules | grep -o 'name: ids' || echo "ids group NOT loaded"
```

Now generate a harmless alert to prove the path end to end. **Do not skip this.**
An IDS that has never been shown to report anything is indistinguishable from one
that is not running. `SuricataStopped` (`prometheus/rules/ids.rules.yaml`) proves
the process exists; only this proves it detects (see *Rollback*).

It has to originate **on VLAN 20** and travel in **plaintext**. Suricata sits on
the firewall and cannot see inside TLS, so an HTTPS request proves nothing about
your rules — only that a connection happened.

> [!NOTE]
> Earlier revisions used `curl -A "BlackSun" http://example.com/` and claimed
> `emerging-policy` carried a signature for that user agent. It does not — and
> `emerging-policy` is not even a category pfSense offers (see §3). The BlackSun
> signature lives in `emerging-user_agents`, which this runbook does not enable.
> **That test would have fired for nobody:** a verification step that was itself
> unverified.

The test below depends on **no ET category at all**, which is the point: it tests
the pipeline, not the ruleset.

**Interfaces → Skids → Rules → Category: `custom.rules`:**

```text
alert http any any -> any any (msg:"HOMELAB IDS PIPELINE TEST http"; flow:established,to_server; http.uri; content:"/homelab-ids-test"; classtype:not-suspicious; sid:9000001; rev:1;)
alert dns any any -> any any (msg:"HOMELAB IDS PIPELINE TEST dns"; dns.query; content:"homelab-ids-test"; nocase; classtype:not-suspicious; sid:9000002; rev:1;)
```

Save, then restart Suricata on the interface so the rules load.

Trigger it from anything on VLAN 20. A phone joined to the **Skids** SSID,
visiting:

```text
http://homelab-ids-test.neverssl.com/homelab-ids-test
```

or, if you do have a shell on that segment, the same URL via
`curl http://homelab-ids-test.neverssl.com/homelab-ids-test`. Either works — the
rules match the request, not the client.

Two rules, because each covers the other's blind spot. Browsers try HTTPS first,
so the `http://` URL may be silently upgraded and never appear in plaintext — but
the DNS lookup happens before any of that and is visible regardless, unless the
phone is using DoH. Whichever one fires proves the path.
`neverssl.com` exists specifically to not redirect to HTTPS, which is why it is
the host here rather than `example.com`.

`classtype:not-suspicious` renders as `[Classification: Not Suspicious Traffic]
[Priority: 3]`. That exercises the parsing regex in `syslog.alloy` **without**
tripping `SuricataHighPriorityAlert`, which wants priority 1 — a pipeline test
should not page anyone.

Confirm both the alert and its labels:

```bash
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (classification,priority) (count_over_time({app="suricata"} |= `HOMELAB IDS PIPELINE TEST` [10m]))' \
  | jq -r '.data.result[] | "\(.metric.priority)\t\(.metric.classification)\t\(.value[1])"'
```

Expect `3  Not Suspicious Traffic  1`. **Empty `classification` or `priority`
with a non-zero count means the alert arrived but the regex did not match it** —
a different fault from nothing arriving, and one that would otherwise look
identical.

**Delete both rules once this passes.** They are a test, not a detection, and a
permanent rule matching a string nobody remembers choosing is how a ruleset
becomes untrustworthy.

If nothing appears within a minute, the problem is between Suricata and Loki, not
with your rules — go back to the syslog check above before touching categories.

---

## 5. Watch for several days before considering blocking

This is the actual work, and it cannot be rushed.

```bash
# What is firing, and how much?
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=topk(10, sum by (classification) (count_over_time({app="suricata"}[24h])))' \
  | jq -r '.data.result[] | "\(.metric.classification)\t\(.value[1])"'
```

Expect false positives. Smart TVs and IoT firmware do genuinely strange things
that look like malware to a signature written for enterprise traffic.

Tune by **disabling individual signatures**, not whole categories — and record
why in the pfSense rule comment, because a suppressed rule with no explanation
is indistinguishable from one suppressed by mistake.

### The first one, measured on this network

Within fifteen minutes of enabling the interface, **every single Suricata alert
was the same signature**:

```text
[1:2200121:1] SURICATA Ethertype unknown [Classification: Generic Protocol Command Decode] [Priority: 3]
```

Twenty in fifteen minutes, roughly 1,900 a day, and decoding the raw packets in
the alert body explains all of them: destination `01:80:C2:00:00:0E` with
ethertype `0x88CC` is **LLDP**, and a broadcast frame with ethertype `0x9104` is
vendor traffic. Both are `neo` doing ordinary layer-2 switch things.

That signature lives in `decoder-events.rules`, one of Suricata's own pre-enabled
categories. **Suppress the signature, do not disable the category** — the rest of
`decoder-events` catches genuinely malformed packets:

```text
# SURICATA Ethertype unknown — LLDP (0x88CC) and vendor ethertype 0x9104 from
# neo. Normal L2 switch behaviour, not an anomaly.
suppress gen_id 1, sig_id 2200121
```

The quickest route is **Services → Suricata → Alerts**, find one of those rows
and click the suppress icon beside the signature; pfSense writes the list entry
for you. Then attach the suppress list to the interface.

Note what the volume is *not* a problem for. At roughly 285 KB a day this costs
Loki nothing. The cost is that it was **100% of the alerts** — real findings would
be buried in it, and "are there any Suricata alerts?" stops being a question
worth asking. That is the reason to tune, not disk.

### The second one, measured on this network — and left alone

With `2200121` gone, fourteen days of Skids look like this: 2,949 alerts,
190–357 a day, every one of them priority 3, none priority 1 or 2. And 2,337 of
them — **79%** — are again a single signature:

```text
[1:2210044:2] SURICATA STREAM Packet with invalid timestamp [Classification: Generic Protocol Command Decode] [Priority: 3]
```

It lives in `stream-events.rules`, the other pre-enabled Suricata category §3
named as a likely source of volume. 2,251 of the 2,337 are to port 443, from
eight or so devices rather than one: the Ring alarm hub leads, then an eero
mesh node, the VTech baby monitor, and two addresses `network.md` does not list.
The working reading — a hypothesis, not a finding — is the stream engine's TCP
timestamp check tripping on retransmitted or reordered segments, which cheap
wireless firmware produces constantly. The query that says who, if it changes:

```bash
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=topk(8, sum by (src) (count_over_time({app="suricata"} |= `[1:2210044:` | regexp `\} (?P<src>[\d.]+):\d+ ->` [7d])))' \
  | jq -r '.data.result[] | "\(.metric.src)\t\(.value[1])"'
```

**Not suppressed, deliberately, and this is the difference from `2200121`.**
That one was 100% of alerts at a rate that buried everything; this one is two
alerts every ten minutes, which buries nothing — a priority-1 line is as
findable at 79% as it would be at 0%. And it is the one signature the second
interface can say something about: if Degens shows it at a similar share, it is
the stream engine's view of Wi-Fi in general; if Degens does not, it is these
devices. Suppressing it before that measurement exists would be tuning on
prediction, which is the thing this section is for not doing. Revisit after §6
has run for a fortnight.

> [!CAUTION]
> **Alert bodies contain raw packet bytes, including MAC addresses.**
> `security.md` requires MACs truncated to their OUI anywhere in this repository,
> and `roadmap.md` has an open item to capture dashboard screenshots for the
> README. A Suricata panel showing these lines would publish them. Crop or
> redact before any screenshot leaves the machine.

**Only consider Block Offenders after a fortnight of clean, understood alerts,
and even then not on a segment the household depends on.** Blocking on VLAN 20
means an auto-block can take out a camera, the alarm hub, or the baby monitor.
`security.md` frames a broken DHCP server as a domestic incident; a blocked baby
monitor is the same category of mistake.

---

## 6. The second interface: Degens (VLAN 10)

Guest Wi-Fi and a small unmanaged switch of wired guests. Internet only, client
isolation on, no route to any other segment
([ADR-0013](../adr/0013-segment-access-as-implemented.md)). Its firewall
interface is `igc0.10`.

### Before touching pfSense

Three things have to be true, in this order, and the first two are why this is
a section rather than the one paragraph it used to be.

1. **Skids is quiet and its noise is written down.** Not "seems fine" — the
   numbers in §5, recorded, so that whatever Degens adds is a difference against
   a baseline rather than a feeling. Skids at the time this section was written:
   190–357 alerts a day for fourteen days, every one priority 3, none priority
   1 or 2, 79% of them one signature (§5).
2. **The `interface` label is live and proven on Skids.** `syslog.alloy` maps
   the syslog facility to `interface`, and that change reaches the running
   agent only when the main checkout has it and Alloy has been restarted — see
   §1 of [`ship-firewall-logs.md`](ship-firewall-logs.md) for the "the file is
   newer than the process" trap. Then, ten minutes later:

   ```bash
   curl -sG http://localhost:3100/loki/api/v1/query \
     --data-urlencode 'query=sum by (interface) (count_over_time({app="suricata"}[10m]))' \
     | jq -r '.data.result[] | "\(.metric.interface // "<none>")\t\(.value[1])"'
   ```

   Expect exactly one row, `igc0.20`. A `<none>` row that persists past the
   ten-minute window means Skids is not on `local1` after all — read its *Log
   Facility* field before going further, because the same mistake on Degens
   would be invisible. **Do not add the second interface until the first one is
   labelled.** Two unlabelled interfaces is the situation this whole section
   exists to avoid.
3. **filterlog is still flowing.** The §4 syslog check. Nothing in this section
   touches *Remote Syslog Contents*, so nothing should have changed — verify
   anyway, it is one line.

### Add it

**Services → Suricata → Interfaces → Add**, exactly as §2, with one deliberate
difference:

| Section | Setting | Value | Why |
| --- | --- | --- | --- |
| General Settings | Enable | ✔ | |
| General Settings | Interface | Degens / VLAN 10 | |
| Logging Settings | **Send Alerts to System Log** | ✔ | Same as Skids: the only setting the pipeline depends on |
| Logging Settings | **Log Facility** | **`local2`** | **The one non-default.** This is what becomes `interface="igc0.10"` in Loki. `local1` would merge it with Skids; `local3` would never arrive (§2) |
| Logging Settings | Log Priority | `notice` (default) | §2 |
| Block Settings | **Block Offenders** | **unticked** | Still non-negotiable. §5 applies to every interface |

Leave **Send Suricata Log Messages to System Log** — a separate checkbox for
the engine's own messages, not alerts — **unticked**. Those lines would arrive
as `app="suricata"` with no `[Classification: …]` to parse and whatever facility
that field holds, which is either noise under the right label or noise under
the wrong one.

Save. The tab row appears, as in §2.

### Declare it to Prometheus

`SuricataStopped` fires for every interface named in
`homelab_suricata_expected_interface` (`prometheus/rules/ids.rules.yaml`) that
has no running `suricata -i <interface>` process in the firewall's SNMP process
table. A new interface is invisible to it until it is declared, and a declared
interface with no process fires within ten minutes — so declare it *after* the
process is running, not before. Degens is already declared; a third interface
repeats these steps:

1. Add an `or label_replace(vector(1), "interface", "<interface>", "", "")` line
   to the recording rule.
2. Add a fixture set for it to `prometheus/tests/ids.test.yaml`, so the join is
   proved rather than assumed.
3. `make validate`, deploy, and confirm `hrSWRunStatus{hrSWRunName="suricata"}`
   in Prometheus shows a row whose `hrSWRunParameters` starts `-i <interface>`.

The facility map in `syslog.alloy` and this declaration are the two copies of
the interface list, and neither checks the other.

### Suppress list, categories, restart

**Attach the existing suppress list** before enabling any category. Suppress
lists are attached per interface, so the one carrying `sig_id 2200121` from §5
does nothing for Degens until it is. The LLDP it suppresses comes from `neo`,
which is upstream of both segments; the frames are the same.

**Categories:** the five from §3, plus `emerging-coinminer` if Skids has it.
The argument for a narrow set is stronger here, not weaker — guest devices are
an arbitrary rotating set of phones and laptops, and every category adds
matches against traffic you cannot go and look at.

Save, then **restart Suricata on the interface**. A saved category list is not a
running one (§3).

### Verify the pipeline, per interface

Same two `custom.rules` as §4, added to **Interfaces → Degens → Rules**, then
restart the interface.

> [!IMPORTANT]
> **Wait for the engine before triggering, and check it is actually running.**
> On this box *Restart* stopped the Degens instance and left it stopped — the
> log said `START` and no process appeared — until *Start* was clicked by
> hand, and then loading 22,000 rules took **35 seconds** between "Starting"
> and "Engine started". A test URL visited in that window fires nothing, and
> nothing is exactly what a broken pipeline looks like. The Interfaces page
> shows a running/stopped icon per interface; believe it over the log.

Trigger from a device on the **guest** segment:

```text
http://homelab-ids-test.neverssl.com/homelab-ids-test
```

Client isolation does not affect this: it stops guests reaching each other, and
the test is egress. Expect the **DNS** rule to be the one that fires.

> [!WARNING]
> **An iPhone with iCloud Private Relay fires neither rule.** Private Relay
> tunnels DNS *and* HTTP, so the phone that seems the obvious guest client
> produced no port-53 and no port-80 packet on `igc0.10` at all — measured with
> `tcpdump -i igc0.10 -n port 53 or port 80` on `morpheus`, which is the
> command that settles "is this device's traffic even visible". §4's caveat about DoH
> was half of this: it said only the HTTP rule could fire, and Private Relay
> takes that one too. Use a device whose DNS goes to `10.0.10.1` in the clear
> (the same `tcpdump` shows which ones do), or on the phone turn off *Limit IP
> Address Tracking* for that Wi-Fi network and retry. The `curl` from a laptop
> fired the DNS rule three times in a millisecond (A, AAAA and HTTPS lookups)
> and the HTTP rule not at all — unexplained, and not worth chasing while the
> DNS rule proves the path.

```bash
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (interface,classification,priority) (count_over_time({app="suricata"} |= `HOMELAB IDS PIPELINE TEST` [10m]))' \
  | jq -r '.data.result[] | "\(.metric.interface // "<none>")\t\(.metric.priority)\t\(.metric.classification)\t\(.value[1])"'
```

Expect `igc0.10  3  Not Suspicious Traffic  1`. Three distinct failures look
alike without the `interface` column: `<none>` means the alert arrived on a
facility `syslog.alloy` does not map (check the *Log Facility* field);
`igc0.20` means you added the rules to the wrong interface; an empty result
with `filterlog` still climbing means Suricata on Degens is not sending at all.

That last one splits again, and the engine's own log is what splits it. On
`morpheus`, `/var/log/suricata/suricata_igc0.10*/alerts.log` is written by the
process before anything reaches syslog. **Empty there means the alert never
fired** — the process was down, or the client's traffic was not visible (the
two callouts above) — and the syslog path is not the suspect. A line there
and nothing in Loki means the syslog path *is* the suspect, and §4's *Remote
Syslog Contents* check is where to go.

**Delete both test rules once this passes**, as in §4.

### Watch it, by interface

The §5 query with one more dimension. This is the query that justifies doing
the interfaces one at a time:

```bash
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=topk(10, sum by (interface, classification) (count_over_time({app="suricata"}[24h])))' \
  | jq -r '.data.result[] | "\(.metric.interface)\t\(.metric.classification)\t\(.value[1])"'
```

Guest noise will not look like IoT noise, and three differences are worth
expecting rather than discovering:

- **No east–west.** Client isolation means guests cannot reach each other and
  the firewall blocks everything inward, so the lateral-movement signal that
  matters on Skids barely exists here. What Degens can show is egress: DNS,
  plaintext HTTP, a beacon to a known-bad address.
- **Sources do not persist.** A Skids address is a device you can walk over to.
  A Degens address is whoever was on the couch, and next week it is someone
  else. Tune by signature, as always; do not tune by source.
- **The one signature to compare.** §5's `2210044` is 79% of Skids. If Degens
  shows it at a similar share, it is the stream engine's view of Wi-Fi in
  general; if Degens does not, it is something about the Skids devices. That
  is a question the second interface answers and the first could not.

One measurement to take once, because the interfaces share a firewall: a packet
crossing from one monitored segment to another could in principle be seen by
both processes. In practice `pf` drops it before the second interface sees it,
and nothing between these two segments is permitted. Confirm rather than assume:

```bash
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum(count_over_time({app="suricata", interface="igc0.10"} |~ `10\.0\.20\.` [24h]))' \
  | jq -r '.data.result[]?.value[1] // "0"'
```

Expect `0`. Anything else is either a permitted inter-segment flow that ADR-0013
says should not exist, or double counting — and both are worth knowing.

**Blocking stays off.** The domestic-incident argument in §5 is weaker on a
guest segment than on the one with the baby monitor, and the other argument is
stronger: an auto-block on Degens hits a device whose owner cannot be told why.
Alert-only, on every interface, until a fortnight of understood alerts on each.

### Measured on this network

Degens went live at 16:30 PDT on 2026-09-02, on `local2`. The first alert
came **two seconds** after "Engine started", reached Loki as `igc0.10`, and
was `2210044` — the same stream-timestamp signature that is 79% of Skids —
from a guest phone to a Google address on `:443`. Every alert since has
carried the label; the unlabelled count is zero. The cross-segment query
above returned `0`, so the two processes do not double-count.

The first ten minutes, for the record rather than as a baseline: three alerts
on `igc0.10`, two of them `2210044` and one other `stream-events` signature
(`2210027`), from two of the four devices holding VLAN 10 leases at the time —
a phone and a laptop. Skids produced three in the same window. All priority 3.
Ten minutes is a sample of nothing; the "watch it, by interface" query above
is the one to run after a day, and its numbers belong here when they exist.

**Revisit `2210044` on 2026-09-16**, a fortnight in: compare its share on
`igc0.10` against Skids' 79% with the §5 query, and only then decide whether
it is the stream engine's view of Wi-Fi or the Skids devices.

---

## Rollback

**Services → Suricata → Interfaces**, untick Enable on the interface in
question. Alerts stop immediately for that interface and only that one; nothing
else in the stack is affected — except that `SuricataStopped` fires for it ten
minutes later, because the interface is still declared in
`prometheus/rules/ids.rules.yaml`. Remove its line from
`homelab_suricata_expected_interface` (and its fixtures in
`prometheus/tests/ids.test.yaml`) in the same change if the retirement is meant
to last; leave it if the stop is temporary and the alert is the reminder.

The `ids` rule group in Loki stays loaded and simply has nothing to match, which
is harmless. A quiet IDS and a dead IDS produce identical log output, which is
why the stopped-process rule reads the firewall's process table over SNMP
rather than these logs ([#90](https://github.com/Gerrrt/HomeLab/issues/90)).
