# ADR-0029: Size the lab domain by what it must be able to do, and give it its own namespace and clock

**Status:** Accepted · 2026-09

## Context

[ADR-0007](0007-defensive-estate-and-offensive-range.md) gave `Saruman` "a small
Windows domain, realistic endpoints" and never said how small.
[ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
then made that domain the load-bearing part of the segment's whole arrangement:
the techniques it exists to detect — LLMNR and NBNS poisoning, ARP spoofing,
rogue DHCP, mitm6, WPAD — are layer 2, and reach only a domain sharing their
broadcast domain. [#101](https://github.com/Gerrrt/HomeLab/issues/101) split the
work seven ways and [#265](https://github.com/Gerrrt/HomeLab/issues/265) is the
one everything else points at.

Two files already say so in their own comments.
[`compose.yaml`](../../stacks/lab/compose.yaml) names the domain first among the
things sharing the spindles, and
[`prometheus.yaml`](../../stacks/lab/prometheus/prometheus.yaml) ends by saying
its missing job list "is #265's work". So the shape of the decision is already
half-written; what is missing is every number in it.

Four questions block the build, and three of them are the kind that get answered
by whoever types first.

**How small is small.** #265 puts it exactly: "A DC and two endpoints is enough
to poison; it is not enough to have realistic authentication traffic, tiered
admin, or anything to laterally move *toward*. The right answer is bounded by
spindles, not by taste."

**What the licences are.** Evaluation media expires, and #265's objection is the
real one: "an estate that has to be rebuilt every 180 days is one that will not
be rebuilt."

**Where the domain's names are answered.** A Windows domain member must use a
domain controller for DNS or it cannot find `_ldap._tcp.dc._msdcs` and nothing
works. [ADR-0010](0010-keep-the-resolver-on-the-gateway.md) decided the opposite
for everything else in the house — clients receive the gateway as their **only**
resolver — and rests the whole decision on that property: "clients only ever
have one resolver, so they cannot select around the filter." These two
statements collide, and #265 does not name the collision.

**What the clock is.** ADR-0014 names this failure and does not fix it, because
fixing it was not that ADR's job: "a domain controller syncing time from
`time.windows.com` drifts once 123/udp is blocked, and the symptom is Kerberos
failing estate-wide five minutes later, with nothing in the firewall log but
w32time events on the DC."

### The size, derived twice

Two independent derivations land on the same shape, which is the argument for it
rather than for a number someone liked.

**By technique.** Each attack ADR-0014 names has a minimum machine count. Most
are satisfied by a DC and one client. One is not, and it is the one that fixes
the inventory: **NTLM relay needs a relay destination that is not the origin,
with inbound SMB signing not required.** Since Windows 11 24H2, Pro, Enterprise
and Education require *both* inbound and outbound SMB signing by default;
Windows Server 2025 requires **outbound only**. So on current defaults you
cannot relay into a Windows 11 endpoint at all, and the only host in a
DC-plus-workstations domain you *can* relay into is the DC — which is Tier 0, so
the exercise skips the entire middle of an engagement.

A member server is therefore not a nice-to-have. It is the only relay target
that exists on modern defaults, and that is a derived requirement rather than
taste. Two workstations rather than one follows for the same shape of reason:
pass-the-hash and lateral movement need a peer, and the Tier 2 admin whose
credentials are cached on both is the thing there is to move *toward*.

**By spindle.** ADR-0007: "128 GB and 48 threads against a single mirrored pair
of 7.2K disks. The fleet is sized against spindles, not RAM." A 7.2K SAS drive
is roughly 83 random IOPS at queue depth 1; a mirror serves reads from either
spindle but must land every write on both, so the machine has **~80–100 random
write IOPS in total**. That figure assumes no write cache, which is the honest
assumption here: [`hardware.md`](../hardware.md) records the Smart Storage
Battery fitted on 2026-09-02 with `cpqDaAccelWriteCachePercent` still reading
`0`, unexplained ([#76](https://github.com/Gerrrt/HomeLab/issues/76)) — the same
fact that made the lab guest's runbook leave disk cache at the Proxmox default.

Against that budget: an idle Windows guest costs 2–10 IOPS, and a Windows boot
is a 300–1500 IOPS burst for thirty to sixty seconds. Six guests at idle would
be most of the machine's write budget before anything useful happened, and six
booting at once saturates the array for minutes while their own services time
out waiting for disk.

Neither derivation mentions RAM or threads, and that is the point. Six guests
are 28 GiB of 128 and 12 vCPU of 48. Any sizing conversation that starts from
RAM is answering a question this host does not have.

### Three sizes were considered

1. **A DC and two endpoints.** Enough to poison, and #265 says so. It has no
   relay target on 2025 defaults, nothing to move laterally toward, and one
   admin tier — which means every logon looks alike and
   [#266](https://github.com/Gerrrt/HomeLab/issues/266) has no baseline against
   which a tier violation is an *event*.
2. **A DC, a member server and two endpoints.** The minimum that makes every
   technique in the table exercisable. Four guests, ~40 idle write IOPS.
3. **Two DCs, two member servers and two endpoints.** Adds replication traffic
   to observe, a second Tier 0 asset so "Tier 0 compromise" is not automatically
   the whole forest in one box, and a service account with an SPN on a real
   service rather than on nothing. Six guests, and the duty cycle stops being
   free.

## Decision

**Six guests on the `.50` decade, sized by what they must be able to do; the
servers run continuously and the endpoints run per session; the domain answers
its own names and takes its clock from the gateway.**

### The inventory

| Name | Role | OS | vCPU | RAM | Disk | Address | Duty |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `bahamut` | Domain controller, PDC emulator, DNS — Tier 0 | Windows Server 2025 Standard (Desktop Experience) | 2 | 4 GiB | 60 GiB | `10.0.30.50`, static | continuous |
| `leviathan` | Second domain controller, DNS — Tier 0 | Windows Server 2025 Standard | 2 | 4 GiB | 60 GiB | `10.0.30.51`, static | continuous |
| `titan` | File and member server — the shares, and the relay target — Tier 1 | Windows Server 2025 Standard | 2 | 6 GiB | 80 GiB | `10.0.30.52`, DHCP + reservation | continuous |
| `ramuh` | Application server — the SPN service account, the Kerberoasting target — Tier 1 | Windows Server 2025 Standard | 2 | 6 GiB | 80 GiB | `10.0.30.53`, DHCP + reservation | continuous |
| `carbuncle` | Endpoint — Tier 2 | Windows 11 Pro 24H2 | 2 | 4 GiB | 64 GiB | `10.0.30.54`, DHCP + reservation | on demand |
| `siren` | Endpoint — Tier 2 | Windows 11 Pro 24H2 | 2 | 4 GiB | 64 GiB | `10.0.30.55`, DHCP + reservation | on demand |

The names continue this segment's Final Fantasy summons — `shiva`, `ifrit`,
`alexander` — and the summon hierarchy is made to read as the admin tier, so
`AD\bahamut$` in an alert is legible as Tier 0 without a lookup. All six
are fifteen characters or fewer, which NetBIOS requires and which is cheaper to
notice now than at promotion time.

**Desktop Experience, not Server Core.** Core saves roughly 15 GiB per server,
and capacity is not the constraint that binds; it does not improve write IOPS at
all. What it costs is every hour of #266 and
[#267](https://github.com/Gerrrt/HomeLab/issues/267) spent in Event Viewer, the
Group Policy Management console and the DNS console. Spending the loose resource
to save the tight one's operator is the trade this estate makes everywhere else.

### The duty cycle is a spindle decision

**The four servers run continuously; the two endpoints start per session.** Four
servers at idle is roughly 40 of the machine's ~90 write IOPS, and the endpoints
would be most of what is left. Continuous servers are what keep Kerberos,
replication and time healthy, and what give #266 a baseline that is not empty.

Boot order is staggered — `--onboot 1 --startup order=N,up=120` — because four
Windows boots at once saturate the array for minutes. That is derived from the
IOPS budget and not from tidiness, and it is the one setting in this build that
looks like fussiness until the first unplanned power event.

**Say what this costs rather than only what it saves:** endpoint detections are
meaningful only during a session. #266 can baseline the servers continuously and
the endpoints not at all, and any rule it writes about workstation behaviour has
to be written knowing that.

### What must not be hardened

Each of these is a shipped default that, tidied up, deletes one of the
techniques ADR-0014 built this segment for:

| Leave alone | The reflex that would delete an exercise |
| --- | --- |
| LLMNR enabled | GPO *Turn off multicast name resolution* |
| NetBIOS over TCP/IP enabled | Disabling NBT on the adapter, or DHCP option 001 |
| IPv6 enabled on every guest | "Disable IPv6" — the only thing that stops mitm6, and the first thing people do |
| WPAD auto-detect left on | Turning off *Automatically detect settings* |
| The DNS `GlobalQueryBlockList` as shipped | Leave it. Windows DNS blocks `wpad` by default, so the name fails in DNS and **falls through to LLMNR** — which is the exercise. Creating a `wpad` A record to "fix" the failure is what kills it |

And the inverse: hardening deliberately removed, once, with the removal
recorded. Inbound SMB signing on `titan`, if it turns out to be required — 2025
requires outbound only, so relay should work as shipped, but that is a default
which moves in servicing updates and fails silently. And LDAP signing on the two
DCs: new Server 2025 domain controllers require it where 2019 and 2022 defaulted
to None.

**Each modern default deliberately turned off is a documented exercise, not a
hole.** A lab shipping 2019-era defaults teaches what worked in 2019. A lab
shipping 2025 defaults, with a written list of which one was switched off and
what came back to life when it was, teaches what each control is worth. That is
the difference between a range and an estate, and it is ADR-0007's own
distinction.

### Licensing: buy the endpoints, evaluate the servers, instrument the clock

**The two endpoints are purchased Windows 11 Pro licences. The four servers run
Windows Server 2025 Evaluation.**

Client evaluation is 90 days, and at expiry the machine shows a black desktop, a
non-genuine notice, and **shuts itself down every hour**. A workstation that
switches itself off hourly is not an estate anyone keeps using; it is one they
stop opening. The two machines an operator sits in front of should not carry
that clock. Server evaluation is 180 days, twice the client's, and the servers
are the machines whose rebuild is scriptable — `Install-ADDSForest` plus a
seeding script for the OUs, users, service account and GPOs — rather than an
afternoon of settling in.

**No rearm count is written here, and that is deliberate.** Microsoft's own
support answers say Server 2025 permits one extension; third-party write-ups say
the historical five or six. Neither is citable, and this is exactly the failure
ADR-0010's own verification section diagnosed: "a copied fact goes stale at the
copy, and the copy is the thing with nobody watching it." The runbook's job is
to make you run `slmgr /dlv` on build day, read *Remaining Windows rearm count*
off the machine, and record that number in the commit that says the domain is
built.

**The licence clock becomes a metric, and this is what answers #265's
objection.** The reason a 180-day estate does not get rebuilt is not that
rebuilding is hard; it is that nobody is told the clock is running. Every other
slow-moving fact in this estate is already a metric — patch state
([#152](https://github.com/Gerrrt/HomeLab/issues/152),
[#360](https://github.com/Gerrrt/HomeLab/issues/360)), SMART
([#351](https://github.com/Gerrrt/HomeLab/issues/351)), package state — and
`windows_exporter` ships a textfile collector exactly like the `node_exporter`
directory [`collect-patch-state.sh`](../../scripts/collect-patch-state.sh)
already writes into. A weekly scheduled task writes one gauge from
`SoftwareLicensingProduct.GracePeriodRemaining`; one rule fires at thirty days.
The rebuild stops being a surprise and becomes a scheduled afternoon, which is
the only form in which it actually happens.

### Addressing: the domain controllers are static, and the rest are not

The segment's rule is statics below `.100`, a Kea pool of `.100–.200`, and
decade spacing — `.10` `shiva`, `.20` `Saruman` after
[#96](https://github.com/Gerrrt/HomeLab/issues/96), `.30` `ifrit`, `.40`
`alexander`. **The domain takes `.50`–`.55`**, which leaves `.60` upward for
whatever #266 and #267 need and keeps the spacing legible.

**Both domain controllers are hard statics**, and the reason is a property
rather than a preference: every other machine finds a DC through DNS, and the
DCs *are* the DNS. A domain controller that boots without an address has nothing
to register into and no way to be found — a bootstrap dependency on itself that
nothing else in the domain has. Every other member's address may move freely,
because the thing that resolves it does not.

**The other four are DHCP clients with reservations, and that is load-bearing.**
Rogue DHCP is one of the five techniques ADR-0014 names as the reason this whole
segment is arranged the way it is, and **a statically-addressed estate cannot be
lied to by DHCP**. Making the non-DC members DHCP clients is not a convenience;
it is what keeps a fifth of the design's stated purpose exercisable. Statically
addressing them would delete a technique in exchange for tidiness.

Reservations below `.100` are the pattern `shiva` already follows, and
[`build-the-playground.md`](../runbooks/build-the-playground.md) has already
written out why: below `.100` the reservation is not what protects the address —
it is there so the address is recorded where a reader looks for it, and so the
protection does not depend on the pool never moving. It also avoids repeating
the `10.0.30.110` mistake [`network.md`](../network.md) is still apologising
for.

### DNS resolves inward only

**Domain members point at the two domain controllers; the domain controllers
forward to `10.0.30.1`.**

The AD zone is authoritative on the DCs. Everything else goes one hop to Unbound
on `morpheus` and out from there. No change to the firewall, no change to the
DHCP scope — reserved clients still receive the interface address like everyone
else, and the DC addresses are set inside Windows on the members — and no new
rule, because `10.0.30.x → 10.0.30.1` is intra-segment. ADR-0010 is untouched
for every host that is not in the domain: `alexander`, `Saruman` and `ifrit`'s
attack VM keep pointing at the gateway and simply cannot resolve AD names, which
costs nothing, because the scrape list below holds addresses and not names.

ADR-0010's verification section closes by saying that a documented exception is
a policy and an undocumented one is a hole that gets rediscovered. This is that
exception, written down: **the members of `ad.matrix.elysium` are the one set of
hosts in the estate that do not receive the gateway as their resolver.**

**Rejected: a domain override on Unbound for the AD zone.** It would let the
whole house resolve AD names, and it would do so by inserting a nameserver that
lives on the segment built to hold attackers into the resolution path of the
house's own resolver. An attacker who owns a domain controller would then answer
questions the house asks. That is the same inversion ADR-0007 refuses for the
remote-write path, one layer down.

**Rejected: forwarding the DCs straight to public resolvers.** It gives the lab
a second, independent name-resolution path for no benefit, and throws away
ADR-0010's best property — that "DNS is down" and "the gateway is down" are one
event and never two.

**Root hints are disabled on both Windows DNS servers.** Left on, Windows DNS
falls back to recursing against the root servers whenever the forwarder is slow,
so the domain's resolution path silently diverges from every other host in the
house exactly when something is already wrong. Root hints off makes a forwarder
problem fail immediately and locally, which is
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)'s reasoning
about default routes applied to DNS.

### The namespace is `ad.matrix.elysium`, NetBIOS `AD`

A dedicated subdomain of the estate's existing internal name. It collides with
none of the six Unbound host overrides ADR-0010's verification section
enumerates — `grafana`, `prometheus`, `lemmiwinks`, `oracle`, `morpheus` and
`neo` are all direct children of `matrix.elysium` — and a query for an AD name
from a non-domain host recurses to NXDOMAIN, so it works without touching
`morpheus` at all.

**Because it is a subdomain, this ADR must say the thing a subdomain implies and
this design refuses: the delegation is never added.** A subdomain normally
means a delegation, and the delegation is the option rejected two sections
above. Without one, the hierarchy is appearance and not function — which is
fine, and is the trade being made, but it leaves a standing temptation to add
the delegation later "just to make names resolve". Adding it is a decision that
requires superseding this ADR, not a convenience.

The alternative, and it is a real one: an unrelated name such as
`ivalice.internal`. ICANN permanently reserved `.INTERNAL` from delegation in
the root zone in 2024, so it is the one string that can never start resolving to
somebody else's server — where `.elysium` is an invented TLD and a standing bet
that nobody applies for it in a future round. And a name that *looks* related to
the house, on a domain whose entire premise is that it shares no credentials
with the house, argues against the design every time someone reads it. The
subdomain is chosen for namespace continuity and legibility, over an argument
that had genuine force; if the delegation temptation is ever acted on, that is
the evidence this choice was wrong.

### Time comes from the gateway

**The domain controllers sync from `morpheus` at `10.0.30.1`. Members are left
on `NT5DS`.**

This is ADR-0010's co-location argument reused: a clock source that is also the
default gateway means "time is broken" and "the segment is broken" are one event
and never two, so the domain has no independent way to lose time. An internet
source gives the domain a failure mode invisible from inside the segment, which
is the shape of failure ADR-0014 is complaining about in the first place. It
also gives the whole lab one clock tree, which is what makes Wazuh events,
Velociraptor timelines, Loki lines from `alexander` and `filterlog` blocks
correlatable at all.

Members get nothing configured. `NT5DS` — the domain hierarchy — is the default
the moment they join, and the failure to avoid is a member whose manual peer
list quietly overrides it.

Two things the runbook verifies rather than assumes: that `morpheus` serves NTP
**on the ImaginationLAN interface** at all, since pfSense binds the service per
interface and a VLAN interface is not necessarily among them; and that this
build adds **zero firewall rules**, since `10.0.30.x → 10.0.30.1:123/udp` is
intra-segment and covered by nothing. One Proxmox-specific trap belongs with
them: Proxmox sets `localtime=1` automatically for `ostype=win*`, so a drifting
host RTC can be read at boot and served to the domain by the PDC emulator.

### Two rules, and the second is the one that matters

| Alert | Catches |
| --- | --- |
| `DomainControllerClockDrifting` | Real drift, while the configured source is still a source |
| `DomainControllerTimeSourceIsLocalClock` | **The ADR-0014 failure** |

The second exists because the obvious metric reads approximately zero for
exactly the failure being hunted. `windows_time_computed_time_offset_seconds` is
the offset against *the source w32time has chosen*, so when the peer becomes
unreachable and w32time falls back to the local CMOS clock, the offset reads
fine and the domain controller looks perfectly synchronised while Kerberos runs
out of tolerance. A single-rule design would reproduce the quiet failure inside
its own detector, which is the #62 and #63 shape this repository keeps paying
for. `windows_time_clock_sync_source` carries a `type` label — `NTP`, `NT5DS`,
`Local CMOS Clock`, `NoSync`, `AllSync` — and reading it is the check.

The drift threshold is sixty seconds, and it is derived rather than picked:
Kerberos' default `MaxTolerance` is five minutes, so sixty seconds is above
anything a virtualised clock produces as noise and four minutes clear of the
point at which authentication starts failing. The alert fires **while the domain
still works**, which is the entire complaint ADR-0014 lodges against the
port-allowlist option it rejected.

`windows_exporter`'s `time` collector is **not enabled by default** — it needs
`--collectors.time.enabled` and its `ntp` sub-collector. A rule written against
a collector nobody enabled is #63 arriving for the third time, so enabling it is
part of the build and not part of the tuning.

### The domain is scraped, not published — reversing a comment this repository already wrote

`windows_exporter` listens on `9182` on each guest, and `alexander` scrapes it
**outbound**. Four files in `stacks/lab` currently say #265 is when the `ports:`
block opens and the endpoints push instead. That was written before the
endpoints had a shape, and it is wrong for four reasons:

1. **A published remote-write receiver would be unauthenticated on the segment
   ADR-0014 deliberately fills with attackers.**
   [`security.md`](../security.md) already calls the estate's published ingest
   ports "a real residual rather than a solved problem — anything that can reach
   them can read every metric and log line, inject metrics, and delete log
   ranges." On VLAN 99, "anything" is a host already inside Winterfell. Here it
   is, by ADR-0014's own decision, a Kali VM sharing the broadcast domain —
   handed a delete-series API pointed at the lab's own evidence. **The direction
   the connection travels is the control.**
2. **The property that makes remote-write preferable in the estate does not hold
   here.** [`architecture.md`](../architecture.md) gives the reason as "a new
   host appears in Prometheus as soon as its agent starts — no target list to
   edit, no firewall hole from the monitoring VLAN into the monitored one."
   Neither half applies: the target list is six addresses fixed by this ADR, and
   a list that changes only when an ADR changes is not a maintenance burden;
   and there is no firewall between `alexander` and the domain, because they
   share a segment, so a scrape costs no rule.
3. **`config.alloy` is not portable to Windows.** It uses
   `prometheus.exporter.unix`, `loki.source.journal`, and explicit file tails of
   `/var/log/auth.log` and `/var/log/syslog`. ADR-0007's "reused unchanged, the
   two `*_URL` variables are the only difference" is true for `alexander` and
   cannot be true here. An Alloy path means a third agent config, for machines
   whose security telemetry is #266's job anyway — and two collectors reading
   one Windows Event Log gives two answers to "what happened", which is the same
   objection `prometheus.yaml` already raises about polling `shiva` twice.
4. **Loki's `3100` stays closed too.** Nothing in #265 pushes logs. Windows
   Event Log belongs to #266, and if #266 decides some of it should also land in
   the lab's Loki, that is #266's port to open and #266's argument to write.

`--web.enable-remote-write-receiver` stays enabled. `alexander`'s own Alloy uses
it over the compose network, exactly as the comment above that flag says.

## Consequences

- **This build adds no firewall rules.** Three builds in a row now.
  [`firewall-claims.yaml`](../firewall-claims.yaml) records wholesale catch-all
  reach per interface, and every packet this domain sends is intra-segment, so
  the file is unchanged — and the runbook asserts that rather than hoping it.
- **The lab's Prometheus gains a scrape list**, which is the first target list in
  the estate that is not SNMP. That is a maintenance surface the estate
  deliberately avoided, accepted here because the list is fixed by this document
  and because the alternative opens a port.
- **`windows_exporter` listens on `9182` on the segment that exists to hold
  attackers.** It is source-scoped to `10.0.30.40` in each guest's Windows
  Firewall, which is the difference between an endpoint found by a `/24` sweep
  and one you have to go looking for. It is not a control against someone who
  already owns `alexander`, and `security.md` records it as a residual rather
  than a mitigation.
- **Credential Guard is off, because the endpoints are Pro.** A current
  Enterprise estate has VBS and Credential Guard on by default on new installs;
  this one will not. LSASS credential theft is therefore easier here than in the
  estate being modelled. That is a recorded limitation, not a discovery to make
  in the middle of an exercise.
- **The domain has an expiry date, and the date is now a metric.** When the
  rearms run out, this ADR is superseded by whatever the next licensing decision
  is — not amended.
- **PBS gets zero disk on this pool, and that is now settled rather than
  deferred.** [ADR-0027](0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md)
  landed while this was being written and answers
  [#268](https://github.com/Gerrrt/HomeLab/issues/268): PBS is not installed
  until `zion` exists, because a hypervisor backing up its own guests to itself
  is not a backup and PVE's own snapshots already provide the local-only
  capability. So there is nothing to budget for, and the six guests here are
  sized against a pool that PBS is not competing for.

  **What that means for this domain specifically is worth saying, because it is
  the half a sizing table hides:** the lab has *revert and not backup*. A
  snapshot of `bahamut` is a way back from a broken change, and it is not a copy
  that survives losing the mirrored pair. Rebuilding the forest from the runbook
  is the recovery path, which is one more reason the servers are the machines
  whose build is scriptable. Snapshots also cost capacity on the same spindles —
  a snapshot held across a patch cycle on all four servers is real space, and it
  is the growth this table does not model.
- **Nothing counted in the documents moves.** `facts()` in
  [`check_docs.py`](../../scripts/check_docs.py) reads
  `stacks/observability` only, so rules added to `stacks/lab` change no counted
  claim anywhere, and the Contents cell of each new `architecture.md` row must
  avoid the word "Alloy" so `count_alloy_agents()` stays honest. Worth stating so
  that the next person does not go looking for a number to bump.
- **The four guests join none of the estate's loops.** No `converge.sh`, no
  `deploy-agent.sh`, no PBS. What watches them is #266 and #267, and until those
  land the two clock rules are the only thing in this repository with an opinion
  about whether the domain is healthy — and nothing pages, because ADR-0020 put
  no Alertmanager in `stacks/lab` and none is added here.
- **Two of these guests will trip the estate's `HypervisorGuestStopped`, and
  that is correct rather than a defect.**
  [ADR-0028](0028-let-guest-liveness-cross-but-not-guest-telemetry.md) landed while this was being
  written and lets a guest's *run state* cross to the estate — read from `qm` on
  the hypervisor, never from inside the guest — so `homelab_guest_running == 0`
  for an hour is a warning on VLAN 99. `carbuncle` and `siren` are off far more
  than they are on, which makes them the first concrete instance of the case
  that rule's own comment anticipates: #257 "allows for *a machine that is
  powered off between sessions*, which is exactly this signal with a different
  cause."

  Nothing here proposes changing that rule. It considered a table of which
  guests are expected to be up and rejected it as "a second copy of a fact that
  changes whenever a VM is created" — which is the same reasoning this ADR
  applies to its own scrape list, and it would be inconsistent to ask for the
  exception here. The cost is recorded rather than removed: two warnings a
  session, and anyone reading that rule should know which two guests they are
  before concluding it is noisy.
- **Reopened by:** a seventh guest wanted for a technique not in the table;
  Wazuh's indexer turning out to need the IOPS these six are consuming; a
  purchased Server licence; a delegation added for the AD zone; or anything that
  makes the domain reachable from outside VLAN 30.
