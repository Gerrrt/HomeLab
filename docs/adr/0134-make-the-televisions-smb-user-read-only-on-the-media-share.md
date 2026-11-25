# ADR-0134: Make the televisions' SMB user read-only on the media share

**Status:** Accepted · 2026-11 · amends
[ADR-0051](0051-let-hicks-workstations-mount-the-media-share-as-a-user-of-their-own.md),
deciding the change its third decision deferred

## Context

The `media` share on `erebor/media` was created from TrueNAS's SMB preset,
whose ACL grants `builtin_users` Modify. Every SMB user joins that group when
it is created, so `bilbo`, the credential stored on the televisions, can
write, rename and delete the library
([`build-the-nas.md`](../runbooks/build-the-nas.md) §5).

ADR-0051 gave workstations their own user, `samwise`, so that the
credential typed on workstations is not the one living on televisions, and
the two can be revoked apart. It considered making `bilbo` read-only and
deferred it, because "it means changing the share's ACL, which is a separate
change with its own test".

A read-only audit of `smaug` on 2026-11-13 read the ACL as five entries:
`owner@` and `group@` (root), `builtin_users` Modify,
`builtin_administrators` Full Control, and `everyone@` Basic Read with
inheritance. `builtin_users` held `bilbo`, `samwise` and the local admin
account.

The televisions run firmware nobody can audit, with a permanent internet
connection and no patch guarantee: `network.md` gives CasaBonita a guest's
trust for that reason. A television never needs to write the library. It
plays through Jellyfin, or reads files over SMB. And `erebor/media` is not
snapshotted, so a delete or an encryption from a television is final.

## Decision

**`bilbo` reads the library and writes nothing.** The share's ACL loses the
preset's `builtin_users` Modify entry, gains a `samwise` user entry with
Modify and inheritance, and is applied recursively. `bilbo` keeps read access
through the existing `everyone@` Basic Read entry, the same entry Jellyfin
reads by as uid 65534. Nothing else changes: the users, the share, the `445`
pass and the services' read-only mounts.

**Write access to the library is granted to users by name, never to a group
every SMB user joins.** A future SMB user starts read-only.

[`build-the-nas.md`](../runbooks/build-the-nas.md) §5 is the procedure, with
the test ADR-0051 asked for: `bilbo` is refused a write and still reads,
`samwise` writes and deletes, and Jellyfin still plays.

## Alternatives considered

- **Leave it, and accept the residual.** Rejected: the cost of the change is
  one ACL edit, and the residual is the whole library on a device class the
  estate trusts least.
- **A read-only share for the televisions beside a writable one.** Two shares
  on one dataset, with `bilbo` on one and `samwise` on the other. It works,
  but the ACL already expresses the difference, and a second share is a
  second thing to keep in step.
- **Snapshot `erebor/media` instead.** It would undo a delete, but not keep
  one from happening, and the library's size makes it a capacity decision.
  ADR-0051 left it separate, and so does this one.

## Consequences

- **A compromised television can read the library and nothing more.** That
  was already true of what Jellyfin exposes. It is now true of SMB too.
- **The local admin account loses write through `builtin_users`** and keeps
  Full Control through `builtin_administrators`. Nothing in the estate writes
  the library as that account.
- **MakeMKV's rips are unaffected.** It writes `rips/` as 65534, its owner
  ([ADR-0114](0114-rip-discs-on-smaug-with-makemkv-started-only-to-rip.md)),
  and a person moves the result into `movies/` as `samwise`.
- **A recursive ACL apply rewrites every file's entries.** On a library of
  about 31 MiB it is instant. On a full one it takes longer, and is still
  one operation.
