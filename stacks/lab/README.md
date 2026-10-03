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
| `prometheus` | `prom/prometheus` | 9090 (localhost) | Metrics store, remote-write receiver, rule evaluation |
| `loki` | `grafana/loki` | 3100 (localhost) | Log store |
| `caddy` | `caddy` | 9090, 3100 on 10.0.30.40 | The ingest proxy: odin, phoenix and fenrir push through it with a token each, and everything else on the segment gets a 401 ([#834]) |
| `grafana` | `grafana/grafana-oss` | 3000 (https) | Dashboards, the one service a human opens |
| `alloy` | `grafana/alloy` | 12345 (localhost) | Metric and log collection |

Five services, where the estate has seven. What is absent is as deliberate as
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
compose.yaml               five services, one network, health-gated ordering
Caddyfile                  the ingest proxy's token table and path allowlist
.env.example               non-sensitive tunables — edit this, not .env
prometheus/
  prometheus.yaml          four scrape jobs; no alerting block, no file_sd;
                           the domain's and odin's jobs land commented
  rules/lab.rules.yaml     9 rules — four for this stack watching itself,
                           two for the guests' disks, three for the domain
                           ADR-0029 sized
  rules/soc.rules.yaml     6 rules — the SOC's indexer on odin, whose health is
                           pushed here by stacks/soc's Alloy (ADR-0030)
  tests/lab.test.yaml      promtool unit tests; all nine rules, firing + quiet
  tests/soc.test.yaml      the same for the six
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

## The ingest proxy, and the order it goes in

Since [#834], `caddy` holds `10.0.30.40:9090` and `:3100`, and Prometheus and
Loki are on loopback. odin, phoenix and fenrir push with a token each, and
everything else on the segment gets a 401. That includes `/-/quit`, Loki's
delete API, and any query without the reader token.

**Clients first, then the proxy.** Prometheus and Loki ignore an
`Authorization` header they do not need, so a client that starts sending its
token early loses nothing. A proxy that goes up before its clients refuses
their pushes until each one catches up.

1. **On `alexander`**, generate four tokens with `openssl rand -hex 32` and add
   them with `make secrets-edit STACK=lab`. The keys are `INGEST_TOKEN_ODIN`,
   `_PHOENIX`, `_FENRIR` and `_READER`, and
   [`secrets/lab.example.yaml`](../../secrets/lab.example.yaml) says where each
   one goes. Do not `make up` yet.
2. **On `odin`**, set `INGEST_TOKEN` to `INGEST_TOKEN_ODIN` with `make
   secrets-edit STACK=soc`, then `make up STACK=soc`.
3. **On `fenrir`**, which has no secrets file yet, follow
   [`build-the-sensor-guest.md`](../../docs/runbooks/build-the-sensor-guest.md)
   §4: install `sops` and `age`, then run `make secrets-init STACK=sensor` and
   `make secrets-edit STACK=sensor`, then `make up STACK=sensor`. Commit
   `.sops.yaml` and the new file through a pull request.
4. **From the Mac**, export `INGEST_TOKEN` (phoenix's) and
   `INGEST_TOKEN_READER`, then re-run `deploy-agent.sh` for phoenix
   ([`build-the-jumpbox.md`](../../docs/runbooks/build-the-jumpbox.md) §6).
5. **On `alexander`**, `make up STACK=lab`. The proxy is now in front.

**Then prove it.** From any VLAN 30 address, or on `alexander` against its own
address, each of these must print `401`:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://10.0.30.40:9090/-/quit
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://10.0.30.40:3100/loki/api/v1/delete
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://10.0.30.40:9090/api/v1/write
```

The three clients must still deliver. In the lab's Grafana, `up` and the
newest log line for `odin`, `phoenix` and `fenrir` should be minutes old.
`docker logs lab-ingest-proxy` lists any refused request, with the client its
token mapped to. A client still on its old config shows there as `-`.

Nothing pages if this later stops being true. The lab has no blackbox exporter
and no Alertmanager (ADR-0020), so the three `curl`s are the check, re-run after
any change to the Caddyfile. A lab failure that reaches the estate is
[#858]'s question.

## Things worth knowing before editing

- **CI validates this stack.** It did not when the directory first landed —
  every checker was pinned to `stacks/observability` — and [#263] fixed that:
  `scripts/stacks.sh` is now the one definition of what a stack is, and
  `validate.sh`, `ci.yml`, `pin-digests.sh` and the Python checkers all read it.
  What that does *not* cover is stated below.
- **Nothing converges this stack, either.** [#99] replaced deploying over SSH
  with `scripts/converge.sh` on an hourly timer, and that script runs a bare
  `make up` — which is `STACK=observability`, on the monitoring host. This
  stack is deployed by hand, on this guest, and a commit that changes it
  reaches the lab when someone goes and applies it. Worth knowing before
  assuming a merged change is running.
- **`prometheus.yaml` is a single-file bind mount, so an editor that writes a
  new inode is a silent no-op.** `compose.yaml` mounts
  `./prometheus/prometheus.yaml` as a file, not a directory, so the container
  pins the inode it started with. Editing with `sed -i`, or any editor that
  replaces the file, leaves the container reading the *old* inode — and a
  `make reload` (SIGHUP) re-reads that stale inode too, so the change looks
  applied on the host and never reaches Prometheus. Edit in place (preserving
  the inode) or, after any inode-replacing edit, `docker restart lab-prometheus`
  so it re-opens the path. This cost real confusion turning on the `windows`
  job (#414 §8).
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
  compose network. [#265] was expected to change that and did not:
  [ADR-0029](../../docs/adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
  has this Prometheus **scrape** the Windows domain instead, so the connection
  travels outward and nothing new listens on the segment that exists to hold
  attackers. That first client with no scrape alternative is now decided:
  `odin`, [`stacks/soc`](../soc)'s guest
  ([ADR-0030](../../docs/adr/0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)),
  whose Alloy pushes here — and `phoenix`, the deployment host
  ([ADR-0043](../../docs/adr/0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)),
  which was built first. The two `ports:` blocks in `compose.yaml` stayed
  commented until then;
  [`build-the-jumpbox.md`](../../docs/runbooks/build-the-jumpbox.md) §5
  published them in 2026-09
  ([#436](https://github.com/Gerrrt/HomeLab/issues/436)), and
  [`build-the-soc-guest.md`](../../docs/runbooks/build-the-soc-guest.md) §7 now
  only confirms they are open.
- **Image tags are pinned here but bumped separately.** `.github/dependabot.yml`
  now watches this directory as well as the estate's, so the two do not drift.
  Versions are deliberately absent from the table above — Dependabot only edits
  `compose.yaml`, so a version written anywhere else goes stale the moment it
  lands (#73).

## Validate before deploying

```bash
make validate
```

Covers this stack and the estate's together, and names which is which on every
line. `make check-rules STACK=lab` narrows it to this stack's Prometheus rules
and their unit tests.

What `make validate` still does **not** prove about this stack, in the order it
matters:

- **That it runs.** It has — `alexander` was built and this stack brought up
  on 2026-09-05 ([#262]) — but nothing in `make validate` knows that. Every
  check is static: configs parse, images resolve, healthcheck binaries exist
  inside their pinned images. None of it says the four services come up and
  talk to each other; that is
  [`build-the-lab-guest.md`](../../docs/runbooks/build-the-lab-guest.md) §7,
  by hand.
- **That its Grafana serves.** `check_dashboard_roundtrip.sh` boots the pinned
  Grafana against the estate's dashboards; this stack has none to round-trip,
  so that check has nothing to say here.
- **That the retention figures are right.** They are a bound, not a
  measurement — see above.

[#99]: https://github.com/Gerrrt/HomeLab/issues/99
[#88]: https://github.com/Gerrrt/HomeLab/issues/88
[#257]: https://github.com/Gerrrt/HomeLab/issues/257
[#263]: https://github.com/Gerrrt/HomeLab/issues/263
[#265]: https://github.com/Gerrrt/HomeLab/issues/265
[#834]: https://github.com/Gerrrt/HomeLab/issues/834
[#858]: https://github.com/Gerrrt/HomeLab/issues/858
