# Wiki stack

The Lemmiwinks wiki: Wiki.js and its Postgres, on `oracle` (`10.0.99.30`,
VLAN 99). It is the middle of [ADR-0011]'s three documentation tiers, the one
the household reads, on the host [ADR-0015] ratified for it. It has run there
since 2025-11-12, created by hand with `docker run` and described by nothing
until this directory ([#251]).

| Service | Container | Port | Purpose |
| --- | --- | --- | --- |
| app | `wiki-app` | 80 → 3000 (http), to the segment and to Hicks | Wiki.js 2, at `http://lemmiwinks.matrix.elysium` |
| db | `wiki-db` | none | Postgres 17, the wiki's only state |

## Deploying a change

`make up STACK=wiki` does **not** work on `oracle`. It renders a secrets file
this stack does not have, and `oracle` holds no age identity and must not get
one: [ADR-0015] put the estate's ciphertext there on the condition that no key
which opens it sits beside it. This is [`stacks/media`](../media/README.md)'s
shape ([#528]). A change reaches `oracle` by fetching the two files from
`main` and running compose there, by hand. Nothing on `oracle` pulls from
`main` on its own, so a Dependabot bump merged here is deployed by this, or
not at all:

```bash
cd /opt/wiki && curl -fsSLO https://raw.githubusercontent.com/Gerrrt/HomeLab/main/stacks/wiki/compose.yaml && docker compose up -d
```

`.env` is a copy of [`.env.example`](.env.example), made once, and holds a
path and nothing secret. Re-fetch it only if `.env.example` changed.

## The one secret

`/etc/wiki/.db-secret` on `oracle`: the `wiki` role's password, which Wiki.js
reads itself (`DB_PASS_FILE`). It is owned by uid 1000 and is mode `0400`.
uid 1000 is `node` inside the pinned image and the operator's account on
`oracle`, so the container can read it and no other account can. Until
2026-09-30 it was `0664`, readable by every account on the machine. It is
mounted into the app alone. Postgres reads a password only to initialise an
empty cluster, and see [Restore](#restore) for the one time that happens.

## What is backed up, and what is not

**The database, nightly, as a `pg_dump`, pulled off `oracle` by `prometheus`**
([ADR-0065]). [`scripts/backup-wiki.sh`](../../scripts/backup-wiki.sh) runs
on `prometheus` at 04:45 and dumps `wiki-db` over ssh. It encrypts the dump
there to the estate's two recipients and proves it decrypts and is a
`pg_dump`. Fourteen sets are kept in `backups/wiki/`. Nothing on `oracle`
stops, and nothing plaintext lands on either disk. `make verify-backups`
re-reads every set each morning, and the generic `ScheduledJob*` rules alert
if the job fails or stops.

```bash
make backup-wiki ARGS=--prove
```

That command, on `prometheus`, restores the newest set into a scratch Postgres
and counts it against what the set's MANIFEST recorded.

**Nothing else**, by decision. Everything under `/wiki/data` is derived from
the database or from GitHub. `repo/` is a clone of `Gerrrt/Lemmiwinks`,
`secure/` holds the deploy key Wiki.js writes out of the database on each
start, and `cache/` is a render cache. `compose.yaml`'s header has the
measurements. The pages are in GitHub regardless, so what the dump protects is
everything else: accounts, history, navigation and settings.

A set holds the git storage target's deploy key, because the database does.
It is ciphertext to the same keys that open `grafana.db`.

## Restore

A set is `wiki-db.tar.gz.age`, a gzipped `pg_dump -Ft`. To put it back:

1. **Onto the running cluster** (a bad edit, or a lost account). Decrypt on
   `prometheus`, which holds the key, and stream the dump across to `oracle`,
   which does not, so the plaintext never lands on a disk:

   ```bash
   age -d -i ~/.config/sops/age/keys.txt backups/wiki/<STAMP>/wiki-db.tar.gz.age | gzip -dc | ssh atropos@10.0.99.30 docker exec -i wiki-db pg_restore -U wiki -d wiki --clean --if-exists --no-owner
   ```

   Run `docker compose stop app` on `oracle` first and `docker compose start app` after, so
   Wiki.js does not write between the `--clean` and the load.

2. **Onto an empty volume** (a new disk, or a new host). The role and its
   password are not in a dump, so the cluster must be initialised with the
   password in `/etc/wiki/.db-secret` before the restore. It is passed for one
   `up` and never written down:

   ```bash
   docker volume create pgdata
   ```

   ```bash
   WIKI_DB_BOOTSTRAP_PASSWORD="$(cat /etc/wiki/.db-secret)" docker compose up -d --wait db
   ```

   ```bash
   docker compose up -d --wait db
   ```

   The second `up` recreates `db` without the variable. The cluster is
   initialised and ignores its absence from then on. Then restore as in (1),
   and `docker compose up -d`.

   Rehearsed on `oracle` on 2026-09-30 against a scratch project, with this
   file's hardening. The bootstrap, the restore of a dump of the live
   database (108 pages, 4 users), the app booting read-only and healthy, and
   a page rendering all worked. The git storage target was disabled in the
   scratch copy first, so the rehearsal could not push to `Lemmiwinks`. Do
   the same in any rehearsal:

   ```sql
   update storage set "isEnabled" = false;
   ```

## Upgrading

A Wiki.js bump is a Dependabot PR and the fetch above. A Postgres **major**
is not a bump, and Dependabot ignores majors for this stack. It is a restore:
take a set, point `db` at a new empty volume and a new image, and restore
into it as in (2) above. A dump restores into a newer Postgres, and the
on-disk cluster does not.

The update companion that ran beside the old container is gone on purpose.
It held the Docker socket and recreated Wiki.js from the floating `2` tag,
outside any compose file, which would undo every pin here the day it worked.

## The cutover

**Run on 2026-09-30.** The wiki was down for about a minute, from 13:54:32
to 13:55:36 UTC.

- **The old containers.** `wiki` ran from the `2` tag with `UPGRADE_COMPANION=1`,
  its content directory on an anonymous volume, and 80 and 443 published.
  `db` ran from the `17` tag with the password file mounted and the named
  volume `pgdata`. Both were on a bridge network, `wikinet`. Alongside them
  were `wiki-update-companion`, exited, and `node_exporter`, from
  `prom/node-exporter` at `latest`, exited ten months earlier and
  superseded by the Alloy agent.
- **First, a set.** On `prometheus`, `make backup-wiki WIKI_DB_CONTAINER=db`
  wrote `20260930T133451Z` from the old container: 5.1 MB, 34 entries,
  `toc.dat` present. `ARGS=--prove` restored it into a scratch 17.6 and
  counted pages=108 users=4. The primed timer run before it had been
  refused, correctly, because `wiki-db` did not exist yet. It left an empty
  `backups/wiki/` that failed `verify-backups`, which
  [#757](https://github.com/Gerrrt/HomeLab/pull/757) fixed.
- **Then the host.**
  - `/etc/wiki/.db-secret` went from `0664` to `0400`, owned by `1000:1000`
    as before.
  - The two files were fetched into `/opt/wiki`, created by `sudo install`
    and owned by `atropos`.
  - `wiki` and `db` were stopped and removed without `-v`, and
    `docker compose up -d --wait` brought up `wiki-db`, then `wiki-app` 8 s
    later, both healthy. `pgdata` was adopted, not recreated.
- **Checked.**
  - `http://10.0.99.30/`, `http://lemmiwinks.matrix.elysium/` and a page
    answered 200, and `wiki-db` counted 108 pages and 4 users.
  - Git sync started, fetched, rebased and "pushed" nothing: the clone's
    head was still `7a7176b`, level with `origin/main`.
  - Neither container has an anonymous volume.
- **Removed:** `wiki-update-companion`, `node_exporter` and `wikinet`, which
  had nothing attached. `docker ps -a` on `oracle` now lists `wiki-app`,
  `wiki-db` and `alloy`, and nothing else.
- **Removed later the same day:** the old container's anonymous volume
  `eed420de7438…`, which was empty, once the first set taken from `wiki-db`
  had passed `--prove`. That was the last step of [#251].

  The old containers' `docker inspect` was saved before they were removed,
  in case a rollback ever needed them.

[ADR-0011]: ../../docs/adr/0011-keep-the-wiki-internal.md
[ADR-0015]: ../../docs/adr/0015-give-oracle-the-off-host-jobs.md
[ADR-0065]: ../../docs/adr/0065-pull-the-wikis-database-to-prometheus-as-a-dump.md
[#251]: https://github.com/Gerrrt/HomeLab/issues/251
[#528]: https://github.com/Gerrrt/HomeLab/issues/528
