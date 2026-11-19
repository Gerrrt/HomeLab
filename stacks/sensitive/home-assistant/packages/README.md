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
| `presence.yaml` | Follows `zone.home`: indoor cameras' Ring motion detection (label `indoor_camera_motion`) off while anyone is home; ten minutes after everyone leaves, dimmable lights off and the thermostat to away; first one home, the schedule back and, after dark, the shared rooms lit. *Someone else is home* pauses the comings and goings |
| `ring_push_guard.yaml` | Loads `custom_components/ring_push_guard`, our two patches that keep the Ring push receiver alive: on pushes without a `ding.id` in `ring_doorbell` (ADR-0101), and on two-parameter Web Push headers in `firebase_messaging` (ADR-0110). Each patch goes when its fixed library ships (#1240, #1383), and this file with the component once both have gone |
| `pyatv_scan_guard.yaml` | Loads `custom_components/pyatv_scan_guard`, our patch to pyatv 0.18.0's scan by address, which asks a HomePod only for a service it does not answer, so the Apple TV integration cannot add or reconnect to one (ADR-0113). It goes, with this file, when a fixed pyatv ships (#1393) |
| `roomba.yaml` | *Roomba: start / stop / dock* scripts that ask the living-room Echo, through `alexa_devices.send_text_command`, to drive the Roomba 105 linked in Alexa. The core `roomba` integration does not support x05 models. One-way, cloud, with phrases editable in the UI |
| `thermostat.yaml` | Thermostat alerts, no control: the hallway too cold or hot, humidity out of range, emergency heat switched on, the thermostat gone from Honeywell's cloud, or its gateway gone from the network (from its DHCP renewals in Loki). Each condition is a template binary sensor, so a restart does not lose it. Alerts go to phones labelled `household_phones` and to Home Assistant's notifications. The thermostat keeps its own schedule |
| `tv_room_evening.yaml` | At 19:00 the TV comes on with Prime Video open and the TV room at its Mood scene; at 21:00 a bedtime nudge on the living-room Echo and the TV. A pause switch skips both |
| `wall_calendar.yaml` | `sensor.wall_today`: the next seven days' events, asked of `calendar.get_events` every five minutes, for the office wall's Today panel, its week below tomorrow and the header's *Up next* (ADR-0119). The calendars are those labelled `wall_calendar` in the UI, or all of them when none is labelled, so no calendar is named here. Unavailable, not empty, when a calendar cannot be read |
| `wall_house.yaml` | `sensor.wall_alarm`, `binary_sensor.wall_office_lights` and `sensor.wall_litter` for the office wall (ADR-0119): the house's one alarm panel's mode, and whether any light whose id contains `office` is on. Their own ids name the city and a person, so the wall reads these instead. Unavailable when nothing matches. `sensor.wall_litter` is `ok` or `attention`, with what in `needs`: the drawer at 90%, the litter under 30% or a cat's weight dropping, `litter_robot.yaml`'s thresholds |
| `wall_commute.yaml` | `sensor.wall_commute` for the office wall's context card (ADR-0119): the minutes of the quickest live-traffic route from the home zone to the next timed event within three hours, on a calendar labelled `wall_commute` in the UI, whose location looks like a place (a digit or a comma, and not Teams, Zoom, Meet, Webex or a link), and when to leave, five minutes ahead. Asked of `waze_travel_time.get_travel_times` every five minutes, only while there is such an event; the Waze Travel Time integration has to be added once in the UI for the action to exist. Sends that location to Waze. `none` when there is nothing to drive to |
| `wall_deliveries.yaml` | `sensor.wall_deliveries` for the office wall's context card (ADR-0119): the 17TRACK packages delivered today, ready to be picked up or undelivered, by their own labels, and how many are in transit. Asked of `seventeentrack.get_packages` every fifteen minutes. Never the tracking numbers. Unavailable until the 17TRACK integration is added |
| `wall_shabbat.yaml` | `sensor.wall_shabbat` for the office wall's context card (ADR-0119): the upcoming candle lighting as its state, with havdalah, the parsha, the Hebrew date and any Yom Tov's name, from the Jewish Calendar integration's entities, found by what their ids end with. Unavailable until that integration is added |
| `wall_todo.yaml` | `sensor.wall_todo` for the office wall's context card (ADR-0119): the open items, title and due date, of the to-do lists labelled `wall_todo` in the UI, asked of `todo.get_items` every minute. Unavailable while no list carries the label |
| `wall_trash.yaml` | `sensor.wall_trash` for the office wall's context card (ADR-0119): the next pickup date and whether recycling goes with it, from three helpers set in the UI (`input_select.trash_pickup_day`, `input_select.recycling_schedule`, `input_datetime.recycling_reference_date`). No integration; a holiday that moves a pickup is not known. Unavailable until the pickup day is set |
| `wall_weather.yaml` | `sensor.wall_weather` for the office wall's header (ADR-0119): today's high and low, the first of the next six hours with rain or snow, and `sun.sun`'s next sunrise and sunset. Asked of `weather.get_forecasts` on `weather.forecast_home` every fifteen minutes, because a forecast is an action's answer, not an attribute. Unavailable only when neither the daily nor the hourly forecast answers; with no daily entry for today, the state is `none` and the rain and sun still come through |

Home Assistant reads these files only when it starts, and the directory is
mounted as a whole, so a changed package is visible inside the container at
once and loaded by nothing. `make up` therefore restarts Home Assistant on every
deploy of this stack (`scripts/reload-config.sh`, `restart_home_assistant`). A
package change takes effect on the next converge or `make up`, with no restart
by hand, at the cost of about a minute without automations on each deploy.

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
