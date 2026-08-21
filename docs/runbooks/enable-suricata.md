# Runbook: Enable Suricata on the firewall

**Target:** `morpheus` (pfSense CE 2.8.1)
**Time:** thirty minutes to install, then **several days of watching**
**You will need:** the pfSense web UI, and the syslog pipeline from
[`ship-firewall-logs.md`](ship-firewall-logs.md) already working

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

> [!NOTE]
> Two fields in *Logging Settings* are worth recognising and **not** changing.
> `Log Facility` and `Log Priority` decide how these alerts appear on the syslog
> wire. pfSense's `filterlog` arrives as `<134>` — facility `local0`, severity
> `info` — and Suricata may well default to `local1`. That difference is
> harmless: `config.alloy` keys on the syslog **tag**, not the facility, so
> alerts are labelled `app="suricata"` either way. It looks like a discrepancy in
> a raw `tcpdump` and is not one.

Add **Degens (VLAN 10)** the same way once VLAN 20 has been quiet for a few
days. Do not add all interfaces at once — you cannot tell which one is
producing noise if they all start together.

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
| `emerging-exploit` | |
| `emerging-scan` | |
| `emerging-policy` | Tiny (~2 KB) and easy to scroll past in the alphabetical list. It is there |
| `emerging-attack_response` | Command output flowing *back* from a host — evidence of a device already compromised rather than one being probed. Low volume, and the highest-value signal available on a segment of cameras and an alarm hub |

> [!NOTE]
> **There is no `emerging-trojan`.** Emerging Threats retired it and folded those
> rules into `emerging-malware`. Earlier revisions of this runbook named it, which
> sends you looking for a category that has not shipped in years. If you are
> checking this list against another guide, that is why.

**Nothing needs disabling.** A new interface starts with no categories selected,
so the end state is these five ticked and nothing else. If your build pre-ticked
anything, untick it.

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
that is not running, and this stack deliberately has no `SuricataStopped` rule to
tell you otherwise (see *Rollback*).

It has to originate **on VLAN 20** and travel in **plaintext**. Suricata sits on
the firewall and cannot see inside TLS, so an HTTPS request proves nothing about
your rules — only that a connection happened.

> [!NOTE]
> Earlier revisions used `curl -A "BlackSun" http://example.com/` and claimed
> `emerging-policy` carried a signature for that user agent. **It does not.**
> `emerging-policy.rules` is about 2 KB of Dameware, TeamViewer and Radmin
> detections; the BlackSun signature lives in `emerging-user_agents`, which this
> runbook does not enable. That test would have fired for nobody — a verification
> step that was itself unverified.

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
[Priority: 3]`. That exercises the parsing regex in `config.alloy` **without**
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

**Only consider Block Offenders after a fortnight of clean, understood alerts,
and even then not on a segment the household depends on.** Blocking on VLAN 20
means an auto-block can take out a camera, the alarm hub, or the baby monitor.
`security.md` frames a broken DHCP server as a domestic incident; a blocked baby
monitor is the same category of mistake.

---

## Rollback

**Services → Suricata → Interfaces**, untick Enable. Alerts stop immediately;
nothing else in the stack is affected.

The `ids` rule group stays loaded and simply has nothing to match, which is
harmless — and is exactly why there is **no `SuricataStopped` alert**. A quiet
IDS and a dead IDS produce identical log output. Detecting the difference needs
a process metric, not a log rule; it is tracked in
[`roadmap.md`](../roadmap.md).
