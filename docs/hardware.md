# Hardware

A 9U open-frame rack, a firewall built from a refurbished mini PC, a
decommissioned enterprise server, and two laptops that were headed for a
landfill.

## Rack

| U | Device | Role | Powered by |
| --- | --- | --- | --- |
| U1–U2 | APC Smart-UPS X 1500[^UPS] (`mjolnir`) | Power | The wall |
| U3 | HPE ProLiant DL360 Gen9[^Shiva] | Proxmox hypervisor (`Saruman`, BMC `shiva`) | The PDU |
| U4 | 1U vented shelf, carrying the 8-port unmanaged TP-Link switch[^tp-linkswitch] | Feeds `prometheus` and `oracle` | A UPS outlet, since 2026-09-08 |
| U5 | HP ProDesk 600 G4 Mini[^ProDesk] | pfSense firewall (`morpheus`) | The PDU |
| U6 | MT-VIKI 8-port KVM[^KVM] | Console access | The PDU |
| U7 | 10-outlet PDU[^PDU] | Power distribution | The UPS |
| U8 | Jadol 24-port patch panel[^Panel] | Cabling | — |
| U9 | MokerLink 26-port managed switch[^MokerLink] | Core switching (`neo`) | The PDU |

The *Powered by* column was added on 2026-09-20 and read at the rack that day
([#574](https://github.com/Gerrrt/HomeLab/issues/574)): everything on the PDU
is on the UPS, so a mains cut longer than the pack stops all of it at once,
and until that day nothing in this repository said which hosts that was. The
UPS's model is read off the card as `upsIdentModel` and was in no document
before then either. Who acts on the pack running out — and who does not — is
[ADR-0049](adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md),
and the runtime the pack actually gives at this load is **not measured**: the
card claimed 47 minutes at 21 % load on 2026-09-20, and the one mains pull
that turns that estimate into a number is
[`shut-down-on-the-ups.md`](runbooks/shut-down-on-the-ups.md) §6.

Off-rack: two Ubuntu Server laptops on a shelf (`prometheus`, `oracle`), fed
by the TP-Link in U4; the NAS `smaug`, a tower in the media room **powered
from the rack's PDU by a long cord**, so on the UPS like everything else on
that strip and a subscriber under ADR-0049; and eero Pro 6E units distributed
through the house.
Both laptops ride a mains cut out on their own cells, so each cell is a
dependency of the mains-cut path and is watched as one: Alloy's node collector
exports `node_power_supply_*` from both, and `host.rules.yaml` alerts when the
shelf is off mains, when a cell falls below 80 % of its design capacity, when a
laptop reports no cell at all
([#454](https://github.com/Gerrrt/HomeLab/issues/454)), when a cell reads above
45 °C, and when a host on its cell has under thirty minutes left
([#532](https://github.com/Gerrrt/HomeLab/issues/532)). `prometheus`'s cell was
replaced on 2026-09-18 and reads 101 % of its design capacity at one cycle;
`oracle`'s is the original, reads 72 %, and its replacement — a Dell M5Y1K —
was bought on 2026-09-19 and is in transit
([#531](https://github.com/Gerrrt/HomeLab/issues/531)). `prometheus`'s runtime
was measured on 2026-09-19: 2.72 Ah/h at the stack's load, about 2.5 hours
from a full pack, one measurement on one day. `oracle`'s has never been
measured. Neither pack reports a moving cell temperature — the Dell exports
none, and the A1437 fitted to `prometheus` returns a constant — so the
temperature alert is blind until a pack that measures is fitted, and
`HostBatteryTempNotMeasured` says so.

The patch panel and the PDU were listed the other way round here until
2026-08-29. U8 is the panel and U7 is the PDU, confirmed against the rack.
Nothing in this repository depended on the order, but the wiki's rack page had
it right and this table did not, so the correction is recorded rather than
quietly swapped.

## Compute

| Host | Hardware | CPU | RAM | Storage | OS |
| --- | --- | --- | --- | --- | --- |
| `morpheus` | HP ProDesk 600 G4 Mini | i5-8500T | 32 GB | 1 TB NVMe SSD | FreeBSD 16.0 (pfSense) |
| `Saruman` | HPE ProLiant DL360 Gen9 | 2× Xeon E5-2680 v3 (48 threads) | 128 GB | 2× 1 TB SATA HDD, RAID 1 (`pve`); 2× 960 GB SATA SSD, RAID 1, LVM-thin `large_data` | Proxmox VE 9 |
| `prometheus` | Apple MacBook Pro (2012, Retina 13") | i5/i7 | 8 GB | 256 GB SSD | Ubuntu Server 24.04 LTS |
| `oracle` | Dell Inspiron 15-3565 | AMD A6-9200 (2 cores) | 4 GB | 500 GB HDD | Ubuntu Server 24.04 LTS |
| `smaug` | Lenovo ThinkServer TS150 | Xeon E3-1225 v6 (4 cores) | 8 GB ECC | 240 GB SATA SSD (boot) + 2× 18 TB ZFS mirror `erebor` | TrueNAS 25.10 |

The observability stack runs on a thirteen-year-old MacBook. It handles four
SNMP devices at a 60-second interval, five Alloy agents, and 30 days of metric
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
| `Saruman` | `shiva` — HPE iLO 4, firmware 2.82 | `10.0.30.10` | iLO Advanced licensed. Dedicated network port. DHCP with a reservation. Hardened 2026-09-09 per [ADR-0033](adr/0033-keep-the-ilo-on-the-lab-segment.md): IPMI-over-LAN, SSH and iLO Federation off; HTTPS, the remote console and SNMP stay on; the account's credential is shared with nothing else; the security log was read for a baseline. Polled over SNMPv3 authPriv (SHA, AES, user `prometheus`) since 2026-09-20 per [ADR-0036](adr/0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md), with *SNMPv1 Request* off — it answers no community at all |

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
- HP ProDesk 600 G4 Micro[^Trinity] — i5-8500T, 32 GB, 512 GB SSD, the same
  model as `morpheus` — ordered 2026-09-08, **in hand since 2026-09-14** and
  opened on 2026-09-15. This is `trinity`, and it is **one box with two jobs,
  not two boxes**: the sensitive tier's host, and
  the firewall's spare hardware in a disaster
  ([ADR-0034](adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)).
  The documents call it "the tier's host" in one place and "the spare" in
  another, which is how it came to be read as two machines ([ADR-0038](adr/0038-name-the-nas-smaug-and-reserve-zion-for-the-box-that-does-not-exist.md));
  a second ProDesk is deferred, not ordered.
  This entry read "in hand since 2026-09-15" until 2026-09-17. The carrier's
  notice puts the drop-off at 15:05 local on the 14th; the commit that recorded
  it was written that evening and dated by UTC, which had already turned over.
  The opening date is a separate reading and stands.
  It enters the Compute table when
  [#404](https://github.com/Gerrrt/HomeLab/issues/404) builds it, after the
  firewall restore has been rehearsed on it. It ships with the onboard NIC
  only; the I226 card the restore depends on was a separate purchase, made
  2026-09-11 and the entry below — which has **not** landed. So what the
  rehearsal waits on is no longer this box: it is that card and the installer
  stick. **The 512 GB SSD is M.2, and the second M.2 slot is free** — read off
  the machine on 2026-09-15, and the answer the entry below was waiting for.
  There is no drive carrier and nothing contends: the I226 card has a slot to
  land in when it arrives, and the contingency the documents carried since
  2026-09-11 does not fire.
  **It arrived carrying Windows 11 Pro**, sold refurbished with a licence. The
  rehearsal's first act is to wipe it, so that licence is spent rather than
  banked: it is OEM, it dies with the install it shipped on, and **it does not
  move the buy table's two Windows 11 Pro keys**
  ([`roadmap.md`](roadmap.md#everything-still-to-buy)). Those are for the lab
  domain's two endpoints ([ADR-0029](adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md),
  [#414](https://github.com/Gerrrt/HomeLab/issues/414)) — a different machine
  and a different decision.
  **The warranty runs to 2027-09-08** — one year from purchase, through
  SquareTrade, applied automatically because it was sold as eBay Refurbished.
  It is worth recording because
  [ADR-0034](adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)
  accepts that the tier is down until a replacement arrives: inside that year a
  dead `trinity` has a claim behind it, and after it the ADR's cost is the
  whole cost.
  **The seller-return window closes 2026-10-08**, thirty days from purchase.
  That is a deadline on the list below rather than a fact about the machine.
  Still the listing's claims rather than the machine's, and still to be read:
  the i5-8500T, the 32 GB and the 512 GB above, the serial and the product
  number off the case, and that it really does have the onboard NIC alone —
  **read them before that date**. Installing pfSense over the Windows partition
  is what ends the return and is the one step of the rehearsal that cannot be
  taken back, so the machine has to be proved while sending it back is still an
  option. That is sooner than the card arrives, and it does not wait on it.
- Intel I226-V 2.5 GbE card on an M.2 B+M-key adapter — bought 2026-09-11,
  in transit. The second port on the ProDesk Micro above, matching the card
  in `morpheus` so a pfSense restore onto the spare brings the LAN up as
  `igc0` and asks nothing
  ([`restore-the-firewall.md`](runbooks/restore-the-firewall.md),
  [#404](https://github.com/Gerrrt/HomeLab/issues/404)). It is the one
  entry on that runbook's prerequisite list that was still unbought, and it
  is deliberately not a USB NIC: a USB
  adapter comes up as `ure0`, which is the one thing a restore must not be
  asked about. It goes in the G4 Micro's second M.2 slot, **and that slot is
  free**: the box was opened on 2026-09-15 and its 512 GB SSD is M.2, so there
  is no 2.5" drive carrier to contend with. This entry carried the opposite
  contingency from 2026-09-11 until then — that a carrier and this card would
  want the same space, and that one of them would have to go. It was a real
  risk and it did not happen; recorded as answered rather than deleted,
  because the reason the card was bought before the box was opened is the
  part worth remembering. Part number and the port's MAC go here when it
  lands, as does confirmation that the free slot takes a B+M-key 2280 card —
  `morpheus` is the same model and does exactly this, which is why the same
  model was bought.
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
  2026-09-09, **in hand since 2026-09-15**. The NAS `smaug` of
  [ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md),
  tracked under [#413](https://github.com/Gerrrt/HomeLab/issues/413). A tower,
  not a rack unit, and a 73 W part where the ADRs pictured an N100. **It entered
  the Compute table on 2026-09-16**, which is the trigger this entry set for
  itself — placed, addressed at `10.0.40.30`, and in `network.md`. **It is
  powered from the rack's PDU by a long cord to the media room**, read at the
  rack on 2026-09-20 — the one sentence
  [#413](https://github.com/Gerrrt/HomeLab/issues/413) owed this entry, and
  the fact [#574](https://github.com/Gerrrt/HomeLab/issues/574) could not
  find: the box is on the UPS, so a cut longer than the pack is a deferred
  unclean stop for the mirror rather than an immediate one, and
  [ADR-0049](adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md)
  makes it a subscriber that halts on the signal instead. The Storage
  column reads the boot disk alone on purpose: the ZFS mirror does not exist
  until the two Exos drives land, and a Storage column describing a pool nobody
  has created would be the kind of claim this table exists to not make. The boot disk the TrueNAS install wants
  ([ADR-0040](adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md))
  and the bracket that carries it in the optical bay are the entries below and
  landed with it; the two drives for the mirror, bought 2026-09-11, landed on
  2026-09-18 and were in the bays that evening. The Storage column reads the
  mirror since 2026-09-19. **Nothing for this machine was outstanding on the
  roadmap's [list](roadmap.md#everything-still-to-buy) from 2026-09-18 until
  2026-09-21, when memory re-entered it**
  ([#599](https://github.com/Gerrrt/HomeLab/issues/599)) — the pool and the
  transcoder both landed after the box was specced, and neither was weighed
  against the one DIMM below when it was.
  **Read off the machine on 2026-09-15**, where everything above it came off a
  listing: `ThinkServer TS150`, machine type-model `70UB000AUX`, serial
  `MJ05N4NK`. Xeon E3-1225 v6 at 3.30 GHz, four cores, and `Active Video: IGD`
  — so the P630 this box was chosen for is live, which is the hardware half of
  [ADR-0040](adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)'s
  reopen condition and not the whole of it; **whether Quick Sync reaches a
  container was tested on 2026-09-19 and it does** — a hardware decode,
  scale and `h264_qsv` encode inside the Jellyfin container, per
  [`build-the-nas.md`](runbooks/build-the-nas.md) §6.1. 8192 MB at 2133 MHz, which is **one** Samsung
  `M391A1G43EB1-CPBQ` — 8 GB 2Rx8 PC4-2133P, ECC unbuffered, date code 1728 —
  in one of four slots. More memory is therefore an add and not a replace, and
  the part to match is ECC **unbuffered**: a registered DIMM will not run on
  this board. **The label was photographed on 2026-09-21 and reads
  `PC4-2133P-EE1-11`**, which is the same constraint in the form a listing
  photograph can be checked against: in the JEDEC module marking the two
  letters after the speed grade are the module type, and `EE` is ECC
  unbuffered. `RA` or `RB` is registered and will not POST here, `LD` is
  load-reduced and will not either, and `UA` or `UB` is unbuffered without
  ECC — which this board does accept, and which
  [ADR-0040](adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)
  rules out anyway, ECC being ZFS's home ground. Read those two letters rather
  than the vendor part number: most DDR4 sold as server memory is `RA`. The
  same label confirms every field this entry already carried, which is why it
  is recorded as a check rather than a correction. The board takes four DDR4 UDIMMs at 2133 or 2400 to a maximum of
  64 GB, so 8 GB is an eighth of what it holds and three slots are empty.
  [#599](https://github.com/Gerrrt/HomeLab/issues/599) takes it to 32 GB, and
  **it does so by filling the board rather than by halves**: three more of the
  same 8 GB part, bought 2026-09-22, in the entry below. The roadmap row that
  left the buy list that day had said 32 GB *with two slots still free*, which
  would have meant two 16 GB modules; new ECC unbuffered 16 GB ran $134 to
  $140 each against $44 for this part, and the 2133 stick already fitted sets
  the clock for whatever joins it either way. **The cost of that choice is
  named rather than discovered later**: at four slots occupied, 64 GB is a
  replacement of all four modules and not an addition, so the board's ceiling
  is reachable only by discarding what is in it. 32 GB is the number ADR-0040's
  workload was sized against, and the second half of the ceiling was never
  costed. Onboard NIC `4c:cc:6a:xx:xx:xx`, recorded as an OUI like every
  other address here. BIOS **`S06KT81L` dated 2024-02-05**, boot block `1.81`, flashed
  2026-09-16 while the box was still empty. It shipped on `S06KT03R` dated
  2017-05-22 with boot block `1.03` — a firmware predating the Spectre and
  Meltdown microcode by a year — and the flash was done before the pool existed
  precisely so that a reset of `Configure SATA as` or of `CSM` would cost a
  re-check rather than an unbootable host with data on it. Both were re-checked
  and both survived, as did the machine type-model, the serial, the UUID, the
  MAC and the clock. **The embedded controller did not move**: it read
  `S06CT01A` before and reads `S06CT01A` after, and whether the package updates
  that component at all is unestablished — recorded as an observation rather
  than as a failure, because nothing misbehaves and the BIOS half plainly
  took.
  **Intel AMT was enabled and on its factory-default credential when this box
  arrived, and is now off.** Intel ME `v11.6.12.1204`, MEBx `v11.0.0.0012`: the
  MEBx accepted `admin` on 2026-09-16, which is Intel's default and means
  nobody had ever set one — the same class of thing the CRS326 entry below
  warns about, that a used device arrives carrying whatever its last owner left
  on it. `Manageability Feature Selection` read `Enabled`, `Password Policy`
  the stock `Anytime`, and the ME network name and domain were both **blank**,
  which is the evidence it had never been provisioned onto a network rather
  than a proof of it. Closed the same day, in the order the firmware requires:
  a new ME password (MEBx forces one at first login, and it lives in the
  operator's password manager), then `Unconfigure Network Access` →
  `Full Unprovision` while the feature was still enabled, then
  `Manageability Feature Selection` → `Disabled`. Verified by the `<CTRL-P>`
  prompt no longer being offered at boot.
  **Disabled rather than hardened, which is the opposite of what
  [ADR-0033](adr/0033-keep-the-ilo-on-the-lab-segment.md) decided for
  `shiva`**, and the difference is the host's job rather than a change of
  posture: `Saruman` is headless in a rack and a remote console is load-bearing
  there, so its iLO was kept and locked down. `smaug` is a tower with a monitor
  beside it, on the segment with the televisions and the consoles. Out-of-band
  management buys it nothing and would cost a management plane that answers
  when the operating system is off.
  Six SATA ports, all enabled, and two settings that were already right rather
  than needing changing: `Configure SATA as [AHCI]`, which is the raw-disk
  access ZFS wants and the thing
  [#418](https://github.com/Gerrrt/HomeLab/issues/418) is the cautionary tale
  for, and `CSM [Disabled]`, so it boots UEFI as TrueNAS wants.
  Two 3.5" trays, filled by the Exos pair on 2026-09-18 — exactly the mirror
  and no spare. **The trays are not on those six ports.** Read with `lspci`
  and `readlink` at the console on 2026-09-19, while triaging the faulted
  disk: both Exos enumerate under `host0` at PCI `01:00.0`, a **Broadcom /
  LSI MegaRAID SAS-3 3008 "Fury"**, PCI ID `1000:005f` — the SAS3008 in its
  MegaRAID personality, which is the ThinkServer RAID 520i option for this
  chassis, sitting in the PCIe slot and cabled to the bays. The chipset AHCI
  at `00:17.0` carries only the boot SSD on `ata6`; `ata1`–`ata5` read *SATA
  link down* at boot. So `Configure SATA as [AHCI]` protects the boot disk
  and nothing else, and the pool has had a RAID controller between ZFS and
  its disks since the day it was built — the arrangement the line above
  calls #418's cautionary tale. It is the MegaRAID firmware, not the
  chipset, that handled `sdb`'s failure with 60-second command timeouts,
  task aborts and a target reset. `smartctl` reaches the drives without a
  `-d megaraid` option and reports them by their own model and serial, which
  is what a JBOD pass-through looks like — and `dmesg` confirms it, read the
  same night: driver `megaraid_sas` 07.727.03.00-rc1, controller type
  **`iMR(0MB)`** — the cacheless entry-level MegaRAID, no write cache and
  no battery to worry about — subsystem `1000:9340`, which is the 9340-8i
  family the ThinkServer RAID 520i is built on, *Secure JBOD support: Yes*,
  and **`JBOD sequence map : enabled`**, which is the driver's way of
  saying the disks are JBOD devices rather than virtual drives. So ZFS sees
  the drives themselves through a RAID firmware's error handling, which is
  the better of the two arrangements a MegaRAID offers and still not an
  IT-mode HBA. The firmware version is not in `dmesg` and not in sysfs
  either — `/sys/class/scsi_host/host0/fw_ver` does not exist, read
  2026-09-19, and `megaraid_sas` exposes crash-dump and queue attributes
  there and nothing about its firmware. TrueNAS ships no `storcli`. So the
  version is read off the card's own boot-time utility. **Read 2026-09-22**
  at the power-on after the faulted disk came out, in the UEFI setup's
  *Advanced → AVAGO MegaRAID Configuration → Controller Management*: product
  **AVAGO MegaRAID SAS 9340-8i**, PCI ID `1000:005F:1000:9340`, package
  **24.16.0-0104**, firmware **4.660.01-8219**, NVDATA 3.1605.01-0008,
  two connectors, status *Optimal*, no BBU, zero virtual drives, and the
  one remaining Exos on drive port 0 as *JBOD*. That reading is what
  [#571](https://github.com/Gerrrt/HomeLab/issues/571) was owed. **The card
  is coming out, by decision, 2026-09-23**
  ([ADR-0052](adr/0052-cable-smaugs-pool-to-the-chipset-and-take-the-megaraid-out.md)):
  at the swap, the Exos pair moves to the chipset's free ports on two plain
  SATA cables, bought for it because the only tray cable is the card's own
  mini-SAS breakout. The card and the breakout go on the shelf as the
  fallback. Until the swap, everything in this paragraph describes the path
  as it still is. The driver
  logged a disable/enable of its interrupts at 21:03:51 on 2026-09-19, the
  same second as the target reset in the fault's `dmesg` — the controller
  resetting itself around a disk that had stopped answering, which is the
  Online Controller Reset it advertises as enabled. `1000:005f` is the ID to watch:
  `1000:0097` is the same silicon in IT mode, and the card was never
  recorded here, like the optical drive was not. Cabling below, in
  [`build-the-nas.md`](runbooks/build-the-nas.md) §1, says `SATA2` and
  `SATA3`; that is now known to be wrong, and the same reading corrects it.
  **The 5.25" bay was not empty**: a PLDS `DVD-RW DU8AESH` answered on SATA5.
  A photograph of the open case had been read here as an empty cage and was
  wrong; the BIOS summary is what caught it. The optical drive came out on
  2026-09-16 and the boot disk took its place, its port and both its cables.
  The bay is a cage carrying its own fan on the board's `AUX1_FAN` header, and
  that fan is **not optional**: it is the airflow over the drive bays, and two
  7200 rpm Exos under a scrub will want it. Reconnected after the swap and
  reading `Aux Fan: Operating`.
- 2× Seagate Exos X20 18 TB (`ST18000NM003D`, firmware `SN03`), 3.5" SATA[^Exos] —
  bought 2026-09-11, **in hand since 2026-09-18**, a day after the carrier's
  window lapsed. `smaug`'s ZFS mirror
  ([ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md),
  [#413](https://github.com/Gerrrt/HomeLab/issues/413)). A mirror of two is
  one drive's capacity, so this is 18 TB usable, not 36.
  **Read off both drives with `smartctl -a` at the console on 2026-09-18,
  before the pool existed**: serials `ZVTBS4NL` and `ZVTBSDL3`, both `PASSED`,
  both at **0 power-on hours**, 0 reallocated, 0 pending, 0 uncorrectable, no
  errors logged, 26 °C in the bays against a lifetime range of 24–26. **The
  zero hours is a fact, not a claim, and it was checked the one way that
  settles it.** SMART's hours counter can be reset, and used Exos drives with
  it zeroed were sold as new through 2025; Seagate's FARM log keeps a second
  counter that the reset does not touch, and `smartctl -l farm` on this host
  read **0 power-on hours and 0 spindle hours on both drives**. What the
  resettable counters add is consistent with new drives bench-checked by the
  seller and with nothing more: `ZVTBSDL3` arrived carrying a Windows quick
  format — a 16 MB Microsoft reserved partition and an NTFS volume labelled
  `New Volume` filling the rest — with 718,258 LBAs written, about 370 MB
  and the size of that format, three power cycles, and one short self-test
  logged at lifetime hour 0; `ZVTBS4NL` arrived blank, two power cycles,
  nothing written. Both spun up and enumerated on the first power-up. **The
  TS150's SATA power lead has four wires and no orange one**, read on
  2026-09-18, so this supply puts nothing on pin 3 and the Power Disable trap
  `build-the-nas.md` §1 records does not apply on this box — it would on a
  supply that does. They entered the Compute table with the pool.
  **Both extended self-tests completed without error.** Started 2026-09-18 at
  lifetime hour 0, under the pool creation and the first day of the stack, and
  read on 2026-09-20 with `smartctl -l selftest`: `ZVTBS4NL` (`sda`) logged
  the completion at lifetime hour 25 and `ZVTBSDL3` (`sdb`) at 26, no LBA of
  first error on either, and `sdb`'s log still carries the seller's short
  test at hour 0 above it. That was the last open line of
  [`build-the-nas.md`](runbooks/build-the-nas.md) §7, and
  [#413](https://github.com/Gerrrt/HomeLab/issues/413) closed on it.
  **`ZVTBSDL3` (`sdb`) FAULTED on 2026-09-19 at 20:55 PDT (03:55 UTC
  2026-09-20), at about lifetime hour 27** — one day after arrival and about
  an hour after the extended self-test above completed clean. TrueNAS
  raised *"Pool erebor state is ONLINE: One or more devices are faulted in
  response to persistent errors … Disk ST18000NM003D-3DL103 ZVTBSDL3 is
  FAULTED"*. node_exporter's `/metrics` had stopped answering at 20:46, nine
  minutes earlier, with the port still accepting connections, so
  `InstanceDown` was the page and `ZpoolNotOnline` — the rule this fault
  produced — never got a sample. `ZVTBS4NL` carries the pool alone until a
  replacement is fitted; the return runs under the eBay guarantee, thirty
  days from the 2026-09-18 delivery, to 2026-10-18. What `dmesg` and SMART
  said at the console, and the outcome, belong in
  [`replace-the-nas-disk.md`](runbooks/replace-the-nas-disk.md)'s status
  block and then here; [#558](https://github.com/Gerrrt/HomeLab/issues/558)
  carries it. **Read at the console on 2026-09-19 at 23:19 PDT, at lifetime
  hour 32: it is the drive.** `zpool status` counts 3 read and 99 write
  errors on the leaf; `dmesg` is *Logical unit not ready* and 60-second
  command timeouts from 20:47 on, with no link resets and no CRC errors;
  SMART reads **850 pending and 850 offline-uncorrectable sectors** against
  the 0 and 0 of the day before, `Command_Timeout` normalised to 1, overall
  health still `PASSED`; and FARM puts **all 850 reallocation candidates on
  head 5**, with 124 command timeouts and 179 hardware resets, both rails
  in spec, 28 °C. `ZVTBS4NL` is unaffected. The extended self-test that
  completed at hour 26 was true when it was read and is not evidence now.
  **The return was opened on 2026-09-20** under the eBay guarantee, as
  *defective*; the label is due by 2026-09-24, and the seller had not
  chosen refund or replacement when this was written — a replacement means
  no purchase, a refund means an 18 TB bought outright and a row in
  [`roadmap.md`](roadmap.md)'s buy list. **Seagate's warranty, read
  2026-09-22 with the tray out: none.** The label's QR code verifies as a
  genuine 18000 GB drive, so the "0HR" lot is not relabelled stock, and
  Seagate's lookup for `ZVTBSDL3` says *"Your product is not under
  warranty. Please contact the place of purchase."* The eBay return is the
  only remedy. `ZVTBS4NL` came from the same lot and was not looked up,
  because its tray stays in; assume it is the same until it is read.
  **Wiped and pulled 2026-09-22, runbook step 4.** Offlined in the UI;
  `shred -n 1` ran on `/dev/sdb`, confirmed `ZVTBSDL3` by `smartctl -i`, at
  about 215 MB/s, which is a day or more for 18 TB. It was stopped at
  **93 GiB** for time, so the fallback ran: `zpool labelclear -f` refused
  (*failed to clear label*, because shred had already overwritten the
  front), then a `dd` of zeros over the first and the last 1 GiB, both
  complete. `wipefs` then listed no signature and `sdb1` no longer
  existed. The labels and partition tables at both ends are gone; the data
  blocks between 93 GiB and the last GiB were not overwritten. The drive
  took every write it was given, so this was a choice made for time and
  not a refusal. Tray pulled by its label, and shipped on eBay's label
  on 2026-09-22. `erebor` reads `DEGRADED` on `ZVTBS4NL` alone,
  `0 0 0`, *No known data errors*. One correction from the
  same day: TrueNAS's alert did not stop at the web UI. TrueNAS Connect
  emailed it to the operator's mailbox 37 s after it fired, which is a
  mailbox rather than a page, and a cloud service this host initiates a
  connection to — [#483](https://github.com/Gerrrt/HomeLab/issues/483)'s
  subject.
- Intel DC S3520 240 GB, 2.5" SATA 6 Gb/s enterprise SSD with power-loss
  protection — bought 2026-09-11, **in hand since 2026-09-15**. `smaug`'s boot
  disk, carrying TrueNAS and the media stack it launches
  ([ADR-0040](adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md),
  superseding ADR-0016's Ubuntu Server), deliberately not the mirror — an
  arrangement TrueNAS wants anyway, since it keeps its boot device out of the
  pool entirely. A data-centre part where the roadmap asked only
  for "a 240–256 GB 2.5" SATA SSD": the endurance is beside the point for a
  boot disk, but
  the power-loss protection is the same property the SM863a pair was bought
  for, and a boot disk that survives a power cut is worth more here than one
  that is merely fast. The TS150's optical bay is 5.25" and this is a 2.5"
  drive, so it cannot be fitted bare: **a bracket for the bay and
  double-sided tape to mount it were bought 2026-09-11**, alongside the drive,
  and both landed with it on 2026-09-15. The bracket is a 5.25"-to-2.5" adapter
  and does fit both the drive and the bay — an assumption until it was fitted.
  It and the tape are still unnamed here, which is a naming this document owes
  rather than one it is waiting on.
  **Fitted 2026-09-16 and detected:** the BIOS summary reads
  `SATA Drive 5 Hard Disk INTEL SSDSC2BB240G7`, and the `G7` suffix is the
  S3520 generation — so the part is what the listing said, on the port the
  optical drive vacated, with both its cables inherited rather than found.
  Serial `PHDV706401TM240AGN`, firmware `N2010101`, on SATA 3.1 at 6.0 Gb/s.
  **`smartctl` read 2026-09-16, and it is a used drive with a history worth
  recording**: SMART self-assessment `PASSED`, `Media_Wearout_Indicator` **088**
  — Intel's own counter, which starts at 100 and falls, so roughly a tenth of
  the write endurance is spent and the rest is ample for a disk that will carry
  an operating system and no data. 13,182 power-on hours, about eighteen months
  running. Around 72 TiB written by its previous host. Zero pending sectors,
  zero reported-uncorrectable, zero CRC errors, zero end-to-end errors, and
  24 °C in the bay with the fan on.
  **509 unsafe shutdowns out of 538 power cycles**, which is the number that
  says what this drive did before: it was almost never shut down cleanly.
  **Re-read at the console on 2026-09-21: 519**, at 13,301 power-on hours —
  ten more in the five days since the install, on a host that has been up
  throughout, which is the counter
  [#574](https://github.com/Gerrrt/HomeLab/issues/574) wants watched and the
  reason ADR-0047's collector now reads it. Note that this drive reports it
  under **two** attributes, 174 and 192, both of which `smartctl` names
  `Unsafe_Shutdown_Count`; the collector renders one series and says why. It is
  also the argument above, tested. This part was chosen because *a boot disk
  that survives a power cut is worth more here than one that is merely fast*,
  and `Power_Loss_Cap_Test` still passes after 509 of them — the capacitor works
  and somebody else did the proving.
  **Four reallocated sectors, and that is a number to watch rather than to
  reject** — normalised 099 against a threshold of 000, with nothing pending
  and nothing uncorrectable behind it. It has a consequence that is better
  written down now than discovered later: `SmartDriveBadSectors` holds every
  drive to the reallocated count already recorded for it, and to zero when
  none is, because a remapped sector never un-remaps and the first one is the
  finding. **So this drive's four are recorded**, in
  `scripts/render-smart-baselines.sh` beside `oracle`'s 32 with the day they
  were read — the answer [#572](https://github.com/Gerrrt/HomeLab/issues/572)
  built in place of the silence #351 used, because a silence matches labels
  and no label carries the count, and a baseline lives in git and does not
  expire. `SmartDriveBadSectorsGrowing` carries the trend above it. The row
  is inert until [`build-the-nas.md`](runbooks/build-the-nas.md) §6.4 runs
  the collector on this host — a root cron job under the scrape, by
  [ADR-0047](adr/0047-collect-smaug-smart-through-a-root-cron-and-the-textfile-collector.md),
  which closed [#483](https://github.com/Gerrrt/HomeLab/issues/483) — and
  its device letter is confirmed that day from what the collector prints.
  Since that ADR the collector also reads this drive's wearout indicator, so
  `SmartDriveWearHigh` can see it, and its unsafe-shutdown counter, which is
  the number [#574](https://github.com/Gerrrt/HomeLab/issues/574) asked for
  and `SmartDriveUnsafeShutdownsGrowing` now reads
  ([ADR-0049](adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md)).
  `SmartDriveWearHigh` will not fire — it wants 80 % of rated life used and this
  is near a tenth. No self-tests had ever been logged in 13,182 hours, so a
  baseline was taken on 2026-09-16 before the machine carried anything:
  **extended offline, completed without error, at lifetime hour 13,183**. The
  drive took far longer than its own two-minute estimate because it advertises
  *Suspend Offline collection upon new command* and TrueNAS was live underneath
  it — worth knowing before reading a slow self-test as a sick disk. TrueNAS's
  scheduled tests take it from here; they run the tests, and ADR-0047
  publishes the attributes.
- 2× Samsung SM863a 960 GB (`MZ-7KM960N`), 2.5" SATA 6 Gb/s enterprise
  SSDs with power-loss protection[^SM863a] — purchased 2026-09-09, delivered
  2026-09-11, fitted 2026-09-18 in bays 3 and 4 of the ProLiant, and **since
  2026-09-19 the P440ar's logical drive 2: RAID 1, `915683` MB, carrying the
  LVM-thin pool `large_data`** (volume group, pool and Proxmox storage id are
  all that one word). Bought against the number every sizing decision on
  `Saruman` starts from: a 7.2K mirror serving about ninety random write IOPS
  ([ADR-0029](adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)).
  **Measured 2026-09-20** (fit runbook step 8: 4 KiB random write, queue
  depth 1, `direct=1`, an 8 GiB thin volume on each pool): the HDD mirror
  does **741 IOPS** idle and 734 with the guest live, 1.3 ms mean and 12.5 ms
  p99, against the derived 83 — the controller's battery-backed write cache,
  which `ssacli` reads as `10% Read / 90% Write` and the iLO reads as `0`, is
  absorbing writes; at queue depth 32 the mirror sustains 712. The SSD mirror
  does **7,952 IOPS** at queue depth 1, 102 µs mean and 198 µs p99, and
  51,600 at queue depth 32 — on SSD Smart Path, with no controller cache in
  the path. Serial `S3F3NX0K601487` in Bay 3 and `S3F3NX0K806107` in Bay 4, firmware
  `GXM5304Q`, both negotiated at 6 Gb/s — **as the iLO reports them over
  SNMP, not as read off the labels.** The fit runbook asked for the labels
  first, because reading a serial back through the controller means reading
  it through the tool the fit is trying to verify; that was not done while
  the drives were unassigned, and the window closed when they joined an
  array. The iLO gives the model only as `SAMSUNG` — it names a third-party
  SATA drive by vendor where it gives the HPE disks their part number — so
  the part is proved by the size (`915715` MB), the firmware and the serial
  prefix rather than by the model string. Both read solid-state, SMART `ok`
  and `notConfigured` from the first scrape they appeared in, at 20:11 UTC on
  2026-09-18, and `configured` from 13:40 UTC the next day, the scrape the
  logical drive first appeared in — created through the offline Smart Storage
  Administrator, not `ssacli`, which reached the host that evening from HPE's
  `trixie` suite and read the controller for the first time. The array read
  `ok` from its first scrape and nothing alerted for it; what did alert was
  the fourteen-and-a-half-hour power-off the SSA session sat inside, which the
  runbook now records. **The iLO's wear columns stayed blank once the drives
  were configured** — wear status `other`, endurance and power-on hours
  unknown — which is the condition
  [#529](https://github.com/Gerrrt/HomeLab/issues/529) was filed against, so
  wear on these two drives is [#529](https://github.com/Gerrrt/HomeLab/issues/529)'s
  to read through `hpsa`, and `ssacli` agrees: both report `SSD Smart Trip
  Wearout: Not Supported`. **`alexander` has lived on `large_data` since
  02:41 UTC on 2026-09-20** — a 100 GiB disk mirrored across online in
  7 min 28 s, `unused0` removed, `ssd=1` set, and rebooted so the guest sees
  a non-rotational disk. The cache reading
  [#76](https://github.com/Gerrrt/HomeLab/issues/76) waited on since
  2026-09-02 is taken and is the iLO's blind spot, not the controller's:
  the ratio is set and the cache is working. The numbers above are what
  [#527](https://github.com/Gerrrt/HomeLab/issues/527) closed on, and the
  ADRs whose arithmetic they replace carry dated notes rather than edits.
  The two spinners in bays 1 and 2 are **SATA**, not the SAS this table
  said until 2026-09-20 — `Interface Type: SATA`, `MM1000GBKAL`, read by
  `ssacli` — which changes no decision and one word. This entry is where the
  serials live, which is the question
  [#148](https://github.com/Gerrrt/HomeLab/issues/148) asked.
- 2× HP 2.5" SFF drive tray, `651687-001`[^Caddy] — bought 2026-09-11,
  **arrived and fitted 2026-09-18**, one under each SM863a in bays 3 and 4.
  The carriers the pair above needs to sit in `Saruman`'s SFF bays
  ([#418](https://github.com/Gerrrt/HomeLab/issues/418)). A Gen9 bay holds a
  drive only in a tray, so two drives want two trays, and two is what was
  bought — worth writing down, because one tray short is one SSD fitted and
  one on a shelf. The arrival checks this entry asked for are answered by the
  bays rather than by the packaging: both trays took a drive, and the iLO
  reads the same carrier firmware on all four bays
  (`cpqDaPhyDrvSmartCarrierAppFWRev` `11`, bootloader `6`), so they are the
  Gen8/Gen9 SmartDrive carrier and not the Gen10 part or the 3.5" LFF one.
  **This purchase went unrecorded for six days**, which is the omission this
  entry exists to close. It was made in the same sitting as the I226 card, the
  Exos pair, and the boot disk's bracket and tape, every one of which has had
  an entry here since the day it was bought. The roadmap's rule is that a
  purchase is written down when the money is spent, so a gap like this is the
  rule failing rather than a thing the rule allows. Found on 2026-09-17 while
  reading the ProDesk's arrival paperwork for
  [#92](https://github.com/Gerrrt/HomeLab/issues/92), which is not a way of
  finding purchases that can be relied on. `651687-001` is the listing's part
  number, not read off the tray.
- MikroTik CRS326-24G-2S+RM[^CRS326] — 24 × 1 GbE, 2 × SFP+, 1U, dual-boot
  RouterOS / SwOS — bought used 2026-09-13, **in hand since 2026-09-23**.
  The box held the switch and its rack ears and **no power adapter**. The rear
  panel has no AC inlet: the only power input is a barrel jack marked
  `DC 10–28V`, beside a ground screw, with a blank plate where other units
  carry an inlet. PoE-in on port 1 is the other input. MikroTik rates the
  unit at 24 W maximum. A MikroTik 24HPOW[^24HPOW] (24 V, 2.5 A, North
  American cord) was ordered 2026-09-23 and is in transit, and the bench
  steps wait for it
  ([#444](https://github.com/Gerrrt/HomeLab/issues/444)). **Not 48POW:** it
  is MikroTik's too, has the same plug, and puts 48 V into a jack labelled
  10–28 V. The replacement for
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
  found the switch in the rack already answers v3 on the wire. **How it is
  configured was decided before the window rather than during it** —
  [ADR-0041](adr/0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md)
  runs it on RouterOS, keeps the name `neo` and the address `10.7.7.2`, serves
  `www-ssl` from a leaf off the estate's CA with plain `www` off, and gives it
  an SNMPv3 authPriv user; the procedure is
  [`swap-the-switch.md`](runbooks/swap-the-switch.md). It enters the
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
- A1437 battery cell for `prometheus`[^A1437] — the pack that fits the
  `A1425`, the late-2012 Retina 13" in the Compute table — bought new
  2026-09-13, delivered 2026-09-18 and **fitted the same day.** A consumable and
  not an upgrade: it is the one
  exception the roadmap's *Never* line names, bought because the estate's
  mains-cut path rests on this cell and the failure mode of a
  thirteen-year-old lithium cell on a shelf is swelling
  ([#454](https://github.com/Gerrrt/HomeLab/issues/454)). The listing calls
  it genuine and its brand field says unbranded, so it is recorded as a
  compatible cell, not an Apple part. That wording was written to be settled
  once the part could be looked at, and the fit settled it sideways.
  `manufacturer` and `model_name` came back unchanged — `SMP`, `bq20z451` —
  because an aftermarket A1437 reuses the same gas gauge; but **both design
  figures moved**, `charge_full_design` 6.6 → 6.8 Ah and `voltage_min_design`
  11.21 → 11.4 V, which is a pack reporting its own numbers and is the only
  proof of a different part available on a machine that exports no serial. It
  stays recorded as a compatible cell. The new pack reads `charge_full`
  6.889 Ah of 6.8 Ah design (101 %) at `cyclecount` 1. The cell it replaced
  read 94 % of design capacity after 108 cycles, on 2026-09-12 and again on
  2026-09-17 — above `HostBatteryHealthLow`'s 80 %, so it was bought on age and
  not on the alert — and went for recycling on 2026-09-18. Nothing in the
  Compute table changes; a cell is not a spec.
  **Checked at the fit:** `charge_full` above `charge_full_design`,
  `cyclecount` 1, `charge_ampere` moving, and both design figures changed — all
  read from this host's own Prometheus on 2026-09-18. **Checked on
  2026-09-19, and the check that closed
  [#454](https://github.com/Gerrrt/HomeLab/issues/454):** the mains pull on the
  fully charged pack. The host stayed up for a bounded 22 minutes on the cell,
  `HostOnBattery` fired for it alone, and the draw measured 2.72 Ah/h — about
  2.5 hours from full at the load the stack presents, the first runtime figure
  the estate has had for either laptop, and one measurement on one day.
  ([`replace-the-laptop-cell.md`](runbooks/replace-the-laptop-cell.md) carries
  the baseline, the stack-down window — 14:53 to about 18:12 on the day, over
  its own two-hour bound — and the disposal.) `oracle`'s cell reads 72 % and is
  second in line, bought 2026-09-19 — the entry below.
- Dell M5Y1K 4-cell pack for `oracle`[^M5Y1K] — 14.8 V, 40 Wh, the latched
  pack the Inspiron 15-3565 in the Compute table takes. **Identified and
  bought 2026-09-19, in transit**, under
  [#531](https://github.com/Gerrrt/HomeLab/issues/531): the part was written
  down here before the money was spent, which is the order that issue asks
  for, and the purchase followed the same day. The listing calls it genuine
  Dell, which — as with the A1437 above — is the listing's claim until the
  pack is looked at; a Dell label and a `serial_number` that is not `1650`
  are what would settle it, and the fit records which it turned out to be.
  The listing quoted delivery in two to four days. The number comes off the
  machine rather than off the listing: `/sys/class/power_supply/BAT0` reports `model_name`
  `DELL VN3N047`, and `VN3N0` is one of the interchangeable Dell part numbers
  for this pack — `M5Y1K` is the primary, and `WKRJ2`, `HD4J0`, `991XP` and
  `GXVJ3` the others listings carry — with `manufacturer` `SMP-Sanyo2` and
  `serial_number` `1650`. The design figures agree with the part: 2.8 Ah at
  14.8 V is the 40 Wh on the label. It is the second laptop cell and the same
  consumable exception as the A1437 above, second in line because
  `prometheus` dying is the estate going blind and `oracle` dying is the wiki
  and the off-host jobs going quiet
  ([#454](https://github.com/Gerrrt/HomeLab/issues/454)). It measures worse
  than the cell that exception was written for: `charge_full` 2.021 Ah of
  2.8 Ah design, **72 %**, read 2026-09-12 and unchanged on 2026-09-19 — the
  same figure across the whole 30-day retention — below
  `HostBatteryHealthLow`'s 80 % line, and that alert has fired for it since
  2026-09-14 under a silence that expires 2026-10-08. **A bare battery, not a
  kit**: unlike the MacBook's glued cell this one sits behind a slide latch on
  the underside, so the swap is a latch and a lift with the machine off, and
  needs no solvent, no screws and no tools. The machine's coin cell is a
  separate CR2032 behind the keyboard and palmrest, which a latch swap never
  reaches — the reason its clock is expected to survive the disconnect that
  reset `prometheus`'s
  ([#519](https://github.com/Gerrrt/HomeLab/issues/519)), and a thing the fit
  checks rather than assumes. What proves the swap differs from the MacBook
  too: this pack's info series carries a `serial_number`, which the MacBook's
  does not, so a changed serial is the clean proof row; and its firmware
  reports `cyclecount` as `0` always and exports no `temp_celsius`, so two of
  the MacBook's rows are unavailable here.
  [`replace-the-laptop-cell.md`](runbooks/replace-the-laptop-cell.md) has the
  procedure and a section on what differs on this host. Nothing in the
  Compute table changes; a cell is not a spec.
- Three Samsung `M391A1G43EB1-CPB`[^Smaugmem] — 8 GB DDR4-2133 ECC UDIMM,
  PC4-17000P-E, dual rank x8 — **bought 2026-09-22, in transit**, under
  [#599](https://github.com/Gerrrt/HomeLab/issues/599). `smaug`'s memory, and
  the same part as the module the machine already carries: this is the
  matched-set answer to that issue rather than the two-16 GB one, for the
  reason the Compute entry above now records. $44 each, $132 the three, $15.30
  FedEx 2Day, **$147.30 all in**, from Memory.NET with a lifetime warranty on
  the modules. New, not pulled — the used market for this part sat between $19
  and $45 a stick with no warranty, so the premium here is small and buys the
  replacement path. **It takes the board to 32 GB across all four slots**, and
  what the arrival has to check is what no listing can answer: that three
  strangers and the incumbent train together at 2133 and that the board posts
  with every slot filled. Until then the Compute table reads 8 GB, because
  memory in a box in transit is not memory in the machine. Ordered the day
  after the label was photographed, which is what settled the part number —
  `PC4-2133P-EE1-11` off the installed module, `EE` being ECC unbuffered, and
  this listing naming `PC4-17000P-E` for the same thing.
- WD Elements Portable 5 TB, `WDBU6Y0050BBK-WESN`[^Elements] — 2.5" USB 3.2
  Gen 1, bus-powered, no power brick — **bought 2026-09-22**, under
  [#455](https://github.com/Gerrrt/HomeLab/issues/455). The drive
  [ADR-0023](adr/0023-keep-the-household-recovery-path-outside-the-estate.md)
  was waiting on: the off-estate copy of the household's photographs and
  documents, kept at another address. **Not the estate's backup sets** —
  those ride with the second age recipient
  ([ADR-0048](adr/0048-carry-the-estates-backup-sets-with-the-second-recipient.md),
  [`copy-the-backups-offsite.md`](runbooks/copy-the-backups-offsite.md)) and
  this drive is not that medium. 5 TB against a 2 TB source — Immich's
  originals on `trinity`'s USB disk, plus Paperless's documents — so the
  capacity question does not come back. **What it cost is not written down
  here**, which is this entry's one gap and the thing to close when the
  receipt is to hand; the roadmap's rule is that a purchase is recorded when
  the money is spent, and the date and the part are what that rule is for.
  **It has no vendor encryption and that is why it qualifies**: ADR-0023
  requires a key that is not the one only the operator holds, and a drive
  password is a single-holder secret behind a vendor utility, which is the
  failure that ADR exists to prevent moved one shelf further away. The
  encryption is the estate's own, over a filesystem the other person's machine
  can read — the pairing, and whose key it is, are
  [#455](https://github.com/Gerrrt/HomeLab/issues/455)'s two open conditions,
  neither of which a drive satisfies. Three things the fit checks rather than
  assumes: it ships formatted for Windows and wants reformatting for that
  pairing; its cable is USB 3.0 Micro-B at the drive end, so **the cable
  travels with the drive** or the drive is a brick at the other address; and a
  5 TB 2.5" drive of this class is shingled, which is fine for an archive
  written in one pass and not fine as a live target.
- ViewSonic N1700W LCD, used as a rack console via the KVM
- RJ45 Cat6 in-line couplers[^Couplers]
- Cat6 patch cables[^Patchcables]

[^UPS]: [APC Smart-UPS](https://www.apc.com/us/en/product-range/61913-smart-ups/)
[^Shiva]: [HPE ProLiant DL360 Gen9](https://buy.hpe.com/us/en/servers/rack-servers/proliant-dl300-servers/proliant-dl360-server/p/1010026922)
[^ProDesk]: [HP ProDesk 600 G4 Mini](https://www.microcenter.com/product/692358/)
[^Trinity]: [HP ProDesk 600 G4 Micro, the refurbished unit that is `trinity`](https://www.ebay.com/itm/237046034784)
[^Exos]: [Seagate Exos X20 18TB SATA 6Gb/s 7200RPM Enterprise HDD ST18000NM003D 0HR Drives](https://www.ebay.com/itm/237056026029)
[^SM863a]: [Samsung SM863a 960 GB, MZ-7KM960N](https://www.ebay.com/itm/800210578217)
[^Elements]: [WD 5TB Elements Portable External Hard Drive, WDBU6Y0050BBK-WESN](https://www.amazon.com/dp/B07X41PWTY)
[^Smaugmem]: [Samsung M391A1G43EB1-CPB, 8 GB DDR4-2133 ECC UDIMM PC4-17000P-E dual rank x8](https://memory.net/product/m391a1g43eb1-cpb-samsung-1x-8gb-ddr4-2133-udimm-pc4-17000p-e-dual-rank-x8-module/)
[^Caddy]: [HP 2.5" SFF drive tray, 651687-001, for DL360/DL380/ML350 Gen8 and Gen9](https://www.ebay.com/itm/126297185368)
[^KVM]: [MT-VIKI 8-port rackmount KVM](https://a.co/d/2yQl4KH)
[^Panel]: [Jadol 24-port patch panel](https://a.co/d/izggRoK)
[^PDU]: [10-outlet 1U PDU](https://a.co/d/ibEygxZ)
[^tp-linkswitch]: [TP-Link 8-port gigabit switch](https://www.tp-link.com/us/business-networking/unmanaged-switch/)
[^MokerLink]: [MokerLink 26-port managed switch](https://a.co/d/gaJvCKV)
[^CRS326]: [MikroTik CRS326-24G-2S+RM](https://www.ebay.com/itm/257688846446)
[^24HPOW]: [MikroTik 24HPOW, 24 V 2.5 A](https://mikrotik.com/product/24HPOW)
[^A1437]: [A1437 battery for the MacBook Pro 13" A1425 Retina](https://www.ebay.com/itm/356174101017)
[^M5Y1K]: [Dell M5Y1K 40 Wh 4-cell battery for the Inspiron 15 3000 series](https://www.ebay.com/itm/357495025211)
[^ProDeskRackmount]: [1U rackmount for ProDesk Mini](https://a.co/d/4d7klOL)
[^I226]: [Intel I226 2.5 GbE card on an M.2 B+M-key adapter](https://a.co/d/dJ4BD2N)
[^Sliderail]: [Sliding rails for ProLiant](https://a.co/d/5d4A4FO)
[^Rail]: [1U universal rack mount](https://a.co/d/6R0vjHz)
[^Couplers]: [Cat6 in-line couplers](https://a.co/d/gP3b948)
[^Patchcables]: [Cat6 patch cables](https://vetco.net/collections/cables-cat6-patch-cables)
