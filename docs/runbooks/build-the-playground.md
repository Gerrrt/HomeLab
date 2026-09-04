# Runbook: Build the playground on ifrit

**Target:** `ifrit` — the second hypervisor, on ImaginationLAN (VLAN 30)
**Time:** an afternoon for the host and the bridges, then as long as you like
for the guests
**You will need:** the machine itself, one Cat6 patch to a Green access port on
`neo`, the pfSense web UI on `morpheus`, and a shell on the monitoring host for
the verification in §8

This builds the offensive range
[ADR-0007](../adr/0007-defensive-estate-and-offensive-range.md) called for,
inside the isolation
[ADR-0014](../adr/0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
decided, to the shape
[ADR-0017](../adr/0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)
bought. ADR-0014 says its constraints are "checked by the build runbook rather
than assumed"; §8 is that check, and it is the reason this file exists.

> [!CAUTION]
> **The isolation here is one click from failing, and the click is easy.** A
> target NIC attached to `vmbr0` instead of `vmbr1`, or a sysctl on the attack
> VM, puts a deliberately-vulnerable machine on the same segment as the estate's
> hypervisor and its BMC, with internet. ADR-0014 names this as the real cost of
> the decision. Nothing in the firewall stops it, because there is no rule to
> stop it with — §8 and §9 are what stand in for one, and they are worth
> rerunning after any change to a guest's hardware.

---

## 0. Before you start

Three things belong ahead of this work, per ADR-0017:

| | Why it is first |
| --- | --- |
| [#101](https://github.com/Gerrrt/HomeLab/issues/101) — `stacks/lab/` on `Saruman` | An attack VM pointed at an estate with no Wazuh, no Velociraptor and no domain teaches nothing. This is the half that carries the value |
| [#234](https://github.com/Gerrrt/HomeLab/issues/234) — the ImaginationLAN tripwire | The only thing watching the boundary this build creates. It is a no-op until the segment holds attackers, which is what §5 makes it |
| [#235](https://github.com/Gerrrt/HomeLab/issues/235) — whether `shiva` stays on VLAN 30 | This build is what puts a Kali VM in the iLO's broadcast domain. Decide it before that is true, not after |

You will also need a free Green access port on `neo` and an outlet on the PDU.
`ifrit` does **not** hang off the unmanaged shelf switch: that switch is fed
from a Winterfell port, and `ifrit` belongs on ImaginationLAN.

The addresses this runbook uses, all decided in ADR-0017:

| | |
| --- | --- |
| `ifrit` on ImaginationLAN | `10.0.30.30/24`, gateway `10.0.30.1` |
| The attack VM's VLAN 30 leg | DHCP, from the `.100–.200` pool |
| The attack VM on the range bridge | `172.30.30.10/24`, no gateway |
| Targets | `172.30.30.100` upward, static, no gateway |

---

## 1. Rack, cable and install

One Cat6 from the machine's single NIC to a Green access port on `neo`,
untagged VLAN 30. **No trunk, no tagged port** — ADR-0014 applies ADR-0007's
constraint on `Saruman` to `ifrit` by name, and a VLAN-aware bridge here is
listed as a reason to reopen that ADR.

Install Proxmox VE. Take the defaults; the only thing worth deciding at install
time is the filesystem, and there is one disk, so it is ext4 or a single-disk
ZFS root. ZFS is worth it here for one reason: the range's whole operating model
is snapshot and revert.

Record what you actually bought in [`hardware.md`](../hardware.md) — the CPU,
the memory kit and the disk capacity are chosen at the till and written down
afterwards, which is the same split [ADR-0016](../adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
used for the NAS.

---

## 2. The two bridges

`/etc/network/interfaces` on `ifrit`. Substitute the real NIC name for
`enp1s0`:

```text
auto lo
iface lo inet loopback

iface enp1s0 inet manual

auto vmbr0
iface vmbr0 inet static
        address 10.0.30.30/24
        gateway 10.0.30.1
        bridge-ports enp1s0
        bridge-stp off
        bridge-fd 0

auto vmbr1
iface vmbr1 inet manual
        bridge-ports none
        bridge-stp off
        bridge-fd 0
```

Two things in there are load-bearing and neither is obvious:

- **`bridge-ports none` on `vmbr1`.** This is the isolation. It is not a filter
  and there is nothing to configure — the bridge has no path to a physical
  interface, so a guest on it can reach the other guests on it and nothing else.
- **`iface vmbr1 inet manual`.** The host takes no address on the range subnet.
  Give `vmbr1` an address and the hypervisor — the box whose management plane
  §4 closes — becomes a live host on the segment holding the vulnerable
  machines, and their only unreachable neighbour stops being unreachable.

Then add the reservation for `10.0.30.30` on `morpheus` alongside the other
ImaginationLAN statics. `.30` is below `.100` and therefore outside the Kea
pool, so unlike `Saruman`'s the reservation is not what protects the address —
it is there so the address is recorded where a reader looks for it, and so the
protection does not depend on the pool never moving.

---

## 3. Move `Saruman` to `10.0.30.20`

ADR-0014 requires this "at the same time", and the reason is in
[`network.md`](../network.md): `10.0.30.110` is the one fixed address in the
estate that sits *inside* a DHCP pool. It holds today only because the server is
Kea and consults reservations on every allocation; under the ISC dhcpd binaries
still on the box it would not.

This is the riskiest step in the build. Nothing scrapes `Saruman` by address —
its Alloy agent pushes — so the blast radius is one firewall rule and the
documents:

1. Change the static on `Saruman` and its Kea reservation to `10.0.30.20`.
2. Edit the pass rule on the **ImaginationLAN** interface from
   `10.0.30.110 → 10.0.99.20` to `10.0.30.20 → 10.0.99.20`, ports 9090 and
   3100, **logging off**, still above the ADR-0014 tripwire. It is documented in
   [`add-monitored-device.md`](add-monitored-device.md); logging it makes the
   agent's every push a hit on the tripwire.
3. Confirm the agent is still arriving before you move on — a broken rule looks
   exactly like a host that is down. The hypervisor should still be in this
   list:

   ```bash
   curl -s http://localhost:3100/loki/api/v1/label/host/values | jq -r '.data[]'
   ```

   `host` is `constants.hostname` as the agent sees it, so read the value out of
   the list rather than asserting one — see
   [`ship-firewall-logs.md`](ship-firewall-logs.md) for why that label means
   something different on relayed logs.
4. Update the address where the documents carry it: `hardware.md`,
   `network.md`, `architecture.md`, `add-monitored-device.md`,
   `replace-the-smart-storage-battery.md`, and the ADRs that quote the rule —
   those get a note rather than an edit, per
   [ADR-0001](../adr/0001-record-architecture-decisions.md). `roadmap.md` also
   carries `.110`, in a Done entry, and that one is **left alone**: it records
   what was true when that work landed.

---

## 4. Close the management plane

ADR-0014: the Proxmox firewall on `Saruman` and on `ifrit` admits `8006`,
`8007` and `22` from `10.0.50.0/24` only. This is the one gap the design opens —
an attacker sharing a broadcast domain with a hypervisor — and it is closed on
the host rather than at a segment boundary, because there is no boundary between
them.

> [!CAUTION]
> Enabling the Proxmox firewall with a `DROP` input policy will lock you out of
> a machine whose console is a KVM switch away. Write both files, check the
> rules render, and only then enable. Have the console to hand.

`/etc/pve/firewall/cluster.fw`:

```ini
[OPTIONS]
enable: 1
policy_in: DROP
```

`/etc/pve/nodes/ifrit/host.fw`:

```ini
[OPTIONS]
enable: 1

[RULES]
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8006 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8007 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 22 -log nolog
```

`8007` is Proxmox Backup Server and nothing on `ifrit` listens on it — ADR-0017
gives the range no backups. The rule is written as ADR-0014 specifies rather
than narrowed here; ADR-0017's Consequences record that it admits nothing.

**Then turn the firewall off on every guest NIC** (`firewall=0`, or the
checkbox clear in the hardware tab). This is what makes ADR-0014's "guests are
unaffected" true rather than assumed: the datacenter-level enable above is what
brings the per-NIC flag to life, and that flag is set by default on any NIC
added through the GUI. A range whose hypervisor quietly filters its own guests
is a range that lies to you about what your tooling did — and the isolation
here is the bridge, not the guest firewall, so clearing it costs nothing.

---

## 5. The attack VM

One VM, and it is the only guest with a leg on both bridges.

- **`net0` on `vmbr0`** — ImaginationLAN, DHCP from the pool. Nothing points at
  this address, so it does not get a reservation.
- **`net1` on `vmbr1`** — `172.30.30.10/24`, **no gateway**.

Forwarding off, persistently. `/etc/sysctl.d/99-no-forward.conf`:

```ini
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
```

`sysctl --system` to load it, and note the trap: **installing Docker sets
`ip_forward=1` at daemon start**, whatever this file says, and it will do it
again on every boot. If the attack VM needs containers, the file is not enough
and §8's check is what tells you.

No NAT. There is nothing to configure to achieve that — the point is to confirm
nothing has configured it, which §8 does.

Scope the tooling on the VM itself, per ADR-0014: scans and sweeps are bounded
to `10.0.30.0/24` and `172.30.30.0/24`. "That is where a mis-scoped scan is
actually stopped — at the tool, not at a segment boundary that would let it
through on 443 anyway."

**What a Hicks workstation reaches on this machine** — write it down as you
build it, because [#228](https://github.com/Gerrrt/HomeLab/issues/228) cannot
narrow `50 → 30` without the list: Proxmox on `10.0.30.30:8006`, the C2
operator's interface on the attack VM, and whatever the lab's Grafana and RDP
into the estate already need on `Saruman`.

---

## 6. The targets

Each target attaches to **`vmbr1` and nothing else**, takes a static address
from `172.30.30.100` upward, and has **no default route**. Every image insisting
on DHCP gets a static override before its first boot on the bridge — ADR-0017
declines to run a DHCP server here, because the obvious place to run one is the
dual-homed VM, and a DHCP server that binds the wrong interface there is rogue
DHCP on the segment holding the estate's hypervisor and its BMC.

Take a snapshot named `clean` before the first session and revert to it after
every one. The images in use are a working list and belong here rather than in
an ADR; they are expected to churn, are never patched, and are never backed up.

**A guest that acquires a domain join, a real user or a monitoring agent has
stopped being a target and become part of the estate** — which lives on
`Saruman`, where it is instrumented. That is ADR-0007's judgement turned into a
placement rule, and it is the question to ask before adding anything here.

---

## 7. Powering the range

`ifrit` is off between sessions. There is no alert for it being left on, and
ADR-0017 says why: every rule shape available says "this host is down", which is
the normal state. Nothing is watching, so the discipline is yours.

```text
on  → revert every target to `clean` → work → revert → off
```

---

## 8. Check the four properties

ADR-0014 makes four claims. Each one is checkable, and none of them is checked
by anything else in this repository.

**One — `ifrit` is single-homed, and `vmbr1` has no port.** On the host:

```bash
ip -br link show type bridge
bridge link show
```

`vmbr0` should carry exactly one physical interface. `vmbr1` should appear in
the first command and contribute **nothing but guest taps** to the second. A
physical NIC name under `vmbr1` is the failure this whole design is built to
avoid.

**Two — no trunk, no VLAN-aware bridge.**

```bash
grep -c 'bridge-vlan-aware\|vlan-aware' /etc/network/interfaces
```

Zero. Anything else and ADR-0014 has been reopened without an ADR saying so.

**Three — the attack VM does not forward, and does not NAT.** On the VM:

```bash
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
nft list ruleset 2>/dev/null | grep -i 'masquerade\|snat' || echo "no NAT"
iptables -t nat -S 2>/dev/null | grep -- '-j MASQUERADE' || echo "no legacy NAT"
```

Both sysctls `= 0`, and no NAT from either table — Kali's `iptables` is
nft-backed, so the two commands can disagree about a rule that exists. Run this
after installing anything that touches the network stack, not just once.

**Four — a target has no route anywhere.** On a target:

```bash
ip route
ping -c1 -W1 10.0.30.1
ping -c1 -W1 1.1.1.1
```

No `default` line in the first, and both pings failing with *Network is
unreachable* rather than timing out. A timeout means a default route exists and
something is swallowing the packets, which is a different and much worse state:
it is a filtered target rather than an unrouted one.

---

## 9. Prove that a leak reports itself

ADR-0014 claims a specific safety property: the target subnet was chosen so that
a forwarded packet "arrives at the firewall with a source outside
`10.0.30.0/24`, misses the `→ any` pass, hits default deny and is logged as a
block. A leak reports itself."

That is worth proving once, and it can only be proved by causing one. **Do this
with a throwaway Linux guest on `vmbr1`, before any vulnerable image exists on
the machine.**

1. On the attack VM, turn forwarding on for the test only —
   `sysctl -w net.ipv4.ip_forward=1`. Add **no** NAT: without it nothing comes
   back, which is what keeps this bounded.
2. On the throwaway guest, add a default route via `172.30.30.10` and send
   something outbound: `ping -c3 1.1.1.1`.
3. On the monitoring host, look for the block:

   ```bash
   curl -sG http://localhost:3100/loki/api/v1/query \
     --data-urlencode 'query=sum by (src) (count_over_time({app="filterlog", action="block"} | regexp `,(?P<src>\d+\.\d+\.\d+\.\d+),(?P<dst>\d+\.\d+\.\d+\.\d+),` | src =~ "172\\.30\\.30\\..+" [15m]))' \
     | jq '.data.result'
   ```

   A row with a `172.30.30.x` source is the property working. **An empty result
   is not a pass** — it means the leak was silent, and you should find out
   whether the packet was forwarded at all before concluding anything.
4. Turn forwarding back off, remove the route, delete the guest, and rerun §8's
   third check.

Addresses are parsed at query time rather than indexed, per
[ADR-0003](../adr/0003-observability-stack-selection.md), which is why this is a
`| regexp` over a metric query and not a label selector.

---

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| Locked out of the Proxmox UI after §4 | `policy_in: DROP` with the rules unrendered, or reaching it from somewhere other than Hicks | Console via the KVM; `pve-firewall stop` |
| A target can reach the internet | Its NIC is on `vmbr0` | Move it to `vmbr1`, then §8 and §9 |
| A target can reach `10.0.30.x` but not the internet | The attack VM is forwarding | §8, check three. Look for Docker |
| The attack VM's tools see nothing on VLAN 30 | The guest firewall flag is still set on `net0` | Clear it — end of §4 |
| Everything on `vmbr1` can reach everything else and nothing outside | Working as designed | — |
| `Saruman` stops appearing in Loki after §3 | The pass rule still names `.110` | §3, step 2 |
| Kea hands `10.0.30.30` to something else | The reservation was not added | §2 |
| The §9 query returns nothing | Either the leak never happened, or firewall logs are not arriving | Check the pipeline first: [`ship-firewall-logs.md`](ship-firewall-logs.md) §5 |

---

## Also worth knowing

**The range is not monitored and not backed up, and both are decisions.**
ADR-0017 declines an Alloy agent because `ifrit` is off by design, so any rule
watching it is permanently firing or permanently silenced; and it declines PBS
because a deliberately-vulnerable image in the estate's backup store is a
supported path for it to arrive somewhere it should not be. If you find yourself
wanting to back something up here, the thing you want to keep has stopped being
range and started being estate, and it is on the wrong machine.

**The tripwire is the only thing watching.** `pass` + `log` for
`vlan30 net → Internal_Segments` on the ImaginationLAN interface, below the
blocks and the `quick` iLO pass, above the `→ any` egress rule
([#234](https://github.com/Gerrrt/HomeLab/issues/234)). It matches nothing while
this design holds. **A line in it is an incident**, not a tuning exercise:
ADR-0014 says the segment that holds attackers has reached the house, and that
the ADR was wrong somewhere.

**Reaching in is still wholesale.** A Hicks workstation reaches all of VLAN 30
on every port, because the Hicks interface blocks 40/20/10 and then passes to
`any` ([ADR-0013](../adr/0013-segment-access-as-implemented.md)). Once this
build exists, that path enters hostile layer 2: the lab domain gets its own
credentials, and none of the house's.
