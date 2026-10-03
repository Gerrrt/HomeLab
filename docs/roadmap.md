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
   — side by side, with no order between them. The domain, which everything
   else on `Saruman` points at, is built and closed; the NAS's first issue,
   the one-disk mirror, is done.
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
  The switch has been in hand since 2026-09-23, without a power adapter.
  Gate: the 24HPOW landing, and a rack window outside working hours — `neo`
  carries every VLAN, so the swap cannot share the day with anyone working
  on them. → [runbook](runbooks/swap-the-switch.md)
- **[#84](https://github.com/Gerrrt/HomeLab/issues/84) Retire the MokerLink's
  previous SNMP community.** Closes with #444: the row cannot be verified,
  so it is retired by the hardware leaving, not by a measurement.
  → [runbook](runbooks/rotate-snmp-community.md#the-mokerlink-switch-overwrite-the-row)
- **[#574](https://github.com/Gerrrt/HomeLab/issues/574) Shut down on the
  UPS's signal.** Decided by
  [ADR-0049](adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md).
  Steps 0–4 were built on 2026-09-23: NUT on `morpheus`, its rules, and
  `Saruman` and `smaug` subscribed. The sequence is armed and not proved. The
  gate is a rack visit, which proves the order with `upsmon -c fsd` and pulls
  the mains once to replace the card's 47-minute claim with a number.
  Shares a window with #444 if its parts have landed.
  → [runbook](runbooks/shut-down-on-the-ups.md)
- **[#182](https://github.com/Gerrrt/HomeLab/issues/182) Authenticate the
  Prometheus and Loki ingest ports.** Reopened 2026-09-26: #319 closed it by
  accident. Authored 2026-09-30:
  [ADR-0067](adr/0067-authenticate-the-ingest-ports-with-a-token-per-client.md)'s
  ingest proxy, a token per agent and a reader token. Not yet deployed. The
  order is the tokens into both SOPS files, the three agents and `trinity`
  redeployed carrying them, then `make up` on the monitoring host. The issue
  stays open until `deploy-agent.sh` has shown fresh data from all three agents
  and the refusal probes are green.

The rest of the milestone has no order between its issues.

## trinity

Closes when the nine services serve from `trinity` and the firewall restore
has been rehearsed on it.

- **[#92](https://github.com/Gerrrt/HomeLab/issues/92) Rehearse the firewall
  restore — done 2026-09-27.** The machine was proved on 2026-09-26, inside
  the return window that closed 2026-10-08 (#674). The rehearsal restored
  `config-20260926T043704Z` — taken from `oracle`, schema `24.6`, 112 rules —
  onto pfSense CE 2.9.0 on `trinity` in 42 minutes, and it booted with **no
  interface-assignment prompt**: WAN on `em0`, LAN on `igc0`, all six VLANs,
  112 rules, the four tripwires, the twelve `Tunnel_Peers` rules and six Kea
  scopes, and a laptop tagged into VLAN 99 leased `10.0.99.100`. Three things
  asked questions the runbook had not answered — Secure Boot (and HP's
  four-digit confirmation code), a kernel panic from the undisclosed
  Wireless-AC 9560 under `iwm` (fixed with `hint.iwm.0.disabled`), and an
  installer that needs the internet — and all three are now in §3. The box
  went to #404 with the I226 card still fitted. It was recorded as in the
  drawer until the build found it in the slot on 2026-09-28, and it stays
  there, unconfigured, for the day `trinity` has to be the firewall.
  → [runbook](runbooks/restore-the-firewall.md#rehearse-the-restore-on-the-spare)
- **[#404](https://github.com/Gerrrt/HomeLab/issues/404) Build the tier's
  host.** **Built and deployed 2026-09-28**
  ([ADR-0034](adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md),
  → [runbook](runbooks/build-the-sensitive-tier-host.md)). What is left:
  - the DNS failure test, which proves `AdGuardNotAnswering` pages (and
    closes [#135](https://github.com/Gerrrt/HomeLab/issues/135));
  - the step 10 gate, which the first real photos passed on 2026-09-28
    while most of it was still open: the second age recipient, the
    off-estate copy, ADR-0022's identity-provider record and ADR-0023's
    *Independent* test. The Immich restore rehearsal is done
    ([#132](https://github.com/Gerrrt/HomeLab/issues/132), →
    [runbook](runbooks/restore-the-sensitive-tier.md#restore-immich)). Until
    [#455](https://github.com/Gerrrt/HomeLab/issues/455) exists, the
    originals' only copy beyond the USB disk is the nightly one to `oracle`,
    in the same room
    ([ADR-0064](adr/0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)).

  [#533](https://github.com/Gerrrt/HomeLab/issues/533)'s converge timer is
  authored and installs report-only; it closes when `trinity` applies and a
  Dependabot bump to `stacks/sensitive` lands with nobody at a shell
  (→ [runbook](runbooks/converge-the-host.md#on-trinity)).
  [#534](https://github.com/Gerrrt/HomeLab/issues/534)'s CI re-check is
  already done (#646).
- **The nine services**, each authored ahead of the hardware and each open
  until it serves from the host:
  [#129](https://github.com/Gerrrt/HomeLab/issues/129) Caddy and
  [#130](https://github.com/Gerrrt/HomeLab/issues/130) step-ca first, because
  everything else sits behind the one and is issued by the other
  ([ADR-0037](adr/0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md)
  — → [runbook](runbooks/build-the-tier-ca.md)); then
  [#135](https://github.com/Gerrrt/HomeLab/issues/135) AdGuard Home, serving
  since 2026-09-28 with `morpheus` forwarding to it alone
  ([ADR-0010](adr/0010-keep-the-resolver-on-the-gateway.md),
  [ADR-0055](adr/0055-forward-to-adguard-alone.md)) and both probes live, open
  only for the failure test (→ [runbook](runbooks/forward-dns-to-adguard.md#4-stop-adguard-on-purpose-and-time-the-page));
  [#131](https://github.com/Gerrrt/HomeLab/issues/131) Vaultwarden;
  [#132](https://github.com/Gerrrt/HomeLab/issues/132) Immich;
  [#133](https://github.com/Gerrrt/HomeLab/issues/133) Paperless-ngx;
  [#134](https://github.com/Gerrrt/HomeLab/issues/134) Home Assistant
  ([ADR-0035](adr/0035-scope-the-99-to-20-rule-to-the-hue-bridge.md));
  [#136](https://github.com/Gerrrt/HomeLab/issues/136) ntfy — authored, with
  the decision taken both ways at once: the in-house topics replace ntfy.sh for
  all three real channels, and `urgent` and `security` page ntfy.sh as well,
  because a phone away from home cannot reach the tier. The deploy and the
  observed end-to-end check remain
  (→ [runbook](runbooks/verify-the-alert-path.md#cutting-over-to-the-in-house-ntfy));
  and [#137](https://github.com/Gerrrt/HomeLab/issues/137) Homepage, authored
  on 2026-09-28 against the running tier: `home.matrix.elysium`, a directory
  and not a status page, with live numbers only where a read-only token can
  read them (Immich, Paperless-ngx) or none is needed (Prometheus), and its
  widget path measured through Caddy with placeholder tokens before the real
  ones exist. Deployed and reading real numbers since; on 2026-09-29 it took
  Tokyo Night, groups by VLAN, and four more tiles read from Prometheus (UPS,
  firewall, iLO, NAS) with no new rule or credential. The restore path is
  rehearsed already:
  → [runbook](runbooks/restore-the-sensitive-tier.md).
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
  off-estate. When this lands, it supersedes ADR-0064.

## NAS

Closes when a workstation can mount the share. Its other condition, the
faulted Exos replaced and the mirror resilvered, is met and is in
[`changelog.md`](changelog.md).

## Saruman: the domain, then the SOC

Closes when it is empty. Both things its name names are done. The domain was
built by hand on 2026-09-24 and 25, and
[#414](https://github.com/Gerrrt/HomeLab/issues/414) closed on 2026-10-02 with
its authentication generator running and §10 read from Hicks. The SOC followed:
Wazuh and Velociraptor reported the six agents in on 2026-09-27.

- **[#671](https://github.com/Gerrrt/HomeLab/issues/671) A second way into
  the lab's secrets.** `secrets/lab.sops.yaml` is in git since #667, and
  encrypted to one key that lives only on `alexander`; a second recipient or
  a proved off-box copy, run on that guest.
- **[#485](https://github.com/Gerrrt/HomeLab/issues/485) PBS.**
  [ADR-0027](adr/0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md)'s
  trigger has fired — `smaug` answers, `erebor` is online — and its sync job
  was designed for a host TrueNAS is not. **Re-read and decided 2026-09-23:**
  [ADR-0053](adr/0053-run-pbs-on-saruman-with-its-datastore-on-smaug-over-nfs.md) runs PBS on `Saruman` as `golem`
  (`10.0.30.80`) with its datastore on `erebor/pbs` over NFSv4, and TrueNAS
  snapshots as the copy it cannot prune. What is left is the build: the
  guest, the dataset and share, the `2049` pass on `morpheus`, and a verify
  job the lab can see.
  → [runbook](runbooks/build-the-backup-guest.md)
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
  [#440](https://github.com/Gerrrt/HomeLab/issues/440) Packer (written,
  [ADR-0074](adr/0074-build-the-lab-templates-with-packer-from-phoenix.md);
  901 built twice and usable, 912 built and to be rebuilt with the
  `SetupComplete.cmd` fix, 911 not yet built,
  → [runbook](runbooks/build-the-lab-templates.md); Kali's
  template waits for `ifrit`, [#790](https://github.com/Gerrrt/HomeLab/issues/790)) →
  [#445](https://github.com/Gerrrt/HomeLab/issues/445) OpenTofu (done
  2026-10-03,
  [ADR-0076](adr/0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md):
  state encrypted, escrowed, and both proofs run against a real apply,
  → [runbook](runbooks/provision-lab-guests.md)) →
  [#448](https://github.com/Gerrrt/HomeLab/issues/448) Ansible and ADR-0029's
  six guests from the pipeline (written,
  [ADR-0077](adr/0077-configure-the-lab-domain-with-ansible-from-phoenix.md),
  → [`ansible/`](../ansible/README.md); closes on a `tofu destroy` and rebuild,
  so it waits for the six to be declared in `tofu/` with pinned MACs, and for
  #440's first build) →
  [#449](https://github.com/Gerrrt/HomeLab/issues/449) users and deliberate
  weaknesses and [#450](https://github.com/Gerrrt/HomeLab/issues/450) Sysmon
  and Pktmon → [#451](https://github.com/Gerrrt/HomeLab/issues/451)
  BloodHound, which closes the milestone. All of it runs from `phoenix`
  ([ADR-0043](adr/0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md),
  → [runbook](runbooks/build-the-jumpbox.md)).
  **#440's templates read their installers from `smaug-iso`**, the ISO store
  [ADR-0072](adr/0072-put-the-iso-store-on-smaug-over-nfs-to-saruman-alone.md)
  put on `erebor/iso`. Every file there is hashed daily on `Saruman` against
  the list in `scripts/collect-iso-store-state.sh`, and `IsoChecksumMismatch`
  pages if one changes, because the export trusts an address and Packer does
  not check an ISO it is handed from storage. Copying the installers there,
  listing their hashes and installing the check is
  [`build-the-lab-templates.md`](runbooks/build-the-lab-templates.md) §2b.

## last

Gated on the domain, on a household observation, or on something to publish.

- **[#421](https://github.com/Gerrrt/HomeLab/issues/421) Buy `ifrit` and build
  the range.** Gated on #414 and the SOC: an attack VM pointed at an
  uninstrumented estate teaches nothing. Both are met — the domain built
  2026-09-25, #266 and #267 closed 2026-09-27 — so nothing gates the purchase;
  a shortlist is on the issue. It is still the last purchase on the estate's
  list.
  → [runbook](runbooks/build-the-playground.md)
- **[#447](https://github.com/Gerrrt/HomeLab/issues/447) A cloud relay** —
  only if there is ever something to publish; the day it exists it replaces
  the dynamic DNS record
  ([ADR-0044](adr/0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md)).

## Tier extras

Beyond ADR-0008's nine: each needs its own decision before it is authored, and
none is in the order until one is taken.

- **[#147](https://github.com/Gerrrt/HomeLab/issues/147) Miniflux** — decided by [ADR-0057](adr/0057-add-miniflux-to-the-sensitive-tier-with-its-fetcher-kept-off-winterfell.md), deployed on `trinity` 2026-09-29.
  What remains is committing the encrypted `secrets/sensitive.sops.yaml`
  that carries its two keys, and seeing `miniflux-db-data` in a nightly set.
- **[#145](https://github.com/Gerrrt/HomeLab/issues/145) Memos** — decided by
  [ADR-0059](adr/0059-add-memos-to-the-sensitive-tier-for-notes-and-keep-documentation-in-docs.md)
  and deployed on `trinity` 2026-09-29, and reachable from Hicks by name the
  same day. The admin registered and closed registration on 2026-10-02.
  Nothing is left; #145 closes with this. It holds no real notes until
  ADR-0023's *Durable* condition is met, which is the tier's condition and
  not this issue's.
- **[#146](https://github.com/Gerrrt/HomeLab/issues/146) Mealie, as
  `recipes.matrix.elysium`.** Decided by
  [ADR-0060](adr/0060-add-mealie-to-the-sensitive-tier-as-recipes.md) and
  **deployed on `trinity` 2026-09-29**. It is the one service here meant for
  the household to open rather than to benefit from. It uses no new firewall
  rule and no SOPS secret, and it has no second factor, which is named
  alongside Immich and AdGuard. The default admin was renamed and
  re-passworded the same day. Nothing is left.
- **[#144](https://github.com/Gerrrt/HomeLab/issues/144) linkding** — decided by [ADR-0061](adr/0061-add-linkding-to-the-sensitive-tier-behind-one-factor.md) and authored in `stacks/sensitive`.
  **Deployed on `trinity` 2026-09-29**, with its host override, and the
  operator's first login with the superuser password from SOPS is done.
  Nothing is left.
- **[#143](https://github.com/Gerrrt/HomeLab/issues/143) Stirling-PDF** is
  **deployed on `trinity` 2026-09-29** ([ADR-0063](adr/0063-add-stirling-pdf-to-the-sensitive-tier-and-keep-its-documents-in-memory.md)): behind Caddy at
  `pdf.matrix.elysium`, login from SOPS, and its documents held on a tmpfs so
  none reaches a disk. The `pdf` override on `morpheus` is in, and TOTP is
  enrolled on the admin. Nothing is left; #143 closes with this.

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

**Buy these, and the estate as decided is fully bought.** The table is empty
as of 2026-09-25. It is kept so that the next decided purchase has somewhere
to go:

| Item | For | Decided by | When it is needed |
| --- | --- | --- | --- |

**One more, later, and it is the last:** `ifrit`, the range host — a quiet
SFF box, NVMe, two socketed DIMM slots with 32 GB fitted, one NIC
([ADR-0017](adr/0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md),
[#421](https://github.com/Gerrrt/HomeLab/issues/421)). Gated on the domain
and the SOC, and both are built (#266 and #267 closed 2026-09-27), so nothing
gates it now; it is still the last purchase on this list. 32 GB is a
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
