# ADR-0014: Put ifrit on ImaginationLAN and give the targets no route

**Status:** Accepted · 2026-09

> [!NOTE]
> The details this ADR leaves as adjectives — which subnet "deliberately
> outside `10.0.0.0/16`" is, what `ifrit` is bought as, and who maintains the
> guests — are filled in by
> [ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md),
> 2026-09: `172.30.30.0/24` with no gateway on it, a quiet NVMe box with
> socketed RAM, and no backups, monitoring or patching for the range. Nothing
> here is amended; the constraints below are what
> [`build-the-playground.md`](../runbooks/build-the-playground.md) checks.

## Context

[ADR-0007](0007-defensive-estate-and-offensive-range.md) split the lab into a
defended estate on `Saruman` and an offensive range on `ifrit`, and then
declined to say where `ifrit` goes: "whether it gets a dedicated VLAN or a
physically separate network is deferred deliberately". Two issues carry that
deferral from opposite sides — [#86](https://github.com/Gerrrt/HomeLab/issues/86)
asks whether ImaginationLAN (30) needs egress filtering before the playground
exists, and [#96](https://github.com/Gerrrt/HomeLab/issues/96) asks what
`ifrit`'s isolation mechanism is. They are one question. This ADR answers it.

What VLAN 30 is today, per [ADR-0013](0013-segment-access-as-implemented.md):
default deny to every other segment, with one explicit exception —
`10.0.30.10 → 10.0.99.20/udp`, the iLO's SNMP return path. Egress to the
internet is open. Hicks (50) reaches all of it through its catch-all, which
[#228](https://github.com/Gerrrt/HomeLab/issues/228) has yet to decide about.
The firewall is `morpheus`, configured by hand, not from this repository.

The fact that decides the placement question: **the techniques the estate
exists to detect are layer 2.** LLMNR and NBNS poisoning, ARP spoofing, rogue
DHCP, mitm6, WPAD — the bread and butter of an internal engagement, and
precisely what a Windows domain instrumented with Wazuh and Velociraptor teaches
you to see — do not cross a router. If the attack VM is not in the domain's
broadcast domain, the estate never experiences them, and ADR-0007's reason for
existing ("detecting a real technique against a realistic estate teaches a
great deal") does not survive. It is also why ADR-0007 puts lab detection on
`Saruman`: it sees VLAN 30 by construction, and nothing else.

Four options:

1. **Contain at the hypervisor.** `ifrit` joins VLAN 30 like `Saruman` does.
   The vulnerable targets live only on a bridge inside `ifrit` that has no
   physical port, so they have no route to anything — not filtered, absent.
   Only the attack VM touches VLAN 30. No new segment, no new pass rules.
2. **Filter VLAN 30's egress by port.** DNS to the gateway only, NTP, 80 and
   443, ICMP, block and log the rest: roughly six hand-entered rules on an
   interface that already carries the iLO exception and five blocks. Every
   scanner and every C2 framework speaks 443, so the one thing this is imagined
   to stop walks through it. What it does stop is quiet: a domain controller
   syncing time from `time.windows.com` drifts once 123/udp is blocked, and
   Kerberos fails domain-wide five minutes later with nothing to show for it
   but w32time events on the DC. NCSI probes on port 80, and Windows decides it
   has no internet. [`security.md`](../security.md) already declines egress
   filtering by domain, and [ADR-0010](0010-keep-the-resolver-on-the-gateway.md)
   records why DNS filtering is a convenience and not a control. A port
   allowlist is the weakest member of that family.
3. **A dedicated range VLAN.** `ifrit` on its own segment with no egress and a
   pass rule into 30 for the attacks. This is the segment
   [ADR-0008](0008-place-services-by-data-trust.md) declined once. It routes
   every attack through the one box whose failure takes the house offline — a
   full-port scan of a `/24` through the firewall is millions of state-table
   entries on a device sized by RAM, and exhausting it drops new connections
   for everyone. Either Suricata watches that interface, and every session
   fires the *house* alerts and lands lab telemetry in the production Loki
   through the syslog pipe — the thing ADR-0007 forbids — or it does not, and
   the segment has bought no visibility `Saruman` lacked. It needs a
   `30 → range` callback rule as well, because victims call the C2, which makes
   the range reachable from any compromised guest. And it never sees the
   layer-2 techniques at all.
4. **A physically separate network.** `ifrit` on its own switch with no uplink.
   The strongest isolation available, and it means `ifrit` cannot reach
   `Saruman`, so "the estate has nothing attacking it" — the open loop ADR-0007
   names as its own cost — stays open permanently. Dual-homing something to
   close that is what ADR-0007 forbade.

## Decision

**No egress filtering on ImaginationLAN. `ifrit` joins it. The targets get no
route.**

- **VLAN 30 membership means internet.** The non-goal in `security.md` — no
  egress filtering by domain — extends to by port, for ADR-0010's reason: it
  would be described as a control and would not be one. Anything that must not
  reach the internet does not get a VLAN 30 interface.
- **`ifrit` is single-homed on VLAN 30**, the same way `Saruman` is: one
  physical NIC on an untagged Green access port, `vmbr0` on it, a static
  address below `.100` with a Kea reservation. ADR-0007's constraint on
  `Saruman` — no trunk, no VLAN-aware bridge — applies to `ifrit` by name.
  `Saruman` moves below `.100` at the same time; [`network.md`](../network.md)
  has wanted that since the reservation was found missing.
- **The vulnerable targets attach only to a second bridge with no physical
  port** (`bridge-ports none`), on a subnet `morpheus` has no interface for and
  no route to, deliberately outside `10.0.0.0/16`. A target with no route beats
  a target with a filtered route: there is nothing to misconfigure, log, or
  keep in step with a runbook.
- **The attack VM is the only dual-homed guest.** IPv4 and IPv6 forwarding off,
  no NAT, and checked by the build runbook rather than assumed. Its own
  outbound scope is limited on the VM itself, to `10.0.30.0/24` and the target
  subnet. That is where a mis-scoped scan is actually stopped — at the tool,
  not at a segment boundary that would let it through on 443 anyway.
- **The hypervisor management planes close at the host.** The Proxmox firewall
  on `Saruman` and on `ifrit` admits `8006`, `8007` (Proxmox Backup Server) and
  `22` from `10.0.50.0/24` only. Guests are unaffected. This is the one real
  gap option 1 opens — an attacker sharing a broadcast domain with the estate's
  hypervisor — and this is where it is closed.
- **One log-only tripwire on the ImaginationLAN interface**, in the shape
  [#223](https://github.com/Gerrrt/HomeLab/issues/223) gave the terminal
  segments: `pass` + `log` for `vlan30 net → Internal_Segments`, below the
  block rules and the `quick` iLO pass, above the `→ any` egress rule. It
  matches nothing while the design holds; if it logs a line, the segment that
  holds attackers has reached the house. It gets a sibling Loki rule, because
  `TerminalSegmentReachedInternalNetwork` hard-codes its sources as 10, 20 and
  40. Decided here, built as [#234](https://github.com/Gerrrt/HomeLab/issues/234).
  It cannot weaken anything. It turns the threat-table row "a lab VM escaping
  into the house" from a sentence into something watched.
- **The iLO exception and the Hicks catch-all are unchanged.** This ADR adds no
  pass rules and removes none. VLAN 30's egress passes are not logged; #223
  measured what that costs.

## Consequences

- The boundary being exercised stays inside one layer-2 domain, where
  `Saruman`'s sensor sees it and `morpheus`'s does not. The house alerts stay
  about the house, and no lab telemetry crosses into Winterfell — ADR-0007
  holds without a rule to make it hold.
- **Isolation of the targets is one click from failing.** A target NIC moved
  from the portless bridge to `vmbr0`, or a sysctl on the attack VM, and a
  deliberately-vulnerable machine is on VLAN 30 with internet. That is the real
  cost of this decision, and it is a property of a virtualised range under any
  of the four options — a dedicated VLAN would not have stopped a guest landing
  on the wrong bridge either. Two things make it survivable: the build runbook
  checks both, and the target subnet is chosen so that a forwarded packet
  arrives at the firewall with a source outside `10.0.30.0/24`, misses the
  `→ any` pass, hits default deny and is logged as a block. A leak reports
  itself. #234 carries the optional Loki rule that turns that line into an
  alert.
- **The defended estate's BMC sits on the attackers' segment.** `shiva`, the
  iLO at `10.0.30.10`, is now layer-2 adjacent to a Kali VM, and a BMC does not
  get patched the way a guest does. The only explicit pass on the ImaginationLAN
  interface exists *because* the iLO is there; moving it to Winterfell would
  delete both SNMP rules and the exception, and Hicks already reaches 99 for
  console access. Whether it should move is a question this ADR records and
  does not answer — [#235](https://github.com/Gerrrt/HomeLab/issues/235).
- **This ADR consumes `50 → 30` wholesale.** Proxmox on two hosts, the lab's
  Grafana, RDP into the estate, the C2 operator's interface: a workstation on
  Hicks needs all of them. #228 cannot narrow that path without that list; its
  "block `50 → 99` only" option is compatible with this decision. The direction
  that matters is the other one — `30 → 50` stays blocked, and a lab that now
  contains attackers makes that block load-bearing rather than tidy. A Hicks
  client connecting into VLAN 30 is entering hostile layer 2: the lab domain
  gets its own credentials, and none of the house's.
- Firewall rule surface, once #234 lands: one log-only tripwire, zero passes,
  zero blocks. ADR-0013's table of cross-segment passes is unchanged.
  [`restore-the-firewall.md`](../runbooks/restore-the-firewall.md) will expect
  four tripwires where it now expects three.
- **Any one of these reopens the decision** and gets a superseding ADR:
  something on `Saruman` must be *unable* to reach the internet (detonating
  real samples on the estate — and note that option 2 would not have helped);
  Suricata is wanted on the ImaginationLAN interface, which reopens the
  [ADR-0006](0006-detect-at-the-chokepoint.md) and ADR-0007 split, not just
  this; #228 narrows `50 → 30` without the list above; `ifrit` gains a trunk,
  a second physical NIC or a VLAN-aware bridge for any reason; or remote access
  into VLAN 30 is wanted, which also takes ADR-0008's "no external access"
  premise with it. The lab tripwire firing is an incident rather than a reopen,
  but it is evidence this ADR was wrong somewhere, and should be read that way.
