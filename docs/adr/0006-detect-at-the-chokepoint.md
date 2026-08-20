# ADR-0006: Put network detection on the firewall, not on the hypervisor

**Status:** Accepted · 2026-08

## Context

[`security.md`](../security.md) states plainly that this network has no IDS/IPS.
That is the largest remaining hole in a design otherwise built around
segmentation: traffic is contained, but nothing inspects it.

A `pfSense-pkg-snort` package was installed at some point and never configured,
so the gap was real rather than merely undocumented.

The question is where a sensor should live. Three options:

1. **A Suricata/Zeek VM on `Saruman`, fed by a SPAN port from `neo`.** The
   MokerLink does support port mirroring — this was verified, and it is
   currently disabled. Mirroring the trunk would give the sensor every VLAN.
2. **A Suricata VM on `Saruman`, fed by a trunk port.** Same visibility,
   achieved by making the hypervisor VLAN-aware.
3. **Suricata on `morpheus`, inline on the interfaces already terminating
   there.**

The deciding fact is where the interesting traffic actually is. `Saruman` is
single-homed on a VLAN 30 access port, so a sensor there sees VLAN 30 — which is
to say, it sees `Saruman`. The segment that warrants inspection is **Skids
(20)**: seven cameras, a doorbell, an alarm hub, five voice assistants, two baby
monitors and a $20 Tuya device, every one of them running firmware nobody
outside its vendor has audited.

Options 1 and 2 both fix that by giving the *contained* segment a view of every
other segment. A SPAN destination is receive-only and unrouted, so it does not
technically violate the segmentation rules — but an all-VLAN tap terminating on
the box explicitly designated for breaking things is a worse trade than it
appears. Option 2 is worse still: it makes the lab hypervisor routable
everywhere.

Meanwhile every VLAN already terminates on `morpheus`. It is the one device that
sees inter-VLAN and egress traffic for the entire house, by construction.

## Decision

Suricata runs on **`morpheus`**, the firewall.

- **IDS mode only** to begin with — alert, never block — on the IoT and guest
  interfaces first, where a detection is most likely to be real.
- Alerts ship to Loki over the existing remote-syslog path, which
  `alloy/config.alloy` already ingests. No new collection mechanism.
- The unconfigured Snort package is removed rather than left installed. Two IDS
  packages, one of them dormant, is how you end up debugging the wrong one.

Port mirroring on `neo` stays disabled.

This ADR covers detection **for the house**. A sensor scoped to the lab segment
is a separate concern and is addressed in
[ADR-0007](0007-defensive-estate-and-offensive-range.md).

## Consequences

- The only point in the network that sees untrusted traffic is now instrumented,
  and it required no new hardware, no tap, and no firewall rule.
- The contained segment is not granted visibility of every other segment, so the
  trust boundary ADR-0002 establishes stays intact.
- **Load moves onto the single point of failure.** `morpheus` is an i5-8500T with
  32 GB, which is ample for Suricata at residential line rates — but it is also
  the box whose failure takes the house offline, and this makes it do more.
  Accepted knowingly; the mitigation is the restore story, not a smaller
  workload.
- Blocking stays off until the false-positive rate is known. A firewall that
  drops the baby monitor is a domestic incident, which is the standard this
  project set for itself.
- Cross-VLAN full packet capture for forensics is given up. If that is ever
  genuinely needed, `neo` can mirror on demand — a deliberate, temporary action
  rather than a standing configuration.
- Detection now depends on a FreeBSD package on an appliance rather than a
  container pinned by digest. That is a real inconsistency with how everything
  else here is deployed, and it is the honest cost of putting the sensor where
  the traffic is.
