# Runbook: Move the WAN onto `neo`

**Target:** `morpheus`'s WAN, from `em0` (onboard I219, 1000baseT) to
`igc0.2`, VLAN 2 through `neo`'s SFP+ cages at 2.5G
**Time:** an hour of preparation with nothing interrupted, then a 30-minute
window: about a minute with the LAN down, and up to fifteen with the
internet down
**You will need:** two MikroTik S+RJ10 modules, physical access to the rack,
a workstation on Hicks, the switch's serial console cable if you have one, and
`em0`'s MAC address read from `morpheus` (it is not in this repository)

[ADR-0131](../adr/0131-carry-the-wan-through-neos-sfp-cages-at-2-5g.md)
decided the shape. This is how it gets there,
[#1691](https://github.com/Gerrrt/HomeLab/issues/1691). The end state:

| Port | What | VLANs |
| --- | --- | --- |
| `neo` `sfp-sfpplus1` (port 25), S+RJ10 | `morpheus`'s `igc0`, 2.5G | 7 untagged (PVID 7); 2 and every segment VLAN tagged |
| `neo` `sfp-sfpplus2` (port 26), S+RJ10 | The CODA56's 2.5G port | 2 untagged (PVID 2), untagged frames only |
| `neo` `ether1` | Empty, once the cutover has held | none |
| `morpheus` `em0` | Unassigned, cable-free, kept for rollback | — |

## Read this part first

1. **VLAN 2 is the internet.** If it reaches any port but the two above, a
   device on that port gets a public address from the ISP, with no firewall in
   front of it. Before each commit, read `/interface bridge vlan print` and
   confirm VLAN 2 names `sfp-sfpplus1` and `sfp-sfpplus2` and nothing else.
2. **`igc0`'s move is the management path's move.** The switch LAN rides
   `ether1`'s PVID today. `sfp-sfpplus1` must carry PVID 7 and the same
   frame admission before the cable moves, or the workstation loses the
   switch. Do every `neo` change in RouterOS Safe Mode (`Ctrl+X` in the
   terminal), so a lost session undoes it. The serial console is the way in
   that depends on none of this.
3. **The two modules sit side by side on a passive switch**, which is what
   MikroTik's
   [S+RJ10 guidance](https://help.mikrotik.com/docs/spaces/ROS/pages/240156916/S+RJ10+general+guidance)
   warns against. Do not start Phase 2 until §1.2's hour of temperatures
   has been read and the alert exists.
4. **Until Phase 2, the remedy for `WanReceiveErrors` is still rebooting
   `morpheus`.** Nothing in Phase 1 changes the WAN.

---

## Phase 1 — preparation, nothing interrupted

### 1.1 Back up both ends

- `morpheus`: *Diagnostics → Backup & Restore*, download the configuration.
  Keep it off the repository.
- `neo`: `/export file=pre-wan` and copy `pre-wan.rsc` off the switch.
- Read and write down, outside the repository: `em0`'s MAC
  (`ifconfig em0 | grep ether`), the WAN's current public address and its
  IPv6 prefix (*Status → Interfaces*).

### 1.2 Seat the modules and read their heat

Insert both S+RJ10s, `sfp-sfpplus1` and `sfp-sfpplus2`, with nothing
plugged into them. Then:

```
/interface ethernet monitor sfp-sfpplus1,sfp-sfpplus2 once
```

Each should show the module (`sfp-module-present: yes`, vendor MikroTik,
part S+RJ10) and an `sfp-temperature`. Read it again after an hour. Write
both readings, and the room's temperature, into #1691.

Then add the temperature to the scrape, so Phase 2 is watched:

- Walk MIKROTIK-MIB's optical table with `scripts/snmp-walk.sh` and confirm
  the temperature column (`mtxrOpticalTemperature`, under
  `1.3.6.1.4.1.14988.1.1.19.1`) returns a row per module, as
  `generator.yaml`'s other modules were measured before they were written.
- Add it to the `neo` module in
  `stacks/observability/snmp-exporter/generator.yaml`, and add a warning
  alert to `network.rules.yaml` for either module at 80 °C or more for ten
  minutes, with a test. The module can reach 90 °C itself, so 80 leaves
  room to act.
- Deploy it, and see both series in Prometheus before going on.

If an idle module already reads within 10 °C of the alert, stop here.
ADR-0131's fallback is one module, or none.

### 1.3 Prepare `neo`'s bridge

Nothing below changes a port with a link. In Safe Mode:

1. Read `ether1`'s port entry, so `sfp-sfpplus1` can match it:
   ```
   /interface bridge port print detail where interface=ether1
   /interface bridge vlan print
   ```
2. Add `sfp-sfpplus1` to the bridge with `ether1`'s `pvid` (7),
   `frame-types` and `ingress-filtering`. Add it to the `tagged` list of
   every VLAN entry where `ether1` is tagged.
3. Add `sfp-sfpplus2`:
   ```
   /interface bridge port add bridge=<bridge> interface=sfp-sfpplus2 pvid=2 frame-types=admit-only-untagged-and-priority-tagged ingress-filtering=yes edge=yes
   /interface bridge vlan add bridge=<bridge> vlan-ids=2 tagged=sfp-sfpplus1 untagged=sfp-sfpplus2
   ```
   `<bridge>` is the name `/interface bridge print` shows.
4. Re-read `/interface bridge vlan print`. VLAN 2 names the two cages and
   nothing else, and not the bridge itself. Leave Safe Mode to commit.

`SwitchPortVlanChanged` cannot fire on this, because the cages were not
bridge ports before. Their `dot1qPvid` rows appear now, reading 7 and 2.

### 1.4 Prepare `morpheus`

1. *Interfaces → Assignments → VLANs → Add*: parent `igc0`, tag `2`,
   description `WAN`. Do not assign it yet.
2. Read `igc0`'s Energy-Efficient Ethernet setting (`sysctl dev.igc.0 | grep
   -i eee`). If it is on, turn it off in a loader tunable, the way `em0`'s
   is, so it survives a reboot.

---

## Phase 2 — the window

Silence alerts with `component=~"internet|network"` for an hour, from
`prometheus`, as [`move-into-the-32u-rack.md`](move-into-the-32u-rack.md) §2
does. Delete the silence at the end, not on expiry.

### 2.1 Move the trunk: `igc0` to `sfp-sfpplus1`

Move the cable from `neo`'s `ether1` to the S+RJ10 in `sfp-sfpplus1`. The
LAN is down for as long as that takes.

- On `morpheus`: `ifconfig igc0` reads `2500Base-T <full-duplex>`.
- On `neo`: `/interface ethernet monitor sfp-sfpplus1 once` reads
  `rate: 2.5Gbps` and `full-duplex: yes`.
- From the workstation: `https://10.7.7.2/` answers, and a host on each
  segment reaches its gateway.

**Rollback A:** the cable back to `ether1`. Its configuration is untouched.

### 2.2 Move the WAN: the modem to `sfp-sfpplus2`, WAN to `igc0.2`

1. Move the modem's cable from `em0` to the S+RJ10 in `sfp-sfpplus2`.
   `sfp-sfpplus2` should read `2.5Gbps`.
2. *Interfaces → Assignments*: set WAN to `igc0.2` (VLAN 2 on `igc0`).
   Save, then apply.
3. *Interfaces → WAN*: set *MAC Address* to `em0`'s, as read in §1.1. Save,
   then apply.
4. *Status → Interfaces*: WAN has an address, the IPv6 prefix is delegated,
   and *Status → Dynamic DNS* shows the record current. If WAN has no lease
   within two minutes, unplug the CODA56's brick from PDU outlet 5 for 30
   seconds. The modem then learns the client again.
5. Run a speed test from a wired host and one from speedtest-tracker's UI.
   Expect about 940 down on the wired host, which is the client's own
   gigabit port. The tracker's figure is the one to record.

**Rollback B:** the modem's cable back into `em0`, and WAN reassigned to
`em0`, with the *MAC Address* field cleared. Then Rollback A if the trunk is
also suspect.

### 2.3 Close the window

- `netstat -I igc0 -w 5` for a minute: `errs` stays at 0.
- The two modules' temperatures under load are in Prometheus.
- Delete the silence.

---

## Phase 3 — the configuration and the documents

In one PR, with the facts the window measured:

- **`internet.rules.yaml` and its tests.** The recording rules match the
  WAN by `pfInterfacesIfDescr`. Replace `0x656D30` (`em0`) with the hex of
  the new interface's description, read from the exporter rather than
  derived. `WanReceiveErrors` reads `ifInErrors` on `igc0` from `morpheus`
  and on `sfp-sfpplus2` from `neo`. Its description drops the reboot remedy
  and says which end counted. The receive figure in
  `homelab_wan_capacity_bits_per_second` becomes the plan's usable rate, as
  measured in §2.2. The comment at the top of the file stops calling the
  port the ceiling.
- **The Internet dashboard and Glance's network page**, wherever they name
  `em0`.
- `grep -rnE 'em0|0x656D30|ether1\b|port 1\b' docs stacks` and settle
  every hit. A record (the changelog, an ADR, an exercise) is left as
  written.
- **The current-state documents** ADR-0131's *Consequences* lists, and the
  diagram's PNG re-rendered in the same commit.
- **The changelog**, a dated entry: the window, both modules'
  temperatures idle and under load, the speed test, and anything that went
  differently from here.

Then empty `ether1`: remove it from the VLAN entries and from the bridge, in
Safe Mode. `SwitchInterfaceDown` stays quiet, because the port has been down
since the window.

Close #1691 after a week on `igc0.2` with `WanReceiveErrors` quiet and both
modules under the temperature alert.
