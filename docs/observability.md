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

Retention is 30 days for both metrics (`PROMETHEUS_RETENTION` in `.env`) and
logs (`retention_period` in `loki/loki-config.yaml`). Change both together or
dashboards will show metrics with no matching logs at the far end of the range.

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

Five dashboards are provisioned from `grafana/dashboards/` into a **HomeLab**
folder:

| Dashboard | UID | Covers |
| --- | --- | --- |
| Host Overview | `homelab-host-overview` | CPU, memory, storage, network per host |
| Docker Containers | `homelab-docker` | Per-container resources, restarts, OOM kills |
| Network & Firewall | `homelab-network` | pf state table, switch interfaces, iLO health |
| UPS & Power | `homelab-ups` | Battery, runtime, load, input voltage |
| Logs | `homelab-logs` | Volume by level and source, error and auth streams |

`allowUiUpdates` is `false`, so edits made in the Grafana UI are discarded on
restart. That is deliberate — the JSON in git is the source of truth. To change
a dashboard: edit it in the UI, **Dashboard settings → JSON Model**, copy, and
commit it over the file. CI checks the result parses, that every datasource UID
resolves, that panels fit the grid and do not overlap, and that every PromQL
expression in every panel is syntactically valid.

## Alerting

51 rules in total: 38 metric-based in `prometheus/rules/`, and 13 log-based in
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

38 rules across six files in `prometheus/rules/`:

| File | Covers |
| --- | --- |
| `host.rules.yaml` | Instance down, predictive disk fill, memory, load, clock skew, reboots |
| `network.rules.yaml` | SNMP reachability, pf not running, state table, switch links, iLO hardware |
| `ups.rules.yaml` | On battery, low battery, runtime, load, temperature. A pack was fitted on 2026-08-28 and passed its self-test, so these read real hardware; stored metrics older than that date are the card's fabricated values — see [`runbooks/fit-the-ups-battery.md`](runbooks/fit-the-ups-battery.md) |
| `containers.rules.yaml` | Restart loops, OOM kills, memory, throttling, and the stack watching itself |
| `watchdog.rules.yaml` | One rule that always fires, so that its absence is detectable |
| `blackbox.rules.yaml` | Whether an endpoint can actually be reached, from outside the service |

`promtool check rules` validates that these parse. It does not — and cannot —
tell you whether a rule can ever be true: `ContainerHighMemory` passed it for
months while dividing by a memory limit no service sets, so it showed as loaded
and healthy and could not fire for any input ([#63](https://github.com/Gerrrt/HomeLab/issues/63)).
`prometheus/tests/*.test.yaml` holds `promtool test rules` unit tests, which
feed a rule synthetic series and assert it fires — paired with a case asserting
it stays quiet, because a test that only ever expects silence would have passed
against the broken rule too. Coverage is two rules of 35 so far:
`ContainerHighMemory` and `Watchdog`. The other 33 are still validated for
syntax only, which is exactly the standing #63 had.

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

## Adding a monitored device

See [`runbooks/add-monitored-device.md`](runbooks/add-monitored-device.md). In
short:

- **A Linux host:** widen the Prometheus and Loki binds in `compose.yaml`
  first — they are `127.0.0.1` by default (#70) — then run Alloy with
  `LOKI_URL` and `PROMETHEUS_REMOTE_WRITE_URL` pointed at `10.0.99.20`. That
  bind change is the only thing on the monitoring host that has to move.
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
