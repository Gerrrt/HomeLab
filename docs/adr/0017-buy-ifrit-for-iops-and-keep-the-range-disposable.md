# ADR-0017: Buy ifrit for IOPS, and keep the range disposable

**Status:** Accepted · 2026-09

## Context

[ADR-0007](0007-defensive-estate-and-offensive-range.md) split the lab into a
defended estate on `Saruman` and an offensive range on `ifrit`, and left
`ifrit`'s isolation mechanism open.
[ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
closed that: `ifrit` is single-homed on ImaginationLAN, the vulnerable targets
attach only to a bridge with no physical port on a subnet `morpheus` does not
route, the attack VM is the one dual-homed guest and does not forward, and the
hypervisor management planes close at the host.

[`roadmap.md`](../roadmap.md) states what is left: "the purchase and a build
runbook that checks each of those". Three things have to be pinned before
either can happen, and none of them is settled anywhere.

**What to buy.** ADR-0007 says only that `ifrit` is "sized for on-demand use
and powered off between sessions".

**What the range's addresses are.** ADR-0014 says the target subnet is
"deliberately outside `10.0.0.0/16`" and stops there. A runbook cannot be
written against an adjective.

**What the range contains, and who keeps it running.** ADR-0007 says `ifrit`
"holds C2 and attack tooling, and the vulnerable targets", and that the
playground is "deliberately the least important part". Nothing says whether
those guests are backed up, monitored or patched — and the estate's answer to
each of those is already yes, which is the wrong answer here.

### The two facts that decide the purchase

**The fleet's measured bottleneck is spindles, not RAM.** ADR-0007: "The
constraint on `Saruman` is storage, not compute: 128 GB and 48 threads against a
single mirrored pair of 7.2K disks. The fleet is sized against spindles, not
RAM." A range's characteristic operation is *revert to clean* — clone a
template, break it, roll it back, do it again. That is the one workload where
the DL360's shape is worst, and buying a second machine with the same shape
would buy the same complaint twice.

**The estate has already been bitten by a ceiling it could not raise.**
[`hardware.md`](../hardware.md) on `prometheus`: "Its RAM is soldered at 8 GB".
That sentence is in the inventory because it is a permanent constraint on a
machine that is otherwise fine, and it was not chosen — it came with the box.

Four options for the machine:

1. **A second used 1U enterprise server.** Cheapest per thread and per gigabyte
   by a wide margin, which is exactly why `Saruman` is one. It also reproduces
   `Saruman`'s real defect — capacity stranded behind slow disks — and doubles a
   cost ADR-0007 already named and disliked: "a DL360 Gen9 is loud and lives in
   an occupied office". A machine you power on to use is the worst candidate for
   that trade.
2. **No purchase: run the range on `Saruman`.** ADR-0007 considered and rejected
   this as its option 1 — attacker and victim sharing a fault domain means you
   "can never fully separate 'my detection fired' from 'my own tooling made that
   noise'". Named here so the purchase is not assumed rather than argued.
3. **A quiet small-form-factor box with socketed RAM and NVMe.** The class
   `morpheus` is already drawn from, proven in this house and this rack.
4. **A hosted range.** Removes the machine entirely, and removes the point with
   it: ADR-0014 turns on the attack VM sharing a broadcast domain with the
   estate, because "the techniques the estate exists to detect are layer 2".

## Decision

**`ifrit` is bought for IOPS and quiet, and the range it runs is maintained by
nobody.**

### The purchase: decide the half that cannot be changed later

Option 3. Following [ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md),
which decided the NAS's bay count and left the drive capacity to be "chosen at
the till on cost per terabyte and recorded in `hardware.md` when it is bought",
this decides only what a later purchase cannot fix:

| | Decided | Why it cannot wait |
| --- | --- | --- |
| Disk | **NVMe.** Not a spindle, and not a mirror | The range's core operation is snapshot revert. A chassis without an M.2 slot cannot be given one |
| RAM | **Socketed, two slots, 32 GB fitted** | `prometheus` is the cautionary tale. Soldered RAM is a ceiling bought by accident |
| Form | **Quiet SFF or mini, not rack-mount** | Acoustics cannot be retrofitted, and ADR-0007 has already paid this once |
| Network | **One NIC is sufficient, and one is what gets cabled** | ADR-0014 lists "a second physical NIC" as a trigger to reopen it |

CPU model, disk capacity and the exact memory kit are chosen on cost when it is
bought, and recorded in `hardware.md` then. 32 GB is sized from what actually
runs — a Kali VM with BloodHound and its Neo4j alongside a C2 server wants
roughly half of it on its own, four concurrent targets most of the rest, and
Proxmox the remainder — and the second slot is there because that estimate is a
guess and the fix should be a memory kit rather than a machine.

**No redundancy.** ADR-0016 gave the NAS a ZFS mirror because the requirement
there was availability. Here the recovery model is *rebuild*, so a dead disk on
`ifrit` costs a weekend of reinstalling things that were designed to be
reinstalled. Buying two disks to protect a machine whose contents are
deliberately worthless is the kind of consistency that is not one.

### The address space: `172.30.30.0/24`, and no gateway at all

The isolated bridge is **`172.30.30.0/24`**. The attack VM takes
`172.30.30.10` on that leg; targets are static from `172.30.30.100` upward.

Rejected: `192.168.0.0/16`, the default of nearly every vulnerable image and
every consumer router, where a collision is likely and a leaked packet with a
`192.168` source is the least remarkable line in a log; any further
`10.0.0.0/16`, forbidden by ADR-0014 because a leak has to *miss* the
ImaginationLAN pass rule to be caught by default deny; and `100.64.0.0/10`,
which is Tailscale's, and would collide with a real overlay the day anything in
the house runs one. `172.16.0.0/12` is left, and the /24 sits high in it
because Docker's default pool walks that block upward from `172.17`: a target
running containers would have to stand up fourteen networks before it collided.
`172.30.30.0/24` also reads in a log line as what it is.

**Nothing on that subnet has a default route, and `vmbr1` has no address on the
host.** A default route pointing at a gateway that does not exist is a target
ARPing into the void on every outbound packet, and a configuration that starts
working the moment somebody gives that address to something. No default route
fails immediately, locally, and stays failed. This is ADR-0014's own reasoning
one level down: "a target with no route beats a target with a filtered route:
there is nothing to misconfigure, log, or keep in step with a runbook."

**No DHCP on the bridge.** The obvious place to run it is the attack VM, which
is the one guest with a leg on ImaginationLAN — and a DHCP server on a
dual-homed VM that binds the wrong interface is rogue DHCP on the segment
holding the estate's hypervisor and its BMC. That is a technique to practise
deliberately, not to commit by accident on a Tuesday. Images that insist on
DHCP get a static override, and that chore is named in the runbook.

`ifrit` itself takes **`10.0.30.30`** on ImaginationLAN, with a Kea
reservation, per ADR-0014. `.20` is left clear for `Saruman`, whose move below
`.100` ADR-0014 requires "at the same time" — nine references across eight
files carry `10.0.30.110`, one of them a firewall pass rule, so that move is a
step in the build runbook rather than a detail of it.

**The attack VM takes a DHCP lease from the pool.** Nothing in the estate
points at it, so nothing breaks when it moves, and a reservation on `morpheus`
maintained for the benefit of a machine whose entire job is to be hostile is a
piece of house configuration that exists for the range. An attacker's box takes
a lease.

### Contents: one attack VM, and a target set nobody owns

- **One attack VM.** Dual-homed, the only such guest, forwarding and NAT off,
  and its own tooling scoped on the VM to `10.0.30.0/24` and `172.30.30.0/24`
  per ADR-0014. It is the piece with real capability and the piece worth
  configuring carefully, because it is the half that closes ADR-0007's loop:
  the estate currently "has nothing attacking it".
- **The targets are chosen to be thrown away, and the set is expected to
  churn.** This ADR fixes the policy, not the images: attach to `vmbr1` only,
  static, no gateway, never patched, never persistent, reverted to snapshot at
  the end of every session. The images in use on any given day belong in the
  runbook, where a stale list is a five-minute correction rather than an
  amendment to an accepted decision.
- **Anything that starts to look realistic belongs on `Saruman`, not here.**
  That is ADR-0007's judgement — "popping a box built to be popped teaches very
  little" — turned into a rule for deciding where a new guest goes. A target
  that acquires a domain join, a real user or a monitoring agent has become part
  of the estate, and the estate is instrumented and on the other machine.

### Upkeep: none, and that is the decision rather than the omission

- **No backups.** `Saruman`'s Proxmox Backup Server does not take `ifrit`. The
  targets are disposable by construction, the attack VM's value is a
  configuration that can be rebuilt, and putting a deliberately-vulnerable image
  into the estate's backup store creates a supported path for it to arrive
  somewhere it should not be. Recovery is rebuild from the runbook.
- **No monitoring.** No Alloy agent, no SNMP target, no blackbox probe. `ifrit`
  is off by design between sessions, so every rule watching it would be
  permanently firing or permanently silenced, and
  [`observability.md`](../observability.md)'s standard for that is not met by
  either. It would also need a pass into Winterfell, and ADR-0014 accounts the
  ImaginationLAN interface at "one log-only tripwire, zero passes, zero blocks"
  once [#234](https://github.com/Gerrrt/HomeLab/issues/234) lands. The boundary
  that matters is watched by that tripwire, which works whether `ifrit` is
  powered or not.
- **No patching.** Of the guests. The Proxmox host is patched like any other
  host in the estate, because the host is the isolation mechanism.

### Ordering: what "after the main network is finished" means

The roadmap's constraint on this work is "only after the main network is
finished", which has never named an issue. It means three:

- **[#101](https://github.com/Gerrrt/HomeLab/issues/101) first, not this.**
  ADR-0007's `stacks/lab/` — the Windows domain, Wazuh, Velociraptor, the second
  observability stack. An attack VM pointed at an estate that is not
  instrumented teaches nothing, and building the range first builds the half
  ADR-0007 calls "deliberately the least important" before the half that carries
  the value.
- **[#234](https://github.com/Gerrrt/HomeLab/issues/234) before the range holds
  attackers.** It is the only thing watching the boundary this work creates, and
  it is described as "a no-op until the segment holds attackers" — which is the
  same sentence read from the other end.
- **[#235](https://github.com/Gerrrt/HomeLab/issues/235) decided either way.**
  `shiva` is a BMC on firmware that will not get newer, and this work is what
  makes it layer-2 adjacent to a Kali VM. A decision taken afterwards is taken
  under a fact that is already true.

Not gates, and worth saying so rather than leaving them to be assumed:
[#228](https://github.com/Gerrrt/HomeLab/issues/228) needs this build's list of
what a Hicks workstation reaches in VLAN 30 before it can narrow `50 → 30`, so
it waits on this rather than the reverse; and
[#229](https://github.com/Gerrrt/HomeLab/issues/229)'s exposure runs
`10.7.7.0/24` → everywhere, which is the direction the range does not travel —
VLAN 30's default deny still stops `30 → 10.7.7.0/24`.

## Consequences

- **The range costs one machine and no ongoing work**, which is the only shape
  in which the least important part of the lab is worth having at all. Nothing
  in the estate's backup, monitoring or patching loops gains a member.
- **Nothing knows whether `ifrit` is powered.** A range left running after a
  session is invisible to the estate, and there is no cheap alert for it: the
  useful statement is "this host is on when it should be off", and every rule
  shape available here says the opposite and fires nightly. The mitigation is
  that a running range with the targets still on `vmbr1` reaches nothing —
  which is the property ADR-0014 bought, being spent here.
- **`8007` on `ifrit` will admit nothing.** ADR-0014 wrote one management-plane
  rule for two hosts — "`8006`, `8007` (Proxmox Backup Server) and `22` from
  `10.0.50.0/24` only" — and this ADR gives `ifrit` no PBS. The rule is not
  narrowed here, because ADR-0001 does not let this file edit that one; but
  `roadmap.md` says of [#95](https://github.com/Gerrrt/HomeLab/issues/95)'s
  written-down-and-not-created rules that "a `pass` to an address with nothing
  behind it is a rule nobody can test", and that applies to this port. Recorded,
  not decided.
- **32 GB is a guess against a workload nobody has run yet**, and the honest
  version of the sizing table is that the second DIMM slot is the part that
  matters. If four concurrent targets and a BloodHound ingest turn out not to
  fit, the fix costs a memory kit; if the range is only ever two targets and a
  shell, half of it was bought for nothing and it was still the cheaper mistake.
- **`Saruman` moving to `10.0.30.20` is the riskiest step in the build**, and it
  is not optional — ADR-0014 requires it, and the reason is that `.110` sits
  inside the Kea pool. It touches a firewall pass rule that
  [`add-monitored-device.md`](../runbooks/add-monitored-device.md) documents,
  and eight files that carry the address. Nothing scrapes it — the agent
  pushes — which is what makes the move survivable.
- **The address space is now three private blocks in one house**, none of them
  routed to each other: `10.0.0.0/16` for the estate, `10.7.7.0/24` for the
  switch, and `172.30.30.0/24` for the range. That is one more thing to know
  before reading a log line, and it is the price of a source address that
  cannot be mistaken for anything real.
- **This decision is reopened** by any of ADR-0014's triggers, and by one of its
  own: a target that needs to be kept rather than rebuilt. The moment something
  on `ifrit` is worth backing up, it is estate and it is on the wrong machine.
