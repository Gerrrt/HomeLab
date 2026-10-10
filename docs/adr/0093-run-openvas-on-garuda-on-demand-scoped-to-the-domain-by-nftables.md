# ADR-0093: Run OpenVAS on garuda on demand, scoped to the domain by nftables

**Status:** Accepted · 2026-10

## Context

[ADR-0091](0091-put-a-kali-purple-analyst-workstation-on-saruman.md) gives
`garuda` a third job: "Vulnerability scanning of the lab (OpenVAS/GVM)",
deferred to its own change. Two conditions were set on that change: the scope
has to be written down, and the scans will trip the SOC.
[#921](https://github.com/Gerrrt/HomeLab/issues/921) is phase 3.

What `garuda` has to work with:

- **Packages.** Kali packages the Greenbone stack as `gvm` (25.04.3 on
  2026-10-10). That is gvmd 26.24, openvas-scanner 23.45, ospd-openvas,
  notus-scanner and gsad, over PostgreSQL and Redis, with `gvm-setup` and
  `gvm-start`/`gvm-stop`.
- **Room.** `garuda` has 4 vCPU, 8 GiB and 79 GB of disk. GVM wants 2–4 GB
  of RAM running and some GB of feed data.
- **Network.** `garuda` sits on VLAN 30 with everything else, including the
  firewall (`.1`), the hypervisor's iLO (`.10`) and the hypervisor (`.110`).
  Traffic inside VLAN 30 crosses no router, so `morpheus` cannot fence a
  scanner on the segment.

How the scanner runs on Kali matters to the fence. `ospd-openvas` runs as
`_gvm` and starts the scanner, `openvas`, as root through `sudo`. So the
packets that probe a target are root's.

## Decision

**1. Kali's `gvm` packages, not Greenbone's containers.**

- They update with Kali's rolling apt, like the rest of `garuda`'s tools.
- They add nothing for Dependabot to track. Greenbone's community compose
  file is about a dozen images, each of which would have to be pinned and
  bumped.
- The web UI, gsad, listens on `127.0.0.1:9392` and is used from `garuda`'s
  own desktop. Nothing is published.

**2. On demand.**

- GVM's services do not start at boot.
- A scan starts with `gvm-start`, which brings the feeds up to date first, and
  ends with `gvm-stop`, the way `dotfiles-Defense`'s `siemup` is used.
- When idle, the RAM stays with the desktop, and a scanner that is not running
  cannot be pointed anywhere.

**3. The scope is the lab domain's six, `10.0.30.50`–`.55`.**

- Those are the deliberately weak estate the exercises are about.
- Every other address on the segment is out of scope: the firewall, the iLO,
  the hypervisor, and the lab's own services (`alexander`, `odin`, `eden`,
  `fenrir`, `phoenix`, `golem`, the dotfiles VMs and `garuda`). Widening it
  is a change to this ADR.

**4. The kernel enforces the scope, not only GVM's target list.**

- **The rule.** An nftables table on `garuda`, `stacks/analyst/gvm/gvm-scope.nft`,
  matches every packet sent from the cgroup of `ospd-openvas.service`.
  - **Why the cgroup and not a user.** The cgroup holds the scanner however
    it was started, because a process keeps its cgroup through `sudo`. A
    rule on the `_gvm` user would miss every scan packet, since those are
    root's.
  - **What it allows:** the six, loopback, and DNS to `morpheus`. Everything
    else is counted, logged and dropped. A mistyped or widened target fails
    closed, and the attempt shows in garuda's journal.
- **How it loads.** nftables resolves a cgroup when the rule is loaded, so the
  rule cannot be loaded before the service exists. A drop-in,
  `ospd-openvas-scope.conf`, loads it as the service's `ExecStartPre`, inside
  that cgroup. If the load fails, the start fails, so the scanner never runs
  without its scope.
- **No `flush ruleset`.** The file replaces only its own table, so Docker's
  rules on `garuda` are untouched.
- **The proof.** A GVM task against an out-of-scope host, run through the
  real `ospd-openvas` → `sudo` → `openvas` path, must reach nothing and must
  raise the table's drop counter. Its record is in the runbook.

**5. No estate silence is needed.**

- **Why.** ADR-0091 asked for an Alertmanager silence owned by #921 while a
  scan runs. A scan of the six never leaves VLAN 30, and nothing on the
  estate side sees inside the segment: Suricata on `morpheus` sees
  cross-segment traffic only, and the estate's guest metrics are run state.
  So there is no estate alert to silence.
- **Where the scan does show.** In `odin`'s Wazuh, from the six's agents and
  `garuda`'s own, and in Zeek on `fenrir`. That is the detection test
  ADR-0091 wanted, and the lab has no Alertmanager to page.
- **The one estate alert a scan could raise is
  `LabSegmentReachedInternalNetwork`.** It fires only if a scan crosses to
  another segment, which decision 4 makes impossible. If it ever fires during
  a scan, the scope failed. It must page, so it is never silenced for a scan.

## Consequences

- **A scan is a short procedure in
  [`scan-the-lab-with-openvas.md`](../runbooks/scan-the-lab-with-openvas.md):**
  start, scan the six, read the results, stop. Results and reports live in
  GVM's database on `garuda`, which `golem` backs up with the rest of the
  guest. They are never committed.
- **Kali upgrades GVM underneath this.** A `full-upgrade` can move gvmd's
  database schema. `gvm-check-setup` after an upgrade, and a migration if it
  asks for one, are part of the procedure.
- **The scope is two files.** The address set is in `gvm-scope.nft`, and the
  targets are in GVM. Widening means changing this ADR, the set and the
  target, together.
- **If the cgroup path changes,** for instance because the unit is renamed by
  a packaging change, the rule stops loading and the scanner stops starting.
  That is the safe direction, and the runbook's check names it.
- **What the SOC sees is the point.** A scan's noise in Wazuh is expected and
  is not tuned away. Tuning that hides a scan would also hide an attacker's.
