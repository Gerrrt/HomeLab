# Hardware

A 9U open-frame rack, a firewall built from a refurbished mini PC, a
decommissioned enterprise server, and two laptops that were headed for a
landfill.

## Rack

| U | Device | Role |
| --- | --- | --- |
| U1–U2 | APC Smart-UPS[^UPS] | Power |
| U3 | HPE ProLiant DL360 Gen9[^Shiva] | Proxmox hypervisor (`Saruman`, BMC `shiva`) |
| U5 | HP ProDesk 600 G4 Mini[^ProDesk] | pfSense firewall (`morpheus`) |
| U6 | MT-VIKI 8-port KVM[^KVM] | Console access |
| U7 | 10-outlet PDU[^PDU] | Power distribution |
| U8 | Jadol 24-port patch panel[^Panel] | Cabling |
| U9 | MokerLink 26-port managed switch[^MokerLink] | Core switching (`neo`) |

Off-rack: two Ubuntu Server laptops on a shelf (`prometheus`, `oracle`), an
8-port unmanaged TP-Link switch feeding them, and eero Pro 6E units distributed
through the house.

The patch panel and the PDU were listed the other way round here until
2026-08-29. U8 is the panel and U7 is the PDU, confirmed against the rack.
Nothing in this repository depended on the order, but the wiki's rack page had
it right and this table did not, so the correction is recorded rather than
quietly swapped.

## Compute

| Host | Hardware | CPU | RAM | Storage | OS |
| --- | --- | --- | --- | --- | --- |
| `morpheus` | HP ProDesk 600 G4 Mini | i5-8500T | 32 GB | 1 TB SSD | FreeBSD 15.0 (pfSense) |
| `Saruman` | HPE ProLiant DL360 Gen9 | 2× Xeon E5-2680 v3 (48 threads) | 128 GB | 2× 1 TB SAS HDD, RAID 1 | Proxmox VE 9.2.11 |
| `prometheus` | Apple MacBook Pro (2012, Retina 13") | i5/i7 | 8 GB | 256 GB SSD | Ubuntu Server 24.04.3 |
| `oracle` | Dell Inspiron 15-3565 | AMD A6-9200 (2 cores) | 4 GB | 500 GB HDD | Ubuntu Server 24.04.3 |

The observability stack runs on a thirteen-year-old MacBook. It handles four
SNMP devices at a 60-second interval, three Alloy agents, and 30 days of metric
retention without complaint — which is a useful thing to know before spending
money on a monitoring host. Its RAM is soldered at 8 GB and it has no built-in
Ethernet, so it reaches the network over a USB NIC.

`oracle` was previously recorded here as an i5-1235U with 32 GB and a 2 TB SSD.
It is not: it is a dual-core AMD A6-9200 with 4 GB and a 5400 rpm disk. The
older entry described a machine that does not exist, which is worth stating
plainly because it was load-bearing in planning.

## Management

| Host | BMC | Address | Notes |
| --- | --- | --- | --- |
| `Saruman` | `shiva` — HPE iLO 4, firmware 2.82 | `10.0.30.10` | iLO Advanced licensed. Dedicated network port. DHCP with a reservation |

The BMC and the host it manages carry different names and different addresses:
`shiva` is the iLO, `Saruman` is the hypervisor at `10.0.30.110`. Earlier
revisions of this repository treated `shiva` as the hypervisor itself.

## Accessories

- 1U rackmount tray for the ProDesk Mini[^ProDeskRackmount]
- Sliding rails for the ProLiant[^Sliderail]
- 1U universal rack mount for the APC[^Rail]
- APCRBC115 replacement battery cartridge for the APC, fitted 2026-08-28,
  proven by a passing self-test the same day and under a biweekly schedule on
  the card ([#93](https://github.com/Gerrrt/HomeLab/issues/93)). The card's
  `upsBasicBatteryLastReplaceDate` still reads `08/15/2026` and wants resetting
  to the fit date — it is the only record of the pack's age
- 1U vented rack shelf, 4-post with square-hole mounting — on hand, for U4 and
  the unmanaged switch that feeds `prometheus` and `oracle`. It is not in the
  rack table above because it is not yet in the rack
  ([#110](https://github.com/Gerrrt/HomeLab/issues/110))
- USB stick holding the pfSense installer — **in transit; it belongs in the rack
  beside the KVM once it arrives**, and is not there yet.
  [`restore-the-firewall.md`](runbooks/restore-the-firewall.md) lists it as
  something you will need, so a restore attempted before it lands is a restore
  that stops to go looking for one
- HP Smart Storage Battery 96W (`727258-B21`, spare part `815983-001`) in the
  ProLiant, fitted 2026-09-02 to replace the pack that had failed. The Smart
  Array re-enabled its write cache on the first scrape after the fit; the
  cache ratio it reports is still open
  ([#76](https://github.com/Gerrrt/HomeLab/issues/76))
- ViewSonic N1700W LCD, used as a rack console via the KVM
- RJ45 Cat6 in-line couplers[^Couplers]
- Cat6 patch cables[^Patchcables]

[^UPS]: [APC Smart-UPS](https://www.apc.com/us/en/product-range/61913-smart-ups/)
[^Shiva]: [HPE ProLiant DL360 Gen9](https://buy.hpe.com/us/en/servers/rack-servers/proliant-dl300-servers/proliant-dl360-server/p/1010026922)
[^ProDesk]: [HP ProDesk 600 G4 Mini](https://www.microcenter.com/product/692358/)
[^KVM]: [MT-VIKI 8-port rackmount KVM](https://a.co/d/2yQl4KH)
[^Panel]: [Jadol 24-port patch panel](https://a.co/d/izggRoK)
[^PDU]: [10-outlet 1U PDU](https://a.co/d/ibEygxZ)
[^MokerLink]: [MokerLink 26-port managed switch](https://a.co/d/gaJvCKV)
[^ProDeskRackmount]: [1U rackmount for ProDesk Mini](https://a.co/d/4d7klOL)
[^Sliderail]: [Sliding rails for ProLiant](https://a.co/d/5d4A4FO)
[^Rail]: [1U universal rack mount](https://a.co/d/6R0vjHz)
[^Couplers]: [Cat6 in-line couplers](https://a.co/d/gP3b948)
[^Patchcables]: [Cat6 patch cables](https://vetco.net/collections/cables-cat6-patch-cables)
