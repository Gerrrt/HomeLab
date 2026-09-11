# ADR-0027: Defer Proxmox Backup Server until there is somewhere to send it

**Status:** Accepted · 2026-09

> [!NOTE]
> The host this ADR calls `zion` is named **`smaug`** since 2026-09
> ([ADR-0038](0038-name-the-nas-smaug-and-reserve-zion-for-the-box-that-does-not-exist.md)).
> The address, the rules and the decision are unchanged — only the label. The
> text here is left as written, per ADR-0001. `zion` is now reserved for the
> dedicated firewall cold spare ADR-0034 defers, which does not exist.

## Context

[ADR-0007](0007-defensive-estate-and-offensive-range.md) lists Proxmox Backup
Server as part of the defended estate on `Saruman`.
[#268](https://github.com/Gerrrt/HomeLab/issues/268) declined to install it
until a prior question was answered, and the question is the right one:

> **A hypervisor backing up its own guests to itself is not a backup.**

If PBS runs as a guest on `Saruman` and stores to `Saruman`'s disks, the
mirrored pair is a single point of failure for the estate *and* its backups. The
only fault that protects against is "someone broke a VM", which is real and is
snapshot territory rather than backup territory.

Three facts settle it, and two of them were checked rather than assumed.

**There is nowhere off-host to send it.** The NAS is `zion` at `10.0.40.30`,
decided by [ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
and recorded in `network.md` as **"not yet bought"**.
[#95](https://github.com/Gerrrt/HomeLab/issues/95) is closed, which is easy to
read as "the NAS exists" — it does not. #95 was *plan and build*, and what
completed was the plan. Backing up to anything on VLAN 99 is a path ADR-0007
does not grant, so there is no third option.

**Proxmox VE already does the thing the local-only answer needs.** Snapshots and
`vzdump` are native to PVE. If the honest scope is snapshot-and-revert for the
lab, PBS adds a service, a datastore, a web UI on 8007 and a second thing to
patch, in exchange for deduplication and incremental backups of data that is
already on the same spindles. What PBS is actually *for* — dedup, incremental,
verification and **sync to a remote datastore** — is mostly the last item, and
the last item is what does not exist.

**A second backup system with no verification is one nobody finds out has been
failing.** The estate's own path sets the bar: `make backup` quiesces the stack,
archives its volumes, encrypts them and verifies the result, and
`homelab-verify-backups.timer` re-checks on a schedule with
`ScheduledJobStale` behind it. PBS can verify — but a PBS installed now would be
verifying a copy that shares a disk with its original, which is a green check
mark for a property nobody should be reassured by.

## Decision

**Do not install Proxmox Backup Server yet. Use PVE's native snapshots for
revert, and record that the lab has revert and not backup.**

The lab estate on `Saruman` is protected against a broken VM and against
nothing else. That is a real capability and it is worth having; it is not a
backup and this repository will not call it one.

**PBS is installed when `zion` exists**, in the shape PBS is designed for: the
datastore local to `Saruman` for speed and dedup, and a **sync job to `zion`**
for the copy that survives the hypervisor. That is the point at which it stops
being a service that duplicates PVE and starts being the only thing that
provides an off-host copy.

**What it will back up, decided now so the answer is not improvised later:**

| | | |
| --- | --- | --- |
| The Windows domain ([#265](https://github.com/Gerrrt/HomeLab/issues/265)) | **yes** | Stateful and expensive to rebuild. It is the thing everything else in the lab is pointed at |
| Wazuh's indexer ([#266](https://github.com/Gerrrt/HomeLab/issues/266)) | **yes** | Its retained alerts are the record of what the lab saw, and re-running an exercise does not reproduce them |
| The lab observability stack | **no** | Reproducible from this repository. `stacks/lab/` is in git and its secrets have their own age key, which is the recovery path |
| The lab stack's Loki | **no** | The evidence is reproducible by running the exercise again, which is the same argument [ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) makes for `ifrit` |
| `ifrit`'s range | **no** | Already decided by ADR-0017 and unchanged here |

**Whatever is installed must be verified on a schedule, and its verification
must be visible where the estate's already is.** A PBS verify job that nobody
watches is worth less than no backup at all, because it removes the worry
without removing the risk.

## Consequences

- **The lab has no backup, and that is now written down rather than implied.**
  Losing `Saruman`'s mirrored pair loses the Windows domain, Wazuh's history and
  every guest. The rebuild path is this repository plus the exercise being run
  again — which is survivable for a lab and would not be for the estate.
- **ADR-0007's component list is one item lighter for now.** It named PBS as
  part of the defended estate; this defers it without rejecting it, and names
  the condition that ends the deferral. That is the same shape
  [ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md) gave
  the SSO deferral, and for the same reason: a deferral with no trigger is
  indistinguishable from a decision not to do it.
- **`zion` acquires a second dependant.** ADR-0016 justified it for media and
  household data; it is now also the only planned destination for the lab's
  backups. That strengthens the case for buying it and should be noted when its
  capacity is sized — Wazuh's indexer is the heaviest component in ADR-0007 and
  its retention is what will drive the number.
- **The snapshot capability needs no work to gain and none to keep**, which is
  most of why this is the right answer today. Nothing is installed, nothing is
  patched, and nothing claims to be a backup.
- **One thing this does not settle:** whether the lab's guests should be
  snapshotted on a schedule or only before an exercise. That is an operational
  choice, it costs disk on the same constrained pair, and it can be made when
  #265 gives the lab something whose state is worth keeping.
