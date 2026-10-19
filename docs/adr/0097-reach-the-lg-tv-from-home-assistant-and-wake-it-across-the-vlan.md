# ADR-0097: Reach the LG TV from Home Assistant, and wake it across the VLAN

**Status:** Accepted · 2026-10

## Context

The household wants `mediatv`, the LG OLED at `10.0.40.100` on CasaBonita (40),
in Home Assistant, including the power button.
[#1218](https://github.com/Gerrrt/HomeLab/issues/1218) carries the work.
Home Assistant runs on `trinity` (`10.0.99.40`, Winterfell, 99), and
[ADR-0035](0035-scope-the-99-to-20-rule-to-the-hue-bridge.md) set the shape for
a pass from it to a device. Read the code that would use the pass, write down
the narrowest rule that code needs, and put that rule above the segment's
deny. That ADR's rule went into Skids. This one goes into CasaBonita, which
[`network.md`](../network.md) describes as internet only. Since
[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md) it
takes host- and port-scoped passes in from more trusted segments, and it
initiates nothing.

The order ADR-0013 set was followed again: the integrations, the code, then
the ruleset. All of it was read in the pinned Home Assistant image on
2026-10-19.

### Which integration: LG webOS TV, not LG ThinQ

| Integration | How it reaches the TV | TV support in the pinned image |
| --- | --- | --- |
| **LG webOS TV** (`webostv`) | Locally, a websocket to the TV. `iot_class: local_push`, platinum quality scale | Power off, volume, inputs, apps, notifications. Power **on** is a trigger for something else to fire |
| LG ThinQ (`lg_thinq`) | LG's cloud (`cloud_push`) | **None.** `thinqconnect` 1.0.14 has device modules for washers, refrigerators, air conditioners and some thirty other appliance types, and no TV |

ThinQ would have needed no firewall rule, because Winterfell already egresses.
It cannot drive a TV, though, so the choice is `webostv` and a pass into 40.

### The code: which ports `webostv` opens

From `aiowebostv` 0.10.0, the version the integration pins:

- `_create_main_ws` connects to `ws://<host>:3000` and falls back to
  `wss://<host>:3001` **only** when the first attempt raises
  `ClientConnectionError` (refused) or `WSServerHandshakeError` (the firmware
  insists on TLS). A connection that times out is neither. A firewall that
  **drops** 3000 therefore stops the integration altogether, because it never
  tries 3001.
- `_ws_connect` passes `ssl=False`: *"webOS uses self-signed certificates,
  disable SSL certificate validation"*. Port 3001 encrypts the session and
  authenticates nothing. What authenticates Home Assistant to the TV is the
  client key the TV issues when someone accepts the pairing prompt on the
  screen. Home Assistant stores the key in `.storage` and sends it in every
  `register` message.
- Discovery is SSDP (`urn:lge-com:service:webos-second-screen:1`), which is
  link-local and does not cross a VLAN. The TV is added by address, as the
  Hue bridge was.

### Power-on: the part the integration does not do

A webOS TV in standby has its network stack mostly off, and nothing answers on
3000 or 3001. The integration exposes a *turn on* trigger. Something has to be
wired to it that wakes the TV, and the usual answer is
`wake_on_lan.send_magic_packet`. That service takes the TV's **full MAC** in
its call data, and it sends a UDP datagram to a broadcast address and port
(default `255.255.255.255:9`).

A broadcast from `trinity` stays on Winterfell. To cross the VLAN, the packet
has to be a unicast to `10.0.40.100`, routed by `morpheus`, and that has two
preconditions:

- **`morpheus` must know the TV's MAC while the TV sleeps.** A sleeping NIC
  does not answer ARP. Once the router's entry ages out, the routed packet
  waits on an ARP reply that never arrives, and it is dropped. A **static ARP
  entry** for `mediatv` on the CasaBonita interface removes that dependency.
- **The TV must listen for the packet in standby.** On LG's 2020 firmware the
  setting is *Turn on via Wi-Fi*. Despite the name, it governs the wired port
  as well.

## Decision

**One host-to-host set of rules above the deny, with the plaintext port
refused rather than passed, and power-on by a unicast magic packet to a
static ARP entry.**

| On interface | Rule | Action | Position | Purpose |
| --- | --- | --- | --- | --- |
| 99 | `10.0.99.40 → 10.0.40.100:3001/tcp` | pass | **above** *Block access to CasaBonita* | The webOS websocket, over TLS |
| 99 | `10.0.99.40 → 10.0.40.100:3000/tcp` | **reject** | same | Refuses plaintext, so `aiowebostv` falls back to 3001 at once |
| 99 | `10.0.99.40 → 10.0.40.100:9/udp` | pass | same | The magic packet |

1. **Source is `trinity`, and the destination is the TV.** This is ADR-0035's
   argument, restated for this segment. `10.0.99.20` keeps its two passes to
   `smaug` and gains nothing. No other host on 40 is reached.
2. **3000 is rejected, not passed and not dropped.** Passing it would put the
   client key on the wire in clear, through the router, on every connection.
   Dropping it would leave the integration hanging on a timeout and never
   reaching 3001. A reject sends a TCP reset, which `aiohttp` raises as a
   `ClientConnectionError`, and that is the one exception the fallback
   catches. If the TV turns out to serve **only** 3000, this ADR is reopened.
   3000 is not simply passed.
3. **Port 9/udp, unicast, and nothing else for waking.** No directed broadcast
   to `10.0.40.255`, which `morpheus` does not forward and should not start
   forwarding for one device.
4. **A Kea reservation, then a static ARP entry, for `mediatv`** on
   `morpheus`. `network.md` lists `10.0.40.100` but does not record a
   reservation for it, and ADR-0035 found Skids had none at all. So the first
   step of #1218 is to read `morpheus` and reserve the address if the
   reservation is missing, as ADR-0035's step 4 did for `bifrost`. A host rule
   aimed at a leased address stops matching when the lease moves. The ARP
   entry sits beside the reservation. It is verified with `arp -an` while the
   TV is in standby, and it is the reason the unicast works at all. Both carry
   the full MAC on the firewall, where every other reservation's already is.
5. **The full MAC lives in `secrets/sensitive.sops.yaml`.** The Wake-on-LAN
   call needs it, and [`security.md`](../security.md#what-this-repository-deliberately-does-not-publish)
   truncates every MAC in the repository to its OUI. It reaches Home Assistant
   as an environment variable, read with `!env_var`, the way the Prometheus
   token already does in `homelab_rack.yaml`. It is not a credential, and it
   goes in SOPS because SOPS is where the repository keeps a value it does not
   publish.
6. **The pairing key stays where Home Assistant puts it**, in `.storage`.
   This is the deviation ADR-0035 recorded, and this device adds one more key
   to it.
7. **The rules are not created by this ADR.** #1218 creates them, wires the
   trigger in a package, pairs the TV and tests power-on from standby. Until
   then, `network.md`'s CasaBonita notes carry the rules as decided.

## Alternatives considered

- **LG ThinQ.** No TV support in the pinned library, as above.
- **No power-on.** Only the 3001 pass, and Home Assistant controls the TV once
  something else has turned it on. This is the fallback if the unicast packet
  proves unreliable, and it costs the 9/udp row and the static ARP entry. The
  household asked for the power button, so the fuller version is decided.
- **The firewall's own Wake-on-LAN service.** pfSense can send the packet as a
  real broadcast on the CasaBonita interface, with no 9/udp pass and no static
  ARP. Home Assistant would need a credential to `morpheus`'s API to ask it
  to. That puts the firewall's control plane in the store this repository
  already treats as its least governable. Declined.
- **The streambox, or Alexa.** `streambox` shares the TV's segment and could
  wake it over HDMI-CEC, but Home Assistant has no local path to it either.
  The Echo devices reach the TV through LG's Alexa skill, and Home Assistant's
  `alexa_devices` integration exposes no power control for it. Neither is
  shorter than a datagram.

## Consequences

- **CasaBonita stays terminal outward.** Nothing here lets the TV initiate.
  The return half of each session rides on state, and the #223 tripwire on
  `igc0.40` must still read zero afterwards. `security.md`'s sentence that
  media *"gets internet and nothing more"* is about what the segment
  initiates, and it stays true.
- **Home Assistant now parses replies from a guest-trust device.** The TV runs
  unauditable firmware, which is why it is on 40. A compromised TV can answer
  `trinity`'s websocket with anything, so `aiowebostv`'s JSON handling becomes
  attack surface on the tier that holds every other config-flow credential.
  This is the trade ADR-0035 made for the Hue bridge, and it is accepted for
  the same reason: the device answers and never asks.
- **An impersonator gets the TV, not the tier.** With TLS unverified, a device
  on 40 that took `10.0.40.100` could receive the `register` message and its
  client key. That key controls this TV and nothing else. The static ARP
  entry also pins the router's view of the address, which is the half of that
  attack the firewall can see.
- **The TV's address becomes load-bearing**, as `bifrost`'s did. The
  reservation is what keeps `network.md`'s row true, and the static ARP entry
  sits beside it.
- **Reopened by:** firmware that serves only plaintext 3000; unicast wake that
  proves unreliable, in which case the 9/udp row and the ARP entry are removed
  and the decision falls back to no power-on; or a second device on 40 wanted
  in Home Assistant, which is a row of its own.
