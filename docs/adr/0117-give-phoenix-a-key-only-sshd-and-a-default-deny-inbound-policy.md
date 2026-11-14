# ADR-0117: Give `phoenix` a key-only `sshd` and a default-deny inbound policy

**Status:** Accepted · 2026-11 · amends [ADR-0043](0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)

## Context

[ADR-0043](0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)
made `phoenix` the one machine whose purpose is to hold credentials for other
machines. It holds the Proxmox tokens for `Saruman` and `gandalf`, the
domain's passwords, `tofu/`'s state passphrase, and the only key that
ADR-0029's six accept for administration
([ADR-0077](0077-configure-the-lab-domain-with-ansible-from-phoenix.md)).
[`security.md`](../security.md) accepts the residual: whoever owns `phoenix`
owns the lab domain.

That acceptance assumes the way into `phoenix` is narrow, but nothing in the
repository says what it is. The runbook that built it,
[`build-the-jumpbox.md`](../runbooks/build-the-jumpbox.md), installs OpenSSH
and says nothing more. The six, which `phoenix` configures, are held to more
than that: `sshd` refuses passwords, and one rule admits `10.0.30.70` alone.
The audit of the host on 2026-11-13
([#1496](https://github.com/Gerrrt/HomeLab/issues/1496)) found what that gap
leaves in place:

- the Ubuntu installer's `PasswordAuthentication yes`, in
  `sshd_config.d/50-cloud-init.conf`;
- no host firewall;
- `sshd` answering every address that can route to it.

Those addresses are all of VLAN 30, all of Hicks
([`firewall-claims.yaml`](../firewall-claims.yaml): nothing blocks Hicks from
ImaginationLAN), and the tunnel's peers. A password guessed or reused from any
of those owns the lab domain. The key-only rule on the six then protects
nothing, because the key is on the machine the password opens.

Three things must still reach `phoenix`:

- **The operator,** from a Hicks workstation or through the tunnel. The
  Mac's `deploy-agent.sh` run and the CA copy in
  [`build-the-lab-templates.md`](../runbooks/build-the-lab-templates.md) both
  come from Hicks.
- **WireGuard's handshake,** from the internet through `morpheus`'s one
  `rdr` ([ADR-0042](0042-terminate-the-remote-path-on-the-lab-and-route-it.md)).
- **A Debian or Kali installer under construction,** fetching its preseed from
  Packer's HTTP server on `8800`, for the length of that build
  ([ADR-0090](0090-test-the-dotfiles-os-layers-on-on-demand-saruman-guests.md)).

Nothing on VLAN 30 needs to log in to `phoenix`. Its work all flows outward:
API calls to `8006`, SSH and WinRM to the guests it builds and configures,
and Alloy's push to `alexander`.

## Decision

**`sshd` on `phoenix` is key-only.** A drop-in,
`/etc/ssh/sshd_config.d/10-phoenix.conf`, sorts ahead of the installer's
`50-cloud-init.conf`. `sshd` keeps the first value it reads, so the drop-in
wins without the installer's file being edited. It sets:

- `PasswordAuthentication no` and `KbdInteractiveAuthentication no`;
- `PermitRootLogin no`;
- `X11Forwarding no`.

Every workstation that logs in has its key in `authorized_keys` before the
drop-in is applied. That ordering is the whole risk of the change, so the
runbook makes it a check rather than a reminder.

**Inbound is default-deny, with `ufw`.** `ufw` because
[`build-the-lab-templates.md`](../runbooks/build-the-lab-templates.md)
already opens `8800` with it. One tool, not two. The rules:

- `22/tcp` from Hicks, `10.0.50.0/24`;
- `22/tcp` arriving on `wg0` from the peers, `172.31.0.0/24`;
- the WireGuard listen port, `udp`, from anywhere. `morpheus` decides who
  reaches it, and the port number stays out of this repository;
- `8800/tcp` from `10.0.30.0/24`, added for a Debian or Kali build and
  deleted after it, as that runbook already says;
- outbound allowed, as `ufw` defaults.

**Routing from the tunnel is left as ADR-0042 made it.** `ufw`'s forward
policy is `DROP`, so one route rule, `wg0` to `ens18`, carries the peers'
traffic as before, with replies admitted as established. It does not narrow
the destinations. ADR-0042 makes `morpheus` the control and its blocks the
attribution. A second filter on `phoenix` would stop that traffic before
`morpheus` could log it, and the remote-path runbook's negative tests would
then prove the wrong firewall. `ufw` does not touch `net.ipv4.ip_forward`, so
the systemd drop-in still scopes forwarding to the tunnel's lifetime.

**Nothing converges `phoenix`, so this is applied by hand** from
[`build-the-jumpbox.md`](../runbooks/build-the-jumpbox.md) §6a, and a rebuild
applies it in the same place. The runbook ends with the checks that prove
each rule from the side it applies to.

This amends ADR-0043, which placed `phoenix` and named what it holds but not
how it is reached.

## Alternatives considered

- **`nftables` directly,** with a ruleset file in the repository. It is more
  exact, and [ADR-0093](0093-run-openvas-on-garuda-on-demand-scoped-to-the-domain-by-nftables.md)
  uses it on `garuda`. Declined because the template runbook's `ufw` step
  would then be a second tool on the same host. The policy here is a short
  allow-list, which `ufw` states in five lines.
- **Admit `22` from VLAN 30 as well.** It is the segment `phoenix` is on, and
  the rule would be shorter. Declined: nothing on it needs to log in. VLAN 30
  includes the lab domain and the guests `phoenix` builds, which are the
  machines least trusted to reach the one that owns them.
- **Narrow the routed traffic on `phoenix` to `10.0.30.0/24`.** Declined
  for the reason above: it moves ADR-0042's control and its evidence off
  `morpheus`.
- **Leave passwords on and rely on the firewall.** Declined. Hicks is a
  whole segment of household machines, and the firewall admits all of it.

## Consequences

- **A lost key now locks a workstation out,** where before it fell back to a
  password. The recovery path is `phoenix`'s console in `Saruman`'s web UI,
  reached from Hicks, where a local login still takes a password.
- **A rebuilt `phoenix` is closed before its first login from anywhere but
  Hicks and the tunnel.** `deploy-agent.sh` from the Mac is unaffected.
- **Peers keep their access to `phoenix`'s `22`,** as before. A peer is a
  device with a key and no second factor (`security.md`), and `sshd` asks for
  a second key.
- **`8800` is a step again, not a no-op.** The template runbook's "if `ufw` is
  active" becomes unconditional.
- **Reopened by:**
  - anything on VLAN 30 that needs to reach `phoenix` inbound;
  - `phoenix` gaining a converger, which would carry this config instead of
    the runbook;
  - Hicks being narrowed by `firewall-claims.yaml`, which would let the
    `22` rule name workstations instead of the segment.
