<div align="center">

# HomeLab

**A segmented home network and its observability stack, managed as code.**

[![CI](https://img.shields.io/github/actions/workflow/status/Gerrrt/HomeLab/ci.yml?branch=main&style=plastic&logo=githubactions&logoColor=white&label=CI)](https://github.com/Gerrrt/HomeLab/actions/workflows/ci.yml)
[![Digest drift](https://img.shields.io/github/actions/workflow/status/Gerrrt/HomeLab/digests.yml?branch=main&style=plastic&logo=githubactions&logoColor=white&label=Digest%20drift)](https://github.com/Gerrrt/HomeLab/actions/workflows/digests.yml)
[![CVE scan](https://img.shields.io/github/actions/workflow/status/Gerrrt/HomeLab/cve-scan.yml?branch=main&style=plastic&logo=githubactions&logoColor=white&label=CVE%20scan)](https://github.com/Gerrrt/HomeLab/actions/workflows/cve-scan.yml)
[![Last commit](https://img.shields.io/github/last-commit/Gerrrt/HomeLab/main?style=plastic&logo=git&logoColor=white&label=last%20commit)](https://github.com/Gerrrt/HomeLab/commits/main)
[![Open issues](https://img.shields.io/github/issues/Gerrrt/HomeLab?style=plastic&logo=github&logoColor=white&label=open%20issues)](https://github.com/Gerrrt/HomeLab/issues)
[![Dependabot](https://img.shields.io/badge/Dependabot-enabled-025E8C?style=plastic&logo=dependabot&logoColor=white)](.github/dependabot.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=plastic)](LICENSE)

[![pfSense](https://img.shields.io/badge/pfSense-212121?style=plastic&logo=pfsense&logoColor=white)](https://www.pfsense.org)
[![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-E57000?style=plastic&logo=proxmox&logoColor=white)](https://www.proxmox.com/en/proxmox-virtual-environment)
[![TrueNAS](https://img.shields.io/badge/TrueNAS-0095D5?style=plastic&logo=truenas&logoColor=white)](https://www.truenas.com)
[![Ubuntu Server](https://img.shields.io/badge/Ubuntu%20Server-E95420?style=plastic&logo=ubuntu&logoColor=white)](https://ubuntu.com/server)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-2496ED?style=plastic&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![WireGuard](https://img.shields.io/badge/WireGuard-88171A?style=plastic&logo=wireguard&logoColor=white)](https://www.wireguard.com)

[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=plastic&logo=prometheus&logoColor=white)](https://prometheus.io)
[![Alertmanager](https://img.shields.io/badge/Alertmanager-E6522C?style=plastic&logo=prometheus&logoColor=white)](https://prometheus.io/docs/alerting/latest/alertmanager/)
[![snmp_exporter](https://img.shields.io/badge/snmp__exporter-E6522C?style=plastic&logo=prometheus&logoColor=white)](https://github.com/prometheus/snmp_exporter)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/grafana/)
[![Loki](https://img.shields.io/badge/Loki-F5A800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/loki/)
[![Alloy](https://img.shields.io/badge/Alloy-F46800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/alloy-opentelemetry-collector/)

[![SOPS](https://img.shields.io/badge/SOPS-6f42c1?style=plastic)](https://github.com/getsops/sops)
[![age](https://img.shields.io/badge/age-6f42c1?style=plastic)](https://github.com/FiloSottile/age)
[![Suricata](https://img.shields.io/badge/Suricata-EF7F1A?style=plastic)](docs/runbooks/enable-suricata.md)
[![Zeek](https://img.shields.io/badge/Zeek-0a4d84?style=plastic)](stacks/sensor)
[![Wazuh](https://img.shields.io/badge/Wazuh-3595F7?style=plastic)](stacks/soc)
[![Velociraptor](https://img.shields.io/badge/Velociraptor-4b7b4b?style=plastic)](stacks/soc)
[![Caddy](https://img.shields.io/badge/Caddy-1F88C0?style=plastic&logo=caddy&logoColor=white)](https://caddyserver.com)
[![step-ca](https://img.shields.io/badge/step--ca-2b3a8c?style=plastic)](https://smallstep.com/docs/step-ca/)
[![gitleaks](https://img.shields.io/badge/gitleaks-d73a49?style=plastic)](https://github.com/gitleaks/gitleaks)

[![OpenTofu](https://img.shields.io/badge/OpenTofu-FFDA18?style=plastic&logo=opentofu&logoColor=black)](tofu)
[![Packer](https://img.shields.io/badge/Packer-02A8EF?style=plastic&logo=packer&logoColor=white)](packer)
[![Ansible](https://img.shields.io/badge/Ansible-EE0000?style=plastic&logo=ansible&logoColor=white)](ansible)
[![Home Assistant](https://img.shields.io/badge/Home%20Assistant-18BCF2?style=plastic&logo=homeassistant&logoColor=white)](stacks/sensitive)
[![Jellyfin](https://img.shields.io/badge/Jellyfin-00A4DC?style=plastic&logo=jellyfin&logoColor=white)](stacks/media)
[![Immich](https://img.shields.io/badge/Immich-4250AF?style=plastic&logo=immich&logoColor=white)](stacks/sensitive)

[Start here](docs/runbooks/successor-handover.md) ·
[Architecture](docs/architecture.md) ·
[Network](docs/network.md) ·
[Observability](docs/observability.md) ·
[Security](SECURITY.md) ·
[Runbooks](docs/runbooks) ·
[Decisions](docs/adr) ·
[Roadmap](docs/roadmap.md)

</div>

---

Six VLANs and the untagged switch-management LAN behind a pfSense firewall,
default-deny between every segment, with a Prometheus/Loki/Grafana stack
watching all of it. Every config in this
repository is the config that runs, validated on every push.

It started as a place to practise security work and turned into the network the
house actually depends on, which changed the requirements considerably — a
broken experiment is a learning opportunity, a broken DHCP server is a domestic
incident.

**Arriving without the context?**
[`docs/runbooks/successor-handover.md`](docs/runbooks/successor-handover.md) is
the front door: what this estate is, what to check on day one and in what order,
what fails soonest if nobody touches anything, where the secrets are and what is
needed to decrypt them, and what can be switched off. **This repository is the
operator-facing documentation** — the wiki on `oracle` is the household's, and
[ADR-0011](docs/adr/0011-keep-the-wiki-internal.md) is why they are different
documents for different readers.

## Highlights

- **Network segmented by trust, not by function.** Six VLANs; IoT, media and
  guest segments are terminal **outward** — nothing on them initiates anywhere
  else, and each carries a tripwire that logs anything which gets past that.
  Inbound is a separate question, answered one host at a time: since
  2026-09-16 more-trusted segments reach `smaug` on CasaBonita on named ports,
  so the televisions can have a media server without the segment ceasing to be
  terminal in the direction that matters
  ([ADR-0016](docs/adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)),
  and since 2026-09-28 Home Assistant reaches the Hue bridge on Skids and
  nothing else there
  ([ADR-0035](docs/adr/0035-scope-the-99-to-20-rule-to-the-hue-bridge.md)).
  Default deny holds everywhere except the trusted workstation segment and the
  switch LAN, both of which are listed rather than counted.
  [Why](docs/adr/0013-segment-access-as-implemented.md)
- **Full observability pipeline for a mixed estate.** Grafana Alloy agents push
  metrics and logs from Linux hosts; `snmp_exporter` polls the four devices that
  can't run an agent (firewall, switch, UPS, iLO). One agent config, deployed
  identically everywhere. [How](docs/architecture.md#observability-data-flow)
- **Dashboards and alerting as code.** 8 provisioned dashboards, 156 panels, and
  165 alert rules — 146 metric-based in Prometheus, 19 log-based in Loki — sharing
  one Alertmanager routing tree. No dashboard exists only in a database.
- **Secrets encrypted in-repo with SOPS + age.** Per-device credentials,
  decrypted at deploy time into gitignored paths, with `git log` showing which
  credential rotated and when — but never to what.
  [Why](docs/adr/0005-secrets-with-sops-and-age.md)
- **CI that actually validates the infrastructure.** `docker compose config`,
  `promtool`, `amtool`, `alloy fmt`, a real Loki boot to parse the LogQL rules,
  dashboard-JSON and datasource checks, every dashboard's PromQL parsed, plus
  `gitleaks` over the full history.
- **CI that validates the documentation too.** Eleven assertions cross-check
  this prose against the configs it describes — counted claims (rules,
  dashboards, panels, Alloy agents, VLANs, ADRs, runbooks), the SNMP
  inventory and the compute table against `docs/network.md`, the host/stack
  and ports tables against `compose.yaml`, ADR numbering, firewall posture
  against `docs/firewall-claims.yaml`, guest rows against each other, this
  file's outstanding-purchase count against the roadmap's buy table, every
  critical alert's `runbook_url` against the runbook and heading it names, and
  a ban on image versions in prose — Dependabot edits only `compose.yaml`, so
  a version written anywhere else is stale from the next bump. A document
  that disagrees with the repository fails the build. That opening count is
  now one of the claims, read from the check registry rather than kept by
  hand: it said six while ten ran, and the list beside it had been overtaken
  by four — drift in the sentence advertising that drift gets caught.
- **Supply chain pinned by digest.** Every image carries both a tag and a
  `sha256:` digest, so a moved tag cannot change what deploys. CI enforces it;
  `make pin-digests` re-resolves them from the registry. Every `docker run` in
  the Makefile, the scripts, the workflow and the runbooks resolves its image
  from `compose.yaml` too, so an image that is not pinned there cannot be run
  at all. Every pinned digest is also scanned weekly for fixable HIGH and
  CRITICAL CVEs, and each image with findings has an open issue until a scan
  finds it clean.
- **Documented decisions and runbooks.** 82 ADRs covering what was chosen
  and what was rejected — including the costs accepted knowingly; 46
  runbooks for the operations that are easy to get wrong at 1am, one of which
  is the handover page a successor reads first. Every critical alert links to
  one.

## Architecture

[![The home network: the ISP gateway in bridge mode, the pfSense firewall
morpheus, the core switch neo and the 9U rack across the top; below them one
panel per VLAN in its patch-cable colour, holding every addressed host —
Winterfell's monitoring, wiki and household hosts, Hicks' workstations by role,
CasaBonita's NAS and screens, ImaginationLAN's hypervisor and its ten guests,
Skids' IoT by class, and the guest
network.](docs/diagrams/current/network.svg)](docs/diagrams/current/network.svg)

<sub>Click for the full-resolution SVG. Drawn from
[`docs/network.md`](docs/network.md) and
[`docs/hardware.md`](docs/hardware.md); how to edit it is in
[`docs/diagrams/`](docs/diagrams/README.md).</sub>

Each panel's footer says what that segment reaches, and that is the short
version. Default deny holds for every segment except Hicks and the switch LAN,
both of which reach further than any picture of exceptions suggests.
[`network.md`](docs/network.md)'s *Reaches* column is the segment-level
summary. The host-scoped passes underneath it are in each segment's notes in
the same file, and the two together are the current state. Two examples:
`Saruman` reaching `prometheus` on 9090/3100, and `smaug` over NFS.
[ADR-0013](docs/adr/0013-segment-access-as-implemented.md) holds the method and
the reasoning, and describes the ruleset as it stood on 2026-09-01; the Hicks
interface was narrowed the day after. A count was the wrong instrument and this
README carried the wrong count for months. Segment colour matches the patch
cable in the rack. A dashed border means the segment is terminal outward:
nothing on it initiates a connection to another internal segment, though named
inbound passes may still reach it. Data flow and the maintained Mermaid topology are in
[`docs/architecture.md`](docs/architecture.md).

## Stack

| Layer | Tool | Where | Role |
| --- | --- | --- | --- |
| Firewall / routing | [pfSense on FreeBSD 16](docs/network.md) | `morpheus` | VLANs, Kea DHCP, Unbound, Suricata, NUT, default-deny, the one WireGuard `rdr` |
| Virtualisation | Proxmox VE | `Saruman` | Lab hypervisor; iLO on `shiva` |
| Storage | [TrueNAS 25.10](docs/runbooks/build-the-nas.md) | `smaug` | 2× 18 TB ZFS mirror `erebor`, the SMB share, and the Docker the media stack runs under |
| Media | [Jellyfin, Audiobookshelf, Navidrome](stacks/media) | `smaug` | Quick Sync transcoding on the NAS, audiobooks with synced progress and music over Subsonic ([#140](https://github.com/Gerrrt/HomeLab/issues/140), [#141](https://github.com/Gerrrt/HomeLab/issues/141)); the one stack deployed from TrueNAS rather than by `make deploy` |
| Household services | [Caddy, step-ca, Home Assistant, AdGuard Home, Immich, Paperless-ngx, Vaultwarden and more](stacks/sensitive) | `trinity` | The sensitive tier, behind its own CA, and the house's DNS filter |
| Wiki | [Wiki.js and Postgres](stacks/wiki) | `oracle` | The household's documentation, and the off-host backup copies |
| Metrics | [Prometheus](stacks/observability/prometheus) | `prometheus` | 30-day retention capped at 12 GiB, remote-write receiver |
| Logs | [Loki](stacks/observability/loki) | `prometheus` | Single-binary, filesystem storage |
| Collection | [Grafana Alloy](stacks/observability/alloy) | every Linux host but `smaug`, which is scraped through node_exporter instead | node + cAdvisor metrics, Docker/journal/syslog/auth logs |
| Network polling | [snmp_exporter](stacks/observability/snmp-exporter) | `prometheus` | pfSense, switch, UPS, iLO |
| Alerting | [Alertmanager](stacks/observability/alertmanager) | `prometheus` | Severity routing, inhibition |
| Visualisation | [Grafana](stacks/observability/grafana) | `prometheus` | 8 provisioned dashboards |
| Lab observability | [Prometheus, Loki, Grafana](stacks/lab) | `alexander` | The lab's own Prometheus; only liveness crosses to the estate's, never telemetry |
| Security tooling | [Wazuh, Velociraptor](stacks/soc) | `odin` | SIEM and endpoint forensics for the lab domain |
| Network sensor | [Zeek](stacks/sensor) | `fenrir` | East-west traffic on the lab bridge, from a `tc` mirror |
| Attack paths | [BloodHound CE](stacks/bloodhound) | `eden` | Which path to Domain Admin exists in the lab domain; not built yet, and off between sessions |
| Lab provisioning | [Packer](packer), [OpenTofu](tofu), [Ansible](ansible) | `phoenix` | VM templates, guests cloned from them, and the `ad.matrix.elysium` domain's configuration |
| Secrets | [SOPS + age](secrets) | in the repo | Encrypted in-repo, decrypted at deploy time |
| CI | [GitHub Actions](.github/workflows/ci.yml) | GitHub | Lint, config validation, secret scanning, digest pinning, [close keywords in prose](.github/workflows/close-keywords.yml) |

## Repository layout

```text
.
├── stacks/
│   ├── observability/        # the estate's stack on prometheus — ten services
│   │   ├── prometheus/       #   config, file_sd targets, 146 alert rules
│   │   ├── alertmanager/     #   routing and inhibition
│   │   ├── loki/             #   single-binary config + 19 LogQL rules
│   │   ├── alloy/            #   the agent config directory, shipped to every host
│   │   ├── snmp-exporter/    #   generator.yaml is the source of truth
│   │   └── grafana/          #   provisioning + 8 dashboards
│   ├── sensitive/            # the household's tier on trinity — its own CA,
│   │                         #   leaves over ACME (ADR-0034, ADR-0037)
│   ├── media/                # Jellyfin, Audiobookshelf and Navidrome on smaug,
│   │                         #   under TrueNAS's own Docker (ADR-0040)
│   ├── wiki/                 # Wiki.js on oracle (ADR-0011, ADR-0015)
│   ├── lab/                  # the lab's own stack on alexander — six services,
│   │                         #   never remote-writes to VLAN 99 (ADR-0020)
│   ├── soc/                  # Wazuh and Velociraptor on odin (ADR-0030)
│   ├── sensor/               # Zeek on fenrir, on a mirror of the lab bridge (ADR-0068)
│   ├── bloodhound/           # BloodHound CE on eden, off between sessions (ADR-0081)
│   └── scratch/              # a DISPOSABLE copy of soc on diabolos (ADR-0071)
├── packer/  tofu/  ansible/  # lab templates, guests and domain, run from phoenix
├── secrets/                  # SOPS-encrypted; see secrets/README.md
├── scripts/                  # bootstrap, render, validate, check_docs… — see its README
├── systemd/                  # the timers that back up, verify and converge — see its README
├── .github/                  # CI, Dependabot, the ruleset on main — see OVERVIEW.md
├── SECURITY.md               # disclosure policy and known exposure
├── docs/
│   ├── architecture.md  network.md  hardware.md
│   ├── observability.md  security.md  roadmap.md  changelog.md
│   ├── diagrams/             # the network diagram (SVG) and its predecessors
│   ├── adr/                  # 82 ADRs — architecture decision records
│   └── runbooks/             # 46 runbooks; successor-handover.md is the front door
└── Makefile                  # make help
```

Every directory with more in it than its name says has a page of its own:

- [`stacks/`](stacks): each stack's README covers its host, its services and
  what it deliberately leaves out.
- [`scripts/`](scripts/README.md): every script by purpose, with the `make`
  target that runs it.
- [`systemd/`](systemd/README.md): every timer, its host and its schedule, and
  how a job that stops running pages.
- [`.github/`](.github/OVERVIEW.md): the workflows, the ruleset on `main`,
  Dependabot and the templates.
- [`docs/diagrams/`](docs/diagrams/README.md): the network diagram, what it is
  drawn from, and how to keep it current.
- [`packer/`](packer/README.md), [`tofu/`](tofu/README.md),
  [`ansible/`](ansible/README.md) and [`secrets/`](secrets/README.md).

## Quick start

Requires Docker with the compose plugin, plus [`sops`](https://github.com/getsops/sops),
[`age`](https://github.com/FiloSottile/age) and `openssl`.

```bash
git clone https://github.com/Gerrrt/HomeLab.git && cd HomeLab

make secrets-init     # generate an age keypair, create the encrypted secrets file
make secrets-edit     # fill in real values
make certs ARGS=--ca  # create the lab CA
make certs ARGS="--host grafana.matrix.elysium --ip 10.0.99.20 --dns grafana"    # Grafana's leaf
make certs ARGS="--host speedtest.matrix.elysium --ip 10.0.99.20 --dns speedtest-tracker"    # speedtest-tracker's
make certs ARGS="--host prometheus.matrix.elysium --ip 10.0.99.20 --dns caddy"    # the ingest proxy's
make validate         # everything CI runs
make up               # render config and start the stack
```

The `certs` steps are not optional: Grafana, speedtest-tracker and the ingest
proxy each mount their leaf, and Prometheus verifies Grafana's with the CA, so
`make up` renders nothing until they exist. Details in
[`docs/runbooks/generate-certificates.md`](docs/runbooks/generate-certificates.md).

Grafana on `:3000` over https, Prometheus on `:9090`. Alertmanager binds to
`127.0.0.1` and is reached through Grafana
([#70](https://github.com/Gerrrt/HomeLab/issues/70)). Grafana's certificate is
signed by the lab's own CA, so a browser warns and `curl` needs `-k` until you
trust `certificates/ca.pem` — step 4 of that runbook. Full procedure,
verification steps and troubleshooting in
[`docs/runbooks/deploy-stack.md`](docs/runbooks/deploy-stack.md).

That is the first deploy. After it, the monitoring host deploys itself: a timer
runs `scripts/converge.sh` hourly, which fetches `main`, refuses it unless the
tip carries GitHub's signature, fast-forwards and runs the same `make up` —
recording what it deployed and refusing to overwrite anything edited on the host
([#99](https://github.com/Gerrrt/HomeLab/issues/99),
[ADR-0021](docs/adr/0021-converge-on-a-timer-instead-of-deploying-over-ssh.md),
[`docs/runbooks/converge-the-host.md`](docs/runbooks/converge-the-host.md)).
A host is installed with `HOMELAB_CONVERGE_APPLY=0`, which makes the timer
fetch, verify and report what it *would* deploy without applying it, and that
runbook has the step that lets it act — so on a host still in that mode, a
merge reaches the stack only when someone runs `make up` there.

```console
$ make help
  up               Render config and start the stack
  converge         Fetch main, verify it, fast-forward and deploy (ARGS=--dry-run)
  down             Stop the stack (volumes are preserved)
  reload           Hot-reload Prometheus, Alertmanager and snmp-exporter (no restart)
  secrets-init     Generate an age keypair and create the encrypted secrets file
  secrets-edit     Edit the encrypted secrets in $EDITOR
  validate         Run every check CI runs
  check-docs       Verify the documents agree with the configs
  backup           Quiesce the stack, archive its volumes to ./backups/, verify, copy to oracle
  restore          Restore the stack's volumes from a backup set (ARGS="--from <stamp>")
  install-timers   Install and enable the systemd timers on this host (needs sudo)
  secrets-verify-backup  Check a backup age key decrypts the secrets (KEY=/path/to/keys.txt)
  ...
```

The timers are what stop `backup`, `backup-firewall`, `snmp-verify` and now
deployment itself being things someone has to remember, and the alert rules that come with them fire on a
job having *stopped being run* rather than only on one that failed
([#77](https://github.com/Gerrrt/HomeLab/issues/77)). One job deliberately has no
timer: `secrets-verify-backup` needs a human to mount removable media, so it gets
a ninety-day deadline and an alert instead. See
[`docs/runbooks/schedule-maintenance.md`](docs/runbooks/schedule-maintenance.md).

## Dashboards

Rendered from the running stack by `make screenshots` on 2026-10-04, over a
24-hour window. Every dashboard but Logs and Security is here;
`docs/images/README.md` explains why those two are deliberately left out, and
what in these renders is a known fault rather than the steady state.

![Host Overview dashboard: CPU, memory, load, storage and network for every host
running an Alloy agent, with a table of firing host alerts across the
top.](docs/images/host-overview.png)

![Docker Containers dashboard: per-container CPU, memory, network and filesystem
writes from cAdvisor, alongside restart counts, CPU throttling and a container
inventory.](docs/images/docker-containers.png)

![Network & Firewall dashboard: pfSense pf state table and packet filter drops,
MokerLink switch interface throughput and link status, and HPE iLO chassis power
draw and hardware health.](docs/images/network-snmp.png)

![UPS & Power dashboard: APC power source, battery charge, output load,
runtime, voltage and time on battery, under the banner recording when the pack
was fitted and proven.](docs/images/ups-power.png)

![Observability Stack dashboard: every scrape target with its staleness, then
Prometheus, Loki, Alertmanager and the Alloy agents — the collection path
watching itself.](docs/images/observability-stack.png)

## What runs it

The entire observability stack runs on a 2012 MacBook Pro with Ubuntu Server on
it. Four SNMP devices at a 60-second interval, Alloy agents, and 30 days of
metrics, on hardware that was otherwise going to landfill. The rest of the
estate is as unglamorous:

| Host | Hardware | Job |
| --- | --- | --- |
| `morpheus` | HP ProDesk 600 G4 Mini, a second NIC on an M.2 adapter | pfSense firewall |
| `neo` | MokerLink 26-port managed switch | Core switching |
| `Saruman` | HPE ProLiant DL360 Gen9, iLO 4 as `shiva` | Proxmox VE, and the lab's guests |
| `smaug` | Lenovo ThinkServer TS150 | TrueNAS and the media stack |
| `trinity` | HP ProDesk 600 G4 DM | The household's tier |
| `prometheus` | Apple MacBook Pro (2012) | The observability stack |
| `oracle` | Dell Inspiron 15 | The wiki and the off-host copies |
| `mjolnir` | APC Smart-UPS X 1500 | Power for the rack and everything on its PDU |

All of it but the two laptops, `trinity` and the NAS sits in a 9U open-frame rack. Details
in [`docs/hardware.md`](docs/hardware.md).

## Security posture

Segmentation rationale, threat model, secrets handling, and an explicit account
of what this repository deliberately does not publish (full MAC addresses,
owner-linked device names, camera placement) are in
[`docs/security.md`](docs/security.md).

Historical credential exposure in this repository's git history is documented
there too, along with the runbooks to remediate it — including the parts not yet
done. [`SECURITY.md`](SECURITY.md) carries the disclosure policy and a summary of
what is known.

Container images are pinned by **tag and digest**. A tag is a mutable pointer; a
digest is the content hash, so a moved tag cannot change what gets deployed. CI
enforces it, and `make pin-digests` re-resolves them.

`compose.yaml` is the only place an image may be named, including images no
service runs — the tar that takes backups and the scanner CI runs are both
profile-gated entries there. CI parses every `docker run`, `pull` and `create`
in the repository and requires each to resolve its image through
`scripts/image-for.sh`, because the pin that caused this rule was not a wrong
one but a missing one, and no amount of grepping finds those.

## Roadmap

Open work is tracked in
[Issues](https://github.com/Gerrrt/HomeLab/issues), grouped into
[milestones](https://github.com/Gerrrt/HomeLab/milestones);
[`docs/roadmap.md`](docs/roadmap.md) is the shape of it — what is outstanding,
what gates it, and why it is in that order. What happened, and what it found,
is [`docs/changelog.md`](docs/changelog.md), dated and never rewritten.

**Every purchase still outstanding is in one place**, the roadmap's
[*Everything still to buy*](docs/roadmap.md#everything-still-to-buy):
0 items now, one later, and a rule that nothing joins them without a
decision. This sentence used to carry the list itself, name three purchases
coupled to the UPS work and omit the tier's host entirely, which is how one
ProDesk came to be bought for two jobs. It names no current item for the
same reason: the roadmap moves faster than a front page is reread.

## License

[MIT](LICENSE)
