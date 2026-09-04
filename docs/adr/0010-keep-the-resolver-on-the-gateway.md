# ADR-0010: Keep the resolver on the gateway and filter behind it

**Status:** Accepted · 2026-08

> **Two facts in the Context below are wrong, and were wrong when this was
> accepted:** Unbound forwards nothing, and one client is handed public
> resolvers directly. Both were read off `morpheus` on 2026-09-04 — see
> [Verified against the running config](#verified-against-the-running-config--2026-09-04)
> at the foot of this ADR. The decision is unaffected; what it costs to
> implement is not.

## Context

ADR-0008 places AdGuard Home on the Winterfell mini PC. It says where the
service sits and nothing about how clients reach it — and that second question
turns out to carry more risk than the first.

Today every DHCP scope hands out pfSense as the client's only resolver. Unbound
answers `matrix.elysium` from host overrides and forwards everything else to
Cloudflare and Google. Those two are *Unbound's* upstreams, not a secondary for
the client: the client has exactly one resolver, and it is the same box as its
default gateway. That co-location is worth more than it looks. It means "DNS is
down" and "the gateway is down" are one event and never two, so the estate has
no independent way to lose name resolution.

Making AdGuard the client-facing resolver would end that property. DNS would
move onto a single non-redundant mini PC that reboots for updates, and its
failure would look like this: every device in the house breaks at once, pfSense
healthy, WAN up, modem lights green. It reads as "the internet is down". The
household runbook walks modem → switch → pfSense → eero and comes back green at
every step, because every one of those things *is* fine. There is no branch for
"everything is up and it still doesn't work", and the person following it is, by
assumption, not technical.

Three options were considered:

1. **AdGuard alone, advertised by DHCP.** Filtering is airtight and the mini PC
   becomes a household-wide single point of failure. This is the case above.
2. **AdGuard primary, pfSense secondary, both advertised.** The intuitive fix,
   and the weakest, because stub resolvers do not do primary-then-secondary
   failover in the way the names suggest. Behaviour varies by platform — some
   query the first and fall back after a timeout, some rotate, some race and
   prefer whichever answered fastest last. The practical effect is that the
   secondary is consulted whenever the primary is merely *slow*, so filtering
   leaks unpredictably and invisibly: both servers return valid answers, and
   nothing distinguishes a filtered reply from an unfiltered one at the client.
3. **pfSense stays the only advertised resolver, and Unbound forwards to
   AdGuard.** Filtering moves behind the resolver instead of in front of it.

Two facts settled it. First, **per-client filtering rules and visibility are not
wanted.** That was the only property favouring options 1 and 2, and without it
they have nothing the third lacks. Second, options 1 and 2 both require every
VLAN — including the low-trust ones — to hold a DNS path into the sensitive
tier. ADR-0008 places services by the trust of their data; routing guest and IoT
name resolution into VLAN 99 works against the reasoning that put AdGuard there.

## Decision

**Clients keep receiving pfSense, per VLAN, as their only resolver.** The DHCP
scopes do not change. Unbound runs in forwarding mode, and its forwarder list is
AdGuard's Winterfell address first, followed by the existing public upstreams.
The `matrix.elysium` host overrides stay where they are.

Filtering therefore happens one hop behind the resolver the household talks to,
and **no new inter-VLAN rule is needed** — the rule count stays at the five
ADR-0008 established.

**The public upstreams are deliberately left in the forwarder list**, and that
detail is the whole difference between this decision and option 1. With AdGuard
as the sole forwarder, a dead AdGuard still costs every external name in the
house; it would be option 1 wearing a different hat. Listing the public
resolvers alongside it means Unbound marks an unresponsive forwarder down and
carries on, so the failure costs filtering rather than connectivity.

That does let some queries bypass the filter while AdGuard is healthy, since
Unbound selects forwarders by round-trip time. In practice the leak is small
precisely because it is decided by latency: AdGuard on the LAN answers in well
under a millisecond against ten to twenty to Cloudflare, so it wins nearly every
selection while it is alive. This is not option 2 repeating one layer down —
Unbound's forwarder selection is stable, observable and tunable, and a client
stub's is none of those.

## Consequences

- **Per-client attribution is gone, and that is the real price.** AdGuard sees
  every query arriving from pfSense, so its dashboard becomes a single aggregate
  and per-device rules stop being possible without revisiting this ADR. The
  decision rests entirely on *per-client filtering is not wanted*; if that
  premise changes, this should be reopened rather than worked around, because
  every workaround for it leads back to option 1 or 2.
- **Losing AdGuard becomes silent, which is the cost of the graceful failure.**
  Option 1 failed loudly — a dead filter took the house offline and reported
  itself within ninety seconds. Here the only symptom is advertisements
  reappearing, which nobody reports and which is indistinguishable from a
  blocklist that never covered a given site. Detection has to be deliberate, and
  a probe has to query AdGuard directly: one sent through the normal path always
  passes, because the fallback is doing its job. Tracked as its own item; the
  mechanism is the blackbox-exporter already on the roadmap.
- **The household-facing documentation stays correct without edits.** Every
  runbook, wiki page and diagram that points at pfSense for DNS keeps pointing
  at pfSense. A change that requires no update to the pages the family reads is
  worth something on its own, given how reliably those pages go stale.
- **ADR-0008's trust boundary is strengthened rather than diluted.** DNS from
  the low-trust segments terminates at their gateway and never enters VLAN 99.
  Given that ADR-0008 already concedes Winterfell becomes busier and less
  special, declining to add a household-wide inbound service to it is a small
  repayment against that cost.
- **AdGuard becomes a dependency of one config file rather than of every
  client.** Reversing this decision, or swapping the filter for something else,
  is an edit to Unbound's forwarder list — no DHCP change, no client reconfigured,
  no lease renewal to wait out. Options 1 and 2 would have made the same reversal
  a scope-by-scope change with a lease TTL attached to it.
- Filtering is now a convenience rather than a control, and should be described
  that way. Anything relying on DNS blocking for security would be relying on a
  component the design lets fail open on purpose.

## Verified against the running config · 2026-09-04

The Context above was written from the `Gerrrt/Lemmiwinks` pages. It has now
been read off `morpheus` directly. **The decision stands unchanged. Two of the
facts underneath it do not.**

**Where the error actually came from, because the obvious answer is wrong.**
This ADR was written on 2026-08-24, and on that date the vault did say external
DNS was Cloudflare and Google — the claim was copied accurately. Six days later,
on 2026-08-30, the vault settled that section against `/cf/conf/config.xml` and
corrected itself in two places at once: `network/dhcp_dns_architecture` now says
"**There isn't one, and that is the correct answer rather than a gap**", and
`runbooks/dns_is_broken` carries a standing instruction not to restore the
forwarding description. Both were right, and both were right eleven days before
this section was written.

So the failure was not that the wiki went stale. The wiki repaired itself in six
days. The failure was that this ADR copied a fact and never looked at the source
again — and [#123](https://github.com/Gerrrt/HomeLab/issues/123), filed the same
day as this ADR, quotes the same superseded text and concludes from it that the
Lemmiwinks pages are nine months stale. They are not, on this subject. A copied
fact goes stale at the copy, and the copy is the thing with nobody watching it.

### Unbound forwards to nothing at all

`/var/unbound/unbound.conf` holds `module-config: "validator iterator"`, an
`auto-trust-anchor-file`, and **zero `forward-zone` blocks**. The resolver walks
the root servers itself and validates DNSSEC. The `8.8.8.8` and `1.1.1.1` under
System → General Setup are the *firewall's own* fallback — they sit in
`morpheus`'s `/etc/resolv.conf` below `127.0.0.1`, with *DNS Server Override*
and *Use local DNS* both unchecked — and no client query has ever reached them.

So "the existing public upstreams", which the Decision says to keep listed
alongside AdGuard, are not an existing forwarder list waiting to be prepended
to. **Implementing this ADR means switching Unbound from recursive to forwarding
mode**, which is a larger change than the Decision's wording implies:

- Today no third party sees the estate's query stream at all. Forwarding hands
  it to AdGuard, and whenever AdGuard is slow or down, to Cloudflare and Google.
  That is a fair price for filtering, but this ADR assumed the price had already
  been paid, and it has not been. It should be accepted deliberately rather than
  arrive as a side effect of ticking *Enable Forwarding Mode*.
- DNSSEC validation is on and should stay on, which makes the forwarders'
  behaviour part of this change rather than incidental to it: a forwarder that
  strips DNSSEC records turns every signed zone into SERVFAIL, and the symptom
  is indistinguishable from the outage this ADR exists to prevent.
- **The graceful fallback the whole decision turns on has never run here**,
  because there is currently no forwarder that can fail. "Unbound marks an
  unresponsive forwarder down and carries on" is documented behaviour, not
  measured behaviour on this box. It is worth stopping AdGuard on purpose once
  #102 is built and watching resolution continue, rather than finding out during
  the first real outage.

### One client bypasses all of this

Every enabled scope hands out pfSense — five by leaving `dnsserver` empty so the
interface address is served, and Hicks by naming `10.0.50.1`, which is that same
address written out. One static map inside Hicks overrides it:

| Static map | Address | DHCP hands it |
| --- | --- | --- |
| `Mekenna-Laptop` — "Mekenna's Work Laptop" | `10.0.50.69` | `8.8.8.8`, `9.9.9.9` |

That laptop never reaches Unbound. It will never be filtered by AdGuard, and it
cannot resolve `matrix.elysium` names at all. This reads as deliberate — a work
machine kept off the household's split-horizon DNS — and nothing here proposes
changing it.

It is recorded because *clients only ever have one resolver, so they cannot
select around the filter* is the premise this decision rests on, and there is
exactly one exception to it. An exception that is written down is a policy; one
that is not is a hole that gets rediscovered.

### What was confirmed as documented

- **Six host overrides**, all `.matrix.elysium`: `grafana` and `prometheus` →
  `10.0.99.20`, `lemmiwinks` and `oracle` → `10.0.99.30`, `morpheus` →
  `10.0.99.1`, `neo` → `10.7.7.2`. This settles the inconsistency #123 raised:
  the wiki really is on `10.0.99.30` alongside `oracle` — both the name and that
  address answer `200` from the running blackbox exporter — so the Lemmiwinks
  page putting it on `10.0.99.20` is the stale one.
- **No domain overrides**, so nothing else is diverted per-zone.
- **The client's view**, checked with `resolvectl status` on `prometheus`
  (10.0.99.20): a single resolver, `10.0.99.1`, search domain `matrix.elysium`.
