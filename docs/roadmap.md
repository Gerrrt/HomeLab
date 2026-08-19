# Roadmap

Open work, extracted from the per-VLAN task lists that used to live inside the
inventory. Ordered roughly by how much it matters.

## Security

- [ ] **Retire the MokerLink switch's previous SNMP community.** All four
      devices are rotated, but `neo` still accepts its old community alongside
      the new one: its firmware does not persist a deletion from the community
      table, and each attempt drops the SNMP agent until the switch is
      rebooted. Low priority and accepted for now — the community is read-only
      and reachable only from the management VLAN. Overwrite the row with a
      fresh value rather than deleting it, next time the switch is down anyway.
      → [runbook](runbooks/rotate-snmp-community.md)
- [ ] Move to SNMPv3 authPriv where the hardware supports it. pfSense, the APC
      and iLO all do; the MokerLink switch does not, which is the blocker for
      doing it uniformly.
- [ ] Put Grafana behind TLS rather than plain HTTP on the management VLAN.
      The CA and a `grafana.matrix.elysium` leaf already exist — see
      [runbook](runbooks/generate-certificates.md) — so this is wiring, not PKI.
- [ ] Decide whether the lab VLAN needs egress filtering before the
      deliberately-vulnerable playground exists.

## Monitoring

- [ ] **Add `ifXTable` (64-bit counters) to the `mokerlink` SNMP module.** The
      current `ifTable` counters are 32-bit and wrap in roughly 34 seconds at
      gigabit line rate, so sustained high-throughput ports under-report. The
      `SwitchCounterWrapSuspected` alert detects this but does not fix it.
- [ ] Deploy Alloy to the remaining hosts — currently only the monitoring host
      and one other report in. `shiva` and `oracle` are next.
- [ ] Add blackbox-exporter for uptime and TLS-expiry checks on internal
      services.
- [ ] Confirm whether `10.0.30.10` is genuinely both the Proxmox host and its
      iLO, or whether one of the two records is stale. The SNMP target and the
      inventory currently agree on the address but describe different things.
- [ ] Capture dashboard screenshots for the README once the stack has a few days
      of real data. → [`images/README.md`](images/README.md)

## Infrastructure

- [ ] **Replace the UPS battery.** `mjolnir` currently has none, so a mains loss
      is an immediate hard shutdown of the rack. Every rule in
      `ups.rules.yaml` is currently reporting on a UPS that cannot actually hold
      the load.
- [ ] Decide what `oracle` (10.0.99.30) is for. It is a 32 GB / 2 TB machine
      sitting idle on the management VLAN.
- [ ] Plan and build the NAS on VLAN 40.
- [ ] Procure a second server ("ifrit") for the isolated playground network.
- [ ] Build the playground — **only** after the main network is finished.
- [ ] Work out DNS for the MokerLink management UI so it is not reached by IP.

## Automation

- [ ] Home Assistant integration with the eero API, so device joins and leaves
      show up as events rather than being discovered by accident.
- [ ] Move stack deployment from `make up` over SSH to something pull-based, so
      the monitoring host converges on the repo rather than being pushed to.
- [ ] Automate the Grafana dashboard export step — the current loop (edit in UI,
      copy JSON, commit) is manual and therefore skipped under pressure.

## Done

- [x] Bridge mode on the ISP gateway
- [x] Lock down guest VLAN firewall rules
- [x] Move IoT devices onto their own SSID and VLAN
- [x] Stand up Prometheus, Grafana, Loki, snmp-exporter and Alloy
- [x] Consolidate five broken compose files into one working stack
- [x] Provision Grafana datasources and dashboards from files
- [x] Add alerting (32 rules) and Alertmanager routing
- [x] Move secrets to SOPS + age
- [x] Add CI: lint, config validation, secret scanning
- [x] Pin every image by digest, not just tag, with drift detection in CI
- [x] Add SECURITY.md with a disclosure policy and known-exposure summary
- [x] Loki alerting rules (8) for auth, SSH brute force and disk/OOM events,
      validated in CI by booting the pinned Loki image against them
- [x] Replace the CA and leaf certificates that leaked, and add tooling so
      issuing one is a command rather than a research project
- [x] Purge the shared SNMP community, the inline Grafana password and the
      TLS private keys under `certificates/` from git history, and delete the
      `.gitleaksignore` that acknowledged them
- [x] Give every SNMP device its own community, and rotate three of the four on
      the hardware (pfSense, the APC NMC, iLO), confirming each refuses the old
      shared string
