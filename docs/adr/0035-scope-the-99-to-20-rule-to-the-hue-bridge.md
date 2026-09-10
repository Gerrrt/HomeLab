# ADR-0035: Scope the 99 → 20 rule to the Hue bridge

**Status:** Accepted · 2026-09

## Context

[ADR-0008](0008-place-services-by-data-trust.md) put Home Assistant on
Winterfell (99) rather than among the devices it controls — it holds their
credentials, and Skids (20) is the segment whose stated assumption is that
everything on it is already compromised — and added one row to pay for the
placement: `99 → 20`, *"Home Assistant reaching IoT devices"*. A direction and
a purpose; not a source, a destination or a port.
[#134](https://github.com/Gerrrt/HomeLab/issues/134) asks that the rule be
written down before it is created and *"scoped as tightly as the devices
actually require rather than opening the segment wholesale"*, and `roadmap.md`
names the part the firewall cannot answer: **how wide**. The source did not
exist when it was written. The destination is the whole segment unless the
devices have addresses that hold.

Three things were read before deciding, in the order
[ADR-0013](0013-segment-access-as-implemented.md) established: the ruleset,
the inventory, and the code that would use the rule.

### The ruleset, on `morpheus`, 2026-09-09

Winterfell's interface blocks every other VLAN explicitly above its egress
pass — *Block access to Skids* among them, `inet` and `inet6` — and above that
stack sit the three passes ADR-0013 lists for `10.0.99.20`: SNMP to the iLO,
SNMP and HTTP to the switch. So the rule is the fourth insertion above a deny
that has been there since the segments were, beside the SNMP passes, exactly
where `roadmap.md` said it would go. Appended at the bottom of the tab it
would match nothing, which is the fault ADR-0013 found in *Allow Hicks access
to ImaginationLAN*.

Skids as a source is untouched by anything here: it blocks the five other
VLANs, carries [#223](https://github.com/Gerrrt/HomeLab/issues/223)'s tripwire,
then egresses. The return half of a session Home Assistant opens is carried by
state and never reaches that ruleset.

**Skids has no DHCP reservations.** None — against three on Winterfell — and
its pool is `10.0.20.100–200`, which contains every address `network.md`
lists for the segment. The Hue bridge is at `.104` by lease, not by
reservation. A host-scoped pass to a leased address is a rule that stops
matching the day the lease moves, silently, with nothing to say why the lights
stopped answering.

### The inventory: what on Skids has a local API

`network.md` lists the segment. Read for what Home Assistant would actually
open a connection *to*, from 99:

| Device | How Home Assistant reaches it | Needs the rule |
| --- | --- | --- |
| `bifrost`, the Philips Hue bridge | Its local API, over HTTPS — the bridge is the radio, the bulbs are Zigbee behind it | **Yes** |
| Ring cameras, floodlights, doorbell, alarm hub | Ring's cloud. No local stream, no local API — the fact [ADR-0032](0032-decline-frigate-while-the-cameras-are-ring.md) turned on | No |
| Amazon Echo ×5 | Amazon's cloud, if at all | No |
| Apple HomePod ×4 | HomeKit over mDNS, which does not cross a VLAN; and a HomePod is a controller, not an accessory | No |
| Litter-Robot 4 | Its vendor's cloud | No |
| Tuya white-noise machine | Tuya's cloud | No |
| VTech baby monitors | Nothing — they are not integrated | No |
| eero ×3 | Nothing — [ADR-0019](0019-read-device-joins-from-the-dhcp-server.md) declined the cloud integration | No |

One device. The phrase ADR-0008 used — *"credentials to the locks and
cameras"* — describes a house this is not: there are no locks, and the cameras
are reached through a vendor rather than across a VLAN. What the rule is for,
on this inventory, is one bridge.

### The code: which ports the Hue integration opens

Read from `aiohue` and Home Assistant's `hue` config flow on 2026-09-09, not
from the Hue documentation:

- Adding the bridge by address runs `discover_bridge`, which probes
  `http://<host>/api/config` — **port 80** — to confirm it is a Hue bridge and
  then `https://<host>/clip/v2/resource` to confirm it speaks v2.
- Pressing the link button runs `create_app_key`, which tries HTTPS first.
- Every request after that, and the event stream the integration lives on, is
  `https://<host>/` — **port 443**.

So the pairing needs 80 once and the running integration needs 443 always.
The integration's other way of finding a bridge, `discover_nupnp`, asks
`discovery.meethue.com` over the WAN and would return this bridge's address —
a path 99 already has, and one this decision does not depend on.

## Decision

**One pass, host to host, on two ports, above the deny — created after the
destination holds still.**

| On interface | Rule | Position | Purpose |
| --- | --- | --- | --- |
| 99 | `10.0.99.40 → 10.0.20.104:80,443/tcp` | **above** *Block access to Skids*, beside the SNMP passes | `trinity`'s Home Assistant to `bifrost`, the Hue bridge |

1. **Source is `trinity`, not Winterfell.** `10.0.99.40` is the address
   [#404](https://github.com/Gerrrt/HomeLab/issues/404) reserved for the tier's
   host. `prometheus` and `oracle` gain nothing from this rule and get nothing.
2. **Destination is the bridge, not the segment.** Every other device on Skids
   is reached through a cloud or not at all, so a segment-wide pass would
   grant access to nineteen devices for the benefit of one. A second device
   with a local API is a second row in this table, argued on its own, not a
   widening of this one. The direction ADR-0008 cares about is preserved in
   both halves: management initiates into IoT, and nothing on IoT can initiate
   anywhere.
3. **Ports are the two the code uses.** 80 for the identification probe the
   config flow runs at pairing, 443 for everything else. Not `any`: the bridge
   also listens for SSDP and mDNS, and neither is wanted from a segment away.
4. **`bifrost` gets a Kea reservation first.** At `10.0.20.104`, where it is —
   an in-pool reservation holds under Kea, as the `Saruman` note in
   `network.md` records, and keeping the address means no document changes.
   The reservation is the first Skids will have, and it is what turns the
   destination above from a guess into a fact. The bridge's MAC is already in
   the inventory, truncated; the reservation carries the full one on the
   firewall, where every other reservation's already is.
5. **The rule is not created by this ADR.** Its source does not exist yet.
   #404 builds `trinity`; the pass is created in the same sitting as the
   reservation, once there is a host to test it from, and `network.md`'s
   Winterfell and Skids notes carry the rule as decided until then and as
   enforced after. `security.md`'s sentence that IoT *"gets internet and
   nothing more"* is about what Skids initiates, stays true, and is left
   alone — the same treatment [ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
   gave CasaBonita's.

**Discovery is not a reason to network the container differently.** Home
Assistant's compose example upstream is `network_mode: host`, for mDNS and
SSDP. Both are link-local; the bridge is a VLAN away; nothing on 20 would be
discovered from 99 however the container were attached. So Home Assistant is
an ordinary member of the tier's bridge network behind Caddy, the bridge is
added by address, and ADR-0008's containment sentence — *"only the reverse
proxy publishing a port"* — stays a property of `compose.yaml`.

### The credentials stay where Home Assistant puts them

The estate's rule is that a credential lives in `secrets/*.sops.yaml` and
nowhere else, rendered at deploy time. Home Assistant cannot be made to obey
it, and this is the service that accumulates more credentials than anything
else on the tier: the Hue application key, the Ring account token, and
everything else a config flow produces are written by Home Assistant into
`/config/.storage/`, and no environment variable or rendered file is a way in.
Rather than a rendered `secrets.yaml` that nothing reads, the deviation is
recorded: **those credentials live in the application's own store, in the
`home-assistant-config` volume, protected by the disk-encryption decision #404
makes and by the volume backup, not by SOPS.** What *can* be held the estate's
way is: a long-lived access token minted for another service belongs in that
service's SOPS file, and the first YAML-configured integration that needs a
credential is the day `/config/secrets.yaml` is rendered from SOPS the way
Alertmanager's URL files are.

## Consequences

- **Skids stops being terminal inbound, for one host on two ports, and stays
  terminal outbound.** The same trade ADR-0016 made for CasaBonita, with the
  same test: #223's tripwire counter on the Skids interface, zero today, must
  not move after the rule lands. `network.md`'s *Reaches* column for Skids is
  unchanged, and Winterfell's gains "named ports on 20" on the day the rule
  exists.
- **The bridge's address is now load-bearing.** `network.md`'s `bifrost` row
  is what the rule is written from, and the reservation is what keeps the row
  true. That is a stronger coupling than the segment has had, and it is the
  price of a host-scoped rule; the alternative was a segment-scoped one.
- **The rule is per device, and that is what keeps it small.** ADR-0032 already
  refused continuous RTSP through this row; this ADR refuses a second
  destination through it. A Zigbee coordinator, an MQTT broker, a locally
  reachable lock: each is a row of its own, each above the same block, and the
  table above is where they go.
- **A hardware answer falls out.** No device needs a USB radio, so `trinity`'s
  placement is unconstrained by Home Assistant — the question
  [ADR-0034](0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)
  left to #404, answered for this service's part.
- **Nothing depends on the eero or on Ring being reachable locally.** Ring's
  integration is cloud-side; the tier being down takes the automations with it
  and leaves the Ring app working, which is the property
  [ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)
  requires — nothing physical may be operable only through Home Assistant.
- **The credential store is a second class of secret on the tier.** SOPS holds
  what the stack takes from outside; Home Assistant holds what it obtained
  itself. The volume archive therefore carries live credentials and has to be
  treated as `grafana-data` already is — encrypted at rest, never tracked, and
  `security.md` names it beside the age key as something an unencrypted disk
  exposes.
- **Reopened by:** a device on Skids that serves a local API and is wanted in
  Home Assistant, which adds a row; the cameras being replaced with ones that
  do, which is ADR-0032's reopen condition and not this one's; or Home
  Assistant gaining a way to take config-flow credentials from a file, which
  would retire the deviation above.
