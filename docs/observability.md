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

32 rules across four files in `prometheus/rules/`:

| File | Covers |
| --- | --- |
| `host.rules.yaml` | Instance down, predictive disk fill, memory, load, clock skew, reboots |
| `network.rules.yaml` | SNMP reachability, pf not running, state table, switch links, iLO hardware |
| `ups.rules.yaml` | On battery, low battery, runtime, load, temperature |
| `containers.rules.yaml` | Restart loops, OOM kills, throttling, and the stack watching itself |

Routing is by `severity` and `category` (see `alertmanager/alertmanager.yaml`).
`critical` + `category=power` pages immediately and repeats every 30 minutes;
other criticals repeat every 4 hours; warnings every 12; `info` is recorded but
never notified.

Inhibit rules stop cascades: a down host suppresses its own disk warnings, and a
dead `snmp-exporter` suppresses the "every device is unreachable" storm that
would otherwise follow.

Disk alerting is predictive rather than a fixed threshold — `predict_linear` over
a 6-hour window, firing when the extrapolation reaches zero within a day *and*
free space is already under 30%. A disk sitting at 86% and stable is not an
emergency; one climbing fast at 60% is.

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

- **The `ilo` SNMP module exposes ~1,355 metrics.** The HP Insight tree is
  enormous. It is scraped once a minute from one device, which is fine — but do
  not add a second module that broad without trimming the OID list in
  `generator.yaml`.
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
make reload                # hot-reload Prometheus + Alertmanager config
make validate              # everything CI runs
make backup                # tar the data volumes into ./backups/
make down                  # stop, keep data
make nuke                  # stop, destroy data (prompts)
```

Prometheus and Alertmanager are started with lifecycle endpoints enabled, so
rule and route changes apply via `make reload` without dropping the TSDB head
block.
