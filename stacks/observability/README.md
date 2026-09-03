# Observability stack

Runs on `prometheus` (10.0.99.20), VLAN 99.

```bash
make up        # from the repository root
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `prometheus` | `prom/prometheus` | 9090 | Metrics store, remote-write receiver, rule evaluation |
| `alertmanager` | `prom/alertmanager` | 9093 (localhost) | Alert routing, grouping, inhibition |
| `loki` | `grafana/loki` | 3100 | Log store |
| `grafana` | `grafana/grafana-oss` | 3000 (https) | Dashboards — the only published UI, and the only service that terminates TLS or authenticates |
| `snmp-exporter` | `prom/snmp-exporter` | *internal* | SNMP polling proxy |
| `alloy` | `grafana/alloy` | 12345 (localhost) | Metric and log collection |

"(localhost)" means bound to `127.0.0.1`: reachable from the monitoring host
itself and over the compose network, and from no VLAN at all. A port is
published only when something off-host uses it, and nothing off-host uses
Alertmanager (#70). The rest, plus the Alloy syslog receiver on 1514/udp, bind
to `BIND_ADDR`. Reasoning in
[`docs/architecture.md`](../../docs/architecture.md#ports).

## Layout

```text
compose.yaml               all seven services, one network, health-gated ordering
.env.example               non-sensitive tunables (ports, retention, bind address)
                           edit this, not .env — .env is regenerated on `make up`
prometheus/
  prometheus.yaml          scrape config; SNMP via file_sd
  targets/snmp.yaml        SNMP targets — hot-reloaded, no restart needed
  targets/blackbox.yaml    probe targets — hot-reloaded, no restart needed
  rules/*.rules.yaml       48 alert rules across host/network/ups/containers/blackbox/backup/ids
  tests/*.test.yaml        promtool unit tests — assert the rules can fire
blackbox/blackbox.yaml     probe modules — reachability from outside the service
alertmanager/
  alertmanager.yaml        severity + category routing, inhibition
loki/loki-config.yaml      single-binary, filesystem, 30-day retention
alloy/                     the agent config — Alloy loads the directory
  config.alloy             every monitored host
  docker.alloy             hosts with a Docker socket
  syslog.alloy             this host only: the listener morpheus sends to
snmp-exporter/
  generator.yaml           source of truth — edit this
  snmp.yaml                generated, 14k lines, ${PLACEHOLDER} communities
grafana/
  provisioning/            datasources + dashboard provider
  dashboards/*.json        7 dashboards, 140 panels
  dashboards/README.md     conventions that hold across all of them
```

## Things worth knowing before editing

- **`snmp-exporter/snmp.yaml` is generated.** Edit `generator.yaml` and run
  `make snmp-generate`. Its community strings are `${PLACEHOLDERS}`;
  `scripts/render-config.sh` renders the real file into a gitignored
  `.rendered/` directory at deploy time.
- **Grafana UI edits are discarded on restart** (`allowUiUpdates: false`). Export
  the JSON model and commit it — see
  [`docs/observability.md`](../../docs/observability.md#dashboards) and
  [`grafana/dashboards/README.md`](grafana/dashboards/README.md), which is where
  the constraints CI imposes on panel queries are written down.
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
`promtool test rules`, `amtool check-config`, `alloy fmt --test`, the dashboard
and documentation checks, every linter in `scripts/lint.sh`, and gitleaks. Same
set CI runs — both call the same scripts, so the two cannot drift (#68).
