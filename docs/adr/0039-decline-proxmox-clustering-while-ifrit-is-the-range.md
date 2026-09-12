# ADR-0039: Decline Proxmox clustering while ifrit is the range

**Status:** Accepted · 2026-09

## Context

[#443](https://github.com/Gerrrt/HomeLab/issues/443) asked for a decision
before the question is asked by the hardware. Once
[#421](https://github.com/Gerrrt/HomeLab/issues/421) buys `ifrit` there will be
two Proxmox VE hosts on VLAN 30 — `Saruman` at `10.0.30.110`, moving to
`10.0.30.20` in the same build, and `ifrit` at `10.0.30.30` — and joining them
into one cluster will look like the obvious
next step: one pane of glass, guest migration, shared storage. It is the sort
of decision [ADR-0032](0032-decline-frigate-while-the-cameras-are-ring.md)
records rather than leaves to be re-proposed, for the reason the roadmap's
*Considered and declined* section gives: a thing rejected for good reasons with
nothing written down is indistinguishable from one nobody thought of.

The issue gave four reasons to decline. Three of them hold as written; the
first needs correcting before it is relied on, because a decline that rests on
a claim a reader can refute is weaker than one that does not.

**What a cluster actually is.** A Proxmox cluster is not a dashboard that
happens to list two hosts. It is corosync carrying a membership ring between
the nodes over UDP 5405; pmxcfs, which turns `/etc/pve` on every node into one
replicated filesystem; one authentication realm, so an identity with rights on
the datacenter has them on every node; and quorum, without which that
filesystem goes read-only and guests can neither be started nor changed until
an operator overrides it by hand. Every one of those properties runs into a
decision this repository has already made.

**It couples the attacker to the defended estate.**
[ADR-0007](0007-defensive-estate-and-offensive-range.md) puts them on separate
hosts so that "did the detection fire?" has a clean answer, and
[ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
keeps `ifrit`'s management plane closed to everything but Hicks. A shared
`/etc/pve` and a shared realm mean root on the attacker's host is root on the
estate's — one control plane and one blast radius across exactly the boundary
those two ADRs exist to draw. The isolation of the targets is already, in
ADR-0014's own words, one click from failing; a cluster puts that click on a
console the range shares.

**It cannot be built without reopening ADR-0014.** The corosync ring needs a
path between the two hypervisors, and ADR-0014 admits `8006`, `8007` and `22`
to each host from `10.0.50.0/24` only. Either that rule is widened to let the
two hosts talk to each other on VLAN 30 — with a guest that ARP-spoofs its
neighbour able to sit in the middle of the ring — or the ring gets the
dedicated link Proxmox recommends, which is the second physical NIC ADR-0014
names by name as grounds to supersede it, and which
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) decided
against cabling. A Proxmox SDN VLAN zone, the clustered way to share segments
between nodes, makes `vmbr0` VLAN-aware: the other named reopener.

**It breaks with a host that is off by design.** ADR-0007 has `ifrit` powered
off between sessions and ADR-0017 makes that a feature: nothing knows whether
the range is up, and nothing needs to. A two-node cluster has no quorum with
one node down, so every session would begin with `Saruman`'s `/etc/pve`
read-only and its guests unstartable until `pvecm expected 1` is run — the
estate's hypervisor held hostage to whether the range is plugged in. The fix
Proxmox offers is a third vote, a QDevice, which is a third host and its own
decision. ADR-0017 also decided that nothing in the estate's backup, monitoring
or patching loops gains a member on account of the range; a cluster adds the
range to the one loop underneath all three.

**And the issue's first reason, corrected.** #443 says clustering breaks
[#437](https://github.com/Gerrrt/HomeLab/issues/437) because sharing segments
across nodes needs a separate router or SDN, and with a separate router the
hypervisors stop seeing traffic that crosses it, "and port mirroring — the
mechanism Zeek depends on — is gone entirely." Two things are more precise.
The mirror #437 describes is an Open vSwitch mirror on `Saruman`'s own bridge,
not a SPAN from `neo` — [ADR-0006](0006-detect-at-the-chokepoint.md) keeps the
switch's mirroring disabled — so a cluster as such does not touch it; both
hosts are already on one access segment through `neo`, and nothing about
corosync moves a packet. What removes Zeek's view is what a cluster invites:
migrating the domain guests off the bridge the mirror is on, or an SDN zone
spanning both nodes so that east-west traffic no longer terminates on one
hypervisor. That is a real cost and it lands, as the issue says, at the
networking layer where this estate has been most careful and found the most
stale claims
([ADR-0025](0025-close-the-switch-lan-to-winterfell.md),
[#363](https://github.com/Gerrrt/HomeLab/issues/363)). It is the fourth reason,
not the first.

[ADR-0027](0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md)
is the precedent for the shape of the answer: a Proxmox feature that is real
and useful, declined until a precondition exists, with the precondition named.

## Decision

**Two standalone hypervisors. `Saruman` and `ifrit` are never joined into a
cluster while `ifrit` holds attack tooling.**

- Each host keeps its own root, its own `/etc/pve`, its own realm and its own
  host firewall, authored independently.
  [`build-the-playground.md`](../runbooks/build-the-playground.md) writes
  `ifrit`'s, and nothing on `Saruman` can change it.
- No Proxmox SDN on either host, and no second NIC, trunk or VLAN-aware bridge
  on either — unchanged from ADR-0014, and restated because SDN is the feature
  most likely to be reached for in a cluster's name.
- No shared storage between them. `Saruman`'s guests live on `Saruman`;
  `ifrit`'s targets are disposable by ADR-0017 and live nowhere else.
- Moving a guest between the two, should it ever be wanted, is an export and an
  import — `vzdump` on one side, `qmrestore` on the other — done by a person,
  through Hicks, with the guest's network detached first. Not migration.

What the cluster would have bought is given up knowingly: one pane of glass is
two browser tabs, and live migration is a capability the range's
snapshot-and-rebuild model does not need and the estate's guests have no reason
to use.

## Consequences

- **The management-plane rule stays as narrow as ADR-0014 wrote it.** Nothing
  on VLAN 30 gains a path to `8006` on either hypervisor, and neither host
  needs to reach the other at all.
- **Nothing in the estate's loops gains a member.** ADR-0017's list — no
  backups, no monitoring, no patching for the range — now also covers the
  quorum a cluster would have added underneath them.
- **`neo`'s port mirroring stays disabled** (ADR-0006), and #437's Zeek mirror,
  if built, stays on `Saruman`'s own bridge where the domain guests are.
- **Cross-host movement is manual and rare, and that is the point.** A guest
  that has been on the range does not come back to the estate by drag and
  drop; it comes back through a person who detached its network first.
- **The `Considered and declined` list in `roadmap.md` gains an entry** — its
  first that is a capability rather than a service — so the next time two
  hypervisors look like a cluster, the proposal argues with this document.
- **Reopened by any one of these**, each of which gets its own decision first:
  a third host that is neither attacker nor defended estate (a QDevice is
  exactly that, and buying one to make a two-node cluster work would be the
  purchase for a feature this document declines); a reason to migrate guests
  live that snapshot-and-rebuild does not serve; or `ifrit` ceasing to hold
  attack tooling, at which point ADR-0007's split no longer has anything to
  keep apart.
