# ADR-0016: Open CasaBonita inward, keep it terminal outward

**Status:** Accepted · 2026-09

## Context

[ADR-0008](0008-place-services-by-data-trust.md) put the media tier on
CasaBonita (40) — a quiet N100-class NAS running Jellyfin, with the televisions
it serves — and justified the placement by the terminal property rather than
against it: put the server *with* the clients and no rule has to punch through.
[#95](https://github.com/Gerrrt/HomeLab/issues/95) asks for the three things
that have to exist before hardware is bought — capacity and redundancy, the
firewall rule written down before it is created, and where the backups go —
and names the fourth itself: adding a NAS "changes what *terminal* means for
that segment".

Following [ADR-0013](0013-segment-access-as-implemented.md), the starting point
is the enforced ruleset rather than the prose about it. Read on `morpheus` on
2026-09-04, `pfctl -sr` with the interface tables resolved:

**CasaBonita as a source** blocks Degens, Skids, ImaginationLAN, Hicks and
Winterfell explicitly, blocks HTTP, HTTPS and SSH to its own gateway address,
then carries the [#223](https://github.com/Gerrrt/HomeLab/issues/223) tripwire
(`pass` + `log` to `<Internal_Segments>`, which is 30/50/99) and finally the
`→ any` egress rule. That is the terminal property, and it is intact.

**CasaBonita as a destination** is blocked from both segments that would want
it. Hicks carries *Block access to CasaBonita* — `block drop in quick on
igc0.50 from <OPT2__NETWORK> to <OPT3__NETWORK>` — **above** its catch-all, and
Winterfell carries the same block above its own. Neither is a gap that a new
rule fills. Both are denies that a new rule has to be ordered in front of.

That is the first thing #95 and ADR-0008 both understate. **50→40 is not an
addition; it is an insertion above an existing deny.** A pass appended at the
bottom of the Hicks tab, next to *Allow internet* where a new rule naturally
lands, would never match — which is precisely the fault ADR-0013 found in
*Allow Hicks access to ImaginationLAN*, a rule that has sat on the wrong
interface doing nothing since it was written. Getting this wrong produces a
firewall that looks configured and a NAS that is unreachable, and the
troubleshooting for that starts at the switch.

The second is larger. ADR-0008 lists 50→40 as the single rule the media tier
needs, and claims of its two new rules that "every one remains directional —
nothing untrusted ever initiates upward". Both hold only if the NAS is a thing
the household reaches and nothing else. It is not: it is a host, and every
other host in the estate is monitored and backed up by **pushing** — `Saruman`,
`oracle` and `prometheus` all run Alloy agents that write to `10.0.99.20` on
9090 and 3100, and `backup-firewall.sh` pushes ciphertext from `prometheus` to
`oracle`. Build the NAS the way every other host is built and its Alloy agent
needs 40→99, which would be the first time anything untrusted in this estate
initiates upward, and would retire the property ADR-0008 says it keeps. The
choice is not "one rule or two". It is which direction the estate's own
services run in when one of their hosts sits on a low-trust segment.

## Decision

**Nothing on CasaBonita initiates anywhere. Everything the estate needs from
the NAS, it reaches in and takes.**

### Capacity: buy the chassis for the library you cannot measure

A **four-bay** N100-class chassis, **two bays populated**, two left empty. The
library's current size is not known, and an ADR that names a drive capacity is
wrong within a year; drive size is chosen at the till on cost per terabyte and
recorded in `hardware.md` when it is bought. What cannot be changed later
without buying the enclosure twice is the bay count, so that is the half this
decides. Two empty bays is the cheapest possible answer to a number nobody has.

### Redundancy: a mirror, and a mirror is not a backup

Two drives in a **ZFS mirror**. The requirement here is *availability*, not
durability — ADR-0008 says this data is replaceable, and that is the entire
reason it is allowed on a segment with the televisions. A mirror turns a dead
disk into a drive swap instead of a re-acquisition weekend; ZFS rather than
`mdadm` because checksums and a scheduled scrub are what catch a cheap disk
rotting quietly, which is the realistic failure for a large store of files
nobody opens for a year. Parity is not on the table at two disks and is not
wanted at four: rebuilding a mirror is a copy.

**It protects against a disk dying and against nothing else.** Not a deletion,
not a bad `zfs destroy`, not the room catching fire. #95 opens by calling this
"the first machine in the estate holding data whose loss would actually
matter", and that is the one line in it worth disagreeing with — ADR-0008
already ruled the opposite way, and the machine whose loss matters is the
sensitive-tier box on Winterfell holding Vaultwarden, Immich and Paperless.
Keeping that distinction is what lets the answer below be so small.

### Backups: the library is not backed up, the metadata is

The two halves of this box have nothing in common. The **library** is terabytes
and replaceable, and it is not copied anywhere: `oracle` has 67 GB free behind
a 100 Mb/s NIC ([ADR-0015](0015-give-oracle-the-off-host-jobs.md)) and could
not hold it if it were wanted. The **metadata** — the Jellyfin database, watch
state, users, and the compose stack's configuration — is gigabytes at most, is
not replaceable, and is what actually costs an evening to rebuild.

That half leaves, in the shape everything else in this estate already uses:
encrypted **on the NAS** with `age -r` to the `.sops.yaml` recipient, so a
VLAN 40 host holds ciphertext and no private key; **pulled** by `prometheus`
over 99→40:22; landed on `oracle` beside the firewall exports and the volume
sets, by the path `backup-firewall.sh` already walks. It runs on `prometheus`
rather than on `oracle` deliberately — ADR-0015 gives `oracle` only work whose
value is that it is *not* on the monitoring host, and a collection job has no
such property.

`oracle` is unaffected by this: nothing new reaches it, and it gains a third
small set on a disk with 362 GB unallocated in the volume group.

### Monitoring: scraped, never pushed

**No Alloy agent on the NAS.** `node_exporter` binds there instead and
Prometheus scrapes it over 99→40:9100 — management initiating downward into
something less trusted, the same shape as the two SNMP exceptions ADR-0013
lists and carrying the same directional guarantee. The target joins a
`targets/node.yaml` beside the existing `snmp.yaml` and `blackbox.yaml`.

This is a deliberate break from the convention that every host runs Alloy, and
it is worth naming as one. Alloy is deployed here to `remote_write` metrics and
push logs; strip both and what is left is `prometheus.exporter.unix` behind an
agent nothing pushes with. The convention exists to serve the direction, and on
this host the direction reverses, so the tool does too.

**Logs are the part this cannot solve, and it says so rather than quietly
dropping them.** Loki has no pull; ingest is a push or it is nothing. The only
way to centralise this host's logs is a 40→99:3100 rule, and Loki's ingest is
unauthenticated by design ([ADR-0012](0012-publish-only-ports-with-an-off-host-consumer.md)),
so that rule does not just move logs — it lets anything that reaches the NAS
write to the log store the rest of the estate is judged by. **The NAS gets
metrics and no logs.** It is therefore the one host in the estate whose
compromise is invisible: Prometheus will show it alive and busy, and nothing
will show what it did. That is a real cost, it is the price of the direction,
and it is tracked rather than absorbed.

### The three rules, written down before they are created

Host `zion` at **10.0.40.30** — a static below the DHCP range, which starts at
10.0.40.100, and the Matrix naming the infrastructure hosts already use.

| On interface | Rule | Position | Purpose |
| --- | --- | --- | --- |
| 50 | `vlan50 → 10.0.40.30:22,8096/tcp` | **above** *Block access to CasaBonita* | Administer the NAS and reach Jellyfin from a workstation |
| 99 | `10.0.99.20 → 10.0.40.30:9100/tcp` | **above** *Block access to CasaBonita* | Prometheus scrapes `node_exporter` |
| 99 | `10.0.99.20 → 10.0.40.30:22/tcp` | **above** *Block access to CasaBonita* | `prometheus` pulls the metadata backup |

All three are host-scoped and port-scoped. The Hicks rule especially: Hicks
already reaches Winterfell and ImaginationLAN wholesale through a catch-all
nobody wrote ([#228](https://github.com/Gerrrt/HomeLab/issues/228)), and this
is the first rule granting Hicks a segment narrowly and on purpose. It is a
small worked example of what #228's answer should look like.

**The televisions need no rule at all.** They reach the NAS on the same
broadcast domain, the firewall never sees the packets, and that is the whole of
what ADR-0008 bought by placing the server with its clients.

None of the three are created by this ADR. The hardware is not bought, and a
`pass` to an address with nothing behind it is a rule nobody can test.

### Jellyfin now; Plex only if a screen makes it necessary

ADR-0008 lists Jellyfin "with Plex beside it for household convenience".
Build **Jellyfin alone** and add Plex only if a client on 40 turns out to have
no working Jellyfin app — the LG OLED, which is the primary screen, has one.
Plex authenticates its clients through `plex.tv` even on a local network, which
would make a household service that works today depend on a third party being
up and keeping its terms, in an estate that went to the trouble of keeping even
the wiki internal ([ADR-0011](0011-keep-the-wiki-internal.md)). It also doubles
the metadata to back up for a library that is already indexed. This is a
deferral against a test, not a rejection: if the Xumo box or a console can only
do Plex, that is the answer and Plex gets installed.

### The box is built like the rest of the estate

Ubuntu Server and one Docker Compose stack, per
[ADR-0004](0004-one-compose-stack-per-host.md), not an appliance OS. TrueNAS or
Unraid would make the storage easier and put the host outside every mechanism
this repository has — no compose file, no pinned digests, no `make validate`,
configuration that exists only as clicks. `oracle`'s hand-made wiki containers
are what that costs, and they took until [#251](https://github.com/Gerrrt/HomeLab/issues/251)
to become visible.

### What "terminal" means now

**Terminal was never a property of the segment. It is a property of a
direction, and the direction that matters is unchanged.**

After these rules land, nothing on CasaBonita may initiate into any other
segment — every block above its egress rule stays exactly as it is, and #223's
tripwire stays where it is and must still never log a line. What changes is
that CasaBonita is no longer terminal *inbound*: two segments may now initiate
into it, both more trusted than it, both to one host on named ports.

The tripwire is untouched by this, and that is a small vindication of where it
was put. It sits on the CasaBonita interface and matches only packets that
originate there; the return traffic for a session Hicks or Winterfell opened is
carried by state, exactly as the existing 50→99 passes already are, and never
reaches the ruleset. Its counter staying at zero after the rules land is the
test that this is true, and it should be read the day they land rather than
assumed.

`README.md` and `security.md` both say the media segment is "egress only, no
path to anything else". That sentence becomes wrong for CasaBonita on the day
the first rule is created — and it stays right for Skids and Degens. It is
correct today and is left alone; it is edited when the rules exist, not now.

## Consequences

- **The rule list grows by three, not by one.** ADR-0013's table gains three
  rows when they land. ADR-0008 expected one rule here and said the estate's
  count "rises from three to five"; the count was retired by ADR-0013 for
  exactly this reason, and this is the second time it has been wrong in the
  direction of too small.
- **Position is what will go wrong.** Two of the three sit above a deny that
  has been in place since 2025. "Can I reach the NAS" is a weak test — a rule
  in the wrong position and a NAS that is not powered on look identical. The
  strong test is the block rule's own counter, which should stop rising for the
  permitted flows, and the tripwire's, which should not move at all.
- **A compromised NAS still reaches nothing**, including the monitoring stack —
  and so nothing on the NAS is visible in Loki. Jellyfin is a large codebase
  with a network-facing indexer, on the segment whose stated assumption is that
  everything on it is already compromised. Metrics will show the host; logs
  will show nothing, by choice, and the reasoning is above.
- **The mirror buys availability and the backup buys the library's index. The
  library itself is accepted as lost** in any event that takes both drives.
  That is not an oversight, it is ADR-0008's placement decision arriving at its
  logical end: the data is on the low-trust segment *because* losing it is
  survivable, and paying for offsite copies of it would contradict the reason
  it is there.
- **Off-host is still not off-site.** The metadata copy lands on `oracle`, on
  the same shelf, under the same roof, behind the same unmanaged switch —
  ADR-0015's first consequence applies here unchanged, and
  [#92](https://github.com/Gerrrt/HomeLab/issues/92) still owns it.
- **Deferring Plex leaves ADR-0008's service list longer than what gets
  built.** That is a deferral with a stated test, not an amendment; ADR-0008 is
  not superseded and its reasoning about the two tiers is untouched.
- **A second host now exists that this repository does not deploy to.** The
  compose stack lives here; `make up` over SSH is the model, and
  [#99](https://github.com/Gerrrt/HomeLab/issues/99) wants to replace it. A
  third host makes that issue slightly more worth doing and no more urgent.
- If the household ever wants the library reachable from outside the house,
  every line of this is wrong and the decision is a new one. ADR-0008 says the
  same thing about the sensitive tier, for the same reason.
