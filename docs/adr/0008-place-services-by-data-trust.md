# ADR-0008: Place self-hosted services by the trust of their data

**Status:** Accepted · 2026-08

## Context

The network is well segmented and thinly served. Beyond the observability stack
it hosts nothing the household actually uses — no password manager, no photo
library, no document archive, no media server. Adding them raises a question the
existing design does not answer: **which segment does a self-hosted service
belong to?**

ADR-0002 sorts *devices* by trust. Applying the same test to services is the
obvious move, but it only works once you stop treating "self-hosted services" as
a single category. They are not one thing. A password vault and a film library
have almost nothing in common in terms of what their compromise would cost.

Three options were considered:

1. **A dedicated services VLAN.** Clean in principle: household services are a
   distinct trust tier, so give them their own segment. Costs a new VLAN, a DHCP
   scope, switch configuration, and three or four new firewall rules — and it
   would have required amending ADR-0002, a document load-bearing in three
   places.
2. **Everything on Winterfell (99).** Simplest, and needs no new rules at all,
   since 50→99 already exists. But ADR-0002 describes 99 as the segment where
   "compromise here is total," and this would put a large, fast-moving codebase
   with a media upload endpoint on the same segment as the firewall's admin UI.
3. **Split by the trust of the data.** Sensitive services on management,
   streaming services with the media clients they serve.

Two discovered facts shaped the outcome. First, `oracle` — long earmarked as the
spare that would host this — turned out to be a dual-core A6-9200 with 4 GB and
a 5400 rpm disk, not the 32 GB machine the inventory claimed. It cannot host any
of this, so new hardware was required regardless of segment. Second, **CasaBonita
(40) is terminal by design and its televisions need a media server.** Any design
placing the media server elsewhere has to punch a rule through that terminal
property.

## Decision

Services are placed by what their data is worth, across two hosts. **No new
segment is created; the seven VLANs stand.**

**The sensitive tier — Winterfell (99).** A dedicated low-power mini PC hosts
Vaultwarden, Immich, Paperless-ngx and Home Assistant, behind Caddy and step-ca
for certificates, with AdGuard Home, ntfy and Homepage alongside. Everything
here holds data whose loss or exposure genuinely hurts. Clients on Hicks reach
all of it under the existing 50→99 rule, so this adds no rule at all.

**The streaming tier — CasaBonita (40).** A quiet N100-class NAS holds the bulk
media library and runs Jellyfin, with Plex beside it for household convenience.
This data is replaceable; its loss is annoying rather than catastrophic. Placing
it *with* the televisions means they reach it natively — **which answers the
terminal-VLAN problem by placement rather than by exception.**

Two new rules, both management-or-trusted initiating into something less
trusted:

| Flow | Purpose |
| --- | --- |
| 50 → 40 | Reach the NAS and media server from a workstation |
| 99 → 20 | Home Assistant reaching IoT devices |

Home Assistant sits on 99 rather than among the devices it controls. It holds
credentials to the locks and cameras, and does not belong on the segment whose
stated assumption is that everything on it is already compromised.

**Single sign-on is deferred.** Authelia was planned and is not being deployed
yet: with two users and no external exposure, per-application authentication with
TOTP is proportionate, and an SSO layer is operational weight that has not yet
earned its place. This leaves the "no MFA on the internal services" gap in
`security.md` open, knowingly.

> *The deferral above has an expiry as of
> [ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md),
> which also finds that per-application TOTP is not available on two of the
> services this paragraph assumes it for. The reasoning above is unchanged and
> this ADR is not superseded.*

## Consequences

- **Winterfell becomes busier and less special, and this is the real cost.**
  ADR-0002 says compromise there is total. Immich is a large, rapidly-moving
  codebase with an upload endpoint, and it will now sit on the same segment as
  the firewall's administrative interface, the UPS and the observability stack.
  That is a genuine dilution of the most valuable trust boundary in the design,
  and it is the strongest argument for the dedicated segment that was rejected.

  What makes it acceptable rather than reckless: nothing here is exposed to the
  internet and no ports are forwarded; the realistic threat is a supply-chain
  compromise in a container image, which `security.md` already names as accepted
  and undefended and which digest pinning mitigates; containers sit on private
  bridge networks with only the reverse proxy publishing a port, exactly as
  `snmp-exporter` already does; and pfSense's admin UI is already restricted to
  specific hosts on Hicks.

  Recording the cost is the point. A tradeoff written down is a decision; one
  that is not is an accident.
- The rule count rises from three to five. Every one remains directional —
  nothing untrusted ever initiates upward — which is the property that actually
  matters, and matters more than the count.
- ADR-0002 needs no amendment. The segment model is unchanged; only its
  population grows.
- **New hardware is required.** `oracle` cannot host this, and the loud lab
  hypervisor is the wrong home for services the household depends on (see
  ADR-0007). Two purchases where the plan originally assumed zero.
- Separating the tiers means two hosts to maintain and back up rather than one.
  The compensation is that a failure of the media box costs a film night, and a
  failure of the sensitive box costs a restore — never both at once.
- If the household grows, or if external access is ever wanted, this should be
  revisited. Both changes push toward a dedicated services segment and toward
  Authelia, and both were declined here on the strength of *two users, no remote
  access*. When that premise changes, so does the decision.
