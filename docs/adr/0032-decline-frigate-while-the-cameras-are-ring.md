# ADR-0032: Decline Frigate while the cameras are Ring

**Status:** Accepted · 2026-09

## Context

[#149](https://github.com/Gerrrt/HomeLab/issues/149) asked for a decision on
[Frigate](https://frigate.video/) before anyone deployed it, on the grounds that
it is the one service on the self-hosted shortlist that changes the network's
shape rather than its population.
[ADR-0008](0008-place-services-by-data-trust.md) set the precedent that a
service like that gets a decision record rather than a ticket.

The issue set out four things to settle first, and they are all real:

1. **It changes the character of the `99 → 20` rule.** ADR-0008 adds that rule
   for Home Assistant reaching IoT devices — occasional, low-volume control
   traffic. Frigate on Winterfell would pull continuous RTSP from every camera
   through the same rule, permanently. The direction stays right; the volume
   and purpose do not resemble what was authorised.
2. **It becomes the most sensitive data store in the house.** `security.md`
   withholds camera placement from this repository on purpose. A clip archive
   is that information plus continuous footage of the inside of the house, on
   the same segment as the firewall's admin UI.
3. **Hardware.** Frigate wants a Coral TPU or a capable GPU. On CPU it
   saturates whatever it runs on, and ADR-0008's tier is a low-power mini PC
   already carrying Immich's ML and Paperless's OCR.
4. **Storage and retention.** Continuous recording is terabytes per camera per
   month, and retention is a privacy decision as much as a capacity one.

It also priced the alternative — Frigate on the NAS (40) — and that alternative
needs `40 → 20` or a camera path into a terminal segment, and puts the most
sensitive archive in the house on the tier
[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md) defines
as holding replaceable data. Rejected here, on the record, so it is not proposed
again by omission.

**A fifth fact settles the question before the four are reached.** Every
camera on Skids is a Ring device — `network.md` lists seven cameras, floodlights
and a doorbell, plus the Ring alarm hub — and Ring cameras expose no local
stream. There is no RTSP, no ONVIF, no path for footage to leave the device
except through Ring's cloud. Frigate consumes RTSP. Pointed at this estate it
has nothing to consume, and the four questions above are questions about a
system that cannot be built with the cameras that exist.

## Decision

**Do not deploy Frigate.** Not on Winterfell, not on the NAS, and not in
`stacks/` at all while the cameras are Ring.

Adopting Frigate is a camera replacement first. That is a hardware and privacy
decision of its own — seven devices, a doorbell, and the alarm integration they
come with — and it is the decision that would actually be being made under the
name of "deploy Frigate". It is not made here, and it is not made implicitly by
a compose file.

The `99 → 20` rule stays what ADR-0008 authorised: Home Assistant's control
traffic, occasional and low-volume. Nothing continuous is authorised through it
by this document, and a future Frigate would need its own row in that table
rather than inheriting this one.

## Consequences

- **The IoT segment's camera footage stays in a vendor cloud**, which is the
  current state and is not changed by this decision. `security.md`'s description
  of the cameras — network-connected computers running firmware nobody outside
  its vendor has audited — is unchanged, and the segment's whole design assumes
  they are already compromised.
- **Home Assistant ([#134](https://github.com/Gerrrt/HomeLab/issues/134)) loses
  nothing.** Its Ring integration is cloud-side either way; Frigate was an
  addition to it, not a prerequisite.
- **The `Considered and declined` list in `roadmap.md` gains an entry**, so the
  next shortlist argues with this reasoning rather than restarting from nothing.
- **Reopened by any one of these**, each of which gets its own decision first:
  the cameras are replaced with devices that serve RTSP locally; an accelerator
  is bought for the sensitive tier, or a machine is bought for this alone; and
  `99 → 20` is re-authorised for continuous RTSP as a separate row in ADR-0008's
  table, with the retention policy written down beside it. The alternative
  placement on the NAS stays rejected even then, for the reason above.
