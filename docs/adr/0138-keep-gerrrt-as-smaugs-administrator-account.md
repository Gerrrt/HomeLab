# ADR-0138: Keep `gerrrt` as `smaug`'s administrator account, with a checkout and no deploy path

**Status:** Accepted · 2026-11 · amends
[ADR-0045](0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md),
whose fourth decision opened SSH on `smaug` for `frodo` "and nothing else",
and whose context said the host has "no repository checkout"

> [!NOTE]
> **Two consequences below are amended, 2026-11-25.** `ClaudeCode2` has a
> use, the TrueNAS MCP server on the operator's Windows desktop, and stays.
> The NUT monitor password printed into a transcript on 2026-11-13 is not
> rotated. Both are
> [ADR-0139](0139-keep-the-mcp-servers-api-key-on-smaug.md)'s. The rest of
> this decision is unchanged.

## Context

ADR-0045 turned SSH on for one user, `frodo`, the backup pull's read-only
account, and recorded the host as having no checkout of this repository and
no key that opens anything. The documents kept saying so after both stopped
being true.

The read-only audit of `smaug` on 2026-11-13 found a second account that no
document named: `gerrrt`, uid `3004`, with TrueNAS's `FULL_ADMIN` role, sudo
for every command, `zsh`, a home at `/mnt/erebor/apps/home/gerrrt`, an SSH
key, and in that home a checkout of this repository, the operator's dotfiles
and Claude Code, which the audit itself ran in. It logged in by password as
well as by key. `network.md` and `security.md` have since recorded the half
of this the firewall sees: the operator decided on 2026-11-23 to keep
`desktop-02` → `10.0.40.30:22` as the path `smaug` is administered by, and
password login was cleared on 2026-11-24. What no document decided is the
account itself: whether an interactive administrator with a checkout belongs
on the appliance that holds the backup datastore.

The alternative is the shape ADR-0045 described: administer `smaug` from the
TrueNAS UI and its console shell as `truenas_admin`, carry nothing of this
repository on the box, and put every file the stack needs there through
[`smaug-fetch.sh`](../../scripts/smaug-fetch.sh), run on a workstation. That
works, and is what the runbooks still say. What it costs is that every audit,
every `midclt` read and every redeploy is done through the UI shell, by
pasting, from a machine that does not run the commands it prints. The
sessions of 2026-11-13 to 2026-11-25 did their reading, their patches and
the `smaug-fetch.sh` block for the redeploy from `gerrrt`, and none of it
needed to leave the box to be checked.

## Decision

**1. `gerrrt` stays, as `smaug`'s one interactive administrator.** It keeps
`FULL_ADMIN` and sudo for all commands. Sudo asks for the password every time:
no `NOPASSWD` entry, for any command. SSH is by key alone, and only from
`desktop-02`, by the host-scoped pass `network.md` records. `truenas_admin`
remains the UI's and the console's account, and is not used over SSH.

**2. The checkout is for reading, and for printing what the box is given. It
is never a deploy path.** Files reach `/mnt/erebor/apps/stack` only as
`smaug-fetch.sh` installs them: fetched from a commit on `origin/main` and
checked against its sha256 before they replace anything. The checkout may
generate that block, but only from a clean tree at `origin/main`, which is
what the script already refuses otherwise. Nothing is copied from the
checkout into the stack directory, and nothing the stack runs points into
the home.

**3. Nothing on `smaug` can push to this repository or decrypt its
secrets.** The checkout's push URL is SSH, and `gerrrt` holds no key GitHub
accepts. There is no `gh` and no token. A change found on the box leaves it
as a patch or a bundle and is pushed from a workstation, through review.
There is no `age` identity, so `secrets/*.sops.yaml` stay ciphertext here.
ADR-0045's property, that the host holds no key that opens a backup, is
unchanged.

**4. A Claude Code session on `smaug` runs as `gerrrt` and is held to the
same rules as the operator.** It reads with `midclt`, `zpool`, `zfs` and the
textfile metrics. It changes the box only when the operator asks it to, and
records what it changed through the repository the way a runbook step is
recorded. It cannot use the Docker socket or sudo without the operator.

## Consequences

- **`gerrrt` is root for anyone who has its key and its password.** Sudo for
  all commands means the key alone is not enough, and the key works only from
  `desktop-02`. That is the residual, and `security.md` carries it.
- **The home is on `erebor/apps`, so it is in that dataset's snapshots.** A
  session's transcript under `~/.claude` holds what the session read, kept
  for the snapshot task's two weeks after it is deleted. One read on
  2026-11-13 printed the NUT monitor password into a transcript. Sessions
  must read secrets by existence and permissions only, and a value that
  reaches a transcript is rotated. The backup pull is not affected: it reads
  only the subpaths its table names, and the home is not one of them.
- **The root-run scripts must stay owned by root.** On 2026-11-25 the
  redeploy block was first run as `gerrrt`, which left the stack directory's
  files owned by it until they were changed back. A `.sh` there that
  `gerrrt` owns can be edited into root's cron without sudo. The block is
  run as root, and an audit checks the owner.
- **The account must not outlive its use.** Turning `gerrrt` off is a UI
  change: clear its role and its sudo, remove its key, and delete the home.
  Nothing in the stack depends on it, and the pass on `morpheus` can go with
  it.
- **The API key the audit found, `ClaudeCode2` on `truenas_admin`, is not
  part of this decision.** No session in this account uses it. It is to be
  revoked.
