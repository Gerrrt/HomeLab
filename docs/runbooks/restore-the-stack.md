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

# 3. grafana-data — the dashboards are in git and prove nothing. Annotations
#    and users exist only in the volume.
curl -sk 'https://localhost:3000/api/search?type=dash-db' | jq length
curl -sk -u admin:<the password from BEFORE the backup> \
     'https://localhost:3000/api/annotations?limit=5' | jq '.[].time'

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

# 6b. Alloy must not be re-shipping. Count Loki lines for a window that closed
#     before the restore, then run it again ten minutes later. The number must
#     not change. If it climbs, Alloy went back to an old position and is
#     replaying files it has already sent.

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
> looking like it passed. Where that is the case, use the annotation timestamps
> from step 3 instead — an annotation older than the stamp cannot have been
> written since the restart.

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

The restore path was exercised on 2026-08-29 against a quiesced set, by
extracting each archive into a scratch volume under a throwaway project name and
starting the pinned image against it. Three claims came out of that as facts:

- **The Prometheus TSDB survives the round trip.** Every block was reported
  healthy, the WAL replayed without error, and instant queries returned real
  series from months before the backup was taken.
- **Grafana opens the restored database.** It connected, found the schema
  already current, performed no migrations and restored its plugin cache.
- **Loki serves the restored store.** Label values came back, and a range query
  over an hour that closed before the backup returned the log lines in it.
- **Ownership survives.** The volumes came back owned by 65534, 10001 and 472,
  which is what Prometheus, Loki and Grafana respectively need in order to
  write to them.

The cheap check, worth running whenever a set is written somewhere new:

```bash
make restore ARGS="--dry-run --from latest"
```

That proves the key on this host decrypts every file in the set, that each
stream survives its gzip CRC end to end, that each unpacks to a complete tar
holding the volume its filename claims, and that the set contains all five
volumes rather than the four somebody noticed were missing later.

It does not prove the thing this runbook actually asks you to do. **No
whole-stack restore has ever been performed** — five volumes replaced in the
live project at once, followed by `make up` and §4 against the result. The
per-volume evidence above says each part works in isolation; it says nothing
about the five together, about `make up` starting a stack whose volumes all
moved at once, or about any of the negative assertions in §6.

The experiment that closes the gap: bring a set up as a second, scratch stack
and run §4 against it — `COMPOSE_PROJECT_NAME=restoretest`,
`BIND_ADDR=127.0.0.1`, and the Alloy syslog port left unbound, so the scratch
stack cannot take `morpheus`'s syslog stream or double-write into the live
remote-write receiver. Two of these must never be listening at once, for the
same reason two firewalls must never serve DHCP on one segment. Until that has
been done once, §3 of this runbook is a hypothesis.
