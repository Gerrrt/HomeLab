# Roadmap

**The tracking lives in [Issues](https://github.com/Gerrrt/HomeLab/issues).**
This file is the shape of the work — what is outstanding, what gates it, and
why it is in this order. Whether a thing is started, blocked or done is on its
issue. What happened, and what it found, is in
[`changelog.md`](changelog.md), dated. Two places holding the same checkbox is
how a checkbox stops being true, and for a month this file was the second
place — [#577](https://github.com/Gerrrt/HomeLab/issues/577) moved the history
out.

The order is the seven
[milestones](https://github.com/Gerrrt/HomeLab/milestones), each of which
states what closes it. This file adds what a milestone cannot say: the order
between them, and inside each the order and the gate where an issue cannot
carry it alone.

What an entry here may contain:

- **A link, the gate, its place in the order, and why.** Nothing else. No
  date except a gate that is a date.
- **When the issue closes, the entry leaves.** Anything worth keeping goes to
  [`changelog.md`](changelog.md) as a dated entry, in the same PR.
- **An accepted ADR with work behind it has an issue in a milestone.** One
  that does not is the bug, not a section here.
- **A PR that implies a purchase edits *Everything still to buy* in the same
  commit.** That section is the one place a purchase enters or leaves, and
  the README's count of outstanding purchases is checked against it.

## The order

1. [**Nothing blocks these**](https://github.com/Gerrrt/HomeLab/milestone/1)
   — first because nothing gates them, and three of them carry a date.
2. [**trinity**](https://github.com/Gerrrt/HomeLab/milestone/2) — the return
   on the box closes 2026-10-08, and the rehearsal is the step that ends it.
3. [**NAS**](https://github.com/Gerrrt/HomeLab/milestone/4) and
   [**Saruman: the domain, then the SOC**](https://github.com/Gerrrt/HomeLab/milestone/3)
   — side by side, with no order between them. Each has one issue that goes
   first for its own reason: a mirror that is one disk, and a domain that
   everything else on that host points at.
4. [**automation**](https://github.com/Gerrrt/HomeLab/milestone/5) — the
   pipeline that populates the domain; it runs from `phoenix`, which exists.
5. [**last**](https://github.com/Gerrrt/HomeLab/milestone/6) — gated on the
   domain, on a household observation, or on something to publish.
6. [**Tier extras**](https://github.com/Gerrrt/HomeLab/milestone/7) —
   decision-gated, and outside the order until one is decided.

## Nothing blocks these

Closes when it is empty.

- **[#444](https://github.com/Gerrrt/HomeLab/issues/444) Swap the MokerLink
  for the CRS326.** Decided by
  [ADR-0041](adr/0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md).
  Gate: the switch landing, and a rack window outside working hours — `neo`
  carries every VLAN, so the swap cannot share the day with anyone working
  on them. → [runbook](runbooks/swap-the-switch.md)
- **[#84](https://github.com/Gerrrt/HomeLab/issues/84) Retire the MokerLink's
  previous SNMP community.** Closes with #444: the row cannot be verified,
  so it is retired by the hardware leaving, not by a measurement.
  → [runbook](runbooks/rotate-snmp-community.md#the-mokerlink-switch-overwrite-the-row)
- **[#531](https://github.com/Gerrrt/HomeLab/issues/531) Fit `oracle`'s
  cell.** The cell is bought. What closes it is the fit, the mains pull, and
  the silence deleted rather than left to expire on 2026-10-08.
  → [runbook](runbooks/replace-the-laptop-cell.md)
- **[#573](https://github.com/Gerrrt/HomeLab/issues/573) Carry the backup sets
  off the shelf.** Decided by
  [ADR-0048](adr/0048-carry-the-estates-backup-sets-with-the-second-recipient.md):
  the newest set of each kind rides on the medium that holds the second age
  recipient, on the ninety-day visit that medium already owes. The mechanism
  is built; the gate is the visit, and the issue closes on the first one.
  → [runbook](runbooks/copy-the-backups-offsite.md)
- **[#574](https://github.com/Gerrrt/HomeLab/issues/574) Shut down on the
  UPS's signal.** Decided by
  [ADR-0049](adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md);
  nothing is built. No purchase and no new path between segments — the gate is
  a rack visit, which builds it, proves the order with `upsmon -c fsd`, and
  pulls the mains once to replace the card's 47-minute claim with a number.
  Shares a window with #531's fit and, if its parts have landed, #444.
  → [runbook](runbooks/shut-down-on-the-ups.md)
- **[#294](https://github.com/Gerrrt/HomeLab/issues/294) Add a second age
  recipient.** The implementation half of
  [#106](https://github.com/Gerrrt/HomeLab/issues/106), decided by
  [ADR-0024](adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)
  and held by the technical second named on the break-glass card. The
  recipient is added and the file re-keyed: `.sops.yaml` and the ciphertext
  carry two, and either opens the secrets. The gate is the first proof of the
  new copy, which is the visit #573 also rides — the check refuses the live
  key by device and inode, so no timer can clear it and the medium has to be
  brought to this host. `SecretsKeyBackupUnproven` names that recipient until
  then, which the runbook calls the honest reading of a backup nobody has
  tested rather than a fault.
  → [runbook](runbooks/back-up-the-age-key.md)
- **[#604](https://github.com/Gerrrt/HomeLab/issues/604) Watch the dynamic DNS
  record.** [ADR-0044](adr/0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md)
  recorded the gap and left it to a follow-up. Since
  [#442](https://github.com/Gerrrt/HomeLab/issues/442) closed on 2026-09-22 the
  remote path depends on that record, and nothing asks whether it still
  resolves to the WAN address. The address is sticky, so a broken updater stays
  invisible for months and surfaces on the one day it matters.

The rest of the milestone has no order between its issues.

## trinity

Closes when the nine services serve from `trinity` and the firewall restore
has been rehearsed on it.

- **[#92](https://github.com/Gerrrt/HomeLab/issues/92) Rehearse the firewall
  restore.** First, because the box was sold with a thirty-day return that
  closes **2026-10-08**, and installing pfSense over the Windows it arrived
  with is both the step that proves the machine and the step that ends the
  return. Gate: the I226 card and the installer stick. The rehearsal is what
  turns the runbook from a hypothesis into a procedure.
  → [runbook](runbooks/restore-the-firewall.md)
- **[#404](https://github.com/Gerrrt/HomeLab/issues/404) Build the tier's
  host.** After #92: the same box, wiped and built once the rehearsal is done
  ([ADR-0034](adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)).
  [#533](https://github.com/Gerrrt/HomeLab/issues/533) and
  [#534](https://github.com/Gerrrt/HomeLab/issues/534) follow the build.
- **The nine services**, each authored ahead of the hardware and each open
  until it serves from the host:
  [#129](https://github.com/Gerrrt/HomeLab/issues/129) Caddy and
  [#130](https://github.com/Gerrrt/HomeLab/issues/130) step-ca first, because
  everything else sits behind the one and is issued by the other
  ([ADR-0037](adr/0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md);
  [#426](https://github.com/Gerrrt/HomeLab/issues/426)'s expiry rule lands with
  it — → [runbook](runbooks/build-the-tier-ca.md)); then
  [#135](https://github.com/Gerrrt/HomeLab/issues/135) AdGuard Home, whose
  `morpheus` half is a resolution-mode change
  ([ADR-0010](adr/0010-keep-the-resolver-on-the-gateway.md), →
  [runbook](runbooks/forward-dns-to-adguard.md));
  [#131](https://github.com/Gerrrt/HomeLab/issues/131) Vaultwarden;
  [#132](https://github.com/Gerrrt/HomeLab/issues/132) Immich;
  [#133](https://github.com/Gerrrt/HomeLab/issues/133) Paperless-ngx;
  [#134](https://github.com/Gerrrt/HomeLab/issues/134) Home Assistant, whose
  `99 → 20` rule also waits on a Kea reservation for the Hue bridge
  ([ADR-0035](adr/0035-scope-the-99-to-20-rule-to-the-hue-bridge.md));
  [#136](https://github.com/Gerrrt/HomeLab/issues/136) ntfy, which decides
  whether the in-house topic replaces the external ones or sits beside them;
  and [#137](https://github.com/Gerrrt/HomeLab/issues/137) Homepage. The
  restore path is rehearsed already:
  → [runbook](runbooks/restore-the-sensitive-tier.md).
- **[#455](https://github.com/Gerrrt/HomeLab/issues/455) The off-estate copy.**
  **The drive is bought** — 2026-09-22, in
  [`hardware.md`](hardware.md) — so what is left is not a purchase. Two
  conditions
  [ADR-0023](adr/0023-keep-the-household-recovery-path-outside-the-estate.md)
  attaches are open and a drive satisfies neither: the copy is encrypted with
  a key that is **not** the one only the operator holds, and the path is
  opened once **from the other person's device, without the operator
  present**. Whether that key is
  [ADR-0024](adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)'s
  second recipient or a separate one is the decision this issue still owes.
  Before the tier holds real data, not after:
  [ADR-0022](adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)'s
  first trigger is the first real photo or document, so this precedes Immich
  and Paperless-ngx going live.

## NAS

Closes when the faulted Exos is replaced and the mirror resilvered, and a
workstation can mount the share.

- **[#558](https://github.com/Gerrrt/HomeLab/issues/558) Replace the faulted
  Exos.** First: `erebor` is one disk until the swap and the resilver.
  → [runbook](runbooks/replace-the-nas-disk.md)
- **[#571](https://github.com/Gerrrt/HomeLab/issues/571) Decide what stands
  between ZFS and the pair.** After the swap, with the replacement in hand —
  the controller nobody recorded is read then, not guessed at now.
- **[#523](https://github.com/Gerrrt/HomeLab/issues/523) A rule for the share**
  and **[#570](https://github.com/Gerrrt/HomeLab/issues/570) a healthcheck
  that can fail** have no gate and no order between them.
- **[#140](https://github.com/Gerrrt/HomeLab/issues/140) Audiobookshelf** is
  authored — the service, a fifth Hicks pass it needs and the #140 text said
  it did not, and its archive in the NAS pull, `pending` until deployed
  ([ADR-0050](adr/0050-add-audiobookshelf-to-the-media-tier-behind-a-fifth-hicks-pass.md)).
  What is left is [`build-the-nas.md`](runbooks/build-the-nas.md) §6.5 on
  `smaug`, gated on the mirror being whole, which is #558.
  [#141](https://github.com/Gerrrt/HomeLab/issues/141) Navidrome has no gate
  but the same one.

## Saruman: the domain, then the SOC

Closes when Wazuh and Velociraptor report the six agents in.

- **[#414](https://github.com/Gerrrt/HomeLab/issues/414) Build the lab
  domain.** First: it is what the SOC, the range and the automation all point
  at. Sized by
  [ADR-0029](adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md),
  six guests on `large_data`; nothing to buy until the endpoints, which are
  the two keys on the buy table below.
  → [runbook](runbooks/build-the-lab-domain.md)
- **[#266](https://github.com/Gerrrt/HomeLab/issues/266) Wazuh and
  [#267](https://github.com/Gerrrt/HomeLab/issues/267) Velociraptor.** After
  #414: one decision
  ([ADR-0030](adr/0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)),
  `stacks/soc/` authored ahead of the guest, and an agentless Wazuh has
  nothing to report.
  [#439](https://github.com/Gerrrt/HomeLab/issues/439)'s removal procedure
  lands with Velociraptor, not after it;
  [#438](https://github.com/Gerrrt/HomeLab/issues/438)'s disposable stack
  follows `odin`. → [runbook](runbooks/build-the-soc-guest.md)
- **[#437](https://github.com/Gerrrt/HomeLab/issues/437) Zeek on a mirror
  port.** Gated on the switch, not the domain: the CRS326 arrives with
  mirroring disabled per ADR-0006, so this is a decision and #444 before it
  is a build.
- **[#485](https://github.com/Gerrrt/HomeLab/issues/485) PBS.**
  [ADR-0027](adr/0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md)'s
  trigger has fired — `smaug` answers, `erebor` is online — and its sync job
  was designed for a host TrueNAS is not. Waits on the re-read, and on a
  whole mirror to send to (#558).
- **[#538](https://github.com/Gerrrt/HomeLab/issues/538),
  [#529](https://github.com/Gerrrt/HomeLab/issues/529),
  [#562](https://github.com/Gerrrt/HomeLab/issues/562) and
  [#576](https://github.com/Gerrrt/HomeLab/issues/576)** are the host's own
  blind spots, with no order between them. #576 watches the Proxmox firewall
  that #566 turned on, so it is the one of the four that has already lost its
  excuse for waiting.

## automation

Closes on BloodHound running where nothing attacks it.

- **A chain, in this order:**
  [#440](https://github.com/Gerrrt/HomeLab/issues/440) Packer →
  [#445](https://github.com/Gerrrt/HomeLab/issues/445) OpenTofu →
  [#448](https://github.com/Gerrrt/HomeLab/issues/448) Ansible and ADR-0029's
  six guests from the pipeline →
  [#449](https://github.com/Gerrrt/HomeLab/issues/449) users and deliberate
  weaknesses and [#450](https://github.com/Gerrrt/HomeLab/issues/450) Sysmon
  and Pktmon → [#451](https://github.com/Gerrrt/HomeLab/issues/451)
  BloodHound, which closes the milestone. All of it runs from `phoenix`
  ([ADR-0043](adr/0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md),
  → [runbook](runbooks/build-the-jumpbox.md)).
- **[#446](https://github.com/Gerrrt/HomeLab/issues/446) The ISO store on
  `smaug`** wants the fifth inbound rule ADR-0016 did not write down, and is
  otherwise independent of the chain.

## last

Gated on the domain, on a household observation, or on something to publish.

- **[#421](https://github.com/Gerrrt/HomeLab/issues/421) Buy `ifrit` and build
  the range.** Gated on #414 and the SOC: an attack VM pointed at an
  uninstrumented estate teaches nothing. It is the last purchase on the
  estate's list, not the next.
  → [runbook](runbooks/build-the-playground.md)
- **[#447](https://github.com/Gerrrt/HomeLab/issues/447) A cloud relay** —
  only if there is ever something to publish; the day it exists it replaces
  the dynamic DNS record
  ([ADR-0044](adr/0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md)).
- **[#139](https://github.com/Gerrrt/HomeLab/issues/139) Plex** — only if a
  client on CasaBonita turns out to need it
  ([ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)),
  a test nobody has run.

## Tier extras

Beyond ADR-0008's nine: each needs its own decision before it is authored, and
none is in the order until one is taken.

## Everything still to buy

The one list, because purchases kept appearing one at a time in issues, ADRs
and runbooks until one box had been bought for two jobs
([ADR-0034](adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)).
**Nothing enters the table without a decision the operator made, and a PR that
implies a purchase edits this section in the same commit.** Parts on hand are
in [`hardware.md`](hardware.md); a part in transit is its issue's to track.
`smaug`'s memory and the off-estate drive both left this table on 2026-09-22
by that rule, bought rather than dropped
([#599](https://github.com/Gerrrt/HomeLab/issues/599),
[#455](https://github.com/Gerrrt/HomeLab/issues/455)) — and it
was bought to a different shape than the row described, which is in
[`hardware.md`](hardware.md) and in
[`changelog.md`](changelog.md) rather than here.

**Buy these, and the estate as decided is fully bought:**

| Item | For | Decided by | When it is needed |
| --- | --- | --- | --- |
| Two Windows 11 Pro keys | The lab domain's two endpoints; the four servers are free evaluations | [ADR-0029](adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md), [#414](https://github.com/Gerrrt/HomeLab/issues/414) | When the domain build reaches the endpoints, not before |

**One more, later, and it is the last:** `ifrit`, the range host — a quiet
SFF box, NVMe, two socketed DIMM slots with 32 GB fitted, one NIC
([ADR-0017](adr/0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md),
[#421](https://github.com/Gerrrt/HomeLab/issues/421)). Gated on the domain
being built; it is the last purchase on this list, not the next. 32 GB is a
spec the candidate machines do not meet as shipped — the SFF boxes in that
class ship with 16 GB in two slots — so a SO-DIMM kit is part of that purchase
and not a later contingency. The model, the CPU and the disk are chosen at the
till and recorded in [`hardware.md`](hardware.md) afterwards; nothing is named
here before it is bought.

**Only if a decision is taken, and none is pending** — these are not on the
list, and each names what would put it there:

- A dedicated firewall cold spare: deferred by ADR-0034 until the tier
  holding real data makes an hour of firewall downtime unacceptable. There is
  one ProDesk, not two — `trinity` is the tier's host *and* the firewall's
  spare hardware — and the reserved name `zion` belongs to the box this
  bullet would buy ([ADR-0038](adr/0038-name-the-nas-smaug-and-reserve-zion-for-the-box-that-does-not-exist.md)).
- A Zigbee or Z-Wave coordinator for Home Assistant: only if a device needs
  one, and nothing on Skids does today — Ring is cloud, Hue has its own
  bridge, the assistants are Wi-Fi ([#134](https://github.com/Gerrrt/HomeLab/issues/134)).
- **More** memory for `ifrit` than ADR-0017's 32 GB: only if 32 GB proves
  short. Reaching 32 GB is above, in the purchase itself.
- A Coral TPU and RTSP cameras: declined with Frigate
  ([ADR-0032](adr/0032-decline-frigate-while-the-cameras-are-ring.md)).
- Plex Pass: [ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
  builds Jellyfin alone and adds Plex only if a client on CasaBonita turns out
  to need it. Its headline feature is hardware transcoding, and the TS150's
  Quick Sync already gives Jellyfin that for nothing.
- A reachable address for the WireGuard endpoint, in either of its paid
  forms: [ADR-0044](adr/0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md)
  answers it with a free dynamic DNS record instead. A **static address** is
  not sold on the residential service the house buys and enters only if that
  service changes; a **VPS relay** is
  [#447](https://github.com/Gerrrt/HomeLab/issues/447)'s purchase, entered
  when there is something to publish.

**Never**, and the documents say so: anything to make `prometheus` or `oracle`
faster or bigger, and any disk or memory on account of Wazuh — ADR-0030 sizes
it to what `Saruman` has. A 2012 MacBook running the whole observability stack
is the point, not a problem to spend money on.

**The one exception, and it narrows this line rather than reversing it:** a
**consumable whose failure is a safety or availability event** is not an
upgrade. `prometheus`'s cell was that case and is replaced
([#454](https://github.com/Gerrrt/HomeLab/issues/454)); `oracle`'s is bought
and waits on the fit ([#531](https://github.com/Gerrrt/HomeLab/issues/531)).
Nothing else about either machine is.

## Considered and declined

The mirror of the roadmap, and recorded for the reason turned around: a
service rejected for good reasons with nothing written down is
indistinguishable from one nobody thought of. It gets proposed again, evaluated
again, and can be deployed on the second pass because the first pass left no
trace ([#150](https://github.com/Gerrrt/HomeLab/issues/150)).

These are declines, not bans. Each records what was weighed, so a later proposal
argues with the reasoning rather than restarting from nothing — and several of
them name the condition that would change the answer.

- **Nextcloud** — the obvious "one app for everything" answer, and declined
  because it overlaps three services already chosen: Immich
  ([#132](https://github.com/Gerrrt/HomeLab/issues/132)) for photos,
  Paperless-ngx ([#133](https://github.com/Gerrrt/HomeLab/issues/133)) for
  documents, and file sync. It is more surface and more upkeep than all three
  together, and its app ecosystem is a second, unpinned supply chain operating
  outside `compose.yaml` — the same objection that rules out Home Assistant
  add-ons in [#134](https://github.com/Gerrrt/HomeLab/issues/134). **If the want
  is file sync rather than a suite, Syncthing does that with no server-side
  application at all**, and would be the thing to evaluate instead.
- **The \*arr stack** — Sonarr, Radarr, Lidarr and the indexer and subtitle
  services around them. Five or more services, each holding indexer credentials
  and each with a standing outbound appetite, added to the tier
  [ADR-0008](adr/0008-place-services-by-data-trust.md) deliberately defined as
  *low* consequence. The media tier's whole justification is that its compromise
  costs a film night; this raises what is at stake there while adding the most
  moving parts of anything on the list. **Declined for now rather than
  permanently** — but it should be its own decision with its own reasoning, not
  a footnote to the NAS build.
- **YunoHost-class installers** — YunoHost, Tipi, HomelabOS, StartOS and
  similar. They own the compose file, the update path and often the reverse
  proxy, which conflicts with essentially everything this repository does on
  purpose: one compose stack per host
  ([ADR-0004](adr/0004-one-compose-stack-per-host.md)), every image pinned by
  tag **and** digest, configuration validated in CI, secrets rendered from SOPS
  at deploy time. Adopting one trades the properties that make this estate
  reproducible for a faster first install. Wrong trade here — and the trade, not
  the software, is the reason.
- **Guacamole** — a clientless browser-reachable RDP/VNC gateway. Convenient,
  and a larger concession on the management segment than SSH already is: it
  turns any browser session on Hicks into a potential path to every console in
  the estate, and it stores connection credentials to do it. The estate already
  has a KVM in U6 for physical console access. Declined. **The remote-access question it
  gestured at is answered differently** by
  [ADR-0042](adr/0042-terminate-the-remote-path-on-the-lab-and-route-it.md):
  WireGuard to the lab jumpbox, terminating on ImaginationLAN and reaching the
  lab only. That is not a softening of this decline — it stores no connection
  credentials at a gateway, it never touches Winterfell, and the boundary is
  the firewall's rather than an application's. Guacamole's objection was about
  the management segment, and nothing about ADR-0042 goes near it.
- **Frigate** — locally-processed object detection on camera streams, and the
  one service on the shortlist that would change the network's shape rather
  than its population: continuous RTSP from every camera through the `99 → 20`
  rule ADR-0008 authorised for Home Assistant's occasional control traffic, a
  clip archive that is the most sensitive data store in the house on the
  management segment, and a Coral or GPU the sensitive tier does not have.
  Declined by
  [ADR-0032](adr/0032-decline-frigate-while-the-cameras-are-ring.md) on a fact
  that comes before all four: every camera on Skids is a Ring device, and Ring
  exposes no local stream, so Frigate has nothing to consume. Adopting it is a
  camera replacement first, which is its own decision. **Reopened by RTSP
  cameras, an accelerator, and a separate row in ADR-0008's table for the
  continuous rule** — all three, each decided on its own
  ([#149](https://github.com/Gerrrt/HomeLab/issues/149)).
- **Proxmox clustering** — joining `Saruman` and `ifrit` into one cluster once
  [#421](https://github.com/Gerrrt/HomeLab/issues/421) makes them two Proxmox
  hosts on VLAN 30: one pane of glass, guest migration, shared storage. The
  first entry here that is a capability rather than a service, and declined by
  [ADR-0039](adr/0039-decline-proxmox-clustering-while-ifrit-is-the-range.md)
  because a cluster is one `/etc/pve`, one realm and one quorum across exactly
  the boundary ADR-0007 draws — root on the attacker's host becomes root on the
  estate's — and cannot be built without the second NIC or VLAN-aware bridge
  ADR-0014 names as grounds to reopen it, on a host that is off between
  sessions by design and would take the estate's hypervisor's quorum down with
  it. **Reopened by a third host that is neither attacker nor defended estate,
  a live-migration need that snapshot-and-rebuild does not serve, or `ifrit`
  ceasing to hold attack tooling** — each its own decision
  ([#443](https://github.com/Gerrrt/HomeLab/issues/443)).
- **Authelia / Authentik** — **already decided, and listed only so the next
  shortlist does not present it as new.** ADR-0008 defers SSO knowingly for two
  users with no external access;
  [ADR-0022](adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)
  gives that deferral an expiry, which is what
  [#103](https://github.com/Gerrrt/HomeLab/issues/103) closed on. An identity
  provider is also the only route to a second factor for Grafana, Immich and
  AdGuard Home, none of which can carry one themselves — so this decline has a
  known end, unlike the others here.

## Done

What closed, when, and what it found is in [`changelog.md`](changelog.md),
newest first. An entry leaves this file on the day its issue closes and goes
there with the date.
