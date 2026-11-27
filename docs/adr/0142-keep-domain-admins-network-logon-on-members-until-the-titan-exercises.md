# ADR-0142: Keep Domain Admins' network logon on members until the titan exercises are recorded

**Status:** Accepted · 2026-11 · amends
[ADR-0140](0140-correct-why-adr-0136-leaves-domain-admins-network-logon.md),
taking the decision it left open

## Context

[ADR-0136](0136-deny-the-domains-own-admins-the-console-on-members.md)
refuses Domain and Enterprise Admins the console and RDP on members, and
leaves them network logon.
[ADR-0140](0140-correct-why-adr-0136-leaves-domain-admins-network-logon.md)
withdrew the reason given for the second half, because the pipeline reaches a
member as its local Administrator. It left whether to close the gap as a
separate decision. This is that decision.

Read on `titan` on 2026-11-27:

- Its local Administrators are `AD\Domain Admins` and `TITAN\Administrator`,
  and nothing else. `t1-admin` exists (`roles/tiers`) but belongs to no group
  that administers a server.
- `RequireSecuritySignature` is `False`, so it is still a relay target as
  [ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
  derived.

Three exercises land on `titan`'s SMB as a borrowed identity, and none has
been recorded: constrained delegation (#1480) and resource-based constrained
delegation (#1478), both of which impersonate a user to `titan`'s CIFS, and
the NTLM relay (#1781). In each, the identity that matters is one that is an
administrator on `titan`, and today the only domain one is a Domain Admin.

## Decision

**Domain and Enterprise Admins keep network logon on members for now.**
`roles/gpos` and `verify.yml` are unchanged: `SeDenyNetworkLogonRight` names
`Tier 0 Admins` only.

**It is revisited once #1478, #1480 and #1781 are recorded.** Each exercise
file says which identity reached `titan` and what the estate saw. Closing the
gap then is a new ADR, and its precondition is a Tier 1 group that is an
administrator on `Servers`. Without that, a deny leaves no domain account to
administer `titan` over the network, and the three exercises reach it as a
user and nothing more.

## Alternatives considered

- **Deny it now.** It closes the residual ADR-0136 names. But it changes what
  the first run of each exercise against `titan` can show, before any of them
  has a baseline. It would also need the Tier 1 administrators group first, so
  it is not the one-line GPO change it looks like.
- **Leave the question open.** ADR-0140 did that, and it left the gap with no
  owner and no condition for closing it.

## Consequences

- **A Tier 0 credential can still arrive at a member over the network** (SMB,
  WMI, SSH as a domain admin). It is a known, owned gap, with a condition for
  closing it.
- **The exercises against `titan` run on the domain as built.** A relayed or
  impersonated Domain Admin gets an admin session on `titan`, and the exercise
  file records whether the estate saw it.
- `build-the-lab-domain.md` §5 and `roles/gpos`'s comment point here instead
  of saying the question is undecided.
