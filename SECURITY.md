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
| SNMP community committed in plaintext, shared across firewall, switch, UPS and BMC | Removed from `HEAD` and replaced with four distinct per-device SOPS-encrypted values. Rotated on all four devices; each answers to its own new community. The firewall, the UPS and the BMC additionally refuse the old one. **The switch serves GETBULK to any short community without checking, so whether it still holds the previous one is unverified** — see below. The original shared string has been purged from git history, though it must still be treated as public — it was reachable in a public repository and cannot be un-seen. |
| Grafana `admin`/`admin` with anonymous Admin access enabled | Fixed — anonymous auth off, password from SOPS |
| Passphrase-encrypted TLS private keys under `certificates/` | Removed from `HEAD` and purged from history. A new CA and leaf have been generated with [`scripts/gen-certs.sh`](scripts/gen-certs.sh); the old keys are superseded and should be treated as compromised wherever they were ever trusted. |
| Decrypted secrets in editor undo files, written by `make secrets-edit` | Found 2026-08-20: three files under `~/.local/state/nvim/undodir/` holding the live pfSense, APC and iLO SNMP communities in plaintext, mode 664. Shredded. `make secrets-edit` now hardens `$EDITOR` before handing it plaintext, so it cannot recur. Never committed and never left the host, so those three communities were not rotated on that basis. |
| Alertmanager webhook URL and the MokerLink SNMP community, in a local Claude Code session transcript | Found 2026-08-20 by a value-level sweep of the host. Redacted in place; mode 600, never committed or synced. The webhook topic was rotated — on the public ntfy instance the topic name *is* the credential, there is nothing to revoke — and delivery re-verified end to end. The switch community deliberately was not: rotating it means the `neo` residual above all over again. |
| Pre-purge objects still served by GitHub after the history rewrite | The 2026-08-19 rewrite (`021d2b6`) removed both secrets above from every *reachable* commit, but GitHub still serves the orphaned objects by SHA. Verified 2026-08-26: `647d90a`, `21afcad`, `efb2632` and `ee3d443` all still resolve through the API, and the tree at `21afcad` still lists `certificates/Gandalf.Gondor.Lab/ca-key.pem` and `cert-key.pem`. Garbage collection requested from GitHub Support on 2026-08-26 — **pending**; this is the [purge runbook](docs/runbooks/purge-git-history.md)'s *Afterwards* step, and it is the last one outstanding. The repository has no forks and a network count of 0, so nothing else is perpetuating them. Both credentials were rotated *before* the rewrite, so this changes nothing about their status: the old keys and the old community remain superseded and must still be treated as public. Re-check with `gh api repos/Gerrrt/HomeLab/commits/647d90a --jq .sha` — a `404` means GitHub has collected them. |
| Alertmanager published on `0.0.0.0`, letting anyone who could reach it silence an alert | Fixed 2026-08-30 — 9093 now binds to `127.0.0.1` ([#70](https://github.com/Gerrrt/HomeLab/issues/70), [ADR-0012](docs/adr/0012-publish-only-ports-with-an-off-host-consumer.md)). This was the sharpest of the three because a silence switches off monitoring and the record of it lives in the system being switched off. Nothing off-host ever used the port: silences are reached through Grafana, which proxies Alertmanager over the compose network behind a login, so closing it cost no capability. |
| Prometheus and Loki published on `0.0.0.0` with no authentication | **Accepted residual, not a fix in progress.** Anything that can route to `10.0.99.20:9090` or `10.0.99.20:3100` can read every metric and log line, inject metrics through Prometheus' remote-write receiver, and delete log ranges through Loki's delete API. Both stay published because `oracle`'s Alloy agent remote-writes to 9090 and pushes to 3100 — it is not a scrape target, so those ports are its only path. Firewall default-deny is the whole control, and since 2026-09-02 it is narrower than it was: the ingest ports are reachable from Winterfell (99) itself and from `10.0.30.110` on ImaginationLAN, which has an explicit pass for `Saruman`'s Alloy agent. Hicks (50) reaches `10.0.99.20` on `3000` only — a logged *Block access to Winterfell* drops the rest — and no untrusted segment reaches it at all. `docs/network.md` lists what Hicks may reach. Closing it properly means authentication in front of the ingest ports and a credential on every agent, which is a separate piece of work — see below. |
| The monitoring host's disk and swap are unencrypted | **Accepted residual, not a fix in progress** — see below. |
| Loki's log volume has no size ceiling | **Accepted residual, not a fix in progress** — see below. Prometheus has a byte ceiling since [#184](https://github.com/Gerrrt/HomeLab/issues/184); Loki has no size-based retention to set, only time. `HostDiskWillFillIn24h` is the control. |
| The hypervisor's BMC shares a broadcast domain with the attack VM | **Accepted residual, not a fix in progress.** `shiva`, the iLO 4 at `10.0.30.10` on firmware 2.82, sits on ImaginationLAN, the segment [ADR-0014](docs/adr/0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md) gives to `ifrit`'s Kali VM, and a BMC does not get patched the way a guest does. [ADR-0033](docs/adr/0033-keep-the-ilo-on-the-lab-segment.md) keeps it there on purpose: the iLO is part of the estate under attack, and a BMC compromise in the lab costs the lab. Moving it to Winterfell would put an end-of-line BMC beside the firewall's admin UI and open three more ports on the Hicks list to reach its console. Controls: the BMC's own hardening (IPMI-over-LAN and unused services off, a credential shared with nothing in the house), and the lab tripwire — anything the BMC initiates toward another segment is a logged pass and a `LabSegmentReachedInternalNetwork` alert. Both done 2026-09-09: IPMI-over-LAN, SSH and iLO Federation off on the BMC, its account's credential shared with nothing in the house, its security log read for a baseline; and the `10.0.30.10 → 10.0.99.20/udp` "return path" rule deleted from `morpheus` — it had been evaluated 7.4 million times and matched zero packets, because pf state carries the scrape's replies, and it was the BMC's only path to the monitoring host's syslog listener. The scrape failed once at the reload and has been clean since; the lab interface now passes nothing across a segment except `Saruman`'s two agent ports. |

The switch is the honest gap, and it is a deliberate one. `neo` (10.7.7.2) is
rotated and polling. Its firmware does not persist a deletion from the SNMP
community table: the row can be removed, applied and saved, and the entry is
still there after a restart. Each attempt also drops the SNMP agent until the
switch is rebooted, and it is the switch the whole network runs through. Until
2026-09-12 this section said the switch still accepted the community it held
before the rotation, "verified after a reboot"; that verification was a
GETBULK probe, and the paragraph after this one is why it proved nothing.

**The larger finding, measured on 2026-09-12: the switch does not check the
community on GETBULK at all when the string is sixteen characters or fewer.**
Any such string — `public`, `private`, `asdf`, a single letter — is served a
full walk of every table over that PDU, from any host that can reach UDP/161.
Strings of seventeen characters or more are checked, and GET and GETNEXT are
checked at every length: with the current community all three PDUs answer,
with a wrong one only a short GETBULK does. The other three devices refuse a
junk string over every PDU. This explains every earlier sighting: the
2026-09-06 and 2026-09-09 measurements that found the stock `public` and
`private` answering were GETBULK probes, the empty-community scrape that first
surfaced it was the same thing, and so was every `STILL ACCEPTED` for the old
community. Whether any of those rows ever existed cannot be told from here.
Over GET, after the stale rows were overwritten and the switch rebooted on
2026-09-12, `public`, `private` and a junk string are refused. The previous
community's row is the one thing still unmeasured over GET, because the
string — the shared value purged from history — was not to hand in the
window; it is recorded as unverified rather than as retired.

`scripts/snmp-verify.sh` probes with GET since that date, because GET is what
the switch authenticates. It also sends a short and a long junk string over
both PDUs to every device on every run: a GETBULK answer is `WARN` — a
firmware limit no row in the table changes, so a failure would keep the weekly
job's alert lit for as long as this is the switch — and a GET answer would be
`FAIL`, because nothing else in the run could then be believed for that
device. The exporter scrapes with GETBULK, so a scrape that works after a
rotation proves nothing about the community on this switch either.

The residual risk is accepted rather than overlooked, and it is larger than
the one this section used to describe: read access to the switch's whole MIB
with any short community over GETBULK, rather than one stale read-only row.
What bounds it is unchanged. Reaching UDP/161 on `10.7.7.2` requires both a
foothold on the management VLAN and the specific pfSense rule that permits
`10.0.99.20` to reach it, or a port on the switch LAN itself — it is not
exposed beyond those. What would close it is a switch whose firmware checks
what it serves, which is the replacement
[ADR-0018](docs/adr/0018-name-the-switch-and-leave-its-ui-on-plain-http.md)
already names and the roadmap's buy list carries. SET was not tested, because
a SET is a change to the device. The overwrite procedure stays at [§2.5,
*The MokerLink switch: overwrite
the row*](docs/runbooks/rotate-snmp-community.md#the-mokerlink-switch-overwrite-the-row)
for the rows that are real.

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
socket it mounted was the remaining path — that API can start a container with
`/` mounted read-write — and it is no longer mounted into Alloy at all: an
allowlisting proxy holds it and refuses `POST`
([#193](https://github.com/Gerrrt/HomeLab/issues/193)). That moves the boundary
rather than removing it, and the proxy is now the container to look at.
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

### Loki has no size ceiling, and rate limits would not give it one

`--storage.tsdb.retention.size=12GB` bounds Prometheus. Loki has
`retention_period: 720h` and no size equivalent, because Loki has no
size-based retention to configure — so it is the only store on this disk
bounded by time alone, fed by a push endpoint that is unauthenticated for the
reason the ingest-port row above gives
([#189](https://github.com/Gerrrt/HomeLab/issues/189)).

**Rate limits are the obvious response and they do not solve it.** The lab
produces roughly 0.012 MB/s of logs, so even a deliberately tight 0.5 MB/s
`ingestion_rate_mb` is 40x headroom — and 0.5 MB/s still fills 59 GiB inside a
day and a half. Any limit loose enough not to drop real logs is loose enough to
fill the disk. There is no clean number, which is why one has not been picked.

What actually bounds this is **who can write**, not how fast, and that is
authentication in front of the ingest ports — the work in
[#182](https://github.com/Gerrrt/HomeLab/issues/182), which this is a second
justification for rather than a separate task. Until then the volume is bounded
by trust in the segments that can reach `10.0.99.20:3100`, which is the same
control and the same firewall rules as the row above.

The measured position, so a later reader can tell drift from noise:
`loki-data` was 461 MB on 2026-08-31 and 549 MB on 2026-09-04 — about 22 MB a
day against 53 GiB free, which is years rather than months. Nothing here is
urgent; it is unbounded, which is a different property from close.

`HostDiskWillFillIn24h` is the whole control if that ever changes, so it is no
longer an untested rule: `prometheus/tests/host.test.yaml` asserts it fires on a
disk that is filling, and stays quiet both on one that is full but stable and on
one that is filling with room to spare. That file was added with this residual
and for it — a residual is only as good as the control it leans on, and that
control had no test at all.

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
