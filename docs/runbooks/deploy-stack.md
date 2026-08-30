# Runbook: Deploy the observability stack

**Target:** `prometheus` (10.0.99.20), VLAN 99
**Time:** ~10 minutes on a clean host

## Prerequisites

```bash
docker --version          # 24+ with the compose plugin
sops --version            # https://github.com/getsops/sops/releases
age --version             # https://github.com/FiloSottile/age/releases
openssl version           # issues the lab CA and Grafana's leaf
```

## First deployment

```bash
git clone <repo> HomeLab && cd HomeLab

make secrets-init     # generates an age keypair, creates the encrypted file
make secrets-edit     # replace every change-me value

# TLS. Grafana serves https from this leaf and Prometheus verifies it with the
# CA — see generate-certificates.md. Both are required before the stack starts.
make certs ARGS=--ca
make certs ARGS="--host grafana.matrix.elysium --ip 10.0.99.20"

make validate         # confirm the configs are sound before starting anything
make up
```

`make up` renders the decrypted config and starts all six services. Give it a
minute — Grafana waits on Prometheus and Loki reporting healthy.

`certificates/` is gitignored, so a clean clone has neither the CA nor the leaf
and the `certs` steps above are not optional. Skipping them used to produce a
stack that started and then failed obscurely: Docker creates a *directory* when
a bind-mount source is missing, so Grafana got directories where its cert and
key belong and Prometheus got one where its `ca_file` belongs. `make render`
now refuses to run in that state and names the step that was missed
([#69](https://github.com/Gerrrt/HomeLab/issues/69)).

> **Back up `~/.config/sops/age/keys.txt` off this machine now.** Without it the
> encrypted secrets in the repository cannot be decrypted by anything, including
> you.

## Verify

```bash
make ps                                     # all six services healthy
curl -s localhost:9090/-/healthy            # Prometheus
curl -s localhost:3100/ready                # Loki
curl -s localhost:9093/-/healthy            # Alertmanager
curl -sk https://localhost:3000/api/health  # Grafana (-k: lab CA)
```

The `curl`s pass wherever the services are bound, so confirm the binds
themselves are what `docs/architecture.md` claims (#70):

```bash
ss -ltn | grep -E ':(9093|12345)'        # 127.0.0.1 — Alertmanager and Alloy
ss -ltn | grep -E ':(9090|3100|3000)'    # BIND_ADDR — 0.0.0.0 by default
ss -lun | grep ':1514'                   # BIND_ADDR
```

Then in the UI:

1. **Prometheus → Status → Targets.** Every job `UP`. The four `snmp` targets
   take up to 45 seconds on their first scrape.
2. **Prometheus → Status → Rules.** 38 rules loaded, none in error.
3. **Grafana → Dashboards → HomeLab.** Five dashboards, populated.
4. **Grafana → Explore → Loki**, run `{host=~".+"}`. Logs should be arriving.
5. Confirm level normalisation is working — this has been silently broken
   before:

   ```logql
   sum by (level) (count_over_time({host=~".+"}[1h]))
   ```

   More than one series means the regex is matching. Only `info` means it is not
   (see `docs/observability.md`).

## Updating

```bash
git pull
make validate
make up          # recreates changed services, then reloads config on the rest
```

`make up` recreates a container only when its *service definition* changes — a
changed bind-mounted config file is invisible to `docker compose up -d`. So
`make up` finishes by reloading Prometheus, Alertmanager and snmp-exporter from
disk, and fails if any of them will not take the new config.

A config-only change — Prometheus rules, Alertmanager routing, the rendered
snmp-exporter config — needs no compose round trip at all:

```bash
make render && make reload
```

## Rolling back

Images are pinned, so rolling back is a git operation:

```bash
git revert <commit>
make up
```

Data volumes survive `make down` and `make up`. Only `make nuke` destroys them,
it prompts, and it is recoverable from a backup set — see
[`restore-the-stack.md`](restore-the-stack.md).

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `GRAFANA_ADMIN_PASSWORD: unset` | `.env` not rendered | `make render` |
| `unsubstituted placeholders remain` | A `SNMP_COMMUNITY_*` key is missing from the secrets file | `make secrets-edit` |
| `compose.yaml mounts these certificates, which are missing or empty` | `make certs` was never run | [`generate-certificates.md`](generate-certificates.md) |
| `a previous run of the stack created these as directories` | A `make up` predating the guard bind-mounted the absent certificates and Docker created directories | `rmdir` the paths it lists, then issue the certificates |
| SNMP targets `DOWN` | Community mismatch, or the device is not reachable from VLAN 99 | `make snmp-verify` (keeps the community out of your shell history) |
| Grafana panels empty, no error | Datasource UID mismatch | `make check-dashboards` |
| Loki `ready` returns 503 for a while | Normal on first start | Wait ~45s |
| Every log line labelled `info` | The level regex is not matching | See `docs/observability.md` |
| `make up` fails: `did not accept a reload within 60s` | A service started but never bound its listener, so it may be serving a stale config | `make logs SERVICE=<name>`; raise `RELOAD_TIMEOUT` only if the box is genuinely that slow |

## Backups

```bash
make backup                                 # quiesce, archive, encrypt, verify
make backup ARGS=--list                     # the sets that exist
make restore ARGS="--dry-run --from latest" # prove the newest one is readable
```

`make backup` stops the services for the length of the copy — about ninety
seconds — because a copy of a live store is not a backup. It writes one
timestamped, age-encrypted, verified archive per volume into
`backups/volumes/<STAMP>/`, keeps the seven newest complete sets, and prunes
only after the new one has verified.

Prometheus and Loki data re-accumulates, so losing it is a hole in the record
rather than a loss of function. `grafana-data` is the exception and the reason
this matters: the dashboards are in git, but the users, the annotations, the
admin password and every UI edit that was never exported exist only in that
volume. Restoring any of it is [`restore-the-stack.md`](restore-the-stack.md).
