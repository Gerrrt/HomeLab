# Security policy

This repository documents and configures a private home network. It is not a
product and has no users other than its owner, so "supported versions" does not
really apply — `main` is the only branch that means anything, and it is what the
lab runs.

What *is* useful here is a clear answer to two questions: what to do if you spot
a problem, and what is already known.

## Reporting something

If you find a misconfiguration, a leaked credential, or a weakness in what is
published here, please report it privately rather than opening a public issue:

- **GitHub Security Advisories** — [open a draft advisory](https://github.com/Gerrrt/HomeLab/security/advisories/new)
  (preferred; it stays private until fixed)
- Failing that, a GitHub issue *without* details, asking for a contact.

Please do not open a public issue containing a working credential, a capture, or
anything that would let someone else reach the network before it can be fixed.

This is a personal project, so there is no SLA. Realistically: acknowledgement
within a few days, and credential exposure treated as urgent.

### Please don't

The lab is a home network, not a bug bounty target. Scanning, probing or
attempting to reach any host described in `docs/network.md` is unwelcome and not
authorised. Everything worth reviewing is in this repository — review the
configuration, not the running system.

## Known exposure

Documented rather than quietly fixed, because a known and written-down exposure
is a very different thing from an overlooked one. Full detail in
[`docs/security.md`](docs/security.md).

| What | Status |
| --- | --- |
| SNMP community committed in plaintext, shared across firewall, switch, UPS and BMC | Removed from `HEAD` and replaced with four distinct per-device SOPS-encrypted values. Rotated on all four devices; each answers to its own new community. The firewall, the UPS and the BMC additionally refuse the old one. **The switch still accepts its previous community alongside the new one** — see below. The original shared string has been purged from git history, though it must still be treated as public — it was reachable in a public repository and cannot be un-seen. |
| Grafana `admin`/`admin` with anonymous Admin access enabled | Fixed — anonymous auth off, password from SOPS |
| Passphrase-encrypted TLS private keys under `certificates/` | Removed from `HEAD` and purged from history. A new CA and leaf have been generated with [`scripts/gen-certs.sh`](scripts/gen-certs.sh); the old keys are superseded and should be treated as compromised wherever they were ever trusted. |

The switch is the honest gap, and it is a deliberate one. `neo` (10.7.7.2) is
rotated and polling, but it also still accepts the community it held before the
rotation, verified after a reboot so the result reflects its saved
configuration rather than a stale agent. Its firmware does not persist a
deletion from the SNMP community table: the row can be removed, applied and
saved, and the entry is still there after a restart. Each attempt also drops
the SNMP agent until the switch is rebooted, and it is the switch the whole
network runs through.

The residual risk is accepted rather than overlooked. The community is
read-only, and reaching UDP/161 on `10.7.7.2` requires both a foothold on the
management VLAN and the specific pfSense rule that permits `10.0.99.20` to
reach it — it is not exposed beyond the management segment. The way to close it
without fighting the firmware is to overwrite that row with a fresh value
rather than delete it, on some future pass when the switch is already being
taken down for something else.

Remediation is tracked in [`docs/roadmap.md`](docs/roadmap.md), with procedures
in [`docs/runbooks/rotate-snmp-community.md`](docs/runbooks/rotate-snmp-community.md)
and [`docs/runbooks/purge-git-history.md`](docs/runbooks/purge-git-history.md).

There is no `.gitleaksignore`. There was one, enumerating nine historical
findings so the full-history scan stayed meaningful; the purge removed what it
acknowledged, so it was deleted. CI now scans the whole history with no
exceptions, which is the only way to know the purge worked — an ignore file
large enough to cover real findings can also hide new ones.

## What this repository will not contain

Deliberate omissions, so their absence is not mistaken for an oversight:

- **Full MAC addresses.** Truncated to the vendor OUI, which keeps the useful
  half and drops the unique identifier.
- **Owner-linked device names**, and no room labelled as a child's.
- **Camera-to-room mapping.** That there are cameras is fine; which one covers
  which door is not.
- **The WAN address, firewall rule bodies, and Wi-Fi configuration.**
- **Any plaintext credential.** Secrets are SOPS + age encrypted; the private key
  never enters the repository. See [`secrets/README.md`](secrets/README.md).

## Controls in CI

Every push and pull request runs:

- **`gitleaks`** over the working tree *and* full history, with rules for SNMP
  communities, inline Grafana passwords, PEM private keys and age secret keys.
- An assertion that every `secrets/*.sops.yaml` is genuinely encrypted, which
  needs no ability to decrypt.
- An assertion that no rendered or decrypted artefact — `.env`, `.rendered/`,
  `.purge-secrets.txt` — is ever a tracked file.
- Verification that every container image is pinned by **tag *and* digest**, so a
  moved tag cannot silently change what is deployed.

See [`docs/security.md`](docs/security.md) for the threat model and segmentation
rationale.
