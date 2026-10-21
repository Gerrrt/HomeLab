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
| `bedtime.yaml` | The adults' bedtime script (shared rooms off, bedroom dimmed warm) and an optional timer for it, whose time and on/off switch are set in the UI |
| `doorbell.yaml` | When the event entity labelled `doorbell` rings: the phones, a pop-up on the TV when it is on, and every Echo outside quiet hours (helpers, 20:00–07:00 until set). The label is checked at each ring, so assigning it needs no restart, and no door is named here |
| `eero.yaml` | Each eero unit's status from its DHCP renewals in Loki, keyed by its reserved address, with an alert when one has not renewed in two hours. No eero API, no firewall rule (#1228) |
| `homelab_rack.yaml` | The rack's power draw for the Energy dashboard, read from the UPS's load through Prometheus rather than from the card directly, plus the UPS's on-battery state and runtime remaining for the dashboard. Paging stays with Alertmanager's `UpsOnBattery` |
| `kid_bedtime.yaml` | The child's bedtime: from 19:00 the room's sleep scene dims to 25% and the white noise rises from 30% to 80% with a green night light; at 19:45 lights out and the night light red. Rooms through the labels `kid_room_lights` and `kid_room_sleep_scene`; a pause switch skips it |
| `lighting.yaml` | `light.evening_lights`, a group of the shared rooms' Hue lights, on fifteen minutes before sunset and off at sunrise |
| `litter_robot.yaml` | Litter-Robot reminders with *Done* / *Remind me tomorrow* buttons, every two daytime hours while the drawer is full or the litter low, and cat-health alerts: a cat's two-day weight 8% under its nine-day baseline, or no visit by 21:00. Buttons need the phones' notify services in `input_text.household_phone_services` |
| `mediatv.yaml` | The LG TV's power-on: the webOS integration's *turn on* trigger sends a unicast magic packet to `10.0.40.40` (ADR-0097), with the MAC from SOPS |
| `movie_mode.yaml` | When the TV comes on after dark with the TV room lit, the room goes to its Hue *Mood* scene. A minute after the TV goes off, the lights are restored from a snapshot |
| `night_brightness.yaml` | From 20:00 to 06:00, a Hue light a person turns on is held to 25%, never one an automation, a script or an automation-recalled scene turns on. A pause switch turns it off |
| `ring_push_guard.yaml` | Loads `custom_components/ring_push_guard`, our patch that keeps the Ring push receiver alive on pushes without a `ding.id` (ADR-0101). To be deleted with the component when a fixed `ring_doorbell` ships (#1240) |
| `roomba.yaml` | *Roomba: start / stop / dock* scripts that ask the living-room Echo, through `alexa_devices.send_text_command`, to drive the Roomba 105 linked in Alexa. The core `roomba` integration does not support x05 models. One-way, cloud, with phrases editable in the UI |
| `thermostat.yaml` | Thermostat alerts, no control: the hallway too cold or hot, humidity out of range, emergency heat switched on, the thermostat gone from Honeywell's cloud, or its gateway gone from the network (from its DHCP renewals in Loki). Each condition is a template binary sensor, so a restart does not lose it. Alerts go to phones labelled `household_phones` and to Home Assistant's notifications. The thermostat keeps its own schedule |
| `tv_room_evening.yaml` | At 19:00 the TV comes on with Prime Video open and the TV room at its Mood scene; at 21:00 a bedtime nudge on the living-room Echo and the TV. A pause switch skips both |

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
