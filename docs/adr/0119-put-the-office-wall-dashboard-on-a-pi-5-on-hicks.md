# ADR-0119: Put the office wall dashboard on a Pi 5 on Hicks

**Status:** Accepted · 2026-11 · reuses the name `heimdall` that
[ADR-0102](0102-bridge-the-vtech-monitor-into-home-assistant-from-a-pi-on-skids.md)
gave a different Pi, superseded by
[ADR-0109](0109-leave-the-vtech-monitor-out-of-home-assistant.md) and never
bought

## Context

The office has a 40" 1080p television on its front wall, above the desk's
monitors and about seven feet from the chair. It was mounted on 2026-10-31 to
show a dashboard: the estate's state and the household's day, read at a glance.
A Raspberry Pi 5 to drive it arrived on 2026-11-16. Nothing in this repository
described either of them.

The name `heimdall` is free. ADR-0102 gave it to a Pi on Skids, at `10.0.20.30`,
that would have bridged the baby monitor. ADR-0109 dropped that bridge, and
that Pi was never ordered. No reservation or firewall row was ever made for it.
This Pi takes the name for a different job on a different segment.

Read from the Pi on 2026-11-17:

- **The device.** A Raspberry Pi 5, 2 GB, on Raspberry Pi OS 13 (trixie),
  booting from a 64 GB card. It idles at about 48 °C with `throttled=0x0`.
- **The desktop.** Raspberry Pi OS's own: `graphical.target`, an autologin
  session on the console, labwc as the compositor. Chromium, `wlr-randr` and
  `cec-ctl` are installed, and both HDMI ports expose a CEC device.
- **The network.** Wi-Fi only, on Hicks, through the basement eero, at
  −45 dBm and 433 Mbit/s on 5 GHz. The OUI is Raspberry Pi's, so the MAC is
  the hardware's own and a reservation by MAC holds.
- **SSH** accepted passwords as shipped.

The question is where a device like this sits, what it may hold, and what may
reach it. It runs unattended, it renders pages, and it shows household data to
anyone standing in the office.

## Decision

1. **`heimdall` is a kiosk on Hicks, at `10.0.50.15`.** A Kea reservation
   below the pool, beside `wearable-01` at `.14`. It joins over Wi-Fi from
   behind the television, so nothing crosses the room from the rack. Hicks
   already reaches `trinity:443` and `prometheus:3000` on its named passes, so
   the screen needs **no new row** to read what it shows.
2. **It holds no credentials.** Chromium opens a page served by `trinity` and
   nothing else. Every token a page needs is added server-side, by the service
   or the proxy that serves it, never stored on the Pi or in the page. Until
   the wall page exists, the kiosk shows Glance's Homelab page, which already
   works that way (ADR-0098). The Pi trusts the tier's root in Chromium's own
   certificate store, imported after its fingerprint is compared with a copy
   already trusted (`build-the-tier-ca.md` §6).
3. **The household's details stay out of the repository.** The wall page's
   code, layout and the Pi's build are committed. Names, calendars, places and
   entity IDs live in `secrets/sensitive.sops.yaml`, as ADR-0100 did for the
   start page's lists. `docs/security.md`'s section on what this repository
   does not publish governs what the wall page's files may say.
4. **One Winterfell row: `10.0.99.20 → 10.0.50.15:9100/tcp`,** above the
   block into Hicks, so `prometheus` scrapes `node_exporter` like any host.
   That is what makes a hung kiosk, a hot Pi or a weak power supply
   (`node_hwmon_temp_celsius`, the throttle state) visible without walking to
   the wall. It is host- and port-scoped, so `firewall-claims.yaml` is
   unchanged.
5. **Hardened like any unattended host.** Key-only SSH with root login off,
   unattended-upgrades on, and the screen never blanked by the desktop.
   Turning the television off at night is a separate step: by HDMI-CEC from
   the Pi if the television obeys it, otherwise by switching the Pi's output
   off on a schedule with `wlr-randr`.
6. **Rebuilt from the runbook, not backed up.** It keeps no state worth
   keeping. [`build-heimdall.md`](../runbooks/build-heimdall.md) is the whole
   of it.

## Alternatives considered

- **Skids, beside the other unattended devices.** Skids' rule is that nothing
  on it initiates upward ([ADR-0102](0102-bridge-the-vtech-monitor-into-home-assistant-from-a-pi-on-skids.md)
  decision 1). A kiosk has to fetch its page from `trinity`, so it would need
  an upward pass, and Skids would no longer be the segment that starts nothing.
  Hicks already carries the passes the screen needs.
- **A Home Assistant dashboard as the screen.** It suits the household half,
  but the estate's figures live in Prometheus. Carrying them into Home
  Assistant to show them would be a second copy of the monitoring data.
- **Grafana in kiosk mode, or a playlist.** Good for one trend graph, poor for
  a calendar and a lock state. It can still be one panel on the wall page.
- **MagicMirror², Dashy, DAKboard and similar.** Each is a third look beside
  Glance and Grafana and a third copy of data already collected. DAKboard
  also puts the household's calendar on a vendor's server.
- **A Glance page styled for the television.** Glance's theme is set once for
  the whole instance (`theme:` in `glance.yml`), so restyling one page for the
  wall would restyle the start page too.
- **Ethernet.** It means a cable along the raceway from the rack in the alcove
  to the front wall. At −45 dBm, Wi-Fi does not need it. It stays the fix if
  the link proves unreliable.

## Consequences

- **The second pass from Winterfell into Hicks,** after ADR-0112's echo
  requests to the eeros. `node_exporter` answers unauthenticated, so anything
  on Hicks can read the Pi's metrics. That is the same residual as
  `smaug`'s on CasaBonita (`docs/security.md`), and it discloses only the Pi's
  own counters.
- **The office shows the household's day.** Anyone in the room can read the
  screen. The webcam faces the chair, and the television is behind it, so the
  screen never appears on a call.
- **The Pi is on the trusted segment.** It runs a browser all day, so the
  browser and the OS take updates unattended, and SSH accepts keys only. A
  compromised Pi is a host on Hicks, no more and no less, which is why it
  holds nothing.
- **Not yet verified:** the HDMI output, the kiosk on the television, and
  whether the 2014 television obeys CEC. The micro-HDMI cable arrives after
  this ADR. The runbook's steps record each when it is done, and the
  changelog records the CEC result.
- **Reopened by:** the wall page needing a source that a server-side token
  cannot serve, a second screen elsewhere in the house, or Hicks being
  narrowed so the screen's passes no longer apply.
