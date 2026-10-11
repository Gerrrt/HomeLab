# Analyst stack

[![host: garuda](https://img.shields.io/badge/host-garuda-30363d?style=plastic)](../../docs/network.md#imaginationlan--vlan-30--lab)
[![VLAN 30: ImaginationLAN](https://img.shields.io/badge/VLAN%2030-ImaginationLAN-2ea043?style=plastic)](../../docs/network.md#imaginationlan--vlan-30--lab)
![status: live](https://img.shields.io/badge/status-live-2ea043?style=plastic)
[![Alloy](https://img.shields.io/badge/Alloy-F46800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/alloy-opentelemetry-collector/)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-2496ED?style=plastic&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

The collector on `garuda` (`10.0.30.62`, ImaginationLAN / VLAN 30), Defense's
analyst workstation: a Kali Purple guest on `Saruman`, VMID 162, cloned by
[`tofu/`](../../tofu/README.md) from template 910 ([#921]). [ADR-0091] is the
decision, and [`build-the-analyst-workstation.md`] is the build.

```bash
make secrets-init STACK=analyst    # on garuda, once: its own age key and rule
make secrets-edit STACK=analyst    # INGEST_TOKEN, copied from the lab's INGEST_TOKEN_GARUDA
make up STACK=analyst
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `alloy` | `grafana/alloy` | 12345 (localhost) | This guest's collector. Host metrics, the journal and container logs, pushed to `alexander` |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy` | *internal* | Holds the Docker socket so Alloy does not: GET-only, the estate's allowlist ([#836](https://github.com/Gerrrt/HomeLab/issues/836)) |

## OpenVAS, and its fence: `gvm/`

OpenVAS/GVM is Kali's `gvm` packages on the host, run on demand. It is not a
service in this compose file. `gvm/` holds what fences it to the lab domain's
six ([ADR-0093]):

| File | Installed as | Does |
| --- | --- | --- |
| `gvm/gvm-scope.nft` | `/etc/nftables.d/gvm-scope.nft` | An nftables table that drops everything `ospd-openvas.service`'s cgroup sends, except to `10.0.30.50`–`.55`, loopback and DNS to `morpheus` |
| `gvm/ospd-openvas-scope.conf` | `/etc/systemd/system/ospd-openvas.service.d/scope.conf` | Loads that table as the scanner's `ExecStartPre`, so it never starts unscoped |

[`scan-the-lab-with-openvas.md`](../../docs/runbooks/scan-the-lab-with-openvas.md)
installs both, proves the fence and runs a scan.

## What is not here

Kali Purple's SOC. Its SIEM and sensors stay off, because Wazuh on `odin`,
Zeek on `fenrir` and Suricata on `morpheus` already do that work, and a
second SIEM would split the telemetry and the RAM ([ADR-0091]). `garuda`'s
analyst tools (CyberChef, Wireshark and the
[`dotfiles-Defense`](https://github.com/dotgibson/dotfiles-Defense) layer) are
host tools, installed by the runbook, not services.

`dotfiles-Defense` ships its own Dockerized detection lab, `siemup`. It is
brought up for an exercise and down after it, and is never part of this file.
A `docker ps` on `garuda` that shows more than this stack's two containers
between exercises is a finding.

[#921]: https://github.com/Gerrrt/HomeLab/issues/921
[ADR-0091]: ../../docs/adr/0091-put-a-kali-purple-analyst-workstation-on-saruman.md
[`build-the-analyst-workstation.md`]: ../../docs/runbooks/build-the-analyst-workstation.md
[ADR-0093]: ../../docs/adr/0093-run-openvas-on-garuda-on-demand-scoped-to-the-domain-by-nftables.md
