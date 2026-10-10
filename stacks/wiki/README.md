# Wiki stack

[![host: oracle](https://img.shields.io/badge/host-oracle-30363d?style=plastic)](../../docs/network.md#winterfell--vlan-99--management)
[![VLAN 99: Winterfell](https://img.shields.io/badge/VLAN%2099-Winterfell-f85149?style=plastic)](../../docs/network.md#winterfell--vlan-99--management)
![status: live](https://img.shields.io/badge/status-live-2ea043?style=plastic)
[![Wiki.js](https://img.shields.io/badge/Wiki.js-1976D2?style=plastic&logo=wikidotjs&logoColor=white)](https://js.wiki)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?style=plastic&logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-2496ED?style=plastic&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

The Lemmiwinks wiki: Wiki.js and its Postgres, on `oracle` (`10.0.99.30`,
VLAN 99). It is the middle of [ADR-0011]'s three documentation tiers, the one
the household reads, on the host [ADR-0015] ratified for it. It has run there
since 2025-11-12, created by hand with `docker run` and described by nothing
until this directory ([#251]).

| Service | Container | Port | Purpose |
| --- | --- | --- | --- |
| caddy | `wiki-caddy` | 443 (https), and 80, which only redirects to it; to the segment and to Hicks | TLS in front of Wiki.js, at `https://lemmiwinks.matrix.elysium`, on a leaf from the estate's CA ([ADR-0082]) |
| app | `wiki-app` | none (3000, to Caddy) | Wiki.js 2 |
| db | `wiki-db` | none | Postgres 17, the wiki's only state |

## Deploying a change

`make up STACK=wiki` does **not** work on `oracle`. It renders a secrets file
this stack does not have, and `oracle` holds no age identity and must not get
one: [ADR-0015] put the estate's ciphertext there on the condition that no key
which opens it sits beside it. Nor does `homelab-converge` reach it: the agent
pulls on `prometheus` and `trinity` only, each its own stack, and ends in
`make up` ([ADR-0021]).
[ADR-0082] records why this stays a hand step and what would move it.

A change reaches `oracle` from a checkout of this repository, and only once
its commit is proved signed by the same key, by the same comparison, that
`scripts/converge.sh` demands on its hosts. Nothing on `oracle` pulls from
`main` on its own, so a Dependabot bump merged here is deployed by this, or
not at all. It is three steps, because the second needs the commit the first
fetched.

**1. Fetch, from the canonical URL, and name the commit.** Not `origin`,
which is whatever the checkout's config says; `converge.sh` fetches the
canonical URL for the same reason. `FETCH_HEAD` is that commit, and the full
SHA printed is what the next two steps are about:

```bash
cd /opt/wiki/HomeLab && git fetch https://github.com/Gerrrt/HomeLab.git main && git rev-parse FETCH_HEAD
```

**2. Check that commit's CI.** `Lint`, `Validate configs`, `Boot hardened
services` and `Secret scan` must each read `completed success`. The ruleset
already demands it before a merge, and `converge.sh` asks again on its hosts
rather than trust one setting ([#833]); here a human reads the answer. The
query is anonymous, as `converge.sh`'s is:

```bash
curl -fsS -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/Gerrrt/HomeLab/commits/$(git -C /opt/wiki/HomeLab rev-parse FETCH_HEAD)/check-runs?per_page=100&filter=latest" | python3 -c 'import json, sys; [print(r["name"], r["status"], r["conclusion"]) for r in json.load(sys.stdin)["check_runs"] if (r.get("app") or {}).get("slug") == "github-actions"]'
```

Anything else (a failure, a check still running, one missing) is not a
deploy. Wait, or find out why.

**3. Verify it, move to exactly it, and deploy it.** Set `SHA` to what step 1
printed:

```bash
cd /opt/wiki/HomeLab && SHA=<the SHA from step 1> && test -z "$(git status --porcelain)" && test "$(git symbolic-ref --short HEAD)" = main && git verify-commit "$SHA" && test "$(git log -1 --format=%GF "$SHA")" = 968479A1AFF927E37D1A566BB5690EEEBB952194 && git merge --ff-only "$SHA" && test "$(git rev-parse HEAD)" = "$SHA" && docker compose -f stacks/wiki/compose.yaml --env-file /opt/wiki/.env up -d
```

Each `&&` is a refusal, and each closes a different way to deploy something
that was not verified:

- **`git status --porcelain` empty.** An edit or an untracked file in the
  checkout would otherwise ride along with a verified commit. A dirty tree
  is a hard stop for `converge.sh` too.
- **`main` checked out.** The fast-forward moves the branch that is checked
  out, and only `main` is meant to be deployed from.
- **`verify-commit`** fails on a missing or bad signature.
- **The fingerprint test** is the one that matters. A signature names its own
  key id, and `%GF` is empty unless gpg verified it, so comparing it to the
  pin asserts both "verified" and "by GitHub's web-flow key".
- **`--ff-only`** refuses a history that is not a descendant of the one
  deployed.
- **`HEAD` equal to the verified SHA** catches the case `--ff-only` lets
  through: a checkout already *ahead* of it, with a local commit nobody
  signed. The merge says "Already up to date" and succeeds, and only this
  test notices that what compose would run is not what was verified.

Until 2026-10-07 this was a `curl` of `compose.yaml` from
`raw.githubusercontent.com`, which pinned the images by digest and pinned
nothing about the file that named them ([#847]).

`/opt/wiki/.env` is a copy of [`.env.example`](.env.example), made once and
kept outside the checkout, so `git status` there stays clean. It holds paths
and nothing secret. Compare it with `.env.example` after a deploy that changed
that file.

### Setting up the checkout, once

As `atropos` on `oracle`. Import the key and check it is the one meant, as
[`converge-the-host.md`](../../docs/runbooks/converge-the-host.md#import-githubs-signing-key)
does on `prometheus`:

```bash
curl -fsSL https://github.com/web-flow.gpg | gpg --import
```

```bash
gpg --fingerprint 968479A1AFF927E37D1A566BB5690EEEBB952194
```

Then clone over https, which needs no credential, and keep the existing
`.env`:

```bash
git clone https://github.com/Gerrrt/HomeLab.git /opt/wiki/HomeLab
```

The compose project is named `wiki` by the file, not by its directory, so
the first `up` from the checkout adopts the running containers and volumes
rather than creating a second set. The old `/opt/wiki/compose.yaml` is then
unused; remove it so nothing runs from it by habit.

## TLS

Caddy serves the wiki on 443 with a leaf from the estate's CA, and answers
80 with a `308` to the same path on 443, so the http name printed on the card
still lands somewhere ([ADR-0023]). Wiki.js is not published at all. A login
posted to port 80 is redirected before it reaches anything that reads it
([ADR-0082], [#847]).

**Issue the leaf on `prometheus`**, where the CA's key lives and stays
([ADR-0043]):

```bash
make certs ARGS="--host lemmiwinks.matrix.elysium --dns oracle.matrix.elysium --ip 10.0.99.30"
```

The IP SAN is not optional: blackbox probes the address as well as the name,
and so does anyone who types `10.0.99.30`. Carry the two files across. Both
hosts are on VLAN 99, so this is direct, and it is never `certificates/*`:

```bash
scp certificates/lemmiwinks.matrix.elysium.pem atropos@10.0.99.30:/tmp/cert.pem && scp certificates/lemmiwinks.matrix.elysium-key.pem atropos@10.0.99.30:/tmp/key.pem
```

**Then on `oracle`**, into the directory `.env` names:

```bash
sudo install -d -o 1000 -g 1000 -m 0750 /etc/wiki/tls && sudo install -o 1000 -g 1000 -m 0644 /tmp/cert.pem /etc/wiki/tls/cert.pem && sudo install -o 1000 -g 1000 -m 0640 /tmp/key.pem /etc/wiki/tls/key.pem && rm /tmp/cert.pem /tmp/key.pem
```

```bash
cd /opt/wiki/HomeLab && docker compose -f stacks/wiki/compose.yaml --env-file /opt/wiki/.env up -d --force-recreate caddy
```

**The cutover from http, once.** In this order, so nothing points at a port
before it answers:

1. On `morpheus`, add a Hicks pass to `10.0.99.30` on `443/tcp` beside the
   existing `80/tcp` one, then `make backup-firewall` and the row in
   [`network.md`](../../docs/network.md#hicks--vlan-50--trusted).
2. Set up the checkout and the leaf above, then deploy. `wiki-app` gives up
   80 and `wiki-caddy` takes 80 and 443 in the same `up`.
3. In Wiki.js, **Administration → General → Site URL** becomes
   `https://lemmiwinks.matrix.elysium`. Wiki.js builds absolute links and
   its login redirects from it.
4. From `prometheus`, probe both targets through the live exporter before
   the targets file is trusted, the way its header asks. Both, because they
   fail differently: the name tests the resolver, the SNI and the leaf's DNS
   SAN; the address tests `default_sni` and the IP SAN. Each must print
   `probe_success 1` and `probe_http_status_code 200`. The exporter is not
   published on the host, so `localhost:9115` there refuses; it is asked from
   inside its own container, as every other probe in
   [`targets/blackbox.yaml`](../observability/prometheus/targets/blackbox.yaml)
   is:

   ```bash
   docker exec blackbox-exporter wget -qO- 'http://localhost:9115/probe?module=http_2xx_lab_ca&target=https://lemmiwinks.matrix.elysium/healthz' | grep -E '^probe_(success|http_status_code|ssl_earliest_cert_expiry)'
   ```

   ```bash
   docker exec blackbox-exporter wget -qO- 'http://localhost:9115/probe?module=http_2xx_lab_ca&target=https://10.0.99.30/healthz' | grep -E '^probe_(success|http_status_code|ssl_earliest_cert_expiry)'
   ```

5. `curl -si -X POST http://lemmiwinks.matrix.elysium/login` from Hicks
   answers `308` with a `Location: https://…`, and nothing else.

**Renewal** is the same three steps, prompted by `TlsCertificateExpiringSoon`
at 30 days. The leaf lasts 825 days. Blackbox reads the expiry off the
handshake it verifies, so the alert watches what is being served, not a file.

**Trusting it.** A device that has not installed `certificates/ca.pem` warns
on every visit. [`generate-certificates.md`](../../docs/runbooks/generate-certificates.md#4-trust-the-ca-where-you-need-it--and-write-down-where)
§4 has the steps for phones, and the table there is where each install is
written down.

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

A set is `wiki-db.tar.gz.age`, a gzipped `pg_dump -Ft`. Every `docker
compose` on `oracle` below runs in the checkout, `/opt/wiki/HomeLab`, with
the file and the `.env` named as in [Deploying a change](#deploying-a-change).
To put it back:

1. **Onto the running cluster** (a bad edit, or a lost account). Decrypt on
   `prometheus`, which holds the key, and stream the dump across to `oracle`,
   which does not, so the plaintext never lands on a disk:

   ```bash
   age -d -i ~/.config/sops/age/keys.txt backups/wiki/<STAMP>/wiki-db.tar.gz.age | gzip -dc | ssh atropos@10.0.99.30 docker exec -i wiki-db pg_restore -U wiki -d wiki --clean --if-exists --no-owner
   ```

   Run `docker compose -f stacks/wiki/compose.yaml --env-file /opt/wiki/.env stop app` on `oracle` first and `start app` after, so
   Wiki.js does not write between the `--clean` and the load.

2. **Onto an empty volume** (a new disk, or a new host). The role and its
   password are not in a dump, so the cluster must be initialised with the
   password in `/etc/wiki/.db-secret` before the restore. It is passed for one
   `up` and never written down:

   ```bash
   docker volume create pgdata
   ```

   ```bash
   WIKI_DB_BOOTSTRAP_PASSWORD="$(cat /etc/wiki/.db-secret)" docker compose -f stacks/wiki/compose.yaml --env-file /opt/wiki/.env up -d --wait db
   ```

   ```bash
   docker compose -f stacks/wiki/compose.yaml --env-file /opt/wiki/.env up -d --wait db
   ```

   The second `up` recreates `db` without the variable. The cluster is
   initialised and ignores its absence from then on. Then restore as in (1),
   and bring the rest up with the same command and `up -d`.

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

A Wiki.js bump, or a Caddy one, is a Dependabot PR and the deploy above. A Postgres **major**
is not a bump, and Dependabot ignores majors for this stack. It is a restore:
take a set, point `db` at a new empty volume and a new image, and restore
into it as in (2) above. A dump restores into a newer Postgres, and the
on-disk cluster does not.

The weekly CVE scan's issue for this image, [#984], is expected to stay
open. Its findings are in the npm packages that Wiki.js 2.x bundles, and no
2.x image carries their fixes yet, so Dependabot has nothing to propose. The
scan count does not decide when the wiki moves off 2.x. [ADR-0089]'s
triggers do, and its note records why.

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
[ADR-0021]: ../../docs/adr/0021-converge-on-a-timer-instead-of-deploying-over-ssh.md
[ADR-0023]: ../../docs/adr/0023-keep-the-household-recovery-path-outside-the-estate.md
[ADR-0043]: ../../docs/adr/0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md
[ADR-0065]: ../../docs/adr/0065-pull-the-wikis-database-to-prometheus-as-a-dump.md
[ADR-0082]: ../../docs/adr/0082-serve-the-wiki-over-tls-and-deploy-it-from-a-verified-checkout.md
[ADR-0089]: ../../docs/adr/0089-keep-the-wiki-on-wikijs-2-until-a-named-trigger-fires.md
[#251]: https://github.com/Gerrrt/HomeLab/issues/251
[#833]: https://github.com/Gerrrt/HomeLab/issues/833
[#847]: https://github.com/Gerrrt/HomeLab/issues/847
[#984]: https://github.com/Gerrrt/HomeLab/issues/984
