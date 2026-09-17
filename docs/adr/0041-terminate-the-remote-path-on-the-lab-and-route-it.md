# ADR-0041: Terminate the remote path on the lab, and route it

**Status:** Accepted · 2026-09

## Context

The estate has no remote access. Every path in is a workstation physically on
Hicks, and that is a posture rather than an omission — it is the premise
[ADR-0008](0008-place-services-by-data-trust.md) deferred single sign-on on
("two users and no external exposure"), the premise
[ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md) declined
a VPN under, and the state
[ADR-0011](0011-keep-the-wiki-internal.md) went and *measured* rather than
asserted: "`morpheus` carries no `rdr` port forwards, and WAN (`em0`) has no
inbound pass rules beyond DHCP client replies."

Nothing in `docs/` describes an alternative, which is exactly why one should be
designed on a quiet afternoon rather than improvised from a hotel room. This
ADR designs it. [#442](https://github.com/Gerrrt/HomeLab/issues/442) is the
issue; the jumpbox it terminates on is
[#436](https://github.com/Gerrrt/HomeLab/issues/436), a guest on `Saruman` at a
static below `.100` on ImaginationLAN.

### The trigger, and the temptation to read it narrowly

[ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md) names
three triggers that end the SSO deferral. The second:

> **Any of it becomes reachable from outside the house**, by any means,
> including a VPN terminating on 99. This is ADR-0008's *no external exposure*
> premise made testable.

There is a narrow reading available, and it is tempting. Read against its
siblings — trigger 1 is "the sensitive tier holds real data", trigger 3 is "a
third person gets an account on any of it" — "it" looks like the sensitive
tier, and a tunnel that reaches `10.0.30.0/24` and stops makes none of
Vaultwarden, Immich, Paperless-ngx or Home Assistant reachable. On that reading
nothing fires and this ADR is a convenience with no consequences.

**That reading does not survive contact with ADR-0014, which already decided
this question.** Its closing list of what reopens it contains this ADR by name:

> or remote access into VLAN 30 is wanted, **which also takes ADR-0008's "no
> external access" premise with it**.

So the chain is already written down, in two documents, by people who were not
thinking about a jumpbox at the time: remote access into VLAN 30 takes
ADR-0008's premise; trigger 2 *is* that premise made testable. Arguing that a
lab tunnel leaves the premise intact means arguing with ADR-0014's own
sentence.

**And the narrow reading is wrong on the facts as well as the grammar.**
`stacks/lab/compose.yaml` runs Grafana OSS on `alexander` at `10.0.30.40`,
publishing `3000` to the segment, with one account and a password from SOPS.
ADR-0022's own table is what condemns it: "**Grafana OSS** — None, in any
edition… the documented route is an external identity provider." So a lab-only
tunnel does not merely touch the premise in the abstract. It makes an
authenticated, permanently MFA-incapable service reachable from outside the
house — which is the exact risk shape ADR-0022 was written about, on an
instance its table did not enumerate because `docs/security.md` counts service
types and there are two Grafanas.

### Two properties of WireGuard that decide the rest

**`AllowedIPs` is asymmetric.** On a client it is a *route* — which CIDRs go
down the tunnel. On a server it is an *access control list* — which source
addresses that peer may present. Getting them backwards is not a typo, it is a
segmentation failure, and a peer whose `AllowedIPs` is quietly wider than the
lab will not announce itself.

**Forwarding is a capability, and it can be scoped to the tunnel's lifetime.**
Putting `net.ipv4.ip_forward` in `/etc/sysctl.conf` makes the jumpbox a router
permanently. Putting it in `PostUp`/`PostDown` makes it a router only while the
tunnel is up.

### The property this estate has that most designs do not

Most WireGuard subnet-router guides reach for `MASQUERADE` in `PostUp`, and
this estate should not. NAT rewrites every peer's source to the jumpbox's own,
and three things here read source addresses and would be lied to:

| What reads the source | What NAT does to it |
| --- | --- |
| `Saruman`'s Proxmox firewall — ADR-0014 admits `8006`, `8007` and `22` from `10.0.50.0/24` only, and #436 needs a pass for the jumpbox | Every VPN peer inherits that pass, because every peer *is* the jumpbox on the wire |
| The ImaginationLAN tripwire (#234) and `LabSegmentReachedInternalNetwork` | A breach is still detected, but attributed to the jumpbox; which peer did it is unrecoverable |
| Suricata and `filterlog`, if the lab is ever watched | Same |

## Decision

**1. The tunnel terminates on the jumpbox, on ImaginationLAN, and reaches the
lab only.** Not on Winterfell, and not on `morpheus`. Terminating on the
firewall is the option this ADR most nearly took: it is the one device already
exposed to the WAN, it needs no port forward, and its restriction would be
enforced by the ruleset `pfctl -sr` can read back — the standard ADR-0013 and
ADR-0031 hold every other boundary to. It is declined because it puts a
listening daemon and a key store on the box whose failure is every segment at
once, which is the objection ADR-0010 raised against house-wide dependencies on
the gateway and ADR-0014's option 3 raised against routing lab traffic through
it. That is a close call and it is recorded as one.

**The reach is enforced by the firewall, not by the jumpbox's good behaviour.**
This is the strongest property of the design and it is worth stating plainly:
ADR-0013 records that VLAN 30 blocks every other segment explicitly before its
egress rule, so **even a fully compromised jumpbox with `AllowedIPs = 0.0.0.0/0`
reaches the lab and the internet and nothing else in the house.** The jumpbox's
configuration is the second lock. #442's verification treats it as the only
one.

**2. ADR-0022's trigger 2 is fired, and the deferral is re-accepted here, with
reasons.** ADR-0022 anticipated this: "Expiry means a decision gets recorded,
not that Authelia gets deployed… Re-accepting is a legitimate outcome — it is
what happened here once already." The reasons:

- **Nothing in trigger 2's table becomes reachable.** The sensitive tier is
  unbuilt, and when it is built it will be on Winterfell, which this tunnel
  cannot route to.
- **The premise that actually carried ADR-0008's deferral is unchanged.** Two
  users, no third account, and the services that hold data whose loss hurts are
  still reachable only from inside.
- **What did become externally reachable is one Grafana on the lab**, holding
  dashboards of a segment that exists to be broken. An identity provider in
  front of it is the operational weight ADR-0008 was right about, for a service
  whose compromise costs the lab.
- **The other two triggers are untouched and keep their force.** This ADR
  spends trigger 2 and nothing else.

Recording it this way costs a paragraph. Reading "it" narrowly costs the same
paragraph and leaves the next reader to re-derive an interpretation that
ADR-0014 contradicts.

**3. Routed, not masqueraded.** No `MASQUERADE` rule, ever. Peers keep their
tunnel addresses across the jumpbox, `morpheus` carries one static route for
the tunnel subnet, and every rule and log line downstream sees a source that
names the peer. Forwarding still lives in `PostUp`/`PostDown`.

This is also what makes the estate's own idiom work here. Under NAT a tunnel
address never appears on the wire at all, so "a source that should not exist is
a leak reporting itself" — ADR-0017's property for `172.30.30.0/24` — does not
transfer. Under routed mode it does, fully.

The cost is real and accepted: **a second source subnet now arrives on
`igc0.30`, and every rule and alert that names `10.0.30.0/24` as a source has
to be re-read.** Two do. The tripwire is
`pass in log quick on igc0.30 inet from <OPT4__NETWORK> to <House_Segments>`,
and `LabSegmentReachedInternalNetwork` hard-codes `,10\.0\.30\.[0-9]+,`.
Neither matches a tunnel peer, and the block rules above the tripwire do not
either — so left unwidened, tunnel traffic misses every block and the catch-all
carries it to the house. **Routed mode without that widening is strictly worse
than NAT**, and it is done in the same change that creates the tunnel.

**4. The tunnel subnet is `172.31.0.0/24`, and every peer is pinned to a
`/32`.** Outside `10.0.0.0/16`, so a leak misses the ImaginationLAN pass rule
and lands on default deny — ADR-0014's reasoning for
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)'s
`172.30.30.0/24`, applied again. Not `100.64.0.0/10`, which ADR-0017 reserves
as Tailscale's. Not `192.168.0.0/16` or `10.0.0.0/8`, where roaming clients sit
— a tunnel subnet that collides with the café is a tunnel that does not come
up. `172.31` is the top of Docker's default pool walk, which ADR-0017 used as
its argument for sitting high in `172.16/12`.

**The second octet is the discriminator, and that is deliberate.** An earlier
draft used `172.31.30.0/24` to echo the VLAN it reaches. It was rejected: it is
one middle digit from `ifrit`'s `172.30.30.0/24`, and the two mean opposite
things in a log line at two in the morning — `172.30.30.x` in a block is a
never-patched target that has escaped a bridge with no physical port, an
incident and the scariest line this estate can produce; `172.31.x` in a block
is a peer's packet that did not route. Conflating them either raises a false
incident or, the one that costs, dismisses a real one as "that will be the
VPN". ADR-0017 chose its subnet so it "reads in a log line as what it is", and
a one-digit neighbour fails that test. **`172.30.` is the range. `172.31.` is
the tunnel.**

**5. The endpoint is a prerequisite, and it is not decided here.** A WireGuard
server needs a reachable UDP endpoint, and this estate has no way to be one:
the WAN address is ISP-assigned by DHCP and there is no dynamic DNS anywhere in
it. The two answers — a static address from the ISP, which is a recurring
purchase, or a dynamic DNS provider, which means handing a third party a
continuously-updated pointer to a house whose WAN address
[`security.md`](../security.md) deliberately withholds — are a different
decision with a different argument, and folding them in here would bury them.
**Recorded as blocking, owned by its own issue.**

**6. What is published about this, and what is not.** The tunnel subnet, the
design and the rules are documented. The endpoint hostname and the listen port
join the WAN address on `security.md`'s withheld list. A repository that
withholds the WAN address and then publishes the port a VPN listens on has
withheld nothing.

### On ADR-0014, and why it is not superseded

ADR-0014's clause says remote access into VLAN 30 "gets a superseding ADR".
**It does not get one, and declining that instruction deserves saying out loud
rather than doing quietly.**

The clause fired on a premise ADR-0014 *borrowed* from ADR-0008 — which is why
the clause names ADR-0008 rather than any of ADR-0014's own bullets. Every
decision ADR-0014 made still governs and is still checked by
[`build-the-playground.md`](../runbooks/build-the-playground.md): `ifrit`
single-homed on VLAN 30, the targets on a bridge with no physical port and no
default route, the attack VM as the only dual-homed guest, egress unfiltered by
choice, and the `igc0.30` tripwire — which this ADR widens rather than removes.
Retiring a document whose every operative bullet holds, because a premise it
cited has moved, would make ADR-0014 look decided-against in every place that
cites it.

The house already has the instrument for this and it is not supersession:
ADR-0007 is `Accepted` and carries a note block recording what later documents
amended, and ADR-0014's own header note uses the same form. That is what it
gets here.

**ADR-0014's reopening clause mixes two kinds of condition in one sentence, and
that is worth naming for the next one.** "`ifrit` gains a trunk" would genuinely
supersede its Decision. "Remote access into VLAN 30 is wanted" cannot, because
it touches nothing ADR-0014 decided. A reopening clause is more useful when it
says which of *its own* decisions a condition puts back in play, and which
conditions are premise-watches that discharge into a pointer.

## Consequences

- **ADR-0011's measured fact stops being true the day this is built**, and its
  decision does not. The wiki is still not published, still has no external
  hostname and no reverse proxy — and a tunnel peer cannot reach `oracle` at
  all, because `30 → 99` is default deny. ADR-0011's own reopening clause, that
  wanting the wiki readable from outside should supersede it rather than be
  argued as an exception, is **not** hit and is not being argued around.
- **ADR-0014's reopening clause has fired and is discharged, not superseded.**
  ADR-0008 and ADR-0022 get forward pointers for the same reason: ADR-0008's
  final consequence names this change ("if external access is ever wanted, this
  should be revisited"), and ADR-0022 promises that a decision gets recorded at
  the first trigger — a reader has to be able to find it from there.
- **The estate gains its first inbound path from the internet.** Everything in
  the threat model that rested on "there is no way in" now rests on one UDP
  listener and one keypair. WireGuard is a good bet for that job — it answers
  nothing to an unkeyed probe, so the port is not discoverable by scanning —
  but the bet is now being made, where before it was not.
- **The internet-facing host reports to the one telemetry store the house does
  not read.** ADR-0007 keeps lab telemetry in the lab, and #436 sends the
  jumpbox's Alloy to `alexander` and never to `10.0.99.20`. So every handshake
  failure and every SSH auth failure on the estate's only externally reachable
  host lands where no house alert looks. Either that becomes a #88-shaped
  exception — ADR-0007's forbidden direction — or the exposure is unmonitored
  by construction. **It is unmonitored by construction today**, and that is the
  gap most likely to be discovered after it matters rather than before.
- **This re-scopes an accepted residual in another document.** `SECURITY.md`
  accepts the end-of-life iLO on `shiva` (`10.0.30.10`, firmware 2.82) on the
  reasoning that "a BMC compromise in the lab costs the lab". That was written
  when the lab's attacker population was a VM the operator starts on purpose
  and powers off afterwards. A remote path changes who can be on that segment,
  and the residual was not written against this population.
- **It collides with #436's reason for existing, and that collision is
  recorded, not resolved here.** ADR-0014 closes Proxmox `8006` to
  `10.0.50.0/24` only, and ADR-0039 restates it: "Nothing on VLAN 30 gains a
  path to `8006` on either hypervisor." #436's jumpbox is on VLAN 30 and exists
  to hold a Proxmox API token. Either that rule widens — which changes an
  ADR-0014 *decision* and makes ADR-0039's consequence false, and would need a
  partial supersession rather than a note — or the jumpbox cannot do its job.
  **That is #436's decision and it is not taken here**; this ADR records that
  whichever issue lands first owns it, and that routed mode is what stops a
  widened `8006` rule from silently admitting every VPN peer.
- **The jumpbox's blast radius is the hypervisor, and this raises the odds.**
  Routed mode keeps a compromise legible afterwards; it does not make one less
  likely. #436's choice to give the jumpbox its own Proxmox user and token
  rather than `root@pam` is load-bearing for this ADR, not tidiness.
- **A peer is a credential, and there is no revocation story.** Removing one
  means editing `wg0.conf` and reloading. With two or three devices that is
  proportionate; it does not stay proportionate, and the first device that is
  lost rather than retired is when that matters. The peer ACL also lives in one
  file on one lab host, readable only by `wg show` — not in the firewall, where
  `pfctl -sr` could read it back, and not under any CI assertion, which is out
  of character for a repository that pins digests and greps its own history for
  secrets.
- **`docs/firewall-claims.yaml` will stay green while under-describing this.**
  Its shape is one `wholesale` list per interface, and `igc0.30`'s stays `[]` —
  correct, because the tunnel adds no wholesale reach. What it cannot express
  is "a second source subnet arrives on this interface", which is the fact that
  matters. Recorded so a green `make check-firewall` is not read as more than
  it is.
- **Nothing here is deployed.** The jumpbox does not exist; this ADR and its
  runbook are authored ahead of the host, the way `stacks/sensitive` was
  authored ahead of `trinity`. The decision is recorded now because the
  alternative is deciding it while locked out.

## What would reopen this

- **The tunnel is wanted from Winterfell, or routed to the sensitive tier.**
  That is trigger 2 fired a second time against the services it was written
  for, and the re-acceptance above does not survive it: it would take an
  identity provider or a new argument, not a rule change.
- **A third person gets a peer.** ADR-0022's trigger 3 is about accounts, and a
  WireGuard peer is an account by another name.
- **The Proxmox `8006` rule widens to admit the jumpbox.** That reopens
  ADR-0014 in its Decision rather than its premises, and ADR-0039 with it.
- **The peer list outgrows hand-editing**, or a device is lost rather than
  retired — both make revocation a mechanism rather than a habit.
- **Anything on ImaginationLAN becomes something the house depends on.**
  ADR-0014 put attack tooling there precisely because nothing does. A remote
  path into that segment is cheap only while the segment stays disposable.
