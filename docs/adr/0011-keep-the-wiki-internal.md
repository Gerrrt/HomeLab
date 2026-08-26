# ADR-0011: Keep the wiki internal and put the emergency tier on paper

**Status:** Accepted · 2026-08

## Context

The Lemmiwinks wiki documents this estate, and it runs inside it — a container
on Oracle at `10.0.99.30`, on VLAN 99, behind the same firewall, switch and
power as everything it describes. The consequence is circular in a way that is
easy to state and easy to leave unfixed: **the instructions for recovering a
system are hosted on that system.**

Three ordinary failures take the documentation out along with the thing it
documents. pfSense down: no docs. Oracle down: no docs. Power cut: no docs. The
household runbook makes the shape of it obvious — its Step 5 tells the reader to
browse to `https://10.0.99.1`, and that instruction is itself only readable over
the network whose gateway is at `10.0.99.1`.

The audience makes this sharper than it would otherwise be. These pages are
written for a non-technical household, for the case where the person who built
the estate is unreachable. A recovery document that requires the estate to be
healthy is not a recovery document; it is a reference manual that has been
mislabelled.

The content itself is not at risk. The wiki syncs from a GitHub repository, so
the words survive any hardware failure here. But surviving and being *reachable
by the intended reader* are different properties, and only the first was ever
true. The repository is private, it is a tree of raw Markdown with no navigation,
and nothing anywhere told anyone it existed.

ADR-0008 makes external exposure look like the obvious fix. It already placed
Caddy and step-ca on the Winterfell mini PC for the sensitive tier, so the
machinery for publishing a service exists and reusing it would be cheap.

## Decision

**The wiki is not exposed outside the estate.** No port forward, no external
hostname, no reverse-proxy entry. It stays reachable only from inside, exactly
as it is today.

Instead the documentation is treated as three tiers, each depending on strictly
less than the one above it, and each covering strictly less:

| Tier | Contents | Dependencies |
| --- | --- | --- |
| Printed break-glass card | Who to call, reset order, where credentials are | None |
| The wiki | Everything | The estate's network and power |
| The GitHub repository | The same words, as raw Markdown | Internet, plus a private-repo grant |

**The emergency subset lives on paper**, as a one-page card kept on the fridge
and with the estate paperwork. That work is done; this ADR records why it is the
top tier rather than a stopgap.

**The GitHub copy is documented as a technical recovery path and not as a
household one.** Read access is granted to the person named on the card as the
technical second — someone who knows what a repository is — and that grant is
tested once rather than assumed.

Three alternatives were considered and rejected.

**Publish the wiki behind Caddy and step-ca**, per the ADR-0008 pattern. This is
the one that looks right and is not. It would make the documentation depend on a
reverse proxy and a certificate authority that both run in this house, on the
same rack and the same power as the wiki itself. The failure modes that make the
docs unreachable today would still make them unreachable, and there would be two
more components able to cause the same outage on their own — an expired internal
certificate being the obvious one, since it fails quietly and looks like a
browser problem to whoever is holding the phone. It would add exposure and
availability risk in exchange for availability that does not materialise in any
of the three cases that motivated it.

**Make the Lemmiwinks repository public**, so no account is needed. This buys
real convenience, and it publishes the estate's full topology: addressing plan,
VLAN layout, rack order, service inventory, and the specific host that holds the
password manager. That is a poor trade for a fallback whose realistic reader is
one named person.

**Keep a periodic offline export** — a PDF or synced folder on family phones.
Attractive, because it is the only option that is both readable by the household
and independent of the house. Rejected because it decays without announcing it:
it requires a recurring manual export, nothing detects the day it stops, and a
stale copy read with confidence during an emergency is worse than no copy at
all. The paper card covers the same need with a maintenance obligation that is
visible on its face and checked annually.

## Consequences

- **The emergency tier is now a maintenance obligation rather than a solved
  problem, and that is the honest cost.** A printed card goes stale silently in
  exactly the way an offline export would; the difference is that its staleness
  is bounded by a deliberate annual drill and by a `Last checked` line on the
  card itself. If that drill does not happen, this decision quietly degrades to
  "the household has nothing", and the drill is therefore load-bearing rather
  than tidy.
- **The rack's physical order becomes part of the documentation contract.** The
  card instructs whoever holds it to press the power button on the fifth box
  from the top. Reordering the rack invalidates a document that cannot be
  hot-fixed, and someone will follow it anyway. This is already noted in the
  wiki's physical-topology page; it is a consequence of choosing paper.
- **The GitHub tier depends on an access grant that must actually be tested.**
  Granting and never verifying is the standard failure here, and it presents as
  working right up until the moment it matters.
- **The wiki should be described as a convenience rather than a recovery tool,
  and written that way.** Anything that positions it as the thing to consult in
  an emergency is relying on a component this decision lets fail. The same
  distinction ADR-0010 draws for DNS filtering applies here.
- **Nothing about the estate's exposure changes.** No new inbound path, no new
  certificate to renew, no new service on the Winterfell segment whose dilution
  ADR-0008 already conceded. Declining to add one is a small repayment against
  that cost.
- **Reversing this is cheap if the premise changes.** The rejection of external
  exposure rests on emergency-time availability, not on secrecy. If the wiki
  ever needs to be readable from outside for an ordinary reason — reading it at
  work, or a second household — that is a different question with a different
  answer, and it should supersede this ADR rather than be argued as an exception
  to it. The paper tier stays regardless; it is not what external exposure would
  replace.
