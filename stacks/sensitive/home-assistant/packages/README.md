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
| `homelab_rack.yaml` | The rack's power draw for the Energy dashboard, read from the UPS's load through Prometheus rather than from the card directly |

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
