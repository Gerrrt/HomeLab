# ADR-0019: Read device joins from the DHCP server, not from the eero cloud

**Status:** Accepted · 2026-09

## Context

[#98](https://github.com/Gerrrt/HomeLab/issues/98) asks for a Home Assistant
integration with the eero API so that device joins and leaves stop being
discovered by accident, and it is right about the important half: the events
belong in the log pipeline that already exists — Alloy's syslog listener on
1514, Loki, and a rule in `security.rules.yaml` — rather than in a Home
Assistant notification, because that is where every other security signal in
this estate lives.

It is the other half that this decision is about. **Where the events come from
was assumed rather than chosen**, and the assumption came with a dependency:
Home Assistant sits on ADR-0008's sensitive tier, on a mini PC nobody has
bought, so the issue as filed cannot be built at all today.

Two things were checked before accepting that, one about eero and one about
this network.

### What "the eero API" is

There is no local one. eero is managed from a phone app against a cloud
service; the units serve no management interface on the LAN, so an integration
cannot ask an access point in this house what just associated to it.

The integration everyone means by "the eero integration" is
[`schmittx/home-assistant-eero`](https://github.com/schmittx/home-assistant-eero)
— a HACS custom component rather than anything in Home Assistant core. Read on
2026-09-04, its API base is `https://api-user.e2ro.com` and its default poll
interval is 120 seconds. Its README also records that it cannot log in with an
Amazon-linked eero account at all; the workaround it offers is to create a
second, non-Amazon account and add that as a network admin.

So the shape of the proposal, stated plainly: a join that happens on this
network would be reported to Amazon, held there, and fetched back over the WAN
up to two minutes later by an unofficial component, to be written into a log
store two hops from the wire the association actually happened on.

### What this network already sees

The eeros here are bridged access points on tagged VLANs — `network.md` lists
units on Hicks, Skids and Degens, which is three eero systems, because the
hardware does not tag — and `morpheus` serves DHCP for all seven segments. The
bridging is visible rather than assumed: every wireless client in the house
takes its lease from Kea on the firewall, phones and cameras included, which
could not happen if an eero were routing.

`morpheus` is already shipping syslog to Alloy for firewall and system events.
Measured on the firewall on 2026-09-04:

| Fact | Value |
| --- | --- |
| DHCP backend | Kea, syslog program name `kea-dhcp4` |
| Lease lifetime | 7200 s (`valid-lifetime`), so devices renew about hourly |
| Volume | ~1,200 lines/day across all seven segments |
| `DHCP4_LEASE_ALLOC` | 4,732 lines in four days, from 57 distinct MACs |
| Largest gap between lines | 975 s, over the 13 days since the firewall settled |
| Remote forwarding today | Off — `/var/etc/syslog.d/pfSense.conf` excludes `kea-dhcp4` from the System Events selector, so it needs its own content class |

Every message type carries the client's MAC and the address in one line:

```text
Sep  3 22:12:16 morpheus kea-dhcp4[62524]: INFO  [kea-dhcp4.leases.0x…]
DHCP4_LEASE_ALLOC [hwtype=1 04:42:1a:…], cid=[01:04:42:1a:…], tid=0xb53e488e:
lease 10.0.50.90 has been allocated for 7200 seconds
```

The event the issue wants is one checkbox and three rules away from a stream
this estate already carries, on a path that never leaves the house.

## Decision

**Device joins are read from Kea's lease log on `morpheus`.** The DHCP content
class is enabled in pfSense's Remote Syslog Contents, the lines arrive on the
same 1514 listener as filterlog and land with `app="kea-dhcp4"`, and
`loki/rules/security.rules.yaml` gains a `dhcp` group with three rules:

| Rule | Segment | Severity |
| --- | --- | --- |
| `UnknownDeviceOnTrustedSegment` | Hicks (50) | warning |
| `UnknownDeviceOnManagementSegment` | Winterfell (99) | critical |
| `DhcpLeaseLogsStopped` | — | warning |

**A lease is not a join.** With a two-hour lifetime, `DHCP4_LEASE_ALLOC` is
overwhelmingly a renewal — 4,732 of them in four days from 57 devices. The
event worth alerting on is the *first* line from a MAC on a segment, and LogQL
can express that without any state of its own: everything seen in the last ten
minutes, `unless` everything seen in the seven days before that.

```logql
sum by (mac) (count_over_time({app="kea-dhcp4"} | regexp `…` | vlan = "50" [10m]))
unless
sum by (mac) (count_over_time({app="kea-dhcp4"} | regexp `…` | vlan = "50" [7d] offset 10m))
```

`mac` is a parser label, extracted at query time and never at ingest — the same
decision, for the same reason, as source and destination addresses in the
filterlog rules next to it. ADR-0003 records label cardinality as this stack's
live constraint, and one stream per MAC is the textbook way to detonate it.

**The known-device list is the log history, not a file.** No allowlist of
household MAC addresses is written down anywhere, which matters because
`security.md` says a full device fingerprint of a house is exactly what this
public repository does not publish. A rule that had to enumerate the trusted
MACs would have published them; this one asks Loki what it has already seen.

**Only two segments are watched.** Winterfell, where nothing joins by accident:
zero first-seen events in 13 days of logs. Hicks, because it is the only
segment with a path into management and its Wi-Fi is a pre-shared key that
people are given. Skids, CasaBonita and Degens are deliberately excluded — new
devices arrive on them by design, they are terminal by ADR-0002, and the
tripwires that matter there already exist in the firewall group.

**Leaves are dropped as a requirement.** DHCP sees them only when a client
bothers to release, which almost nothing does: 9 releases in four days against
4,732 allocations. Nothing else here can see a departure either, and a
departure is not a security event — the devices whose absence matters are the
ones blackbox and SNMP already probe.

### What was rejected

- **Home Assistant plus the eero cloud integration — the issue as filed.**
  Rejected as the source, not merely deferred behind the hardware. It routes a
  signal about this network's own wire through a vendor cloud and back; it is
  therefore blind exactly when the WAN is down, which is one of the moments
  someone would care; it depends on an unofficial component whose auth story is
  a token obtained from an emailed code and which cannot log in with an
  Amazon-linked account without a second account created to work around it; it stores credentials that control the estate's
  wireless on a host that would then hold the locks and the cameras too; and it
  polls at 120 seconds for an event the firewall logs in the same second. The
  eero units here are also bridged, and what the eero cloud reports about
  clients in bridge mode is not something this repository has verified.
- **The switch's MAC address table.** `neo` could be polled for
  `dot1dTpFdbTable` over SNMP, which is local and vendor-free. But every
  wireless client in the house arrives through a bridged eero, so they all land
  on the port the eero is plugged into; an FDB walk is a table rather than an
  event; and `neo` is the device already carrying three firmware limits (#84,
  #85, ADR-0018). It would cost a new high-cardinality poll to learn less.
- **Deriving joins from filterlog or Suricata.** Both see traffic, not
  membership: a device is visible once it talks, and only then. The
  segmentation rules already read those streams for the question they are good
  at.
- **Making Kea refuse unknown clients.** This turns a join into a failure
  rather than into an event, and it breaks guest and IoT onboarding on the two
  segments where strangers are the normal case.

## Consequences

- **DHCP shipping must be enabled on `morpheus` before this merges.**
  `DhcpLeaseLogsStopped` is `absent_over_time`, and a stream that has never
  existed is absent: verified against a real Loki, the expression returns 1 for
  a stream nobody ever pushed. Merged ahead of the checkbox, the rule fires
  truthfully and permanently. This is the same ordering ADR-0018 needed for the
  host override, and [`ship-firewall-logs.md`](../runbooks/ship-firewall-logs.md)
  is the procedure.
- **The first week is an inventory, not an alert storm to be silenced.** Until
  seven days of lease history exist, the right-hand side of every rule is
  empty and each device announces itself once — about twenty on Hicks, three on
  Winterfell, one each. Every one of them is a claim to check against
  `network.md`, and then it is quiet.
- **The measured rate on Hicks is roughly one alert every three days**, from
  the 13 days of `dhcpd.log` this rule was written against: one device that
  arrived and stayed, one phone rotating its private Wi-Fi address, two an OUI
  the inventory places on Skids taking a brief lease on Hicks, one a new
  machine on a familiar OUI. That last pair is the argument for the rule
  existing — the inventory did not know about them — and the rate is the
  argument for warning rather than critical.
- **Private MAC addresses are the noise floor and are not filtered out.** Five
  of the twenty MACs seen on Hicks are locally administered, which is iOS and
  Android rotating their per-network addresses; each rotation reads as a new
  device. Excluding them would silence precisely the class of address an
  intruder would present.
- **A device with a static address is invisible to this, and always will be.**
  So is the difference between wired and wireless on Hicks, which VLAN alone
  cannot tell — the segment is the resolution this source offers. eero would
  have given the access point, the band and the roam; none of that is bought
  here.
- **~1,200 lines/day are added to a 30-day Loki on a 2012 MacBook.** That is
  about 1.3% of what filterlog already contributes at 3,798 lines an hour, so
  the caution `ship-firewall-logs.md` records about turning content classes on
  is answered with a number rather than waived.
- **Seven days is the baseline because 30 days is the retention.** A device
  away for longer than the window re-announces itself when it comes back, which
  is a false positive with an obvious explanation; a longer window would cost
  more per evaluation and still have an edge. The group evaluates every five
  minutes rather than every minute for the same reason.
- **The Loki rule count rises from 13 to 16**, and `observability.md`, the
  README and `security.md` carry counts that CI checks.
- **#98 stops depending on #102.** Home Assistant is no longer the prerequisite
  for the estate seeing device joins, which removes the one automation item
  that was blocked behind unbought hardware. Home Assistant, when it arrives,
  arrives to control IoT devices — the job ADR-0008 gave it.
- **What would reopen the eero question:** an eero API that can be reached on
  the LAN, or a need for the three things DHCP cannot supply — association
  without a lease, the access point a client is on, and roaming between them.
  None of those is worth a cloud round trip today, and the first would change
  the argument entirely rather than partially.
