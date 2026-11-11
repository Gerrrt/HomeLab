# Roadmap

**The tracking lives in [Issues](https://github.com/Gerrrt/HomeLab/issues).**
This file is the shape of the work — what is outstanding, what gates it, and
why it is in this order. Whether a thing is started, blocked or done is on its
issue. What happened, and what it found, is in
[`changelog.md`](changelog.md), dated. Two places holding the same checkbox is
how a checkbox stops being true, and for a month this file was the second
place — [#577](https://github.com/Gerrrt/HomeLab/issues/577) moved the history
out.

The order is the five open
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
   — first because nothing gates them; most wait on an upstream release.
2. [**trinity**](https://github.com/Gerrrt/HomeLab/milestone/2) — the host
   is built and serving; what is left is its gates, and the off-estate copy.
3. [**Saruman: the domain, then the SOC**](https://github.com/Gerrrt/HomeLab/milestone/3)
   — one proof left, the lab's second key.
4. [**automation**](https://github.com/Gerrrt/HomeLab/milestone/5) — the
   pipeline is built; what is left is using it, as exercises.
5. [**last**](https://github.com/Gerrrt/HomeLab/milestone/6) — gated on the
   domain, on a household observation, or on something to publish.

## Nothing blocks these

Closes when it is empty.

- **[#574](https://github.com/Gerrrt/HomeLab/issues/574) Shut down on the
  UPS's signal.** Decided by
  [ADR-0049](adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md).
  Steps 0–4 were built on 2026-09-23: NUT on `morpheus`, its rules, and
  `Saruman` and `smaug` subscribed. The sequence is armed and not proved.
  Since the rack move,
  [ADR-0107](adr/0107-subscribe-trinity-to-the-ups-and-bound-saruman-s-guest-stop.md)
  adds `trinity` as a third subscriber and caps `Saruman`'s ordered guests at
  `down=90`, and neither is applied yet. The gate is a rack visit. It reads
  the outlet groups, applies step 4b and steps 3.6 to 3.8, proves the order
  with `upsmon -c fsd`, and pulls the mains once to replace the card's
  47-minute claim with a number.
  → [runbook](runbooks/shut-down-on-the-ups.md)
- **[#1226](https://github.com/Gerrrt/HomeLab/issues/1226) The HomePods in
  Home Assistant, for control.** Decided by
  [ADR-0099](adr/0099-control-the-homepods-from-home-assistant-and-leave-their-audio-out.md).
  Gate: `pyatv_scan_guard` deployed. It patches pyatv 0.18.0's scan by
  address, which cannot find a HomePod
  ([postlund/pyatv#2929](https://github.com/postlund/pyatv/issues/2929)),
  until Home Assistant pins a pyatv with the fix
  ([ADR-0113](adr/0113-patch-pyatvs-unicast-scan-locally-until-upstream-ships-a-fix.md)).
  The reservations and the rules on `morpheus` are in force. Left: adding each
  HomePod by address from `trinity`, the Home app's speaker-access setting
  that lets it connect, the HomePods' ports read from the firewall log while
  pairing, and the lines in `network.md` and `security.md` that say Home
  Assistant has not added them yet.
- **[#1240](https://github.com/Gerrrt/HomeLab/issues/1240) Retire
  `ring_push_guard`.** Decided by
  [ADR-0101](adr/0101-patch-ring-doorbells-push-parser-locally-until-upstream-ships-a-fix.md).
  Gate: a Home Assistant release that pins a `ring_doorbell` with the
  missing-`ding.id` fix (python-ring-doorbell#540 or #556). Until then the
  patch stays, and the issue tracks it.
- **[#1383](https://github.com/Gerrrt/HomeLab/issues/1383) Retire
  `ring_push_guard`'s firebase_messaging patch.** Decided by
  [ADR-0110](adr/0110-patch-firebase-messagings-header-parsing-locally-until-upstream-ships-a-fix.md).
  Gate: a Home Assistant release that pulls a `firebase-messaging` that reads
  Web Push headers by name (sdb9696/firebase-messaging#43 or #46). Whichever
  of this and #1240 retires last takes the component and its package with it.
- **[#1393](https://github.com/Gerrrt/HomeLab/issues/1393) Retire
  `pyatv_scan_guard`.** Decided by
  [ADR-0113](adr/0113-patch-pyatvs-unicast-scan-locally-until-upstream-ships-a-fix.md).
  Gate: a Home Assistant release that pins a pyatv with the unicast-scan fix
  ([postlund/pyatv#2930](https://github.com/postlund/pyatv/pull/2930) or an
  equivalent). The component and its package go then. The mount stays while
  `ring_push_guard` does.

The rest of the milestone has no order between its issues.

## trinity

Closes when #404 and #132 close, and #455 has its holder.

- **[#404](https://github.com/Gerrrt/HomeLab/issues/404) Build the tier's
  host.** **Built and deployed 2026-09-28**
  ([ADR-0034](adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md),
  → [runbook](runbooks/build-the-sensitive-tier-host.md)). What is left:
  - the DNS failure test, which proves `AdGuardNotAnswering` pages. #135
    closed on 2026-09-28 without a record of it, so it is owed here
    (→ [runbook](runbooks/forward-dns-to-adguard.md#4-stop-adguard-on-purpose-and-time-the-page));
  - the step 10 gate: the second age recipient, the off-estate copy
    (#455), ADR-0022's identity-provider record and ADR-0023's
    *Independent* test. Until #455 exists, the originals' only copy beyond
    the USB disk is the nightly one to `oracle`, in the same room
    ([ADR-0064](adr/0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)).
- **[#132](https://github.com/Gerrrt/HomeLab/issues/132) Immich**, the one of
  ADR-0008's nine still open; the issue says what is left. Its restore is
  rehearsed (→ [runbook](runbooks/restore-the-sensitive-tier.md#restore-immich)).
- **[#455](https://github.com/Gerrrt/HomeLab/issues/455) The off-estate copy.**
  **The drive is here.** It was bought 2026-09-22 and arrived 2026-09-29
  ([`hardware.md`](hardware.md)). **The key is decided**: on 2026-10-01
  [ADR-0073](adr/0073-carry-the-household-copy-on-a-drive-the-holder-keeps.md)
  settled the first of
  [ADR-0023](adr/0023-keep-the-household-recovery-path-outside-the-estate.md)'s
  two conditions. The copy is encrypted to the household holder's key, with
  [ADR-0024](adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)'s
  second recipient as a fallback. The keys are kept in
  `stacks/sensitive/household.recipients` and not in a sops rule. The drive
  holds age archives on exFAT. **The copy is built**: `make household-copy`
  carries it, `HouseholdCopyStale` watches it, and the holder's page is
  [`open-the-household-copy.md`](runbooks/open-the-household-copy.md).
  The drive was formatted and rehearsed on 2026-10-01.
  **What is left is a person**: choosing the
  holder, and the holder opening the copy once **from their own device,
  without the operator present**. Both were meant to come before the tier
  held real data, and they did not.
  [ADR-0022](adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)'s
  first trigger, the first real photo, fired on 2026-09-28. Until this lands,
  [ADR-0064](adr/0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)'s
  nightly copy to `oracle` stands in for the library, off-host and not
  off-estate. When this lands, it supersedes ADR-0064. **It does not carry
  Memos yet.** `make household-copy` writes Immich's library and a
  Paperless export; `memos-data`, which holds real notes since 2026-10-22,
  has only the nightly volume set on `oracle`. Adding it to the copy is
  part of this, and Memos' *Durable* row is not met before it is.

## Saruman: the domain, then the SOC

Closes when it is empty. Both things its name names are done. The domain was
built by hand on 2026-09-24 and 25, and
[#414](https://github.com/Gerrrt/HomeLab/issues/414) closed on 2026-10-02 with
its authentication generator running and §10 read from Hicks. The SOC followed:
Wazuh and Velociraptor reported the six agents in on 2026-09-27.

- **[#671](https://github.com/Gerrrt/HomeLab/issues/671) Prove the lab's
  second key.** `secrets/lab.sops.yaml` is encrypted to the offline technical
  second as well as `alexander`'s key since 2026-10-07. What remains is
  `make secrets-verify-backup STACK=lab KEY=…` with the offline copy.

## automation

Closes when #449 does. The pipeline it names is built: Packer, OpenTofu,
Ansible, Sysmon and BloodHound each closed with its issue, and the record is in
[`changelog.md`](changelog.md).

- **[#449](https://github.com/Gerrrt/HomeLab/issues/449) Users and deliberate
  weaknesses.** Every weakness role exists, one tag each, and the loop ran
  config-only on 2026-10-08. What is left is to use them: apply one weakness at
  a time, find its path in BloodHound, exploit it from `ragnarok`, and record
  what Wazuh and Zeek saw as an exercise in [`exercises/`](exercises/). It
  closes on the first five exercises, one per weakness, each with a detection
  outcome. → [runbook](runbooks/build-the-lab-domain.md)

## last

Gated on the domain, on a household observation, or on something to publish.

- **[#421](https://github.com/Gerrrt/HomeLab/issues/421) Build the range on
  `gandalf`.** Gated on #414 and the SOC: an attack VM pointed at an
  uninstrumented estate teaches nothing. Both are met. The runbook's §1–§5
  are behind it: the host, its bridges, `Saruman` at `.20`, the closed
  management plane, and the attack VM `ragnarok` on template 902. So are §8
  and §9, which ran before any target, because the leak proof must run
  before any vulnerable image is on the machine, and then §6, the targets.
  Next, Sliver goes on `ragnarok`, before the first exercise.
  The name is
  [ADR-0106](adr/0106-name-the-range-host-gandalf-and-leave-ifrit-to-its-disabled-amt.md)'s.
  → [runbook](runbooks/build-the-playground.md)
- **[#447](https://github.com/Gerrrt/HomeLab/issues/447) A cloud relay** —
  only if there is ever something to publish; the day it exists it replaces
  the dynamic DNS record
  ([ADR-0044](adr/0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md)).

## Tier extras

Empty: its five issues are closed, and the milestone with them. The heading
stays because [ADR-0063](adr/0063-add-stirling-pdf-to-the-sensitive-tier-and-keep-its-documents-in-memory.md),
a record, links here. A new extra starts with its own decision, in
*Nothing blocks these*.

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
The two Windows 11 Pro keys left it on 2026-09-25 by the same rule. They were
bought and activated on the lab domain's two endpoints, `carbuncle` and
`siren` ([ADR-0029](adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md),
[#414](https://github.com/Gerrrt/HomeLab/issues/414)). The replacement for
`smaug`'s faulted Exos never entered it. The eBay return came back as a
refund rather than a new drive, and the drive was bought outright on
2026-09-24, the day the choice was known
([#558](https://github.com/Gerrrt/HomeLab/issues/558)). It is in
[`hardware.md`](hardware.md).

**Buy these, and the estate as decided is fully bought.** The table was empty
from 2026-09-25 until `gandalf` was bought on 2026-10-05, short of the spec its
ADR set. The RAM and the range disk it still needed left on 2026-11-07,
fitted and read back from the installed host
([#421](https://github.com/Gerrrt/HomeLab/issues/421)). So did the factory
patch cable for the WAN, fitted on 2026-11-01
([#923](https://github.com/Gerrrt/HomeLab/issues/923)); it fixed the
hand-crimped plug, and the rest of that fault was the XB7's 2.5G port,
recorded in the [changelog](changelog.md). On 2026-10-13 the move
into the 32U rack ([#919](https://github.com/Gerrrt/HomeLab/issues/919)) put
its parts here, which had been listed only in its runbook's §0.1, and
`Saruman`'s memory joined them. The six rows the move needed (`smaug`'s
shelf, the three 1U shelves, the cable manager, the vented blank and both
sets of rails) left on 2026-11-06, bought and racked; they are in
[`hardware.md`](hardware.md#rack). The accessories below never gated the
move and stay until they are bought or dropped.

| Item | For | Decided by | When it is needed |
| --- | --- | --- | --- |
| APC AP9335T temperature probe, for the UPS's AP9641 card | Rack ambient at U1–U2, where the heavy iron is; the existing SNMP job polls the card, so a generator change follows the purchase | The operator, 2026-10-16 | Any time |
| Switched, SNMP-managed 1U PDU, eight outlets or more: APC AP7900B class | Remote power-cycling for the four hosts without a BMC: `morpheus`, `trinity`, `gandalf`, `smaug`. It replaces the strip at U4; the screen's brick and the KVM move to the UPS's own outlets, so eight outlets suffice | The operator, 2026-10-16. **Its segment and hardening are an ADR before it is cabled**, as [ADR-0036](adr/0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md) was for the iLO and the UPS card | Now that the #919 move is done: a management-plane device, not a move part |
| USB-to-RJ45 serial console cable | The CRS326's console port: the way back in when its UI is unreachable, which is the swap runbook's rollback case | The operator, 2026-10-16 | Any time; the #919 move is done |
| Label maker with flag tape, or self-laminating wrap labels | Both ends of every lead, and the panel and switch ports: the physical half of the port map the swap runbook captures | The operator, 2026-10-16 | Any time; the #919 move is done |
| Stick-on LED rack light, USB or battery | The top of the frame, lighting the bottom where the UPS, the DL360 and `smaug` sit | The operator, 2026-10-16 | Any time |
| Bonding strap, frame to the UPS's ground | The frame's grounding screw; it shipped without a strap | The operator, 2026-10-16 | Any time; the #919 move is done |
| Cable tester, the basic kind | The in-wall runs to the panel, never tested; the September fault was a plug ([#923](https://github.com/Gerrrt/HomeLab/issues/923)) | The operator, 2026-10-16 | Any time; the #919 move is done |
| Adhesive D-rings or a short vertical finger duct | The power-side rear post: the move runbook keeps power and data apart, and the horizontal manager serves the data side only | The operator, 2026-10-16 | Any time; the #919 move is done |
| Levelling feet for the frame | Only if the floor is uneven: the frame wobbled until its screws were torqued | The operator, 2026-10-16 | Any time; the #919 move is done |
| Tenkeyless keyboard and a mouse | The 10.8" drawer: a full-size keyboard with a trackpad does not fit under its lip, per its reviewers | The operator, 2026-10-16 | Any time; the #919 move is done |
| 8 × 16 GB DDR4 RDIMM, dual-rank, matched to a fitted stick's label (2Rx4 or 2Rx8, PC4-2400) | `Saruman`, 128 GB to 256 GB, one more per channel on both CPUs | The operator, 2026-10-13: headroom | The next time the DL360 is out of the rack: not fitted in the #919 move |

**The last one, bought 2026-10-05:** `gandalf`, the range host — a quiet
SFF box with flash storage, two socketed DIMM slots with 32 GB fitted, one NIC
([ADR-0017](adr/0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md),
[#421](https://github.com/Gerrrt/HomeLab/issues/421)). The box is a
refurbished ThinkCentre M80q, and it arrived on 2026-10-14. It shipped with
8 GB and a 256 GB SSD. The 32 GB and the range disk were fitted before its
install on 2026-11-07, and the node is named `gandalf`
([ADR-0106](adr/0106-name-the-range-host-gandalf-and-leave-ifrit-to-its-disabled-amt.md)).
[`hardware.md`](hardware.md) records the parts as fitted.

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
- **More** memory for `gandalf` than ADR-0017's 32 GB: only if 32 GB proves
  short. Reaching 32 GB is above, in the purchase itself.
- A Coral TPU and RTSP cameras: declined with Frigate
  ([ADR-0032](adr/0032-decline-frigate-while-the-cameras-are-ring.md)).
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
([#454](https://github.com/Gerrrt/HomeLab/issues/454)); so is `oracle`'s,
fitted 2026-09-29 ([#531](https://github.com/Gerrrt/HomeLab/issues/531)).
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
  has a KVM in U23 for physical console access. Declined. **The remote-access question it
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
- **Plex** — the media server the household already knows, with polished
  clients, and ADR-0008 listed it beside Jellyfin for that reason. It is also
  the one proprietary service on the shortlist: clients authenticate through
  `plex.tv` even on a local network, nobody outside the vendor can read the
  image that digest pinning fixes, and features have moved behind a
  subscription before. ADR-0016 deferred it against one test, whether any
  screen on CasaBonita lacks a working Jellyfin client, and the test was run by
  2026-09-28: the LG OLED, a console, and the phones and tablets all play from
  Jellyfin, and the Xumo box is not used for the library. Declined by
  [ADR-0056](adr/0056-decline-plex-because-every-screen-on-casabonita-plays-jellyfin.md). **Reopened by a screen the household uses for
  library media that has no working Jellyfin client**, with Remote Access off
  even then ([#139](https://github.com/Gerrrt/HomeLab/issues/139)).
- **HomeBox** — a home inventory with items, locations, warranties and receipts
  as attachments. It was proposed for the sensitive tier as the place for the
  serials `hardware.md` withheld. By the time it was argued, `hardware.md`
  carried the serials and warranty dates itself. Paperless-ngx already held the
  receipts and manuals, and a licence key is Vaultwarden's. What remained was a
  list of household objects, which does not earn a place on the segment
  ADR-0008 calls its real cost, and which would be a second inventory that
  drifts from the first. Declined by
  [ADR-0058](adr/0058-decline-homebox-because-hardware-md-and-paperless-already-hold-its-records.md).
  **Reopened by a household need to track non-infrastructure possessions that
  Paperless's tags cannot meet**, with the proposal saying what leaves
  `hardware.md` so there is still one inventory
  ([#148](https://github.com/Gerrrt/HomeLab/issues/148)).
- **Proxmox clustering** — joining `Saruman` and `gandalf` into one cluster once
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
  a live-migration need that snapshot-and-rebuild does not serve, or `gandalf`
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
  known end, unlike the others here. **Pocket ID**, the lighter passkey-only
  provider, has been weighed and changes nothing until a reopen condition
  fires. It is the first candidate when one does
  ([#860](https://github.com/Gerrrt/HomeLab/issues/860), the note on
  [ADR-0075](adr/0075-re-accept-the-sso-deferral-once-the-tier-holds-real-data.md)).

## Done

What closed, when, and what it found is in [`changelog.md`](changelog.md),
newest first. An entry leaves this file on the day its issue closes and goes
there with the date.
