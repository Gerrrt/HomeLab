# systemd

[![systemd](https://img.shields.io/badge/systemd-timers-30363d?style=plastic)](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)
[![installed by](https://img.shields.io/badge/installed%20by-make%20install--timers-30363d?style=plastic)](../scripts/install-timers.sh)
[![checked by](https://img.shields.io/badge/checked%20by-make%20check--timers-30363d?style=plastic)](../scripts/install-timers.sh)

The schedule. Every unit here is a `.service` and `.timer` pair, and they are
what stop backups, proofs and deployment being things someone has to remember
([#77](https://github.com/Gerrrt/HomeLab/issues/77)). Two rules make that hold:

- **A job that stops running pages.** On the monitoring host and `trinity`,
  each scheduled job runs through `run-scheduled.sh` and reports its outcome as
  `homelab_job_*` metrics. The alert rules fire on a job going *stale* as well
  as on one that failed, so a dead timer is as loud as a broken script. Agent
  hosts work differently; see [below](#on-agent-hosts).
- **The table, the units and the alerts agree.** The schedule is a table in
  [`scripts/install-timers.sh`](../scripts/install-timers.sh), with each
  job's staleness threshold beside it. `make check-timers` fails when a unit
  exists without a row, a row without a unit, or a threshold is less than
  twice its timer's period, so one late run never pages.

Times are the host's local time. The full procedure, and what to do when a
job goes stale, is
[`docs/runbooks/schedule-maintenance.md`](../docs/runbooks/schedule-maintenance.md).

## The three directories

| Directory | Host | Installed by | Runs through |
| --- | --- | --- | --- |
| `systemd/` | `prometheus`, the monitoring host | `make install-timers` | `scripts/run-scheduled.sh`, from the deployment checkout |
| [`sensitive/`](sensitive) | `trinity` | `make install-timers ARGS="--profile sensitive"` | the same, with `@DEPLOY_ROOT@` and `@RUN_USER@` filled in at install |
| [`agent/`](agent) | each agent host, by what it can run | `make install-agent-collectors AGENT=user@host` | a collector copied to `/usr/local/bin`; an agent host has no checkout |

The estate's units name the deployment checkout's absolute path, because the
live stack runs from that checkout and nowhere else, and `install-timers.sh
--install` refuses to run from any other directory. A worktree is for
editing units, not installing them.

## On the monitoring host

| Unit | When | Does |
| --- | --- | --- |
| `homelab-converge` | hourly, at :25 | Fetches `main`, checks its signature and CI, deploys it. Installs report-only; see [`converge-the-host.md`](../docs/runbooks/converge-the-host.md) |
| `homelab-backup-firewall` | daily 04:30 | Exports and encrypts `morpheus`'s pfSense config |
| `homelab-backup-wiki` | daily 04:45 | Pulls a dump of the wiki's database off `oracle` |
| `homelab-verify-backups` | daily 05:30 | Proves every stored backup set still decrypts |
| `homelab-backup-nas` | Saturday 03:30 | Pulls the media tier's state off `smaug`'s newest snapshot |
| `homelab-backup-volumes` | Sunday 03:30 | Quiesces the observability stack and archives its volumes |
| `homelab-prune-images` | Monday 04:00 | Removes Docker images no container uses |
| `homelab-dashboards-drift` | daily 07:30 | Looks for Grafana edits not yet exported to the repo |
| `homelab-loki-coverage` | daily 07:45 | Checks every Loki rule can see the hosts it is about |
| `homelab-patch-state` | daily 08:00 | This host's apt patch state |
| `homelab-firewall-claims` | daily 08:15 | `docs/firewall-claims.yaml` against the live ruleset |
| `homelab-smart-state` | daily 08:30 | SMART health for this host's disks |
| `homelab-smart-state-remote` | daily 08:45 | SMART health from `morpheus`, over SSH |
| `homelab-pkg-state` | daily 09:00 | `morpheus`'s package state, over SSH |
| `homelab-recipient-state` | daily 09:15 | Which age recipients can open the secrets, and when each was proved |
| `homelab-ca-key-state` | daily 09:30 | The CA key's fingerprint, and when its offline copy was last proved |
| `homelab-gateway-state` | every 15 min | The firewall's view of its uplinks and its DDNS record |
| `homelab-silence-state` | every 15 min, at :05 | Alertmanager's silences, as metrics |
| `homelab-snmp-verify` | Wednesday 06:30 | Every SNMP device answers to its current credential |
| `homelab-check-versions` | Wednesday 06:45 | The documented OS versions against what the hosts report |

`secrets-verify-backup` and `certs-verify-backup` have no timer on purpose:
each needs a person to mount removable media. They get a deadline and an alert
instead.

## On `trinity`

| Unit | When | Does |
| --- | --- | --- |
| `homelab-converge-sensitive` | hourly, at :25 | Converges the sensitive tier onto `main`, report-only until switched on |
| `homelab-backup-sensitive` | daily 04:30 | Quiesces the tier and archives its volumes |
| `homelab-backup-library` | daily 05:15 | Archives Immich's library and copies it to `oracle` |

## On agent hosts

An agent host has no checkout, so these units emit no `homelab_job_*` metrics.
Each collector's own output is watched instead: an alert fires when a host that
*was* reporting stops. `install-agent-collectors.sh` installs only the
collectors a host can run, and reports the rest as skipped.

The one exception is `homelab-zeek-archive-prune` on `fenrir` (#850). The
installer ships `run-scheduled.sh` with it as `/usr/local/bin/homelab-run-scheduled`,
and its outcome goes to the lab's Prometheus, which has `ScheduledJob*` rules
for it in `stacks/lab/prometheus/rules/lab.rules.yaml`.

| Unit | When | Where it runs | Reports |
| --- | --- | --- | --- |
| `homelab-patch-state` | daily 08:00 | every Linux agent host | apt patch state |
| `homelab-smart-state` | daily 08:30 | hosts with disks to read | SMART health |
| `homelab-prune-images` | Monday 04:00 | hosts that run Docker | Removes unused images |
| `homelab-drift-check` | daily 06:30 | `oracle` | The wiki's drift check |
| `homelab-pve-version` | daily 08:15 | `Saruman` | The Proxmox VE version |
| `homelab-pve-firewall-state` | every 5 min | `Saruman` | Whether the Proxmox firewall is on |
| `homelab-guest-state` | every 10 min | `Saruman` | Which guests are running |
| `homelab-guest-disk-state` | every 10 min | `Saruman` | How full the guests' filesystems are |
| `homelab-thin-pool-state` | every 10 min | `Saruman` | How full the LVM-thin pools are |
| `homelab-iso-store-state` | daily 04:30 | `Saruman` | The ISO store against the repository's checksums |
| `homelab-zeek-mirror` | 2 min after boot, then every minute | `Saruman` | Builds the `tc` mirror of the lab bridge to `fenrir`, and re-applies it every minute |
| `homelab-zeek-mirror-state` | every 5 min | `Saruman` | Whether that mirror carries packets |
| `homelab-zeek-archive-prune` | daily 03:17 | `fenrir` | Deletes Zeek archive files past their retention; `homelab_job_*` to the lab |
| `homelab-pbs-task-state` | hourly at :17 | `golem` | What PBS last did: each verify, prune and garbage-collection job's outcome, and the snapshots by verify state ([#485](https://github.com/Gerrrt/HomeLab/issues/485)) |

## Adding a timer

1. Write the script, and give it a `make` target.
2. Add a `.service` and `.timer` pair here, in the directory for its host.
   An estate service's `ExecStart` goes through `run-scheduled.sh`.
3. Add its row, with a staleness threshold, to `install-timers.sh` (or a
   collector row to `install-agent-collectors.sh`).
4. Run `make check-timers`, then install it on the host.
