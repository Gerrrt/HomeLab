# ADR-0131: Carry the WAN through `neo`'s SFP+ cages at 2.5G

**Status:** Accepted · 2026-11

## Context

`morpheus`'s WAN is `em0`, the ProDesk's onboard Intel I219-LM, at 1000baseT.
Five times between 2026-11-01 and 2026-11-22 it began taking inbound frames as
CRC and fragment errors on a clean full-duplex link. Each time, downloads fell
to a few Mbit/s while upload and latency looked normal, and `WanReceiveErrors`
fired. On 2026-11-22 the errors carried on across a new modem, a re-plug at
`em0` and a different cable, and stopped when `morpheus` was rebooted
([#1594](https://github.com/Gerrrt/HomeLab/issues/1594), the changelog's
2026-11-22 entry). The fault is `em0`'s own state. Rebooting clears it, and
nothing so far has stopped it coming back.

[#922](https://github.com/Gerrrt/HomeLab/issues/922) asked a different
question: whether the 2000/250 Mbit/s plan is worth paying for when every
port in the house is gigabit. It sketched a 2.5G WAN through the CRS326's two
SFP+ cages, and its data (2026-10-10 to 2026-11-09) found no need for it:
download peaked at 71% of ~940 Mbit/s and never held above 85%. On that data
the plan was to downgrade.

Two facts have changed since #922 was written:

- **The WAN has to leave `em0` anyway.** Any design that does so ends the
  recurring fault. #922's sketch is one of them.
- **The modem's port is now trusted.** The XB7's striped 2.5G port was
  blamed for the early incidents. The CODA56 that replaced it has one port,
  2.5G, and the faults that followed it were `em0`'s.

`morpheus` has one other NIC: `igc0`, an Intel I226-V on an M.2 adapter,
2.5G-capable, today meeting `neo`'s `ether1` at 1000baseT as the LAN trunk
and the untagged switch LAN (VLAN 7,
[ADR-0041](0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md)).
`neo`'s copper ports are all gigabit. Its two SFP+ cages, `sfp-sfpplus1` and
`sfp-sfpplus2` (ports 25 and 26), are empty and are not bridge ports. CRS3xx
runs SFP+ at a true 2.5G since RouterOS 7.3, and `neo` runs 7.24.6.

## Decision

**The WAN becomes VLAN 2 on `neo`. The CODA56's 2.5G port goes into
`sfp-sfpplus2`, and `igc0` moves from `ether1` to `sfp-sfpplus1` at 2.5G,
carrying the WAN tagged beside the LAN VLANs. Both cages take a MikroTik
S+RJ10. `em0` leaves service. The 2000/250 plan stays.**

1. **Two MikroTik S+RJ10 modules**, genuine, the module MikroTik's
   compatibility table lists for the CRS326-24G-2S+. They enter through the
   roadmap's *Everything still to buy*.
2. **On `neo`, VLAN 2 touches two ports and nothing else.** `sfp-sfpplus2`
   joins the bridge with PVID 2, admits untagged frames only, and is an edge
   port. VLAN 2 is untagged on `sfp-sfpplus2`, tagged on `sfp-sfpplus1`, and
   not a member of the bridge's own interface, so the switch has no address
   and no service on the WAN. The VID is arbitrary. 2 is unused, and the
   segment VLANs keep their tens.
3. **`sfp-sfpplus1` takes over `ether1`'s role whole.** PVID 7 for the
   untagged switch LAN, the same frame admission, and tagged membership of
   every segment VLAN that `ether1` carries today, plus VLAN 2. `ether1` is
   left configured until the cutover has held, then emptied. The way back
   into the switch stays untagged and stays on the trunk, as ADR-0041
   requires. Only the cage it arrives through changes.
4. **On `morpheus`, WAN is reassigned from `em0` to `igc0.2`**, with `em0`'s
   MAC set on the new interface. The modem and the ISP then see the same
   client, so the DHCP lease and the public address can carry over, and with
   them the dynamic DNS record of
   [ADR-0044](0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md).
   pfSense's rules, NAT and the WireGuard `rdr` name the WAN interface, not
   `em0`, so they follow the assignment.
5. **Heat is watched before it is trusted.** MikroTik's S+RJ10 guidance says
   not to place two side by side, and to add cooling where they must be or
   where the device is passive. The CRS326 is passive, and its two cages are
   adjacent, so this design does exactly what the guidance warns about. The
   module runs in 0–70 °C ambient and can itself reach 90 °C. U22 above the
   switch is already a vented blank for this. The modules' DDM temperature
   joins `neo`'s SNMP scrape, with an alert, before the cutover, and the
   cutover waits until an hour of both modules idling in the cages has been
   read.
6. **Monitoring follows the WAN.** The recording rules and
   `WanReceiveErrors` move from `em0` to `igc0` and `neo`'s
   `sfp-sfpplus2`, and `homelab_wan_capacity_bits_per_second`'s receive
   figure moves from ~940 Mbit/s to what the plan delivers through the new
   path, measured.

The procedure is
[`move-the-wan-onto-neo.md`](../runbooks/move-the-wan-onto-neo.md), and the
build is [#1691](https://github.com/Gerrrt/HomeLab/issues/1691). This
decides #922: the plan stays, and the 2.5G path is built.

## Considered and rejected

- **The WAN as a VLAN on the existing 1G trunk, with the modem on a copper
  port.** It costs nothing and fixes `em0` just as well. It was the
  recommendation put to the operator on 2026-11-23. It caps the WAN at
  ~940 Mbit/s and puts WAN, LAN and inter-VLAN traffic on one gigabit
  trunk. The operator chose to pay ~$130 to make the plan usable and to
  lift the trunk to 2.5G at the same time. It stays the fallback if the
  modules run too hot. It needs no purchase and reuses this ADR's VLAN 2
  configuration on a copper port.
- **One S+RJ10, for `igc0` only, with the modem on a copper port.** It has
  half the heat, but the WAN stays at ~940. It is the step down if two
  modules side by side cannot be held under the alert.
- **A second add-on NIC for the WAN.** The Mini's add-on NIC already takes
  its spare M.2 slot. A USB NIC on a firewall's WAN would trade one
  unreliable port for another.
- **Downgrading the plan, as #922's data suggested.** It saves money and
  leaves `em0` where it is, so it does not touch the fault.
- **Keeping `em0` and rebooting on `WanReceiveErrors`.** It works, and it
  stays the remedy until the cutover. Each recurrence costs slow internet
  until someone sees the alert and is home to reboot the firewall.

## Consequences

- **The internet becomes a VLAN on the core switch.** A bridge commit that
  puts VLAN 2 on any other port hands that port a public DHCP lease from the
  ISP, around the firewall. A reboot or a bad commit on `neo` now takes the
  WAN down as well as the LAN. Two things guard against the first:
  `SwitchPortVlanChanged` sees a PVID change on any bridge port, the cages
  included once they join the bridge; and the port map in
  [`network.md`](../network.md) names VLAN 2's two ports. The rollback is
  physical and short: the modem's cable back into `em0`, and WAN reassigned
  to `em0`. `em0` therefore stays in `morpheus`, unassigned, not removed.
- **One device still tops out at ~940 Mbit/s.** Every client NIC is gigabit.
  The plan's 2000 is reachable only in aggregate, which is what #922 said.
- **`igc0` now carries everything.** Downloads arrive on its receive side
  and leave on its transmit side towards the LAN, so the 2.5G full-duplex
  trunk is shared by WAN, LAN and inter-VLAN traffic. That is more headroom
  than today's 1G trunk carries for LAN alone. `igc0` is also the I226-V,
  a family with its own history of dropped links. Energy-Efficient Ethernet
  is checked and kept off on it, as it is on `em0`.
- **These current-state documents change in the PR that records the
  cutover**, not in this one:
  - [`network.md`](../network.md): the WAN and LAN notes, the port map and
    `[^adapter]`;
  - [`hardware.md`](../hardware.md): the CRS326 row, U22's note and the WAN
    table;
  - [`security.md`](../security.md) and
    [`architecture.md`](../architecture.md), wherever they place the WAN on
    `em0`;
  - the network diagram and its PNG;
  - [`move-into-the-32u-rack.md`](../runbooks/move-into-the-32u-rack.md)
    §6.1;
  - the `em0` series in `internet.rules.yaml`, its tests, the Internet
    dashboard and Glance's network page.

  Until then they describe `em0`, which is still true.
