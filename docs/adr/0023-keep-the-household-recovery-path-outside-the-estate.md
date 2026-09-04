# ADR-0023: Keep the household's recovery path outside the estate

**Status:** Accepted · 2026-09

## Context

[ADR-0008](0008-place-services-by-data-trust.md) puts Vaultwarden, Immich,
Paperless-ngx and Home Assistant on one mini PC on Winterfell, and the trust
reasoning that gets them there is sound — everything in that tier holds data
whose loss or exposure genuinely hurts, so it goes behind the most valuable
boundary in the design. Nothing below argues with the placement.

What the ADR does not weigh is **who can reach that data when the person who
runs the estate cannot.** That tier ends up holding the password manager — the
keys to every other account — the photo archive and the scanned documents,
behind self-hosted TLS from an internal CA, on a single low-power box, on a VLAN
that exists because pfSense says so.

If that box is down and the operator is unavailable, the credentials needed to
recover everything else are behind the thing that broke. And because step-ca
issues the certificates, a browser will not complete the handshake even when the
box is limping, so the failure is not a slow degradation the household can work
around — it is a wall, and clearing it takes exactly the skills the person doing
the clearing does not have.

**This is [ADR-0011](0011-keep-the-wiki-internal.md)'s problem with different
contents.** That ADR found the instructions for recovering a system hosted on
that system, and fixed it not by making the wiki more available but by tiering
the documentation by what each tier depends on: paper, then the wiki, then the
GitHub copy. The sensitive tier repeats the same circularity with data in place
of words. Its audience note transfers without amendment — a recovery path that
requires the estate to be healthy is not a recovery path, it is a reference
manual that has been mislabelled.

**The tier is unbuilt, which is the only reason this is cheap.** #102 was split
into per-service issues and every one of them is open; no hardware is bought and
nothing runs. Satisfying a continuity constraint before the data arrives is a
configuration choice. Satisfying it afterwards is a migration of a live vault, a
photo library and a document archive, done by the one person who is by
assumption already busy. This is the same argument ADR-0022 makes about putting
an identity provider in front of an empty Immich rather than a full one, and it
is due at the same moment.

Three things were checked while writing this, and each changed what the decision
had to say.

**Off-host is already a pattern here, and it is not off-estate.** `oracle` holds
the off-host copy of the firewall export
([ADR-0015](0015-give-oracle-the-off-host-jobs.md), `docs/architecture.md`), and
that is a real improvement on
[#92](https://github.com/Gerrrt/HomeLab/issues/92)'s complaint that a backup sat
on the machine it protects. But `oracle` is `10.0.99.30`: the same VLAN, the
same rack, the same power feed and the same room as the mini PC would be. Every
failure that motivates this document — fire, theft, flood, a mistake made with
root, or simply the operator being unreachable — reaches both boxes in one
event. The existing pattern therefore does not satisfy this constraint, and it
is close enough to look as though it does.

**Name resolution for the way out is already safe, by a decision made for other
reasons.** Any out-of-estate path needs the internet, and the internet needs
DNS. [ADR-0010](0010-keep-the-resolver-on-the-gateway.md) leaves the public
upstreams in Unbound's forwarder list precisely so that a dead AdGuard costs
filtering rather than resolution, which means the household keeps resolving
names while the mini PC is down. That is a dependency of this ADR which is
already met, and it is recorded here because nothing else says so: the next
person to tidy that forwarder list down to AdGuard alone would be removing the
floor under a recovery path, and would have no way to know it.

**The break-glass card already claims to answer this.** ADR-0011's paper tier
carries "who to call, reset order, **where credentials are**". That line is true
today because there is no vault. The day Vaultwarden holds the household's
credentials it either points inside the estate — which is the failure this
document exists about — or it points at something outside it, which has to exist
first. The artefact does not need inventing; an existing sentence on it goes
false on a knowable date.

## Decision

**No sensitive-tier service is required to stay reachable while the estate is
down.** That is the direct answer to the question, and it is deliberately not
the expected one. One mini PC cannot be made highly available, and each way of
pretending otherwise — a second box, a VPN terminating on 99, publishing through
Caddy — buys availability by adding components that can take it away. ADR-0011
already refused that trade for the wiki and gave the arithmetic: the failures
that make the thing unreachable still make it unreachable, and there are now two
more ways to arrive there.

The constraint is on the path instead. **Nothing the household needs in an
emergency may have the estate on its only route.** Each service in the tier gets
a class, and the class says what has to exist outside the estate before that
service is allowed to hold real data.

| Service | Class | What must be true before it holds real data |
| --- | --- | --- |
| Vaultwarden | **Independent** | The household's own credentials are recoverable without it |
| Immich | **Durable** | An off-estate copy exists, and its staleness is visible |
| Paperless-ngx | **Durable** | The same |
| Home Assistant | **Fail-safe** | Nothing physical it controls can be operated only through it |
| Caddy, step-ca | **Never on the path** | No household recovery step depends on either |
| AdGuard Home | **Never on the path** | Already true, under ADR-0010 |
| ntfy, Homepage | **Unclassed** | They hold nothing a household would need back |

**Vaultwarden — the household's vault is not this vault.** The recommendation is
that the family's own credentials live in hosted Bitwarden and that Vaultwarden
keeps the operator's. Vaultwarden is Bitwarden-compatible by design, which is
the entire reason [#131](https://github.com/Gerrrt/HomeLab/issues/131) chose it,
so this costs nothing in clients or habits — the same app on the same phone,
pointed at a different server — and it takes the operator out of the recovery
path for the one dataset where being in it is intolerable.

The alternative the question offers is not rejected: the vault stays here, the
emergency kit is on paper, and Bitwarden's emergency access is configured. What
that route has to carry is a cost ADR-0011 already priced. It rejected a
periodic offline export because it "decays without announcing it", and a paper
kit is that artefact with the same decay; it survives in this estate only
because ADR-0011 bounds it with an annual drill and a `Last checked` line. Take
the paper route and it inherits that drill, and the drill grows an item.

Whichever is chosen, **it is tested from the other person's own device, signed
into their own account, without the operator present.** A path demonstrated by
the person who built it has tested the path and not the reader. ADR-0011 names
this failure for its GitHub grant — granting and never verifying "presents as
working right up until the moment it matters" — and an untested emergency-access
configuration presents identically.

**Immich and Paperless-ngx — the requirement is durability, not availability.**
Nobody needs a photograph at 2am, and a document archive that is unreachable for
a week costs nothing. What cannot be tolerated is losing them: of everything in
this estate, these two are the only categories that cannot be re-bought,
re-derived from the hardware or re-created from this repository. So the
requirement is a copy outside the estate, with two properties on the copy.

- **Off-estate, not off-host** — for the reason `oracle` demonstrates above.
- **Its freshness is observable.** ADR-0011's objection to the offline export
  applies here exactly: a copy that quietly stops updating is worse than no copy,
  because it is read with confidence. The mechanism is
  [#77](https://github.com/Gerrrt/HomeLab/issues/77)'s timers and the alerting
  that already exists — this is a scheduled job that reports, not a habit.

And the circularity has to be broken rather than moved: **the off-estate copy is
encrypted, and the key that opens it cannot be the one only the operator holds.**
[#106](https://github.com/Gerrrt/HomeLab/issues/106) is this same problem one
layer down — one key, one holder — and an encrypted archive of the household's
photographs and documents whose key has a single holder recreates the failure it
was made to prevent, one shelf further away.

**step-ca and Caddy — never on a household recovery path.** This is a
prohibition rather than a piece of work, and it is the cheapest item here.
Nothing printed on the break-glass card, and no step a non-technical reader is
asked to take, may be an internal HTTPS name or depend on a certificate this
estate issues or on its expiry. ADR-0011 made this ruling for the wiki and gave
the reason — an expired internal certificate "fails quietly and looks like a
browser problem to whoever is holding the phone" — and it generalises unchanged.
The card's existing `lemmiwinks.matrix.elysium` stays consistent with this
because ADR-0011 classes the wiki as a convenience rather than a recovery tool.
It should remain the only internal name on there.

**Home Assistant — the constraint is physical, and it is not about reachability
at all.** It holds nothing physical today. Nothing it acquires may become the
only way to operate a door, a lock or the heating: keys keep working, switches
keep working, valves keep turning. A dead dashboard is an inconvenience; a door
that opens only through a container on a box that is down, while the person who
understands the box is elsewhere, is a different severity class entirely. If
that stops being true — the moment a lock is *fitted* rather than *integrated* —
this paragraph is no longer sufficient and the question deserves its own
decision rather than a clause in someone else's.

**These fall due on ADR-0022's triggers, deliberately.** The first real
credential, the first real photo, the first real document; seeded test entries do
not count. One event therefore fires two obligations — record an SSO decision,
and satisfy the continuity class — because they are the same moment observed
twice, and giving them separate conditions would mean maintaining two answers to
"has the data arrived yet". ADR-0022's other two triggers, external reachability
and a third account holder, are not repeated here; they change the SSO question
and not this one.

**What this does not do.** It chooses no provider, buys no storage, configures no
emergency access and rehearses no restore. The constraint is the artefact. The
work is per-service and belongs on
[#131](https://github.com/Gerrrt/HomeLab/issues/131),
[#132](https://github.com/Gerrrt/HomeLab/issues/132),
[#133](https://github.com/Gerrrt/HomeLab/issues/133) and
[#134](https://github.com/Gerrrt/HomeLab/issues/134).

## Consequences

- **Four of the sensitive-tier issues gain a precondition they did not have.**
  #131 cannot hold a real household credential until the family's own vault is
  elsewhere and has been opened from their device; #132 and #133 cannot hold a
  real photo or document until an off-estate copy exists whose staleness is
  visible; #134 gains a limit on what it is allowed to be the only route to. None
  of them is blocked from being deployed, which matters — the constraint is on
  the data arriving, not on the container starting, and that is what makes it
  cheap to honour.
- **It costs money and it sends household data out of the house for the first
  time.** ADR-0011 declined to publish the wiki partly because doing so would
  reveal the estate's topology and "the specific host that holds the password
  manager". This sends the photograph and document archives further than that.
  The difference that makes it acceptable is the difference between an encrypted
  blob at rest with a provider and a readable map: one needs a key nobody outside
  this house holds, the other needs a browser. That difference is load-bearing,
  which is why the encryption clause above is a requirement and not a
  recommendation.
- **The recommended answer for Vaultwarden reverses this estate's default for one
  dataset, and it should be read as a concession rather than a preference.**
  Self-hosting exists here to avoid depending on someone else's availability and
  someone else's retention policy. For the household's own credentials that
  calculation genuinely inverts, because the alternative is not a large operator
  with an SRE team but one mini PC and one person, and the person is the part
  that fails in the scenario this document is about.
- **The off-estate copy is a new place the household's data can be lost from, and
  it is the estate's first.** A provider breach or an account takeover reaches
  something no firewall rule here protects. Encryption at rest with a key that
  never leaves the house is what reduces it to an availability problem, and the
  residual — that the copy exists at all, in someone else's building — is
  accepted deliberately and belongs in `docs/security.md` alongside the others.
- **The paper card acquires a second obligation and no second drill.** ADR-0011's
  annual check already exists and already reads the "where credentials are" line;
  it now also checks that what that line points at still opens. Reusing a drill
  is worth more than adding one, because the failure mode of both documents is
  the same — a maintenance obligation nobody performs — and two drills halve the
  odds that either happens.
- **Sharing ADR-0022's triggers is efficient and slightly risky.** The risk is
  that a busy moment honours the half of the trigger that is easier to see. The
  mitigation is that both halves are checkable after the fact by a reader with no
  context: an ADR either exists or does not, and a copy either opens from another
  device or does not.
- **ADR-0008 is not superseded and not amended.** ADR-0001 keeps it immutable;
  its sensitive-tier paragraph gains a forward pointer to this document and
  nothing else. Every placement it made still holds — this constrains what must
  exist *elsewhere*, not what runs on Winterfell.
- As with ADR-0022, no rule, container or byte of configuration changes here. The
  artefact is a constraint written down before the data exists to violate it,
  which is the smallest thing that could have answered the question and the only
  one that gets cheaper the earlier it lands.
