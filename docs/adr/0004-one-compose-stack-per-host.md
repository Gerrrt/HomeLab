# ADR-0004: One compose stack per host, not one directory per service

**Status:** Accepted · 2025-11

## Context

The repository previously used `<service>/<fqdn>/docker-compose.yaml` — five
directories, each with its own compose file, all for services running on the
same host:

```text
prometheus/prometheus.matrix.elysium/docker-compose.yaml
grafana/prometheus.matrix.elysium/docker-compose.yaml
loki/prometheus.matrix.elysium/docker-compose.yaml
alloy/prometheus.matrix.elysium/docker-compose.yaml
snmp-exporter/prometheus.matrix.elysium/docker-compose.yaml
```

This looked like it was designed for many hosts, but the hostname level had
exactly one value, and that value appeared nowhere in the documentation. Worse,
the split actively broke things:

- `grafana`'s compose declared `depends_on: [prometheus, loki]`, but those
  services were defined in *other* compose files. Compose rejects this outright —
  the file could not start.
- Services could not resolve each other by name, so every cross-reference was a
  hardcoded IP (`10.0.99.20` appeared five times across two files).
- Five separate `docker compose up` invocations, in an order nothing recorded.
- No shared network, no ordering, no health gating.

## Decision

One directory per **stack**, where a stack is the set of services deployed
together as a unit:

```text
stacks/observability/
├── compose.yaml          # all six services
├── prometheus/  loki/  grafana/  alertmanager/  alloy/  snmp-exporter/
```

Host-to-stack mapping lives in `docs/architecture.md`, not in the directory
tree. A second host means a second directory under `stacks/`.

## Consequences

- Services resolve each other by name on a shared compose network, so the
  hardcoded monitoring-host IP disappeared from both `prometheus.yaml` and
  `config.alloy`.
- `depends_on` with `condition: service_healthy` now works, so Grafana does not
  start before its datasources are ready.
- One `make up` instead of five ordered invocations.
- `docker compose config` validates the whole stack at once, which is what makes
  the CI job meaningful.
- The tradeoff: restarting one service means `docker compose up -d <service>`
  rather than acting on an isolated directory. In practice these six services are
  always deployed and upgraded together, which is the definition of a stack.
- Directory names no longer encode which host they run on. That information moved
  to documentation, where it can be kept accurate — the FQDN in the old paths had
  already drifted out of every other document.
