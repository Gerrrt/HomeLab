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

- **[#228](https://github.com/Gerrrt/HomeLab/issues/228) Decide whether Hicks
  should reach all of Winterfell and ImaginationLAN.** **The Winterfell half was
  answered on the firewall and never written down.** Read on `morpheus`
  2026-09-04, `pfctl -sr` with the interface tables resolved: the Hicks tab
  carries ten narrow passes into Winterfell — SSH, the pfSense management UI,
  the resolver, NTP, ping, the wiki on both ports, Grafana, and `mjolnir`'s card
  on both ports — above a logged *Block access to Winterfell*; a second logged
  *Block access to LAN* sits under the pass to the switch's web UI; and only
  then the catch-all. Nine of those passes and both blocks were created
  2026-09-02, the day after ADR-0013 was written, which is why that ADR and
  [ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)'s
  aside about "a catch-all nobody wrote" both describe a ruleset one day out of
  date. It is enforcing rather than decorative: the Winterfell block has dropped
  22 packets, and the passes above it carry the real traffic — 834,283 through
  *Allow SSH to Winterfell* alone — with only *Allow NTP* and *Allow HTTP to
  Mjolnir* still at zero. `network.md` and both security documents described the
  wider state until they were corrected against this read; the description is no
  longer the outstanding part, the posture is.

  **ImaginationLAN is the half still open.** No rule blocks it, so the catch-all
  grants the segment entire, on every protocol and port. *Allow Hicks access to
  ImaginationLAN* was recreated on the **Hicks** interface in the same batch —
  ADR-0013's dead rule, fixed — where it matches at last and grants nothing the
  catch-all was not already granting. What is left is to decide whether 30 gets
  the treatment 99 just had, and to write down the treatment 99 got. Still worth
  settling before [#102](https://github.com/Gerrrt/HomeLab/issues/102) and #95
  add passes to this tab, though the reason has changed: not precedent, which
  now exists, but position — this is an ordered list in which a pass below the
  blocks does nothing.
- **[#229](https://github.com/Gerrrt/HomeLab/issues/229) The switch LAN still
  carries pfSense's stock *Default allow LAN to any*.** `10.7.7.0/24` reaches
  every VLAN; `network.md` said "Nothing". Bounded by that segment holding only
  the switch — which is also the device that still answers its previous SNMP
  community (#84) and cannot do v3 (#85). Lower risk than #228: getting it wrong
  costs SNMP polling of `neo`, which is monitored.
- **[#84](https://github.com/Gerrrt/HomeLab/issues/84) Retire the MokerLink
  switch's previous SNMP community.** `neo` still accepts its old one alongside
  the new; its firmware will not persist a deletion. Accepted residual, recorded
  in `SECURITY.md`. The method is settled — overwrite the row rather than delete
  it — so what is left is a window in which the switch can be rebooted. Two rows
  go that way, not one: the *current* community, exposed in a local transcript
  and deliberately never rotated because doing so would have added a second stuck
  row, follows once the first overwrite is proven to survive a reboot. →
  [runbook](runbooks/rotate-snmp-community.md#the-mokerlink-switch-overwrite-the-row)
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
- **[#103](https://github.com/Gerrrt/HomeLab/issues/103) Give ADR-0008's SSO
  deferral an expiry.** Answered by
  [ADR-0022](adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md):
  the deferral ends on a state rather than a date — the first real secret, photo
  or document in the sensitive tier, any reachability from outside the house, or
  a third account holder, whichever comes first. At the first of those a
  decision gets recorded. Re-accepting is allowed; arriving at the same place by
  never looking is what the expiry removes.

  **Writing it turned up that ADR-0008's substitute for SSO does not exist for
  half the tier.** Per-application TOTP is available on Vaultwarden,
  Paperless-ngx and Home Assistant, and on none of Grafana, Immich or AdGuard
  Home — Grafana OSS has no MFA in any edition, Immich's upstream has declined
  it and points at OAuth, and AdGuard has one password-only admin. Grafana is
  the only one of the six deployed, so the thing ADR-0008 offered *in place of*
  SSO has never been available here, and for those three an identity provider is
  the only route to a second factor rather than a heavier alternative to one.
  What is outstanding belongs to #102: TOTP enrolled at first login on the three
  that can carry it, and the mini PC's disk encryption decided at build time
  rather than inherited from `prometheus` — a vault behind one factor on an
  unencrypted disk is not the bet `SECURITY.md` accepted for a metrics
  dashboard.
- **[#235](https://github.com/Gerrrt/HomeLab/issues/235) Decide whether the
  iLO stays on the lab segment.** ADR-0014 puts `ifrit`'s attack VM on
  ImaginationLAN, so `shiva` — the BMC of the box being defended, on firmware
  that will not get newer — is now layer-2 adjacent to a Kali VM. The only
  explicit pass on that interface exists because the iLO is there; moving it to
  Winterfell deletes two rules and the exception, and puts a BMC next to the
  firewall's admin UI instead. Found writing ADR-0014; recorded there, not
  decided.

## Monitoring

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
- **[#249](https://github.com/Gerrrt/HomeLab/issues/249) Scrape the UPS
  self-test schedule.** [#93](https://github.com/Gerrrt/HomeLab/issues/93) left
  `mjolnir` testing itself every fortnight and nothing able to see that it does.
  The schedule, the last-test date and the last result are all PowerNet OIDs and
  the `apc_ups` module walks the standard UPS-MIB only, so a card that reverts
  to `never(5)` produces no alert and no changed metric — `upsTestResultsSummary`
  holds `1` (donePass) forever. The missing pack was visible in a MIB already
  walked; the missing schedule is not, which is the same failure one level up.
  The real cost is not the two rules but a pinning decision for APC's MIB in
  `scripts/snmp-mibs.sh`, which has no first-party git ref to point at.
  → [runbook](runbooks/fit-the-ups-battery.md)
- **[#12](https://github.com/Gerrrt/HomeLab/issues/12) Capture dashboard
  screenshots.** `make screenshots` does five of the seven; the Logs and
  Security dashboards are deliberately excluded.
  → [`images/README.md`](images/README.md)

### The stack does not watch itself

Found while verifying [#12](https://github.com/Gerrrt/HomeLab/issues/12), and
new since this file was last honest:

- **[#67](https://github.com/Gerrrt/HomeLab/issues/67)** No dead man's switch on
  the notification path — a 200 into a dead topic is a successful notification.
  The awkward half of it — the watcher has to be somewhere other than this
  host — is answered: [ADR-0015](adr/0015-give-oracle-the-off-host-jobs.md)
  puts it on `oracle`. What that buys is bounded, and the ADR says so: it
  catches a silently dead notification path, and it cannot report a mains cut,
  because the switch between the two laptops has no battery (#110).

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
  off `prometheus`, and buy a spare ProDesk.** Half done. Since 2026-09-03
  `make backup-firewall` copies every export to `oracle` — ciphertext only, the
  key stays here — and exits non-zero if it cannot, so the nightly job's metric
  says "stopped leaving this host" rather than "fine". Off-host, not offsite:
  both laptops share a shelf and a roof, and nothing copies anywhere a fire
  would not reach. The copy needs a one-time key exchange between the two
  laptops before its first run can succeed, and fails on purpose until then.
  That copy shipped defaulting to the wrong account — `robo@10.0.99.30`, where
  the login is `atropos` — so every nightly run would have failed on
  `Permission denied` from the first one, the local export written and verified
  and the copy step dead. It was invisible for a day only because the checkout
  the timer runs from was behind the commit that added it, which is its own
  lesson: a default nobody has executed is a guess. Retention landed with the
  fix, because until then both sides kept every export ever taken, nightly,
  forever; `FW_KEEP` (default thirty, and deliberately not `KEEP`, which
  `make backup` already owns in the shared environment file) bounds each side,
  never evicts the newest, never touches a file the script did not write, and
  clears the `.part` fragments a died copy leaves on `oracle`. Both sides
  converge in one run from any divergence. The far side's login shell is zsh,
  where an unmatched glob is fatal rather than literal, so the prune deletes by
  explicit basename and sends no pattern over the wire at all.
  What remains is the spare — the same ProDesk model, racked on the #110
  shelf, powered off — and the rehearsal, which is what turns
  [`restore-the-firewall.md`](runbooks/restore-the-firewall.md) from a
  hypothesis into a runbook; it now carries the bench procedure to follow and
  what to record. Writing that procedure found the runbook's own decrypt
  command had never been run: it passed `--input-type binary`, which sops
  rejects on the first byte of a real export, so a restore following the
  runbook would have stopped at step one. Fixed, and it is the kind of thing
  the rehearsal exists to find. The volume sets `make backup` writes still sit
  on the host they protect. Unlike the firewall, they have been restored — the
  whole stack was brought up on a restored set on 2026-08-29 and verified — but
  nothing copies them anywhere. Where they go is no longer open:
  [ADR-0015](adr/0015-give-oracle-the-off-host-jobs.md) sends them to `oracle`
  alongside the firewall exports, which fits — a set is 867 MB of `age`
  ciphertext against 67 GB free — and leaves only the copying to build.
- **[#110](https://github.com/Gerrrt/HomeLab/issues/110) Rack the shelf switch.**
  A 1U vented shelf in **U4**, carrying the unmanaged switch `prometheus` and
  `oracle` hang off. Both shelf machines are laptops, so on a mains cut they stay
  running and go deaf while the switch between them and the network has no
  battery at all — the pack in #93 protects the rack, not the monitoring path.
  **The shelf is on hand; what is left is the rack visit**, to the spec measured
  at the rack on 2026-08-21: 4-post, square holes, full 1U with rear support
  rather than a cantilever. The spare ProDesk from
  [#92](https://github.com/Gerrrt/HomeLab/issues/92) racks here too, powered off.
  → [runbook](runbooks/fit-the-ups-battery.md)
- **[#251](https://github.com/Gerrrt/HomeLab/issues/251) Put the wiki on
  `oracle` into the repository, and back up its database.** ADR-0015 ratified a
  host whose main service is not described anywhere here: `wiki` and its
  Postgres were created by hand in November, the content volume is anonymous,
  nothing copies either volume anywhere, and `/etc/wiki/.db-secret` is mode
  664. The pages survive a disk failure because Wiki.js syncs from the
  Lemmiwinks repository; the accounts, history and configuration do not.
- **[#102](https://github.com/Gerrrt/HomeLab/issues/102) Build ADR-0008's
  sensitive tier on VLAN 99.** A low-power mini PC running Vaultwarden, Immich,
  Paperless-ngx and Home Assistant behind Caddy and step-ca, with AdGuard Home,
  ntfy and Homepage alongside. Nothing is bought and nothing is built. The
  placement is not the outstanding part — ADR-0008 settled it, and
  [ADR-0010](adr/0010-keep-the-resolver-on-the-gateway.md) has since been
  decided on top of it. What is outstanding is a purchase, a stack, and four
  firewall rules the ADR counted as two.

  **All four are insertions above a deny, and none of them is an addition.**
  ADR-0008 named 50→40 and 99→20 and said the estate's count "rises from three
  to five"; [ADR-0013](adr/0013-segment-access-as-implemented.md) retired the
  count precisely because a number cannot say *where in the order* a rule goes,
  and when these land they belong in that ADR's list rather than in a new total.
  ADR-0016 then read the ruleset and turned 50→40 into three — one on the Hicks
  tab and two on Winterfell's, each above a *Block access to CasaBonita* — and
  #95 carries those with the hardware, because a `pass` to an address with no
  NAS behind it is a rule nobody can test.

  **99→20 was the row nobody had read. It is read now.** `pfctl -sr` on
  `morpheus`, 2026-09-04: Winterfell blocks every other VLAN explicitly above
  its egress pass, *Block access to Skids* (`10.0.99.0/24 → 10.0.20.0/24`)
  among them, so Home Assistant's rule is the fourth insertion and not an
  append. It goes beside the two SNMP passes that already sit above that stack.
  Skids as a source is untouched — it blocks all five other VLANs, carries
  #223's tripwire, then egresses — and the return traffic for a session Home
  Assistant opens is carried by state and never reaches the ruleset. So **Skids
  stops being terminal inbound and stays terminal outbound**, the same trade
  ADR-0016 made for CasaBonita and with the same test: the tripwire's counter,
  zero today, must not move.

  **What the firewall cannot tell you is how wide the rule should be.** The
  other three are host- and port-scoped. This one has a source that does not
  exist yet, and a destination that is a whole segment unless the IoT devices
  are given statics — which would be a segment-wide grant of the kind #228
  exists to close, this time out of Winterfell and into the VLAN whose stated
  assumption is that everything on it is already compromised. Worth settling in
  the same sitting: Home Assistant discovers devices over mDNS, which is
  link-local and does not cross a VLAN boundary, so nothing on 20 appears by
  itself however the pass is written.

  **Two of the three things said to be waiting on this tier are not waiting on
  it.** [#67](https://github.com/Gerrrt/HomeLab/issues/67)'s watcher went to
  `oracle` under ADR-0015 and needs no self-hosted ntfy;
  [#97](https://github.com/Gerrrt/HomeLab/issues/97)'s host override was never
  downstream of AdGuard, which ADR-0018 says outright and ADR-0010 is the reason
  for. [#98](https://github.com/Gerrrt/HomeLab/issues/98) is the one that
  stands — there is no eero integration until there is a Home Assistant. What
  moving ntfy in-house *does* change is the alert path: the heartbeat's whole
  value is that it leaves the house, and an endpoint on a network with no
  external exposure cannot reach a phone that is not on it. Whether the
  in-house ntfy replaces the external topics or sits beside them is a decision
  this build makes, not a detail of it.

  **Two purchases where the plan assumed zero, and this is the first.** `oracle`
  cannot host it — ADR-0015 measured 2549 MiB available behind a 5400 rpm disk
  and a 100 Mb/s NIC — and ADR-0007 keeps household services off the lab
  hypervisor. The SSO this box deliberately does not get is
  [#103](https://github.com/Gerrrt/HomeLab/issues/103), and as of
  [ADR-0022](adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)
  it does not get it *until this box holds real data* rather than indefinitely —
  which puts two things on this build: TOTP enrolled on the three services that
  can carry it, and a disk encryption decision made here rather than inherited.
- **[#95](https://github.com/Gerrrt/HomeLab/issues/95) Plan and build the NAS on
  VLAN 40.** Planned;
  [ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
  answers the four questions #95 raised, and nothing is bought or configured.
  Reading the enforced ruleset first changed two of the answers. **50→40 is not
  a rule to add**: Hicks and Winterfell each carry an explicit *Block access to
  CasaBonita* above their catch-all, so the pass has to be ordered in front of a
  deny, and one appended where new rules naturally land would match nothing —
  the same fault ADR-0013 found in *Allow Hicks access to ImaginationLAN*. And
  **one rule is not enough**: every other host in the estate is monitored and
  backed up by pushing, so a NAS built like the others would have its Alloy
  agent initiating 40→99, the first upward path in the estate and the end of the
  property ADR-0008 claims to keep. The ADR reverses the direction instead —
  `node_exporter` scraped rather than Alloy pushing, the metadata backup pulled
  by `prometheus` rather than sent — which costs the NAS its logs, because Loki
  has no pull and its ingest is unauthenticated. Three rules, all inbound, all
  host- and port-scoped, written down and deliberately not created: a `pass` to
  an address with nothing behind it is a rule nobody can test. Terminal survives
  in the direction that carries it — CasaBonita stops being terminal inbound and
  stays terminal outbound, with #223's tripwire untouched. Capacity buys a
  four-bay chassis with two bays filled, because the bay count is the half that
  cannot be changed later and the library's size is a number nobody has.
- **[#101](https://github.com/Gerrrt/HomeLab/issues/101) Build ADR-0007's
  defended estate on `Saruman`** — a Windows domain, Wazuh, Velociraptor, PBS
  and a second observability stack. The umbrella. Nothing of it is built, but
  the shape is settled and the work is split seven ways, which is what moved it
  out of *Decided but not built* below.
  [ADR-0020](adr/0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)
  answered the two questions ADR-0007 left open, and both of them blocked the
  first line of work. `stacks/lab/` runs in a **guest**, not on the hypervisor:
  `Saruman` is the one host in the estate that must not run Docker, because
  ADR-0014 leans on its own firewall and Docker rewrites iptables — which is
  why #88 deployed the native `.deb` there rather than a container. And the
  stack carries its own **Prometheus**: ADR-0007 named three services while
  saying in the same sentence that `config.alloy` is reused with only the two
  `*_URL` variables changed, and that file has two sinks, so a lab without a
  Prometheus points the second one at `10.0.99.20` and inverts the isolation
  the ADR exists for.
  [#264](https://github.com/Gerrrt/HomeLab/issues/264) is built:
  `stacks/lab/` holds the compose file, both configs, four alert rules and
  their unit tests, and the secrets template. What is left of it is a deploy,
  which needs [#262](https://github.com/Gerrrt/HomeLab/issues/262) — the guest
  on `Saruman` — to exist first.
  → [runbook](runbooks/build-the-lab-guest.md) Building it made the tooling stack-aware
  (`render-config.sh` derives its required keys per stack rather than demanding
  the estate's ten, `reload-config.sh` skips services a stack does not declare,
  `bootstrap.sh` refuses to give one age key both stacks) and gave `.sops.yaml`
  the lab rule ADR-0020 asked for. [#263](https://github.com/Gerrrt/HomeLab/issues/263)
  followed it: `scripts/stacks.sh` is now the single definition of what a stack
  is, and `validate.sh`, `ci.yml`, `pin-digests.sh` and the Python checkers all
  read it instead of carrying `stacks/observability`. Both stacks are checked,
  each line says which, and a directory under `stacks/` with no compose.yaml
  fails rather than being skipped — a stack nothing checks being the defect the
  list exists to prevent. Two guards got stronger on the way: rules without
  `promtool` unit tests are now a failure rather than an absence nobody
  measured (#63), and the reload/ABSENT_BINARIES cross-checks gained a
  cross-stack mode, because "not in this compose file" stopped meaning "in no
  stack at all" the moment there were two.
  [#265](https://github.com/Gerrrt/HomeLab/issues/265) the domain is what
  everything else is pointed at, and blocks both
  [#266](https://github.com/Gerrrt/HomeLab/issues/266) Wazuh — the heaviest
  component, and the one most likely to be what the spindles run out on — and
  [#267](https://github.com/Gerrrt/HomeLab/issues/267) Velociraptor.
  [#268](https://github.com/Gerrrt/HomeLab/issues/268) PBS decides what it is
  for before it is installed, since a hypervisor backing up its own guests to
  itself is not a backup. Liveness stays where it already was, with
  [#257](https://github.com/Gerrrt/HomeLab/issues/257): ADR-0020 decides only
  that no Alertmanager goes *inside* the stack, and the lab is otherwise being
  built to go quiet.
- **[#96](https://github.com/Gerrrt/HomeLab/issues/96) Procure `ifrit` and build
  the playground** — only after the main network is finished. The isolation
  mechanism ADR-0007 deferred is settled by ADR-0014: `ifrit` is single-homed on
  ImaginationLAN, the targets sit on a bridge with no physical port on a subnet
  the firewall does not route, the attack VM does not forward, and the
  hypervisor management planes close at the host. ADR-0017 settles the rest —
  buy for IOPS and quiet rather than for threads, because the range's whole
  operation is snapshot-and-revert and `Saruman`'s complaint is already
  spindles; socketed RAM, because `prometheus`'s is soldered; `172.30.30.0/24`
  on the isolated bridge with no gateway anywhere on it; and no backups, no
  monitoring and no patching for the guests, so the least important part of the
  lab joins none of the estate's loops. "After the main network is finished"
  now names issues: #101 first, because an attack VM pointed at an
  uninstrumented estate teaches nothing; #234 before the segment holds
  attackers; #235 decided either way before this build makes it true. What is
  left is the purchase itself and the build.
  → [runbook](runbooks/build-the-playground.md)
- **[#97](https://github.com/Gerrrt/HomeLab/issues/97) Work out DNS for the
  MokerLink management UI** so it is not reached by IP. Answered by
  [ADR-0018](adr/0018-name-the-switch-and-leave-its-ui-on-plain-http.md), which
  splits the issue in two and only grants one half. The name is a host override
  like any other — `neo` → `10.7.7.2` — and was never blocked behind ADR-0008,
  because ADR-0010 keeps the overrides on Unbound whatever AdGuard does. **The
  certificate half is closed as unavailable rather than pending:** the switch
  has no TLS listener and no way to import one, checked against the device on
  2026-09-04. That is its third firmware limit after #84 and #85, and the
  argument for replacing it — where TLS management belongs in the selection
  criteria next to SNMPv3. What is left is applying the override and adding the
  `via: dns` blackbox twin, in that order.

## Automation

- **[#98](https://github.com/Gerrrt/HomeLab/issues/98) Device joins as events.**
  Answered by
  [ADR-0019](adr/0019-read-device-joins-from-the-dhcp-server.md), which keeps
  the issue's landing site and changes its source. The events belong in Loki
  and in `security.rules.yaml` — that part was right. But "the eero API" is a
  cloud API: there is no local one, the integration everyone means is a HACS
  component polling `api-user.e2ro.com` every 120 seconds, and it cannot log in
  with an Amazon-linked account. Routing a question about this network's own
  wire through Amazon makes the answer late and makes it disappear whenever the
  WAN does. **`morpheus` already knows.** The eeros are bridged, Kea serves
  every segment, and 1,200 lease lines a day are one pfSense checkbox from the
  1514 listener that already carries filterlog. Three rules land in the `dhcp`
  group: first lease on Hicks in seven days (warning), the same on Winterfell
  (critical, and zero in 13 days of logs), and `DhcpLeaseLogsStopped`, because
  the other two fail silently. Measured cost on Hicks: about one alert every
  three days, and every one of the five in the sample was worth a look — two of
  them an OUI the inventory places on Skids. **No longer blocked behind
  ADR-0008's sensitive tier**, and leaves are dropped rather than deferred: 9
  releases against 4,732 allocations in four days, and a departure is not a
  security event. What is left is ticking **DHCP Events** on `morpheus` —
  before the rules deploy, or `DhcpLeaseLogsStopped` fires truthfully — and
  reading the first week, which is one alert per device and therefore an
  inventory check.
  → [runbook](runbooks/ship-firewall-logs.md)
- **[#99](https://github.com/Gerrrt/HomeLab/issues/99) Move deployment from
  `make up` over SSH to something pull-based**, so the host converges on the repo
  rather than being pushed to. Answered by
  [ADR-0021](adr/0021-converge-on-a-timer-instead-of-deploying-over-ssh.md): an
  hourly timer running `scripts/converge.sh`, on #77's existing wrapper and
  alert machinery. The issue's stated blocker — an age key on a host that pulls
  from a public repository — turned out not to be one, because the key was
  already on that host and *public* means readable. The real question was
  unattended execution, and the answer is a pinned signing fingerprint plus a
  record of every revision deployed. What is deliberately left out: `oracle` and
  `saruman` are still pushed to with `deploy-agent.sh`, and nothing tracks
  unifying that.
- **[#100](https://github.com/Gerrrt/HomeLab/issues/100) Automate the Grafana

## Decided but not built

Accepted ADRs with no work behind them. Recorded here because an accepted ADR
with nothing tracking it is indistinguishable from a rejected one after six
months.

- **[#234](https://github.com/Gerrrt/HomeLab/issues/234)** ADR-0014's tripwire
  on ImaginationLAN — the fourth rule in #223's shape, a Loki rule whose source
  is `10.0.30.0/24`, and the restore runbook expecting four where it expects
  three. Log-only; a no-op until the segment holds attackers.
- **[#102](https://github.com/Gerrrt/HomeLab/issues/102)** ADR-0008's sensitive
  tier — the mini PC, its nine services and the four firewall rules. Under
  **Infrastructure** above, because it has a shape now rather than only a
  decision.
- **[#103](https://github.com/Gerrrt/HomeLab/issues/103)** The SSO deferral
  ADR-0008 takes knowingly, given an expiry by
  [ADR-0022](adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md).
  Under **Security** above, because it has a condition now rather than only a
  decision.

## Done

- [x] **[#105](https://github.com/Gerrrt/HomeLab/issues/105) Confirm the
      unconfigured Snort package actually went.** 2026-09-04. It did.
      `pkg info` on `morpheus` lists `pfSense-pkg-suricata` and `suricata` and
      no Snort of any kind, so ADR-0006's line 49 was describing a fact and the
      runbook prerequisite asking for the removal was describing a job already
      done. The prerequisite is gone from
      [`enable-suricata.md`](runbooks/enable-suricata.md) §0; the ADR stands as
      written.

      **What "removed" left behind is worth knowing before the next package is
      uninstalled.** pfSense removed the package but honoured
      `forcekeepsettings`, so `config.xml` kept a `<snortglobal>` stanza — and
      inside it `snort_alerts:col2:open`, a widget record pointing at a
      `snort_alerts` widget no longer on disk; only `suricata_alerts.widget.php`
      is there. `/var/log/snort/` also survived, holding one 111-byte
      rules-update log from 2025-10-30. The `snort`-named keys under
      `<suricata>` — `snortcommunityrules`, `enable_snort_custom_url` — are not
      residue at all: they are Suricata's own names for the Snort Community
      ruleset options, both `off`, and were left alone.

      **Both are now cleared.** `config_del_path()` and `write_config()` over
      SSH for the stanza, `rm -rf` for the log directory, with an encrypted
      off-host export taken either side. Not because the residue was dangerous
      — nothing ran, updated or listened, and the live dashboard reads
      `<widgets><sequence>`, which never referenced `snort_alerts`, so nothing
      was even visibly broken. It went because of the one line in the stanza
      that was not inert: `<forcekeepsettings>on</forcekeepsettings>` is what a
      future `pkg install pfSense-pkg-snort` would have read its settings back
      out of, so leaving it meant a reinstall resurrecting a half-configured
      Snort rather than starting clean — the 1am mistake this issue was opened
      about, deferred rather than closed.

      Verified after the write: 88 user-defined rules, the same count the
      pre-change export recorded; `<widgets><sequence>` byte-identical;
      Suricata still on `igc0.20` and `igc0.10` under the same PIDs, never
      restarted; web UI answering 200. `write_config()` leaves its own audit
      line in the config revision log, so the word `snortglobal` still appears
      once in `config.xml` — as the description of the change that removed it.

- [x] **[#100](https://github.com/Gerrrt/HomeLab/issues/100) Automate the Grafana
      dashboard export step.** 2026-09-04. `make dashboards-export` pulls every
      dashboard back by uid and writes it over the file, so the loop is edit →
      one command → `git diff` rather than a hand copy out of the JSON Model
      panel — manual, and therefore skipped under pressure, which is what this
      file said about it.

      **The issue's design could not work as written, and finding out why is
      most of what this was.** The plan was to pull each dashboard from the API
      and write it back. But `allowUiUpdates` was `false`, and that does not
      mean what the issue assumed it meant: Grafana does not discard a UI edit
      at the next restart, it refuses to *store* one at all —
      `POST /api/dashboards/db` answers `400 Cannot save provisioned
      dashboard`. So the API could only ever return the file it was provisioned
      from. Every export would have been a clean no-op over the very edit it
      existed to capture, exiting zero and writing nothing while `git diff`
      reported no change to something plainly different on the screen. Measured
      against the running stack before anything was built: the API's copy of
      `homelab-docker` was identical to the committed file in every field but
      `id` and `version`.

      So `allowUiUpdates` is now `true`. The JSON stays the source of truth —
      a file change re-provisions over Grafana's copy — but an edit now survives
      long enough to be exported. What `false` bought for free was that the
      running dashboard and the committed one could not disagree, and that is
      bought back rather than dropped: `ARGS=--check` writes nothing and exits
      non-zero when Grafana holds an edit git does not, and the daily
      `dashboards-drift` timer runs it, so forgetting to export ages into a
      stale job with an alert behind it. The rules in `backup.rules.yaml` join
      against the `JOBS` table rather than naming jobs, so it needed no rule.

      Two things found on the way, both of which would have made the diffs
      unreadable. Grafana serialises keys **alphabetically** at every level,
      while these files put `uid`, `title` and `description` first — a naive
      write-back would have reordered every key in all seven and buried the one
      line that changed, so the committed order is preserved and only new keys
      are appended. And Grafana persists whatever the browser was showing at
      save time, so the time picker's range and each variable's selection are
      read back out of the file rather than taken from the API: without that,
      one person's afternoon of debugging silently becomes everyone's default
      time range. Those fields are the one thing the round trip will not write,
      and the dashboards README says so.

      The round-trip check the issue asked for boots the pinned Grafana image,
      provisions the committed JSON into it and reads it back, which is what
      keeps an export from arriving as noise. It also asserts that a save to a
      provisioned dashboard is still accepted — the condition the whole feature
      depends on and the one it cannot detect for itself, since flipping the
      flag back breaks the export silently. Verified in both directions: with
      `allowUiUpdates: false` the check fails and names the setting.
      → [`grafana/dashboards/README.md`](../stacks/observability/grafana/dashboards/README.md)

- [x] **[#94](https://github.com/Gerrrt/HomeLab/issues/94) Decide what `oracle`
      is for.** 2026-09-03,
      [ADR-0015](adr/0015-give-oracle-the-off-host-jobs.md). The issue's four
      options were answered by first checking the machine, which made one of
      them impossible: `oracle` has run the Lemmiwinks wiki and its Postgres
      since 2025-11-12, ADR-0011 depends on it, and blackbox has been probing
      it twice on `host: oracle` all along. Three places in the repository said
      it had no role at the same time — the host table in `architecture.md`,
      the VLAN 99 notes in `network.md`, and `backup-firewall.sh`'s header
      ("It has no role (#94)"). `check_docs.py` reads that architecture row for
      the word "Alloy" and for a `stacks/` path and never for what it claims
      the host does, which is how the wrong sentence sat next to a checked one.

      **Decided:** it stays powered, and its role is the small off-host jobs —
      work whose value is that it is not on the monitoring host. The wiki and
      the firewall export copy it already has; the volume backup sets (#92) and
      the dead man's switch watcher (#67) are added, decided here and built
      under their own issues. **Rejected:** a second age recipient, because
      `back-up-the-age-key.md` already answers that gap with an *offline* key
      and a second person, and because a private key on `oracle` would put the
      backups and the means to open them on one disk and retire the property
      the off-host copy exists to have. Also rejected: the ADR-0007 stack, the
      ADR-0008 tier, bringing `wlp22s0` up to give the watcher an independent
      path — that dual-homes a VLAN 99 host onto an untrusted segment — and
      switching the machine off, which was never really on offer: the wiki had
      been running there for nine months when the issue was filed.

      Measured rather than quoted, 2026-09-03: 3785 MiB of RAM with 2549
      available under the wiki, its database and Alloy; a 465.8 GB 5400 rpm
      disk carrying one 100 GB LV with 67 GB free and 362 GB unallocated; and a
      NIC that advertises 10/100 only, so the link is 100 Mb/s and no cable
      will change that. A 867 MB backup set is 75 seconds of wire time there;
      seven of them are 6.1 GB, and they are already `age` ciphertext before
      they leave this host.

- [x] **[#93](https://github.com/Gerrrt/HomeLab/issues/93) Replace the UPS
      battery, delete the silence, put the card under scheduled test.**
      2026-09-03. The first two steps were done on 2026-08-28: an APCRBC115 into
      `mjolnir`, `upsTestResultsSummary` `4` (aborted) → `1` (donePass) at
      22:45 UTC, and the `UpsSelfTestFailed` silence
      `54f1715c-e57b-4322-8a6d-5435bc8e1bd8` deleted at 23:14 rather than left
      to lapse on 2026-09-20 — nine minutes after the proving reading instead
      of before it, which is the inversion the runbook exists to prevent and
      which cost nothing only because the test passed.

      The third step turned out to need checking rather than doing. The card
      reads `upsAdvTestDiagnosticSchedule` `8` (biweeklySinceLastTest), with
      `upsAdvTestDiagnosticsResults` `1` (ok) and
      `upsAdvTestLastDiagnosticsDate` `08/28/2026`. Six files had been asserting
      the opposite since the fit; they now say what the device says. Whether the
      schedule was set at the rack or has been the default all along, the NMC
      will not say after the fact.

      **Nothing watches it.** All three are PowerNet OIDs and the `apc_ups`
      module walks the standard UPS-MIB only, so a card that reverts to
      `never(5)` produces no alert and no changed metric — `upsTestResultsSummary`
      would simply hold `1` forever. Closing that means adding APC's MIB to
      `scripts/snmp-mibs.sh`, which is a new vendor source with its own pinning
      decision; it is filed as
      [#249](https://github.com/Gerrrt/HomeLab/issues/249) rather than done
      here. Until it is, the check is
      `scripts/snmp-walk.sh --device mjolnir 1.3.6.1.4.1.318.1.1.1.7.2`, and
      what proves the schedule *runs* rather than merely being set is that date
      advancing unattended, due around 2026-09-11.

      Two smaller findings. `upsBasicBatteryLastReplaceDate` still reads
      `08/15/2026` for a pack fitted on the 28th, so the card's battery-age
      accounting is keyed to a date on which its own self-test was still
      aborting over an empty bay. And runtime is a poor proof of a real pack on
      this UPS: since the fit it has sat on exactly `63` — the fabricated
      value — for 744 of 764 samples. Voltage moving across `540`-`549` is the
      comparison that actually discriminates.
      → [runbook](runbooks/fit-the-ups-battery.md)

- [x] **[#91](https://github.com/Gerrrt/HomeLab/issues/91) Probe the services
      this was filed for, and probe TLS expiry.** 2026-09-03. Seven named, five
      probed, plus the one the sentence about "four devices" implied: Grafana
      by name and by address through a new `http_2xx_lab_ca` module that
      verifies the chain against `certificates/ca.pem` (now mounted into
      blackbox-exporter, CA only); Prometheus and Loki at the address the
      agents push to, so a mis-set `BIND_ADDR` fails the probe while every `up`
      stays green; Alertmanager on the compose network, the only network it is
      on; the switch UI, which is plain http and drops 443; and the APC card,
      https-only with a self-signed certificate, through `http_2xx_self_signed`.
      `TlsCertificateExpiringSoon` at 30 days and `TlsCertificateExpiryImminent`
      at 7 read `probe_ssl_earliest_cert_expiry` off the handshake, aggregated
      per certificate so Grafana's two URLs raise one alert, the critical
      inhibiting the warning. Every enabled target was probed through the new
      modules from a throwaway exporter on the compose network before landing,
      and the lab-CA module was checked to *refuse* the APC card's certificate.

      Two of the seven are written into `targets/blackbox.yaml` and disabled.
      From `10.0.99.20` the iLO and the pfSense UI both time out, and neither
      is a fault: VLAN 99 → 30 passes SNMP and nothing else, and "Block HTTPS to
      pfSense" on igc0.99 is an explicit rule. Each needs one pass on the
      Winterfell interface, written out beside the target, and each is a
      segmentation decision to record in ADR-0013's table when made — the
      pfSense one hands a host with two unauthenticated push ports a path to
      the firewall's login page, and #235 may move the iLO first.

- [x] **[#90](https://github.com/Gerrrt/HomeLab/issues/90) Detect Suricata
      being dead.** 2026-09-03. The roadmap line said the SNMP module does not
      expose a heartbeat; the firewall's agent already did. `bsnmpd` on
      `morpheus` loads `snmp_hostres.so`, so HOST-RESOURCES-MIB `hrSWRunTable`
      is served — 94 rows, 0.04s for a full walk — with one `suricata` row per
      interface and the interface in `hrSWRunParameters` (`-i igc0.20 …`),
      indexed by pid+1 and renewed on every rule update. The `pfsense` module
      now fetches those rows and nothing else from the table, through a
      dynamic filter on `hrSWRunName`, with a `DisplayString` override because
      both string columns are `InternationalDisplayString` and would otherwise
      arrive as hex. `SuricataStopped` in `prometheus/rules/ids.rules.yaml` is
      "declared but not running" per interface, gated on the scrape being up,
      unit-tested against the rows as morpheus read them. It proves the process
      is alive, not that it detects; the runbook's test alert still owns that.

      Proved live the same day. The Degens instance was stopped at 04:49:59
      UTC; `SuricataStopped` for `igc0.10` alone went firing at 05:00:49
      (10m50s) and reached the `security` receiver, Skids stayed quiet. Started
      again at 05:01:12, resolved at 05:03:00 with the row back under index
      `90324` for pid `90323`. A full package restart at 05:03:23 — the shape
      of the daily rule update — never reached firing. Scrape cost for the
      module went from nothing measurable to 0.26s.

- [x] **[#89](https://github.com/Gerrrt/HomeLab/issues/89) Extend Suricata to
      Degens (VLAN 10).** 2026-09-02. Second interface, twelve days after the
      first, alert-only on both. Its alerts are told apart from Skids' by the
      syslog facility — the one per-interface setting pfSense puts on the wire
      — which `syslog.alloy` maps to `interface`; both Loki rules and the
      dashboard split on it. Proven per interface with the §4 test rules: the
      first real alert arrived two seconds after the engine started, labelled,
      and was the same stream-timestamp signature that is 79% of Skids.

      Two things the pipeline test found on the way. *Restart* on the
      interface left the process stopped until started by hand, and loading
      the ruleset then took 35 seconds — a test visited in that window fires
      nothing and looks like a broken pipeline. And a guest iPhone with
      iCloud Private Relay produced no plaintext DNS or HTTP at all, so neither
      test rule could fire from it; the engine's own `alerts.log` on the box is
      what separates "never fired" from "fired and lost". Both are in the
      runbook now. The fortnight comparison of that shared signature is dated
      2026-09-16 there. → [runbook](runbooks/enable-suricata.md)

- [x] **[#76](https://github.com/Gerrrt/HomeLab/issues/76) Replace `shiva`'s
      Smart Storage Battery.** 2026-09-02. Spare `815983-001` fitted;
      `Saruman` was off 22:30–22:58 UTC. The first scrape after it came back
      read chassis 0 battery 1 at `cpqHeSysBatteryCondition` `2` (ok) and
      `cpqHeSysBatteryStatus` `1` (noError), down from `4` and `13`, with serial
      `6EZBN0FB2431YM` where the failed pack was `6EZBN0CB29N3YZ` — a different
      part being read, not the old one reading differently. The Smart Array
      re-enabled its cache on the same scrape: `cpqDaAccelStatus` `5` → `3`
      (enabled), `cpqDaAccelBackupPowerSource` `1` → `4` (smartbattery),
      `cpqDaAccelBattery` `6` → `2`, and the three controller rollups that had
      read `3` (degraded) since 2026-08-18 back to `2`. `cpqDaAccelBadData`
      stayed `2`: nothing dirty was lost at either end.

      The silence `bfdfff66-d9c3-4df4-9495-f1f38ebf93c1` was deleted at 23:11
      UTC rather than left to expire on 2026-10-01, so `IloBatteryCondition`
      and `IloWriteCacheDisabled` are live again over the new part. Deleted
      nine minutes *after* the proving reading, not before — the UPS
      inversion again. It cost nothing because both rules carry a `for:`
      longer than nine minutes, which is the rule shape being kind, not the
      procedure working.

      **Two readings did not move, and neither is alerted on.**
      `cpqDaAccelWriteCachePercent` / `ReadCachePercent` still read `0` / `0`
      ten minutes in, where a P440ar normally reports a ratio; the controller
      says the cache is enabled and reports no split. And
      `cpqDaAccelFailedBatteries` still reads `1`, unchanged from the failed
      pack. Both are named in the runbook with the `ssacli` check on `Saruman`
      that resolves the first; the metrics before 2026-09-02 show the failed
      pack and a write-through array, which any range crossing that date will
      include.
      → [runbook](runbooks/replace-the-smart-storage-battery.md)

- [x] **[#88](https://github.com/Gerrrt/HomeLab/issues/88) Deploy Alloy to
      `Saruman` and `oracle`.** 2026-09-02. One script,
      `scripts/deploy-agent.sh`, for both: the compose service written out as
      `docker run` for a Docker host, and the `.deb` matching the compose tag
      for a host that should not run Docker, which a Proxmox hypervisor is. The
      agent config became a directory of three files so the native package
      loads no Docker components and opens no syslog port on the hypervisor's
      real interface.

      `oracle` turned out to have been the actual gap. It was deployed by hand
      on 2026-08-30 and by 2026-09-01 was running a version behind compose, as
      `--privileged`, with the config it was copied with — no self-scrape, so
      `oracle-alloy` never existed and nothing said so — and no volume for its
      WAL. The runbook's verification could not fail: Alloy logs to stderr and
      the grep read stdout. Redeployed with the script; three jobs now.

      `Saruman` needed a decision, not a deploy: ADR-0007 said it does not
      remote-write to Winterfell and ADR-0012 assumed it does. Resolved for the
      hypervisor's own telemetry only, over one unlogged pass above the
      ADR-0014 tripwire; both ADRs carry a note. The rule and the run are the
      operator's, from Hicks, since 99 → 30 is closed.

      Two more things found on the way, neither fixed here. Since #188 every
      Docker-host agent logs cAdvisor's `rootDiskErr` every few minutes —
      root without `DAC_READ_SEARCH` cannot always size overlay layers —
      partial, nothing charted depends on it, and nobody wrote it down; the
      deploy gate ignores exactly that line. And a throwaway `alloy run` on the monitoring host resolves
      `prometheus` through the host's DNS and pushes into the live stores:
      four `instance="smoke"` series and a silenced `RemoteWriteJobStale`,
      because there is no admin API to delete them.

- [x] **[#87](https://github.com/Gerrrt/HomeLab/issues/87) Add `ifXTable` (64-bit
      counters) to the `mokerlink` module.** Swapped in rather than added: the
      64-bit `ifHCInOctets`/`ifHCOutOctets` replaced the 32-bit pair, so the walk
      stayed at five columns and the load on a switch that has wedged under
      polling stayed where it was. Each column was fetched first with the new
      `scripts/snmp-walk.sh`, at the exporter's own request shape, and the low
      32 bits matched the live counters on every busy port.

      Two things found on the way went with it. `SwitchCounterWrapSuspected`
      could never fire — `rate()` never goes negative — so it was deleted, not
      re-pointed. And no switch metric had ever carried an `ifDescr` label: the
      generator comment said "label lookup" but no lookup existed, so every
      port name in the dashboard and the `SwitchInterfaceDown` summary rendered
      blank. One `lookups` stanza fixed both.

- [x] **[#86](https://github.com/Gerrrt/HomeLab/issues/86) Decide whether the
      lab VLAN needs egress filtering.** No. ADR-0014. The question and #96's
      deferred isolation mechanism were one decision, and the fact that
      decided it is that the techniques the estate exists to detect are layer
      2 — poisoning, spoofing, rogue DHCP — and do not cross a router. So the
      attacker shares the segment with the Windows domain, and the vulnerable
      targets get no route at all: a bridge inside `ifrit` with no physical
      port, on a subnet the firewall does not know. A port allowlist would
      have passed C2 on 443 and broken Kerberos by blocking NTP; a range VLAN
      would have routed every scan through the box that runs the house and
      hidden the layer-2 techniques from the estate.

      Two things it found and did not decide: the iLO of the defended estate
      is now on the attackers' segment (#235), and the segment gets a log-only
      tripwire like the three terminal ones (#234).

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
