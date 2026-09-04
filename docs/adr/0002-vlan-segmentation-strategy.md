# ADR-0002: Segment the network by trust, not by function

**Status:** Superseded · 2025-06 · by
[ADR-0013](0013-segment-access-as-implemented.md)

> [!NOTE]
> Superseded only in its claim about the rule set — "Exactly two inter-VLAN rules
> exist", below, has not been true since the monitoring stack landed. Segmenting
> by trust rather than by function is unchanged and still the design.
> [ADR-0013](0013-segment-access-as-implemented.md) records what is actually
> enforced. The text here is left as written, per ADR-0001.

## Context

A flat home network puts a $20 Wi-Fi plug on the same broadcast domain as a
work laptop. The plug runs unauditable firmware, often has no update mechanism
at all, and is frequently the softest target on the network. Once it is
compromised, everything else is one hop away.

The obvious alternative — segment by function (a "media" network, an "office"
network) — sorts devices by what they do rather than by how much damage they can
do. A smart TV and a workstation both belong to "the household", but they
warrant completely different trust.

There were three plausible options:

1. **Flat network, host firewalls.** Cheapest. Relies on every endpoint
   defending itself, which a Ring doorbell cannot.
2. **Segment by function.** Intuitive to explain, but produces segments with
   mixed trust levels, which means the rules between them end up permissive.
3. **Segment by trust level.** More VLANs, more rules to reason about, but the
   rules are simple because each segment has one trust level.

## Decision

Six VLANs, assigned by how much a compromise of that segment would cost, with
default deny between all of them.

| VLAN | Trust | Rationale |
| --- | --- | --- |
| 99 Winterfell | Highest | Infrastructure. Compromise here is total. |
| 50 Hicks | High | Workstations. The only segment with a management path. |
| 30 ImaginationLAN | Contained | Deliberately broken things live here. |
| 40 CasaBonita | Low | Vendor firmware, permanent internet connection. |
| 20 Skids | Lowest | IoT. Assume every device is already compromised. |
| 10 Degens | Untrusted | Guests. |

Exactly two inter-VLAN rules exist: trusted → management (administration), and
trusted → lab (usability). Everything else is egress-only.

## Consequences

- A compromised IoT device reaches the internet and nothing else. This is the
  main thing the design buys, and it holds even for devices that will never be
  patched.
- Adding a device requires deciding its trust level first, which is a useful
  forcing function.
- Cross-VLAN conveniences break by default. Chromecast and AirPlay discovery use
  mDNS, which does not cross VLANs without an explicit reflector — an ongoing
  annoyance that is the honest cost of this design.
- Trusted devices are a single point of failure for management access. A
  compromised workstation reaches Winterfell. Mitigating that properly needs a
  bastion, which is not worth it at this scale.
- The rule set is small enough to hold in your head, which matters more than any
  individual rule.
