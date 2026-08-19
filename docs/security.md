# Security

The lab is a security project, so the interesting question is not "is it
secure" but "what is it defending against, and what is it knowingly not."

## Threat model

What this network is actually built to survive:

| Threat | Control |
| --- | --- |
| A compromised IoT device pivoting to a workstation | VLAN 20 is terminal — no route to any other segment |
| A guest on the Wi-Fi enumerating the LAN | VLAN 10 is terminal, client isolation on |
| A smart TV's firmware phoning somewhere unexpected | VLAN 40 is terminal, egress only |
| A corporate laptop carrying something in from outside | Sits on VLAN 50 but has no management access |
| A lab VM escaping into the house | VLAN 30 reachable only *from* trusted, never *to* it |
| Losing visibility of a failure | 32 alert rules, 30 days of metrics and logs |
| Mains power loss | UPS on the management VLAN, monitored, alerts on `category=power` |

What it explicitly does **not** defend against: a determined attacker with
physical access to the rack, a supply-chain compromise in an upstream container
image, or a vulnerability in pfSense itself. There is no IDS/IPS, no egress
filtering by domain, and no MFA on the internal services.

## Segmentation

Default deny between every segment. Two exceptions:

1. Specific hosts on **Hicks (50)** may reach **Winterfell (99)** on management
   ports. Without this there is no way to administer anything.
2. **Hicks (50)** may reach **ImaginationLAN (30)** so the lab is usable.

Everything else — IoT, media, guest — gets internet and nothing more.

The IoT segment is the one that justifies the whole exercise. It holds cameras,
a doorbell, an alarm hub, smart speakers, a baby monitor and a $20 Tuya
white-noise machine. Every one of those is a network-connected computer running
firmware nobody outside its vendor has audited, several with no update
mechanism at all. Treating them as untrusted is not paranoia; it is the only
assumption consistent with what they are.

## Secrets

- Credentials are encrypted with [SOPS](https://github.com/getsops/sops) + age
  and committed in encrypted form. See [`secrets/README.md`](../secrets/README.md).
- The private key lives at `~/.config/sops/age/keys.txt` on the deployment host
  and is never in the repository.
- `scripts/render-config.sh` decrypts at deploy time into gitignored files.
  Nothing writes a plaintext secret into a tracked path.
- CI runs `gitleaks` with rules specifically for SNMP communities, inline
  Grafana passwords, PEM private keys and age secret keys, and separately
  asserts that every `secrets/*.sops.yaml` is genuinely encrypted.

### Known historical exposure

This repository previously committed real credentials. Removing them from `HEAD`
does not remove them from history, and anything ever pushed to a public
repository must be treated as compromised:

| What | Where | Status |
| --- | --- | --- |
| SNMP community shared across all four devices | `snmp.yaml`, from commit `ee3d443` | Replaced with four distinct per-device values, SOPS-encrypted. Rotated on all four. `morpheus`, `mjolnir` and `shiva` verified answering the new community and refusing the old; `neo` answers the new one but still accepts its previous community — accepted risk, see [`SECURITY.md`](../SECURITY.md) and the [runbook](runbooks/rotate-snmp-community.md) |
| Grafana `admin` / `admin` with anonymous Admin access | compose file | Fixed: password from SOPS, anonymous auth disabled |
| Passphrase-encrypted TLS private keys | `certificates/`, added in `efb2632`, deleted in `647d90a` but reachable at `647d90a~1` | Still in history. **Purge and regenerate** — see [runbook](runbooks/purge-git-history.md) |

CI scans both the working tree and the full history. The working-tree scan must
be clean unconditionally. The history scan honours
[`.gitleaksignore`](../.gitleaksignore), which lists all nine historical
findings individually, each annotated with what it is and why it is still there.

That file is an acknowledgement, not a fix. It exists because a CI job that is
permanently red for a known reason gets ignored — and then a genuinely new leak
goes unnoticed alongside it. Once the history purge runs, the fingerprints go
stale and the file gets deleted.

### Why SNMPv2c is still a weak point

The devices are polled with SNMPv2c, which transmits the community string in
cleartext. Anyone with a port on the management VLAN can read it off a single
packet. Two mitigations are in place, one only partly, and one is not:

- **Done:** each device has its own community, confirmed live on all four, so
  one captured packet no longer grants read access to the whole fleet. The
  switch does still accept its own previous community as well — an accepted
  residual, recorded in [`SECURITY.md`](../SECURITY.md).
- **Done:** SNMP is reachable only on the management VLAN and the
  switch-management LAN, neither of which anything but specific trusted hosts
  can enter.
- **Not done:** SNMPv3 with authPriv. The MokerLink switch does not support it.
  Tracked in [roadmap](roadmap.md).

These communities are read-only, but "read-only" on a firewall means the
complete state table and interface topology. They are credentials.

## Hardening applied to the stack

- Anonymous Grafana access disabled; sign-up disabled; admin password from SOPS.
- Prometheus, Alertmanager and snmp-exporter run as `nobody` (65534); Loki as
  its own unprivileged UID.
- `snmp-exporter` is never published to a host interface — it is reachable only
  on the compose network.
- The Alloy debug UI binds to `127.0.0.1` only.
- The Docker socket is mounted read-only into Alloy.
- All images are pinned to explicit versions, so an upstream compromise cannot
  arrive silently via `:latest`. Dependabot proposes the bumps; CI validates
  them.
- Grafana telemetry and update checks disabled.

Alloy still runs `privileged: true`, which it needs for host-level metric
collection. That is a real tradeoff and is noted rather than hidden.

## What this repository deliberately does not publish

Being able to describe a network precisely is useful; publishing a complete
fingerprint of a house is not. Withheld on purpose:

- **Full MAC addresses.** Truncated to the OUI, which keeps the useful
  information (vendor, and therefore what the device is) and drops the unique
  identifier. Full MACs enable device tracking and, on some networks, MAC-based
  access control bypass.
- **Owner-linked device names.** Personal devices are listed by role
  (`laptop-01`) rather than by person, and a child's bedroom is not labelled.
- **Camera-to-room mapping.** Knowing there are seven cameras is fine. Knowing
  which one covers which door is a physical-security detail.
- **The WAN address**, firewall rule bodies, and Wi-Fi configuration.

The public IP was already redacted in the original inventory — the rest of this
is the same instinct applied consistently.
