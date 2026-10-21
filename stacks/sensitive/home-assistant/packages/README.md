# Home Assistant packages

[![part of stacks/sensitive](https://img.shields.io/badge/part%20of-stacks%2Fsensitive-30363d?style=plastic)](../../../../stacks/sensitive/README.md)
[![Home Assistant](https://img.shields.io/badge/Home%20Assistant-18BCF2?style=plastic&logo=homeassistant&logoColor=white)](https://www.home-assistant.io)

Every `*.yaml` in this directory is loaded by `configuration.yaml`'s
`packages: !include_dir_named packages` and mounted read-only into the
container at `/config/packages`. Automations, scripts, scenes, template
sensors — anything beyond the core configuration — is a file here, in git,
and nothing else. This README is not YAML and Home Assistant ignores it.

| Package | What it adds |
| --- | --- |
| `attention.yaml` | A *Get attention* script: it blinks the lights labelled `attention_lights` and announces on the Echo labelled `attention_speaker`, unless that Echo is on do not disturb. The labels are set in the UI, so no owner-linked room is named here |
| `bedtime.yaml` | A bedtime script (shared rooms off, bedroom dimmed warm, white-noise machine on) and an optional timer for it, whose time and on/off switch are set in the UI |
| `eero.yaml` | Each eero unit's status from its DHCP renewals in Loki, keyed by its reserved address, with an alert when one has not renewed in two hours. No eero API, no firewall rule (#1228) |
| `homelab_rack.yaml` | The rack's power draw for the Energy dashboard, read from the UPS's load through Prometheus rather than from the card directly, plus the UPS's on-battery state and runtime remaining for the dashboard. Paging stays with Alertmanager's `UpsOnBattery` |
| `lighting.yaml` | `light.evening_lights`, a group of the shared rooms' Hue lights, on fifteen minutes before sunset and off at sunrise |
| `mediatv.yaml` | The LG TV's power-on: the webOS integration's *turn on* trigger sends a unicast magic packet to `10.0.40.40` (ADR-0097), with the MAC from SOPS |
| `roomba.yaml` | *Roomba: start / stop / dock* scripts that ask the living-room Echo, through `alexa_devices.send_text_command`, to drive the Roomba 105 linked in Alexa. The core `roomba` integration does not support x05 models. One-way, cloud, with phrases editable in the UI |
| `thermostat.yaml` | Thermostat alerts, no control: the hallway too cold or hot, humidity out of range, emergency heat switched on, the thermostat gone from Honeywell's cloud, or its gateway gone from the network (from its DHCP renewals in Loki). Each condition is a template binary sensor, so a restart does not lose it. Alerts go to phones labelled `household_phones` and to Home Assistant's notifications. The thermostat keeps its own schedule |

There is no `automations.yaml`. The UI automation editor writes that file into
`/config` and needs `automation: !include automations.yaml` to load it, and
that include fails hard on a file that does not exist yet — which on a fresh
volume it never does, because this repository ships the configuration and
Home Assistant only writes the file when it ships its own. So automations are
authored here, reviewed like every other config, and the UI editor is not
used. Devices and integrations are still added through the UI: a config flow
has no YAML form, and what it produces lands in `/config/.storage`, which is
state, not configuration — `compose.yaml` says where that leaves the
credentials.

Only the shared rooms are named in these files. [`docs/security.md`](../../../../docs/security.md#what-this-repository-deliberately-does-not-publish)
keeps owner-linked device names, a child's room and camera-to-room mapping out
of the repository, so an automation that needs one of those is a UI-side
setting (a label, an area or a helper) that a package here reads, not an
entity id written here.
