# ADR-0012: Publish only the ports something off-host uses

**Status:** Accepted · 2026-08

## Context

The observability stack published five ports on `${BIND_ADDR:-0.0.0.0}` because
one variable governed all of them. Only Grafana authenticates. The others each
carry a write surface: Prometheus runs with `--web.enable-remote-write-receiver`
and `--web.enable-lifecycle`, Loki runs `auth_enabled: false` with a delete API,
and Alertmanager lets any caller create a silence.

The last of those is the one that prompted this. Silencing an alert switches off
monitoring, and the record of the act lives in the system being switched off. It
is the only one of the three whose abuse is designed to leave no trace.

[ADR-0002](0002-vlan-segmentation-strategy.md)'s default-deny means only Hicks
(50) can reach Winterfell (99), so none of this was ever exposed to an untrusted
segment. But it made one firewall rule the entire control, and ADR-0002 already
records the gap that leaves: *"A compromised workstation reaches Winterfell."*

The question was whether the wide default was earning anything. Checking rather
than assuming turned out to matter, and in both directions:

- `docs/roadmap.md` said only the monitoring host ran an agent. It was a day out
  of date. `oracle` had been remote-writing to `10.0.99.20:9090` and pushing to
  `:3100` for about eighteen hours — 378 distinct metric names, and it is not a
  scrape target, so those published ports are its only path. Prometheus and Loki
  are load-bearing.
- Alertmanager had no off-host client at all, and still does not. Grafana
  proxies it over the compose network through an authenticated datasource, so
  every operator path to a silence already avoided port 9093.

A second assumption did not survive either: the monitoring host is a 2012
MacBook Pro, so narrowing `BIND_ADDR` from `0.0.0.0` to the management IP looked
like cheap defence in depth. It is not — the machine has one interface, a USB
ethernet adapter already on VLAN 99. `0.0.0.0` and `10.0.99.20` are the same
thing here, and pinning the literal address would only add a way for the stack
to fail if it ever moved.

## Decision

A port is published to a host interface when something off the host uses it, and
not otherwise. The test is a named client, not a plausible future one.

- **Grafana (3000)** — browsers on Hicks. Published, and the only published
  service that authenticates.
- **Prometheus (9090)** and **Loki (3100)** — `oracle`'s Alloy agent.
  Published.
- **Alloy syslog (1514/udp)** — `morpheus`. Published; pfSense cannot reach
  loopback.
- **Alertmanager (9093)** — nothing. Bound to `127.0.0.1`, hard-coded beside the
  Alloy debug UI (12345) that was already there.

Loopback is hard-coded rather than made a variable. `.env` is regenerated from
`.env.example` on every `make up`, so a variable would advertise a runtime knob
the deploy path does not provide; and publishing one of these hands a VLAN write
access to a store, which should arrive as a reviewed diff against the pull
request template's *"No new port published to a VLAN that could not already
reach the service"* checkbox.

No service flags change. `--web.enable-remote-write-receiver` is what `oracle`
uses, `--web.enable-lifecycle` is what `scripts/reload-config.sh` uses from
inside the container, and Loki's `auth_enabled: false` is correct for one
tenant. The flags were never the problem; reachability was.

## Consequences

- **The silence surface is closed.** The one write path whose abuse leaves no
  trace is no longer reachable from any VLAN.
- **Prometheus and Loki remain an accepted residual, not a fixed one.** They are
  published, unauthenticated, and writable by anything that can route to
  `10.0.99.20` — which today means Hicks and Winterfell. The firewall is still
  the only control there. Recorded in [`SECURITY.md`](../../SECURITY.md) rather
  than quietly carried; closing it needs authentication in front of the ingest
  ports, which is a separate piece of work and a new secret to rotate.
- Alertmanager's `--web.external-url` still points at `10.0.99.20:9093`, so the
  `externalURL` field in webhook payloads now only opens on the monitoring host
  or through an SSH tunnel. No receiver renders it, so no notification text
  changes. Off-host, silences are in Grafana under Alerting; on-host,
  `docker exec alertmanager amtool` still works.
- `127.0.0.1` is a host boundary, not a user one. Any local account on the
  monitoring host, and any container on the host network, still reaches
  Alertmanager unauthenticated.
- **The rule generalises to the next agent.** Deploying Alloy to `Saruman`
  ([#88](https://github.com/Gerrrt/HomeLab/issues/88)) needs no bind change,
  because `oracle` already made Prometheus and Loki published services. Adding a
  service with no off-host client should default to loopback.
- Supersedes nothing. It fills in a layer ADR-0002's consequences section
  admitted was missing, at a scale where a bastion is still not worth building.
