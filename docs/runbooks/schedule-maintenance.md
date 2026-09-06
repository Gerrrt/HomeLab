# Runbook: Put the maintenance jobs on a timer

**Target:** the monitoring host, `prometheus` (10.0.99.20), VLAN 99
**Time:** ten minutes to install, plus one watched backup run
**You will need:** shell access with `sudo`, the stack already deployed, and the
age key in place at `~/.config/sops/age/keys.txt`

Five commands in this repository used to be things someone had to remember.
Nothing ran any of them, and `backups/` did not exist on the host at all — so
`make backup` had never once been run. This is how that stopped being true.

## Read this part first

Everything installed here runs **on the machine it is checking**, with the key
that is on that machine, against the disk that is in it.

`verify-backups` proves an archive still decrypts. It does not prove the disk
will spin up next month, and it cannot prove anything at all about a fire or a
theft. A green dashboard here is a narrower claim than it looks.

The one job that genuinely proves off-host recoverability is
`make secrets-verify-backup`, and it is exactly the job that **cannot** be put on
a timer: [`verify-key-backup.sh`](../../scripts/verify-key-backup.sh) refuses the
live key by device and inode, precisely so that what gets tested is a copy on
removable media. No timer can mount that. So it is enforced from the other end —
a successful run records its timestamp, and `SecretsKeyBackupUnproven` fires when
that proof passes ninety days old.

One job's output leaves this host: `backup-firewall` copies every export to
`oracle` and **fails if it cannot**, so its `ScheduledJobFailed` also means "the
config has stopped leaving `prometheus`" — a file that never left is a failed
run, not a partial success. The same run bounds what accumulates on each side
(`FW_KEEP`, default thirty), so a nightly job cannot fill either disk;
[`restore-the-firewall.md`](restore-the-firewall.md) §0 has the window and how
to change it. The copy needs a one-time key exchange between the
two laptops, in [`restore-the-firewall.md`](restore-the-firewall.md) §0, and
fails on purpose until that is done. The volume sets still do not leave
([#92](https://github.com/Gerrrt/HomeLab/issues/92)). Deployment itself is now
one of these jobs rather than something a human remembers to do —
[#99](https://github.com/Gerrrt/HomeLab/issues/99),
[ADR-0021](../adr/0021-converge-on-a-timer-instead-of-deploying-over-ssh.md), and
[`converge-the-host.md`](converge-the-host.md) for the one setup step it needs
beyond this runbook.
The honest summary is still that this host watches its own chores, and the
*external* cron-monitor described in
[`verify-the-alert-path.md`](verify-the-alert-path.md) is the only thing watching
the host.

---

## What runs, and when

| Job | Command | When | Alerts if not seen in |
| --- | --- | --- | --- |
| `converge` | `make converge` | hourly, :25 | 3 hours |
| `backup-volumes` | `make backup` | Sundays 03:30 | 14 days |
| `verify-backups` | `make backup ARGS='--verify-only --all'` | daily 05:30 | 3 days |
| `backup-firewall` | `make backup-firewall` | daily 04:30 | 3 days |
| `snmp-verify` | `make snmp-verify` | Wednesdays 06:30 | 14 days |
| `check-versions` | `make check-versions` | Wednesdays 06:45 | 14 days |
| `dashboards-drift` | `make dashboards-export ARGS=--check` | daily 07:30 | 2 days |
| `loki-coverage` | `make check-loki-coverage` | daily 07:45 | 2 days |
| `patch-state` | `make patch-state` | daily 08:00 | 2 days |
| `verify-key-backup` | **you**, `make secrets-verify-backup KEY=…` | no timer | 90 days |

Thresholds are roughly twice the period, never once: a threshold equal to the
period fires on every run that slips past its jitter window, whereas twice
tolerates one missed run and not two. `converge` is the one exception at three
times, because it shares the `backups` lock and a run that queues behind the
weekly archive can legitimately spend its full 900-second wait and then be an
hour late. Being late for a reason is not the finding.

`dashboards-drift`, `check-versions` and `loki-coverage` are the odd ones out,
and worth reading as a different kind of job. Every other row here proves that
something *happened* — an archive was written, a device answered. These three
prove that nothing *diverged*. `dashboards-drift` runs `make dashboards-export
ARGS=--check`, which writes nothing and exits non-zero when the running Grafana
holds a dashboard edit that git does not. `check-versions` asks Prometheus what
OS each host is actually running and exits non-zero when a document disagrees —
and since [#309](https://github.com/Gerrrt/HomeLab/issues/309) it also covers
`shiva`, the iLO BMC, which is not a host and so not in the Compute table the
rest of the check is scoped to. An out-of-band management processor that can
power the hypervisor on and off is the first thing anyone checks against an
advisory, so a stale firmware version in `network.md` is worth catching.
`loki-coverage` asks the live Loki whether any alerting rule has gone blind to a
host whose logs it is about, which is a thing CI structurally cannot ask because
it has no log store ([#327](https://github.com/Gerrrt/HomeLab/issues/327)).
`patch-state` is the odd one among the odd ones: it does not prove anything
happened OR that nothing diverged — it collects a fact the estate did not
previously have, which is how far behind this host's packages are
([#152](https://github.com/Gerrrt/HomeLab/issues/152)). It needs no root, and it
covers **this host only**: `oracle` and `Saruman` would need it shipped to them
and `morpheus` is FreeBSD with no apt at all.

`loki-coverage` is daily rather than weekly, and the reason is the opposite of
the obvious one. Its `--window` is not a sensitivity dial: both sides of its
comparison use it, so a host that goes quiet drops out of the denominator too
and the check goes vacuous rather than wrong. What the window sets is
*detection lag* — `reach` counts lines over the window, so a selector that went
blind an hour ago still looks reached until the last pre-breakage line falls out
of range. A 7-day window would hide a new gap for a week. 24 hours is as short
as the estate allows: `Saruman` is the quietest host at roughly 15 lines an
hour and is comfortably present at that window. The window is `WINDOW` in the
Makefile, and the unit deliberately sets none of its own, so there is one
number in one place.

It exists because of a trade made in
[#100](https://github.com/Gerrrt/HomeLab/issues/100). `allowUiUpdates` was
`false`, which meant a UI edit could never be saved at all — and so the
committed JSON and the running dashboard could not disagree. That also meant
`make dashboards-export` had nothing to export, which is why the flag is now
`true`. The property that was free before is bought here instead: a failed
`dashboards-drift` means somebody edited a dashboard in the browser and did not
run `make dashboards-export`. Fix it by running that, reviewing `git diff` and
committing — not by silencing the job.

Both halves of that table live in one place. The cadence is in the `.timer`
files, the threshold is in the `JOBS` table in
[`install-timers.sh`](../../scripts/install-timers.sh), and `make check-timers`
derives each timer's real period from `systemd-analyze calendar` and refuses to
pass if the threshold is less than twice it. Change one without the other and
`make validate` fails rather than the alerting quietly going wrong.

There is a third copy, and it is the one that actually bit:
**what systemd has enabled**. Adding a row here and a `.timer` file does not
install anything — that needs `sudo ./scripts/install-timers.sh --install` on
the monitoring host — and until it is run the job does not exist. Nothing could
see that state, because `ScheduledJobNeverRan` joins against
`homelab_job_max_age_seconds`, which `--install` is what writes: a declared but
uninstalled job has *neither* series and there is nothing to fire on.
`check-versions` sat in that state from
[#292](https://github.com/Gerrrt/HomeLab/issues/292) until 2026-09-06 and simply
never ran.

So `make check-timers` now also asks `systemctl is-enabled` for every declared
timer, and fails naming the ones that are not
([#339](https://github.com/Gerrrt/HomeLab/issues/339)). It is read-only and
means something only on the deployment checkout, so everywhere else — CI, a
worktree — it skips, the same way the `systemd-analyze verify` check does. **On
the monitoring host, a merged row that nobody installed is now a failed
`make validate` rather than silence.**

`make check-digests` is deliberately **not** here. It needs no host and no
secret, so it runs weekly in GitHub Actions
([`digests.yml`](../../.github/workflows/digests.yml)) instead — genuinely
off-host, which nothing else in this list is.

---

## Install

```bash
make check-timers
```

Then, from the deployment checkout — not a worktree, because the units carry
absolute paths and the installer refuses anywhere else:

```bash
make install-timers
```

That copies the units to `/etc/systemd/system`, creates
`/var/lib/node_exporter/textfile_collector`, writes the threshold declarations
into it, enables every timer, and primes each job by running it once.

`backup-volumes` is deliberately **not** primed: it stops the monitoring stack,
and that is not something to do as a side effect of an install. Run it when you
can watch — see below.

```bash
systemctl list-timers 'homelab-*'
```

## Prove it end to end

The cheapest real job first:

```bash
sudo systemctl start homelab-backup-firewall.service
```

```bash
journalctl -u homelab-backup-firewall.service -n 50 --no-pager
```

And that the export reached `oracle` — the second half of the listing:

```bash
make backup-firewall ARGS=--list
```

Then check the file it wrote. Every file must be `0644` and the directory
`0755` — Alloy reads them as root with every capability dropped, so it obeys the
mode like anyone else, and a `0600` file is simply invisible to it:

```bash
ls -l /var/lib/node_exporter/textfile_collector/
```

**The check that matters most.** Confirm the label survived the scrape:

```bash
curl -sG 'http://localhost:9090/api/v1/query' --data-urlencode 'query=homelab_job_last_success_timestamp_seconds' | python3 -m json.tool
```

`homelab_job` must be present, and **`exported_job` must not appear anywhere in
that output**. If it does, a `job` label got back into a `.prom` file: Alloy's
relabel rules set `job` on every target from that exporter and the scrape does
not honour conflicting labels, so the file's own value gets renamed and every
alert in `backup.rules.yaml` silently matches nothing.

Then the plumbing around it:

```bash
curl -sG 'http://localhost:9090/api/v1/query' --data-urlencode 'query=node_textfile_scrape_error'
```

```bash
curl -sG 'http://localhost:9090/api/v1/query' --data-urlencode 'query=homelab_job_max_age_seconds'
```

And the log path, in Grafana → Explore → Loki:

```logql
{unit="homelab-backup-firewall.service"}
```

## Make an alert fire without waiting a week

Write an old timestamp in, using the same temp-then-rename dance the wrapper
uses. A scrape that lands inside a non-atomic rewrite reads a truncated file,
which loses that job's metrics and raises `node_textfile_scrape_error`:

```bash
printf 'homelab_job_last_success_timestamp_seconds{homelab_job="backup-firewall"} %s\n' "$(date -d '30 days ago' +%s)" > /var/lib/node_exporter/textfile_collector/backup-firewall.prom.tmp
```

```bash
mv /var/lib/node_exporter/textfile_collector/backup-firewall.prom.tmp /var/lib/node_exporter/textfile_collector/backup-firewall.prom
```

Within a minute the expression is true. Evaluate it directly in **Prometheus →
Graph** rather than waiting out the `for: 30m`:

```promql
(time() - homelab_job_last_success_timestamp_seconds) > on(homelab_job) group_left() homelab_job_max_age_seconds
```

Then put the real value back:

```bash
sudo systemctl start homelab-backup-firewall.service
```

## The expensive one

Do this once, deliberately, while you are watching:

```bash
sudo systemctl start homelab-backup-volumes.service
```

```bash
grep downtime backups/volumes/*/MANIFEST | tail -1
```

> [!CAUTION]
> This stops Prometheus, Alertmanager, Loki, Grafana and Alloy for the length of
> the archive — which stops the `Watchdog` heartbeat along with them. The
> external cron-monitor in [`verify-the-alert-path.md`](verify-the-alert-path.md)
> has a grace period, and **the backup must finish inside it** or you get paged
> at 03:31 every Sunday for a backup that worked.
>
> The normal run is about ninety seconds against a fifteen-minute grace, which is
> comfortable — but check the `downtime` field above against your own monitor's
> grace rather than trusting that sentence. This is the reason
> `homelab-backup-volumes.timer` is the one timer here with
> `RandomizedDelaySec=0`: a randomised start would make the expected gap
> unstateable.

Two more things that look alarming and are not. `InstanceDown` does **not** fire
during a clean stop — it needs actual zero-valued samples for five minutes, and a
stopped scrape produces no samples at all. And Alertmanager's five-minute
`resolve_timeout` means anything that was firing when the stack went down expires
and re-notifies on the way back up, so a duplicate notification after a backup is
expected rather than a second fault.

---

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ScheduledJobNeverRan` right after install | The job has a threshold declared and has never reported a result | Expected for `verify-key-backup` until you first verify the key. For anything else, `systemctl start homelab-<job>.service` and read the journal |
| `ScheduledJobMetricsAbsent` | Nothing from the textfile directory has reached Prometheus in six hours | This is the whole directory, not one file — check Alloy is up and the directory still exists. A single malformed file shows as `node_textfile_scrape_error 1` and costs only that file |
| One job's series missing, `node_textfile_scrape_error` is 1 | That job's `.prom` failed to parse — a truncated write, or something wrote it without the temp-then-rename | The other files are unaffected. Re-run the job; if it recurs, something is writing the file directly instead of through `run-scheduled.sh` |
| Every `homelab_job_*` series missing, no scrape error | The `textfile` block in `config.alloy` is not reading the right path | It must carry the `ALLOY_ROOTFS` prefix (`/rootfs` in the container). `rootfs_path` does **not** apply to that argument, and a wrong path reports an empty directory rather than an error |
| A metric exists but no alert can fire | `exported_job` in the query output | A `job` label got into a `.prom` file. Fix the label name in `run-scheduled.sh` |
| `homelab_job_last_exit_code` is 75 | The job never started — another job held its lock for the full wait | Expected if a `--verify-only` run collided with a long backup. Persistent means a job is hanging: check `systemctl list-units 'homelab-*'` |
| `backup-firewall` exits 1 with *off-host copy FAILED* | `oracle` is down, its host key is not in `robo`'s `known_hosts`, or this host's key is not authorised there | The export was written locally and is intact. Repair the path to `oracle` — [`restore-the-firewall.md`](restore-the-firewall.md) §0 — and the next run copies every file that never left |
| `dashboards-drift` exits 1 | Grafana holds a dashboard edit that is not committed | Not a fault. Run `make dashboards-export`, read `git diff`, commit it. If the diff is empty but the job still fails, Grafana is down or `make render` has never run here |
| `loki-coverage` exits 1 | A Loki alerting rule cannot see a host that is producing exactly the lines it hunts | Not an outage — nothing is broken, but an alert cannot fire for that host, which is how [#261](https://github.com/Gerrrt/HomeLab/issues/261) went unnoticed. The FAIL line names the rule, the host and the log type the lines are arriving under; the fix is usually an `or` branch on the rule for that host's stream. A `WARN` is the latent form — the rule cannot reach the host at all, but nothing there matches it today — and does not fail the job |
| `check-versions` exits 1 | A document names an OS version the host is not running | Not an outage — nothing is broken. Read the FAIL lines: each names the document, the cell and what the host reports. Correct the document; the box is the source of truth. A `SKIP` for `morpheus` instead means `sysDescr` is not reaching Prometheus, which is a collection fault rather than a clean bill of health |
| `docker info` fails only under systemd | The unit is missing `SupplementaryGroups=docker` | A login shell picks the group up from `/etc/group` and a unit does not, which is why this never reproduces by hand |
| Timers exist but never fire | `WantedBy=timers.target` missing, or the timers were never enabled | `systemctl list-timers 'homelab-*'` shows nothing; re-run `make install-timers` |
| `ScheduledJobMetricsAbsent` fires and nothing else in `backup.rules.yaml` ever has | This step was never run at all | `systemctl list-unit-files 'homelab*'` reports *0 unit files* and `/var/lib/node_exporter/textfile_collector` does not exist. The four other rules here join against a series `--install` writes, so none of them can fire — that alert is the only one that can, and it is doing its job ([#215](https://github.com/Gerrrt/HomeLab/issues/215)). Run `make install-timers` |
| `converge` fails every hour with a signature error | GitHub's signing key was never imported into `robo`'s keyring, so nothing on this host can verify | The one-time import in [`converge-the-host.md`](converge-the-host.md) §Set it up. Every other job here is unaffected |
| `refusing to install from …` | You are in a worktree or a second clone | The units hardcode the deployment path. Install from `/home/robo/code/Gerrrt/HomeLab` |
| `make validate` fails on the schedule | A cadence and its threshold disagree | `make check-timers` names the job and both numbers. Fix the `JOBS` table or the `.timer`, not the alert |
| `make validate` fails with *no `homelab-*` units are installed* | The stack is running on this host but the schedule was never installed | Exactly the condition above, caught before an alert has to. Only a host running the stack is asked; a laptop with the repository checked out skips it |

## Removing it

```bash
sudo ./scripts/install-timers.sh --uninstall
```

The `.prom` files are left in place on purpose. Deleting them would make every
job look like it had *never run* rather than like it had *stopped being
scheduled*, and those are different findings.
