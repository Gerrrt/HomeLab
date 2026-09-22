# ADR-0044: Answer the endpoint with dynamic DNS from `morpheus`

**Status:** Accepted · 2026-09 · discharges decision 5 of
[ADR-0042](0042-terminate-the-remote-path-on-the-lab-and-route-it.md)

## Context

[ADR-0042](0042-terminate-the-remote-path-on-the-lab-and-route-it.md) designed
the estate's first inbound path and then, in its fifth decision, declined to
say where a peer sends its first packet: the WAN address is ISP-assigned by
DHCP, there is no dynamic DNS anywhere in the estate, and the two answers it
could see — a static address bought from the ISP, or a third party handed a
continuously-updated pointer to the house — were "a different decision with a
different argument". It recorded the gap as blocking and owned by its own
issue. That issue was never filed until
[#530](https://github.com/Gerrrt/HomeLab/issues/530), which also noticed the
third answer already on file for another reason:
[#447](https://github.com/Gerrrt/HomeLab/issues/447)'s VPS relay, whose static
address would answer this question for free. Until one of the three is chosen,
[#442](https://github.com/Gerrrt/HomeLab/issues/442) is a configuration file
with nowhere to send anything.

ADR-0042 argued from what the repository knew. This one argues from what the
WAN actually does, measured on 2026-09-19 from `prometheus` and from
`morpheus`, because two of the three options stand or fall on facts no
document here had recorded.

### What the WAN is, measured

- **The address is a real public one, not carrier-grade NAT.** The address on
  `em0` and the address the internet sees from `prometheus` are the same, and
  it is not in `100.64.0.0/10`. The stop-condition
  [`open-the-remote-path.md`](../runbooks/open-the-remote-path.md) §0 wrote
  for the CGNAT case has been checked, and it does not apply. Without this
  fact neither a port forward nor dynamic DNS could work and the only answer
  would have been #447's relay.
- **The ISP is Comcast, on a residential plan.** The DHCP lease says so, and
  so does the reverse record. That settles the first option before price
  enters: Comcast does not sell a static address on residential service. The
  product that carries one is a Comcast Business contract, with the static
  address as a monthly line on top of it. "A static address from the ISP" is
  therefore not a purchase, it is a change of service, and the recurring cost
  is the whole plan rather than the $10–30 a month the address itself is
  listed at.
- **The address is sticky.** Every lease `dhclient` holds on file for `em0` —
  seventeen of them — carries the same address, renewed in place on a
  four-day term. Comcast ties the assignment to the modem's MAC, which is why
  [`restore-the-firewall.md`](../runbooks/restore-the-firewall.md) already
  warns that the spare's different MAC means a different public address. In
  practice the address changes when the hardware does, and not otherwise.
- **The WAN also holds one global IPv6 address**, as
  [`security.md`](../security.md#segmentation) records. It is not the endpoint: a
  roaming client on a café network or a mobile carrier is not reliably v6,
  and a tunnel that only comes up from some networks is not a remote path.
- **Nothing here is configured yet.** `config.xml` carries no dynamic DNS
  client. The pfSense release on `morpheus` ships one, with a long list of
  providers and an RFC 2136 tab, so the mechanism is a form on a box the
  estate already runs, not new software.
- **The estate owns no public domain, no DNS API credential and no public-CA
  ACME.** `.elysium` is an invented top-level domain
  ([ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)),
  the tier's ACME is `tls-alpn-01` against its own CA
  ([ADR-0037](0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md)),
  and Cloudflare appears in this repository only as a resolver upstream. Any
  of the three answers is a new relationship with a third party, from zero.

### What a pointer in someone else's zone can and cannot do

ADR-0042's objection to dynamic DNS was that it hands a third party "a
continuously-updated pointer to a house whose WAN address `security.md`
deliberately withholds". That objection deserves to be taken apart rather than
waved through, because the answer turns on it.

**What the provider learns.** The WAN address, and that a house has given it a
name. The address is the one fact every site the household visits already
sees, and the idiom `security.md` uses to accept the blackbox probes' egress —
"nothing about the estate is disclosed beyond the fact that this address
exists, which the ISP knows anyway" — applies to the address on its own. It
does not apply to the *name*: a name is the maximally remote form of the fact
the withheld list exists to withhold, useful to someone who has never stood
at the rack, which is the exact test `security.md` uses to decide what is
published. So the address is conceded and the name is not.

**What a hijacked or stale record can do.** Send a peer's first packet to the
wrong host. That is all. A WireGuard peer authenticates the server by its
public key before it sends anything readable; a host that answers at the
name without the server's private key cannot complete a handshake, and a
host that has the key is the jumpbox. A wrong record therefore costs
*availability* and nothing else — the peer fails to connect, and the operator
carries the bare address on the withheld list as the fallback. The record is
in the availability path of the remote path and in no other path.

**Whose availability.** The provider's, added to the ISP's and the house's.
That is a real dependency and it is the cost of this decision: a free service
run by someone else is now one of the things that has to be up for the
operator to get in from a hotel room. The sticky address blunts it — a record
that was right last month is almost certainly right today — and sharpens a
second problem, that a broken updater goes unnoticed for as long as the
address does not move, which is months.

## Decision

**1. Dynamic DNS, updated by `morpheus`.** The WireGuard endpoint is a
hostname in a dynamic DNS provider's zone, kept current by the client pfSense
ships, under *Services → Dynamic DNS*, bound to the WAN interface. It updates
on the DHCP event that changes the address and re-checks daily. The client's
configuration lives in `config.xml`, so a restore onto the spare hardware
carries it, and the record follows the new address that the spare's MAC is
given without anyone remembering to do it.

Not a timer on `prometheus`. A host on Winterfell does not own the WAN and
would have to discover the address from outside on a schedule, which is a
second moving part doing badly what the firewall does on the event itself.
[ADR-0015](0015-give-oracle-the-off-host-jobs.md) keeps third-party workloads
off `morpheus`; a client the firewall ships and runs for itself is not one.

**2. A free provider, chosen by criteria the ADR names and not by a name it
publishes.** Native support in the pfSense client, so no custom script on the
firewall; authentication by a token scoped to the one record rather than by
the account password; no periodic "confirm you still exist" renewal, which is
the failure mode that silently deletes a record from a hobby account; and no
charge. The provider, the hostname, the account and the update token join the
endpoint and the listen port on
[`security.md`](../security.md#what-this-repository-deliberately-does-not-publish)'s
withheld list. Publishing the provider narrows the search for the name to one
zone, and ADR-0042 decision 6 already decided that a repository which withholds
the address and then publishes where to send a packet has withheld nothing.

**3. An IPv4 A record only.** The WAN's global v6 address is not a second
endpoint today. It can become one later, as a second client entry on the same
form, when the client population is known to be v6-capable.

**4. A static address from the ISP is rejected on the facts.** It does not
exist on the service the house buys. Reaching it means a business contract,
a subscription several times the size of the line item #530 imagined, for a
tunnel into a segment that exists to be broken. The buy list does not get a
row, and the rule that a purchase enters that list only by a decision the
operator made is honoured by recording the decision not to.

**5. The VPS relay is not taken for this.** #447's relay would answer the
endpoint question as a side effect, and the two issues were right to be read
together. Read together, they say: a relay is justified when there is
something to publish, and nothing is. Buying one for an address is #447's cost
without #447's reason, and it puts a host outside the house on the remote
path's trust — a machine that can be reached without passing `morpheus` at all.
When #447 is taken on its own merits, its static address replaces this record;
see *What would reopen this*.

## Consequences

- **#442 loses this blocker and keeps the other.** The tunnel still waits on
  `phoenix` ([#436](https://github.com/Gerrrt/HomeLab/issues/436)). §0 of
  [`open-the-remote-path.md`](../runbooks/open-the-remote-path.md) stops
  being a stop sign and becomes the first step: configure the client, force
  an update, verify the name from outside the house.
- **A third party sits in the availability path of the remote path.** The
  estate's off-estate dependencies were healthchecks.io and ntfy, both for
  alerting; this is the first one whose failure keeps the operator *out*. The
  fallback is the bare address on the withheld list, which works for as long
  as the address stays sticky and is exactly the kind of thing that is wrong
  after the one hardware swap that changes it.
- **Record freshness is unmonitored by construction, today.** Nothing in the
  estate asks whether the name still resolves to the WAN address, and the
  sticky address means a broken updater stays hidden for months. The check is
  a `dns` probe from inside compared against the address `morpheus` holds,
  and it is not built here — this ADR records the decision, and a follow-up
  issue owns the probe. Until then the runbook's outside-the-house check is
  the only one, and it runs when a human runs it.

  > **Update · 2026-09-22.** The check is built
  > ([#604](https://github.com/Gerrrt/HomeLab/issues/604)), in a different
  > shape from the one this bullet names. There is no `dns` probe from
  > inside. `scripts/collect-gateway-state.sh` sends a script to `morpheus`
  > that reads the name from `config.xml` and the WAN address from the
  > interface, then asks a public resolver on the firewall itself. Neither
  > value leaves the box; only the verdict does, as
  > `homelab_ddns_record_matches_wan`, and `DdnsRecordStale` fires when it
  > has read 0 for an hour. The decision above is unchanged. What expires is
  > this consequence's "unmonitored".
- **One more credential lives outside the repository.** The provider account
  and its token are on the withheld list beside the endpoint, and the token is
  in `config.xml`, which
  [`backup-firewall.sh`](../../scripts/backup-firewall.sh) already treats as
  secret because it carries the WAN address and password hashes. Nothing new
  is needed to keep it out of the tree; something new *is* needed to remember
  it exists when the account is rotated, and that is the withheld list's job.
- **The buy list is untouched**, and the sentence in #442 that said
  "Purchases this needs: None" turns out to have been right for the wrong
  reason.
- **ADR-0042 decision 5 is discharged, not amended.** Its text stands; a note
  at its head points here.

## What would reopen this

- **Carrier-grade NAT arrives on the WAN.** The address on `em0` lands in
  `100.64.0.0/10`, or the address `prometheus` sees from outside stops
  matching it. Then no inbound path from the house works and the answer is
  #447's relay or an outbound-only overlay — the different ADR the runbook's
  CGNAT note already names.
- **#447 is taken.** A relay with a static address is a better endpoint than
  a record in a free zone, and the day it exists the peers' `Endpoint` moves
  to it and the dynamic DNS client is removed rather than left running with
  nothing depending on it.
- **The ISP changes.** Every fact under *What the WAN is, measured* is about
  Comcast's residential service. A new provider is a new measurement.
- **The provider dies, starts charging, or adds the renewal nag this ADR
  selected against.** The record moves to another provider that meets the
  criteria; the criteria do not move.
- **The name is wanted for anything other than this tunnel.** A record that
  fronts a published service is #447's design and
  [ADR-0011](0011-keep-the-wiki-internal.md)'s reopening clause, and neither
  is argued around by pointing at a record that already exists.
