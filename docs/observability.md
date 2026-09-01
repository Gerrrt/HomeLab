# Observability

What is collected, where it goes, and how to change it.

## What is collected

| Source | Via | Interval | Examples |
| --- | --- | --- | --- |
| Linux hosts | Alloy → `node_exporter` | 60s | CPU, memory, filesystem, network, load, clock offset |
| Docker containers | Alloy → cAdvisor | 60s | Per-container CPU, memory, network, restarts, OOM |
| Container logs | Alloy → Docker socket | stream | stdout/stderr per container |
| systemd journal | Alloy | stream | unit, boot ID, transport, priority |
| `/var/log/auth.log` | Alloy | 60s poll | sshd, sudo, PAM |
| syslog, `/var/log/*.log` | Alloy | 60s poll | Everything else |
| pfSense | snmp-exporter | 60s | pf state table, counters, interface stats |
| MokerLink switch | snmp-exporter | 60s | Interface status and octet counters |
| APC UPS | snmp-exporter | 60s | Charge, runtime, load, voltage, alarms |
| ProLiant iLO | snmp-exporter | 60s | Temperature, PSU, drive and battery health |
| The stack itself | Prometheus | 15s | Every component scrapes itself |
| Each Alloy agent | Alloy → itself | 60s | Remote-write throughput and lag, component health, lines forwarded |

Retention is 30 days for both metrics (`PROMETHEUS_RETENTION` in `.env`) and
logs (`retention_period` in `loki/loki-config.yaml`). Change both together or
dashboards will show metrics with no matching logs at the far end of the range.

Metrics carry a second bound: `PROMETHEUS_RETENTION_SIZE` caps the store at
12 GiB, and whichever limit is reached first wins. It is sized from the write
rate rather than the store's current size — 72.9 MiB/day gives 2.28 GiB over
30 days, 2.73 GiB once `Saruman` gets an agent — so it is roughly 4.4x the
planned estate and should never bind. In normal operation the 30 days above is
the limit that applies; if the size cap ever binds, that 30 days stops being
true and `PrometheusSizeRetentionActive` is what says so. Loki has no
equivalent size bound.

## Log level normalisation

Logs arrive spelling severity about twenty different ways — `ERROR`, `err`,
`eror`, `crit`, `fatal`, `panic`, `dbug`. The `log_processor` stage in
`config.alloy` maps all of them onto five canonical values before they reach
Loki:

```text
emerg, panic, corrupt, fatal, alert, crit, critical  →  critical
err, eror, error                                     →  error
warn, warning                                        →  warning
info, information, informational, notice             →  info
dbug, debug, dbg                                     →  debug
```

This is what makes `{level="error"}` a useful query across a FreeBSD firewall, a
Ubuntu host and a Go container at the same time.

> **This was silently broken until recently.** The extracting regex used `\b`
> inside a double-quoted Alloy string, where `\b` is a backspace escape rather
> than a word boundary. The regex never matched, so the template's
> `{{ else }}info{{ end }}` fallback labelled *every* line `info`. It is now a
> backtick string. If you edit that stage, verify afterwards that
> `sum by (level) (count_over_time({host=~".+"}[1h]))` returns more than one
> series.

## Dashboards

Seven dashboards are provisioned from `grafana/dashboards/` into a **HomeLab**
folder:

| Dashboard | UID | Covers |
| --- | --- | --- |
| Host Overview | `homelab-host-overview` | CPU, memory, storage, network per host |
| Docker Containers | `homelab-docker` | Per-container resources, restarts, OOM kills |
| Network & Firewall | `homelab-network` | pf state table, switch interfaces, iLO health |
| UPS & Power | `homelab-ups` | Battery, runtime, load, input voltage |
| Logs | `homelab-logs` | Volume by level and source, error and auth streams |
| Observability Stack | `homelab-stack` | Scrape health for every target, and Prometheus, Loki, Alertmanager and Alloy watching themselves |
| Security | `homelab-security` | Firewall blocks by interface and direction, top blocked sources, Suricata classification and priority, terminal-segment violations |

`allowUiUpdates` is `false`, so edits made in the Grafana UI are discarded on
restart. That is deliberate — the JSON in git is the source of truth. To change
a dashboard: edit it in the UI, **Dashboard settings → JSON Model**, copy, and
commit it over the file. CI checks the result parses, that every datasource UID
resolves, that panels fit the grid and do not overlap, and that every panel
expression is syntactically valid — PromQL through `promtool`, LogQL through a
real Loki, since nothing else parses it.

### Watching the collection path

`homelab-stack` exists because the stack watched four devices and two hosts
attentively and did not watch itself at all
([#81](https://github.com/Gerrrt/HomeLab/issues/81)). Two of the three faults
found while verifying #12 would have been visible on it within a minute:
remote_write failing to a stale address, and cAdvisor reporting one series where
it should report hundreds. Both were invisible for hours because the only view
of the collection path was `up{job="alloy"}`, which stayed `1` throughout.

`up` is a poor liveness signal for half of what this stack collects, and the
dashboard says so rather than papering over it. Prometheus scrapes nine jobs
directly; four more arrive by remote_write from an Alloy agent. **A directly
scraped target that dies sets `up` to 0. A remote-writing agent that dies just
stops pushing, so its `up` goes stale and ages out instead of falling** — and
`InstanceDown` is `up == 0`, so it cannot see that at all. The *Sample staleness
by job* panel is what covers those four on the dashboard, and the *Every target*
table puts `Staleness` next to `Up` for the same reason.

`RemoteWriteJobStale` in `stack.rules.yaml` is the alert for it, and it is
deliberately not written as a threshold on that staleness panel. `time() -
timestamp(up) > 300` reads correctly and cannot fire for any input: an instant
selector stops returning a sample once the lookback delta passes, so the
difference is bounded below any threshold worth alerting on. Measured over 24
hours of real data the largest value any job reached was 79 seconds. The rule
therefore asks the question the other way round — which jobs were reporting in
the last 24 hours and are not reporting now — because `count_over_time` reads a
range and sees through staleness where an instant selector cannot.

Two consequences worth knowing. It matches on the job-name convention
`config.alloy` builds (`<hostname>-metrics`, `<hostname>-alloy`,
`integrations/cadvisor`) rather than a list, so a new agent is covered the day
it is deployed and `Saruman` ([#88](https://github.com/Gerrrt/HomeLab/issues/88))
will need nothing added. And the 24-hour window is a real bound: an agent that
comes back inside a day resolves the alert truthfully, one that stays away
longer resolves it falsely once the window no longer remembers it, having
notified at least twice by then.

Alongside it, **samples returned per scrape** is the panel that catches a
collector which is still answering but has stopped exporting most of what it
used to. That is precisely the cAdvisor fault: `up` at 1, scrape succeeding,
one series where there should be hundreds.

Since #81 each Alloy agent also scrapes itself and remote-writes the result
under `<hostname>-alloy`, so `prometheus_remote_storage_*` and
`alloy_component_*` exist for every agent rather than only the one on this host.
`oracle` publishes Alloy's port on loopback (ADR-0012) and there is no address
Prometheus could be pointed at; pushing down the pipe that is already open costs
nothing and needs no new exposure. The monitoring host's agent is consequently
collected twice — `job="alloy"` by direct scrape and `job="prometheus-alloy"` by
push — which is deliberate: the first is the only one whose `up` can reach 0.

### Drawing the labels the parsing work exists to produce

`homelab-security` exists because `config.alloy` went to real trouble to extract
`interface`, `action` and `direction` from pfSense filterlog, and
`classification` and `priority` from Suricata; five Loki rules fire on them; and
nothing charted any of it ([#82](https://github.com/Gerrrt/HomeLab/issues/82)).
"Network & Firewall" is SNMP — the pf state table and interface counters — and
says nothing about what the firewall decided. "Logs" counts lines by level. The
dimensions the parsing exists to produce had no view, so the only way to see a
scan, a misconfigured device or a segmentation failure was as an alert that had
already fired.

Two things about it are worth stating here rather than only in a panel
description.

**Addresses are parsed at query time, not indexed.** *Top blocked source
addresses* runs `| regexp` over the line body, because ADR-0003 keeps addresses
out of the labels and a label per source address is the textbook way to detonate
Loki's cardinality. The regex anchors on the adjacent `src,dst` pair rather than
counting CSV fields, because pfSense's IPv6 filterlog layout puts `src` at a
different index — v6 lines therefore do not appear in that table, which is a
stated limit rather than an oversight.

**It cannot tell you the IDS is alive.** Suricata watches the Skids (VLAN 20)
interface only, and a quiet IDS and a stopped one produce identical output — so
empty Suricata panels are not evidence of anything. That is the same gap
`security.rules.yaml` declines to paper over with a log-based rule, and it needs
a process metric. The dashboard says so in a text panel at the top rather than
letting a flat line be read as calm.

**And it found that this firewall logs blocks only.** Building the panels turned
up something the alerts had not: across the full 30-day retention the `action`
label has exactly one value, `block`, at roughly 85,000 lines a day and not one
`pass`. `TerminalSegmentReachedInternalNetwork` matches `{app="filterlog",
action="pass"}`, so **it cannot fire for any input** — the same shape of defect
as [#63](https://github.com/Gerrrt/HomeLab/issues/63), where
`ContainerHighMemory` divided by a limit no service set and showed as loaded and
healthy throughout. Arming it means enabling logging on the inter-VLAN pass
rules in pfSense, which is tracked in
[#223](https://github.com/Gerrrt/HomeLab/issues/223).

This is why the two pass-dependent stats read *not logged* rather than `0`.
Zero would be a measurement, and none was taken; the distinction is the whole
reason the panel says which it is.

## Alerting

59 rules in total: 46 metric-based in `prometheus/rules/`, and 13 log-based in
`loki/rules/`.

### Log-based (Loki ruler)

Some conditions only exist in logs. A metric confirms sshd is running; only the
log shows it rejecting forty passwords in five minutes. `loki/rules/security.rules.yaml`
covers SSH brute force, SSH accepted from outside VLAN 50/99, repeated sudo
failures, user/group creation, kernel OOM kills, read-only remounts and disk I/O
errors.

They use the same `severity` and `category` labels as the Prometheus rules and
are sent to the same Alertmanager, so routing and inhibition are shared.

Loki's local ruler reads `<directory>/<tenant>/`, and with `auth_enabled: false`
the tenant is literally `fake` — hence the `loki/rules:/etc/loki/rules/fake`
mount in `compose.yaml`. Getting that path wrong produces no error, just a ruler
that silently evaluates nothing.

`promtool` cannot validate these; it parses PromQL and rejects every LogQL
stream selector. `scripts/check_loki_rules.sh` boots the pinned Loki image with
the rules mounted and fails on a parse error, then asserts the ruler actually
evaluated them. Note that `loki -verify-config` is *not* sufficient on its own —
it validates the config file and never opens the rule files. A file containing
`count_over_time({{{BROKEN` passes `-verify-config` and is caught only by the
boot check.

### Metric-based (Prometheus)

46 rules across eight files in `prometheus/rules/`:

| File | Covers |
| --- | --- |
| `host.rules.yaml` | Instance down, predictive disk fill, memory, load, clock skew, reboots |
| `network.rules.yaml` | SNMP reachability, pf not running, state table, switch links, iLO hardware and Smart Array cache. `shiva`'s Smart Storage Battery has read failed since 2026-08-18 and the array has dropped to write-through as a result — `IloBatteryCondition` names the spare part to order, and the controller rollups are deliberately read at *failed* rather than *degraded* ([#76](https://github.com/Gerrrt/HomeLab/issues/76)) |
| `ups.rules.yaml` | On battery, low battery, runtime, load, temperature. A pack was fitted on 2026-08-28 and passed its self-test, so these read real hardware; stored metrics older than that date are the card's fabricated values — see [`runbooks/fit-the-ups-battery.md`](runbooks/fit-the-ups-battery.md) |
| `containers.rules.yaml` | Restart loops, OOM kills, memory, throttling |
| `stack.rules.yaml` | The stack watching itself: config reloads, rule evaluation, notification delivery, log ingestion, and remote-writing agents that stop pushing — the case `up == 0` structurally cannot see. Split off `containers.rules.yaml` onto `component: stack` in [#81](https://github.com/Gerrrt/HomeLab/issues/81) so a Prometheus that cannot reload its config stops being filed as a container fault |
| `watchdog.rules.yaml` | One rule that always fires, so that its absence is detectable |
| `blackbox.rules.yaml` | Whether an endpoint can actually be reached, from outside the service |
| `backup.rules.yaml` | Whether the scheduled maintenance jobs are still being run at all — staleness, failure, and never-ran |

`promtool check rules` validates that these parse. It does not — and cannot —
tell you whether a rule can ever be true: `ContainerHighMemory` passed it for
months while dividing by a memory limit no service sets, so it showed as loaded
and healthy and could not fire for any input ([#63](https://github.com/Gerrrt/HomeLab/issues/63)).
`prometheus/tests/*.test.yaml` holds `promtool test rules` unit tests, which
feed a rule synthetic series and assert it fires — paired with a case asserting
it stays quiet, because a test that only ever expects silence would have passed
against the broken rule too. Coverage is fifteen rules of 46 so far — the three
in `blackbox.rules.yaml`, `ContainerHighMemory` and
`PrometheusSizeRetentionActive`, `Watchdog`, the three iLO rules from
[#76](https://github.com/Gerrrt/HomeLab/issues/76), all five in
`backup.test.yaml`, and `RemoteWriteJobStale`.
The other 31 are still validated for syntax only, which is exactly the
standing #63 had. Both numbers are checked by `scripts/check_docs.py` — the
sentence they replaced claimed six and named two, and had been wrong for
weeks. Keep each count on one line: the checker reads prose line by line, so a
phrase wrapped mid-claim is a claim it cannot see.

Disk alerting is predictive rather than a fixed threshold — `predict_linear` over
a 6-hour window, firing when the extrapolation reaches zero within a day *and*
free space is already under 30%. A disk sitting at 86% and stable is not an
emergency; one climbing fast at 60% is.

### Routing

Three receivers, **three separate destinations** (see
`alertmanager/alertmanager.yaml`). They were three names for one webhook URL
until [#66](https://github.com/Gerrrt/HomeLab/issues/66), which meant `urgent`
and `default` differed only in how often they repeated — a UPS on battery and a
slow scrape landed in the same place. The routing tree decides which alert is
urgent; only a distinct destination makes that difference audible, because
per-topic sound and do-not-disturb settings live on the receiving end.

| Matches | Receiver | First notification | Repeats |
| --- | --- | --- | --- |
| `critical` + `category=power` | `urgent` | immediately | 30m |
| `critical` + `category=security` | `security` | immediately | 1h |
| `warning` + `category=security` | `security` | 30s | 4h |
| `critical` (anything else) | `urgent` | 10s | 4h |
| `warning` (anything else) | `default` | 30s | 12h |
| `info` | `null` | never | — |

Security has its own destination at both severities because ten rules carry
`category: security` — SSH brute force, a terminal segment reaching the internal
network, IoT lateral movement, priority-1 Suricata — and routed on `severity`
alone, the warning-severity half of that list arrived in the default channel on
a 12-hour repeat, indistinguishable from a disk filling up. `category=power`
was the precedent.

**First match wins and nothing sets `continue`, so the order of those rows is
the design.** A category route moved below the bare `severity` rows silently
stops matching, and `amtool check-config` still reports SUCCESS — that mutation
was tried. `scripts/validate.sh` and CI therefore assert the table itself with
`amtool config routes test --verify.receivers`, one assertion per row.

Inhibit rules stop cascades: a down host suppresses its own disk warnings, and a
dead `snmp-exporter` suppresses the "every device is unreachable" storm that
would otherwise follow.

### The dead man's switch

`AlertmanagerNotificationsFailing` catches delivery *errors*. It cannot catch a
webhook URL that is well-formed, reachable, and pointed at nothing — a 200 into a
deleted ntfy topic is a successful notification by every measure Alertmanager
has. That is not hypothetical: the webhook was the `ntfy.example.invalid`
placeholder for the entire life of the stack and nothing noticed, because the
only symptom is that alerts stop arriving, which is also what a healthy week
looks like ([#67](https://github.com/Gerrrt/HomeLab/issues/67)).

`prometheus/rules/watchdog.rules.yaml` holds one rule, `Watchdog`, whose
expression is `vector(1)`. It fires unconditionally and forever. **Its firing
carries no information; its absence is the entire signal.** One `continue: true`
— the only one in the tree — sends it to two places:

| Route | Destination | Cadence | Catches |
| --- | --- | --- | --- |
| `heartbeat` | external cron-monitor ping | 5m | Prometheus stopped evaluating, Alertmanager died, no outbound network |
| `default` | the real alert channel | 24h | the alert channel itself is a 200 into nothing |

Neither half substitutes for the other. The heartbeat proves delivery to a
*different* URL than real alerts use, so it cannot see a deleted topic; the daily
notification travels the identical URL your warnings travel, but nothing
machine-checks its absence.

The watcher lives off this host by necessity — a watcher here fails at the same
moment as the thing it is watching. Setting it up, the coupling between
`repeat_interval` and the external check's period and grace, and how to read
which half went quiet are in
[`runbooks/verify-the-alert-path.md`](runbooks/verify-the-alert-path.md).

This is the same reasoning `loki/rules/security.rules.yaml` already applies to
the firewall with `FirewallLogsStopped`, and the reason it gives for deliberately
*not* writing a `SuricataStopped` rule: absence of alerts is indistinguishable
from absence of the service, and detecting that needs a heartbeat rather than a
threshold. The notification path was the one place that argument had not been
turned on itself.

### Scheduled jobs

The same inversion, applied to maintenance. `make backup`,
`make backup-firewall`, `make snmp-verify` and `make secrets-verify-backup` were
all commands someone had to remember, and nothing ran any of them
([#77](https://github.com/Gerrrt/HomeLab/issues/77)). A job that fails is loud;
a job that stops being run is silent, and silence is also what a healthy week
looks like.

Four of them are now systemd timers on the monitoring host. Every run — timer or
human — goes through `scripts/run-scheduled.sh`, which records four gauges into
a textfile the node exporter already scrapes:

| Metric | Says |
| --- | --- |
| `homelab_job_last_success_timestamp_seconds` | when this job last exited 0. A failed run carries the previous value forward rather than clobbering it |
| `homelab_job_last_run_timestamp_seconds` | when it last finished, whatever the outcome |
| `homelab_job_last_exit_code` | 0, or 75 for "never started, another job held the lock" |
| `homelab_job_duration_seconds` | how long it took |

The threshold each job is held to is a *fifth* series,
`homelab_job_max_age_seconds`, written by `scripts/install-timers.sh` from the
same table that decides the cadence. That is what lets the five rules in
`prometheus/rules/backup.rules.yaml` cover every job without naming any of them,
and what makes `make check-timers` able to assert that a threshold is at least
twice its timer's real period.

Two things are deliberate and easy to undo by accident:

- **The label is `homelab_job`, not `job`.** `config.alloy`'s
  `discovery.relabel "metrics"` sets `job` on every target from that exporter,
  and scrapes default to `honor_labels: false` — so a `job` label in the file
  would arrive as `exported_job` and every rule would match nothing while still
  showing as loaded and healthy. `backup.test.yaml` has a case that pins this.
- **The staleness rules compare against a stored timestamp rather than using a
  long `for:`.** A long `for` measures continuous pending time in Prometheus's
  own memory, and one of the jobs being measured is the one that stops
  Prometheus. `UpsBatteryUnproven` records the same reasoning.

**What this does not prove.** Every one of these jobs runs on the machine it is
checking, with the key that is on that machine, against the disk that is in it.
`verify-backups` proves an archive still decrypts; it says nothing about a dead
disk or a fire. The only job that proves off-host recoverability is
`secrets-verify-backup`, and it is precisely the one that cannot be automated —
it needs a human to mount removable media, so `SecretsKeyBackupUnproven` nags at
ninety days instead. Getting the sets off this machine is
[#92](https://github.com/Gerrrt/HomeLab/issues/92).

Installing, tuning and troubleshooting all of it:
[`runbooks/schedule-maintenance.md`](runbooks/schedule-maintenance.md).

## Adding a monitored device

See [`runbooks/add-monitored-device.md`](runbooks/add-monitored-device.md). In
short:

- **A Linux host:** run Alloy with `LOKI_URL` and
  `PROMETHEUS_REMOTE_WRITE_URL` pointed at `10.0.99.20`. Nothing on the
  monitoring host changes.
- **An SNMP device:** append a target to
  `prometheus/targets/snmp.yaml` and a module plus auth to
  `snmp-exporter/generator.yaml`. file_sd picks the target up within five
  minutes without a restart.

## Cardinality

The stack is small, but two things will bite if ignored:

- **The `ilo` SNMP module exposes ~1,600 metrics.** The HP Insight tree is
  enormous. It is scraped once a minute from one device, which is fine — but do
  not add a second module that broad without trimming the OID list in
  `generator.yaml`. All four modules together are ~1,800 metrics per scrape
  cycle.
- **Loki labels must stay low-cardinality.** `host`, `level`, `log_type`,
  `service_name` and `unit` are bounded. Never promote a request ID, IP address
  or timestamp to a label; use `|=` line filters instead.

`module` and `auth` are deliberately dropped by `labeldrop` in `prometheus.yaml`
after being converted to query parameters, so they never become metric labels.

## Operating

```bash
make up                    # render secrets, start everything
make ps                    # container status
make logs SERVICE=grafana  # tail one service
make reload                # hot-reload Prometheus, Alertmanager, snmp-exporter
make validate              # everything CI runs
make backup                # quiesce, archive, encrypt and verify the data volumes
make restore ARGS=--list   # the backup sets that exist
make down                  # stop, keep data
make nuke                  # stop, destroy data (prompts) — recoverable, see
                           #   docs/runbooks/restore-the-stack.md
```

Prometheus and Alertmanager are started with lifecycle endpoints enabled, so
rule and route changes apply via `make reload` without dropping the TSDB head
block. snmp-exporter serves `POST /-/reload` unconditionally, with no lifecycle
flag to enable.

`make up` runs that same reload as its last step. It has to: `docker compose up
-d` keys off the service definition, not the contents of the files it mounts,
so without the reload a re-rendered config would sit on disk while the
container served the copy it parsed at startup.
