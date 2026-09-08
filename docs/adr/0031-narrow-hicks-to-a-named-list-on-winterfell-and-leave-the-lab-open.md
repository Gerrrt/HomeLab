# ADR-0031: Narrow Hicks to a named list on Winterfell, and leave the lab open

**Status:** Accepted · 2026-09

## Context

[ADR-0013](0013-segment-access-as-implemented.md) read the ruleset on 2026-09-01
and found that Hicks (50) reached all of Winterfell (99) and all of
ImaginationLAN (30), on every protocol and port. No rule granted it and no rule
denied it: the Hicks interface blocked CasaBonita, Skids and Degens and then
passed to `any`, so the two segments that mattered most fell through to the
catch-all. [ADR-0002](0002-vlan-segmentation-strategy.md), `security.md` and
`README.md` had all described something narrower than what was deployed.
ADR-0013 corrected the description and, deliberately, did not decide the
posture. That decision is
[#228](https://github.com/Gerrrt/HomeLab/issues/228), and this ADR records it.

The exposure was real and it was the whole segment. `SECURITY.md` had already
accepted that a compromised Hicks workstation could write to Prometheus and
Loki without a credential, because the ingest ports are unauthenticated by
design ([ADR-0012](0012-publish-only-ports-with-an-off-host-consumer.md)); that
residual was scoped to one host and two ports. The catch-all made it every host
on Winterfell, every port, and the lab besides.

Three options were on the table:

1. **Accept and record it.** Cheapest; widens the residual from one host to a
   segment and writes that down.
2. **Block `50 → 99` and `50 → 30`, then allow-list back.** The default-deny
   shape everything else has. Highest confidence; the failure mode during
   rollout is losing management access from the only segment that has it.
3. **Block `50 → 99` only.** Winterfell is where compromise is total;
   ImaginationLAN is the segment where broken things are meant to live, and
   [ADR-0007](0007-defensive-estate-and-offensive-range.md) wants the lab
   reachable from trusted workstations.

Two later decisions constrain the third option's other half.
[ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
consumes `50 → 30` wholesale — Proxmox on two hosts, the lab's Grafana, RDP
into the domain, the C2 operator's interface — and says #228 cannot narrow that
path without the list of what a workstation actually reaches there.
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) says the
list comes from the build, so #228 waits on it rather than the reverse.
[`build-the-lab-domain.md`](../runbooks/build-the-lab-domain.md) §10 has
started that list.

## Decision

**Option 3, with the enumeration done.** Decided 2026-09-01, applied on
`morpheus` 2026-09-02, and read back off `pfctl -sr` for this document on
2026-09-08.

### Hicks → Winterfell is a named list

The Hicks interface carries, in order, above a logged full-segment block:

| Rule | Destination | Purpose |
| --- | --- | --- |
| `tcp/22` | all of `10.0.99.0/24` | SSH to every host on Winterfell |
| `tcp/443` | `10.0.99.1` | the firewall's web UI, on its management address |
| `tcp+udp/53` | `10.0.99.1` | DNS to the resolver |
| `udp/123` | `10.0.99.1` | NTP |
| `icmp echoreq` | all of `10.0.99.0/24` | ping |
| `tcp/80`, `tcp/443` | `10.0.99.30` | the wiki |
| `tcp/3000` | `10.0.99.20` | Grafana |
| `tcp/80`, `tcp/443` | `10.0.99.10` | the UPS card, added 2026-09-03 |
| *block, logged* | all of `10.0.99.0/24` | **Block access to Winterfell** |

Prometheus on `9090` and Loki on `3100` are not on the list. The only paths to
those ports from outside Winterfell are the two host-scoped passes that carry
`Saruman`'s agent, which is the residual `SECURITY.md` describes.

**The whole segment is the source, not an admin-host alias.** The devices that
administer the estate are ordinary DHCP leases inside `.100–.200`. A rule naming
them would drift the first time a lease moved, and a rule that drifts silently
is worse than one that is honestly wide. Narrowing to named devices needs
reservations first, and is a follow-up rather than part of this decision.

### Hicks → ImaginationLAN stays open, by a rule

*Allow Hicks access to ImaginationLAN* now sits on the **Hicks** interface,
where it evaluates — ADR-0013 found it on the ImaginationLAN interface, where
Hicks traffic never arrives, and that inert copy is deleted. The lab is reached
entire, and it is reached by a rule that says so rather than by a catch-all
nobody wrote. It is not narrowed, for ADR-0014's reason: the list of what a
workstation needs in the lab does not exist until the lab does.

### Recorded rather than tidied

Two things differ from the plan, and they are written down instead of fixed:

- **The lab pass is TCP-only.** UDP and ICMP from Hicks to the lab still
  arrive, through the catch-all, because nothing on Hicks blocks ImaginationLAN.
  The rule is load-bearing for nothing today; it becomes load-bearing the day a
  block for private ranges lands above the catch-all, and on that day it would
  take ping and SNMP to the lab with it. Widen it to `any` before that.
- **The DNS and NTP passes to `10.0.99.1` carry nothing.** They were added
  because the wiki's DNS runbook said every client resolved at `10.0.99.1`. A
  Hicks laptop's DHCP offer shows `domain_name_server = {10.0.50.1}`, so clients
  resolve at their own gateway and no Hicks rule touches that. The two passes
  stay: they are harmless, and `10.0.99.1` answering from Hicks is occasionally
  useful when the firewall itself is being diagnosed. *Allow NTP* has matched
  zero packets since it was created; that is expected, not a fault.

## Consequences

- **Default deny now holds on every segment.** Hicks was the last exception in
  [ADR-0025](0025-close-the-switch-lan-to-winterfell.md)'s title, and its
  correction block of 2026-09-06 already records this state; this ADR is the
  decision that block was waiting for. ADR-0025 is not superseded — its subject
  was the switch LAN — but its sentence "Hicks is the one segment whose
  catch-all reaches another" is now a description of a rule rather than of an
  omission.
- **The block is enforcing, not decorative.** Read on 2026-09-08: *Block access
  to Winterfell* on Hicks has dropped 28 packets; *Allow SSH to Winterfell* has
  passed about two million; *Allow Hicks access to ImaginationLAN* about 2.7
  million. The list is what carries the real traffic.
- **The residual in `SECURITY.md` narrows rather than widens.** Option 1 would
  have widened it to the whole segment; instead a compromised Hicks workstation
  reaches the named list and nothing else on Winterfell. Its remaining path to
  the unauthenticated ingest ports is SSH to a host that can reach them, which
  is a credential rather than a firewall rule.
- **`50 → 30` wholesale is a decision with an expiry.** When
  [#96](https://github.com/Gerrrt/HomeLab/issues/96) and
  [#265](https://github.com/Gerrrt/HomeLab/issues/265) produce the list of what
  a workstation reaches in the lab, narrowing becomes possible and is worth
  doing; ADR-0014 says narrowing without that list reopens it, so this ADR
  does not.
- **Position matters on this interface.** It is an ordered list in which a
  pass below the blocks does nothing. [ADR-0008](0008-place-services-by-data-trust.md)'s
  `50 → 40` and any future pass into Winterfell must go above *Block access to
  Winterfell*, or they are decorative.
- **Reopened by:** the lab list existing and `50 → 30` being narrowed against
  it; a management surface appearing on Winterfell that is not on the list and
  is wanted from a workstation — the iLO, if
  [#235](https://github.com/Gerrrt/HomeLab/issues/235) had moved it, was the
  first candidate and stays on the lab; or DHCP reservations for the admin
  devices, which make the source narrowable.
