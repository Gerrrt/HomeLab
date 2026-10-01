# Runbook: Restore the sensitive tier

**Target:** the eighteen Docker data volumes on `trinity` (10.0.99.40), VLAN 99 — fifteen of which the backup archives
**Time:** ten minutes for one volume; half an hour for the set on a rebuilt host
**You will need:** a backup set, an age identity the set was encrypted to —
`trinity`'s own key, or the technical second's — and the stack stopped; the
restore script stops it for you

[`restore-the-stack.md`](restore-the-stack.md) is the model for this one and is
not repeated here: the scripts are the same, the phases are the same, and the
reasons a restore is verified before anything is destroyed are argued there.
What is different is what the volumes hold. On the observability host, four of
five volumes are a *record* — metrics and logs that refill on their own. Here,
most are rebuildable or re-fetched from somewhere else and nine are not:

| Volume | What it holds | If it is lost |
| --- | --- | --- |
| `vaultwarden-data` | The vault: every account, every item, every TOTP secret, the RSA key that signs every session | **Lost.** Nothing in git, nothing on another host, nothing regenerates it. This is the one the tier exists to protect |
| `memos-data` | Memos: every account, every note in `memos_prod.db` (and its `-wal`), every attachment under `./assets` | **Lost.** Nothing regenerates it. [ADR-0059](../adr/0059-add-memos-to-the-sensitive-tier-for-notes-and-keep-documentation-in-docs.md) keeps estate documentation out of it, so what is lost is the household's notes, not a way back |
| `home-assistant-config` | Home Assistant's own store: every login, every device credential a config flow produced, the recorder's history. `configuration.yaml` is the repository's and is mounted over it | **Lost**, and re-created by hand: every integration paired again, every credential re-issued by its vendor. ADR-0035 says why these live here and not in SOPS |
| `immich-db` | Immich's metadata: every album, face, tag and the path of every original. The originals are on the USB disk, outside these volumes | **Lost**, unless Immich's own nightly dump beside the originals is intact — [Restore Immich](#restore-immich) below has that route, and it is the one to prefer for a database older than the library |
| `immich-model-cache` | Downloaded ML models | Re-fetched on first use. **Not archived at all** — skipped by name in `backup-volumes.sh`, so it is never in a set and `make up` creates it empty |
| `paperless-media` | Every scanned original, its PDF/A copy and thumbnail | **Lost.** The stack README's Paperless section has the exporter, which is the version-portable second route |
| `paperless-db-data` | Paperless-ngx's metadata: tags, correspondents, every document's fields | **Lost**, unless an export is intact — an export carries the metadata beside the files |
| `linkding-data` | linkding's database, WAL mode, and `secretkey.txt`, which signs its sessions | **Lost**, unless a Netscape HTML export from linkding's settings is intact. It imports into linkding or any browser. A missing `secretkey.txt` alone costs a login and nothing else |
| `paperless-data` | The search index and the classifier | Rebuilt at the next start; the index is re-derived from the documents |
| `paperless-broker-data` | Valkey's task queue | Nothing. Archived because it exists, worth nothing back |
| `miniflux-db-data` | Miniflux's database: every subscription and category, read and starred state, and the entries not yet archived ([#147](https://github.com/Gerrrt/HomeLab/issues/147)) | **Lost**, unless an OPML export is at hand — the stack README's Miniflux section has it — and then the subscriptions come back and the read state and stars do not. Nothing else on the tier depends on it |
| `actual-data` | Actual's server: `account.sqlite` (the password hash and the one session) and every budget's file and sync messages | **Lost** as a server copy. Each client holds the whole budget and can upload it again, which covers losing the server and not a bad sync. A lost `account.sqlite` alone costs a re-claim: `make up` seeds the SOPS password into an empty volume |
| `step-ca-data` | The intermediate CA's tree | Re-minted on the monitoring host from the lab CA's key — [#404](https://github.com/Gerrrt/HomeLab/issues/404)'s procedure. Costs a runbook step, not data |
| `caddy-data` | Caddy's storage: `instance.uuid`, the lock directory, later the ACME state | Recreated on the next start. Nothing here is worth a restore until step-ca issues leaves into it |
| `caddy-config` | `autosave.json`, Caddy's copy of its last loaded config | Recreated on the next start from the `Caddyfile` |
| `ntfy-data` | ntfy's `user.db` and twelve hours of message cache | Nothing. **Not archived at all** ([#136](https://github.com/Gerrrt/HomeLab/issues/136)): the users, access list and token are re-provisioned from `secrets/sensitive.sops.yaml` on every start, and the cache is notifications already delivered. `make up` creates it empty and ntfy fills it |
| `adguard-work` | AdGuard's blocklists, query log, statistics and UI sessions | Re-downloaded and re-accumulated. **Not archived at all since 2026-09-28**: archiving it meant stopping AdGuard, which since that day is the house's only DNS forwarder, and the query log is the household's browsing history. The settings are `adguard/AdGuardHome.yaml`, in git |

So this runbook is mostly about those nine, and [#131](https://github.com/Gerrrt/HomeLab/issues/131)
said why it had to exist before that volume held anything: *"a password vault
is the one service here where 'it is running' and 'it is recoverable' are
entirely different claims, and only the second one counts on the day it
matters."*

> [!CAUTION]
> Restoring is destructive and its worst failure is silent, exactly as it is on
> the observability host. A stack brought back with a stale `db.sqlite3` serves
> a working web vault that is wrong about which items exist, which accounts
> exist and which of them have a second factor. Nothing will tell you. Read §4
> before you start §2.
>
> Whoever is reading this in an emergency: by
> [ADR-0023](../adr/0023-keep-the-household-recovery-path-outside-the-estate.md)
> the household's own credentials are **not** in this vault, and nothing you
> need to recover the house depends on this runbook succeeding. The vault here
> is the operator's. Take the time to do this properly.

---

## 0. Before anything breaks

Three things must be true, and none of them is automatic.

**A current set exists.**

```bash
make backup STACK=sensitive
make backup STACK=sensitive ARGS=--list
```

It lands in `backups/volumes/<STAMP>/` on `trinity`, gitignored, one
age-encrypted archive per volume and a `MANIFEST` written last, and the same
run copies it to `oracle` under `backups/volumes/sensitive` — a directory of
its own, so the estate's prune and the tier's cannot see each other's sets
([#535](https://github.com/Gerrrt/HomeLab/issues/535); the key exchange and
the seed are in [`restore-the-stack.md`](restore-the-stack.md) §0). The archives are
encrypted to every recipient of `secrets/sensitive.sops.yaml` — `trinity`'s key,
and the technical second's once it joins that rule — and the manifest records
which. The stack is stopped for the length of the copy, which is seconds here:
a copy of an open SQLite database is a file that looks like a backup.

**A timer takes a set every night at 04:30.** This is
`homelab-backup-sensitive`, [#404](https://github.com/Gerrrt/HomeLab/issues/404)
step 9, installed with `make install-timers PROFILE=sensitive`
([`schedule-maintenance.md`](schedule-maintenance.md#on-trinity-the-sensitive-profile)).
Its outcome is `backup-sensitive` in the estate's `ScheduledJob*` alerts, so a
night that fails, or a timer that stops, is a finding within two days. Every
set is on `trinity` and on `oracle`. Both are in the same room and on the same
power, so neither is the off-estate copy that
[ADR-0023](../adr/0023-keep-the-household-recovery-path-outside-the-estate.md)
requires. That copy is step 10, and it is one reason the vault holds nothing
real yet.

**The key that opens it is not the only one.** A set encrypted to `trinity`'s
key alone dies with `trinity`'s disk. [ADR-0024](../adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)'s
second recipient has to be on the `sensitive` rule before the first real item
goes in — `make secrets-add-recipient PUBKEY=age1... STACK=sensitive` — and the
backup encrypts to it from the next run.

And it has been dry-run restored at least once:

```bash
make restore STACK=sensitive ARGS="--dry-run --from latest"
```

---

## 1. Decide which failure you have

| Symptom | Likely cause | Go to |
| --- | --- | --- |
| Web vault loads, login says the password or the account is wrong | `db.sqlite3` stale or replaced — a bad upgrade, or a volume started empty | §2, `vaultwarden-data` |
| Every client asks to log in again at once | `rsa_key.pem` changed — Vaultwarden minted a new one on an empty volume | §2, `vaultwarden-data`, and read §4 step 3 |
| Caddy answers 502 for the vault | The container is not up. Not a volume problem — `make logs STACK=sensitive SERVICE=vaultwarden` | — |
| Browser refuses the certificate | The leaf, not a volume — the name is not in its SANs, or it expired | `compose.yaml`'s `make certs` line |
| step-ca will not start, log says `config/ca.json` | `step-ca-data` empty or replaced | §2, or re-mint from the monitoring host |
| linkding's list is empty, or its login refuses the password from SOPS | `linkding-data` empty or replaced. On an empty volume linkding creates a fresh superuser from SOPS and an empty list | §2, `linkding-data` |
| Home Assistant offers onboarding instead of a login | `home-assistant-config` empty or replaced — `.storage/auth` is gone | §2, `home-assistant-config` |
| Memos offers to create the first account, or its notes are gone | `memos-data` empty or replaced | §2, `memos-data` |
| The host's disk is gone | Hardware | §3, after rebuilding the host |
| Files under `/var/lib/docker/volumes` deleted or encrypted | Ransomware, or a mis-aimed `rm -rf` | §3 — and **not** from a set on this host |

Run `make ps STACK=sensitive` and `docker volume ls` first. A vault that looks
like it lost its data is far more often a container that failed to start.

Restore the volume you lost, not the set it came in. Restoring `vaultwarden-data`
alone costs every item added since the stamp; restoring all four costs that plus
a CA tree and a Caddy state that were fine.

---

## 2. Restore one volume

Verify first, and read what it prints:

```bash
make restore STACK=sensitive ARGS="--dry-run --from 20260909T231558Z --only vaultwarden-data"
```

Then, without `--dry-run`:

```bash
make restore STACK=sensitive ARGS="--from 20260909T231558Z --only vaultwarden-data"
```

It stops the stack, snapshots the current contents to
`backups/volumes/.pre-restore-<STAMP>/`, empties the volume and extracts the
archive into it. It asks you to type the stamp, and it needs a terminal to ask
— it will not run from a script or a timer, deliberately. It then reports the
owning uid against the one the service needs: `0` for `vaultwarden-data`,
`home-assistant-config`, `caddy-data` and `caddy-config`, because those
services run as root for the reasons `compose.yaml` measures; `1000` for
`step-ca-data`; `10001` for `memos-data`; `65534` for `adguard-work`; `999` for `immich-db`,
`paperless-db-data`, `paperless-broker-data` and `miniflux-db-data`; `33` for
`linkding-data`, which linkding's own start chowns back to 33 anyway.
Paperless's other two belong
to whoever ran `make up`, which is not a constant the script can check, so
look at those yourself. A mismatch is
reported and never silently corrected.

It leaves the stack **stopped**. Bring it up and then run §4:

```bash
make up STACK=sensitive
```

---

## 3. Restore the whole set

Same, without `--only`. On a rebuilt host, in this order:

1. Restore `trinity`'s age key — or add the host's new key to the `sensitive`
   rule from a machine that holds the second recipient — and run
   `make render STACK=sensitive`. The certificates travel from the monitoring
   host as `build-the-lab-guest.md` §5 does it.
2. `make restore STACK=sensitive ARGS="--from <STAMP>"` — volumes that do not
   exist yet are created, so a bare host is a valid target.
3. `make up STACK=sensitive`.

> [!CAUTION]
> Restore **before** the first `make up`, not after. Started against an empty
> volume, Vaultwarden mints a fresh `rsa_key.pem` and an empty database, and the
> restore then discards both — merely wasteful, but the log line it leaves
> behind is the one §4 step 3 looks for, so it also spoils the check. Home
> Assistant on an empty volume writes a fresh store and offers onboarding, the
> same waste. step-ca is the safe one: on an empty volume it refuses to start
> at all.
>
> **Home Assistant's HTTP settings come back with the volume.** They are
> `.storage/http`, inside `home-assistant-config`, and they are what makes it
> trust Caddy. A restored volume carries them, and `make up`'s seed step leaves
> an existing store alone. A rebuild with no set to restore gets them from
> `scripts/seed-ha-http.sh`, which `make up` runs on the empty volume. Either
> way, §4 step 6 checks them.

`step-ca-data` has a second route: re-mint the intermediate on the monitoring
host and populate the volume by hand, as the build does. Prefer that over a set
older than the certificates in circulation — a CA restored from before a leaf
was issued has no record of it.

---

## 4. Verify

```bash
# 1. Did it come back at all?
make up STACK=sensitive && make ps STACK=sensitive

# 2. vaultwarden-data — the account table. Read the database WITH its journal:
#    after a stop, the last writes sit in db.sqlite3-wal, and the main file read
#    on its own shows a database from before them. Measured during the
#    rehearsal below: an account registered a minute before the stop was
#    absent from db.sqlite3 alone and present once the -wal came with it.
mkdir -p /tmp/vw
for f in db.sqlite3 db.sqlite3-wal db.sqlite3-shm; do
  docker run --rm -v sensitive_vaultwarden-data:/d:ro \
    "$(./scripts/image-for.sh archiver)" cat "/d/$f" > "/tmp/vw/$f" 2>/dev/null || true
done
python3 -c "import sqlite3;print(sqlite3.connect('/tmp/vw/db.sqlite3').execute(
  'select email, created_at from users').fetchall())"
#    Every account's `created_at` must PREDATE the stamp. An account created
#    after it means Vaultwarden provisioned itself a fresh database.

# 3. The signing key. Vaultwarden logs this ONLY when it creates one:
docker logs sensitive-vaultwarden 2>&1 | grep -c "rsa_key.pem' created correctly"
#    Must be 0. A 1 means the volume was empty when the service started and
#    every client is about to be logged out — and that the restore did not
#    happen before the first start (see §3).

# 4. Sign-up is still closed. SIGNUPS_ALLOWED comes from compose.yaml, not the
#    volume, so this proves the config rather than the restore — but a restore
#    is also when someone is most likely to have started the service by hand.
docker exec sensitive-vaultwarden curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Content-Type: application/json' -X POST \
  http://localhost:8080/identity/accounts/register \
  -d '{"email":"nobody@matrix.elysium","masterPasswordHash":"x","key":"x","kdf":0,"kdfIterations":600000}'
#    400. A 200 here is a registration that succeeded.

# 5. step-ca-data — the CA opens its own key and answers health, as the
#    container's own healthcheck asks it to:
docker exec sensitive-step-ca step ca health --ca-url https://localhost:9000 \
  --root /home/step/certs/root_ca.crt

# 6. home-assistant-config — the login page, not onboarding. Onboarding is
#    what a fresh store offers, and it means .storage/auth did not come back.
docker exec sensitive-home-assistant wget -q -O - http://localhost:8123/api/onboarding \
  | grep -c '"done": false'
#    Must be 0: every onboarding step is already done in a restored store.
#    And the HTTP settings came back too, so requests through Caddy are not
#    refused with 400:
./scripts/seed-ha-http.sh --check
#    Must say "already present and trusts 172.28.99.2".

# 7. memos-data — the account table, read the way step 2 reads the vault's:
#    with the -wal, which is where the last writes are if the stop was not
#    clean. created_ts is epoch seconds.
mkdir -p /tmp/memos
for f in memos_prod.db memos_prod.db-wal memos_prod.db-shm; do
  docker run --rm -v sensitive_memos-data:/d:ro \
    "$(./scripts/image-for.sh archiver)" cat "/d/$f" > "/tmp/memos/$f" 2>/dev/null || true
done
python3 -c "import sqlite3;print(sqlite3.connect('/tmp/memos/memos_prod.db').execute(
  'select username, created_ts from user').fetchall())"
#    Every account must PREDATE the stamp, and registration must still be
#    closed — it is a setting in this database, so a restore can reopen it:
docker exec sensitive-memos wget -qO- http://127.0.0.1:5230/api/v1/instance/settings/GENERAL \
  | grep -c '"disallowUserRegistration":true'
#    Must be 1.

# 8. mealie-data — the accounts predate the stamp, and the signing secret came
#    back. Rollback-journal SQLite, so the main file alone is the database.
docker exec sensitive-mealie python3 -c "import sqlite3;print(sqlite3.connect(
  '/app/data/mealie.db').execute('select email, created_at from users').fetchall())"
docker exec sensitive-mealie test -s /app/data/.secret && echo secret present
#    Every account's created_at must PREDATE the stamp. A lone
#    changeme@example.com created after it is a fresh database: the restore
#    did not happen before the first start.

# 9. actual-data — the server is claimed, by the password it had, and the
#    budgets are there. `make up` in step 1 ran the seed first: if it printed
#    "claimed with the SOPS password before first start", the volume was EMPTY
#    when it ran and the restore did not happen. After the fact:
./scripts/seed-actual-password.sh --check
#    Must say "already claimed, and the SOPS password logs in".
docker exec sensitive-actual ls -l /data/user-files
#    One file-<id>.blob per budget, dated no later than the stamp.
```

Then from a client on Hicks — the checks a shell cannot do:

- **Log in as an account that existed before the stamp**, with the second
  factor it had. The TOTP secret lives in the database's `twofactor` table, so a
  login that skips the code is a restore that put back the account and not the
  factor.
- **An item added after the stamp must be absent.** This is the assertion that
  catches a restore that looked perfect and did nothing: the web vault serves
  fine over a volume that never changed, because the web vault is in the image.
  Find one thing you know was added after the set was taken and confirm it is
  gone.
- **Actual's clients still hold their own copies.** A restore puts the
  server back to the stamp. It does not reach the phones and laptops, which
  may hold changes made after it. If the restore was for a bad sync, the
  clients hold the bad copy too. Decide which copy is the real one before
  any client syncs. How a client resolves the difference has not been
  measured: do it on one device first.

---

## 5. Afterwards

- **Take a fresh backup now.** The restored volume is the live one, and the
  pre-restore snapshot is the only copy of what you replaced. Keep it
  deliberately or delete it deliberately; it is the vault.
- **Tell the other account holder** what the stamp was. Everything they added
  after it is gone, and only they know what that was.
- **If `rsa_key.pem` changed, every client is logged out**, on every device, and
  each needs the master password and the second factor again. Not data loss —
  but it is the moment a lost authenticator is discovered, so make sure the
  recovery codes are where the admin token is before doing this on purpose.

---

## Restore Immich

Immich is two stores, and §2–§4 restore only one of them. The metadata is in
`immich-db`. The photographs are a bind mount on the USB disk, in no volume
set; they have sets of their own, `make backup-library`, nightly to `oracle`
([ADR-0064](../adr/0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)).
What protects each is in the stack README's
[*What backs Immich up*](../../stacks/sensitive/README.md#what-backs-immich-up-and-what-does-not-yet).
A restore that brings back the database without the files — or the files
without the database — serves a library of broken thumbnails, or an empty one.

**Put the library back first.** Mount the disk (or its copy) at
`IMMICH_UPLOAD_LOCATION` with `backups/`, `encoded-video/`, `library/`,
`profile/`, `thumbs/` and `upload/` beneath it, owned by the deploying user.
Every folder carries a `.immich` marker, and the server refuses to start
when one is unreadable — that is the check that the mount is the library and
not an empty directory.

**When the disk itself is gone**, the library comes back from a library set.
The one on `oracle` survives `trinity`; the one under `backups/immich-library/`
on the SSD survives only the disk. On a new disk, formatted and mounted per
[`build-the-sensitive-tier-host.md`](build-the-sensitive-tier-host.md) §5:

```bash
STAMP=<newest complete set>        # make backup-library ARGS=--list
ssh atropos@10.0.99.30 "cat 'backups/immich-library/${STAMP}/immich-library.tar.gz.age'" \
  | tee >(sha256sum) \
  | age -d -i ~/.config/sops/age/keys.txt \
  | tar -xz --numeric-owner -C /srv/immich
```

Compare the printed sha256 with the `immich-library` row of the set's
`MANIFEST` (the local copy, or `cat` it off `oracle`) before trusting the
tree. The set holds `upload/`, `library/`, `profile/` and `backups/`, plus the
markers of `thumbs/` and `encoded-video/`, which are otherwise empty. Its
`backups/` holds the dump Immich wrote a few hours before the set, so the
second route below works from the set alone. After the server is up, sign
in as the admin, open *Jobs*, and run **Generate thumbnails** and **Transcode
videos** with *All*, not *Missing*. The rows still name the thumbnails, so
*Missing* finds nothing to do. Assets in the trash are skipped. That is
upstream's choice, and a restored-from-trash asset shows a grey tile until its
own thumbnail is regenerated.

**Then the database, by one of two routes.**

- **The volume**, out of a `make backup` set: §2 with `--only immich-db`.
  Postgres finds a data directory, skips initialisation and needs no redo —
  the set was taken from a stopped container.
- **Immich's own dump**, newest in `IMMICH_UPLOAD_LOCATION/backups/`. This is
  the route when the SSD and every set are gone and the disk is not, and the
  one to prefer when the newest set is older than the newest photos. Upstream's
  command-line restore, with this stack's names:

```bash
make render STACK=sensitive
docker compose -f stacks/sensitive/compose.yaml create           # nothing runs yet
docker volume rm sensitive_immich-db                             # only if it holds a database
docker start sensitive-immich-db                                 # initialises an empty `immich`
gunzip --stdout /srv/immich/backups/<dump>.sql.gz \
  | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  | docker exec -i sensitive-immich-db psql --dbname=immich --username=postgres \
      --single-transaction --set ON_ERROR_STOP=on
make up STACK=sensitive
```

  A version mismatch between the dump's filename and the pinned image is
  upstream's warning, not this runbook's: it migrates forward, it does not
  migrate back. Restore on the version that wrote the dump when you can.

**Before `make up` if you can, not after.** Upstream calls restoring into a
database the server has never touched a hard rule. It is not one on v3.2.2 —
see below — but a server started on an empty `immich-db` answers
`isInitialized: false` and serves *create the first admin* on VLAN 99 to
whoever reaches it first, and a phone that reconnects in that window is
talking to a different, empty Immich. Keep the order.

**Verify.** All three, against the numbers the restored database itself
claims:

```bash
# 1. Not a fresh install. Both must be true; false/false is onboarding.
docker exec sensitive-immich-server curl -fsS http://localhost:2283/api/server/config \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["isInitialized"], d["isOnboarded"])'

# 2. The mount checks, and no drift between the schema and the image.
docker logs sensitive-immich-server 2>&1 | grep -E 'Successfully verified system mount|schema drift'

# 3. Every original is on the disk and is the file the database says it is.
#    asset.checksum is the SHA-1 of the original. Expect bad=0.
docker exec sensitive-immich-db psql -U postgres -d immich -AtF' ' \
  -c "select encode(checksum,'hex'), \"originalPath\" from asset" \
  | python3 -c '
import hashlib, sys
ok = bad = 0
for line in sys.stdin:
    s, p = line.rstrip("\n").split(" ", 1)
    try:
        h = hashlib.sha1(open("/srv/immich/" + p.removeprefix("/data/"), "rb").read()).hexdigest()
    except FileNotFoundError:
        h = None
    if h == s: ok += 1
    else: bad += 1; print("BAD", p)
print(f"ok={ok} bad={bad}")'
```

A `BAD` line is a photograph the database remembers and the disk does not
have — the case upstream's *Backup ordering* warns of when the files were
copied before the database. A database dumped first and files copied second
can only err the other way: files on disk that no asset row names, which cost
a re-upload and nothing else.

### Rehearsed on `trinity`, 2026-09-28

Against the real library — 615 assets from two accounts, uploaded earlier
that day — and without touching the live stack. The library was copied onto a
tmpfs *after* a `pg_dump` of the live database, in upstream's order. Scratch
containers were started by hand with `compose.yaml`'s options on an
`--internal` network, with no port, and no machine-learning container.
Everything was deleted afterwards.

**What it established.**

- **Immich's dump route.** 21 MB of `.sql.gz` restored into a fresh `immich-db`
  in 19 seconds, in one transaction, with no errors. The server started on it
  healthy in 12 seconds. It ran no migrations, found no schema drift, passed
  all six mount checks and skipped the ~228k-row geodata import, because that
  table came back too. `isInitialized` and `isOnboarded` were both true, and
  both accounts were there.
- **The volume route.** `make backup STACK=sensitive` wrote set
  `20260928T203415Z`: ten volumes, 126 MB, the stack down 17 seconds, with
  the set copied to `oracle` and verified there. `restore-volumes.sh --only
  immich-db` into `COMPOSE_PROJECT_NAME=rehearse` brought the volume back
  owned by `999`. Postgres skipped initialisation, and `data_checksums` was
  still on. The server's result matched the dump route's.
- **Every photograph checks out, on both routes.** The `(checksum,
  originalPath)` list read from each restored database was byte-identical to
  the live one. All 615 originals in the copy hashed to their checksum:
  `ok=615 bad=0`.

**What it found.**

- **The order is a safety rule on v3.2.2, not a hard one.** A server started
  first on an empty database ran every migration and offered onboarding. The
  same dump then restored over it cleanly anyway, because `pg_dump --clean
  --if-exists` drops what it recreates. The server restarted on that database
  with both accounts and no drift. That was a dump from the *same* version.
  A dump from an older version, restored over a newer schema, was not tried.
- **Upstream's page restores into `--dbname=immich`, not `postgres`.** The
  dump is a single-database `pg_dump`, so the database has to exist already.
  The image's `POSTGRES_DB=immich` creates it on the first start.
- **The live server rode out its database's stop.** `backup-volumes.sh` stops
  `immich-db` and leaves `immich-server` running. The server logged no error
  across the 17 seconds and answered `ping` afterwards.
- **`restore-volumes.sh --only immich-db` still prints the whole tier's
  warnings** (vault items and `rsa_key.pem`, step-ca leaves). That is noise
  on a single-volume restore, not a fault.

**What is still not proven** (as of 2026-09-28; the next subsection closes the
first point). Nothing came back from anywhere but `trinity`,
and there is no copy of the originals off it. That is [#455](https://github.com/Gerrrt/HomeLab/issues/455),
and until it exists the checksum pass above proves only that a copy of *this
disk* restores. The restored server was not reached through Caddy, nor by a
phone. A phone reconnecting to a restored server is the moment a wrong
restore would first be noticed, and nobody has watched it. Machine learning
did not run, so the face and CLIP vectors came back but nothing used them.
A cross-version restore, the case upstream warns about, was not tried.

### Rehearsed from a library set off `oracle`, 2026-09-29

This is the case of losing the USB disk. The first `make backup-library` set,
`20260929T232136Z`, was 1.5 GB holding 615 originals. It was written in
68 s and copied to `oracle` in about three minutes. It was pulled back from
`oracle`, not from `trinity`'s copy, and streamed through `age -d` into a
tmpfs. The live stack was not touched. The scratch `immich-db` ran on a tmpfs,
with scratch Valkey and server, on an `--internal` network with no port and no
machine learning. Everything was deleted afterwards.

**What it established.**

- **The bytes that came back are the bytes written.** The sha256 of the
  stream as `oracle` served it equalled the `MANIFEST`'s. It unpacked in
  136 s, with all six `.immich` markers present.
- **The set restores on its own.** The dump inside it, Immich's 02:00
  `v3.2.2` dump, restored into a fresh `immich-db` in 18 s, before the
  server's first start. `immich-server` v3.2.4 started on it with
  `isInitialized` and `isOnboarded` both true, both accounts present and all
  six mount checks passing.
- **Every photograph checks out.** `ok=615 bad=0`, by the SHA-1 pass above
  against the restored database. `make backup-library ARGS=--prove` had said
  the same of the set, streamed, against the live database.
- **The derived trees regenerate.** *Generate thumbnails* and *Transcode
  videos*, with *All*, produced 960 thumbnail and preview files and 20
  transcodes.

**What it found.**

- **A transient schema-drift warning.** The server re-ran the geodata import
  on this restore; on 2026-09-28's same-version restore it had skipped it. The
  API worker checked the schema mid-import, while the import had
  `geodata_places`' indexes dropped, and logged drift. The microservices
  worker, and `immich-admin schema-check` a minute later, both read
  `No schema drift detected`. A drift warning within a minute of a restored
  server's first start is not the finding it looks like. Re-run
  `schema-check` before acting on it.
- **121 of the 615 assets are in the trash**, and the thumbnail job skips
  trashed assets. Their originals are in the set and hash correctly; their
  tiles regenerate if they are restored from the trash. Immich empties its
  trash after thirty days, and nothing here keeps a trashed asset longer.
- **The *Missing* option regenerates nothing after a restore.** It keys on
  the database's `asset_file` rows, which the restored database still has. Use
  *All*.
- **`immich-admin reset-admin-password` needs a TTY.** Piped input hangs it.
  On a scratch copy the admin's bcrypt hash was set directly instead. On a
  real restore the admin's own password is the way in.

**What is still not proven.** The key: this set is encrypted to `trinity`'s
key alone, so it proves a restore on a host that has that key. Losing
`trinity` as well as the disk is recoverable only if the key has a proven
copy (`make secrets-verify-backup STACK=sensitive`). Everything the
2026-09-28 rehearsal left open about phones, Caddy, machine learning and
cross-version restores is still open. And this is not off the estate. That is
still [#455](https://github.com/Gerrrt/HomeLab/issues/455). Its copy is built
([`carry-the-household-copy.md`](carry-the-household-copy.md)) and is waiting
on a holder. A restore from the household drive copies its set directories back
into `backups/immich-library/` and `backups/paperless-documents/`, and then
follows this page.

---

## What is proven, and what is not

The round trip was rehearsed on 2026-09-09 on the monitoring host, before
`trinity` exists, with the scripts as they are in this repository and four of
the twelve volumes seeded to look like the tier's — `home-assistant-config`,
`adguard-work`, Immich's two and Paperless's four did not exist yet
([#134](https://github.com/Gerrrt/HomeLab/issues/134),
[#135](https://github.com/Gerrrt/HomeLab/issues/135),
[#132](https://github.com/Gerrrt/HomeLab/issues/132) and
[#133](https://github.com/Gerrrt/HomeLab/issues/133) landed the same day).
Their sentinels were read off boots of the pinned images by the sessions that
landed them, and their restore was not rehearsed that day. `immich-db` has
been since, on `trinity` and by both routes: [Restore Immich](#restore-immich). What was seeded:

- Caddy from the pinned image, started under `compose.yaml`'s options with the
  real `Caddyfile` and a throwaway leaf, populated `caddy-data` and
  `caddy-config` — which is how the sentinels for both were found.
- `step-ca-data` was a **stand-in**: `config/ca.json`, a `certs/` file and empty
  `secrets/` and `db/` directories, owned by uid 1000. Not a CA tree.
- Vaultwarden from the pinned image, under `compose.yaml`'s options, with
  sign-up briefly on; one account registered through the API; stopped.

Then `make backup STACK=sensitive`, `--dry-run`, and a restore into a scratch
project (`COMPOSE_PROJECT_NAME=rehearse`), with Vaultwarden started on the
restored volume by hand.

**What it established.**

- **All four that existed archive, verify against their sentinels, and restore**, and each
  comes back owned by the uid its service needs — `0`, `0`, `1000`, `0`.
- **The vault comes back.** Vaultwarden started on the restored volume without
  minting a key — no `created correctly` line — answered `/alive`, refused a
  registration with sign-up off, and its account table held the seeded account
  with a `created_at` from before the set was taken. `rsa_key.pem` had the same
  SHA-256 in both volumes.
- **The scripts had never seen this stack, and now have.** Before this they
  died on the first of the tier's volumes for want of a sentinel, and read
  their age recipient as the first key in `.sops.yaml` — which, the day
  `trinity`'s placeholder is filled above the catch-all, would have encrypted
  the estate's weekly backup to `trinity`'s key.

**What it found.**

- **The write-ahead log is where the last writes are.** After `docker stop`,
  `db.sqlite3-wal` was 12 KB and held the account; `db.sqlite3` read alone did
  not. The quiesced archive carries all three files, so the restore is
  consistent, and the first start of the restored service checkpoints the
  journal into the main file. §4 step 2 reads the trio for that reason.
- **The byte floor refused a stand-in, and later a real volume.** The first
  step-ca stand-in was a 20-byte file in an empty tree, and the backup refused
  it as *implausibly small* under the old 512-byte floor. On `trinity`'s first
  real backup (2026-09-28) the same floor refused `paperless-media`: 368 bytes,
  holding the real, still-empty `./documents` tree. A byte count cannot tell
  those two cases apart, because each age recipient adds about 100 bytes, so
  the floor is now 256. It catches a truncated file and nothing else, and
  `backup-volumes.sh` gives the measurements. Empty and wrong volumes are
  refused by the entry count and the sentinel, which is what they were always
  for.
- **Caddy could not read its key.** `gen-certs.sh` writes the leaf's key `0640`,
  and a root that has dropped `CAP_DAC_OVERRIDE` is bound by that. Found by
  starting it; fixed with the `group_add` the estate's Grafana already has.
- **The restore needs a terminal.** `script -qec '...' /dev/null` with the
  stamp on stdin is how a rehearsal gets past that without weakening it.

**What is still not proven.** None of this ran on `trinity`, through Caddy, or
against a real step-ca tree; no browser reached the vault; `make up
STACK=sensitive` was never run on the result, because the certificates and the
CA tree do not exist here; and the set was encrypted to the estate's key
standing in for `trinity`'s, so the second recipient was not exercised. Nor
does any rehearsal satisfy the two obligations that fall due with the first
real item — [ADR-0022](../adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)'s
recorded decision and [ADR-0023](../adr/0023-keep-the-household-recovery-path-outside-the-estate.md)'s
*Independent* class. Those are [#404](https://github.com/Gerrrt/HomeLab/issues/404)'s,
on the host, with the real tree, before anything real goes in.

## Rehearsing without touching the live stack

`COMPOSE_PROJECT_NAME=rehearse` restores a set into `rehearse_*` volumes beside
the live ones. Do **not** start the stack on them — Caddy would contend for 443
with the live one — start the service you are checking by hand, with the
compose file's options and no port published:

```bash
STAMP=20260909T231558Z
printf '%s\n' "$STAMP" | script -qec \
  "COMPOSE_PROJECT_NAME=rehearse STACK=sensitive ./scripts/restore-volumes.sh --from $STAMP" /dev/null

docker run -d --name rehearse-vaultwarden --init --cap-drop ALL \
  --security-opt no-new-privileges:true --read-only --tmpfs /tmp:size=16m \
  -v rehearse_vaultwarden-data:/data -e ROCKET_PORT=8080 \
  -e DOMAIN=https://vaultwarden.matrix.elysium -e SIGNUPS_ALLOWED=false \
  -e ADMIN_TOKEN=rehearsal-only \
  "$(COMPOSE_FILE=stacks/sensitive/compose.yaml ./scripts/image-for.sh vaultwarden)"
# ... §4 steps 2–4 against rehearse-vaultwarden and rehearse_vaultwarden-data ...
docker rm -f rehearse-vaultwarden
docker volume ls -q | grep '^rehearse_' | xargs -r docker volume rm
```

The cheap check, worth running whenever a set is written somewhere new:

```bash
make restore STACK=sensitive ARGS="--dry-run --from latest"
```
