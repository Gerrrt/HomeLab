<div align="center">

# HomeLab

**A segmented home network and its observability stack, managed as code.**

[![CI](https://img.shields.io/github/actions/workflow/status/Gerrrt/HomeLab/ci.yml?branch=main&style=plastic&logo=githubactions&logoColor=white&label=CI)](https://github.com/Gerrrt/HomeLab/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=plastic)](LICENSE)
[![SOPS](https://img.shields.io/badge/SOPS-6f42c1?style=plastic)](https://github.com/getsops/sops)
[![age](https://img.shields.io/badge/age-6f42c1?style=plastic)](https://github.com/FiloSottile/age)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=plastic&logo=prometheus&logoColor=white)](https://prometheus.io)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/grafana/)
[![Loki](https://img.shields.io/badge/Loki-F5A800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/loki/)
[![pfSense](https://img.shields.io/badge/pfSense-FreeBSD%2015-212121?style=plastic)](https://www.pfsense.org)

[Architecture](docs/architecture.md) ·
[Network](docs/network.md) ·
[Observability](docs/observability.md) ·
[Security](SECURITY.md) ·
[Runbooks](docs/runbooks) ·
[Decisions](docs/adr) ·
[Roadmap](docs/roadmap.md)

</div>

---

Seven VLANs behind a pfSense firewall, default-deny between every segment, with
a Prometheus/Loki/Grafana stack watching all of it. Every config in this
repository is the config that runs, validated on every push.

It started as a place to practise security work and turned into the network the
house actually depends on, which changed the requirements considerably — a
broken experiment is a learning opportunity, a broken DHCP server is a domestic
incident.

## Highlights

- **Network segmented by trust, not by function.** Seven VLANs; IoT, media and
  guest segments are terminal — egress only, no path to anything else. Three
  inter-VLAN rules exist, each directional and documented.
  [Why](docs/adr/0002-vlan-segmentation-strategy.md)
- **Full observability pipeline for a mixed estate.** Grafana Alloy agents push
  metrics and logs from Linux hosts; `snmp_exporter` polls the four devices that
  can't run an agent (firewall, switch, UPS, iLO). One agent config, deployed
  identically everywhere. [How](docs/architecture.md#observability-data-flow)
- **Dashboards and alerting as code.** 5 provisioned dashboards, 84 panels, and
  47 alert rules — 34 metric-based in Prometheus, 13 log-based in Loki — sharing
  one Alertmanager routing tree. No dashboard exists only in a database.
- **Secrets encrypted in-repo with SOPS + age.** Per-device credentials,
  decrypted at deploy time into gitignored paths, with `git log` showing which
  credential rotated and when — but never to what.
  [Why](docs/adr/0005-secrets-with-sops-and-age.md)
- **CI that actually validates the infrastructure.** `docker compose config`,
  `promtool`, `amtool`, `alloy fmt`, a real Loki boot to parse the LogQL rules,
  dashboard-JSON and datasource checks, every dashboard's PromQL parsed, plus
  `gitleaks` over the full history.
- **Supply chain pinned by digest.** Every image carries both a tag and a
  `sha256:` digest, so a moved tag cannot change what deploys. CI enforces it;
  `make pin-digests` re-resolves them from the registry.
- **Documented decisions and runbooks.** Eight ADRs covering what was chosen and
  what was rejected — including the costs accepted knowingly; nine runbooks for
  the operations that are easy to get wrong at 1am.

## Architecture

```mermaid
graph TB
    INET([Internet]) --- FW{{"morpheus · pfSense<br/>HP ProDesk 600 G4"}}
    FW --- SW[neo · 26-port managed switch]

    subgraph V99["VLAN 99 · Winterfell · Management"]
        MON["<b>prometheus</b><br/>observability stack"]
        UPS["mjolnir · UPS"]
    end
    subgraph V50["VLAN 50 · Hicks · Trusted"]
        WS["workstations"]
    end
    subgraph V30["VLAN 30 · ImaginationLAN · Lab"]
        HV["Saruman · Proxmox<br/>BMC: shiva"]
    end
    subgraph Terminal["VLANs 40 / 20 / 10 · egress only"]
        TV["40 · CasaBonita<br/>media"]
        IOT["20 · Skids<br/>IoT"]
        GUEST["10 · Degens<br/>guest"]
    end

    SW --- V99
    SW --- V50
    SW --- V30
    SW --- Terminal
    WS -.->|management| V99
    WS -.->|lab| V30

    %% Fill is the patch-cable colour in the rack. A dashed border means the
    %% segment is terminal — egress only. Grey carries every VLAN, so it gets
    %% no colour of its own. See docs/adr/0009.
    classDef vlan99 fill:#6e2c2c,stroke:#f85149,color:#fff
    classDef vlan50 fill:#7a3f12,stroke:#db6d28,color:#fff
    classDef vlan30 fill:#1f6f4a,stroke:#2ea043,color:#fff
    classDef infra  fill:#30363d,stroke:#8b949e,color:#e6edf3
    classDef vlan40 fill:#a87f00,stroke:#e3b341,color:#0d1117,stroke-dasharray: 6 4
    classDef vlan20 fill:#1f4e79,stroke:#388bfd,color:#fff,stroke-dasharray: 6 4
    classDef vlan10 fill:#4a3f7a,stroke:#a371f7,color:#fff,stroke-dasharray: 6 4

    class MON,UPS vlan99
    class WS vlan50
    class HV vlan30
    class TV vlan40
    class IOT vlan20
    class GUEST vlan10
    class FW,SW infra

    style V99 fill:#161b22,stroke:#f85149,stroke-width:2px,color:#f85149
    style V50 fill:#161b22,stroke:#db6d28,stroke-width:2px,color:#db6d28
    style V30 fill:#161b22,stroke:#2ea043,stroke-width:2px,color:#2ea043
    style Terminal fill:#161b22,stroke:#8b949e,stroke-width:2px,color:#8b949e,stroke-dasharray: 6 4
```

Dotted lines are the only two paths between segments. Everything else reaches
the internet and nothing more. Segment colour matches the patch cable in the
rack; a dashed border means egress only. Full topology and data flow in
[`docs/architecture.md`](docs/architecture.md).

## Stack

| Layer | Tool | Role |
| --- | --- | --- |
| Firewall / routing | [pfSense on FreeBSD 15](docs/network.md) | VLANs, DHCP, default-deny |
| Virtualisation | Proxmox VE | Lab hypervisor |
| Metrics | [Prometheus](stacks/observability/prometheus) | 30-day retention, remote-write receiver |
| Logs | [Loki](stacks/observability/loki) | Single-binary, filesystem storage |
| Collection | [Grafana Alloy](stacks/observability/alloy) | node + cAdvisor metrics, Docker/journal/syslog/auth logs |
| Network polling | [snmp_exporter](stacks/observability/snmp-exporter) | pfSense, switch, UPS, iLO |
| Alerting | [Alertmanager](stacks/observability/alertmanager) | Severity routing, inhibition |
| Visualisation | [Grafana](stacks/observability/grafana) | 5 provisioned dashboards |
| Secrets | [SOPS + age](secrets) | Encrypted in-repo |
| CI | [GitHub Actions](.github/workflows/ci.yml) | Lint, config validation, secret scanning, digest pinning |

## Repository layout

```text
.
├── stacks/observability/     # the deployed stack — one compose file, six services
│   ├── compose.yaml
│   ├── prometheus/           # config, file_sd targets, 34 alert rules
│   ├── alertmanager/         # routing and inhibition
│   ├── loki/                 # single-binary config + 13 LogQL rules
│   ├── alloy/                # one agent config, used on every host
│   ├── snmp-exporter/        # generator.yaml is the source of truth
│   └── grafana/              # provisioning + 5 dashboards
├── secrets/                  # SOPS-encrypted; see secrets/README.md
├── scripts/                  # bootstrap, render, validate, pin-digests, purge
├── SECURITY.md               # disclosure policy and known exposure
├── docs/
│   ├── architecture.md  network.md  hardware.md
│   ├── observability.md  security.md  roadmap.md
│   ├── adr/                  # 8 architecture decision records
│   └── runbooks/             # deploy, add device, rotate creds, certs, key backup,
│                             #   purge, restore the firewall, ship firewall logs,
│                             #   enable suricata
└── Makefile                  # make help
```

## Quick start

Requires Docker with the compose plugin, plus [`sops`](https://github.com/getsops/sops)
and [`age`](https://github.com/FiloSottile/age).

```bash
git clone https://github.com/Gerrrt/HomeLab.git && cd HomeLab

make secrets-init     # generate an age keypair, create the encrypted secrets file
make secrets-edit     # fill in real values
make validate         # everything CI runs
make up               # render config and start the stack
```

Grafana on `:3000`, Prometheus on `:9090`. Full procedure, verification steps and
troubleshooting in [`docs/runbooks/deploy-stack.md`](docs/runbooks/deploy-stack.md).

```console
$ make help
  up               Render config and start the stack
  down             Stop the stack (volumes are preserved)
  reload           Hot-reload Prometheus, Alertmanager and snmp-exporter (no restart)
  secrets-init     Generate an age keypair and create the encrypted secrets file
  secrets-edit     Edit the encrypted secrets in $EDITOR
  secrets-verify-backup  Check a backup age key decrypts the secrets
  validate         Run every check CI runs
  backup           Back up the stack's volumes to ./backups/
  ...
```

## Dashboards

Rendered from the running stack by `make screenshots`, over a 24-hour window.
Four of the five provisioned dashboards are here; `docs/images/README.md`
explains why the Logs dashboard is deliberately not among them.

![Host Overview dashboard: CPU, memory, load, storage and network for every host
running an Alloy agent, with a table of firing host alerts across the
top.](docs/images/host-overview.png)

![Docker Containers dashboard: per-container CPU, memory, network and filesystem
writes from cAdvisor, alongside restart counts, CPU throttling and a container
inventory.](docs/images/docker-containers.png)

![Network & Firewall dashboard: pfSense pf state table and packet filter drops,
MokerLink switch interface throughput and link status, and HPE iLO chassis power
draw and hardware health.](docs/images/network-snmp.png)

![UPS & Power dashboard: APC power source, output load, input and output voltage
and runtime, under a banner explaining that every battery figure is fabricated
because no battery pack is fitted.](docs/images/ups-power.png)

## What runs it

The entire observability stack runs on a 2012 MacBook Pro with Ubuntu Server on
it. Four SNMP devices at a 60-second interval, Alloy agents, and 30 days of
metrics, on hardware that was otherwise going to landfill. Hardware details in
[`docs/hardware.md`](docs/hardware.md).

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

## Roadmap

Open work is tracked in
[Issues](https://github.com/Gerrrt/HomeLab/issues);
[`docs/roadmap.md`](docs/roadmap.md) is the narrative — what is outstanding and
why it is in that order.

The current top items: replace the UPS battery and rack the shelf switch, which
are one purchase — the pack alone leaves the monitoring path half-protected
([#93](https://github.com/Gerrrt/HomeLab/issues/93),
[#110](https://github.com/Gerrrt/HomeLab/issues/110)); get the firewall backup
off the machine it protects, and buy the spare that turns its restore runbook
from a hypothesis into something rehearsed
([#92](https://github.com/Gerrrt/HomeLab/issues/92)); and take 64-bit interface
counters off the switch, which is unblocked now that it is polling again
([#87](https://github.com/Gerrrt/HomeLab/issues/87)).

## License

[MIT](LICENSE)
