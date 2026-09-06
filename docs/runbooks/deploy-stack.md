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
make certs ARGS="--host grafana.matrix.elysium --ip 10.0.99.20 --dns grafana"

make validate         # confirm the configs are sound before starting anything
make up
```

`make up` renders the decrypted config and starts all six services. Give it a
minute — Grafana waits on Prometheus and Loki reporting healthy.

It then asserts on its own result: every service that declares a healthcheck
must reach `healthy`, and `make up` fails naming the service and the probe's
own output if one does not. That last part is the point — the failure it exists
for is a healthcheck pointed at an endpoint that answers 404, which reports a
permanent fault on a service that is working perfectly and looks in `make ps`
exactly like something that has always been that way
([#205](https://github.com/Gerrrt/HomeLab/issues/205)). The wait is bounded per
service by that service's own `start_period`, `retries`, `interval` and
`timeout`, so a slow start is not a failure and a broken probe does not hang
the deploy.

Loki and Alloy declare no healthcheck, so the check cannot speak for them and
says so by name rather than passing over them.

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

Confirm the per-container limits applied too. A limit that silently failed to
take is the thing they exist to defend against, and nothing in the stack would
report it (#71):

```bash
for c in prometheus alertmanager loki grafana snmp-exporter blackbox-exporter alloy; do
  docker inspect "$c" --format '{{.Name}} init={{.HostConfig.Init}} pids={{.HostConfig.PidsLimit}}'
done
```

Every service should read `init=true`, and `pids=512` except `alloy`, which is
`1024`. That reads back what Docker was *asked* for, so confirm the kernel
agrees — a stale cgroup directory will happily show you the old ceiling:

```bash
p=$(docker inspect -f '{{.State.Pid}}' prometheus)
cat "/sys/fs/cgroup$(cut -d: -f3 /proc/$p/cgroup | head -1)/pids.max"    # 512
```

`init=false` on grafana means the zombie leak is back:

```bash
docker exec grafana sh -c 'ls -d /proc/[0-9]* | wc -l'
```

which should be single digits and stay there, not climb by two every 30 seconds.

Confirm the size ceiling is armed, too. `PrometheusSizeRetentionActive` only
fires once the ceiling *bites*, so if the flag were ever dropped this would
silently read `0` and the rule would stay quiet forever — the #63 shape:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_retention_limit_bytes'
```

`12884901888` is 12 GiB. `0` means there is no size bound in force.

Then in the UI:

1. **Prometheus → Status → Targets.** Every job `UP`. The four `snmp` targets
   take up to 45 seconds on their first scrape.
2. **Prometheus → Status → Rules.** 58 rules loaded, none in error. The
   page counts 57: the extra one is `homelab_suricata_expected_interface`,
   the stack's only recording rule. Everything counted in this repository is
   alert rules, so the two numbers differ by one and always have.
3. **Grafana → Dashboards → HomeLab.** Seven dashboards, populated.
4. **Grafana → Explore → Loki**, run `{host=~".+"}`. Logs should be arriving.
5. Confirm level normalisation is working — this has been silently broken
   twice:

   ```logql
   sum by (level) (count_over_time({host=~".+"}[1h]))
   ```

   At most five series, every name one of `critical`, `error`, `warning`,
   `info`, `debug`. Only `info` means the regex is not matching. A sixth name
   means a path is reaching Loki without being normalised.

   Then confirm nothing escaped labelling entirely — these two must return the
   same number:

   ```logql
   sum(count_over_time({host=~".+"}[1h]))
   sum(count_over_time({host=~".+", level=~".+"}[1h]))
   ```

   A gap is a source that bypasses all three normalising mechanisms; container
   logs did exactly that until #83. See `docs/observability.md`.

## Put the maintenance jobs on a timer

A deployed stack that nothing backs up is one disk away from being a git
repository and nothing else. This step is not optional, and until it is done
`ScheduledJobNeverRan` is what says so.

```bash
make install-timers
```

Then confirm:

```bash
systemctl list-timers 'homelab-*'
```

Full detail, including the one job that has no timer and never will, is in
[`schedule-maintenance.md`](schedule-maintenance.md).

One of those timers deploys this host. `converge` runs hourly, fetches `main`,
verifies its signature and runs `make up` — so after this runbook, the section
below stops being something anybody has to do. It needs one setup step of its
own, a single GPG import:
[`converge-the-host.md`](converge-the-host.md).

## Updating

**Normally you do not.** A merged pull request reaches this host within the hour
on its own ([ADR-0021](../adr/0021-converge-on-a-timer-instead-of-deploying-over-ssh.md)).
What follows is how to deploy something *now* rather than waiting, and what the
timer is doing on your behalf.

**Unless the host is in report-only mode**, in which case none of that is true
and every merge needs one of the commands below —
[`converge-the-host.md`](converge-the-host.md) §Start in report-only mode says
how to tell, and why a merge in that mode looks like it landed when it has not.
That is the mode the agent was rolled out in.

```bash
make converge    # fetch main, verify it, fast-forward, make up — the timer's job, now
```

Or by hand, which is the escape hatch when the change is not on `main` yet:

```bash
git pull
make validate
make up          # recreates changed services, then reloads config on the rest
```

Note that a hand-deploy of something uncommitted leaves the tree dirty, which
**stops convergence** until it is committed or discarded — deliberately, because
the alternative is the timer destroying your edit at :25. `DeployDrifted` says so
within two hours.

`make up` recreates a container only when its *service definition* changes — a
changed bind-mounted config file is invisible to `docker compose up -d`. So
`make up` finishes by reloading Prometheus, Alertmanager and snmp-exporter from
disk, and fails if any of them will not take the new config. Then it runs
`make check-container-health`'s script, which is the step that distinguishes
"the commands were issued" from "the stack came up". Both can be run again
later without a redeploy:

```bash
make reload                 # re-read the configs on disk
make check-container-health # ask the running stack whether its probes pass
```

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

Revert on a branch and merge it if you can: a revert committed straight to the
deployment checkout is an unsigned local commit, which is both a non-fast-forward
against `main` and an unverified `HEAD`, so convergence stops until `main`
catches up. Fine as an emergency measure — that is what the escape hatch is for —
but it is a state to leave, not to stay in.

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
| `make up` fails: `refused the reload` | The service is up and answering, and would not take the new config — it is still serving the one it last parsed | Read the `wget` output printed above it: a 500 names what will not parse; a 404 means that build serves no `/-/reload` (Prometheus needs `--web.enable-lifecycle`) |

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
