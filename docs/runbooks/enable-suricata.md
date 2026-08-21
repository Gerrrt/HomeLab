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

**Services → Suricata → Interfaces → Add**. Do **Skids (VLAN 20)** first, alone.

| Setting | Value | Why |
| --- | --- | --- |
| Interface | Skids / VLAN 20 | The segment with cameras, a doorbell, an alarm hub and a $20 Tuya device |
| Enable | ✔ | |
| **Block Offenders** | **OFF** | Non-negotiable for now. See §5 |
| Send Alerts to System Log | ✔ | This is what puts alerts on the syslog pipe |
| Log to a File | ✔ | Local copy for tuning; Loki is for alerting |

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

- **Enable ET Open** — free, well-maintained, and the right default here.
- Leave Snort VRT off unless you have an Oinkcode.
- **Update Interval:** every 12 hours. **Update Start Time:** something
  unsociable, so a ruleset that starts matching normal traffic does so while
  you are awake rather than at 03:00.

Then **Interfaces → Skids → Categories** and enable, to start:

`emerging-malware` · `emerging-trojan` · `emerging-exploit` ·
`emerging-scan` · `emerging-policy`

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

Whichever route you take, it has to originate **on VLAN 20** and travel in
**plaintext**. Suricata sits on the firewall and cannot see inside TLS, so an
HTTPS request proves nothing about your rules — only that a connection happened.

### If you have a shell on a VLAN 20 device

```bash
curl -A "BlackSun" http://example.com/
```

`ET POLICY` carries a signature for that user agent, and `emerging-policy` is one
of the five categories enabled above.

### If you do not — the case here

VLAN 20 is cameras, a doorbell and an alarm hub. Nothing on it takes a shell, and
a phone browser cannot set a user agent. Rather than go looking for an ET
signature that is simultaneously browser-reachable, plaintext, and inside those
five categories, add two local rules that depend on none of that.

**Interfaces → Skids → Rules → Category: `custom.rules`:**

```text
alert http any any -> any any (msg:"HOMELAB IDS PIPELINE TEST http"; flow:established,to_server; http.uri; content:"/homelab-ids-test"; classtype:not-suspicious; sid:9000001; rev:1;)
alert dns any any -> any any (msg:"HOMELAB IDS PIPELINE TEST dns"; dns.query; content:"homelab-ids-test"; nocase; classtype:not-suspicious; sid:9000002; rev:1;)
```

Save, then restart Suricata on the interface so the rules load.

From a phone joined to the **Skids** SSID, visit:

```text
http://homelab-ids-test.neverssl.com/homelab-ids-test
```

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
