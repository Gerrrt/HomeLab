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
([#454](https://github.com/Gerrrt/HomeLab/issues/454)). `prometheus`'s cell was
replaced on 2026-09-18 and reads 101 % of its design capacity at one cycle;
`oracle`'s is the original, reads 72 %, and its replacement — a Dell M5Y1K —
was bought on 2026-09-19 and is in transit
([#531](https://github.com/Gerrrt/HomeLab/issues/531)). How long either laptop
actually runs on its cell has never been measured.

The patch panel and the PDU were listed the other way round here until
2026-08-29. U8 is the panel and U7 is the PDU, confirmed against the rack.
Nothing in this repository depended on the order, but the wiki's rack page had
it right and this table did not, so the correction is recorded rather than
quietly swapped.

## Compute

| Host | Hardware | CPU | RAM | Storage | OS |
| --- | --- | --- | --- | --- | --- |
| `morpheus` | HP ProDesk 600 G4 Mini | i5-8500T | 32 GB | 1 TB NVMe SSD | FreeBSD 16.0 (pfSense) |
| `Saruman` | HPE ProLiant DL360 Gen9 | 2× Xeon E5-2680 v3 (48 threads) | 128 GB | 2× 1 TB SAS HDD, RAID 1 (`pve`); 2× 960 GB SATA SSD, RAID 1, LVM-thin `Large_data` | Proxmox VE 9 |
| `prometheus` | Apple MacBook Pro (2012, Retina 13") | i5/i7 | 8 GB | 256 GB SSD | Ubuntu Server 24.04 LTS |
| `oracle` | Dell Inspiron 15-3565 | AMD A6-9200 (2 cores) | 4 GB | 500 GB HDD | Ubuntu Server 24.04 LTS |
| `smaug` | Lenovo ThinkServer TS150 | Xeon E3-1225 v6 (4 cores) | 8 GB ECC | 240 GB SATA SSD (boot) + 2× 18 TB ZFS mirror `erebor` | TrueNAS 25.10 |

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
  itself — placed, addressed at `10.0.40.30`, and in `network.md`. The Storage
  column reads the boot disk alone on purpose: the ZFS mirror does not exist
  until the two Exos drives land, and a Storage column describing a pool nobody
  has created would be the kind of claim this table exists to not make. The boot disk the TrueNAS install wants
  ([ADR-0040](adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md))
  and the bracket that carries it in the optical bay are the entries below and
  landed with it; the two drives for the mirror, bought 2026-09-11, landed on
  2026-09-18 and were in the bays that evening. Nothing
  for this machine is outstanding on the roadmap's
  [list](roadmap.md#everything-still-to-buy) any more, and the Storage column
  reads the mirror since 2026-09-19.
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
  this board. Onboard NIC `4c:cc:6a:xx:xx:xx`, recorded as an OUI like every
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
  and no spare.
  **The 5.25" bay was not empty**: a PLDS `DVD-RW DU8AESH` answered on SATA5.
  A photograph of the open case had been read here as an empty cage and was
  wrong; the BIOS summary is what caught it. The optical drive came out on
  2026-09-16 and the boot disk took its place, its port and both its cables.
  The bay is a cage carrying its own fan on the board's `AUX1_FAN` header, and
  that fan is **not optional**: it is the airflow over the drive bays, and two
  7200 rpm Exos under a scrub will want it. Reconnected after the swap and
  reading `Aux Fan: Operating`.
- 2× Seagate Exos X20 18 TB (`ST18000NM003D`, firmware `SN03`), 3.5" SATA —
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
  says what this drive did before: it was almost never shut down cleanly. It is
  also the argument above, tested. This part was chosen because *a boot disk
  that survives a power cut is worth more here than one that is merely fast*,
  and `Power_Loss_Cap_Test` still passes after 509 of them — the capacitor works
  and somebody else did the proving.
  **Four reallocated sectors, and that is a number to watch rather than to
  reject** — normalised 099 against a threshold of 000, with nothing pending
  and nothing uncorrectable behind it. It has a consequence that is better
  written down now than discovered later: `SmartDriveBadSectors` fires on
  `homelab_smart_reallocated_sectors > 0`, deliberately, because a remapped
  sector never un-remaps and the first one is the finding. **So this drive will
  trip that alert on the day SMART collection reaches `smaug`**, exactly as
  `oracle`'s 32 static sectors do, and the answer is the one #351 already built:
  silence the static fact and let `SmartDriveBadSectorsGrowing` carry the trend,
  because a silence matches labels and no label carries the count.
  `SmartDriveWearHigh` will not fire — it wants 80 % of rated life used and this
  is near a tenth. No self-tests had ever been logged in 13,182 hours, so a
  baseline was taken on 2026-09-16 before the machine carried anything:
  **extended offline, completed without error, at lifetime hour 13,183**. The
  drive took far longer than its own two-minute estimate because it advertises
  *Suspend Offline collection upon new command* and TrueNAS was live underneath
  it — worth knowing before reading a slow self-test as a sick disk. TrueNAS's
  scheduled tests take it from here.
- 2× Samsung SM863a 960 GB (`MZ-7KM960N`), 2.5" SATA 6 Gb/s enterprise
  SSDs with power-loss protection[^SM863a] — purchased 2026-09-09, delivered
  2026-09-11, fitted 2026-09-18 in bays 3 and 4 of the ProLiant, and **since
  2026-09-19 the P440ar's logical drive 2: RAID 1, `915683` MB, carrying the
  LVM-thin pool `Large_data`** (volume group, pool and Proxmox storage id are
  all that one word). Bought against the number every sizing decision on
  `Saruman` starts from: a 7.2K mirror serving about ninety random write IOPS
  ([ADR-0029](adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)).
  Serial `S3F3NX0K601487` in Bay 3 and `S3F3NX0K806107` in Bay 4, firmware
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
  Administrator, not `ssacli`, which is still not on the host. The array read
  `ok` from its first scrape and nothing alerted for it; what did alert was
  the fourteen-and-a-half-hour power-off the SSA session sat inside, which the
  runbook now records. **The iLO's wear columns stayed blank once the drives
  were configured** — wear status `other`, endurance and power-on hours
  unknown — which is the condition
  [#529](https://github.com/Gerrrt/HomeLab/issues/529) was filed against, so
  wear on these two drives is [#529](https://github.com/Gerrrt/HomeLab/issues/529)'s
  to read through `hpsa`. What has not moved is everything after the pool:
  `alexander` still on the HDD mirror, no cache reading for
  [#76](https://github.com/Gerrrt/HomeLab/issues/76), and no measurement — so
  [#527](https://github.com/Gerrrt/HomeLab/issues/527) stays open and the
  ADRs whose arithmetic it names stand as written until step 8 of
  [`fit-the-saruman-ssds.md`](runbooks/fit-the-saruman-ssds.md) produces a
  number. This entry is where the serials live, which is the question
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
  RouterOS / SwOS — bought used 2026-09-13; in transit, delivery estimated
  2026-09-23, moved out from the 09-16 to 09-21 window quoted at purchase. The
  replacement for
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
  read from this host's own Prometheus on 2026-09-18. **Not checked, and the
  reason [#454](https://github.com/Gerrrt/HomeLab/issues/454) is still open:**
  the mains pull on the fully charged pack, which is the property the cell was
  bought for and a runtime the estate has never had. The pack was still
  charging when the fit was recorded.
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
- ViewSonic N1700W LCD, used as a rack console via the KVM
- RJ45 Cat6 in-line couplers[^Couplers]
- Cat6 patch cables[^Patchcables]

[^UPS]: [APC Smart-UPS](https://www.apc.com/us/en/product-range/61913-smart-ups/)
[^Shiva]: [HPE ProLiant DL360 Gen9](https://buy.hpe.com/us/en/servers/rack-servers/proliant-dl300-servers/proliant-dl360-server/p/1010026922)
[^ProDesk]: [HP ProDesk 600 G4 Mini](https://www.microcenter.com/product/692358/)
[^Trinity]: [HP ProDesk 600 G4 Micro, the refurbished unit that is `trinity`](https://www.ebay.com/itm/237046034784)
[^SM863a]: [Samsung SM863a 960 GB, MZ-7KM960N](https://www.ebay.com/itm/800210578217)
[^Caddy]: [HP 2.5" SFF drive tray, 651687-001, for DL360/DL380/ML350 Gen8 and Gen9](https://www.ebay.com/itm/126297185368)
[^KVM]: [MT-VIKI 8-port rackmount KVM](https://a.co/d/2yQl4KH)
[^Panel]: [Jadol 24-port patch panel](https://a.co/d/izggRoK)
[^PDU]: [10-outlet 1U PDU](https://a.co/d/ibEygxZ)
[^tp-linkswitch]: [TP-Link 8-port gigabit switch](https://www.tp-link.com/us/business-networking/unmanaged-switch/)
[^MokerLink]: [MokerLink 26-port managed switch](https://a.co/d/gaJvCKV)
[^CRS326]: [MikroTik CRS326-24G-2S+RM](https://www.ebay.com/itm/257688846446)
[^A1437]: [A1437 battery for the MacBook Pro 13" A1425 Retina](https://www.ebay.com/itm/356174101017)
[^M5Y1K]: [Dell M5Y1K 40 Wh 4-cell battery for the Inspiron 15 3000 series](https://www.ebay.com/itm/357495025211)
[^ProDeskRackmount]: [1U rackmount for ProDesk Mini](https://a.co/d/4d7klOL)
[^I226]: [Intel I226 2.5 GbE card on an M.2 B+M-key adapter](https://a.co/d/dJ4BD2N)
[^Sliderail]: [Sliding rails for ProLiant](https://a.co/d/5d4A4FO)
[^Rail]: [1U universal rack mount](https://a.co/d/6R0vjHz)
[^Couplers]: [Cat6 in-line couplers](https://a.co/d/gP3b948)
[^Patchcables]: [Cat6 patch cables](https://vetco.net/collections/cables-cat6-patch-cables)
