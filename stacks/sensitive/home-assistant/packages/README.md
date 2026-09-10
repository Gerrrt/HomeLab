# Home Assistant packages

Every `*.yaml` in this directory is loaded by `configuration.yaml`'s
`packages: !include_dir_named packages` and mounted read-only into the
container at `/config/packages`. Automations, scripts, scenes, template
sensors — anything beyond the core configuration — is a file here, in git,
and nothing else. This README is not YAML and Home Assistant ignores it; it
exists so the directory does.

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
