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

- Firewall logs already reaching Loki. If `{app="filterlog"}` returns nothing,
  stop and finish [`ship-firewall-logs.md`](ship-firewall-logs.md) first —
  Suricata rides the same pipe.
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

Then, from the monitoring host:

```bash
# Are alerts arriving and being parsed into labels?
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={app="suricata"}' | jq -r '.data.result[].stream' | head

# Did the ids rule group load?
curl -s http://localhost:3100/loki/api/v1/rules | grep -o 'name: ids' || echo "ids group NOT loaded"
```

Generate a harmless alert to prove the path end to end, from a VLAN 20 device:

```bash
curl -A "BlackSun" http://example.com/
```

`ET POLICY` has a signature for that user agent. If nothing appears within a
minute, the problem is between Suricata and Loki, not with your rules.

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
