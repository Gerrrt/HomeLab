# ADR-0033: Keep the iLO on the lab segment

**Status:** Accepted · 2026-09

## Context

[ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
puts `ifrit`'s attack VM on ImaginationLAN (30), sharing a broadcast domain with
`Saruman`'s Windows domain, because the techniques worth detecting are layer 2
and do not cross a router. It found, and deliberately did not decide, that this
puts `shiva` — the iLO 4 BMC of the box being defended, at `10.0.30.10` on
firmware 2.82 — layer-2 adjacent to a Kali VM. A BMC is not something that gets
patched the way a guest does. That is
[#235](https://github.com/Gerrrt/HomeLab/issues/235), and this ADR decides it.

ADR-0014 closes the *hypervisor* management planes at the host: the Proxmox
firewall on `Saruman` and `ifrit` admits `8006`, `8007` and `22` from Hicks
only. The iLO has no equivalent. It is a separate device on its own port,
reachable from anything on VLAN 30 that can ARP for it.

**What it is coupled to.** The only cross-segment pass pair on the lab
interface exists because the iLO is there:

| On interface | Rule | Purpose |
| --- | --- | --- |
| 99 | `10.0.99.20 → 10.0.30.10:161-162/udp` | SNMP-Exporter scrapes the iLO |
| 30 | `10.0.30.10 → 10.0.99.20/udp` | the iLO's "return path" |

Moving `shiva` to Winterfell (99) deletes both, which leaves VLAN 30 with
`Saruman`'s two agent passes and the tripwire and nothing else.

**Two facts have changed since #235 was written, and both push the same way.**

- The issue assumed console access was unaffected by a move, because "Hicks
  already reaches 99". Since 2026-09-02 that is a named list
  ([ADR-0031](0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md)):
  SSH, the firewall's UI, DNS, NTP, ping, the wiki, Grafana and the UPS card.
  A BMC on Winterfell would be reachable from a workstation on none of the
  ports that matter — `443` for its web UI, `17988` and `17990` for the remote
  console — without three new passes on the Hicks interface. The move is not a
  port swap; it is a widening of the management list for a device on firmware
  that will not get newer.
- The lab stack ([ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md))
  ships no snmp-exporter because `shiva` is the only SNMP device on its segment
  and is polled by the estate. That reasoning survives either placement, but a
  move would make the estate poll a Winterfell device across no boundary at
  all, and the lab's own Prometheus would be the natural home for a poll it
  currently has no reason to carry.

**The case for moving it** is that Winterfell is where compromise is total, and
a compromised BMC on VLAN 30 hands an attacker the host under the whole lab.
That is true. It is also the definition of the lab: the estate on `Saruman` is
the thing being attacked, and its BMC is part of that estate.
[ADR-0008](0008-place-services-by-data-trust.md) argued that the management
segment should not accumulate things, and a BMC whose firmware line has ended
is exactly the kind of thing it should not accumulate — next to the firewall's
admin interface, reachable from every Hicks device on a port that would have to
be opened for it.

## Decision

**`shiva` stays on ImaginationLAN at `10.0.30.10`.** The iLO is part of the
estate under attack, and a BMC compromise in the lab costs the lab. That cost
is accepted and recorded, not designed around.

Three things follow, none of them a firewall rule on `morpheus`:

1. **Harden the BMC itself**, on the iLO, by hand — the monitoring host cannot
   reach its UI and this repository does not manage it. IPMI-over-LAN off, so
   the classic IPMI attack surface is not offered to the segment at all; SSH
   and any other service the iLO offers that nothing uses, off; a local account
   with a credential that shares nothing with the house; and the iLO's own
   security log read once so its baseline is known. Recorded in `hardware.md`
   when done.
2. **The "return path" rule is redundant and should go.** pf keeps state for
   the scrape the monitoring host initiates, so the iLO's SNMP replies never
   consult the ruleset on VLAN 30. What that rule actually grants is `udp any`
   from the BMC to the monitoring host, which reaches Alloy's syslog listener
   on `514` and `1514`. A compromised BMC could inject log lines into the store
   the estate is judged by, through a rule that exists to carry replies it
   never carries. Deleting it is a firewall change on the Lemmiwinks side and
   is recorded here as the follow-up rather than done; until it is gone, the
   lab interface carries one pass more than this ADR describes.
3. **The residual goes where residuals go.** A row in `SECURITY.md`'s known
   exposure table, in the accepted-residual form, and a sentence in
   `docs/security.md` beside the lab's threat-table row.

## Consequences

- **The two SNMP rules stay**, and `targets/snmp.yaml`, the Kea reservation,
  the switch port and every document that carries `10.0.30.10` are unchanged.
  The disabled iLO UI probe in `targets/blackbox.yaml` keeps its address and
  its precondition: a `99 → 30:443` pass, which is a separate decision.
- **The lab tripwire watches the BMC too.** `shiva` is a `10.0.30.x` source,
  so anything it initiates toward the house is a logged pass on the tripwire
  and a `LabSegmentReachedInternalNetwork` alert
  ([#234](https://github.com/Gerrrt/HomeLab/issues/234)). It is the one
  cross-segment control that covers a device the estate cannot patch.
- **The firmware is watched, not assumed.** `check_versions.py` reads the iLO's
  version over SNMP and checks it against `network.md`, so a release that does
  arrive is noticed rather than missed; a version that never moves is the
  documented state of an end-of-line device, not a gap somebody forgot.
- **Reopened by:** iLO 4 receiving a firmware release that changes its
  exposure; a second BMC arriving on the lab segment (`ifrit` has none —
  [ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)); or
  the Hicks list growing the three iLO ports for some other reason, at which
  point the move costs what the issue originally thought it did.
