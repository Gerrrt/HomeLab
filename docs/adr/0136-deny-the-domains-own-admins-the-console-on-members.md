# ADR-0136: Deny the domain's own admins the console on members

**Status:** Accepted · 2026-11 · extends the tiering of
[`build-the-lab-domain.md`](../runbooks/build-the-lab-domain.md) §5, within
[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
and [ADR-0077](0077-configure-the-lab-domain-with-ansible-from-phoenix.md)

> [!NOTE]
> Amended by [ADR-0140](0140-correct-why-adr-0136-leaves-domain-admins-network-logon.md),
> which corrects the reason given below for leaving network logon. Ansible
> reaches a member as that member's local Administrator, not
> `AD\Administrator`, so the pipeline does not depend on it. The rights
> decided here are unchanged. The text here is left as written, per ADR-0001
> and ADR-0115.

## Context

§5 builds three tiers so that "a violation is an event": the GPO *Deny Tier 0
Logon on Members*, linked to `Servers` and `Workstations`, refuses interactive
and network logon to the group `Tier 0 Admins`, whose one member is
`t0-admin`.

A read-only audit of `titan` on 2026-11-13, re-checked on 2026-11-25, found
that the GPO names nothing else. `AD\Administrator` is in Domain, Enterprise
and Schema Admins and not in `Tier 0 Admins`, so it can log on to any member,
and it was logged on at `titan`'s console for the audit itself. `titan` is
the relay target. A Tier 0 credential in its LSASS is one Mimikatz run from
Enterprise Admin, and its logon raised no event, because nothing it did was
refused.

The obvious fix, denying Domain Admins every kind of logon on members, locks
out the pipeline. Ansible on `phoenix` connects to every guest as
`AD\Administrator` over SSH (ADR-0077 decision 2). A key logon through
Windows OpenSSH is an S4U logon of the network type, so it is governed by
`SeDenyNetworkLogonRight`, not by the interactive right.

## Decision

**Domain Admins and Enterprise Admins are refused the console and RDP on
members, and keep network logon.** The GPO's privilege rights become:

- `SeDenyInteractiveLogonRight`: Tier 0 Admins, Domain Admins, Enterprise
  Admins
- `SeDenyRemoteInteractiveLogonRight`: the same three. RDP is already off on
  all six, and this keeps it from becoming a way round.
- `SeDenyNetworkLogonRight`: Tier 0 Admins only, as before

`roles/gpos` fills the two new SIDs from the domain SID (RIDs 512 and 519) at
apply time, as it already does for Tier 0 Admins, and `verify.yml` asserts
the three lines. The DCs are untouched: the GPO is not linked to their OU.

**The console on a member belongs to its local `Administrator`**, whose
password `roles/base` sets from `LAB_ADMIN_PASSWORD`. On the two endpoints
there is also `labadmin`. An agent session or an audit on a member runs over
SSH from `phoenix`, or as the local account, never as a domain admin at the
console.

## Alternatives considered

- **Deny Domain Admins network logon as well, and give Ansible its own
  Tier 1 account.** The cleanest tiering, but it reworks ADR-0077's access
  path: a new account, a new key on six guests, and every role's
  connection. It can follow later as its own ADR. This change does not get in
  its way.
- **Accept the gap and record it.** It leaves the one credential that owns
  the forest free to land on the box built to be compromised, with no event
  when it does.
- **Add `AD\Administrator` to `Tier 0 Admins`.** That inherits the network
  deny, so the pipeline breaks for the same reason.

## Consequences

- **A domain admin at a member's console now fails with 4625**, which is the
  event the tiering exists to produce, and the logon never happens.
- **The pipeline is unchanged.** Ansible's SSH logon is a network logon. The
  first apply goes through `--check` and one member before the rest, because
  if this reasoning is wrong it locks `phoenix` out of the members. Recovery
  then is the local `Administrator` at the console, which this does not
  touch.
- **A network-logon Tier 0 credential is still possible on a member** (SMB,
  WMI, SSH as a domain admin). That is the residual the alternative above
  would close.
