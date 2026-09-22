# Runbook: Copy the backup sets offsite

**Target:** the newest firewall export, volume set and NAS set under
`backups/` on the monitoring host (10.0.99.20)
**Time:** ten minutes every ninety days, on the visit that proves the second
age recipient; a few minutes longer the first time
**You will need:** the offline medium that holds the second age recipient's
private key ([ADR-0024](../adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md),
[#294](https://github.com/Gerrrt/HomeLab/issues/294)), mounted on the
monitoring host, with a few gigabytes free

This is the third of the ninety-day proofs, and the first that is not a key.
Read [`back-up-the-age-key.md`](back-up-the-age-key.md) first if you have not:
the visit this runbook rides on is that one.

## Why

Three things leave this host on their own — `make backup-firewall` nightly,
`make backup` and `make backup-nas` weekly — and each copies itself to
`oracle` and fails if it cannot. That is off-host. It is not offsite: both
laptops share a shelf, a switch, a circuit and a roof, and `verify-backups`
proving every morning that `oracle` still holds every byte says nothing about
the room. [ADR-0048](../adr/0048-carry-the-estates-backup-sets-with-the-second-recipient.md)
sends one copy of each beyond it, on the medium that already leaves the estate
and already visits: the newest complete set of each kind, encrypted exactly as
it is here, carried in a pocket.

**Why this medium.** Its holder is the technical second named on the
break-glass card — the person who would restore from these sets on the day
they matter — and a successor holding it has the key, the sets and the public
repository in one hand. The cost that comes with that is stated in the ADR and
accepted: this medium is now the one place where the estate's ciphertext sits
beside a key that opens it. Keep it out of the house, and treat losing it as
losing the key, because it is.

**One copy of record.** The proof below records one timestamp. If the sets are
ever copied to a second medium as well, nothing here can see that copy, and
proving it does not count: `OffsiteCopyStale` is about *this* medium.

## 1. Mount it, and see what it holds

```bash
make backup-offsite DEST=/path/to/the/medium ARGS=--list
```

Two lists: what is complete here, newest first, and what the medium holds. On
the first visit the second list is empty and says so. `DEST` is a directory on
the medium, not the device; the script writes under `DEST/backups/`, in the
layout `oracle` uses.

## 2. Copy, and prove it

```bash
make backup-offsite DEST=/path/to/the/medium
```

In order, and each step stops the run if it fails:

1. **Re-verify what the medium already holds.** Every complete set on it is
   hashed against its own MANIFEST, every export against the sha256 written
   beside it. This is the proof that *last* visit's bytes survived ninety
   days on the medium, and it is why the copy is not the first step.
2. **Copy the newest complete set of each kind the medium lacks** — the volume
   set for the stack, the NAS set, the firewall export — into a `.part` name,
   MANIFEST last, then renamed. Room is measured first; the script refuses
   rather than fills.
3. **Hash the new copy** against the MANIFEST after a sync, and compare the
   MANIFEST byte for byte with the one here.
4. **Apply retention** on the medium: `OFFSITE_KEEP` of each kind, default
   one, never the newest, only names this script writes.

Expect:

```console
-- first visit — nothing on the medium to re-verify
copied 20260920T033007Z to /path/to/the/medium/backups/volumes/observability — every archive hashes to its MANIFEST entry
copied 20260920T060234Z to /path/to/the/medium/backups/nas — every archive hashes to its MANIFEST entry
copied config-20260920T051013Z.sops.yaml to /path/to/the/medium/backups/firewall — byte-identical, sha256 recorded beside it
the medium holds the newest of each kind, proved — offsite, not just off-host. Keep it out of the house.
```

**What it proves.** That every byte on the medium is the byte the MANIFEST was
computed from, which is the same column `oracle` is held to every morning; and
that the destination was not one of the places that are provably not a medium.
The script refuses the filesystem the sets already live on, by device number,
so a symlink or a bind mount into the root disk is caught the way the key
proofs catch the live key; it refuses `tmpfs` and `ramfs` anywhere they are
mounted; and it refuses `/tmp`, `/run`, `/dev`, `/proc` and `/sys` whatever is
mounted there.

**What it does not prove, and this is the one that bit.** That the destination
*leaves the house*. No check can establish that, and a green line is not the
claim. `/dev/shm` passed the first version of this runbook's advice because it
genuinely is a different filesystem — and it is this host's RAM, so the copy
was gone on the next reboot while the alert stayed quiet for ninety days. If
the destination is not a thing you can unplug and carry out of the building,
this procedure has not been performed, whatever it printed. The script warns
when the destination does not report as removable media, which catches the
common shape of that mistake and not all of it.

**What it deliberately does not prove.** That the medium will still exist
after a fire at the other address, a theft, or a lost bag; that its cells will
hold the bytes for ninety days unpowered, which is what the re-verify at the
start of the *next* visit is for; and that anyone but the holder knows where
it is. Those parts are judgement, not a check, and the medium's location is
not written down in this repository, for the same reason the key's is not.

Then, while the medium is mounted, do the other thing it is here for:

```bash
make secrets-verify-backup KEY=/path/to/the/medium/keys.txt
```

That clears `SecretsKeyBackupUnproven` for the second recipient; this runbook
clears `OffsiteCopyStale`. Neither clears the other.

## 3. The ninety-day deadline

Like the two key proofs, this cannot be put on a timer — it needs a human to
mount a medium — so it is enforced from the other end. A successful run of the
copy records `offsite-copy` through `run-scheduled.sh`, and `OffsiteCopyStale`
fires when that success passes ninety days old, routed to the normal alert
channel like any other warning. The threshold is the `offsite-copy` row in
the `JOBS` table in [`install-timers.sh`](../../scripts/install-timers.sh),
beside `verify-key-backup` and `verify-ca-key-backup`, so one number governs
the whole visit.

`ARGS=--list`, `ARGS=--verify-only` and `ARGS=--prune` run outside the wrapper
on purpose: looking at the medium, or tidying it, is not refreshing it and
must not reset the clock. Only the full copy counts.

Before the first visit the deadline is declared and nothing has succeeded, so
`ScheduledJobNeverRan` names `offsite-copy` — the same state the key proofs
start in, and the honest reading of a copy nobody has made.

## Restoring from the medium

The layout is `oracle`'s, so a restore starts by putting the directory back
where the restore runbooks expect it, on the rebuilt host:

```bash
cp -r /path/to/the/medium/backups/volumes/observability/<STAMP> backups/volumes/
```

```bash
cp -r /path/to/the/medium/backups/nas/<STAMP> backups/nas/
```

```bash
cp /path/to/the/medium/backups/firewall/config-<STAMP>.sops.yaml backups/firewall/
```

Then [`restore-the-stack.md`](restore-the-stack.md) (`make restore
ARGS="--from <STAMP>"`), [`restore-the-firewall.md`](restore-the-firewall.md)
and [`build-the-nas.md`](build-the-nas.md) §6 as written. None of it decrypts
without the age key, which is on the same medium — that is the point of this
medium, and the cost of it.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `DEST is required` | A bare `make backup-offsite` | Mount the medium and pass `DEST=`. This guard is what keeps a typo from being recorded as a failed copy |
| `the destination is on the same filesystem as the sets it would copy` | `DEST` is a directory on this host's disk, or a symlink or bind mount into it | Point it at the mounted medium. This is the check working |
| `the destination is a tmpfs filesystem, which is not a medium` | `DEST` is `/dev/shm` or another in-memory filesystem | Point it at the mounted medium. A copy in RAM is gone on the next reboot, and the recorded success would have vouched for it for ninety days |
| `the destination is under /…, which this host clears or recreates` | `DEST` is under `/tmp`, `/run`, `/dev`, `/proc` or `/sys` | The same. Whatever is mounted there, it does not leave the house |
| `… does not report as removable media` (a warning, the run continues) | The destination is a fixed disk or a network mount | Only you can say whether it leaves the house. If it does not, stop and mount the medium |
| `the destination is inside this repository` | `DEST` is under the working tree | This tree is published. Use the medium |
| `not enough room on the medium` | A volume set is about 1.7 GB and the medium is small or full of something else | `ARGS=--prune` if an older set of the estate's is what fills it; otherwise a larger medium. Nothing was written |
| `differs from its MANIFEST entry` or `differs from its recorded sha256` | A byte on the medium changed since it was written — media do fade | Remove *that one* set directory (or that export and its `.sha256`) from the medium, then run the copy again. The script names it and never deletes it for you |
| `refusing to check a set with an unexpected name` | A directory holding a `MANIFEST` sits beside the sets under a name that is not a stamp — copied there by hand, or renamed | Move it off the medium or delete it, then run again. A `<stamp>.part` left by a copy that died is not this: the next run removes it on its own and says so (`removing … — a copy that did not finish`) |
| `nothing to verify on the medium` from `--verify-only` | The medium holds no complete set | Not a proof of anything. Run the copy |
| `OffsiteCopyStale` | Ninety days since the last proved copy | This runbook, on the next visit |
| `ScheduledJobNeverRan` for `offsite-copy` | The deadline is declared and no copy has ever been made | Expected until the first visit. Make it |
| `homelab_job_last_exit_code` is 75 for `offsite-copy` | The `backups` lock was held for the full wait — a weekly archive was running | Wait for it and run again; the lock exists so a set is never copied while retention is removing it |
