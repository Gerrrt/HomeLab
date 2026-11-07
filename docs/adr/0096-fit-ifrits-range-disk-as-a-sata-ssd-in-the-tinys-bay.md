# ADR-0096: Fit ifrit's range disk as a SATA SSD in the Tiny's bay

**Status:** Accepted · 2026-10 · supersedes the *Disk* row of
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)

## Context

[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) decided
`ifrit`'s disk as "**NVMe.** Not a spindle, and not a mirror", on the ground
that the range's core operation is snapshot revert and "a chassis without an
M.2 slot cannot be given one". The box that was bought on 2026-10-05, a
first-generation ThinkCentre M80q, has that slot, and it is occupied by the
256 GB M.2 the refurbisher fitted ([`hardware.md`](../hardware.md)). The
roadmap's purchase row therefore read "1 TB NVMe SSD", and the move runbook's
§1.3 had it *replace* the 256 GB drive, "there is nowhere to fit both".

That last sentence was wrong. Lenovo's PSREF sheet for the first-generation
M80q gives its storage as "up to two drives, 1x 2.5" HDD + 1x M.2 SSD", the
2.5" bay on SATA 6 Gb/s. The bay takes a 2.5" SSD as readily as a disk, and
it is empty on a Tiny sold with an M.2 only. The tray and its flat SATA
cable are in this chassis, checked on 2026-10-16; a refurbished box can ship
without them, in which case Lenovo sells them as the Tiny tray kit
`5M10U50268` with the `00XL211` cable.

The operator chose on 2026-10-16 to put the range disk in that bay as a SATA
SSD rather than swap the M.2.

What ADR-0017 was actually guarding against is worth restating, because the
choice turns on it. Its argument was flash against spindles: the range reverts
snapshots all day, and the fleet's measured bottleneck was a 7.2K mirror doing
741 random write IOPS at queue depth 1 against 7,952 from a SATA SSD pair, as
its own note records. A SATA SSD is on the right side of that line by an order
of magnitude. What SATA gives up against NVMe is the next order: sequential
throughput capped near 550 MB/s against several GB/s, and random IOPS in the
tens of thousands rather than the hundreds. For four or five guests on one
host, reverting one at a time, that is not the bottleneck; the range's
activity is attack tooling, not storage benchmarking.

## Decision

**`ifrit`'s range disk is a 1 TB 2.5" SATA SSD in the Tiny's drive bay. The
256 GB M.2 stays, as the hypervisor's boot disk.**

- **The bay, not the slot.** The SATA SSD mounts in the Tiny's 2.5" tray and
  connects by the flat SATA cable to the board, as the M80q hardware
  maintenance manual shows. Both are in the chassis, so no kit is bought.
- **Two drives, two jobs.** The 256 GB M.2 is the Proxmox boot and root disk;
  the 1 TB SATA SSD is the guest storage, where templates, the attack VM and
  the targets' disks live and are reverted. The boot disk is never part of
  the range's churn, which is a cleaner layout than ADR-0017's single drive
  and is the one real gain of this change.
- **Nothing else in ADR-0017 moves.** Socketed RAM to 32 GB, the quiet
  form, one NIC, and the range being maintained by nobody all stand.

## Consequences

- `docs/roadmap.md`'s row becomes a 2.5" SATA SSD;
  [`hardware.md`](../hardware.md) and the two runbooks that fit and
  then use the drive say the same. The move runbook's §1.3 no longer swaps
  the M.2 and no longer keeps a 256 GB drive "with the spare parts".
- The range's storage ceiling is SATA's. If a future exercise is ever
  storage-bound, the M.2 slot is still there, and the fix is a larger NVMe
  in it with the roles swapped, not a new chassis. That is the condition that
  would reopen this decision.
- The 2.5" bay's cable is a flat flexible one that routes under the board on
  a Tiny; fitting it is a case-open job done once, in the move runbook's
  §1.3, before the box is racked.

## Alternatives considered

- **A 1 TB NVMe replacing the 256 GB M.2**, as the runbook had it. One drive
  for boot and guests, the 256 GB left on a shelf, and the fastest option.
  Rejected by the operator on 2026-10-16 in favour of SATA; the layout above
  is also better separated.
- **A 1 TB NVMe plus the 256 GB M.2 moved to the bay** via an M.2 SATA
  drive. Not possible: the 256 GB drive is NVMe, and the bay is SATA.
- **Leaving the 256 GB M.2 as the only disk.** ADR-0017 sized the range at
  four or five guests with templates; 256 GB is below that before the first
  snapshot.
