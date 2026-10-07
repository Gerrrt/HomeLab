# ADR-0064: Copy Immich's library to oracle until the off-estate copy exists

**Status:** Accepted · 2026-09 · interim; to be superseded by the record that
closes [#455](https://github.com/Gerrrt/HomeLab/issues/455). It does **not**
satisfy [ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md),
and it amends nothing in it.

> [!NOTE]
> **The sets open with the household's keys too, 2026-10-01.**
> [ADR-0073](0073-carry-the-household-copy-on-a-drive-the-holder-keeps.md)
> encrypts every library set to `stacks/sensitive/household.recipients` as
> well as to the sensitive rule, so these sets are the ones the household drive
> carries. "Encrypted to `trinity`'s key alone" below no longer describes a new
> set. This record is superseded as the stand-in on the first
> `household-proof`, not before. Its nightly copy to `oracle` continues after
> that.
>
> **The copies on `oracle` are re-verified nightly, from `trinity`,
> 2026-10-07.** Before [#856](https://github.com/Gerrrt/HomeLab/issues/856) a
> set was verified the night it was written and never again, here or there.
> `homelab-verify-backups-sensitive` now runs `make verify-backups
> STACK=sensitive` at 06:30. It decrypts and reads every retained library set
> on `trinity`, then has `oracle` sha256 every archive it holds and compares
> each hash with the set's MANIFEST on `trinity`. It also compares each
> MANIFEST byte for byte. That answers where the far side is verified: from
> `trinity`, which holds the key, by a check that decrypts nothing on
> `oracle`, which holds none ([ADR-0015](0015-give-oracle-the-off-host-jobs.md)).
> A copy with the same bytes as a set that has just decrypted is the same
> backup, so nothing on `oracle` needs a key or a timer of its own. The tier's
> volume sets on `oracle` get the same check in the same run.

## Context

ADR-0023 classes Immich as **Durable**: it may be down, it may not be lost,
and an off-estate copy whose staleness is visible was to exist before the
first real photo arrived. The photos came first. On 2026-09-28 two accounts
uploaded 615 assets to `trinity`
([#132](https://github.com/Gerrrt/HomeLab/issues/132)), while #455's drive
was still undelivered and nobody had been chosen to hold its key. The stack
README records that as a warning, and it is the reason for this record.

What protected those photographs that evening was one disk. `make backup`
covers `immich-db`, the metadata, and has copied it to `oracle` nightly
since #404 step 9. The originals are a different thing. They are a bind mount on
`trinity`'s 2 TB USB disk, and `backup-volumes.sh` archives named volumes, so
no set could hold them. A single USB disk failing would have taken every
photograph in the house and left a database that remembered all of them.

Issue #455 cannot close this quickly, and nothing in this record tries to close it.
Its drive is late (#665), and its first condition is a person, not a key: who
holds the household's copy, which decides the key and then the filesystem.
Both are decisions for a person, and neither should be taken under pressure
because a disk might fail meanwhile. So the question here is narrower: what
protects the photographs **until** #455 exists, without pretending to be it.

Measured on 2026-09-29:

- The library to protect (`library/`, `upload/`, `profile/`, `backups/`) is
  1.5 GB.
- Thumbnails and transcodes are 263 MB, and Immich regenerates them.
- `oracle` has 54 GB free on its root LV (`df -Pk`), with ~362 GB of the
  volume group unallocated
  ([ADR-0015](0015-give-oracle-the-off-host-jobs.md)).

## Decision

**A nightly, age-encrypted copy of the library to `oracle`, by a script of
its own: `scripts/backup-library.sh`, `make backup-library`, timer
`homelab-backup-library` at 05:15.** It covers:

- **What each set holds.** One archive, `immich-library.tar.gz.age`, with:
  - `./upload` and `./library`, the originals;
  - `./profile`;
  - `./backups`, which is Immich's own 02:00 `pg_dump`;
  - the `.immich` markers of `./thumbs` and `./encoded-video`, and nothing
    else from those two trees.

  Each set is therefore a complete restore unit on its own, with the database
  first and the files second (upstream's order). The derived trees are left
  out, and a restore regenerates them.
- **The format is the estate's standard set.** A `MANIFEST` is written last,
  with a sha256 per archive. The archive is encrypted to every recipient of
  `secrets/sensitive.sops.yaml`, then verified by decrypting it. It is copied
  to `oracle:backups/immich-library` by `backup-volumes.sh`'s own helpers:
  `.part` then rename, a far-side sha256, and the `MANIFEST` compared byte
  for byte. The script sources that file, as `backup-nas.sh` does, and
  `immich-library` is an archive name in its sentinel table.
- **Nothing is stopped.** Originals are written once, and the dump is finished
  three hours before the run. A file that changes during the read, which
  means an upload landed, discards the archive and reads it again, up to
  three times.
- **Two sets on each side (`LIB_KEEP=2`).** Every set is the whole library,
  and `oracle`'s root volume is the limit. Protection against deletion is
  Immich's own thirty-day trash, not this copy.
- **Room is a precondition, not a hope.** Before any tar runs, the far side
  is asked for `df`. The run is refused if one more set would leave less than
  15 GiB free on `oracle`'s root LV, which also holds its other sets and its
  dead man's switch. The refusal fails the job, and the failure is a
  `ScheduledJobFailed`.
- **`--prove` is the restore claim, made about a set.** It streams the
  newest set through Python's `tarfile`, with no plaintext on a disk. Every
  original the live database names is SHA-1'd against `asset.checksum`.

## What this is not

- **Not off-estate.** `oracle` is on the same shelf, in the same room, on
  the same power and the same roof. A fire, a flood or a theft takes the USB
  disk, `trinity`'s SSD and `oracle` together. ADR-0023's *Durable* row is
  unmet, and its *Independent* test is unrun. The warning in
  `stacks/sensitive/README.md` stays.
- **Not the household's recovery path.** Every set is encrypted to
  `trinity`'s key alone, because that is the only recipient of the sensitive
  rule today. The copy on `oracle` survives `trinity` only if that key has a
  proven copy of its own, which is `make secrets-verify-backup
  STACK=sensitive`. ADR-0023's requirement, a key the operator does not
  solely hold, is untouched.
- **Not a second mechanism for #455 to replace.** The sets are the standard
  format so #455 can carry them. When a recipient ADR-0023 accepts joins the
  sensitive rule, every later set opens with that key, and
  `backup-offsite.sh` gains one more kind of set to carry to the drive. This
  script does not change.

## Alternatives considered

**Fold the library into `make backup`'s volume sets.** Rejected. Those sets
are derived from named volumes and stop their owners, so every service
behind them — Vaultwarden among them — would stay stopped while photographs
were tarred. `KEEP=7` would also put seven copies of the library on
`oracle`, which would be full before the library passed 6 GB.

**restic, or an age-encrypted per-file mirror.** Either scales to hundreds of
gigabytes better than full sets do, and neither is needed at 1.5 GB:

- restic brings a repository password, which is a new secret, and a format
  an age recipient cannot open. That makes it no help to #455.
- A per-file mirror leaks the library's shape (`library/<user>/<year>/…`),
  and it would be a third set format with its own deletion semantics.

When full sets stop fitting, this record has expired anyway.

**Wait for #455.** Rejected, because this is the one exposure that grows every
day. Waiting would have left a disk failure costing every photograph until a
parcel arrives and a person is chosen.

## Consequences

- **The photographs exist on three disks, not one:** the USB disk, two sets
  on `trinity`'s SSD, and two on `oracle`. The first real run, on 2026-09-29,
  wrote 615 originals in 1.5 GB in 68 s and copied them in about three
  minutes. `--prove` read `ok=615 bad=0`. The set was then restored from
  `oracle` into scratch containers, and the rehearsal is in the restore
  runbook.
- **`oracle` holds household photographs**, as ciphertext and without a key,
  which is ADR-0015's rule for everything it holds. The ssh key that writes
  there can also delete there, as it can for every set on `oracle`.
- **The reserve is the expiry.** When the preflight refuses, one of two
  things happens. Either #455 has landed and this record is superseded, or
  `oracle` gets an `lvextend` from its unallocated space
  ([ADR-0015](0015-give-oracle-the-off-host-jobs.md)) and this record is
  re-read. A nightly full copy of about 20 GB, around half an hour on
  `oracle`'s 100 Mb/s link, is the same signal.
- **Nothing changes on the estate's side.** No firewall rule is added, and
  no credential: the copy uses the same ssh key and the same far-side account
  as the volume sets.
