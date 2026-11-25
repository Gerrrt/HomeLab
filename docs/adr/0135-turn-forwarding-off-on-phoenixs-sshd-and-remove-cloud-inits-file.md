# ADR-0135: Turn forwarding off on `phoenix`'s `sshd`, and remove cloud-init's file

**Status:** Accepted · 2026-11 · amends
[ADR-0117](0117-give-phoenix-a-key-only-sshd-and-a-default-deny-inbound-policy.md)

## Context

[ADR-0117](0117-give-phoenix-a-key-only-sshd-and-a-default-deny-inbound-policy.md)
made `phoenix`'s `sshd` key-only with a drop-in, `10-phoenix.conf`. That
drop-in sorts ahead of the installer's `50-cloud-init.conf`, and `sshd` keeps
the first value it reads. It turned off X11 forwarding and left every other
kind on, and it left cloud-init's file in place on purpose: "the drop-in wins
without the installer's file being edited".

The recheck of `phoenix` on 2026-11-25
([#1496](https://github.com/Gerrrt/HomeLab/issues/1496)'s audit) found both
choices still standing out:

- **`sshd -T` reads `allowtcpforwarding yes`, `allowagentforwarding yes` and
  `allowstreamlocalforwarding yes`.** A key that logs in to `phoenix` can
  therefore tunnel through it. `phoenix` is the one address on VLAN 30 with a
  path to `Saruman`'s and `gandalf`'s `8006`, so it can tunnel there too.
  [ADR-0043](0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)
  already says that "`ProxyJump` through `phoenix` is not a supported path",
  and that the day it becomes one, ADR-0002's decline of a bastion is
  reopened. Nothing in `sshd` enforces that sentence.
- **`50-cloud-init.conf` still reads `PasswordAuthentication yes`.** It has
  no effect, but it is the first thing an audit without `sudo` sees, and it
  has to be explained each time. [`build-the-sensor-guest.md`](../runbooks/build-the-sensor-guest.md)
  removes the same file on `fenrir` for the same reason. There, cloud-init
  wrote it once per instance and did not restore it across four reboots.

Nothing found on the host uses forwarding. Neither the repository nor the
operator's SSH config jumps through `phoenix`. The Claude Code remote session
on the host runs as a command over the SSH channel's stdio, next to
`sftp-server`, and opens no forwarded channel. No remote IDE server is
installed. Agent forwarding *into* `phoenix` would hand a workstation's agent
to the host whose compromise the residual in [`security.md`](../security.md)
already prices as owning the lab domain.

## Decision

**`10-phoenix.conf` gains `DisableForwarding yes`.** One line turns off TCP,
Unix-socket, agent and X11 forwarding at once. `AllowTcpForwarding no` alone
would leave Unix-socket forwarding on. `stacks/analyst/ssh/10-garuda.conf`
already does the same on `garuda`. `X11Forwarding no` stays in the file
because it is harmless, and keeping it means ADR-0117's check still reads
four `no` lines.

**cloud-init's `50-cloud-init.conf` is removed,** as `fenrir`'s runbook
removes it. The `10-` drop-in keeps doing the work. Removing the file stops a
misleading line from being read as the host's policy.

Both are applied by hand from
[`build-the-jumpbox.md`](../runbooks/build-the-jumpbox.md) §6a, because
nothing converges `phoenix`. The check reads `disableforwarding yes` from
`sshd -T` and expects one file in `sshd_config.d`. `sshd -T` still prints the
separate `allow*forwarding` options as `yes`, because `DisableForwarding`
overrides them without changing what they report.

This amends ADR-0117. Its key-only settings and its `ufw` policy are
unchanged.

## Alternatives considered

- **`AllowTcpForwarding no` and `AllowAgentForwarding no`.** This is what
  `heimdall`'s runbook writes. Declined because it leaves Unix-socket
  forwarding at its default of `yes`, and the garuda drop-in's comment
  records that gap.
- **Leave forwarding on and rely on ADR-0043's sentence.** Declined. A rule
  that only a document enforces is the gap ADR-0117 closed for passwords.
- **Edit `50-cloud-init.conf` to read `no`.** Declined. It keeps a second
  file that says the same thing, and the next cloud-init instance would
  rewrite it. Removing it matches `fenrir`.
- **Disable cloud-init on `phoenix`.** Out of scope. It would change how a
  rebuilt `phoenix` gets its first network and user, which build-the-jumpbox
  §2 relies on.

## Consequences

- **`ssh -J`, `-L`, `-D`, `-R` and `-A` through `phoenix` fail.** That was
  already the intended policy, and now it is enforced. A workstation that
  needs `Saruman`'s UI reaches it directly from Hicks, as before.
- **A tool that tunnels over SSH breaks on `phoenix`.** Remote IDEs such as
  VS Code Remote-SSH forward a port by default. The runbook's check opens a
  fresh remote session before the old one closes, so the change can be
  rolled back without the console.
- **The audit's low leftovers for `sshd` close** once it is applied.
- **Reopened by:**
  - anything that needs to tunnel through `phoenix`. That is also ADR-0043's
    bastion question;
  - a remote-development tool on `phoenix` that cannot run without
    forwarding.
