# ADR-0141: Switch three of the DCs' shipped defaults, and keep dsHeuristics as shipped

**Status:** Accepted · 2026-11 · amends
[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
on LDAP signing, and adds three switches to
[ADR-0083](0083-give-the-lab-domain-its-deliberate-weaknesses-as-switchable-tags.md)
under its reopen clause

## Context

A read-only audit of `bahamut`, the PDC emulator, ran from 2026-11-13 to
2026-11-25, with `leviathan` read for the same points. It found four things
on the two domain controllers that the repository either contradicts or does
not mention at all:

- **LDAP signing is enforced.** ADR-0029 lists it as "hardening deliberately
  removed, once, with the removal recorded", because Server 2025 DCs require
  it where 2019 and 2022 did not. Nothing removed it. Both DCs read
  `LDAPServerIntegrity` 1 with `LdapServerEnforceIntegrity` unset, which on
  Server 2025 means enforced, and both log Directory Service event 2888
  (unsigned binds rejected), last on 2026-11-17.
  [`build-the-bloodhound-guest.md`](../runbooks/build-the-bloodhound-guest.md)
  already works around it: `bloodhound-ce-python` and `netexec` cannot
  collect, so SharpHound on a domain host is the only collector. The
  repository therefore said two different things, and `ansible/` encoded
  neither.
- **`ms-DS-MachineAccountQuota` is 10**, the shipped default. Any of the
  population's users can create computer accounts, which is the usual first
  step of RBCD and shadow-credential chains. That does not depend on the `rbcd`
  switch, so a plain run did not remove it.
- **Print Spooler runs on both DCs.** A DC is trusted for unconstrained
  delegation by default, so any domain user can coerce a DC's machine account
  to authenticate somewhere. With signing enforced and no AD CS there is no
  complete relay path today. It completes one as soon as `ucd` is on or
  signing is lifted, outside the switch model.
- **`dsHeuristics` is unset.** Directory Service events 3051 and 3054 at each
  boot say that per-attribute authorization on LDAP add and the implicit-owner
  restrictions are not enforced.

ADR-0083 promised that a plain `lab-domain.yml` followed by `verify.yml` is the
negative test: every weakness off, and no path to Domain Admin. MAQ and
Spooler sat outside that test. LDAP signing was on when ADR-0029 said it should
be off.

ADR-0083's reopen clause says a weakness that turns off a shipped default is a
change to ADR-0029 first. This ADR is that change for LDAP signing. MAQ and
Spooler go the other way: they are shipped defaults that a plain run now turns
off.

## Decision

**Three new switches, in ADR-0083's model.** Each is one role and one tag with
`weakness_<name>_state`. The default is `absent`, both directions are
idempotent, and `verify.yml` asserts the state the toggle names.

| Tag | `present` | `absent` (a plain run) | Where |
| --- | --- | --- | --- |
| `unsigned_ldap` | `LdapServerEnforceIntegrity` = 0: unsigned simple and SASL binds are accepted | the value is removed, which is Server 2025's default of enforced | both DCs |
| `maq` | `ms-DS-MachineAccountQuota` = 10, the shipped default | 0: only delegated admins create computer accounts | the domain head |
| `spooler` | Print Spooler Automatic and running, as shipped | Disabled and stopped | both DCs |

- **LDAP signing becomes off on demand, not off for good.** This amends
  ADR-0029's "removed once, recorded". Signing off permanently would make
  NTLM relay to LDAP available in every plain run. It would then be part of
  every BloodHound graph and every "no path" claim, and it would no longer be
  an exercise someone chose to run. As a switch, the relay exercise still
  exists, and the removal is recorded each time someone enables it.
  `LDAPServerIntegrity` stays at its shipped 1. The role refuses to enable the
  switch if that value is anything else, because 2 would require signing
  whatever the enforcement setting says.
- **MAQ and Spooler are switches whose `absent` hardens.** ADR-0083's six
  *add* a primitive when present. These two *keep* a shipped primitive when
  present. The direction is the same: `present` means the weakness exists. It
  costs nothing the lab uses. Every join runs as `AD\Administrator`, and
  `rbcd` brings its own controlled principal, `svc-rbcd`, rather than one a
  user creates. The members' Spooler is not touched. Coercing a member server
  is not a path to Tier 0, and §0's list does not cover it.
- **`dsHeuristics` stays as shipped.** It is a Server 2025 default that the lab
  keeps, like those in §0's list. Events 3051 and 3054 at boot are expected.
  `verify.yml` asserts the attribute is still unset, so a reflexive hardening
  shows up red. Hardening it would close owner-rights techniques the exercises
  may want later, and it is not on any path the switches open.

## Alternatives considered

- **Encode ADR-0029 as written, with signing off for good.** That is what the
  ADR says. It was rejected because it puts a relay primitive into the negative
  test.
- **Supersede ADR-0029 and keep signing enforced with no switch.** That is
  honest about the box, but it deletes the LDAP-relay exercise, which ADR-0029
  chose Server 2025 partly to teach.
- **Set MAQ to 0 and disable Spooler permanently.** That gives the same plain
  run, but an RBCD-by-new-computer or coercion exercise would then need a
  change to this ADR instead of a tag.
- **Declare MAQ and Spooler as shipped defaults in §0's list.** That keeps "as
  Windows ships", but then ADR-0083's negative test is only true if the graph
  happens to have no path. It would not be true by construction.

## Consequences

- **Unlike ADR-0083's six, these change the live DCs on the first plain run.**
  `--tags maq,spooler` with the defaults sets MAQ to 0 on the domain and stops
  and disables Spooler on `bahamut` and `leviathan`. `unsigned_ldap` changes
  nothing there, because it is already absent.
- **The BloodHound runbook's Linux collectors work only while `unsigned_ldap`
  is present.** SharpHound stays the default collector, and its graph is the
  one the negative test reads.
- **`verify.yml` checks nine switches plus one kept default.** A plain run
  asserts all nine are absent and `dsHeuristics` is unset.
- **The registry value is the proof, not a bind.** `phoenix` has no
  `ldap-utils` or GSSAPI tooling. An unsigned bind test from it would need
  that tooling added through the repository first. Directory Service event
  2888 on the DCs is the observable for the purple-team loop.
- **Reopened by:** an exercise that needs Spooler on a member server turned
  off, or a `dsHeuristics` hardening. Either one is a new ADR.
