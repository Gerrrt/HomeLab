# ADR-0050: Add Audiobookshelf to the media tier behind a fifth Hicks pass, and pull its state with Jellyfin's

**Status:** Accepted · 2026-09 · adds a service to the tier
[ADR-0008](0008-place-services-by-data-trust.md) created, a rule to the four
[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md) became,
and a second archive to the pull
[ADR-0045](0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md) built;
decides [#140](https://github.com/Gerrrt/HomeLab/issues/140)

## Context

[#140](https://github.com/Gerrrt/HomeLab/issues/140) proposed Audiobookshelf,
an audiobook server with its own phone apps, for one property Jellyfin lacks:
**listening progress that follows a person between devices.** Jellyfin tracks
position the way it tracks a film, and nobody listens to a twenty-hour book in
one room.

ADR-0008 does not name it. Its test is the trust of the data, not the
function, and an audiobook library is the same kind of data as the films on
the same pool: replaceable, and annoying rather than catastrophic to lose. So
the placement is not in question. The issue said it was a small addition to a
box being built anyway, and that it needed **"no new rule beyond the 50→40
that #138 already adds"**.

That last clause is wrong, and it is the reason this is an ADR rather than a
changelog line. There is no 50→40 rule. There are two Hicks passes, one per
port — `Allow HTTPS to smaug` on `443` and `Allow 8096 to smaug` —
host-scoped and port-scoped, as ADR-0016 asked of every rule into CasaBonita,
and as [`build-the-nas.md`](../runbooks/build-the-nas.md) §0.5 created them on
2026-09-16. The SMB share found the same edge by trying on 2026-09-18
([#523](https://github.com/Gerrrt/HomeLab/issues/523)). Audiobookshelf listens
on `13378`. And Jellyfin's argument for publishing to its segment was that its
clients are televisions *on* that segment; Audiobookshelf's clients are phones,
and the phones are on Hicks ([`network.md`](../network.md)). **This is the
first service on the NAS whose only real consumers are across a segment
boundary.**

The backup has the same shape of problem. ADR-0045's pull reads one directory,
`jellyfin/config`, into one archive. Audiobookshelf's state — the database that
holds every listener's position, which is the thing this service exists for —
would sit on `erebor/apps`, be snapshotted every night, and never leave the
NAS.

Measured on the pinned image on 2026-09-22, read-only as `65534`:

- It declares no user and binds `PORT=80`, which a process with no
  capabilities cannot. `PORT=13378` in the environment fixes both at once.
- `/config` holds `absdatabase.sqlite` in rollback-journal mode, not WAL;
  `/metadata` holds covers, per-item metadata, logs and transient transcode
  segments. Neither directory exists in the image.
- Its own scheduled backups are off by default.
- 91 MiB idle RSS, 119 MiB with a transcode running.

## Decision

1. **Audiobookshelf joins `stacks/media` on `smaug`**, in Jellyfin's shape:
   non-root, `read_only`, `cap_drop: ALL`, pinned by digest, healthchecked
   with what the image ships, and a memory ceiling over a measured number.
   Its state is two bind mounts under one directory on `erebor/apps`, which
   the nightly snapshot already covers.

2. **A fifth pass: `vlan50 net → 10.0.40.30:13378`**, described
   `Allow 13378 to smaug`, above *Block access to CasaBonita* on Hicks. It is
   a rule of its own and not a port added to the `8096` rule, for the reason
   the Hicks pair is split: §0.6 matches on the description. Its named
   consumer, as [ADR-0012](0012-publish-only-ports-with-an-off-host-consumer.md)
   requires, is the household's phones. It is **created when the service is
   deployed** (§6.5), not when this merges — a pass to a port nothing answers
   on cannot be proved.

3. **Audiobooks only. Podcasts are deferred, not declined.** Auto-download is
   the one feature that makes this service reach out on a schedule, and it
   needs a folder it can write into on `erebor/media`. The library is mounted
   read-only, for Jellyfin's reason — a server on the segment with the game
   consoles should not be able to delete what it serves — and that mount is
   what makes podcasts impossible rather than merely unused. This reopens
   when someone wants a podcast on this server rather than in a phone's own
   app. The answer then is a separate writable folder under `erebor/media`,
   so the audiobook library stays read-only, and a note in `security.md`
   that the segment now fetches on a timer. CasaBonita has internet egress
   already, so this is a data-path change, not a firewall change.

4. **The pull carries one archive per service, all from one snapshot, in one
   set.** `scripts/backup-nas.sh` reads a table of archive → subpath rather
   than one path. Audiobookshelf's is `audiobookshelf-state`, the parent of
   its two mounts, with `./config/absdatabase.sqlite` as its sentinel. A set
   is every archive or no MANIFEST, as before. Verification reads each set
   against its own MANIFEST, so the sets written before this hold
   `jellyfin-config` alone and are still complete.

5. **A service authored before it is deployed is `pending` in that table.**
   `stacks/media` is deployed by hand, later, and Audiobookshelf's deploy
   waits on the mirror being whole
   ([#558](https://github.com/Gerrrt/HomeLab/issues/558)). A pending row whose
   directory is absent from the snapshot is skipped, and the skip is logged by
   name. A pending row whose directory is present is pulled and verified like
   any other. The deploy's Done commit flips it to `required`. After that, a
   missing directory fails the run. Without this, merging the service would
   have failed every Saturday's Jellyfin pull until the deploy. With it, the
   repository still states in plain text whether the service is deployed.

6. **No secrets file**, by [#528](https://github.com/Gerrrt/HomeLab/issues/528)'s
   reasoning: the root user is created in the first-run screen and kept as a
   hash in the database, where no environment variable reaches. The way back
   in without the password was measured. Stop the container, clear the root
   user's hash with a one-off `node` against the database, then sign in with a
   blank password and set a new one.

## Consequences

- **Hicks reaches one more port on the NAS.** The service behind it requires
  a login for everything but its health and status endpoints. Everything on
  CasaBonita reaches it natively as well, as it reaches `8096`.
- **The monitoring host still reaches `9100` and `22` and nothing else.** It
  cannot probe `13378`, so the container healthcheck is the only liveness
  check, which is the position Jellyfin is in
  ([#570](https://github.com/Gerrrt/HomeLab/issues/570)).
- **`frodo` reads one more directory**, and it includes the Audiobookshelf
  users' password hashes. What lands on the monitoring host is ciphertext to
  the same two recipients as before. ADR-0045's stated limit grows by one
  service, and its shape does not change.
- **Every set grows by the size of the database and the metadata**, which is
  kilobytes on a first boot and megabytes on a real library. ABS's own
  auto-backups stay off so the sets do not also carry zipped copies of the
  same database.
- **The skip in decision 5 is the one place the pull does less than its table
  says**, and it is bounded. It applies only to a row the repository marks
  pending, and only while that row's directory does not exist. Each skip
  prints a line naming §6.5.
- **ADR-0016 and ADR-0045 are not superseded.** ADR-0016's rule set grows by a
  row of the same kind, and ADR-0045's mechanism stays the same apart from
  reading a list where it read one path. Both gain a pointer here.
