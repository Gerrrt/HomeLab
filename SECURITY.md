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
| SNMP community committed in plaintext, shared across firewall, switch, UPS and BMC | Removed from `HEAD` and replaced with four distinct per-device SOPS-encrypted values. Rotated and verified on the firewall, the UPS and the BMC: each answers to its own new community and refuses the old one. **Not rotated on the switch**, which has never answered an SNMP poll at all — so whether it still accepts the old community is unknown, not proven clean. **Still present in git history.** Treat the old string as public. |
| Grafana `admin`/`admin` with anonymous Admin access enabled | Fixed — anonymous auth off, password from SOPS |
| Passphrase-encrypted TLS private keys under `certificates/` | Removed from `HEAD`, still reachable in history. Purge tooling and a runbook are provided; not yet run. |

The switch is the honest gap. `10.7.7.2` has returned `up == 0` for every scrape
in the 30-day retention window, which predates the rotation — the target has
never worked, so its failure is not evidence that the rotation broke anything,
and its silence is not evidence that the old community was removed. It is
reachable at layer 3 from the monitoring host on ICMP and TCP/80; only UDP/161
fails. Tracked separately in [#22](https://github.com/Gerrrt/HomeLab/issues/22).

Remediation is tracked in [`docs/roadmap.md`](docs/roadmap.md), with procedures
in [`docs/runbooks/rotate-snmp-community.md`](docs/runbooks/rotate-snmp-community.md)
and [`docs/runbooks/purge-git-history.md`](docs/runbooks/purge-git-history.md).

[`.gitleaksignore`](.gitleaksignore) enumerates all nine historical findings
individually, with a note on each. It exists so the full-history scan stays
meaningful — a job that is permanently red for a known reason gets ignored, and
then a genuinely new leak goes unnoticed alongside it. It is an acknowledgement,
not a fix, and it gets deleted once the purge has run.

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
