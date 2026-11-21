# ADR-0123: Keep agent sessions on `trinity`

**Status:** Accepted · 2026-11

## Context

`trinity` holds the sensitive tier: the household's photographs, documents,
budget and vault, and the tier's age key in the operator's home directory.
The operator account is in `sudo`, `docker` and `lxd`, so anything that runs
as that account can reach root and every secret on the host.

The audit of 2026-11-13 found `trinity` also used as a development host: 41
worktrees in the deployment checkout, Go and npm caches, two upstream forks
and their toolchains, language runtimes under `mise`, and Claude Code sessions
working in the checkout. Third-party code and agents ran as the user holding
the key. The repository said nothing about it either way.

`fenrir` met the same finding the same week and was cleared to an appliance,
Claude Code included (`security.md`, the sensor row).

## Decision

On 2026-11-21 the development tooling left `trinity`: the worktrees, `~/go`,
`~/.npm`, `~/code/upstream`, the `golang` package, the `mise` languages and the
development caches. The operator's shell (the dotfiles and their tools) stays.

**Claude Code stays.** Sessions on `trinity` are how the operator inspects and
maintains the host: reading its state, running the repository's checks, and
preparing pull requests from a scratch clone. That is accepted with its cost.

- Sessions work in a scratch clone for anything they change. The deployment
  checkout is converge's, and changes reach it only through `main`.
- Language toolchains and upstream forks do not return. Lint and validation
  run in the repository's pinned containers, which `homelab-prune-images`
  clears weekly when unused.
- A later audit reads Claude Code on `trinity` as this decision, not as a
  finding.

## Consequences

- **An agent session runs as the account that holds the age key and the
  `docker` group.** A compromised session, or a session that does the wrong
  thing, can read every secret on the tier and reach root. The mitigation is
  the operator watching what each session does and approving its actions; no
  control on the host separates the two.
- The agent's own dependencies (the Claude Code binary and its updates) are a
  supply chain into the sensitive tier that `compose.yaml` does not pin.
- Moving agent work to `prometheus` and reaching `trinity` only by SSH would
  remove both costs, and is the change to make if either becomes unacceptable.
  This ADR would then be superseded.
- `fenrir` stays an appliance. The difference is that `trinity` is maintained
  interactively by the operator, and `fenrir` is not.
