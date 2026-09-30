# ADR-0065: Pull the wiki's database to prometheus as a dump

**Status:** Accepted · 2026-09

## Context

The Lemmiwinks wiki has run on `oracle` since 2025-11-12. [ADR-0011] made it
the documentation tier the household reads, and [ADR-0015] ratified `oracle`
as its host. ADR-0015 also named the gap this record closes
([#251](https://github.com/Gerrrt/HomeLab/issues/251)): the containers were
created by hand, nothing described them, nothing redeployed them, and nothing
backed up their data.

Reading the host on 2026-09-30 narrowed what "their data" means:

- The **database** is 18 MB: 108 pages, 780 revisions, 4 users, the
  navigation, every setting, and the git storage target's configuration,
  deploy key included.
- **Everything else is derived.** The anonymous volume that ADR-0015 worried
  about, `/wiki/data/content`, was empty and had been since the image was
  built. The rest of `/wiki/data` is a git clone of `Gerrrt/Lemmiwinks`, a
  render cache, and a key Wiki.js writes out of the database on start. The
  pages are in GitHub regardless.

So the question is how to back up one small Postgres on a host with two
constraints:

- `oracle` holds the estate's backup sets. ADR-0015's condition is that it
  never also holds a key that opens them, so it has no age identity and
  cannot encrypt.
- It is the host those sets are copied **to**. A backup written on `oracle`
  would sit on the one 5400 rpm disk it is meant to protect.

The repository's only Postgres backup mechanism is `backup-volumes.sh`: stop
the container, tar the volume, encrypt it where it runs. It cannot run here
for either reason.

## Decision

**`prometheus` pulls a `pg_dump` off `oracle` every night, encrypts it on
arrival, and keeps it.** The job is
[`scripts/backup-wiki.sh`](../../scripts/backup-wiki.sh), on
`homelab-backup-wiki.timer` at 04:45.

- **Pull, not push**, for [ADR-0045]'s reason one host over. `prometheus`
  already holds the key `oracle`'s `atropos` accepts, the one every off-host
  copy uses, and `atropos` is in `oracle`'s docker group. The dump is
  `pg_dump`'s stdout on `oracle` piped into `gzip` and `age` on `prometheus`,
  so no plaintext lands on either disk. `oracle` gains no key and no job.
- **A dump, not a stopped volume.** This is the first `pg_dump` in the
  repository:
  - `pg_dump` reads one consistent snapshot of a running database, so the
    wiki never goes down for a backup.
  - A dump restores into a newer Postgres, so the 17 → 18 upgrade this stack
    will one day need is a restore of one of these sets, not a second
    mechanism.
  - It is 5 MB, not a data directory.
- **The tar format**, so the set is proven by the same `verify()` as every
  other. It decrypts, the gzip stream parses, and the listing carries the
  sentinel `toc.dat` and no other archive's. `--prove` goes further and
  restores the set into a scratch Postgres from the image `stacks/wiki` pins,
  then counts pages and users.
- **Kept on `prometheus` only.** The set leaving `oracle` is the off-host
  copy. Copying it back to `oracle` would put it on the disk it came from.
  Fourteen sets are kept; at 5 MB each, retention costs nothing.
- **Nothing under `/wiki/data` is archived.** All of it is derived, and
  `stacks/wiki/compose.yaml`'s header lists what and why.

The stack itself becomes [`stacks/wiki`](../../stacks/wiki), deployed the way
`stacks/media` is ([#528](https://github.com/Gerrrt/HomeLab/issues/528)): it
is fetched from `main` and brought up by hand, with no secrets file, because
`oracle` holds no age identity. Its one secret, the database password, stays
in the file on the host that Wiki.js already read it from, now mode `0400`.

## Consequences

- **The wiki's accounts and history exist on two hosts, not one.** They are
  on the same shelf and the same power, like every off-host copy in this
  estate: this protects against `oracle`'s disk, not against the room.
- **Not yet on the offline medium.** `backup-offsite.sh` ([ADR-0048]) carries
  the volume, NAS and firewall sets. Adding the wiki's is its own change, and
  until then a fire takes this set with the rest.
- **Each set holds the git target's deploy key**, because the database holds
  it. The set is ciphertext to the estate's recipients, and the key is a
  deploy key on one repository, rotated from the wiki's admin page and
  GitHub's.
- **The generic scheduling rules cover the job.** `ScheduledJobFailed`,
  `ScheduledJobStale` and `ScheduledJobNeverRan` join on the job name, so no
  rule was written. `verify-backups` re-reads `backups/wiki/` every morning.
- **A dump is not the whole cluster.** Roles and their passwords are not in
  it, so a restore onto an empty volume initialises the cluster with the
  password from `/etc/wiki/.db-secret` first. `stacks/wiki/README.md` has
  the steps, rehearsed on 2026-09-30.
- **The other Postgres databases are unchanged.** `immich-db`,
  `paperless-db-data` and `miniflux-db-data` are still stopped and tarred by
  `backup-volumes.sh`, where they run and where the key is. That works, and a
  dump there would buy the online property at the cost of a second mechanism
  on a host that has a first. This record decides the wiki, and nothing else.
- **The update companion is gone.** It held the Docker socket and recreated
  Wiki.js from a floating tag outside any compose file. With the stack
  pinned, upgrades are Dependabot's, reviewed here and fetched by hand.

[ADR-0011]: 0011-keep-the-wiki-internal.md
[ADR-0015]: 0015-give-oracle-the-off-host-jobs.md
[ADR-0045]: 0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md
[ADR-0048]: 0048-carry-the-estates-backup-sets-with-the-second-recipient.md
