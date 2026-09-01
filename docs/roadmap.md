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
- **[#182](https://github.com/Gerrrt/HomeLab/issues/182) Authenticate the
  Prometheus and Loki ingest ports.** Both are published and unauthenticated, so
  anything that can route to `10.0.99.20` can read every metric and log line,
  inject metrics and delete log ranges. They stay published because `oracle`'s
  agent pushes to them and has no other path, which is why #70 could close
  Alertmanager and not these. Firewall default-deny is the whole control.
  Accepted residual, recorded in `SECURITY.md`.
- **[#86](https://github.com/Gerrrt/HomeLab/issues/86) Decide whether the lab
  VLAN needs egress filtering** — before the playground exists, not after.

## Monitoring

- **[#87](https://github.com/Gerrrt/HomeLab/issues/87) Add `ifXTable` (64-bit
  counters) to the `mokerlink` module.** The current 32-bit counters wrap in ~34
  seconds at gigabit. Now actionable — the switch has been polling since the
  faults in [#22](https://github.com/Gerrrt/HomeLab/issues/22) cleared. The walk
  has a trap in it; the issue carries the detail.
- **[#88](https://github.com/Gerrrt/HomeLab/issues/88) Deploy Alloy to
  `Saruman`.** `oracle` has had an agent since 2026-08-30 and is remote-writing
  host metrics and pushing logs; `Saruman` is the one left. `morpheus` reaches
  Loki by network syslog and has no host metrics.
- **[#89](https://github.com/Gerrrt/HomeLab/issues/89) Extend Suricata to Degens
  (VLAN 10).** One interface at a time, once Skids has been quiet and understood
  for a few days. → [runbook](runbooks/enable-suricata.md)
- **[#90](https://github.com/Gerrrt/HomeLab/issues/90) Detect Suricata being
  dead.** A quiet IDS and a stopped one produce identical output, so no log rule
  can tell them apart. Needs a heartbeat the SNMP module does not expose.
- **[#91](https://github.com/Gerrrt/HomeLab/issues/91) Probe the services this
  was filed for, and probe TLS expiry.** blackbox-exporter is deployed and
  scraped, but it probes one thing the issue never named — the wiki, added after
  it went unreachable unnoticed — and none of the seven it did: Grafana,
  Prometheus, Alertmanager, Loki, the switch UI, the iLO, the pfSense UI. The
  expiry half has nothing behind it at all. Both targets are plain HTTP, the
  TLS-capable `http_2xx` module is defined and used by nothing, and no rule reads
  `probe_ssl_earliest_cert_expiry`. Grafana is the only service in the estate
  terminating TLS and it is not probed, so expiry is still something you find out
  about from a browser warning.
- **[#114](https://github.com/Gerrrt/HomeLab/issues/114) Set memory limits on
  the six services.** Nothing in `compose.yaml` bounds a leak, so one container
  can take the host down — and the host has 8 GB soldered. It was blocked on
  data: cAdvisor has only reported correctly since
  [#62](https://github.com/Gerrrt/HomeLab/pull/62), and `grafana` swung 3.7x
  inside the six hours available, so a limit picked from it would have been a
  guess at an OOM kill. Nine more days did not settle it — they widened it.
  `loki` now swings 8.6x (121 MiB median, 1039 MiB peak), and `loki`, `grafana`
  and `alloy` all peaked in the *same hour* on 2026-08-29, which is an episodic
  event rather than a distribution that converges with more sampling. The
  method the issue proposed no longer fits the machine either: 3x every peak is
  7536 MiB against 7816 MiB of RAM. So the gate has changed rather than moved —
  waiting for more history is not what unblocks this, explaining that one hour
  is. [#71](https://github.com/Gerrrt/HomeLab/issues/71) took the half that was
  sizeable: `pids_limit`, because tens of threads against a 10,000-thread abort
  is two orders of magnitude of daylight, and a byte ceiling on the TSDB, which
  is at a measurable steady state at day 28 of 30.
- **[#12](https://github.com/Gerrrt/HomeLab/issues/12) Capture dashboard
  screenshots.** `make screenshots` does five of the seven; the Logs and
  Security dashboards are deliberately excluded.
  → [`images/README.md`](images/README.md)

### The stack does not watch itself

Found while verifying [#12](https://github.com/Gerrrt/HomeLab/issues/12), and
new since this file was last honest:

- **[#67](https://github.com/Gerrrt/HomeLab/issues/67)** No dead man's switch on
  the notification path — a 200 into a dead topic is a successful notification.

Two collection faults of the same kind were fixed in
[#62](https://github.com/Gerrrt/HomeLab/pull/62): the agent was answering to the
name of the server, and cAdvisor could only see its own cgroup. Both ran healthy
and produced nothing.

[#63](https://github.com/Gerrrt/HomeLab/issues/63) was the same fault one layer
up. `ContainerHighMemory` divided by a memory limit no service sets and guarded
on it being non-zero, so it could not fire for any input while showing as loaded
and healthy. It now measures against the host total instead. `promtool check
rules` had passed it the entire time — it parses PromQL and never asks whether
an expression can be true — so the fix came with the first `promtool test rules`
unit tests in the repo, which fail if the rule stops being able to fire. They
cover that one rule. The other 33 are still syntax-checked only, so the same
class of fault could be sitting in any of them and would look just as healthy.
Setting the memory limits themselves is
[#114](https://github.com/Gerrrt/HomeLab/issues/114), deliberately separate: a
limit enforces, a rule detects, and making the second depend on the first is
what left this one unfireable for months.

## Infrastructure

- **[#92](https://github.com/Gerrrt/HomeLab/issues/92) Get the firewall backup
  off `prometheus`, and buy a spare ProDesk.** A backup on the same shelf as the
  thing it protects is not a backup, and
  [`restore-the-firewall.md`](runbooks/restore-the-firewall.md) stays a
  hypothesis until it has been restored onto a spare once. The volume sets
  `make backup` writes have exactly the same defect: they sit on the host they
  protect. Unlike the firewall, they have now been restored — the whole stack
  was brought up on a restored set on 2026-08-29 and verified. Getting a copy
  off this host is the part that is still missing.
- **[#93](https://github.com/Gerrrt/HomeLab/issues/93) Replace the UPS battery.**
  An APCRBC115 went into `mjolnir` on 2026-08-28 and passed its self-test the
  same day: `upsTestResultsSummary` `4` → `1`, `upsBatteryVoltage` off its
  fabricated `480`, runtime no longer pinned to exactly `63`. The
  `UpsSelfTestFailed` silence was deleted rather than left to expire in
  September, so the rule that would report a bad pack is live again. **What is
  left is the last step: scheduled self-tests on the card.** Until they are on,
  `1` is a last-known result with nothing refreshing it, and `UpsBatteryUnproven`
  cannot detect a card that has quietly stopped testing — it matches `6`
  (noTestsInitiated), and this one reads `1`.
  → [runbook](runbooks/fit-the-ups-battery.md)
- **[#76](https://github.com/Gerrrt/HomeLab/issues/76) Replace `shiva`'s Smart
  Storage Battery.** Chassis 0 battery 1 reads `cpqHeSysBatteryStatus` `13`
  (shutdownPermanentFailure) and `cpqHeSysBatteryCondition` `4` (failed), and has
  since at least 2026-08-18 — the whole of the retained window, unbroken. **HPE
  spare `815983-001`** (option 727258-B21, "HP Smart Storage Batt 96"). `13` is
  terminal: a reseat does not clear it, so there is nothing to try before
  ordering. The cost is already being paid — the Smart Array has permanently
  disabled its flash-backed write cache (`cpqDaAccelStatus` `5`, read and write
  cache percent both `0`) and the array runs write-through: slower, and *not*
  less durable. `cpqDaAccelBadData` reads `2` (none), so nothing dirty was lost
  when it dropped. **Accepted with an expiry, not a fix in progress:**
  `IloBatteryCondition` and `IloWriteCacheDisabled` are silenced for `shiva`
  until 2026-10-01 (`bfdfff66-d9c3-4df4-9495-f1f38ebf93c1`) so a known
  condition does not notify every 12 hours, and the silence is to be deleted
  when the pack goes in rather than left to run out. Both alerts were watched
  through pending into firing on 2026-08-31 and reached the `default` receiver
  with zero webhook failures before the silence was placed, so what is
  suppressed is known-working rather than assumed-working. The alert was wrong
  independently of the hardware: it read only the scalar
  `cpqHeSysBackupBatteryCondition` while claiming to cover the RAID cache, so it
  could not name the pack, the reason, or the consequence. That is fixed; the
  pack is not.
  → [runbook](runbooks/replace-the-smart-storage-battery.md)
- **[#110](https://github.com/Gerrrt/HomeLab/issues/110) Rack the shelf switch.**
  A 1U vented shelf in **U4**, carrying the unmanaged switch `prometheus` and
  `oracle` hang off. **Buy it with the UPS pack above, not after** — both shelf
  machines are laptops, so on a mains cut they stay running and go deaf while the
  switch between them and the network has no battery at all. Spec settled at the
  rack on 2026-08-21; the spare ProDesk from
  [#92](https://github.com/Gerrrt/HomeLab/issues/92) racks here too, powered off.
  → [runbook](runbooks/fit-the-ups-battery.md)
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
- **[#105](https://github.com/Gerrrt/HomeLab/issues/105)** Confirm the
  unconfigured Snort package actually went.

## Done

- [x] **[#104](https://github.com/Gerrrt/HomeLab/issues/104) A superseding ADR
      for 0002's rule count.** ADR-0013. The issue asked for the third rule and
      the current total; reading the enforced ruleset instead of recounting the
      prose showed the total was the wrong thing to ask for.

      Default deny holds for 99, 30, 40, 20 and 10. It does not hold for Hicks,
      which blocks 40/20/10 and then passes to `any` — so it reaches all of
      Winterfell and all of ImaginationLAN, wholesale, which no rule grants and
      no rule denies. Nor for the switch LAN, which still carries pfSense's stock
      *Default allow LAN to any* and reaches every segment while `network.md`
      said "Nothing". One explicit rule — *Allow Hicks access to ImaginationLAN*
      — sits on the ImaginationLAN interface, where Hicks traffic never arrives,
      and matches nothing.

      Four documents held four different counts. They now hold a list.
      `network.md` had Hicks right the whole time.

- [x] **[#223](https://github.com/Gerrrt/HomeLab/issues/223)
      `TerminalSegmentReachedInternalNetwork` could not fire.** The firewall
      logged blocks only, and the rule matches `action="pass"`, so the alert
      the segmentation design depends on could not fire for any input — the
      #63 shape, found while building #82's dashboard.

      Armed with three tripwire rules rather than by logging passes broadly.
      The obvious fix does not work: every inter-VLAN pass rule is sourced from
      an internal segment, so none can carry a terminal-VLAN packet. Logging
      the terminal `→ any` egress rules does work and costs ~12.6M lines a day,
      about 142× current volume. The tripwires — `pass` + `log` for
      `<terminal net> → Internal_Segments` on `igc0.10/20/40`, below the blocks
      and above `→ any` — cost nothing while segmentation holds and match only
      if the blocks are removed or reordered.

      The logging path was proven rather than assumed: 49 of 49 pass lines put
      the source where the alert's regex reads it, and the destination half
      already matched 2058 block lines.

- [x] **[#82](https://github.com/Gerrrt/HomeLab/issues/82) A dashboard for the
      Suricata and firewall-log labels.** `homelab-security`, 21 panels, all
      from labels `config.alloy` was already extracting and five Loki rules were
      already firing on. It charts blocks per second by `interface` and
      `direction`, top blocked sources — parsed out of the line at query time,
      because ADR-0003 keeps addresses out of the index — Suricata by
      `classification` and `priority`, and terminal-segment violations, which
      is the rule the segmentation design exists to enforce and which had no
      view but the alert.

      It also closed a gap it walked into: dashboard PromQL had been parsed by
      promtool since #78, and dashboard LogQL had been parsed by nothing, so a
      typo in a Loki panel rendered an empty panel and read as quiet traffic.
      `check_dashboards.py --emit-logql` now feeds every panel query to the
      Loki that `check_loki_rules.sh` already boots — 28 expressions, including
      the eleven in `homelab-logs` that had been unchecked since it landed.

      Not captured by `make screenshots`, and never will be, for the reason
      `homelab-logs` is not: three of its panels exist to show real addresses.

- [x] **[#81](https://github.com/Gerrrt/HomeLab/issues/81) A dashboard for the
      observability stack itself.** `homelab-stack`, 33 panels, all from metrics
      already collected. The argument in the issue was that two of the three
      faults found while verifying #12 would have been visible on it
      immediately, and the panels that would have shown them are the two the
      dashboard is really built around: *Samples returned per scrape*, where
      cAdvisor collapsing from hundreds of series to one is a step change while
      `up` stays 1, and the Alloy remote-write lag, where a stale address shows
      as a climbing line rather than as nothing at all.
      Three things came with it because the dashboard could not be honest
      without them. The five rules watching the stack's own components were
      carrying `component: containers` and so were filed under *Container
      alerts* on the Docker dashboard; they are now `stack.rules.yaml` on
      `component: stack`, a relabel with the expressions untouched. Each Alloy
      agent now scrapes itself and remote-writes the result, because
      `prometheus.yaml` could only ever reach the agent on this host —
      `oracle` publishes Alloy's port on loopback and there is no address to
      point at. And `check_docs.py` was matching spelled counts in lowercase
      only, so "Five dashboards are provisioned" was unguarded while "There are
      five dashboards" two files away was checked; both were stale together.
      One thing the dashboard made obvious was that **`up` is not a liveness
      signal for the jobs that arrive by remote_write**: a pushing agent that
      dies stops pushing, so its series ages out rather than falling to 0, and
      `InstanceDown` is `up == 0`. `RemoteWriteJobStale` closes that, and is
      worth reading for how it is written rather than what it covers. The
      obvious form, a threshold on the staleness the dashboard graphs, is
      unfireable for the same reason #63 was — an instant selector stops
      returning a sample after the lookback delta, so the difference never
      reaches the threshold. Both that form and the version with the guard
      dropped were run against the tests and both fail them. What ships asks
      which jobs were reporting in the last 24 hours and are not reporting now.
      It was then watched working rather than argued: the agent on the
      monitoring host was stopped for six minutes with the rule silenced, and
      the alert went pending at t+282s having returned nothing at all for the
      four and a half minutes before that — the lookback delta, and the real
      blind window on any remote-written target.
      The residual is in the 24-hour window: an agent away longer than a day
      resolves the alert falsely, having notified at least twice first. That is the price
      of matching on the job-name convention instead of a list, and the list is
      what would silently miss `Saruman` when it arrives (#88).
      Two panels were added afterwards, which is what closed the issue. The
      Alloy row charted throughput, lag, component health and forwarded lines
      but not the WAL, which the issue had asked for by name — *WAL size and
      append rate* and *WAL replay and corruption* now do, and the replay one
      earns its place by dating an agent restart to the minute, the context
      that is missing when the lag panel jumps and nothing says why.
      Adding them also found that the screenshot this dashboard has been
      waiting for could never have worked. `homelab-stack` renders 4582px tall
      against a `BROWSER_MAX_HEIGHT` of 3000, so a capture would have come back
      cropped at the Alertmanager row — with the Alloy panels, the reason to
      shoot it at all, off the bottom — and reported success. The ceiling is
      raised in `compose.yaml` and in the script together, and the dashboard is
      in `DASHBOARDS`; it is still unshot, because the window wants a clean day
      behind it rather than the hour after a deploy.

- [x] **[#77](https://github.com/Gerrrt/HomeLab/issues/77) Schedule something.**
      Four systemd timers *are written* to run `make backup` weekly,
      `make backup ARGS='--verify-only --all'` and `make backup-firewall` nightly,
      and `make snmp-verify` weekly; `make check-digests` runs weekly in GitHub
      Actions, which is the only one of the five that is genuinely off-host.
      **Installing them on the monitoring host is a separate step
      (`make install-timers`) and it was missed** — for the first days of this
      entry's life the sentence above was in the present tense and simply untrue,
      no unit was installed, and no scheduled job had ever run
      ([#215](https://github.com/Gerrrt/HomeLab/issues/215)). `make validate`
      passed throughout, because the check it ran compared two copies of the
      schedule that both live in git. It now also asks the host.
      Every run records its outcome as a metric, so five rules in
      `backup.rules.yaml` alert on a job having *stopped being run* rather than
      only on one that failed — which was the actual ask.
      `make secrets-verify-backup` deliberately has no timer: it needs a human to
      mount removable media, so it gets a ninety-day deadline and an alert
      instead. What this does **not** solve is that the host still verifies its
      own backups — that is #92 and #99, both still open.
      → [runbook](runbooks/schedule-maintenance.md)
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
- [x] Add alerting (34 rules) and Alertmanager routing
- [x] Move secrets to SOPS + age
- [x] Add CI: lint, config validation, secret scanning
- [x] Pin every image by digest, not just tag, with drift detection in CI
- [x] Add SECURITY.md with a disclosure policy and known-exposure summary
- [x] Loki alerting rules (13) for auth, SSH brute force and disk/OOM events,
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
