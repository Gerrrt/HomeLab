# ADR-0055: Forward to AdGuard alone

**Status:** Accepted · 2026-09 · supersedes the fallback half of
[ADR-0010](0010-keep-the-resolver-on-the-gateway.md)'s decision; the rest of
it stands

## Context

ADR-0010 keeps pfSense as every client's only resolver. Unbound forwards to
AdGuard Home, **with the public resolvers listed alongside it**, so that a dead
AdGuard costs filtering, not connectivity. It accepted a small leak to buy
that, reasoning that Unbound chooses forwarders by round-trip time, and that
AdGuard "on the LAN answers in well under a millisecond against ten to twenty
to Cloudflare, so it wins nearly every selection while it is alive".

AdGuard came up on `trinity` on 2026-09-28
([#404](https://github.com/Gerrrt/HomeLab/issues/404)), and the forwarder
change was made exactly as
[`forward-dns-to-adguard.md`](../runbooks/forward-dns-to-adguard.md) said:
`10.0.99.40`, `1.1.1.1` and `8.8.8.8`. Every check in that runbook passed. The
leak did not stay small:

- **Unbound's timings, read on `morpheus`:** AdGuard 77 ms, `1.1.1.1` 201 ms,
  `8.8.8.8` 375 ms. Minutes later they were 43, 32 and 57 ms. AdGuard is
  not "well under a millisecond". A lookup it has not cached makes its own
  encrypted round trip to Cloudflare or Google, so from Unbound's side it
  costs about what the public resolvers cost.
- **Unbound does not prefer the fastest forwarder.** It picks at random among
  every forwarder within its RTT band (400 ms by default), and all three were
  inside it.
- **Measured:** 60 random, never-cached subdomains of a blocked domain, sent
  through `morpheus`. **38 of them came back with real addresses.** Only 22
  reached AdGuard. `doubleclick.net` itself resolved to a Google address one
  minute, and to `0.0.0.0` the next.

A third of lookups filtered is not the decision ADR-0010 took. pfSense cannot
express the one setting that would keep its intent, Unbound's `forward-first`
("use the forwarder, recurse only if it fails"). It writes a single `.`
forward zone from *System → General Setup*'s DNS servers, and nothing more.

The choices:

| Answer | For | Against |
| --- | --- | --- |
| Leave it: three forwarders | No new dependency | Filters a third of lookups, and the docs would have to say the filter mostly does not work |
| Undo forwarding | Back to 2026-09-27 | No filtering at all, for a service that now exists |
| **AdGuard as the only forwarder** | Every lookup filtered: 60 of 60, measured | A dead AdGuard costs every outside name in the house. ADR-0010 called this option 1 wearing a different hat, and it is |

## Decision

**AdGuard on `10.0.99.40` is the only forwarder behind Unbound on `morpheus`.**
The public resolvers are removed from *System → General Setup*. Clients still
receive pfSense as their resolver, the DHCP scopes do not change, and the
`matrix.elysium` host overrides still answer internal names locally. That part
of ADR-0010 stands.

What makes accepting the dependency reasonable is making its failure loud and
short, not silent:

- **`AdGuardNotAnswering` is critical, at five minutes** (it was a warning at
  fifteen). It pages. Its text says the house cannot resolve outside names,
  and gives the one-line workaround.
- **Nothing routine stops AdGuard.** `backup-volumes.sh` no longer archives
  `adguard-work`, which is what took AdGuard off its stop list. On the day it
  was decided, a backup had taken DNS from the house for two minutes; the
  same backup afterwards resolved 150 of 150 lookups while it ran.
- **The workaround is written down.** Add `1.1.1.1` back under *System →
  General Setup*, unfiltered but resolving, then remove it again once
  AdGuard is back. The alert and the forwarder runbook both carry it.

## Consequences

- **The house's DNS depends on `trinity`.** A patch reboot is about a minute
  without outside names, which the TPM unlock
  ([ADR-0054](0054-encrypt-trinitys-disks-and-seal-the-root-key-to-the-tpm.md))
  keeps short. If `trinity` is off, stolen, or waiting at its passphrase
  prompt, the house has no outside DNS until someone applies the workaround.
  `morpheus`'s own lookups (package updates, the dynamic DNS update) share
  the dependency. Its gateway monitoring does not, because it pings
  addresses.
- **Blocked names answer `SERVFAIL`, not `0.0.0.0`.** Unbound validates
  DNSSEC with `harden-dnssec-stripped` on. To prove a blocked zone is
  unsigned, it asks for the zone's DS record, and AdGuard blocks that too,
  answering with a made-up SOA and no proof. The answer fails validation.
  To a device the name is unreachable either way. Turning validation off
  would buy tidier errors at the cost of validating nothing. The blackbox
  filtering probe asks AdGuard directly, so it still sees `0.0.0.0`.
- **The failure test changes meaning.** Step 4 of the forwarder runbook used
  to prove the fallback. Now it proves the page arrives, and about how long
  the house is without DNS before it does.
- **Reopen if** pfSense gains `forward-first`, or a second AdGuard instance
  exists somewhere that does not share `trinity`'s failure modes. Either
  restores ADR-0010's intent without its leak.
