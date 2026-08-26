# Observability stack

Runs on `prometheus` (10.0.99.20), VLAN 99.

```bash
make up        # from the repository root
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `prometheus` | `prom/prometheus` | 9090 | Metrics store, remote-write receiver, rule evaluation |
| `alertmanager` | `prom/alertmanager` | 9093 | Alert routing, grouping, inhibition |
| `loki` | `grafana/loki` | 3100 | Log store |
| `grafana` | `grafana/grafana-oss` | 3000 | Dashboards |
| `snmp-exporter` | `prom/snmp-exporter` | *internal* | SNMP polling proxy |
| `alloy` | `grafana/alloy` | 12345 (localhost) | Metric and log collection |

## Layout

```text
compose.yaml               all six services, one network, health-gated ordering
.env.example               non-sensitive tunables (ports, retention, bind address)
prometheus/
  prometheus.yaml          scrape config; SNMP via file_sd
  targets/snmp.yaml        SNMP targets — hot-reloaded, no restart needed
  rules/*.rules.yaml       35 alert rules across host/network/ups/containers
  tests/*.test.yaml        promtool unit tests — assert the rules can fire
alertmanager/
  alertmanager.yaml        severity + category routing, inhibition
loki/loki-config.yaml      single-binary, filesystem, 30-day retention
alloy/config.alloy         the agent config, identical on every monitored host
snmp-exporter/
  generator.yaml           source of truth — edit this
  snmp.yaml                generated, 14k lines, ${PLACEHOLDER} communities
grafana/
  provisioning/            datasources + dashboard provider
  dashboards/*.json        5 dashboards, 84 panels
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
- **Image tags are pinned, and the versions are not repeated here.** Every image
  in `compose.yaml` carries a tag *and* a `sha256:` digest; CI fails on
  `:latest` and on any image missing a digest, and Dependabot proposes bumps.
  The table above deliberately names images without versions — Dependabot only
  edits `compose.yaml`, so a version written anywhere else goes stale the moment
  it lands, which is what happened to all six of these (#73).
  `scripts/check_docs.py` now fails the build if a version pin reappears in
  prose. `docker compose images` prints what is actually running.

## Validate before deploying

```bash
make validate
```

Runs `docker compose config`, `promtool check config`, `promtool check rules`,
`promtool test rules`, `amtool check-config`, `alloy fmt --verify`, the
dashboard checks, yamllint, markdownlint, shellcheck and gitleaks. Same set CI
runs.
