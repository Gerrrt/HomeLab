# ADR-0010: Keep the resolver on the gateway and filter behind it

**Status:** Accepted · 2026-08

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
