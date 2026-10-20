# ADR-0099: Control the HomePods from Home Assistant, and leave their audio out

**Status:** Accepted · 2026-10

## Context

The household's rule is that Home Assistant is where everything is controlled.
The four HomePods (`speaker-01…04` in `network.md`) are on Skids (20), and
Home Assistant is on `trinity` (`10.0.99.40`, Winterfell, 99). Today the only
pass into Skids is ADR-0035's, to the Hue bridge.
[#1226](https://github.com/Gerrrt/HomeLab/issues/1226) carries the work.

[ADR-0035](0035-scope-the-99-to-20-rule-to-the-hue-bridge.md) listed the
HomePods as needing no rule, because HomeKit is mDNS and a HomePod is a
controller, not an accessory. That was a reading of HomeKit. It is not this
question. Home Assistant reaches a HomePod through the core **Apple TV**
integration, which uses pyatv and treats a HomePod as a media player. The
method is [ADR-0097](0097-reach-the-lg-tv-from-home-assistant-and-wake-it-across-the-vlan.md)'s:
read the code that would use the pass, then write the narrowest rule that
code needs. Everything below was read from pyatv 0.18.0 in the pinned Home
Assistant image on 2026-10-20.

### What a HomePod offers Home Assistant, and in which direction

pyatv knows the HomePod models (`HomePod`, `HomePodMini`, `HomePodGen2` in
`const.py`). There are two halves, and they point in opposite directions.

**Control: play, pause, volume and what's playing.** It all runs from Home
Assistant to the HomePod:

- **Finding a HomePod by address.** mDNS does not cross a VLAN, so
  discovery falls back to `core/mdns.py`'s `unicast()`, a DNS-SD query sent
  to the device's own `5353/udp`. The reply rides on the state of that query.
- **AirPlay on `7000/tcp`.** `protocols/airplay/__init__.py` opens
  `http_connect(address, service.port)`. The remote-control (MRP) channel is
  tunnelled over AirPlay here (`MrpTunnel`), not on a port of its own.
- **AirPlay 2's event and data channels.** In `ap2_session.py`, the HomePod
  answers `SETUP` with an `eventPort` and a `dataPort`, and pyatv connects to
  both through `auth/hap_channel.py`'s `setup_channel`, which is a plain
  outbound `loop.create_connection(address, port)`. The ports are the
  HomePod's choice, made per session. They are not fixed, and nothing in
  pyatv or Home Assistant can fix them.
- **Companion**, where a HomePod advertises it, is the same shape: an
  outbound connection to a port the device advertises.

**Audio: announcements, chimes, music.** This runs the other way. Before
streaming, `protocols/raop/stream_client.py` opens a `ControlClient` and a
`TimingServer` as UDP listeners on Home Assistant's side, at
`settings.protocols.raop.control_port` and `timing_port`. Both default to
`0`, *"use random free port"*, and the Home Assistant integration sets
neither. The HomePod then sends timing requests to those ports. That needs two
things this estate refuses on purpose:

1. **A device on Skids initiating into Winterfell.** ADR-0008's directional
   rule is that nothing on IoT starts a connection upward, and the #223
   tripwire exists to catch it.
2. **Home Assistant off Docker's bridge network.** Unsolicited inbound
   datagrams to an unpublished, randomly chosen port in the container are
   dropped by Docker's NAT. The fix upstream recommends is `network_mode:
   host`, which `stacks/sensitive/README.md` argues against for this
   container.

## Decision

**Control, not audio. One set of rows from `trinity` to four reserved
addresses, outbound only, with the dynamic range stated as the trade it is.**

| On interface | Rule | Position | Purpose |
| --- | --- | --- | --- |
| 99 | `10.0.99.40 → 10.0.20.21–.24:5353/udp` | **above** *Block access to Skids*, beside ADR-0035's rows | Unicast discovery by address |
| 99 | `10.0.99.40 → 10.0.20.21–.24:7000/tcp` | same | AirPlay, with the remote-control tunnel |
| 99 | `10.0.99.40 → 10.0.20.21–.24:49152–65535/tcp` | same | The event, data and Companion ports each HomePod chooses |

1. **The HomePods get Kea reservations at `10.0.20.21`–`.24`, below the
   pool**, before any rule exists. They hold pool leases today, and ADR-0035's
   note records what a leased destination does: the bridge it was written for
   had drifted by build day. The reservations sit beside `bifrost` at `.20`.
2. **Source is `trinity`, and the destination is four hosts, not the
   segment.** This is ADR-0035's shape: a second device with a local API is a
   row of its own.
3. **The dynamic range is the honest width.** The event and data ports are
   chosen by the HomePod per session, and pyatv connects to whatever it is
   told. A narrower rule would match some sessions and silently drop others.
   The range is the IANA dynamic range, which is where the HomePod's listeners
   are expected to be. #1226 reads the firewall log while pairing and records
   the ports actually used. If they all fall in a narrower band, the row is
   narrowed and this ADR gets a note.
4. **No audio, so no inbound row and no host networking.** Announcements and
   chimes go to the Echos, which already work through `alexa_devices`. The
   HomePods stay AirPlay and Siri speakers in Apple Home for music.
5. **The Home app's speaker access setting** (*Allow Speaker & TV Access*)
   has to admit a controller on another subnet. #1226 records which setting
   that takes. It is household configuration, not a repository fact.
6. **The rules are not created by this ADR.** #1226 creates them after the
   reservations, then adds each HomePod by address and checks state and
   volume. Until then, `network.md`'s Winterfell and Skids notes carry them as
   decided.

## Alternatives considered

- **Audio as well.** This needs an inbound UDP path from four guest-trust
  devices to random ports on the most trusted tier, and Home Assistant on host
  networking. Declined, for the reasons above.
- **HomeKit Bridge, the other direction.** It hands control to Apple Home and
  Siri, which is not where the household wants control. It also needs mDNS
  and a reverse path from the HomePods (as home hubs) to Home Assistant's HAP
  ports. Declined. The entries created in the UI on 2026-10-19 are to be
  removed.
- **Nothing.** The HomePods stay out of Home Assistant. Rejected because the
  household asked for control, and the rows are outbound-only, host-scoped and
  stateful.

## Consequences

- **Skids stays terminal outward.** Everything here is `trinity` initiating.
  The replies ride on state, and #223's tripwire must still read zero.
- **The widest pass in the estate so far, on four hosts.** The dynamic range
  lets `trinity` reach anything a HomePod listens on above 49151. It is
  accepted because the source is one host, the destinations are four devices
  whose listeners are AirPlay's and Companion's, and nothing flows back
  unsolicited. A HomePod with a vulnerable listener in that range is
  reachable from `trinity`, and from nothing else.
- **Home Assistant parses replies from four more guest-trust devices.** This
  is the trade ADR-0035 and ADR-0097 accepted. pyatv's HAP-encrypted channels
  and the pairing credentials in `.storage` are the authentication.
- **Four more load-bearing addresses**, kept true by the reservations.
- **Reopened by:** pyatv or Home Assistant gaining fixed RAOP ports and a
  way to stream without the receiver initiating, which would reopen audio;
  measured event and data ports in a narrow band, which narrows the third
  row; or the household moving control to Apple Home, which retires this.
