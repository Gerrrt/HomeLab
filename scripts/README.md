# scripts

[![Bash](https://img.shields.io/badge/Bash-4EAA25?style=plastic&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Python](https://img.shields.io/badge/Python-3776AB?style=plastic&logo=python&logoColor=white)](https://www.python.org)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-clean-4EAA25?style=plastic)](lint.sh)
[![entry point](https://img.shields.io/badge/entry%20point-make%20help-30363d?style=plastic)](../Makefile)

Everything the repository *does*, as opposed to what it describes. Almost
nothing here is meant to be run directly: the [`Makefile`](../Makefile) is the
interface (`make help` lists it), and the systemd units under
[`systemd/`](../systemd/README.md) run the scheduled half through
`run-scheduled.sh`. Each script's header says why it exists and what it
deliberately does not do, and that header is the documentation. This page is
the map.

Two conventions hold across all of them:

- **Images come from `compose.yaml`, by way of `image-for.sh`.** A `docker run`
  that names its image anywhere else fails `check_image_pins.py`, so a script
  can only run an image that Dependabot can see and that has a pinned digest.
- **Python's one third-party module is PyYAML, and it is pinned.** Every
  script takes it from `_deps.py`: the host's `python3-yaml`, or on a CI runner
  the hash-pinned `requirements.txt`. Nothing runs `pip install` on a host.
- **A check that cannot run says SKIP, not PASS.** `validate.sh` counts the
  skips and prints them at the end, because a skipped check proves nothing.

## Validate: what CI runs

`validate.sh` runs every row here except the last four. CI runs the first three
of those as a job and workflows of their own. The fourth runs on `phoenix`,
and only its fixtures run in CI, through `self-tests.sh`.

| Script | `make` | Checks |
| --- | --- | --- |
| `validate.sh` | `validate` | Everything in this table that does not need a live host, in CI's order |
| `lint.sh` | `lint` | yamllint, markdownlint, shellcheck, ruff, actionlint, zizmor, editorconfig-checker, ansible-lint, `tofu fmt` and `packer fmt` — the one list all three callers share |
| `check_docs.py` | `check-docs` | The prose against the configs: counted claims, inventories, ports, ADR numbering, the buy list ([ADR-0026](../docs/adr/0026-check-the-documents-where-the-truth-is.md)) |
| `check_dashboards.py` | `check-dashboards` | Dashboard JSON, datasource references, every panel's PromQL |
| `check_rule_tests.py` | `check-rules` | Every Prometheus alert has a promtool test that names it |
| `check_loki_rules.sh` | `check-loki-rules` | The LogQL rules and dashboard queries, against a real Loki boot |
| `check_syslog_senders.sh` | `check-syslog-senders` | The syslog listener stores only the senders `syslog.alloy` names, and a message cannot choose its own `host` (#844) |
| `check_compose_health.py` | `check-compose-health` | Every `depends_on: service_healthy` can actually be satisfied |
| `check_caddyfile.sh` | — | Every stack's Caddyfile, validated by the pinned Caddy |
| `check_image_pins.py` | `check-image-pins` | Every image the repository runs comes from a `compose.yaml`, and an image that mounts another stack's config runs that stack's exact pin |
| `check_sops_rules.py`, `check-sops-encrypted.sh` | — | `.sops.yaml` matches its files, and every committed SOPS file is ciphertext |
| `check-tracked-artefacts.sh` | — | Nothing rendered, decrypted or secret-bearing is tracked |
| `check_dashboard_roundtrip.sh` | `check-dashboard-roundtrip` | `make dashboards-export` still round-trips, without a live stack |
| `self-tests.sh` | — | Every fixture suite embedded in the scripts above |
| `seed-validation-env.sh` | — | A throwaway `.env` that satisfies `${VAR:?}` guards, so `docker compose config` can run |
| `check_hardened_boot.sh` | `check-hardened-boot` | Boots a service under its real hardening and waits for healthy — CI's *Boot hardened services* job |
| `check_close_keywords.py` | — | No close keyword sits in prose that says the issue stays open — the *Close keywords* workflow; `--text FILE` lints a draft |
| `check_tool_versions.py` | — | The Packer plugin and Galaxy collection pins, against upstream's newest release — weekly in the *Digest drift* workflow |
| `check-tofu-state-encryption.sh` | — | `tofu/`'s state is encrypted, proved rather than assumed — run on `phoenix`; its fixtures run in `self-tests.sh` |

## Deploy and converge

| Script | `make` | Does |
| --- | --- | --- |
| `render-config.sh` | `render` | Decrypts a stack's secrets and renders the config files that cannot take environment variables |
| `secrets-env.sh` | — | Sourced, not run: a stack's SOPS file as shell variables |
| `converge.sh` | `converge` | Fetches `main`, refuses it unless GitHub signed it and CI passed, fast-forwards and runs `make up` ([ADR-0021](../docs/adr/0021-converge-on-a-timer-instead-of-deploying-over-ssh.md)) |
| `record-applied.sh` | via `up` | Records the revision `make up` applied, so converge can tell a hand edit from a deploy |
| `reload-config.sh` | `reload` | Hot-reloads Prometheus, Alertmanager and snmp-exporter |
| `check_mounted_config.py`, `check_container_health.py`, `check_alert_channels.py` | via `up` | After a deploy: each container runs the repo's config, its healthcheck passes, and Alertmanager can read every receiver URL |
| `seed-ha-http.sh`, `seed-actual-password.sh` | via `up` | First-start state for Home Assistant and Actual, written before anything can reach them |
| `deploy-agent.sh` | `deploy-agent` | Deploys the Alloy agent on a monitored host, with no privilege on the target |
| `install-timers.sh` | `install-timers`, `check-timers` | The schedule, and the staleness each job's alert allows — see [`systemd/`](../systemd/README.md) |
| `install-agent-collectors.sh` | `install-agent-collectors` | The textfile collectors on an agent host. Run by hand, once per host, with a TTY for its sudo prompt |
| `run-scheduled.sh` | — | Runs a job under a lock and records its outcome as `homelab_job_*` metrics |
| `stacks.sh`, `compose-guards.sh`, `image-for.sh` | — | The list of stacks, a stack's required variables, and a service's pinned image — each defined once |
| `pin-digests.sh` | `pin-digests`, `check-digests` | Re-resolves every image digest, or checks they still match the registry |
| `prune-images.sh` | `prune-images` | Removes Docker images no container uses |

## Secrets, keys and certificates

| Script | `make` | Does |
| --- | --- | --- |
| `bootstrap.sh` | `secrets-init` | A new host's age keypair, its `.sops.yaml` rule, and the encrypted file |
| `secrets-edit.sh` | `secrets-edit` | Edits secrets without the editor leaving a plaintext copy behind |
| `add-recipient.sh`, `remove-recipient.sh` | `secrets-add-recipient`, `secrets-remove-recipient` | A second age recipient in, or out, and a re-key ([ADR-0024](../docs/adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)) |
| `key-recipients.sh` | `recipient-state` | Who can open each stack's secrets, and when each was last proved |
| `verify-key-backup.sh` | `secrets-verify-backup` | Proves a backup age key decrypts the secrets |
| `gen-certs.sh` | `certs` | The estate's internal CA and the leaves it signs |
| `tier-ca.sh` | `tier-ca` | The sensitive tier's own CA ([ADR-0037](../docs/adr/0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md)) |
| `ca-key-state.sh`, `verify-ca-key-backup.sh` | `ca-key-state`, `certs-verify-backup` | Which key the CA signs with, and proof an offline copy is that key |
| `gen-secret.sh` | `gen-secret` | Random secrets, one per SNMP device with `--snmp` |
| `purge-history.sh` | `purge-history-dry-run` | Removes committed secrets from the entire history ([runbook](../docs/runbooks/purge-git-history.md)) |

## Backups and copies that leave the house

| Script | `make` | Does |
| --- | --- | --- |
| `backup-volumes.sh` | `backup` | Quiesces the observability stack, archives, encrypts and verifies its volumes, and copies them to `oracle` |
| `restore-volumes.sh` | `restore` | Puts a backup set back |
| `backup-firewall.sh` | `backup-firewall` | `morpheus`'s pfSense config, encrypted at rest and copied off-host |
| `backup-nas.sh` | `backup-nas` | The media tier's state, pulled from `smaug`'s newest snapshot ([ADR-0045](../docs/adr/0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md)) |
| `backup-wiki.sh` | `backup-wiki` | A dump of the wiki's database, pulled off `oracle` ([ADR-0065](../docs/adr/0065-pull-the-wikis-database-to-prometheus-as-a-dump.md)) |
| `backup-library.sh` | `backup-library` | Immich's library, archived on `trinity` and copied to `oracle` ([ADR-0064](../docs/adr/0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)) |
| `backup-offsite.sh` | `backup-offsite` | The newest set of each kind onto the medium that leaves the estate ([ADR-0048](../docs/adr/0048-carry-the-estates-backup-sets-with-the-second-recipient.md)) |
| `carry-household-copy.sh`, `household-recipients.sh` | `household-copy`, `household-proof` | The household's photos and documents onto the holder's drive, and who can open it ([ADR-0073](../docs/adr/0073-carry-the-household-copy-on-a-drive-the-holder-keeps.md)) |
| `medium.sh` | — | Sourced by both of the above: the refusals that stop a "medium" being this host in disguise |

## Collectors: state as metrics

Each writes a `.prom` file for the node exporter's textfile collector, so a
fact becomes something an alert can watch. Some run on the monitoring host
from a `make` target, and reach `morpheus` over SSH where that is the host
they describe. The rest are installed on the host they describe by
`install-agent-collectors.sh`, which knows which host can run which.

| Script | Reports |
| --- | --- |
| `collect-patch-state.sh`, `collect-pkg-state.sh` | How far behind packages are — a Linux host's apt, and `morpheus`'s pkg |
| `collect-smart-state.sh`, `render-smart-baselines.sh` | SMART health for disks the iLO cannot see, and the known reallocated-sector baselines ([ADR-0046](../docs/adr/0046-record-a-known-static-smart-count-as-a-baseline-not-a-silence.md)) |
| `collect-zpool-state.sh`, `collect-truenas-version.sh` | `smaug`'s pool leaves and TrueNAS version |
| `collect-gateway-state.sh` | The firewall's view of its uplinks and its DDNS record |
| `collect_silences.py` | Alertmanager's silences, one series each, so a silence is watched rather than remembered |
| `collect-container-state.sh` | Whether each container of a compose project is running |
| `collect-guest-state.sh`, `collect-guest-disk-state.sh`, `collect-thin-pool-state.sh` | `Saruman`'s guests: running, how full, and how full its thin pools are |
| `collect-pve-version.sh`, `collect-pve-firewall-state.sh` | The Proxmox version, and whether its firewall is on |
| `collect-iso-store-state.sh` | Whether the ISOs on the NFS store are the ones the repository expects |
| `collect-zeek-mirror-state.sh`, `zeek-mirror.sh` | The `tc` mirror to the Zeek sensor: build it, and whether it carries packets ([ADR-0068](../docs/adr/0068-mirror-the-lab-bridge-to-zeek-with-tc-not-open-vswitch.md)) |
| `collect-pbs-task-state.py` | What `golem`'s Proxmox Backup Server last did: verify, prune and garbage-collection outcomes, and its snapshots by verify state and encryption ([ADR-0053](../docs/adr/0053-run-pbs-on-saruman-with-its-datastore-on-smaug-over-nfs.md)) |
| `collect-drift-check.sh` | The wiki's drift check and what it found |
| `mark-clean-shutdown.sh` | Clean stops by kind, so a disk-fault page can tell a power cut from a shutdown |

## Live-host checks

They need the running estate, so CI cannot run them. Timers do.

| Script | `make` | Checks |
| --- | --- | --- |
| `check_firewall_claims.py` | `check-firewall` | [`docs/firewall-claims.yaml`](../docs/firewall-claims.yaml) against the live pfSense ruleset |
| `check_loki_coverage.py` | `check-loki-coverage` | No Loki rule is blind to a host whose logs it would match |
| `check_versions.py` | `check-versions` | The OS versions the documents claim against what the hosts report |
| `check-ruleset.sh` | `check-ruleset`, `apply-ruleset` | The ruleset on `main` against [`.github/rulesets/main.json`](../.github/OVERVIEW.md) |
| `snmp-verify.sh`, `snmp-walk.sh` | `snmp-verify`, `snmp-walk` | Each SNMP device answers its current credential; walk one subtree the way the exporter would |
| `snmp-targets.sh`, `snmp-auth.sh`, `snmp-mibs.sh`, `snmp-generate.sh` | `snmp-generate`, `snmp-mibs` | The SNMP inventory and auth blocks, read once; the vendor MIBs `generator.yaml` needs; and the regeneration of `snmp.yaml` from them |

## Dashboards and the lab

| Script | `make` | Does |
| --- | --- | --- |
| `export-dashboards.sh`, `export_dashboards.py` | `dashboards-export` | Folds UI edits in the running Grafana back over the committed JSON |
| `capture-screenshots.sh` | `screenshots` | Renders the dashboards into [`docs/images/`](../docs/images/README.md) |
| `packer-smoke.sh` | — | Clones a Packer template, boots it, checks it and destroys it ([`packer/`](../packer/README.md)) |
| `gen_population.py` | — | The lab domain's users, into `ansible/population/` |
| `vendor-ja4.sh` | — | Vendors the JA4+ Zeek scripts at one commit ([ADR-0069](../docs/adr/0069-vendor-the-ja4-scripts-into-the-sensor-stack-rather-than-build-an-image.md)) |
| `vendor-sysmon-config.sh` | — | Vendors sysmon-modular's Sysmon config from one release, or `--check`s it ([ADR-0080](../docs/adr/0080-record-the-lab-domain-with-sysmon-and-capture-on-demand-with-pktmon.md)) |

## Adding a script

- **Give it a `make` target** with a `##` comment, so `make help` lists it.
- **Write the header first:** what it does, why it is a script rather than a
  step somewhere else, and what it refuses to do.
- **It passes `make lint`.** That means shellcheck for shell, and
  editorconfig for everything.
- **If it runs on a schedule, it goes through `run-scheduled.sh`.** It also
  needs a row in `install-timers.sh` and a unit pair under `systemd/`;
  `make check-timers` fails until all three agree.
- **If it is a check, give it fixtures** that `self-tests.sh` runs, so the
  check is itself checked.
