# Runbook: Restore the observability stack

**Target:** the five Docker data volumes on `prometheus` (10.0.99.20), VLAN 99
**Time:** 10 minutes for one volume; 30 for the whole set on a rebuilt host
**You will need:** a backup set, the age private key, and the stack stopped —
the restore script stops it for you

Nothing in the house breaks when this stack is down, and that is exactly what
makes it easy to lose. Metrics and logs re-accumulate, the dashboards are in
git, and the alert rules are in git, so for four of the five volumes the loss is
a hole in the record rather than a loss of function. The record is the thing
that tells you whether the incident in front of you has happened before, and it
is the one part of this repository that cannot be rebuilt from the repository.
`grafana-data` is different in kind again: it holds the users, the annotations,
the admin password and every dashboard edit made in the UI and never exported.
It is the only state here with no copy in git.

> [!CAUTION]
> Restoring is destructive and its worst failure is silent. A stack brought back
> with a stale `grafana.db` shows the right dashboards over the right data and
> is wrong about who logged in, what was annotated, what is silenced and what
> the admin password is. Nothing will tell you. Read §4 before you start §2.

---

## 0. Before anything breaks

Three things must be true, and none of them is automatic.

**A current set exists.**

```bash
make backup                 # quiesce, archive, encrypt, verify
make backup ARGS=--list
```

The output lands in `backups/volumes/<STAMP>/`, which is gitignored. Each
archive is age-encrypted to the same recipient as everything else in
[`.sops.yaml`](../../.sops.yaml). A set is complete only when it has a
`MANIFEST`; the backup writes that last, and a set without one is the wreckage
of a failed run.

The default stops the services for the length of the copy — about ninety seconds
— because a copy of a live store is not a backup. `--hot` skips the stop and
records `mode hot` in the manifest, and everything below treats such a set as
unproven, because it is.

**It lives somewhere other than the machine that made it.** A set on
`prometheus` protects against a bad upgrade and a mistyped command. It protects
against nothing that happens to `prometheus`. Copy it to the backup target and
offsite. This is the step that gets skipped — see [`roadmap.md`](../roadmap.md).

**The age key is backed up.** A volume archive you cannot decrypt is a disk you
cannot read. See [`back-up-the-age-key.md`](back-up-the-age-key.md) and
`make secrets-verify-backup`.

And it has been dry-run restored at least once:

```bash
make restore ARGS="--dry-run --from latest"
```

A set that has never been decrypted is a set you are hoping about.

---

## 1. Decide which failure you have

| Symptom | Likely cause | Go to |
| --- | --- | --- |
| Grafana loads, every panel empty, nothing older than this morning | The TSDB is gone — usually `make nuke` in the wrong window | §3 |
| Grafana will not start, or starts with no users and no saved dashboards | `grafana.db` damaged, most often after an upgrade migrated it | §2, `grafana-data` |
| Everything normal, every alert silence vanished | `alertmanager-data` lost | §2, `alertmanager-data` |
| Loki answers but returns nothing older than the last restart | `loki-data` lost or partly written | §2, `loki-data` |
| Duplicate log lines flooding Loki after a restart | `alloy-data` positions lost; Alloy re-read from the top | §2, `alloy-data` |
| The host's disk is gone, or the filesystem is read-only | Hardware | §3, after rebuilding the host |
| Files under `/var/lib/docker/volumes` deleted or encrypted | Ransomware, or a mis-aimed `rm -rf` | §3 — and **not** from a set on this host |

Run `make ps` and `docker volume ls` before anything else. A stack that looks
like it lost its data is far more often a container that failed to start than a
volume that is gone, and the first five rows above cost one volume where §3
costs five.

Check the volume name carefully. This host has carried volumes under two compose
project prefixes, and `prometheus_grafana-data` is not
`observability_grafana-data`. The backup and restore scripts derive the prefix
from the `name:` key in `compose.yaml` rather than guessing it, which is why they
refuse to run against a volume that does not exist instead of quietly creating
an empty one.

Most of this table is not an emergency. Metrics and logs refill on their own, and
restoring them costs everything collected since the backup. Restore the volume
you lost, not the set it came in.

---

## 2. Restore one volume

Verify first, and read what it prints:

```bash
make restore ARGS="--dry-run --from 20260829T064124Z --only grafana-data"
```

That decrypts the archive, reads it end to end, checks it against the manifest's
SHA-256, and prints the live volume's current size beside the archive's. Nothing
is touched. If the two sizes are wildly different, stop and work out why before
going on.

Then, without `--dry-run`:

```bash
make restore ARGS="--from 20260829T064124Z --only grafana-data"
```

It stops the whole stack, writes a pre-restore snapshot of the current contents
to `backups/volumes/.pre-restore-<STAMP>/`, empties the volume and extracts the
archive into it. It asks you to type the stamp first; that is deliberate, and
there is no `--yes`. It then reports the owning uid it found against the one the
service needs, and it does not silently correct a mismatch — a volume restored
byte-for-byte that its service cannot write to is a restore that failed.

It leaves the stack **stopped**. Bring it up yourself and then run §4:

```bash
make up
```

---

## 3. Restore the whole set

Same, without `--only`. On a rebuilt host, do it in this order:

1. Restore the age key and run `make render`, or nothing will start.
2. `make restore ARGS="--from <STAMP>"` — volumes that do not exist yet are
   created rather than replaced, so a bare host is a valid target.
3. `make up`.

> [!CAUTION]
> On a rebuilt host, restore **before** the first `make up`, not after. Starting
> Grafana once against an empty volume writes a fresh `grafana.db` that the
> restore then discards, which is merely wasteful. Starting Prometheus once and
> then restoring an older TSDB over it interleaves two sets of blocks, which is
> not.

One more thing bites only on a rebuilt host, and it is not about the volumes.

> [!CAUTION]
> **Grafana will not start if the host has no internet.** `GF_INSTALL_PLUGINS`
> makes its background installer contact `grafana.com` on every start, and a
> failure there is fatal — it crash-loops, even though both plugins are already
> in the volume you just restored. If the uplink is part of what you are
> recovering from, start Grafana with that variable emptied and put it back
> once the network is up. Every other service starts offline.

---

## 4. Verify

```bash
# 1. Did it come back at all?
make up && make ps

# 2. prometheus-data — ask for a value the running stack could not have
#    scraped since boot: an hour before the backup stamp.
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=count(up)' \
  --data-urlencode "time=$(date -u -d '<STAMP> -1 hour' +%s)" \
  | jq '.data.result | length'          # zero means that block did not come back

# 3. grafana-data — the dashboards are provisioned from git and prove nothing;
#    under unified storage they do not even appear in the legacy dashboard
#    table. What exists only in the volume is the user table. Read it straight
#    out of the database and skip the credential entirely:
docker run --rm -v observability_grafana-data:/d:ro \
  "$(./scripts/image-for.sh archiver)" cat /d/grafana.db > /tmp/g.db
python3 -c "import sqlite3;print(sqlite3.connect('/tmp/g.db').execute(
  \"select login, created from user\").fetchall())"
#    The admin's `created` must PREDATE the restore. If it is today's date,
#    grafana.db did not come back and Grafana provisioned itself a fresh one.
#    This lab has no annotations, so the annotation timestamps some runbooks
#    suggest are a vacuous check here — the user table is the one that works.

# 4. alertmanager-data — silences live in the volume, not the config.
docker exec alertmanager amtool silence query --alertmanager.url=http://localhost:9093

# 5. loki-data — query the restored window, not the last five minutes.
curl -sG http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={host=~".+"}' \
  --data-urlencode "start=<one hour before the stamp, in ns>" \
  --data-urlencode "end=<the stamp, in ns>" | jq '.data.result | length'
```

Then the assertions that must **fail**. These are the ones that catch a restore
which looks perfect and did nothing.

```bash
# 6a. Prometheus must have a GAP between the backup stamp and the restart.
#     Continuous data across that window means you are looking at fresh scrapes
#     and the restore quietly no-opped.
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=count(up)' \
  --data-urlencode "time=<the stamp, plus thirty minutes>" \
  | jq '.data.result | length'          # must be zero

# 6b. Alloy WILL re-ship, and this measures how much. Restoring alloy-data puts
#     the log positions back to their offsets at the stamp, so Alloy re-reads
#     every file from there and pushes the lines again — carrying their
#     ORIGINAL timestamps, so the duplicates land inside a window that closed
#     before the restore. Count that window per host, twice, ten minutes apart.
#     A climb is expected. It is not a failed restore; it is the cost of one,
#     and it tells you how far Alloy still has to catch up.
#
#     Measured during the 2026-08-29 rehearsal: about 4,600 duplicate lines
#     inside the hour before the stamp within four minutes of start-up.
#
#     The lines that must NOT climb are the ones carrying the ORIGINAL host
#     label. Those are the restored data. If that number moves, something is
#     writing into your restored history.

# 6c. Grafana's admin password must NOT be the one in the rendered .env.
#     Grafana applies GF_SECURITY_ADMIN_PASSWORD only when it creates the admin
#     user, so if the value in .env logs you in, grafana.db did not come back
#     and Grafana provisioned itself a fresh one.
```

> [!NOTE]
> Step 6 matters more than it looks, and 6c is weaker than it looks. A restore
> that puts back *something* leaves a stack that starts, serves dashboards and
> answers queries — because the dashboards, the rules and the datasources all
> come from git and never needed the volume at all. Everything visible works.
> The only evidence a volume came back is data that predates the restore, so
> check the age of what you are looking at, not that you are looking at
> something. And 6c proves nothing if the backed-up database was created with
> the password now in `.env`: identical values make the test vacuous while
> looking like it passed — and in this lab it IS the case, so 6c currently
> proves nothing at all. Use the `created` column on the admin row from step 3
> instead: a user created before the stamp cannot have been provisioned by the
> restart, and that check does not depend on the password differing or on any
> annotation existing.

---

## 5. Afterwards

- **Take a fresh backup now.** The restored volumes are the live ones, and the
  pre-restore snapshot is the only remaining copy of what you replaced. Keep it
  deliberately or delete it deliberately; it holds the same secrets as any other
  set and lives under the same rules.
- **Prometheus ages restored blocks from their own timestamps, not from today.**
  Thirty days of retention against a twenty-day-old set is ten days of history,
  shrinking.
- **Review the silences.** Anything created after the stamp is gone, and
  anything live at the stamp is suppressing again.
- If the cause was `make nuke`, the confirmation worked and someone typed it.
  Record it in [`roadmap.md`](../roadmap.md) if the design should have made that
  harder.

---

## What is proven, and what is not

The whole-stack restore in §3 was performed on 2026-08-29. It is no longer a
hypothesis. The set was restored into a scratch project and the entire stack was
started on the result; §4 was run against it, including the negative assertions.

**What it established.**

- **The Prometheus TSDB restores and serves.** Every block was reported healthy,
  the WAL replayed in about a second, and instant queries returned series from a
  day and a week before the stamp.
- **There is a genuine gap after the stamp.** Queries at the stamp plus thirty
  minutes, one hour and three hours all returned nothing, which is the assertion
  that catches a restore that quietly did nothing. The restored stack was
  simultaneously scraping its own targets, so it was serving restored history
  and collecting new data with a clean seam between them.
- **`grafana.db` restores intact.** Compared table by table against the live
  database: users, datasources, orgs, annotations and preferences all matched,
  and the admin row's `created` was twelve days before the restore. A fresh
  provisioning would have stamped it that day.
- **Loki serves the restored store.** Label values came back, and a range query
  over an hour that closed before the stamp returned the lines in it.
- **`nflog` and `silences` come back** with their original modification times.
- **Ownership survives.** The volumes came back owned by 65534, 10001 and 472 —
  what Prometheus, Loki and Grafana need in order to write to them.

**What it found, which per-volume testing had not.**

- **Grafana would not start without internet access.** `GF_INSTALL_PLUGINS`
  made the background installer contact `grafana.com` on every start, and a
  failure there was fatal — Grafana crash-looped, even though both plugins were
  already present in the restored volume. On a host that has lost its uplink,
  which is a perfectly ordinary disaster, the restore succeeded and Grafana
  still would not come up. Neither plugin was used by any dashboard, and one of
  them was an Angular plugin this Grafana refuses to load anyway, so the
  declaration was removed rather than repaired. Grafana's own bundled apps ship
  inside the image and need no network, which is why an offline start works now
  — verified on both fresh and restored volumes.
- **Alloy replays, and now there is a number for it.** Restoring `alloy-data`
  put the log positions back to their offsets at the stamp, and Alloy re-read
  from there and re-shipped the lines with their original timestamps — about
  4,600 duplicates inside the hour before the stamp, within four minutes of
  start-up, after which the count held steady across three samples. The restored
  lines themselves never moved. Duplicates in Loki after a restore are expected
  behaviour, not a symptom.

**What is still not proven.** The rehearsal ran under a scratch project name
with an overlay, and it used `docker compose up -d` rather than `make up` —
`make up` renders config and hot-reloads, and takes no overlay. Restoring **in
place, over the live project, and then running `make up`** has still never been
done. That is a smaller gap than the one this closed, but it is not zero: it is
the difference between "the data restores and a stack runs on it" and "this
stack, on this host, comes back".

## Rehearsing a restore without touching the live stack

Both scripts honour `COMPOSE_PROJECT_NAME` the way compose itself does, so a set
can be restored into a scratch project and started beside the live one. Write
this overlay — `container_name` is not namespaced by project, so without it
every service collides with the running stack:

```yaml
services:
  prometheus: { container_name: rehearse-prometheus }
  alertmanager: { container_name: rehearse-alertmanager }
  loki: { container_name: rehearse-loki }
  snmp-exporter: { container_name: rehearse-snmp-exporter }
  alloy: { container_name: rehearse-alloy }
  renderer: { container_name: rehearse-renderer }
  grafana:
    container_name: rehearse-grafana
    environment:
      GF_INSTALL_PLUGINS: ""
networks:
  observability:
    internal: true
```

`internal: true` is the safety argument, not a detail. Without it the rehearsal
Alertmanager sends to the real notification channels and pings the real
dead-man's-switch heartbeat, and the rehearsal snmp-exporter polls production
devices. It also means published ports do not route, so reach the services with
`docker exec` rather than from the host — and it is why `GF_INSTALL_PLUGINS`
has to be emptied above.

`BIND_ADDR=127.0.0.1` in the export below is belt-and-braces on top of that, and
since #70 it covers only the rehearsal Grafana and syslog receiver — the other
three are pinned to loopback in `compose.yaml` and ignore it.

```bash
export COMPOSE_PROJECT_NAME=rehearse BIND_ADDR=127.0.0.1 \
  PROMETHEUS_PORT=19090 ALERTMANAGER_PORT=19093 LOKI_PORT=13100 \
  GRAFANA_PORT=13000 ALLOY_PORT=12346 SYSLOG_PORT=11514 \
  ALLOY_HOSTNAME=rehearse-alloy

./scripts/restore-volumes.sh --from <STAMP>
docker compose -f stacks/observability/compose.yaml -f rehearse.yaml up -d
# ... run section 4 against it with docker exec ...
docker compose -f stacks/observability/compose.yaml -f rehearse.yaml down --volumes
```

Set `ALLOY_HOSTNAME` to something distinct. It is what lets you tell restored
log lines from ones the rehearsal stack produced, which is the whole of check 6b.

The cheap check, worth running whenever a set is written somewhere new:

```bash
make restore ARGS="--dry-run --from latest"
```

That proves the key on this host decrypts every file in the set, that each
stream survives its gzip CRC end to end, that each unpacks to a complete tar
holding the volume its filename claims, and that the set contains all five
volumes rather than the four somebody noticed were missing later. It proves
nothing about whether the stack runs on the result — for that, rehearse.
