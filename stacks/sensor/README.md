# Sensor stack

Zeek on a mirror of `Saruman`'s lab bridge, and the Alloy that carries its logs
to the lab's Loki. It runs on `fenrir` (`10.0.30.90`, ImaginationLAN / VLAN 30),
a guest on `Saruman`. **The guest is not built yet.** The build is
[`build-the-sensor-guest.md`], and this directory is the stack it deploys.
[ADR-0064] is the decision: why the mirror is `tc` and not Open vSwitch, why a
guest of its own, and what the hypervisor's gauge does and does not prove.

```bash
cp stacks/sensor/.env.example stacks/sensor/.env        # on fenrir, once
docker compose -f stacks/sensor/compose.yaml up -d
```

It is **not** `make up STACK=sensor`: that target renders a secrets file, and
this stack has none ([`docs/security.md`] § Secrets).

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `zeek` | `zeek/zeek` | — (host network, capture only) | Protocol logs from the mirror on `ens19`: conn, dns, ssl, x509, smb, kerberos, ntlm, files and the rest, as JSON, rotated hourly |
| `alloy` | `grafana/alloy` | 12345 (localhost) | This guest's collector. It tails Zeek's current logs into the lab's Loki as `job="zeek"`, one stream per `log_type` |

## What it sees

Every frame on `vmbr0`, once. That includes the domain's east-west traffic:
LLMNR, NBT-NS, SMB, Kerberos, LDAP and ARP between the six guests. That traffic
crosses no router, so Suricata on `morpheus` never sees it. It excludes
`fenrir`'s own traffic, which is filtered out by BPF.

## What says it stopped

Not anything in this stack. The lab's Loki has no ruler (ADR-0020). Instead,
`homelab_zeek_mirror_active` on the hypervisor reads 1 only while:

- VM 190 runs;
- every port of `vmbr0` mirrors to `tap190i1`;
- packets arrive.

`ZeekMirrorInactive` pages on the estate's Alertmanager when it reads 0. **That
proves the mirror, not Zeek.** A Zeek that has crashed inside a running guest
shows as the `job="zeek"` streams going flat in the lab's Grafana.

## Queries

In the lab's Grafana, against its Loki:

```logql
{job="zeek", log_type="conn"} | json | id_resp_p = "445"
{job="zeek", log_type="ssl"} | json | validation_status != "ok"
{job="zeek", log_type="kerberos"} | json | request_type = "TGS"
```

[ADR-0064]: ../../docs/adr/0064-mirror-the-lab-bridge-to-zeek-with-tc-not-open-vswitch.md
[`build-the-sensor-guest.md`]: ../../docs/runbooks/build-the-sensor-guest.md
[`docs/security.md`]: ../../docs/security.md
