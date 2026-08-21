# Roadmap

Open work, extracted from the per-VLAN task lists that used to live inside the
inventory. Ordered roughly by how much it matters.

**The tracking lives in [Issues](https://github.com/Gerrrt/HomeLab/issues).**
This file is the shape of the work — what is outstanding, and why it is in this
order. Whether a thing is started, blocked or done is on its issue. Two places
holding the same checkbox is how a checkbox stops being true, and this file has
already been wrong about the switch answering SNMP and about the history purge.

Detail that used to live here — the trap in the MokerLink walk, the exact order
to bring the UPS back, the isolation question `ifrit` defers — moved to the
issues intact. Nothing was summarised away.

## Security

- **[#84](https://github.com/Gerrrt/HomeLab/issues/84) Retire the MokerLink
  switch's previous SNMP community.** `neo` still accepts its old one alongside
  the new; its firmware will not persist a deletion. Accepted residual, recorded
  in `SECURITY.md`. → [runbook](runbooks/rotate-snmp-community.md)
- **[#85](https://github.com/Gerrrt/HomeLab/issues/85) Move to SNMPv3 authPriv.**
  Three of four devices can. The MokerLink switch cannot, which is the blocker
  for doing it uniformly.
- **[#86](https://github.com/Gerrrt/HomeLab/issues/86) Decide whether the lab
  VLAN needs egress filtering** — before the playground exists, not after.

## Monitoring

- **[#87](https://github.com/Gerrrt/HomeLab/issues/87) Add `ifXTable` (64-bit
  counters) to the `mokerlink` module.** The current 32-bit counters wrap in ~34
  seconds at gigabit. Now actionable — the switch has been polling since the
  faults in [#22](https://github.com/Gerrrt/HomeLab/issues/22) cleared. The walk
  has a trap in it; the issue carries the detail.
- **[#88](https://github.com/Gerrrt/HomeLab/issues/88) Deploy Alloy to `Saruman`
  and `oracle`.** Only the monitoring host runs an agent; `morpheus` reaches Loki
  by network syslog and has no host metrics.
- **[#89](https://github.com/Gerrrt/HomeLab/issues/89) Extend Suricata to Degens
  (VLAN 10).** One interface at a time, once Skids has been quiet and understood
  for a few days. → [runbook](runbooks/enable-suricata.md)
- **[#90](https://github.com/Gerrrt/HomeLab/issues/90) Detect Suricata being
  dead.** A quiet IDS and a stopped one produce identical output, so no log rule
  can tell them apart. Needs a heartbeat the SNMP module does not expose.
- **[#91](https://github.com/Gerrrt/HomeLab/issues/91) Add blackbox-exporter**
  for uptime and TLS-expiry on internal services. Until it exists, expiry is
  something you find out about from a browser warning.
- **[#12](https://github.com/Gerrrt/HomeLab/issues/12) Capture dashboard
  screenshots.** `make screenshots` does four of the five; the Logs dashboard is
  deliberately excluded. → [`images/README.md`](images/README.md)

### The stack does not watch itself

Found while verifying [#12](https://github.com/Gerrrt/HomeLab/issues/12), and
new since this file was last honest:

- **[#81](https://github.com/Gerrrt/HomeLab/issues/81)** No dashboard for the
  observability stack itself, and **[#82](https://github.com/Gerrrt/HomeLab/issues/82)**
  none for the Suricata and firewall-log labels `config.alloy` goes to trouble
  to extract.
- **[#67](https://github.com/Gerrrt/HomeLab/issues/67)** No dead man's switch on
  the notification path — a 200 into a dead topic is a successful notification.
- **[#63](https://github.com/Gerrrt/HomeLab/issues/63)** `ContainerHighMemory`
  cannot fire, because nothing sets a memory limit.

Two collection faults of the same kind were fixed in
[#62](https://github.com/Gerrrt/HomeLab/pull/62): the agent was answering to the
name of the server, and cAdvisor could only see its own cgroup. Both ran healthy
and produced nothing.

## Infrastructure

- **[#92](https://github.com/Gerrrt/HomeLab/issues/92) Get the firewall backup
  off `prometheus`, and buy a spare ProDesk.** A backup on the same shelf as the
  thing it protects is not a backup, and
  [`restore-the-firewall.md`](runbooks/restore-the-firewall.md) stays a
  hypothesis until it has been restored onto a spare once.
- **[#93](https://github.com/Gerrrt/HomeLab/issues/93) Replace the UPS battery.**
  `mjolnir` has none, so a mains loss is an immediate hard shutdown of the rack.
  The management card fabricates a healthy pack. **The `UpsSelfTestFailed`
  silence must be deleted the moment the pack is fitted, not left to expire** —
  the issue carries the command and the reasoning.
- [ ] **Rack the shelf switch.** A 1U vented shelf (~$25–45) in **U4**, the one
      free slot, carrying the unmanaged TP-Link that `prometheus` and `oracle`
      hang off. **Buy it with the UPS pack above, not after** — the pack alone
      leaves the monitoring path half-protected. Both shelf machines are laptops
      with their own batteries, so on a mains cut they stay *running* and go
      *deaf*: the switch between them and the network has no battery at all, and
      a monitoring host that survives the event it exists to observe but cannot
      report it is a strange way to lose an evidence trail. The shelf has room
      beside the switch for the ProDesk in the item above — rack its cold-spare
      role but leave it **powered off**, since a spare that is plugged in and on
      the network is exposed to whatever took the primary.

      Measured at the rack 2026-08-21, so the spec is settled: **4-post frame,
      square mounting holes, depth is not a constraint.** That means a full 1U
      shelf with rear support — not a cantilever — and **cage nuts plus screws**,
      which most shelves include but not all; check the listing rather than
      discovering it on the day. U4 is empty only because nothing had been chosen
      for it, so there is no service clearance to preserve.

      The one thing that could have removed the purchase has been checked and
      does not: `morpheus` sits at U5 in a **purpose-built mount that holds one
      ProDesk Mini** — a single-device bracket, not a shelf with spare room. So
      the switch needs its own U, and the shelf is the way to give it one. The
      1U shelf also has room beside the switch for a second small box later,
      which the U5 bracket by design does not.

      This one has no issue yet — everything else in this file does.
- **[#94](https://github.com/Gerrrt/HomeLab/issues/94) Decide what `oracle` is
  for.** A dual-core A6-9200 with 4 GB and a 5400 rpm disk — too little for
  anything demanding, and a candidate for the jobs that need a machine that is
  *not* the monitoring host.
- **[#95](https://github.com/Gerrrt/HomeLab/issues/95) Plan and build the NAS on
  VLAN 40.** Adds an inter-VLAN rule and changes what "terminal" means for that
  segment. ADR-0008.
- **[#96](https://github.com/Gerrrt/HomeLab/issues/96) Procure `ifrit` and build
  the playground** — only after the main network is finished. ADR-0007 defers the
  isolation mechanism, and that deferral is the real work.
- **[#97](https://github.com/Gerrrt/HomeLab/issues/97) Work out DNS for the
  MokerLink management UI** so it is not reached by IP, and can hold a
  certificate that verifies.

## Automation

- **[#98](https://github.com/Gerrrt/HomeLab/issues/98) Home Assistant ↔ the eero
  API**, so device joins and leaves are events rather than accidents. Blocked
  behind ADR-0008's sensitive tier.
- **[#99](https://github.com/Gerrrt/HomeLab/issues/99) Move deployment from
  `make up` over SSH to something pull-based**, so the host converges on the repo
  rather than being pushed to.
- **[#100](https://github.com/Gerrrt/HomeLab/issues/100) Automate the Grafana
  dashboard export step** — the current loop is manual and therefore skipped
  under pressure.
- **[#77](https://github.com/Gerrrt/HomeLab/issues/77) Schedule something.**
  Nothing runs `make backup`, `make backup-firewall`, `make check-digests` or
  `make secrets-verify-backup` on a timer. The last of those is the only proof
  the secrets are recoverable.

## Decided but not built

Accepted ADRs with no work behind them. Recorded here because an accepted ADR
with nothing tracking it is indistinguishable from a rejected one after six
months.

- **[#101](https://github.com/Gerrrt/HomeLab/issues/101)** ADR-0007's
  `stacks/lab/` on `Saruman` — Wazuh, Velociraptor, PBS, a Windows domain, and a
  second observability stack.
- **[#102](https://github.com/Gerrrt/HomeLab/issues/102)** ADR-0008's sensitive
  tier and its two new firewall rules.
- **[#103](https://github.com/Gerrrt/HomeLab/issues/103)** The SSO deferral
  ADR-0008 takes knowingly — give it an expiry.
- **[#104](https://github.com/Gerrrt/HomeLab/issues/104)** A superseding ADR:
  0002 says two inter-VLAN rules exist and there are three.
- **[#105](https://github.com/Gerrrt/HomeLab/issues/105)** Confirm the
  unconfigured Snort package actually went.

## Done

- [x] **Enable Suricata on `morpheus`.** Running on Skids (VLAN 20) alert-only
      since 2026-08-21; alerts reach Loki with classification and priority parsed
      into labels, verified against real traffic. First tuning decision made from
      measurement rather than prediction: sid 2200121 "Ethertype unknown" was
      100% of alerts and turned out to be LLDP from `neo`, suppressed by
      signature rather than by disabling the whole `decoder-events` category.
      → [runbook](runbooks/enable-suricata.md) · ADR-0006
- [x] **Turn on remote logging on `morpheus`.** The firewall now ships filterlog
      to Loki, so `TerminalSegmentReachedInternalNetwork` and
      `IoTAttemptedLateralMovement` have input for the first time. pfSense saved
      the settings without restarting `syslogd` and sent nothing until the page
      was saved a second time — the runbook now says so, and says to confirm on
      the wire with tcpdump before believing an empty query.
      → [runbook](runbooks/ship-firewall-logs.md)
- [x] Settle the `10.0.30.10` question. It is the iLO BMC on its dedicated port;
      the Proxmox host is `Saruman` at `10.0.30.110`. The SNMP target's
      `hypervisor-bmc` role label was correct all along — the inventory was not
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
- [x] Serve Grafana over TLS with that CA, verified end to end — Prometheus
      scrapes it with `ca_file` and `server_name` rather than
      `insecure_skip_verify`
- [x] Point Alertmanager at a real receiver. The webhook was the
      `ntfy.example.invalid` placeholder for the entire life of the stack, so
      no alert had ever been delivered
- [x] Surface firing alerts on the dashboards. Forty rules and one routing tree
      existed with nothing showing them; four dashboards now carry a table of
      their own component's alerts
- [x] Stop the UPS dashboard reporting a battery that is not there — the
      management card fabricates charge, runtime and status
- [x] Purge the shared SNMP community, the inline Grafana password and the
      TLS private keys under `certificates/` from git history, and delete the
      `.gitleaksignore` that acknowledged them
- [x] Give every SNMP device its own community and rotate all four on the
      hardware, confirming pfSense, the APC NMC and iLO each refuse the old
      shared string. The switch accepts its new one but also still holds its
      previous community — an accepted residual, recorded in `SECURITY.md`
