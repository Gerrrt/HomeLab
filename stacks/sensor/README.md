# Sensor stack

Zeek on a mirror of `Saruman`'s lab bridge, and the Alloy that carries its logs
to the lab's Loki. It runs on `fenrir` (`10.0.30.90`, ImaginationLAN / VLAN 30),
a guest on `Saruman`. **The guest is not built yet.** The build is
[`build-the-sensor-guest.md`], and this directory is the stack it deploys.
[ADR-0068] is the decision: why the mirror is `tc` and not Open vSwitch, why a
guest of its own, and what the hypervisor's gauge does and does not prove.

```bash
make secrets-init STACK=sensor     # on fenrir, once: its own age key and rule
make secrets-edit STACK=sensor     # INGEST_TOKEN, copied from the lab's INGEST_TOKEN_FENRIR
make up STACK=sensor
```

Since [#834] it **is** `make up STACK=sensor`. The stack has one secret, its
token for the lab's ingest proxy, and `make up` renders it from
`secrets/sensor.sops.yaml` ([`docs/security.md`] § Secrets). Before that it had
none and was brought up with plain `docker compose`.

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `zeek` | `zeek/zeek` | — (host network, capture only) | Protocol logs from the mirror on `ens19`: conn, dns, ssl, x509, smb, kerberos, ntlm, files and the rest, as JSON, rotated hourly |
| `alloy` | `grafana/alloy` | 12345 (localhost) | This guest's collector. It tails Zeek's current logs into the lab's Loki as `job="zeek"`, one stream per `log_type` |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy` | *internal* | Holds the Docker socket so Alloy does not: GET-only, the estate's allowlist ([#836](https://github.com/Gerrrt/HomeLab/issues/836)) |

## What it sees

Every frame on `vmbr0`, once. That includes the domain's east-west traffic:
LLMNR, NBT-NS, SMB, Kerberos, LDAP and ARP between the six guests. That traffic
crosses no router, so Suricata on `morpheus` never sees it. It excludes
`fenrir`'s own traffic, which is filtered out by BPF.

## JA4+ fingerprints

`zeek/ja4/` is FoxIO's
[`ja4-zeek-scripts`](https://github.com/FoxIO-LLC/ja4-zeek-scripts), vendored
unmodified at the commit in `zeek/ja4/VENDORED`, mounted read-only and loaded
by `local.zeek` ([ADR-0069], #776). No image is built. It adds these fields:

| Method | Where | Fingerprints |
| --- | --- | --- |
| `ja4`, `ja4s` | `ssl.log` | TLS client hello and server hello |
| `ja4h` | `http.log` | HTTP client |
| `ja4t`, `ja4ts`, `ja4l`, `ja4ls`, `ja4l_delta`, `ja4ls_delta` | `conn.log` | TCP client and server, latency, and latency deltas |
| JA4SSH | `ja4ssh.log` | SSH sessions |
| JA4D | `ja4d.log` | DHCP clients |

Methods are switched in the vendored `config.zeek` at load time, which is
FoxIO's default: all but JA4X.

**Not MIT.** JA4 is BSD 3-Clause. The rest of JA4+ is the FoxIO License 1.1,
which is fine for this non-commercial use and not for monetisation.
`zeek/ja4/NOTICE` is the statement of what covers what.

**To update it**, re-vendor at a full commit SHA and review the diff, which is
upstream's change and nothing else:

```bash
scripts/vendor-ja4.sh <40-char commit sha>
```

```bash
scripts/vendor-ja4.sh --check    # is what's vendored still that commit, byte for byte?
```

Do not edit those files by hand. The EditorConfig checker excludes the
directory so that they can stay byte-identical to upstream.

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
{job="zeek", log_type="ssl"} | json | ja4 != "" | line_format "{{.ja4}} {{.server_name}}"
```

[ADR-0068]: ../../docs/adr/0068-mirror-the-lab-bridge-to-zeek-with-tc-not-open-vswitch.md
[ADR-0069]: ../../docs/adr/0069-vendor-the-ja4-scripts-into-the-sensor-stack-rather-than-build-an-image.md
[`build-the-sensor-guest.md`]: ../../docs/runbooks/build-the-sensor-guest.md
[`docs/security.md`]: ../../docs/security.md
[#834]: https://github.com/Gerrrt/HomeLab/issues/834
