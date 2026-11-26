# ADR-0139: Keep the TrueNAS MCP server's API key on `smaug`, and leave the NUT password that reached a transcript as it is

**Status:** Accepted · 2026-11 · amends
[ADR-0138](0138-keep-gerrrt-as-smaugs-administrator-account.md), whose last
consequence said the `ClaudeCode2` key was to be revoked and whose second
said a value that reaches a transcript is rotated

## Context

The read-only audit of `smaug` on 2026-11-13 found an API key, `ClaudeCode2`,
on `truenas_admin`: created 2026-09-29, with no expiry, and named in no
document. ADR-0138, written when its use was not known, said no session in
`gerrrt` used it and that it was to be revoked.

It has a use. The TrueNAS MCP server on the operator's Windows desktop holds
it and reaches `smaug`'s API with it. That is how the operator works with
`smaug` from the desktop. It is a separate path from `gerrrt`'s SSH and from
Claude Code running on `smaug`.

The same audit printed the NUT monitor password into a session's transcript,
by a `midclt` read on 2026-11-13. ADR-0138 made rotating any such value the
rule.

## Decision

**1. `ClaudeCode2` stays, for the TrueNAS MCP server, with no expiry.** It is
the second administrative path to `smaug` besides `gerrrt`, and the one that
bypasses sudo: the key alone acts as `truenas_admin`, with `FULL_ADMIN`.
What limits it is the source address. The API is served on the UI's port,
and [`build-the-nas.md`](../runbooks/build-the-nas.md) §6.13's allowlist
admits Hicks alone. That the allowlist refuses the API as well as the UI has
not been tested from another segment: the box admits its own address, so a
test from `smaug` proves nothing. A host on CasaBonita is the test.

**2. The NUT monitor password is not rotated.** It logs a subscriber in as
`secondary`, which reads the UPS's state and cannot command a shutdown, and
only the subscribing hosts reach the server's `3493`. ADR-0138's rule still
holds for every other value: a session reads secrets by existence and
permissions only, and a value that reaches a transcript is rotated unless a
decision like this one says otherwise.

## Consequences

- **Whoever holds `ClaudeCode2` holds `smaug`, from any Hicks address.** It
  lives on the Windows desktop, in the MCP server's configuration. A
  compromise of that desktop is a compromise of `smaug`, as it already was
  through `gerrrt`'s key and the `desktop-02` pass. Revoking the key under
  *Credentials → API Keys* ends the path at once. If the MCP server's use
  ends, revoke the key with it.
- **The NUT password stays in the transcript and in `erebor/apps`'s
  snapshots** until the transcript is deleted and the snapshots age out, and
  in the conversation's copy off the estate. The operator accepts that.
- **A future audit will find both and should not raise them again.** It
  should check that the key is still the only one, still on `truenas_admin`,
  and still used.
