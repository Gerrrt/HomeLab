# Lab observability stack

Runs on `alexander` (10.0.30.40), VLAN 30 — a **guest on `Saruman`**, not the
hypervisor. A compose stack is Docker, and Docker rewrites the iptables of a
box whose own firewall ADR-0014 relies on, which is why `Saruman` carries the
native `.deb` agent instead ([#88]) and why this runs one level down.
[ADR-0020](../../docs/adr/0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md).

```bash
make up STACK=lab        # from the repository root
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `prometheus` | `prom/prometheus` | *internal* | Metrics store, remote-write receiver, rule evaluation |
| `loki` | `grafana/loki` | *internal* | Log store |
| `grafana` | `grafana/grafana-oss` | 3000 (https) | Dashboards — the only published port, and the only service that terminates TLS or authenticates |
| `alloy` | `grafana/alloy` | 12345 (localhost) | Metric and log collection |

Four services, where the estate has seven. What is absent is as deliberate as
what is here:

- **No Alertmanager.** Nothing in the lab pages. ADR-0020 decided it, and it is
  explicitly not an answer to [#257] — that asks whether the lab's *liveness*
  may cross to the estate even though its telemetry may not.
- **No snmp-exporter.** `shiva`, the only SNMP device on this segment, is
  polled by the estate over the exception ADR-0013 records. Two stacks polling
  one device is two answers to "when did it last respond".
- **No blackbox-exporter, no renderer.** Nothing to probe from here yet, and no
  dashboards to screenshot.

## Why this exists at all

ADR-0007: **lab telemetry stays in the lab.** Nothing in this stack
remote-writes to `10.0.99.20`; both of Alloy's sinks are services in this
compose file. The one exception on this segment predates it and belongs to the
hypervisor, not to any guest — `Saruman`'s own agent, over a single unlogged
pass ([#88]).

## Layout

```text
compose.yaml               four services, one network, health-gated ordering
.env.example               non-sensitive tunables — edit this, not .env
prometheus/
  prometheus.yaml          four scrape jobs; no alerting block, no file_sd
  rules/lab.rules.yaml     4 rules — this stack watching itself, nothing else
  tests/lab.test.yaml      promtool unit tests; all four rules, firing + quiet
loki/loki-config.yaml      single-binary, filesystem, 15-day retention, no ruler
grafana/
  provisioning/            two datasources + dashboard provider
  dashboards/README.md     why there are no dashboards yet
```

No `alloy/` directory, deliberately. `compose.yaml` mounts `config.alloy` and
`docker.alloy` out of `../observability/alloy/` — ADR-0007 asks for the agent
config "reused unchanged", and a copy is reused-until-someone-edits-one.
`scripts/deploy-agent.sh` exists because `oracle` drifted four separate ways
from a hand-copied agent setup; its header states the rule as *"the fix is to
not copy."* `syslog.alloy` is not mounted: it opens a UDP listener for the
firewall's logs, which is the monitoring host's job and would be the wrong
thing entirely on this segment.

## Things worth knowing before editing

- **Nothing here is validated by CI yet.** Every checker in this repository is
  pinned to `stacks/observability` — `validate.sh`, the four Python checkers,
  `check_loki_rules.sh`, `seed-validation-env.sh` and `ci.yml`. Making them
  multi-stack is [#263]. Until it lands, run the checks against this stack by
  hand; the commands are at the bottom of this file.
- **Nothing converges this stack, either.** [#99] replaced deploying over SSH
  with `scripts/converge.sh` on an hourly timer, and that script runs a bare
  `make up` — which is `STACK=observability`, on the monitoring host. This
  stack is deployed by hand, on this guest, and a commit that changes it
  reaches the lab when someone goes and applies it. Worth knowing before
  assuming a merged change is running.
- **The retention figures are a bound, not a measurement.** 15 days and 4 GiB,
  against ADR-0007's "sized against spindles, not RAM". `compose.yaml` carries
  the queries to re-derive them once this has run for a fortnight, and
  `PrometheusSizeRetentionActive` is what says the ceiling started binding.
- **Grafana needs its own leaf, from the same CA as the estate's.** The
  `grafana` DNS SAN is load-bearing: the `grafana` scrape job connects to the
  compose service name and verifies against it.

  ```bash
  make certs ARGS="--host grafana-lab.matrix.elysium --ip 10.0.30.40 --dns grafana"
  ```

- **Secrets are one key, and it is created on this guest.** See
  [`secrets/lab.example.yaml`](../../secrets/lab.example.yaml) — running
  `make secrets-init STACK=lab` on the monitoring host would give one age key
  both stacks, and `bootstrap.sh` now refuses rather than doing it quietly.
- **Prometheus and Loki are not published.** ADR-0012 publishes a port only
  when something off-host uses it, and today only Alloy talks to them, over the
  compose network. `compose.yaml` marks the exact lines to uncomment when [#265]
  gives them their first real clients.
- **Image tags are pinned here but bumped separately.** `.github/dependabot.yml`
  now watches this directory as well as the estate's, so the two do not drift.
  Versions are deliberately absent from the table above — Dependabot only edits
  `compose.yaml`, so a version written anywhere else goes stale the moment it
  lands (#73).

## Validate before deploying

`make validate` does **not** cover this stack ([#263]). Until it does:

```bash
make check-rules STACK=lab
```

That target already follows `STACK`, because it uses `$(STACK_DIR)`. The rest
needs the image directly:

```bash
docker compose -f stacks/lab/compose.yaml config -q
```

[#99]: https://github.com/Gerrrt/HomeLab/issues/99
[#88]: https://github.com/Gerrrt/HomeLab/issues/88
[#257]: https://github.com/Gerrrt/HomeLab/issues/257
[#263]: https://github.com/Gerrrt/HomeLab/issues/263
[#265]: https://github.com/Gerrrt/HomeLab/issues/265
