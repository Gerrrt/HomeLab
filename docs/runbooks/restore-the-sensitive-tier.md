# Runbook: Restore the sensitive tier

**Target:** the four Docker data volumes on `trinity` (10.0.99.40), VLAN 99
**Time:** ten minutes for one volume; half an hour for the set on a rebuilt host
**You will need:** a backup set, an age identity the set was encrypted to —
`trinity`'s own key, or the technical second's — and the stack stopped; the
restore script stops it for you

[`restore-the-stack.md`](restore-the-stack.md) is the model for this one and is
not repeated here: the scripts are the same, the phases are the same, and the
reasons a restore is verified before anything is destroyed are argued there.
What is different is what the volumes hold. On the observability host, four of
five volumes are a *record* — metrics and logs that refill on their own. Here,
three of four are rebuildable from somewhere else and one is not:

| Volume | What it holds | If it is lost |
| --- | --- | --- |
| `vaultwarden-data` | The vault: every account, every item, every TOTP secret, the RSA key that signs every session | **Lost.** Nothing in git, nothing on another host, nothing regenerates it. This is the one the tier exists to protect |
| `step-ca-data` | The intermediate CA's tree | Re-minted on the monitoring host from the lab CA's key — [#404](https://github.com/Gerrrt/HomeLab/issues/404)'s procedure. Costs a runbook step, not data |
| `caddy-data` | Caddy's storage: `instance.uuid`, the lock directory, later the ACME state | Recreated on the next start. Nothing here is worth a restore until step-ca issues leaves into it |
| `caddy-config` | `autosave.json`, Caddy's copy of its last loaded config | Recreated on the next start from the `Caddyfile` |

So this runbook is mostly about one volume, and [#131](https://github.com/Gerrrt/HomeLab/issues/131)
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
age-encrypted archive per volume and a `MANIFEST` written last. The archives are
encrypted to every recipient of `secrets/sensitive.sops.yaml` — `trinity`'s key,
and the technical second's once it joins that rule — and the manifest records
which. The stack is stopped for the length of the copy, which is seconds here:
a copy of an open SQLite database is a file that looks like a backup.

**Nothing schedules this, and nothing copies it anywhere.** The `homelab-*`
timers belong to the monitoring host. Until [#404](https://github.com/Gerrrt/HomeLab/issues/404)
step 5 lands, a set exists when someone runs the command, and it exists on the
machine it protects. That is the state [#92](https://github.com/Gerrrt/HomeLab/issues/92)
complained about for the firewall export, one host over, and it is the reason
the vault holds nothing real yet.

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
`caddy-data` and `caddy-config`, because those services run as root for the
reason `compose.yaml` measures; `1000` for `step-ca-data`. A mismatch is
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
> behind is the one §4 step 3 looks for, so it also spoils the check. step-ca
> is the safe one: on an empty volume it refuses to start at all.

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

## What is proven, and what is not

The round trip was rehearsed on 2026-09-09 on the monitoring host, before
`trinity` exists, with the scripts as they are in this repository and the four
volumes seeded to look like the tier's:

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

- **All four archive, verify against their sentinels, and restore**, and each
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
- **The 512-byte floor is real.** The first step-ca stand-in was a 20-byte
  file in an empty tree, and the backup refused it as *implausibly small*. An
  artefact of the stand-in — a real tree is kilobytes — but it is what the
  floor is for.
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
