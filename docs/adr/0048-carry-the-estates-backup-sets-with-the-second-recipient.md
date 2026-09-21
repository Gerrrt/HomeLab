# ADR-0048: Carry the estate's backup sets on the second recipient's medium, and prove the copy on its visit

**Status:** Accepted · 2026-09 · answers the *off-site* consequence of
[ADR-0015](0015-give-oracle-the-off-host-jobs.md), which that ADR left with
[#92](https://github.com/Gerrrt/HomeLab/issues/92)

## Context

Three artefacts leave the monitoring host now, and every copy of each is on
the same shelf under the same roof
([#573](https://github.com/Gerrrt/HomeLab/issues/573)):

| Set | Made by | Copies | Since |
| --- | --- | --- | --- |
| The firewall export | `make backup-firewall`, nightly | `prometheus`, `oracle` | 2026-09-03 (#92) |
| The volume sets | `make backup`, weekly | `prometheus`, `oracle` | 2026-09-19 ([#535](https://github.com/Gerrrt/HomeLab/issues/535)) |
| The NAS set | `make backup-nas`, weekly | `prometheus`, `oracle` | 2026-09-20 ([#484](https://github.com/Gerrrt/HomeLab/issues/484)) |

Each of those arrived saying the same sentence on its way out. ADR-0015's
first consequence is *"off-host is not off-site, and here it is not even
off-shelf"*; [ADR-0045](0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md)
closes with *"off-host twice and offsite never"*; `roadmap.md` carried it as a
residual under #92 twice, and `build-the-nas.md` §8 listed it under what the
build leaves open. Four documents named it and no issue owned it, which is the
shape this repository's tracker exists to prevent.

**What the shelf proves, and what it does not.** `verify-backups` runs every
morning: it decrypts every retained set here and asks `oracle` to hash what it
holds, so a copy that has stopped existing on the shelf is a failure within a
day. It says nothing about a fire, a flood, a theft, or a mains event that
takes the rack, because both laptops are on the same shelf, behind the same
switch, on the same circuit
([ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md) makes
the same point about the mini PC). `oracle` protects against `prometheus`'s
disk, a bad `docker volume rm`, and a stack that will not come back up. It was
never meant to protect against the room.

**The sizes make this a small question.** A firewall export is 229 KB. A NAS
set is 2.7 MB. A volume set is 1.7 GB, measured on 2026-09-20 with the
observability stack's five archives. All of it changes slowly: the export
moves when a rule does, the volume set carries `grafana.db` and the TSDBs,
whose loss ADR-0023 has already classed as *the record, and only the record*.
A copy that is ninety days old is stale by thirteen weekly sets and loses
nothing the estate cannot re-accumulate.

### Two things already exist beside this, and neither is it

**#455 buys a drive kept at another address.** That drive is ADR-0023's: the
household's copy of Immich and Paperless-ngx, encrypted to a key the operator
does not solely hold, opened once from the other person's device without the
operator present. Its reader is the household on a bad day. The three sets
above are read by a technical successor on a different bad day, are encrypted
to the estate's two age recipients, and are of no use to anyone who cannot
open those. [#294](https://github.com/Gerrrt/HomeLab/issues/294)'s decision of
2026-09-08 keeps the household archive's key and the estate's key apart on
purpose — *"one key doing both jobs means one leak takes both"* — so
*"put it all on the one drive"* is a decision with a key question inside it.
And the drive does not exist: it is gated on ADR-0022's first trigger, and its
own first condition — which key it is encrypted to — is asked in #455 and not
answered.

**The second age recipient already lives somewhere off this estate.**
[ADR-0024](0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)
made a second recipient the design; #294 named its holder, the technical
second on the break-glass card; the keypair was generated on the medium that
keeps it and only the public half travelled, on 2026-09-09
([#412](https://github.com/Gerrrt/HomeLab/pull/412)). That medium owes this
host a visit every ninety days, because
[`verify-key-backup.sh`](../../scripts/verify-key-backup.sh) refuses the live
key by device and inode and no timer can mount a medium, so
`SecretsKeyBackupUnproven` nags per recipient until the copy is brought here
and proved. Read off the host on 2026-09-20, that recipient's proof series is
`0`: the medium exists, is off-estate by construction, and has not yet made
its first visit.

### The argument that decides it

ADR-0024 chose a second *recipient* over a second *copy* of one key for a
reason that is not cryptographic: *"`.sops.yaml` records a recipient in git.
Nothing records a copy."* Two copies of one key are indistinguishable to the
tooling, so proving either would vouch for the other. The same is true of
sets. `run-scheduled.sh` writes one success timestamp per job name; two media
carrying the same sets would share it, and the alert would be *more* wrong the
more copies existed. So whatever is decided here has to name **one copy of
record**, and the proof has to be of *that* medium.

## Decision

**The estate's three backup sets go beyond the shelf on the medium that holds
the second age recipient, carried there on the ninety-day visit that medium
already owes, and proved by the same visit.** Four parts.

**1. The newest complete set of each kind rides on the second recipient's
medium.** Not every set: a successor rebuilding from nothing wants the newest
firewall export, the newest volume set and the newest NAS set, and the retained
history stays on the shelf where `verify-backups` reads it. The layout on the
medium mirrors `oracle`'s — `backups/firewall/`, `backups/volumes/<stack>/`,
`backups/nas/` — so a restore is *copy the directory back into `backups/`*
and then [`restore-the-firewall.md`](../runbooks/restore-the-firewall.md) or
[`restore-the-stack.md`](../runbooks/restore-the-stack.md) as written.
Everything on it is the same ciphertext that is here and on `oracle`; nothing
is re-encrypted and no key is read to make the copy.

**2. `make backup-offsite DEST=/path/to/the/medium` is the visit's job**, by
[`scripts/backup-offsite.sh`](../../scripts/backup-offsite.sh). It refuses a
destination on this host's own filesystem, by device number rather than by
path, for the reason the key proofs refuse the live key: a copy on the disk
being insured is off-host to nowhere, and the refusal is what makes a recorded
success mean a real medium was mounted. Then, in order: it re-verifies every
complete set the medium already holds against that set's own MANIFEST — the
column `verify()` computed on bytes it had just decrypted, and the same column
`oracle` is held to — which is the proof that *last* visit's bytes survived
ninety days on the medium; it copies what the medium lacks, MANIFEST last, so
a copy that dies is INCOMPLETE by the rule every other directory here follows;
it syncs and hashes the new copy; and it applies `OFFSITE_KEEP`, default one,
never the newest, only names it wrote. A set that differs fails the run and is
named with its repair. Nothing is deleted on a failure path.

**3. The deadline is the same ninety days, declared in the same table.** The
`offsite-copy` row in [`install-timers.sh`](../../scripts/install-timers.sh)
has no unit, like `verify-key-backup` and `verify-ca-key-backup`, and
`OffsiteCopyStale` reads the job's own success series against it. `--list`,
`--verify-only` and `--prune` run unwrapped on purpose: inspecting a
ninety-day-old copy is not the same as refreshing it, and must not reset the
clock. Before the first visit the row is declared and nothing has succeeded,
so `ScheduledJobNeverRan` names it — the honest state, and expected until
then. One visit therefore clears three alerts, in one sitting, with one
medium: the second recipient's proof, the CA key's proof if that copy is
carried too, and this.

**4. One copy of record.** The medium of record is the second recipient's, and
the series is one series. If #455's drive later carries the estate's sets as
well, it does so as a convenience nothing here can see, in the sense ADR-0024
gives that phrase, and the runbook says so rather than pretending two
timestamps exist.

### And three things it is not

**Not `oracle`, and not a network.** ADR-0015's second host holds ciphertext
and no key, on the shelf, and nothing here changes that. There is no path off
the estate that the sets could take on their own: ADR-0015 keeps `oracle`
single-homed, [ADR-0042](0042-terminate-the-remote-path-on-the-lab-and-route-it.md)
terminates the remote path on the lab and not on the monitoring host, and a
copy that leaves by cable would need somewhere to arrive, which is #455's
decision and not this one's. The sets leave the house the way the key does: in
a pocket.

**Not #455's drive, for now.** Its reader cannot open these sets, its key is
deliberately not theirs, and it is months away. On a bad day the successor
would need the drive from one address *and* the key from another; on the
second recipient's medium they need one thing. If the drive's owner and the
technical second are one day the same person the question is worth reopening,
and the runbook is where the answer would change.

**Not the shelf.** The third answer #573 offered was to write down that the
estate's own sets stay where they are: a fire that takes both laptops takes the
estate they describe, and a successor rebuilding from nothing starts from the
repository. That is defensible for the volume sets. It is wrong for the
firewall export, which is the one artefact here with a real rebuild cost — the
whole ruleset, every static mapping, the users and the certificates — and
exactly the thing a successor standing up a replacement `morpheus` on new
hardware wants first. The mechanism that carries it costs one directory on a
medium that already visits, so declining to use it would be accepting a loss
to save nothing.

## Consequences

- **The second recipient's medium now holds ciphertext and a key that opens
  it.** This is the property ADR-0015 refused to give `oracle`, and the
  refusal stands: that argument turned on a powered, network-attached host in
  the same room, and none of it transfers to an offline medium held off the
  estate by the person the sets are for. What does transfer is the cost.
  Losing that medium already means rotating every credential in the
  repository; with the sets on it, the same loss also discloses the firewall's
  rule bodies and WAN address, the device password hashes in the export, and
  `grafana.db`. Accepted, and recorded in [`security.md`](../security.md)
  beside ADR-0023's residual, for the reason that decides it: the alternative
  is a successor who holds the key and not the thing it opens, and a copy that
  only the operator could have made.
- **The copy is up to ninety days old, and that is the design.** The sizes
  and the rate of change above are why. A visit that is late is
  `OffsiteCopyStale`, not a silent gap, and a set that quietly rotted on the
  medium is caught by the re-verify at the start of the next visit rather
  than on the day it is needed.
- **The medium may need to be larger than a key does.** A volume set is 1.7 GB
  and `OFFSITE_KEEP` is one per kind, so a few gigabytes free is the floor.
  The script measures before it writes and refuses rather than fills, because
  a medium that ran out halfway would leave a `.part` and no MANIFEST — which
  is recoverable — while the alert said proved.
- **#573 closes on the first proved copy, not on this merge.** The mechanism
  and the deadline are built here; the copy is a physical visit only the
  holder of the medium can make, exactly as #294's last box is. Until then
  `ScheduledJobNeverRan{homelab_job="offsite-copy"}` is the expected reading,
  and [`successor-handover.md`](../runbooks/successor-handover.md) says where
  the sets are without saying where the medium is, as it does for the key.
- **ADR-0015 is not amended.** ADR-0001 keeps it immutable; its off-site
  consequence gains a forward pointer to this document and nothing else. #92
  stops carrying the residual and stays the rehearsal.
- **A third human job with a deadline and no timer.** The `JOBS` table, the
  Makefile guard against a bare invocation, the exclusion from
  `ScheduledJobStale` and a rule of its own are the same shape as the two key
  proofs, deliberately, so the runbook reader who has done one has done all
  three. The cost is the one ADR-0024 priced: the visit now has three things
  to do instead of two, and the third is a copy that can take a minute at
  USB 2.0 speeds.
