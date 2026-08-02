# ADR-0003: Prometheus, Loki and Alloy over the alternatives

**Status:** Accepted · 2025-11

## Context

The lab needs metrics, logs and alerting on a monitoring host with modest
resources (a 2012 MacBook Pro), covering both Linux hosts and network appliances
that can only speak SNMP.

Options considered:

**Metrics.** Prometheus, InfluxDB, or Zabbix. Zabbix handles SNMP natively and
would have been fewer moving parts, but its data model and alerting are far less
expressive than PromQL, and its config lives in a database rather than in files —
which rules out managing it in git. InfluxDB's push model suits IoT telemetry
better than infrastructure monitoring, and Flux is a smaller ecosystem.

**Logs.** Loki or an ELK/OpenSearch stack. Elasticsearch full-text indexes
everything, which is powerful and expensive; its baseline JVM heap alone exceeds
what this host can spare. Loki indexes only labels and leaves log bodies
compressed, so its footprint is roughly proportional to what you actually query.

**Collection.** Promtail + node_exporter + cAdvisor as three separate agents, or
Grafana Alloy as one. Three agents means three configs, three deployment units
and three sets of version skew per host.

**Deployment mode.** Loki microservices or single binary. Microservices scale
horizontally; nothing here needs that.

## Decision

- **Prometheus** for metrics, with `--web.enable-remote-write-receiver` so agents
  push rather than being scraped.
- **Loki** in single-binary mode with filesystem storage.
- **Grafana Alloy** as the single collection agent, replacing Promtail,
  node_exporter and cAdvisor.
- **snmp_exporter** as a polling proxy for devices that cannot run an agent.
- **Grafana** for visualisation, provisioned entirely from files.

Remote-write rather than scrape is the load-bearing choice: a new host appears in
Prometheus the moment its agent starts, with no target list to maintain and no
firewall rule allowing the monitoring VLAN to reach into the monitored one.

## Consequences

- One agent binary and one config file per host. `config.alloy` is identical
  everywhere; only two environment variables differ.
- PromQL and LogQL are close enough that a metric query translates to a log query
  with little friction, and Grafana correlates the two on one dashboard.
- Loki's label-only indexing means a badly chosen label (a request ID, an IP)
  explodes cardinality in a way Elasticsearch would have absorbed. This is
  documented in `observability.md` and is a real ongoing constraint.
- Single-binary Loki cannot scale out. At this volume — well under 1 GB/day —
  that is not a limitation, and converting later is a config change, not a
  rewrite.
- SNMP devices are polled at 60s rather than pushed, so their resolution is
  coarser than host metrics. Acceptable for interface counters and UPS state.
- Prometheus retention is bounded by local disk. 30 days fits; anything longer
  needs remote storage (Thanos, Mimir), which would be a new ADR.
