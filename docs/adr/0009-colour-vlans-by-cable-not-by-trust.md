# ADR-0009: Colour VLANs by rack cable, not by trust tier

**Status:** Accepted · 2026-08

## Context

The rack is patch-cable colour-coded, and has been since it was built. The
repository did not know it. Six tagged VLANs, six colours, and the mapping lived
in one person's head and in the cables themselves — which is fine until someone
else opens the rack, or until the person who built it is holding a cable at 2am.

Meanwhile the repository had grown a colour convention of its own. Both Mermaid
diagrams — in [`architecture.md`](../architecture.md) and the README — coloured
segments by **trust tier**:

| classDef | Colour | Applied to |
| --- | --- | --- |
| `mgmt` | green | Winterfell (99) |
| `trusted` | blue | Hicks (50) |
| `untrusted` | red | CasaBonita (40), Skids (20), Degens (10) |
| `infra` | purple | ImaginationLAN (30), plus `morpheus` and `neo` |

Every one of the six collides with the physical cable. The worst inverts the
safety cue outright: **red means "assume this segment is compromised" in the
diagrams, and "infrastructure management" in the rack.** Two contradictory
meanings for the same colour, in the same system, one of them attached to the
segment where a compromise is total.

Colour is read faster than text and is trusted more than text, which is the whole
reason to use it and the whole reason a wrong one is dangerous. A diagram that
disagrees with a cable is a trap laid for whoever is tired.

## Decision

**The physical layer wins. Segments are coloured by their patch-cable colour, and
trust moves to a different visual channel.**

| VLAN | Segment | Cable |
| --- | --- | --- |
| 99 | Winterfell | Red |
| 50 | Hicks | Orange |
| 40 | CasaBonita | Yellow |
| 30 | ImaginationLAN | Green |
| 20 | Skids | Blue |
| 10 | Degens | Purple |

[`docs/network.md`](../network.md) carries this table and is the authority for
it. The scheme runs down the visible spectrum as the VLAN id descends, which
makes it a position mnemonic rather than a semantic one — it deliberately does
**not** track trust, and [ADR-0002](0002-vlan-segmentation-strategy.md) is still
the authority for that.

Three consequences of the split, all of which are the point:

- **Trust is carried by border style.** A dashed border marks a terminal segment
  — CasaBonita, Skids and Degens, egress only, nothing comes back in. Both facts
  survive because neither has to borrow the other's channel.
- **The trunk gets no colour at all.** `morpheus`, `neo` and the ISP gateway
  carry every segment at once, so any hue assigned to them is a claim about a
  segment they do not belong to. They are neutral grey, matching the untagged LAN
  row in `network.md` and the `vlan: lan` label in `prometheus/targets/snmp.yaml`.
- **The mapping is published,** unlike the camera-to-room detail withheld in
  [`security.md`](../security.md). Reasoning is recorded there rather than
  assumed.

## Alternatives considered

**Keep the trust colours in diagrams; publish rack colour as data only.** A
column in `network.md` and nothing else. Rejected: it leaves red meaning two
opposite things across a repository and a rack, which is worse than either
convention alone. The point of writing the mapping down is that a reader can act
on it without checking; a scheme you must remember to distrust is not a scheme.

**Recolour to cable and drop the trust cue entirely.** Simplest, one meaning per
colour. Rejected: the terminal/non-terminal split is the single most important
property of this network — it is what three of the eight alert rules exist to
detect — and a diagram that stops showing it has lost more than it gained.

**Assign a seventh colour to the trunk.** Rejected because there is no seventh
cable. Inventing one would put a fact in the diagram that the rack cannot
confirm, which is the failure this ADR exists to close.

## Consequences

- The diagrams, the Grafana alert tables, the issue template and the published
  Artifacts all agree with what is physically in the rack. Colour becomes
  evidence rather than decoration.
- **Yellow needs care and gets an exception.** It is the only cable colour that
  cannot be darkened to the palette's luminance without becoming brown, so
  CasaBonita uses a lighter fill with near-black text. Every other segment uses
  white on a dark fill.
- Recolouring surfaced a wrong grouping that two meanings sharing one colour had
  been hiding: `Saruman` was classed as `infra` alongside the firewall and the
  switch, when it is a host on VLAN 30. Forcing one meaning per colour made it
  visible. Expect more of this if further colour is added.
- The physical topology export under `docs/diagrams/current/` predates the scheme
  and cannot be brought in line — its `.drawio` source was lost. It stays
  authoritative for layout and not for colour, and says so.
- A future segment needs a cable colour decided before it is documented, not
  after. The Range (gateway-less, unbuilt) has no cable and is therefore
  deliberately outside this scheme.
