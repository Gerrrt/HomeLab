# Observability stack

Runs on `prometheus` (10.0.99.20), VLAN 99.

```bash
make up        # from the repository root
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `prometheus` | `prom/prometheus:v3.1.0` | 9090 | Metrics store, remote-write receiver, rule evaluation |
| `alertmanager` | `prom/alertmanager:v0.28.0` | 9093 | Alert routing, grouping, inhibition |
| `loki` | `grafana/loki:3.3.2` | 3100 | Log store |
| `grafana` | `grafana/grafana-oss:11.5.2` | 3000 | Dashboards |
| `snmp-exporter` | `prom/snmp-exporter:v0.28.0` | *internal* | SNMP polling proxy |
| `alloy` | `grafana/alloy:v1.6.1` | 12345 (localhost) | Metric and log collection |

## Layout

```text
compose.yaml               all six services, one network, health-gated ordering
.env.example               non-sensitive tunables (ports, retention, bind address)
prometheus/
  prometheus.yaml          scrape config; SNMP via file_sd
  targets/snmp.yaml        SNMP targets — hot-reloaded, no restart needed
  rules/*.rules.yaml       32 alert rules across host/network/ups/containers
alertmanager/
  alertmanager.yaml        severity + category routing, inhibition
loki/loki-config.yaml      single-binary, filesystem, 30-day retention
alloy/config.alloy         the agent config, identical on every monitored host
snmp-exporter/
  generator.yaml           source of truth — edit this
  snmp.yaml                generated, 14k lines, ${PLACEHOLDER} communities
grafana/
  provisioning/            datasources + dashboard provider
  dashboards/*.json        5 dashboards, 79 panels
```

## Things worth knowing before editing

- **`snmp-exporter/snmp.yaml` is generated.** Edit `generator.yaml` and run
  `make snmp-generate`. Its community strings are `${PLACEHOLDERS}`;
  `scripts/render-config.sh` renders the real file into a gitignored
  `.rendered/` directory at deploy time.
- **Grafana UI edits are discarded on restart** (`allowUiUpdates: false`). Export
  the JSON model and commit it — see
  [`docs/observability.md`](../../docs/observability.md#dashboards).
- **Rules and routes hot-reload** with `make reload`. No restart, no TSDB head
  block dropped.
- **Adding an SNMP target needs no restart** — file_sd re-reads every 5 minutes.
  Adding a *module* does, because snmp-exporter reads its config once.
- **Image tags are pinned.** CI fails on `:latest`. Dependabot proposes bumps.

## Validate before deploying

```bash
make validate
```

Runs `docker compose config`, `promtool check config`, `promtool check rules`,
`amtool check-config`, `alloy fmt --verify`, the dashboard checks, yamllint,
markdownlint, shellcheck and gitleaks. Same set CI runs.
