# Network diagrams

[![drawn from docs/network.md](https://img.shields.io/badge/drawn%20from-docs%2Fnetwork.md-30363d?style=plastic)](../../docs/network.md)
[![SVG](https://img.shields.io/badge/SVG-FFB13B?style=plastic&logo=svg&logoColor=white)](https://developer.mozilla.org/docs/Web/SVG)

[![The home network: ISP gateway, the pfSense firewall morpheus, the core
switch neo, the 9U rack, and one panel per VLAN with every addressed
host.](current/network.svg)](current/network.svg)

| File | What it is |
| --- | --- |
| [`current/network.svg`](current/network.svg) | **The diagram, and its own source.** Hand-written SVG: edit it as text |
| [`current/network.png`](current/network.png) | A raster export of the SVG, for anywhere that will not render SVG |
| [`previous/matrix_elysium.png`](previous/matrix_elysium.png) | The diagram this one replaced, drawn in 2025. Its source was never committed, so it could not be corrected, and by 2026-10 it showed retired hosts, owner-linked device names and none of the lab guests. Kept as a picture of how the house used to be wired |
| [`previous/Network_Diagram.png`](previous/Network_Diagram.png) | The one before that |

## What the diagram is drawn from

[`docs/network.md`](../network.md) is the authority for every segment, subnet,
host and address on it, and [`docs/hardware.md`](../hardware.md) for the rack.
The diagram restates them; it never adds to them. A change that adds, removes or
re-addresses a host in `network.md` touches `network.svg` in the same pull
request. Otherwise the picture goes stale the way its predecessor did, and
nothing in CI would notice.

It follows the same publishing rules as `network.md`
([`security.md`](../security.md#what-this-repository-deliberately-does-not-publish)).
Personal devices appear by role, never by owner, and Skids devices appear by
class and count. The WAN address, the WireGuard endpoint and port, full MAC
addresses and camera placement are absent on purpose.

Colours are the patch-cable colours of
[ADR-0009](../adr/0009-colour-vlans-by-cable-not-by-trust.md), the same hexes
as the Mermaid `classDef`s in [`architecture.md`](../architecture.md). A
dashed panel border marks a segment that is terminal outward. A grey dashed box
is planned and not built.

## Editing it

The SVG is laid out by hand on a 2400 × 1540 canvas and grouped by segment
(`<g id="vlan-30">` and so on). Each host is a `<g class="host"
data-host="…">`, so a host can be found by name. It uses no external fonts,
images or scripts, because GitHub's image proxy strips them. The font stack
falls back to the system sans and mono.

After editing, re-render the PNG at 1.5× from the SVG with any SVG rasteriser,
for example:

```bash
rsvg-convert --zoom=1.5 docs/diagrams/current/network.svg -o docs/diagrams/current/network.png
```

Commit the PNG with the SVG it was rendered from.
