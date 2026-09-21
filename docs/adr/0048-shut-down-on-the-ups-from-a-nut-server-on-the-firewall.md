# ADR-0048: Shut down on the UPS's signal from a NUT server on the firewall, and scope its listener rather than open a segment

**Status:** Accepted · 2026-09 · decides the question
[#574](https://github.com/Gerrrt/HomeLab/issues/574) asked, and records the
power source [#413](https://github.com/Gerrrt/HomeLab/issues/413) owed
`hardware.md`

## Context

`mjolnir` has had a proven pack since 2026-08-28
([#93](https://github.com/Gerrrt/HomeLab/issues/93)), tests it every fortnight
and is watched doing so ([#249](https://github.com/Gerrrt/HomeLab/issues/249)),
and the shelf switch that carries the laptops has been on its power since
2026-09-08 ([#110](https://github.com/Gerrrt/HomeLab/issues/110)). Every one of
those closed the question "does the rack stay up through a cut". None of them
asked the question a UPS exists for, which is what happens when the cut
outlasts the pack — and the answer, read on 2026-09-20, is that **nothing in
this estate subscribes to the card for anything but metrics.** No `apcupsd`,
no NUT, no `upsmon`, no TrueNAS UPS service, in any document, any stack or any
script. A mains cut longer than the pack is a hard stop of every host on the
PDU, arrived at about forty minutes later than it would have been with no
pack at all.

Read live the same day, so the decision is against numbers rather than a
picture: the load is 21 % of a Smart-UPS X 1500 (26 % at its seven-day peak)
— the model, read off the card as `upsIdentModel`, appears in no document
before this one — the card claims 47 minutes of runtime (40 at its seven-day floor), charge
reads 100, float voltage 546, the pack 26 °C, and the last self-test passed on
2026-09-11. The longest the UPS has been on battery in thirty days is three
seconds, which is a self-test transferring the load. **No real cut has ever
been observed by this stack**, so every number above is the card's estimate
and none of it is measured. `Saruman` draws 84 W on average and 185 W at peak,
from its iLO's power meter.

Two documents already pay for this gap. `UpsRuntimeCritical` in
`ups.rules.yaml` pages below five minutes of `upsEstimatedMinutesRemaining`,
the one reading [`fit-the-ups-battery.md`](../runbooks/fit-the-ups-battery.md)
§5 says not to lean on, because it sat on the fabricated `63` for 744 of 764
samples after the pack went in — so the only rule about the end of the pack
keys on the number the estate trusts least. And
[`fit-the-saruman-ssds.md`](../runbooks/fit-the-saruman-ssds.md) left the
Smart Array's drive write cache disabled on the HDD mirror *"whose only
protection is `mjolnir` — a UPS whose runtime reading has sat on the
fabricated `63` for the whole retained window"*: a capability the estate has
bought and cannot use, withheld specifically because nothing shuts the host
down before the pack empties.

### What is on the UPS, read at the rack

`hardware.md`'s Rack table listed what sits in each U and never what feeds it,
and the one host that does not rack was recorded in `network.md` as *Media
room* and nowhere as powered by anything. Read on 2026-09-20:

| Host | Powered by |
| --- | --- |
| `mjolnir` | The wall |
| `morpheus`, `Saruman`, `neo` | The PDU in U7, which the UPS feeds |
| The TP-Link on the U4 shelf | A UPS outlet, since 2026-09-08 |
| `prometheus`, `oracle` | The TP-Link's shelf for network; their own cells for power |
| `smaug` | **The PDU, by a long cord from the rack to the media room** |

So `smaug` is on the UPS. #574 could not say so and priced both cases; the
case that holds is the deferred one — the ZFS mirror, the only spinning data
in the estate, runs until the pack is empty and then stops uncleanly, with a
boot SSD whose previous owner did exactly that 509 times in 538 power cycles
([`hardware.md`](../hardware.md#accessories)).

### What constrains the answer

- **CasaBonita is terminal outward** ([ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md)).
  Nothing on `smaug` initiates into another segment, and ADR-0016 said in
  advance that a `40 → 99` rule for a UPS would be a rule with the shape it
  counts. TrueNAS ships a UPS service that speaks NUT; in its *master* form it
  would drive the card's SNMP agent itself, across that boundary.
- **The lab segment counts its rules too**
  ([ADR-0033](0033-keep-the-ilo-on-the-lab-segment.md)): VLAN 30 reaches
  Winterfell on exactly two passes, `Saruman`'s Alloy pair to `10.0.99.20`, and
  a `30 → 99:161` pass for a driver on the hypervisor would be a third.
- **The card is moving to SNMPv3 authPriv**
  ([ADR-0036](0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md)),
  `shiva` first and `mjolnir` next, and decision 5 there is *authPriv or
  nothing*. Whatever drives the card has to hold that credential.
- **The firewall is on Winterfell natively.** `morpheus` is `10.0.99.1`; it
  reaches `10.0.99.10` with no rule, because there is no boundary between them.
  It is also the one host with an address on every segment.
- **The pfSense NUT package is already installed on `morpheus`** —
  `pfSense-pkg-nut 2.8.2_9` over `nut 2.8.5_1`, installed 2026-08-20, mode
  `none`, no `ups.conf`, no `<nut>` block in `config.xml`, nothing listening on
  3493. It went on the day the pack was ordered and was never configured, and
  no document in this repository knew it was there. Recorded here because a
  package nobody remembers installing is the kind of thing this repository
  exists to write down, and because it is the first half of the answer,
  already done.
- **What the ruleset already permits, read with `pfctl -sr` on 2026-09-20.**
  On `igc0.30` and on `igc0.40` the only blocks to the gateway's own address
  are HTTP, HTTPS and SSH; the *Allow internet* catch-all then passes anything
  from the segment to `any`, and the gateway's address on that segment is
  inside `any`. So `10.0.30.110 → 10.0.30.1:3493` and
  `10.0.40.30 → 10.0.40.1:3493` **already pass**, and neither tripwire logs
  them — [#223](https://github.com/Gerrrt/HomeLab/issues/223)'s rules match
  `<Internal_Segments>` and `<House_Segments>`, not the interface address. A
  listener on the firewall's segment addresses costs no new pass. What it
  costs is that every television, console and stream box on 40 could talk to
  it too, and that is the part to close.

## Decision

**`morpheus` runs the NUT server. `Saruman` and `smaug` subscribe to it on
their own gateway address. The listener is scoped to the two subscribers by a
pass-above-block pair on each interface, in the shape the gateway blocks
already have. `neo` dies with the UPS, the laptops ride their own cells, and
the whole of it is proved by a forced shutdown and one mains pull before any
document says it works.**

### Who shuts down, and who does not

| Host | Powered by | Acts on the signal | How | Rule it costs |
| --- | --- | --- | --- | --- |
| `mjolnir` | Wall | Is the signal | The card's SNMP agent, polled by `snmp-ups` on the firewall | None — `10.0.99.1 → 10.0.99.10` crosses nothing |
| `morpheus` | PDU | **Yes, last** | `upsmon` primary; halts after every secondary has | None |
| `Saruman` and every guest on it | PDU | **Yes, first** | `nut-client` secondary against `10.0.30.1:3493`; Proxmox halts its guests on the way down | A pass from `10.0.30.110` above a block from the segment, both to `10.0.30.1:3493` |
| `smaug` | PDU, by the long cord | **Yes, first** | TrueNAS's UPS service in slave mode against `10.0.40.1:3493` | A pass from `10.0.40.30` above a block from the segment, both to `10.0.40.1:3493` |
| `neo` | PDU | No | A switch has no state to lose and no client to run; it loses power when the pack does | None |
| TP-Link on the shelf | UPS outlet | No | Same; it is on the UPS so the laptops keep a network for as long as the rack has one | None |
| `prometheus`, `oracle` | Own cells | No | They stay up through the rack's shutdown and watch it, which is the property #454 and #532 bought; about 2.5 hours on `prometheus`'s cell, `oracle`'s unmeasured | None |
| `trinity`, when built | To be recorded when it is placed | To be decided when it is placed | — | — |

### The listener is narrowed, not opened

The `pfctl` reading above is the whole reason this is cheap, and it is also
the reason it needs a rule at all. `upsd` binds to `10.0.30.1` and `10.0.40.1`
and nothing else — not the Winterfell address, not the Hicks one, and never
the WAN. On each of the two interfaces, a `pass` from the one subscribing host
to the gateway address on `3493/tcp` goes **above** a `block` from the whole
segment to the same, and both go above the *Allow internet* catch-all. That is
the shape *Block SSH to pfSense*, *Block HTTPS to pfSense* and *Block HTTP to
pfSense* already have on every interface, and it is the same lesson ADR-0016
learned about position: a pass appended at the bottom would sit under a block
and never match, and a block appended there would sit under the catch-all and
never match either.

The count in [ADR-0013](0013-segment-access-as-implemented.md)'s accounting
rises by two pairs. Neither pair lets any host reach any other segment.
CasaBonita's terminal-outward property, the one ADR-0016 said was the
direction that matters, is exactly as it was: the NAS reaches its own gateway
on one more port, and the tripwire on `igc0.40` must still never log a line.

### Why the firewall, and not the hypervisor or the NAS

Three shapes were on the table in #574. Each host polling the card itself
costs a `30 → 99:161` pass and a `40 → 99:161` pass — two crossings into
management, one of them the first thing on CasaBonita ever allowed to initiate
upward, and each host holding the card's v3 credential. A NUT server on
`prometheus` keeps the credential on the monitoring host, where the exporter
already holds it, but `prometheus` is on 99 like the card, so the subscribers
would still cross a boundary to reach it, and the monitoring host would then
be the thing that shuts the firewall down. The firewall is the one host that
is *on* every segment: its subscribers reach it without crossing anything,
the driver reaches the card without crossing anything, the package is already
installed, and pfSense halting last is the right order anyway, because a
hypervisor halting its guests still wants DNS and a route while it does.

APC's own answer, PowerChute Network Shutdown, is a client per host; it has
no pfSense client and would put a second agent on `smaug` beside the exporter.
Doing nothing, with the runtime measured, is the answer #574 offered as the
floor. It would have been the answer if the load were small enough for the
pack to cover any plausible cut; at 21 % and 47 claimed minutes it is not,
and the cost of the real answer turned out to be two pass/block pairs and
zero purchases.

### The low-battery point is the card's

NUT's secondaries shut down on `LB`, and `LB` is set by the card from its own
low-battery runtime threshold. That threshold is read, not chosen here: the
runbook records what the card holds, and the measurement below is what says
whether it is enough for a Proxmox host to halt four guests and a NAS to
export a pool. `upsmon`'s `FINALDELAY` on the primary is the time the firewall
waits after the secondaries have gone, and it is the one number this decision
does set: long enough for `Saruman`'s slowest guest, short enough to leave the
pack something.

### The credential, and where it goes

ADR-0036 decision 5 stands: the driver speaks SNMPv3 authPriv to the card once
the card has moved, and the v2c community until it has, and in either case the
value comes from SOPS and is never on a command line. The pfSense package
stores it in `config.xml`, which is the one new place the card's credential
lives; `backup-firewall.sh` already carries that file off the host encrypted,
so the copy that leaves the estate is ciphertext. When the card moves to v3
the driver's credential moves with it in the same visit, and the runbook says
so, because a driver left on v2c is the thing that keeps v2c enabled.

### The measure, and the proof

Nothing above is proved by reading it back. Two tests, in the runbook, in
this order:

1. **The sequence, without draining the pack.** `upsmon -c fsd` on `morpheus`
   sets the forced-shutdown flag and every secondary halts as it would on
   `LB`: `Saruman`'s guests, then `Saruman`, then `smaug` exporting `erebor`,
   then the firewall after `FINALDELAY`. Watched from `prometheus`, which
   stays up on its cell and sees each host go.
2. **The runtime, once, with the load on.** Mains pulled at the wall with
   every host running and the stack watching `upsSecondsOnBattery`,
   `upsEstimatedMinutesRemaining` and `upsEstimatedChargeRemaining` decay,
   stopped at a chosen charge rather than run to empty, and the slope written
   into `hardware.md` beside the card's claim so the estate has a measured
   number where it has had an estimated one. #454 did this for the laptop
   cell; nothing has done it for the rack.

**Until both have happened, this ADR is a configuration nobody has tested**,
and `security.md`'s *Mains power loss* row says so in those words.

### `smaug` keeps the counter

The S3520's unsafe-shutdown count is the measure of every cut the sequence
did not catch, and it stays the measure after the sequence exists: a clean
`LB` shutdown does not move it, and a mains cut shorter than the pack does
not either, so any growth is a stop nobody planned.
`scripts/collect-smart-state.sh` exports it for NVMe drives and, since
[ADR-0047](0047-collect-smaug-smart-through-a-root-cron-and-the-textfile-collector.md)
put a root cron job on `smaug` under the scrape and taught the collector
Intel's attribute 174, for the S3520 itself — that ADR closed
[#483](https://github.com/Gerrrt/HomeLab/issues/483) and named a rule on the
counter as the decision #574 would take. This is that rule:
`SmartDriveUnsafeShutdownsGrowing` in `host.rules.yaml` fires on any growth
over a day, stays quiet on the 509 the drive arrived with, and clears a day
after the event, so the counter is watched rather than remembered.

## Consequences

- **Two pass/block pairs join the ruleset**, on `igc0.30` and `igc0.40`, and
  ADR-0013's table gains them. Position is the failure mode, as it was for
  ADR-0016's rules: the strong test is the block's own counter rising for the
  televisions and staying flat for the NAS, not "the NAS can reach the
  firewall", which was already true.
- **The firewall halts cleanly a few minutes before it would have died.** The
  house loses DNS, DHCP and its route at `LB` plus `FINALDELAY` rather than at
  an empty pack. That is a cost measured in minutes on a cut that has already
  lasted the better part of an hour, and the alternative is a firewall that
  stops mid-write on the NVMe it boots from. Once the sequence is proved,
  `fit-the-saruman-ssds.md`'s reason for withholding the HDD write cache is
  answered and that decision can be re-read; it is not re-taken here.
- **A new listener on the segment whose hosts are assumed compromised.**
  `upsd` on `10.0.40.1` is reachable from `10.0.40.30` and, after the block,
  nothing else on 40. What a stolen secondary credential buys is UPS status —
  a secondary cannot set `FSD`, only the primary's user can, and that one is
  never given to a subscriber. A compromised NAS can therefore read the pack's
  charge and cannot shut the rack down.
- **The card's credential is on the firewall.** One more copy, in
  `config.xml`, encrypted at rest in the backup and not in the repository.
  ADR-0036's rotation runbook gains a step: the NUT driver's copy moves when
  the card's does.
- **`neo` stops uncleanly, and that is accepted.** RouterOS on a CRS326 keeps
  its configuration in flash and writes it on change, not on traffic; a power
  loss costs it nothing it would have kept. If that turns out to be wrong the
  answer is a `neo` that halts on a script, not a rule.
- **A shutdown on the signal is a deliberate stop nothing announces.**
  [ADR-0028](0028-let-guest-liveness-cross-but-not-guest-telemetry.md) says
  the estate cannot tell a deliberate shutdown from a crash, and this is the
  first deliberate shutdown that no operator schedules. The tell is the pair:
  `UpsOnBattery` firing from `prometheus`'s stack, which stays up, followed by
  `InstanceDown` for the subscribers in the order above. A subscriber that
  goes down with no `UpsOnBattery` in front of it crashed.
- **`smaug` is a subscriber on a segment with no logs**, so a shutdown that
  fails on the NAS is visible only as `InstanceDown` and a counter that moved.
  That is ADR-0016's residual arriving one more time, and the counter is the
  answer to it.
- **The runtime is still the card's estimate until the pull.** Every document
  that quotes 47 minutes is quoting a card that has never been drained, and
  says so.
- Rejected, and why: each host polling the card (two crossings into
  management, one of them the first upward initiation from CasaBonita);
  PowerChute (no pfSense client, a second agent on the NAS); nothing at all
  (the floor #574 offered, wrong at this load and this cost).
