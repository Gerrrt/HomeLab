# ADR-0052: Cable `smaug`'s pool to the chipset and take the MegaRAID out

**Status:** Accepted · 2026-09 · decides the layer beneath the pool layout
[ADR-0040](0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)
chose; decides [#571](https://github.com/Gerrrt/HomeLab/issues/571); carried
out during [#558](https://github.com/Gerrrt/HomeLab/issues/558)'s swap, not
before it

## Context

`erebor`'s two Exos X20 drives have never been on the chipset. Read at the
console on 2026-09-19 while `ZVTBSDL3` was faulting, both sat behind an
**AVAGO MegaRAID SAS 9340-8i** in the PCIe slot (`1000:005f`, subsystem
`1000:9340`, the ThinkServer RAID 520i option), in JBOD pass-through on a
cacheless iMR. Its firmware was read in UEFI setup on 2026-09-22: package
24.16.0-0104, firmware 4.660.01-8219. The chipset's AHCI carries the boot SSD
alone, on `ata6`. `ata1` to `ata5` read *SATA link down* at every boot, so
five of its six ports are free. The documents had assumed the chipset all
along: `hardware.md` said `Configure SATA as [AHCI]` was what kept a
controller out from between ZFS and the disks, and it protected the boot
disk and nothing else.

JBOD is the better of the two MegaRAID arrangements. ZFS owns the mirror,
and `smartctl` reaches each drive by its own model and serial with no
`-d megaraid`. But the card's firmware still sits in the error path, and on
2026-09-19 that path was the fault: 60-second command timeouts, task aborts,
a target reset and an Online Controller Reset at 21:03:51. That was what
held node_exporter for nine minutes (#558) and what ZFS saw instead of the
disk.

[#558](https://github.com/Gerrrt/HomeLab/issues/558) parked three answers
for after the swap:

| Answer | For | Against |
| --- | --- | --- |
| Leave the card, JBOD | Nothing to buy or flash, and it came through one real fault | Firmware between ZFS and the disks; its error path is slow and opaque |
| Flash the 3008 to IT mode | The HBA ZFS is designed for, on `mpt3sas` | A 9340 is a MegaRAID card, so IT firmware means a community crossflash on the only controller the pool is on, with no spare card to recover a bad flash |
| Chipset AHCI, card out | Nothing to flash; two SATA cables to buy; what the documents already assumed | The only tray cable is the card's own breakout, so it needs new cables |

## Decision

**Move the pool's drives to the chipset's free SATA ports and take the
MegaRAID out**, during #558's swap while the case is already open and the
machine is already down.

1. **Buy two SATA data cables before the swap.** The only data cable for
   the trays is the card's own: a mini-SAS HD (SFF-8643) to four-SATA
   breakout, confirmed 2026-09-23. Its drive ends are ordinary SATA plugs,
   but its host end fits only the card, so it cannot go to the board. Two
   plain SATA III cables (7-pin, female at both ends, latching, about
   50 cm) replace it. Power leads do not change, and the boot SSD keeps
   its own cable. They are what the swap waits on besides the drive, so
   they are ordered with it, not on the day. The breakout goes on the
   shelf with the card: it is the fallback's cable.
2. **Move the surviving drive first, alone.** Power off. Unplug the
   breakout from `ZVTBS4NL`, connect it to a free chipset port with one of
   the new cables, and pull the card with the breakout still attached.
   Boot with the pool still one-legged. `lsblk` shows the drive, `dmesg` shows it on `ahci`
   with `SATA link up 6.0 Gbps`, and `zpool status erebor` imports with that
   member `ONLINE` and the missing one `OFFLINE`, as before. ZFS finds its
   members by the GUID in their labels, not by device path or controller,
   and TrueNAS imports by partition UUID, so a new path is not an event to
   the pool. Moving a cable writes nothing: if the pool does not import,
   power off and put the card and the breakout back.
3. **Then fit the replacement on a second chipset port** and resilver it as
   `replace-the-nas-disk.md` §5 says.

**The fallback is the first answer, and it needs no further decision.** If
step 2's boot does not show the drive on `ahci`, or the pool does not import,
the card and its breakout go back in, the card stays in JBOD, and
`hardware.md` records that as the arrangement by decision rather than by
accident. That includes its error path, and the slow, opaque failure it
produced on 2026-09-19.

**Not IT mode.** Crossflashing a 9340 to 9300-8i IT firmware is a known
community procedure, not a vendor-supported one. The pool's only
controller is the one being flashed, and a failed flash leaves a degraded
mirror with no way to reach it until a second card arrives. With five free
chipset ports, a flash buys nothing the cable move does not.

## Consequences

- **The error path becomes libata's.** A disk that stops answering is
  handled by the kernel's AHCI driver and its SCSI error handler, logged
  under `ata1:` and `ata2:` in `dmesg`, with no controller firmware of its
  own and no controller reset to hold the exporter. That is the path the
  documents already assumed, and it is simpler to read. It is not
  guaranteed to be faster: the kernel's default command timeout is 30 s,
  and a disk that retries internally can still stall a read.
- **`Configure SATA as [AHCI]` now protects the pool.** The setting
  `hardware.md` credits with keeping a controller out from between ZFS and
  the disks does that job.
- **`1000:005f` should be gone from `lspci`.** Its presence after the swap
  means the card is back in. `hardware.md` already names `1000:0097` as the
  same silicon in IT mode, for anyone reading it later.
- **The device letters can move.** All three disks are on one controller
  now, so enumeration order changes. ADR-0047's baseline row names the boot
  SSD as `/dev/sdc`, and its own consequence says what happens when that
  goes wrong: the row matches nothing and the boot disk pages. Re-run
  `collect-smart-state.sh --print --host smaug` after the move and correct
  the row, as `build-the-nas.md` §6.7 describes.
- **The card goes on the shelf, not in the bin.** It is the fallback's
  hardware if a chipset port ever fails, and a known-good 9340-8i if IT mode
  is ever worth trying on a machine with a spare controller.
- **The PCIe slot is free**, and the box draws a few watts less. Neither
  was a reason.
- **Not before the swap.** Until a replacement is in hand the pool is a
  single disk, and a controller change on a one-legged mirror is a second
  risk stacked on the first. The recable happens at step 5, with the case
  open for the new drive anyway.
