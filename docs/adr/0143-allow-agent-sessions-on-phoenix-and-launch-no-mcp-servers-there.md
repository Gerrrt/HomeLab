# ADR-0143: Allow agent sessions on `phoenix`, and launch no MCP servers there

**Status:** Accepted · 2026-11

## Context

The audit of `phoenix` on 2026-11-13 found a Claude Code agent running on it,
started from the Mac's desktop app over SSH, and two MCP servers that the
session started as local processes: `@modelcontextprotocol/server-pdf`, from
a desktop plugin, and `actual-mcp`, from the Mac's own MCP configuration.
`npx` fetched both at their newest version on the day, unpinned, and they ran
as the operator, who can read `phoenix.env` and has passwordless `sudo` (§6
of [`build-the-jumpbox.md`](../runbooks/build-the-jumpbox.md)). The 2026-11-27
recheck found them still running. `actual-mcp` had no server address or
credential here, so it reached nothing, but its code still ran.

[`security.md`](../security.md) already prices owning `phoenix` as owning the
lab domain. A package that `npx` resolves at launch is code from outside the
repository that runs with that reach, and nothing pins or reviews it.

[ADR-0123](0123-keep-agent-sessions-on-trinity.md) took the same question for
`trinity` and kept Claude Code there, because sessions are how the operator
inspects and maintains the host. The same is true here: the audits of
`phoenix`, ADR-0135's change and this decision were all prepared from an
agent session on it. Nothing in the repository mentioned agents on `phoenix`
until now.

## Decision

**Agent sessions on `phoenix` are accepted** for the work the host exists
for: reading its state, running the toolchain and the repository's checks,
and preparing changes. They are subject to the rules that already bind the
host. `phoenix` has no GitHub credential (the audit's F3), so a session's
change leaves as a patch that the operator pushes from the Mac. Fixes to
anything the repository deploys go through the repository.

**No MCP server is launched on `phoenix`.** A Claude Code managed-settings
file, owned by root, enforces it:

```json
{
  "allowManagedMcpServersOnly": true,
  "allowedMcpServers": []
}
```

at `/etc/claude-code/managed-settings.json`. An empty allowlist that only
managed settings can extend refuses every MCP server that a plugin, the
user's configuration or a project's `.mcp.json` names, whatever it is called
and however it is started. The operator cannot widen it without `sudo`, and
`sudo` already owns the host. `build-the-jumpbox.md` §6a writes it.

Connectors that the desktop app delivers from claude.ai are not covered by
that file. Claude Code's documentation says they arrive in-process and are
governed from the claude.ai organisation's settings. They run no package on
`phoenix`, so this decision does not need to restrict them.

## Alternatives considered

- **Move agent sessions off `phoenix`.** Declined. The toolchain, the state
  and the env files are here, so the session would SSH in to do the same work
  with the same reach. That adds a hop and no boundary.
- **Pin the MCP packages and accept them.** Declined. A pinned package still
  runs third-party code as a user who owns the lab domain, and neither server
  does anything the host's work needs.
- **Deny the two servers by name.** Declined. Claude Code's documentation
  says a name is not a security control, because any server can be given any
  name. The empty allowlist refuses by default.
- **Turn the plugins and server off on the Mac only.** Declined as the only
  control. It is a setting on another host, and the next plugin brings its
  own server. Turning them off on the Mac is still worth doing, so that the
  refusals do not clutter every session here.

## Consequences

- **A session on `phoenix` has no local MCP tools.** The pdf viewer and the
  budget tools are unavailable here. Both belong to other hosts' work.
- **A later audit reads the agent on `phoenix` as this decision, not as a
  finding,** and checks that the managed file is in place and that no MCP
  server process runs.
- **Reopened by:**
  - work on `phoenix` that needs an MCP server. That is a new ADR naming the
    server, its pinned version and what it can reach;
  - Claude Code changing how managed settings bind remote sessions.
