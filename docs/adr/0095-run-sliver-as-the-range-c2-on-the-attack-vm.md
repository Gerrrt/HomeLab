# ADR-0095: Run Sliver as the range C2 on the attack VM

**Status:** Accepted · 2026-10

## Context

[ADR-0007](0007-defensive-estate-and-offensive-range.md) says `ifrit` "holds
C2 and attack tooling", and [ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)
sizes its memory against "a Kali VM with BloodHound and its Neo4j alongside a
C2 server". Neither names the C2. The playground runbook's §5 builds the attack
VM and references "the C2 operator's interface" without saying what serves it.
This picks one, so the runbook and the first exercises have something concrete
to build against rather than a placeholder.

The purpose fixes the requirement, and it is not the attacker's. The range
exists so the defended estate — the Windows domain on `Saruman`, watched by
Wazuh, Velociraptor and Zeek — **experiences** a real command-and-control
channel and the SOC gets to catch it ([ADR-0007](0007-defensive-estate-and-offensive-range.md),
the exercises in [`docs/exercises/`](../exercises)). So the C2 is chosen to be
representative of what the SOC must detect, inspectable while it runs, and
cheap to stand up and tear down on a box that is powered off between sessions.
Evasion is explicitly not a goal here: the aim is to generate known, labelled
activity and measure whether the estate sees it, not to win against it.

What the choice is between, among the maintained open-source frameworks:

- **Sliver** (BishopFox). Single Go binary for the server and a single binary
  for the operator client. Cross-platform implants, mTLS / HTTP(S) / DNS / WireGuard
  transports, multiplayer, and a scriptable console. Actively maintained, and
  well represented in public detection content, so expected signatures exist
  to test against.
- **Mythic** (its own project). A framework of Docker containers with a web UI
  and pluggable agents. More moving parts, more capable, and heavier to run.
- **Metasploit's own session handler.** Already in Kali, familiar, and its
  traffic is the most heavily signatured of all — but it is a weaker model of
  a modern C2's transports and long-haul beaconing.
- **Havoc**, **Covenant**, and the commercial frameworks. Each is either less
  maintained, .NET-centric, or costs money for no gain the lab needs.

## Decision

**The range C2 is Sliver, run on the attack VM, reached only from the operator
workstation.**

- **Sliver** is the default framework. One server binary on the attack VM, the
  operator client over Sliver's own mTLS. It is a single VM state to snapshot
  and revert with the rest of the range, which suits a disposable playground
  that `ifrit` powers off between sessions.
- **It runs on the attack VM, inside the range**, which already shares VLAN 30's
  broadcast domain with the estate by [ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md).
  The implant's callbacks from a domain host to the attack VM traverse exactly
  the segment the SOC and Zeek watch, which is the point.
- **No new firewall rule, and nothing reaches the house.** The C2 listener and
  its implants live within the lab segment and the routeless range bridge. The
  operator reaches the Sliver console the same way the range is already driven
  — from the analyst workstation per [ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)'s
  operator path — not from a management host, and the C2 never remote-writes,
  phones home off the estate, or opens a path *into* the house.
- **Mythic is the named fallback**, not a second standing install. If an
  exercise needs an agent or a transport Sliver does not offer, that exercise's
  file records why and stands Mythic up on its own guest for the run. The
  default stays one framework so the baseline the SOC is tuned against does not
  drift.
- **Describe, do not publish.** Per [`security.md`](../security.md#what-this-repository-deliberately-does-not-publish)
  and the [`docs/exercises/`](../exercises) rules, exercise files name the
  framework, the transport and the technique by ATT&CK ID. They carry no
  profiles, no generated implants, and no operator configuration or keys.

## Consequences

- The playground runbook's §5 and the first exercises have a concrete C2 to
  name. "Stand up the C2" becomes "install Sliver on the attack VM."
- Detections are tuned against one framework's defaults first, which is the
  honest starting baseline: a known channel the estate either catches or does
  not. Later exercises can vary the transport (mTLS, then HTTPS, then DNS) and
  record how each shifts what Zeek and Suricata see — the measurable progression
  the exercise log is built for.
- Choosing the well-signatured framework on purpose means an early *miss* is a
  real gap in the estate's visibility, not an artifact of an exotic tool. That
  is the more useful failure.
- Sliver on the attack VM adds no RAM beyond what [ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)
  already counted for "a C2 server"; BloodHound still runs on `eden`, off the
  attacker's host.
- The lab gains a second framework's worth of upkeep only when an exercise
  calls for Mythic, and only for that run. The standing surface stays small.

## Alternatives considered

- **Mythic as the default.** Rejected as the standing choice for the weight:
  a container stack with a web UI is more to run, snapshot and revert on a box
  meant to be disposable, for capability the first year of exercises does not
  need. Kept as the fallback for the exercise that outgrows Sliver.
- **Metasploit's handler as the C2.** Rejected as the representative channel:
  it is already in Kali and fine for a quick session, but it models a modern
  beaconing C2 poorly, and leaning on the single most-signatured handler would
  make the estate look more capable than it is.
- **No decision; pick per exercise.** Rejected because a moving baseline cannot
  be measured. One default framework, tuned against and recorded, is what makes
  "the SOC caught more this quarter than last" a true statement rather than a
  comparison of different tools.
