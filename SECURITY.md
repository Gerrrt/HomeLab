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
| Decrypted secrets in editor undo files, written by `make secrets-edit` | Found 2026-08-20: three files under `~/.local/state/nvim/undodir/` holding the live pfSense, APC and iLO SNMP communities in plaintext, mode 664. Shredded. `make secrets-edit` now hardens `$EDITOR` before handing it plaintext, so it cannot recur. Never committed and never left the host, so those three communities were not rotated on that basis. |
| Alertmanager webhook URL and the MokerLink SNMP community, in a local Claude Code session transcript | Found 2026-08-20 by a value-level sweep of the host. Redacted in place; mode 600, never committed or synced. The webhook topic was rotated — on the public ntfy instance the topic name *is* the credential, there is nothing to revoke — and delivery re-verified end to end. The switch community deliberately was not: rotating it means the `neo` residual above all over again. |
| Pre-purge objects still served by GitHub after the history rewrite | The 2026-08-19 rewrite (`021d2b6`) removed both secrets above from every *reachable* commit, but GitHub still serves the orphaned objects by SHA. Verified 2026-08-26: `647d90a`, `21afcad`, `efb2632` and `ee3d443` all still resolve through the API, and the tree at `21afcad` still lists `certificates/Gandalf.Gondor.Lab/ca-key.pem` and `cert-key.pem`. Garbage collection requested from GitHub Support on 2026-08-26 — **pending**; this is the [purge runbook](docs/runbooks/purge-git-history.md)'s *Afterwards* step, and it is the last one outstanding. The repository has no forks and a network count of 0, so nothing else is perpetuating them. Both credentials were rotated *before* the rewrite, so this changes nothing about their status: the old keys and the old community remain superseded and must still be treated as public. Re-check with `gh api repos/Gerrrt/HomeLab/commits/647d90a --jq .sha` — a `404` means GitHub has collected them. |
| Alertmanager published on `0.0.0.0`, letting anyone who could reach it silence an alert | Fixed 2026-08-30 — 9093 now binds to `127.0.0.1` ([#70](https://github.com/Gerrrt/HomeLab/issues/70), [ADR-0012](docs/adr/0012-publish-only-ports-with-an-off-host-consumer.md)). This was the sharpest of the three because a silence switches off monitoring and the record of it lives in the system being switched off. Nothing off-host ever used the port: silences are reached through Grafana, which proxies Alertmanager over the compose network behind a login, so closing it cost no capability. |
| Prometheus and Loki published on `0.0.0.0` with no authentication | **Accepted residual, not a fix in progress.** Anything that can route to `10.0.99.20:9090` or `10.0.99.20:3100` can read every metric and log line, inject metrics through Prometheus' remote-write receiver, and delete log ranges through Loki's delete API. Both stay published because `oracle`'s Alloy agent remote-writes to 9090 and pushes to 3100 — it is not a scrape target, so those ports are its only path. Firewall default-deny is the whole control, and since 2026-09-02 it is narrower than it was: the ingest ports are reachable from Winterfell (99) itself and from `10.0.30.110` on ImaginationLAN, which has an explicit pass for `Saruman`'s Alloy agent. Hicks (50) reaches `10.0.99.20` on `3000` only — a logged *Block access to Winterfell* drops the rest — and no untrusted segment reaches it at all. `docs/network.md` lists what Hicks may reach. Closing it properly means authentication in front of the ingest ports and a credential on every agent, which is a separate piece of work — see below. |
| The monitoring host's disk and swap are unencrypted | **Accepted residual, not a fix in progress** — see below. |

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
without fighting the firmware is to overwrite that row rather than delete it, on
some future pass when the switch is already being taken down for something else.
That is now written out as a procedure — [§2.5, *The MokerLink switch: overwrite
the row*](docs/runbooks/rotate-snmp-community.md#the-mokerlink-switch-overwrite-the-row)
— including what to record here if the overwrite does not persist either.

Remediation is tracked in [`docs/roadmap.md`](docs/roadmap.md), with procedures
in [`docs/runbooks/rotate-snmp-community.md`](docs/runbooks/rotate-snmp-community.md)
and [`docs/runbooks/purge-git-history.md`](docs/runbooks/purge-git-history.md).

There is no `.gitleaksignore`. There was one, enumerating nine historical
findings so the full-history scan stayed meaningful; the purge removed what it
acknowledged, so it was deleted. CI now scans the whole history with no
exceptions, which is the only way to know the purge worked — an ignore file
large enough to cover real findings can also hide new ones.

The unencrypted disk is a different kind of entry from the rest of that table.
The others each happened once and have a date; this one is a standing property
of the host. Measured on `prometheus` (10.0.99.20): `/dev/mapper` holds only
`control` and the LVM logical volume, so there is no LUKS anywhere — the root
filesystem is plain ext4 on LVM — and `/swap.img` is 4 GiB, unencrypted, on that
same filesystem.

The observability containers no longer page into it. Since
[#114](https://github.com/Gerrrt/HomeLab/issues/114) every service sets
`memswap_limit` equal to its `mem_limit`, which disables container swap
outright; the default is twice `mem_limit`, so adding memory limits without it
would have made this entry worse rather than better. The disk itself is
unchanged, and so is this row's status.

So `~/.config/sops/age/keys.txt` and the rendered artefacts under
`snmp-exporter/.rendered/`, `alertmanager/.rendered/` and
`stacks/observability/.env` — which hold plaintext by design — are all mode 600
and owned by `robo`, and file permissions are the only thing protecting them.

Which makes anything that can ignore file permissions worth naming. Until
2026-08-31 the Alloy container was one: uid 0, every capability, and `/` mounted
read-only, so it could read the age key outright. It now holds no capabilities
and cannot ([#188](https://github.com/Gerrrt/HomeLab/issues/188)). The Docker
socket it still mounts is the remaining path — that API can start a container
with `/` mounted read-write — and closing it is tracked, not done.
Permissions mean nothing to someone holding the disk.

This is accepted rather than tracked as work. The threat model in
[`docs/security.md`](docs/security.md) already excludes an attacker with
physical access to the rack, and this is that same exclusion stated at the
filesystem level: recycled hardware, a home lab, and full-disk encryption on a
headless host that must boot unattended after a power cut is a trade with its
own failure mode. It is written down because the undo-file row above
was only serious *because* of this — an undo file at mode 664 on an encrypted
disk is a much smaller problem, and the two facts are easy to lose track of
separately.

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
- Verification that every image any script, recipe, workflow step or runbook
  runs is resolved from `compose.yaml`, so a container cannot be started from an
  image the digest check never saw.

See [`docs/security.md`](docs/security.md) for the threat model and segmentation
rationale.
