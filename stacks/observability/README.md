# Observability stack

[![host: prometheus](https://img.shields.io/badge/host-prometheus-30363d?style=plastic)](../../docs/network.md#winterfell--vlan-99--management)
[![VLAN 99: Winterfell](https://img.shields.io/badge/VLAN%2099-Winterfell-f85149?style=plastic)](../../docs/network.md#winterfell--vlan-99--management)
![status: live](https://img.shields.io/badge/status-live-2ea043?style=plastic)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=plastic&logo=prometheus&logoColor=white)](https://prometheus.io)
[![Alertmanager](https://img.shields.io/badge/Alertmanager-E6522C?style=plastic&logo=prometheus&logoColor=white)](https://prometheus.io/docs/alerting/latest/alertmanager/)
[![Loki](https://img.shields.io/badge/Loki-F5A800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/loki/)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/grafana/)
[![Alloy](https://img.shields.io/badge/Alloy-F46800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/alloy-opentelemetry-collector/)
[![snmp_exporter](https://img.shields.io/badge/snmp__exporter-E6522C?style=plastic&logo=prometheus&logoColor=white)](https://github.com/prometheus/snmp_exporter)
[![blackbox_exporter](https://img.shields.io/badge/blackbox__exporter-E6522C?style=plastic&logo=prometheus&logoColor=white)](https://github.com/prometheus/blackbox_exporter)
[![Caddy](https://img.shields.io/badge/Caddy-1F88C0?style=plastic&logo=caddy&logoColor=white)](https://caddyserver.com)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-2496ED?style=plastic&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

Runs on `prometheus` (10.0.99.20), VLAN 99.

```bash
make up        # from the repository root
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `prometheus` | `prom/prometheus` | 9090 (localhost) | Metrics store, remote-write receiver, rule evaluation |
| `alertmanager` | `prom/alertmanager` | 9093 (localhost) | Alert routing, grouping, inhibition |
| `loki` | `grafana/loki` | 3100 (localhost) | Log store |
| `caddy` | `caddy` | 9090, 3100 (`INGEST_BIND_ADDR`, https) | The ingest proxy: TLS on a lab-CA leaf (#764), a bearer token per agent to push, a reader token to query, the admin and delete APIs to nobody (#182) |
| `grafana` | `grafana/grafana-oss` | 3000 (https) | Dashboards — the main published UI |
| `snmp-exporter` | `prom/snmp-exporter` | *internal* | SNMP polling proxy |
| `blackbox-exporter` | `prom/blackbox-exporter` | *internal* | Probes from outside a service: is it reachable, and what did the resolver answer |
| `alloy` | `grafana/alloy` | 12345 (localhost) | Metric and log collection |
| `speedtest-tracker` | `lscr.io/linuxserver/speedtest-tracker` | 8443 (https) | Ookla speed test every 30 minutes, its history UI, and the latest result for Prometheus (#914) |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy` | *internal* | Holds the Docker socket so Alloy does not: GET-only, an allowlist of endpoints ([#836](https://github.com/Gerrrt/HomeLab/issues/836)) |

"(localhost)" means bound to `127.0.0.1`: reachable from the monitoring host
itself and over the compose network, and from no VLAN at all. A port is
published only when something off-host uses it, and nothing off-host uses
Alertmanager (#70). Prometheus and Loki are used off-host, but only through
`caddy`, which holds the host's address on the same two ports, serves them
over TLS (ADR-0086) and wants a token first (ADR-0067). Grafana binds to `BIND_ADDR`, and the Alloy syslog receiver,
TLS-only on 6514/tcp since #1049, to `INGEST_BIND_ADDR`. Reasoning in
[`docs/architecture.md`](../../docs/architecture.md#ports).

## Layout

```text
compose.yaml               all ten services, one network, health-gated ordering
Caddyfile                  the ingest proxy's policy: which token may reach which path
.env.example               non-sensitive tunables (ports, retention, bind address)
                           edit this, not .env — .env is regenerated on `make up`
prometheus/
  prometheus.yaml          scrape config; SNMP via file_sd
  targets/snmp.yaml        SNMP targets — hot-reloaded, no restart needed
  targets/node.yaml        node_exporter scrapes, for the host that runs no Alloy (smaug)
  targets/blackbox*.yaml   probe targets, http, dns and latency — hot-reloaded, no restart
  rules/*.rules.yaml       155 alert rules: host, network, ups, containers, blackbox,
                           dns, backup, ids, deploy, stack, internet and watchdog
  tests/*.test.yaml        promtool unit tests — assert the rules can fire
blackbox/blackbox.yaml     probe modules — reachability, and what a resolver said
alertmanager/
  alertmanager.yaml        severity + category routing, inhibition
loki/
  loki-config.yaml         single-binary, filesystem, 30-day retention
  rules/*.rules.yaml       20 LogQL rules, security and watchdog, evaluated by Loki's ruler
alloy/                     the agent config — Alloy loads the directory
  config.alloy             every monitored host
  docker.alloy             hosts with a Docker socket
  syslog.alloy             this host only: the listener morpheus sends to
snmp-exporter/
  generator.yaml           source of truth — edit this
  snmp.yaml                generated, never hand-edited; ${PLACEHOLDER} communities
grafana/
  provisioning/            datasources + dashboard provider
  dashboards/*.json        8 dashboards, 156 panels
  dashboards/README.md     conventions that hold across all of them
```

## Things worth knowing before editing

- **`snmp-exporter/snmp.yaml` is generated.** Edit `generator.yaml` and run
  `make snmp-generate`. Its community strings are `${PLACEHOLDERS}`;
  `scripts/render-config.sh` renders the real file into a gitignored
  `.rendered/` directory at deploy time.
- **Grafana UI edits are captured with `make dashboards-export`**, not by hand.
  The JSON in git stays the source of truth — a file change re-provisions over
  Grafana's copy — but `allowUiUpdates` is `true` so an edit survives long
  enough to be exported, and the daily `dashboards-drift` job is what notices
  one nobody exported. See
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
