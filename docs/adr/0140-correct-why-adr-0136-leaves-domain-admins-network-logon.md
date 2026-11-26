# ADR-0140: Correct why ADR-0136 leaves Domain Admins network logon

**Status:** Accepted · 2026-11 · amends
[ADR-0136](0136-deny-the-domains-own-admins-the-console-on-members.md)

## Context

[ADR-0136](0136-deny-the-domains-own-admins-the-console-on-members.md)
refuses Domain and Enterprise Admins the console and RDP on members, and
leaves them network logon. It gives one reason for the second half: Ansible
on `phoenix` connects to every guest as `AD\Administrator` over SSH, a key
logon is a network logon, and so denying it would lock the pipeline out.

That premise is wrong for the members. Ansible's `ansible_user` is
`Administrator` (`group_vars/all.yaml`, ADR-0077), and `phoenix`'s key is in
each guest's `administrators_authorized_keys`. On a DC that name is the
domain's Administrator, because `Install-ADDSForest` makes `bahamut`'s
local Administrator the domain's. On a member it is the member's own local
Administrator. Read on `titan` on 2026-11-26: `whoami` over that SSH path
printed `titan\administrator`. The read-only audit of `ramuh` (#1763) found
the same in `ramuh`'s Security log: `RAMUH\Administrator` for each of
`phoenix`'s logons on 2026-11-16.

Nothing else in the repository logs on to a member as a domain admin.
`roles/member` passes the domain's Administrator to the domain join,
but that credential is checked by a DC, and the join runs before `roles/tiers`
moves the computer into `Servers` or `Workstations`, where the GPO is linked.
No role reaches a member over SMB, WinRM or `Invoke-Command`.

## Decision

**ADR-0136's rights are unchanged.** Domain and Enterprise Admins are refused
the console and RDP on members, and keep network logon, as `roles/gpos`
applies and `verify.yml` asserts.

**Its reason for keeping network logon is withdrawn.** The pipeline does not
need it. Domain Admins keep network logon on members because ADR-0136 left
it, not because anything here depends on it, and the residual ADR-0136 names
(a Tier 0 credential arriving at a member over SMB, WMI or SSH) has no
pipeline cost to close.

**Whether to close it is a separate decision, not taken here.** It has one
real cost: a network deny on `titan` also refuses a relayed Domain Admin.
The relay exercise ADR-0083's loop points at would then end in a 4625 rather
than a session. That is arguably the tiering working, but it changes what an
exercise against `titan` shows, so it is decided on its own, as a new ADR.

## Consequences

- The runbook's §5, `roles/gpos`'s comment and `verify.yml`'s comment stop
  saying that Ansible reaches the members as `AD\Administrator`.
- ADR-0136's alternative "give Ansible its own Tier 1 account" was costed as
  reworking the access path. On the members there is nothing to rework.
- The text of ADR-0136 is left as written, per ADR-0001 and ADR-0115, with a
  note pointing here.
