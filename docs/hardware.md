# Hardware

A 9U open-frame rack, a firewall built from a refurbished mini PC, a
decommissioned enterprise server, and two laptops that were headed for a
landfill.

## Rack

| U | Device | Role |
| --- | --- | --- |
| U1–U2 | APC Smart-UPS[^UPS] | Power |
| U3 | HPE ProLiant DL360 Gen9[^Shiva] | Proxmox hypervisor (`Saruman`, BMC `shiva`) |
| U4 | 1U vented shelf, carrying the 8-port unmanaged TP-Link switch[^tp-linkswitch] | Feeds `prometheus` and `oracle`; on UPS power since 2026-09-08 |
| U5 | HP ProDesk 600 G4 Mini[^ProDesk] | pfSense firewall (`morpheus`) |
| U6 | MT-VIKI 8-port KVM[^KVM] | Console access |
| U7 | 10-outlet PDU[^PDU] | Power distribution |
| U8 | Jadol 24-port patch panel[^Panel] | Cabling |
| U9 | MokerLink 26-port managed switch[^MokerLink] | Core switching (`neo`) |

Off-rack: two Ubuntu Server laptops on a shelf (`prometheus`, `oracle`), fed
by the TP-Link in U4, and eero Pro 6E units distributed through the house.
Both laptops ride a mains cut out on their own cells, so each cell is a
dependency of the mains-cut path and is watched as one: Alloy's node collector
exports `node_power_supply_*` from both, and `host.rules.yaml` alerts when the
shelf is off mains, when a cell falls below 80 % of its design capacity, and
when a laptop reports no cell at all
([#454](https://github.com/Gerrrt/HomeLab/issues/454)).

The patch panel and the PDU were listed the other way round here until
2026-08-29. U8 is the panel and U7 is the PDU, confirmed against the rack.
Nothing in this repository depended on the order, but the wiki's rack page had
it right and this table did not, so the correction is recorded rather than
quietly swapped.

## Compute

| Host | Hardware | CPU | RAM | Storage | OS |
| --- | --- | --- | --- | --- | --- |
| `morpheus` | HP ProDesk 600 G4 Mini | i5-8500T | 32 GB | 1 TB NVMe SSD | FreeBSD 16.0 (pfSense) |
| `Saruman` | HPE ProLiant DL360 Gen9 | 2× Xeon E5-2680 v3 (48 threads) | 128 GB | 2× 1 TB SAS HDD, RAID 1 | Proxmox VE 9 |
| `prometheus` | Apple MacBook Pro (2012, Retina 13") | i5/i7 | 8 GB | 256 GB SSD | Ubuntu Server 24.04 LTS |
| `oracle` | Dell Inspiron 15-3565 | AMD A6-9200 (2 cores) | 4 GB | 500 GB HDD | Ubuntu Server 24.04 LTS |

The observability stack runs on a thirteen-year-old MacBook. It handles four
SNMP devices at a 60-second interval, four Alloy agents, and 30 days of metric
retention without complaint — which is a useful thing to know before spending
money on a monitoring host. Its RAM is soldered at 8 GB and it has no built-in
Ethernet, so it reaches the network over a USB NIC.

`morpheus` has two wired interfaces, and the second is not part of the model:
the onboard Intel I219-LM (`em0`, the WAN) and an Intel I226-V 2.5 GbE card on
an M.2 B+M-key adapter[^I226] in the G4's second M.2 slot (`igc0`, the
switch-management LAN and every VLAN). The card is what a restore onto other
hardware depends on —
[`restore-the-firewall.md`](runbooks/restore-the-firewall.md) §3 — and it was
recorded as a USB NIC in four documents until 2026-09-09, when the box was
read directly: `pciconf` shows it on a PCIe root port, and the only USB device
is the Wi-Fi module's Bluetooth half. The table records the release line
only, as [`check_docs.py`](../scripts/check_docs.py) requires, and unlike the
Linux hosts nothing collects the running release from pfSense — so it is
written here with its date: **pfSense CE 2.9.0-RELEASE**, build
`20260817-1836`, from `/etc/version` on 2026-09-09. Restoring the config
needs a release at least that new
([`restore-the-firewall.md`](runbooks/restore-the-firewall.md) §3).

`oracle` was previously recorded here as an i5-1235U with 32 GB and a 2 TB SSD.
It is not: it is a dual-core AMD A6-9200 with 4 GB and a 5400 rpm disk. The
older entry described a machine that does not exist, which is worth stating
plainly because it was load-bearing in planning.

The OS column names the release line and not the point release. Both laptops
were recorded here as 24.04.3 while both were running 24.04.4, and
`check_docs.py` could not see it — it compares this table against
[`network.md`](network.md), and the two copies were stale together. A point
release changes when a host takes an update, which is not an edit to this
repository, so it is the wrong kind of fact to write down at all: the running
version is already collected on every Linux host as
`node_os_info{pretty_name="Ubuntu 24.04.4 LTS"}`. The check now rejects a third
version component in either table.

## Management

| Host | BMC | Address | Notes |
| --- | --- | --- | --- |
| `Saruman` | `shiva` — HPE iLO 4, firmware 2.82 | `10.0.30.10` | iLO Advanced licensed. Dedicated network port. DHCP with a reservation. Hardened 2026-09-09 per [ADR-0033](adr/0033-keep-the-ilo-on-the-lab-segment.md): IPMI-over-LAN, SSH and iLO Federation off; HTTPS, the remote console and SNMP stay on; the account's credential is shared with nothing else; the security log was read for a baseline |

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
- 1U vented rack shelf, 4-post with square-hole mounting — in U4 since
  2026-09-08, carrying the unmanaged switch that feeds `prometheus` and
  `oracle` ([#110](https://github.com/Gerrrt/HomeLab/issues/110))
- HP ProDesk 600 G4 Micro — i5-8500T, 32 GB, 512 GB SSD, the same model as
  `morpheus` — ordered 2026-09-08, in transit. This is `trinity`, and it is
  **one box with two jobs, not two boxes**: the sensitive tier's host, and
  the firewall's spare hardware in a disaster
  ([ADR-0034](adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)).
  The documents call it "the tier's host" in one place and "the spare" in
  another, which is how it came to be read as two machines ([ADR-0038](adr/0038-name-the-nas-smaug-and-reserve-zion-for-the-box-that-does-not-exist.md));
  a second ProDesk is deferred, not ordered.
  It enters the Compute table when
  [#404](https://github.com/Gerrrt/HomeLab/issues/404) builds it, after the
  firewall restore has been rehearsed on it. It ships with the onboard NIC
  only; the I226 card the restore depends on was a separate purchase, made
  2026-09-11 and the entry below.
- Intel I226-V 2.5 GbE card on an M.2 B+M-key adapter — bought 2026-09-11,
  in transit. The second port on the ProDesk Micro above, matching the card
  in `morpheus` so a pfSense restore onto the spare brings the LAN up as
  `igc0` and asks nothing
  ([`restore-the-firewall.md`](runbooks/restore-the-firewall.md),
  [#404](https://github.com/Gerrrt/HomeLab/issues/404)). It is the one
  entry on that runbook's prerequisite list that was still unbought, and it
  is deliberately not a USB NIC: a USB
  adapter comes up as `ure0`, which is the one thing a restore must not be
  asked about. It goes in the G4 Micro's second M.2 slot — **and if that
  machine's 512 GB SSD turns out to be a 2.5" drive rather than M.2, the
  drive carrier and this card contend for the same space.** Checked on
  arrival, not assumed. Part number and the port's MAC go here when it lands.
- 2 TB USB portable hard drive — on hand, previously a games console's
  storage. Becomes the photo library's disk on `trinity`
  ([#404](https://github.com/Gerrrt/HomeLab/issues/404)): Immich's originals
  on it, its database on the internal SSD, after a wipe and an `ext4` format.
  One consumer spinning disk with no mirror, so the off-estate copy
  [ADR-0023](adr/0023-keep-the-household-recovery-path-outside-the-estate.md)
  requires is what protects it — the same as would have been true of a bought
  drive, which this replaces.
- Lenovo ThinkServer TS150 — Xeon E3-1225 v6 (4 cores, 3.3 GHz, Intel HD P630
  with Quick Sync), 8 GB ECC, four 3.5" bays, no drives, no OS — bought
  2026-09-09, in transit. The NAS `smaug` of
  [ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md),
  tracked under [#413](https://github.com/Gerrrt/HomeLab/issues/413). A tower,
  not a rack unit, and a 73 W part where the ADRs pictured an N100; it enters
  the Compute table when it is racked — or rather placed — addressed and in
  `network.md`. The two drives for the mirror were bought 2026-09-11 and are
  the entry below, as are the boot disk ADR-0016's Ubuntu Server install
  wants and the bracket that carries it in the optical bay. Nothing for this
  machine is outstanding on the roadmap's
  [list](roadmap.md#everything-still-to-buy) any more; what is left is a
  build.
- 2× Seagate Exos X20 18 TB (`ST18000NM003D`), 3.5" SATA — bought
  2026-09-11, in transit. `smaug`'s ZFS mirror
  ([ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md),
  [#413](https://github.com/Gerrrt/HomeLab/issues/413)). A mirror of two is
  one drive's capacity, so this is 18 TB usable, not 36. The listing's
  **zero power-on hours is a claim, not a fact** — read it back with
  `smartctl -a` on arrival and record what the drives actually report here,
  before the mirror is built on them. Serials go here when they land. They
  enter the Compute table with the NAS, which is not built.
- Intel DC S3520 240 GB, 2.5" SATA 6 Gb/s enterprise SSD with power-loss
  protection — bought 2026-09-11, in transit. `smaug`'s boot disk, carrying
  ADR-0016's Ubuntu Server and its one compose stack, deliberately not the
  mirror. A data-centre part where the roadmap asked only for "a 240–256 GB
  2.5" SATA SSD": the endurance is beside the point for a boot disk, but
  the power-loss protection is the same property the SM863a pair was bought
  for, and a boot disk that survives a power cut is worth more here than one
  that is merely fast. The TS150's optical bay is 5.25" and this is a 2.5"
  drive, so it cannot be fitted bare: **a bracket for the bay and
  double-sided tape to mount it were bought 2026-09-11**, alongside the drive.
  Neither is named here yet, for the same reason the drive's serial is not —
  nothing is recorded before it is in hand. Model, part number and serial go
  here when it lands, with SMART read back before the install.
- 2× Samsung SM863a 960 GB (`MZ-7KM960N`), 2.5" SATA 6 Gb/s enterprise
  SSDs with power-loss protection[^SM863a] — purchased 2026-09-09, in transit,
  for the ProLiant's SFF bays. Bought against the number every sizing
  decision on `Saruman` starts from: a 7.2K mirror serving about ninety
  random write IOPS
  ([ADR-0029](adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)).
  Serials go here when they land. The Compute table's Storage column changes
  when [#418](https://github.com/Gerrrt/HomeLab/issues/418) fits them, and
  not before — that issue also names the ADRs whose arithmetic the fit makes
  stale
- MikroTik CRS326-24G-2S+RM[^CRS326] — 24 × 1 GbE, 2 × SFP+, 1U, dual-boot
  RouterOS / SwOS — bought used 2026-09-13, in transit. The replacement for
  `neo` that
  [ADR-0018](adr/0018-name-the-switch-and-leave-its-ui-on-plain-http.md)
  asked for in its last consequence and
  [#444](https://github.com/Gerrrt/HomeLab/issues/444) decided. It is bought
  for **one property, a TLS management interface**: RouterOS serves its UI
  over `www-ssl` and imports a certificate, so the switch admin credential
  stops crossing the wire in clear through the device it protects.
  [#84](https://github.com/Gerrrt/HomeLab/issues/84)'s GETBULK residual rides
  along; SNMPv3 is not the argument, because
  [ADR-0036](adr/0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md)
  found the switch in the rack already answers v3 on the wire. It enters the
  Rack table at U9 and [`network.md`](network.md) when it is racked — `neo`
  carries every VLAN, so the swap is a house-wide outage and shares a rack
  visit rather than getting its own — and until then `neo` is the switch in
  every document and every target. **Checked on arrival, not assumed:** which
  OS it boots and the version on it (`/system resource`), the serial and the
  management MAC, that the rack ears and the power supply are in the box, and
  a netinstall or factory reset before it touches the network — a used
  RouterOS device arrives with whatever its last owner left on it, users
  included. Those go here when it lands.
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
[^SM863a]: [Samsung SM863a 960 GB, MZ-7KM960N](https://www.ebay.com/itm/800210578217)
[^KVM]: [MT-VIKI 8-port rackmount KVM](https://a.co/d/2yQl4KH)
[^Panel]: [Jadol 24-port patch panel](https://a.co/d/izggRoK)
[^PDU]: [10-outlet 1U PDU](https://a.co/d/ibEygxZ)
[^tp-linkswitch]: [TP-Link 8-port gigabit switch](https://www.tp-link.com/us/business-networking/unmanaged-switch/)
[^MokerLink]: [MokerLink 26-port managed switch](https://a.co/d/gaJvCKV)
[^CRS326]: [MikroTik CRS326-24G-2S+RM](https://www.ebay.com/itm/257688846446)
[^ProDeskRackmount]: [1U rackmount for ProDesk Mini](https://a.co/d/4d7klOL)
[^I226]: [Intel I226 2.5 GbE card on an M.2 B+M-key adapter](https://a.co/d/dJ4BD2N)
[^Sliderail]: [Sliding rails for ProLiant](https://a.co/d/5d4A4FO)
[^Rail]: [1U universal rack mount](https://a.co/d/6R0vjHz)
[^Couplers]: [Cat6 in-line couplers](https://a.co/d/gP3b948)
[^Patchcables]: [Cat6 patch cables](https://vetco.net/collections/cables-cat6-patch-cables)
