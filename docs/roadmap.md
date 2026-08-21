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
- [ ] Decide whether the lab VLAN needs egress filtering before the
      deliberately-vulnerable playground exists.

## Monitoring

- [ ] **Add `ifXTable` (64-bit counters) to the `mokerlink` SNMP module.** The
      current `ifTable` counters are 32-bit and wrap in roughly 34 seconds at
      gigabit line rate, so sustained high-throughput ports under-report. The
      `SwitchCounterWrapSuspected` alert detects this but does not fix it.
      Now actionable — the switch has only been polling since the three faults
      in [#22](https://github.com/Gerrrt/HomeLab/issues/22) were cleared. Mind
      the trap documented in `generator.yaml`: this switch returns `ifSpecific`
      with a zero-length value that makes snmp-exporter discard the whole
      response, so the walk lists individual columns and must stay clear of
      column 22.
- [ ] Deploy Alloy to the remaining hosts — currently only the monitoring host
      and one other report in. `Saruman` and `oracle` are next.
- [ ] **Extend Suricata to Degens (VLAN 10).** Running on Skids since
      2026-08-21, alert-only. Add the guest segment once Skids has been quiet and
      understood for a few days — one interface at a time, or you cannot tell
      which is producing the noise. → [runbook](runbooks/enable-suricata.md)
- [ ] **Detect Suricata being dead.** A quiet IDS and a stopped IDS produce
      identical log output, so no log rule can tell them apart — unlike
      `FirewallLogsStopped`, which works because a firewall is never silent.
      This needs a process or heartbeat metric from `morpheus`, which the SNMP
      module does not currently expose.
- [ ] Add blackbox-exporter for uptime and TLS-expiry checks on internal
      services.
- [ ] Capture dashboard screenshots for the README once the stack has a few days
      of real data. → [`images/README.md`](images/README.md)

## Infrastructure

- [ ] **Copy the firewall backup off `prometheus`, and buy a spare.**
      `make backup-firewall` now exports and encrypts morpheus's config, and
      [`restore-the-firewall.md`](runbooks/restore-the-firewall.md) documents the
      restore — but a backup on the same shelf as the thing it protects is not a
      backup, and the runbook is a hypothesis until it has been restored onto a
      spare once. The spare should be the same ProDesk model: pfSense stores
      interface assignments by device name, so identical hardware restores
      straight through and anything else drops you into the console dialogue.
- [ ] **Replace the UPS battery.** `mjolnir` currently has none, so a mains loss
      is an immediate hard shutdown of the rack. A replacement APCRBC115
      cartridge is on order. Most rules in `ups.rules.yaml` still report on a UPS
      that cannot hold the load — but `UpsSelfTestFailed` now detects it, keyed
      on the one metric the management card does not fabricate. Once the pack is
      fitted, enable **scheduled self-tests** on the NMC so that rule stays live
      evidence rather than a stale last-known result.

      `UpsSelfTestFailed` is **silenced in Alertmanager until 2026-09-20**
      (`54f1715c-e57b-4322-8a6d-5435bc8e1bd8`), not dismissed. It routes on
      `category=power` to the `urgent` receiver with `group_wait: 0s` and
      `repeat_interval: 30m`, so leaving it firing meant paging every half hour
      about a condition already known and tracked here — which is how an urgent
      receiver stops being read. The silence carries an expiry on purpose: if the
      pack still is not fitted when it lapses, the alert comes back and asks
      again. **Do not extend it without checking whether the battery arrived** —
      an indefinitely silenced critical is indistinguishable from one nobody
      noticed.

      **Delete that silence the moment the pack is fitted. Do not wait for it to
      expire.** Between fitting and 20 September the silence would suppress
      `UpsSelfTestFailed` on a UPS that can now genuinely report — including a
      new pack that is itself faulty or badly seated, which is exactly when you
      want to hear about it. The window is the whole point of a silence and also
      its whole risk.

      ```bash
      curl -sS -X DELETE \
        http://localhost:9093/api/v2/silence/54f1715c-e57b-4322-8a6d-5435bc8e1bd8
      ```

      Then, in order: run **one** self-test from the management card and confirm
      `upsTestResultsSummary` reads `1` (donePass) rather than `4` (aborted);
      enable **scheduled** self-tests so the metric stays live evidence instead
      of a stale last-known result; and expect the previously-fabricated metrics
      — charge, runtime, voltage — to start reporting real values for the first
      time, which makes `UpsBatteryLow`, `UpsChargeLow` and `UpsRuntimeCritical`
      meaningful rules rather than decorative ones.
- [ ] Decide what `oracle` (10.0.99.30) is for. It is a dual-core AMD A6-9200
      with 4 GB and a 5400 rpm disk — considerably less machine than this list
      previously claimed, and too little for anything demanding.
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
