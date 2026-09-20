# ADR-0045: Pull Jellyfin's state off `smaug` from a ZFS snapshot, over the rule already written for it

**Status:** Accepted · 2026-09 · supersedes the *Backups* clause of
[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md) and
writes the first snapshot schedule decision 4 of
[ADR-0040](0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)
asked for

## Context

[`build-the-nas.md`](../runbooks/build-the-nas.md) §4 splits the pool into
two datasets and calls the split *"the backup decision made deliberately
rather than drifted into"*: `erebor/media`, the library, is not backed up,
and `erebor/apps`, Jellyfin's state, is. The reasoning is ADR-0008's and it
is sound — the library is replaceable and its loss *"annoying rather than
catastrophic"*; the watch history, the resume positions, the accounts and how
the library is organised are not, and *"re-acquiring a series does not
restore which episode you were on, and that is measured in megabytes"*.

**Nothing implemented the yes**
([#484](https://github.com/Gerrrt/HomeLab/issues/484)). Three files claimed
it: §4's table, the `jellyfin-config` comments in
[`stacks/media/compose.yaml`](../../stacks/media/compose.yaml), and the
backup table in [`stacks/media/README.md`](../../stacks/media/README.md),
the last two naming `scripts/backup-volumes.sh` as the mechanism. That script
had no sentinel for the volume, so `STACK=media` died at its inventory; it
runs against the Docker daemon on the monitoring host, which cannot see
`smaug`'s; and it verifies by decrypting, which needs the age identity, which
must not be on the NAS. Two documents asserting a backup no script performs
is worse than no backup — the next reader has no reason to look — and it is
the shape [#428](https://github.com/Gerrrt/HomeLab/issues/428) found in the
sensitive tier, arriving a second time.

Then the deploy found one more thing. As brought up on 2026-09-19, Jellyfin's
`/config` was a Docker **named volume**, and TrueNAS keeps named volumes on
the pool it was given for Apps, in `erebor/ix-apps/docker`. So the dataset §4
called backed up held the compose file and its `.env` and nothing Jellyfin
writes.

### What the estate already decided about this host

Everything about the mechanism was constrained before the question was asked,
which is what makes the answer small:

- **CasaBonita is terminal-outward** (ADR-0016), and the `igc0.40` tripwire
  ([#223](https://github.com/Gerrrt/HomeLab/issues/223)) exists to prove it
  stays that way. Nothing on `smaug` may initiate anything. Every other host
  in the estate is monitored and backed up by *pushing*; this one is scraped,
  and ADR-0016 said its metadata backup would be *pulled* too.
- **The rule for the pull exists.** ADR-0016's table wrote
  `10.0.99.20 → 10.0.40.30:22` for *"`prometheus` pulling the metadata
  backup"*; it was created on 2026-09-16, verified in position with `pfctl`,
  and has been inert since, because TrueNAS ships SSH disabled and §0.5 said
  to turn it on *"when the backup path is actually built, not before"*.
- **`smaug` cannot run `backup-volumes.sh`** and must not be made able to. It
  has no `age`, no repository checkout, an immutable root, and — by design —
  no key that opens anything.
- **The storage layer is clicks** (ADR-0040 decision 4), recorded in a
  runbook as it is created, and no snapshot schedule had been recorded yet.
- **Off-host means `oracle`** (ADR-0015), and the copy of the volume sets to
  it landed the same day this was written
  ([#535](https://github.com/Gerrrt/HomeLab/issues/535)): a step of the
  weekly job, verified there by hash, pruned there to the same `KEEP`, with
  its helpers in `backup-volumes.sh`.

### Three candidate mechanisms

The issue named them. A **second rule on the `9100` path**, so the scrape's
neighbour carries the backup. **The inert port-22 rule**, switched on for
its written purpose. **TrueNAS's own replication or cloud-sync tasks**, which
would put a second backup mechanism in the estate, outside `age`, outside the
sentinel verification and outside the reach of CI and the `ScheduledJob*`
rules — the same boundary ADR-0040 accepted for the pool layout, to be
accepted or rejected on purpose.

And a fourth question the deploy added: bind `/config` to a path under
`erebor/apps`, or back up `ix-apps` as it is.

## Decision

**1. The monitoring host pulls, over `10.0.99.20 → 10.0.40.30:22`, and
encrypts what arrives.** [`scripts/backup-nas.sh`](../../scripts/backup-nas.sh)
runs on `prometheus` on `homelab-backup-nas.timer`, weekly, opens one ssh
session to `smaug`, and streams `tar --numeric-owner -czf -` of one directory
straight into `age -r` for the estate's two recipients — the same two that
open `grafana.db`, read from the observability stack's secrets file by
`key-recipients.sh`, because this stack has none and
[#528](https://github.com/Gerrrt/HomeLab/issues/528) owns whether it ever
does. Plaintext exists only inside the ssh session; nothing unencrypted
touches the monitoring host's disk. The archive is verified the way every
other archive in the estate is: decrypted, read to the end, and checked for
the one entry that proves it is Jellyfin's config directory and nobody
else's — `./data/jellyfin.db`, read off a boot of the pinned image on
2026-09-19 and recorded in `backup-volumes.sh`'s sentinel table, which
`backup-nas.sh` sources rather than copies.

**2. `/config` is a bind mount on `erebor/apps`, at
`/mnt/erebor/apps/jellyfin/config`.** A directory, not a child dataset — a
child would need the snapshot task below to be recursive and would be a
second thing to record. This makes §4's table true rather than aspirational,
and it gives the pull a path a snapshot can name. `jellyfin-cache` stays a
named volume on `ix-apps`, and is listed as disposable by name in
`backup-volumes.sh`, so that script now says the true thing about this stack
— nothing here is its to archive — instead of dying. The state that existed
before this decision is migrated, not abandoned: §6 of the runbook copies
the named volume's contents into the bind path before the compose change is
applied there.

**3. A nightly ZFS snapshot of `erebor/apps` is the quiesce, and Jellyfin is
never stopped.** TrueNAS's periodic snapshot task — daily, not recursive,
named `auto-%Y-%m-%d_%H-%M` in the host's zone, two weeks' retention, empty
snapshots allowed — is the first entry in the snapshot schedule ADR-0040
decision 4 said would be written into the runbook as it was created, and §4
now carries it. The pull reads `/mnt/erebor/apps/.zfs/snapshot/<newest>/jellyfin/config`.
A snapshot is atomic across the dataset, so `jellyfin.db`, its `-wal` and its
`-shm` are captured at one instant: the crash image SQLite's WAL mode is
built to recover from. That is a stronger claim than `backup-volumes.sh
--hot` can make of a live volume, and a weaker one than a quiesced set's,
and the manifest says `snapshot` rather than `quiesced` so nobody reads it
as the latter. Two rules follow. `tar` cannot see a file change on a
snapshot, so its exit 1 is treated as the premise breaking and fails the run.
And **a snapshot that has stopped being taken is a backup that has silently
stopped being current**, so the run reads the newest snapshot's age from its
name and fails, naming it, when that exceeds two days — twice the task's
period, the estate's own rule for every other threshold.

**4. The far side is one unprivileged user with one key.** `frodo`, on
`smaug`: SSH key only, password disabled, no SMB, no sudo, and read access to
`erebor/apps` and nothing else. The key is the monitoring host's operator
key, the one that already reaches `morpheus` and `oracle` — the precedent
`homelab-smart-state-remote.service` set. SSH on `smaug` is switched on for
this and nothing else: key authentication only, no root, no forwarding, and
the firewall already scopes it to `10.0.99.20`. The **fallback**, named and
not built: if Jellyfin ever writes a file `frodo` cannot read, the run fails
loudly with tar's exit 2 rather than writing an archive with a hole in it,
and the remedy is a passwordless-sudo entry for one fixed wrapper script —
never the Docker socket, which is root, and never `sudo zfs`, which is the
pool.

**5. The set lands in `backups/nas/` on `prometheus`, beside the volume
sets, and leaves by the same road.** Not in `backups/volumes/`: the nightly
verification there checks a set against the observability stack's derived
volume list and would refuse a media set, and the two retentions would count
against one `KEEP`. One `make verify-backups` walks both directories, so
the existing timer proves both kinds of set and no second unit is added. The
copy to `oracle` is a step of the same run, by #535's helpers — `backup-nas.sh`
sets the far side to `backups/nas` before it sources them, so the volume
unit's `VOL_OFFHOST` is never inherited — and a run whose copy fails exits
non-zero after the local set is complete, exactly as the volume job does.
`oracle` holds ciphertext for three kinds of artefact now and a key for none.
Off-host is still not offsite: the same shelf, the same room, and a fire
takes all three.

**6. What is not backed up is written where the stack is.** `erebor/media`,
by ADR-0008. `jellyfin-cache`, by name in `backup-volumes.sh`'s table.
`erebor/ix-apps`, Docker's images and that cache volume. The compose file,
`.env.example` and the README each say so, and `STACK=media
backup-volumes.sh --inventory` reports nothing to archive rather than
claiming otherwise.

### Three declines

**Not a second rule on the `9100` path.** The scrape rule is scoped to the
scrape port on purpose, and ADR-0016 already wrote a rule for this exact
job. Adding a rule to avoid using the one written for the purpose would
leave the inert rule inert forever, with its written reason unfulfilled.

**Not TrueNAS replication or cloud-sync.** Both are `smaug`-initiated. A
replication target on VLAN 99 needs a `40 → 99` pass — the first upward path
in the estate, the end of terminal-outward, and a tripwire that stops
reading zero. And the copy would land as ZFS streams or rclone objects:
outside `age`, outside the sentinel check, outside `ScheduledJobFailed`,
outside `make validate`. ADR-0040 accepted that boundary for the pool
*layout*, which cannot be otherwise; it is not accepted for the *backup*,
which can.

**Not encrypting on the NAS.** ADR-0016 said the archive would be encrypted
*"on the NAS with `age -r`"*. It is encrypted on `prometheus` instead.
TrueNAS has no `age`, and there is nothing a copy of it on the NAS would
buy: `age -r` needs only the recipients, which are public keys, and the
property ADR-0016 wanted — *"a VLAN 40 host holds ciphertext and no private
key"* — is stronger this way, since `smaug` holds no archive at all. What
crosses the wire is inside ssh; what lands is ciphertext.

## Consequences

- **SSH is on, on `smaug`.** One service the host did not run, reachable
  from one address on one port by one user with one key, and
  [`security.md`](../security.md) carries it as the residual it is. Turning
  it on is a step of the runbook with this ADR as its written reason, which
  is what §0.5 asked for.
- **The storage layer gained its first recorded schedule.** ADR-0040 said the
  snapshot schedules would be written down as they were created; §4 now has
  one, and the pull depends on its settings — the naming schema, the
  cadence, the empty-snapshot flag — in ways the runbook spells out, so
  changing the task in the UI without reading §4 fails the next run by name
  rather than silently.
- **`backup-volumes.sh` is a library as well as a script.** It returns when
  sourced, just before parsing its arguments, so `backup-nas.sh` reuses the
  tables, `verify()`, the set helpers and `prune()` rather than restating
  them — one sentinel table and one set of assertions, which is the position
  `restore-volumes.sh` already took. Nothing above that line may gain a side
  effect, and the file says so.
- **`verify-backups` fails until the first NAS set exists.** The nightly
  target walks both directories, so from the day the timers are reinstalled
  until §6.2's first `make backup-nas`, it reports *no complete sets in
  backups/nas*. The runbook orders the first run before the reinstall for
  that reason.
- **The set is off-host twice and offsite never.** It leaves `smaug` for the
  monitoring host and leaves that for `oracle` in the same run; every copy
  is on one shelf. What remains for it is what remains for the export and
  the volume sets.
- **The issue closes on deploy, not on merge.** Every mechanism here is
  bench-tested against a directory on `oracle` over real ssh; none of it has
  touched `smaug`, whose SSH is still off when this merges. §6.2 of the
  runbook is the checklist, and its Done block is where the date goes.
