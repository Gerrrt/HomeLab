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
- A scan starts with a feed sync (`greenbone-feed-sync --type all`, as
  `gvm-setup` runs it) and then `gvm-start`, which only starts the services.
  It ends with `gvm-stop`, the way `dotfiles-Defense`'s `siemup` is used.
  Without the sync, a scan would use the definitions of the last one.
- When idle, the RAM stays with the desktop, and a scanner that is not running
  cannot be pointed anywhere.

**3. The scope is the lab domain's six, `10.0.30.50`–`.55`.**

- Those are the deliberately weak estate the exercises are about.
- Every other address on the segment is out of scope: the firewall, the iLO,
  the hypervisor, and the lab's own services (`alexander`, `odin`, `eden`,
  `fenrir`, `phoenix`, `golem`, the dotfiles VMs and `garuda`). Widening it
  is a change to this ADR.

**4. The kernel enforces the scope at the scanner's own interface, at
layer 2.**

- **The scanner gets its own interface in its own network namespace.** Only
  `ospd-openvas`, and the `openvas` it spawns, run in a namespace, `gvmscan`
  (`NetworkNamespacePath` in `ospd-openvas-netns.conf`). Its one route to the
  segment is `scan0`, a macvlan on `eth0` with garuda's second address,
  `10.0.30.63`. `gvmd`, `notus-scanner`, `redis` and `mosquitto` stay on the
  host, reached over unix sockets that a namespace does not change.
  - **Why an interface and not the cgroup.** An earlier fence matched the
    scanner's cgroup at the IP `output` hook. OpenVAS's NASL also sends raw
    frames (`send_frame`) and ARP (`send_arp_request`) through `AF_PACKET`,
    below any IP hook, so that fence was IP only. Giving the scanner its own
    interface lets one rule filter *every* frame it sends.
  - **Why a macvlan, not a second NIC.** A macvlan gives the namespace its own
    MAC and address on VLAN 30 over garuda's one NIC — no `tofu` or Proxmox
    change. `scan0` reaches the six on-link, so nothing is routed and Docker's
    `FORWARD` policy, which blocked a veth-and-NAT design, never sees it.
- **The rule.** `stacks/analyst/gvm/scan0-egress.nft`, an nftables `netdev`
  egress hook on `scan0`, loaded inside the namespace. It allows outgoing ARP
  to resolve the six, ARP replies, and IP to the six; everything else is
  counted, logged (rate-limited) and dropped. A mistyped or widened target
  fails closed at layer 2 and at layer 3, and the attempt shows in garuda's
  journal.
- **MQTT crosses on a veth, nothing else.** `openvas` publishes scan state to
  `notus-scanner` through `mosquitto`. A macvlan cannot reach its own host, so
  a point-to-point veth carries it to the broker at `10.99.0.1`
  (`openvas.conf`'s `mqtt_server_uri`, and a second `mosquitto` listener). The
  veth routes to nothing but the broker, so it is not a scan path and is not
  filtered.
- **How it loads.** `gvm-scan-netns.service` builds the namespace, the macvlan,
  the veth and the rule, and `ospd-openvas` `Requires=` and is ordered
  `After=` it, so the scanner cannot start without its namespace, and the
  namespace is torn down when the scan ends.
- **Alive detection is ICMP/TCP or *Consider Alive*.** The fence passes ARP
  only for the six, so an ARP-based alive test of a wider range would be
  dropped like any other out-of-scope frame — the safe direction, and the
  runbook sets the alive test accordingly.
- **The proof.** Run through the real `ospd-openvas` -> `sudo` -> `openvas`
  path (runbook §7): a GVM scan of an out-of-scope host reaches nothing and
  raises the egress drop counter, and an `arping` from the namespace to an
  out-of-scope host is dropped too. An in-scope host stays reachable.

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
- **The scope is two places.** The address set is in `scan0-egress.nft`, and
  the targets are in GVM. Widening means changing this ADR, the set and the
  target, together.
- **If a packaging change renames `ospd-openvas` or `mosquitto`,** the drop-in
  ordering or the `NetworkNamespacePath` join can break, and the scanner stops
  starting rather than starting unfenced. That is the safe direction, and the
  runbook's check after an upgrade names it.
- **A second MAC and a second address, `.63`, on garuda's NIC.** The macvlan
  answers ARP for `.63` on VLAN 30 while a scan runs. It is below the DHCP
  pool and is recorded in `docs/network.md`; morpheus needs no reservation,
  since the namespace sets it statically.
- **What the SOC sees is the point.** A scan's noise in Wazuh is expected and
  is not tuned away. Tuning that hides a scan would also hide an attacker's.
