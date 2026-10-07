# ADR-0077: Configure the lab domain with Ansible from phoenix

**Status:** Accepted · 2026-10 · amends decision 6 of
[ADR-0074](0074-build-the-lab-templates-with-packer-from-phoenix.md) (the way
in is now part of the image) and the "join none of the estate's loops"
consequence of
[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)

> [!NOTE]
> "Host keys are not pinned" (decision 2, below) is amended by
> [ADR-0085](0085-check-the-lab-domains-host-keys-against-keys-read-through-the-guest-agent.md),
> 2026-10. Host keys are checked, against keys `scripts/lab-known-hosts.sh`
> reads from each guest through the Proxmox guest agent after each rebuild.
> The Windows build's WinRM, which "WinRM is rejected" calls HTTP Basic, is
> HTTPS scoped to `phoenix` since
> [#846](https://github.com/Gerrrt/HomeLab/issues/846); the rejection stands.
> The text here is left as written, per ADR-0001.

## Context

[`build-the-lab-domain.md`](../runbooks/build-the-lab-domain.md) builds
ADR-0029's six guests by hand, in eleven sections and about a day. It has to be
repeated after each 180-day licence runs out on the two evaluation DCs
(ADR-0029's 2026-10-01 note), and after any snapshot revert that loses
something. [#440](https://github.com/Gerrrt/HomeLab/issues/440) makes the
templates, [#445](https://github.com/Gerrrt/HomeLab/issues/445)'s `tofu/`
makes machines from them
([ADR-0076](0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md)),
and [#448](https://github.com/Gerrrt/HomeLab/issues/448) asks for the
configuration to be code too.

Four facts constrain how.

- **The estate has already turned Ansible down once, for something else.**
  [ADR-0021](0021-converge-on-a-timer-instead-of-deploying-over-ssh.md)
  rejected `ansible-pull` as "a wrapper around `make up`". In
  [ADR-0043](0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md),
  a `phoenix` that pushed compose stacks would be "the `ansible-pull`
  rejection re-litigated with a different tool".
- **A clone has no way in.** #448 assumed #440's Autounattend enables OpenSSH.
  It does not. `bootstrap.ps1` opens WinRM for the build, and
  `SetupComplete.cmd` closes it on every clone, deliberately leaving the
  choice of a way in to #448.
- **`phoenix` holds no age key** (ADR-0043), so no `secrets/*.sops.yaml` can be
  what it reads.
- **The lab is meant to be broken.** Its weaknesses (LLMNR, NetBIOS over
  TCP/IP, IPv6, WPAD, the shipped `GlobalQueryBlockList`) are the exercises
  ADR-0014 built the segment for. Generic Windows configuration roles harden
  exactly these.

## Decision

**1. Ansible applies the lab domain's configuration from `phoenix`, on demand,
and does nothing else.** It lives in a top-level `ansible/`, beside `packer/`
and for the same reason ADR-0074 gave: it is not a stack. Its inventory is
ADR-0029's six guests and no other host.

This does not reopen ADR-0021. That ADR decided how a host *that runs a stack*
converges. These guests run no stack, have no `make up`, and are not on a
timer. ADR-0043 already placed this kind of work on `phoenix`: the toolchain
builds machines.

Nothing pulls and nothing enforces. A lab that is broken on purpose and
reverted on purpose should stay broken until someone re-applies, and a
continuous enforcer would fight the range.

**2. The way in is OpenSSH, key-only, built into the Windows templates and
admitting `phoenix` alone.** `packer/windows/scripts/openssh.ps1` runs during
the build. It installs the server (already present on Server 2025; a
capability on Windows 11) and leaves it disabled and never started. It also:

- writes an `sshd_config` with password logins off;
- puts `phoenix`'s public key in `administrators_authorized_keys`;
- sets PowerShell as the login shell;
- replaces the capability's any-address firewall rule with one that admits
  `10.0.30.70` only.

`SetupComplete.cmd` starts `sshd` on each clone. That first start generates the
clone's own host keys, and `sysprep.ps1` deletes any that exist before
generalising.

This amends ADR-0074 decision 6. A template is still an operating system and
nothing more, except for the way in: a clone that nothing can reach cannot be
configured by anything.

WinRM is rejected:

- HTTP Basic is the build shortcut ADR-0074 removes from every clone.
- HTTPS needs a certificate on each guest before anything can connect to
  install one.
- NTLM over HTTP is one of the protocols this segment exists to have attacked.

SSH also reaches the Linux guests that #421 adds later, through the same
transport.

Host keys are not pinned (`host_key_checking = false`). Every rebuild replaces
them, and a rebuild is the normal case here.

**3. Secrets come from `~/.config/proxmox/phoenix.env`**, beside the token and
the build password (ADR-0074 decision 4). There are two:

- `LAB_ADMIN_PASSWORD`: the Administrator password, which the `base` role
  rotates the build password to. It is also AD\Administrator, because
  `Install-ADDSForest` makes `bahamut`'s local Administrator the domain's.
- `LAB_DSRM_PASSWORD`: the directory services restore mode password.

The playbooks read them with `lookup('env')`, and every task that uses one is
`no_log`.

**4. The playbooks encode ADR-0029; they do not re-decide it.** The roles are
the runbook's sections in the runbook's order:

| Role | Does |
| --- | --- |
| `base` | Name, DC static addresses, resolvers, build password rotated |
| `dc_forest` | Forest, forwarder with root hints off, and the clock from `10.0.30.1`. It asserts the clock before anything joins |
| `dc_replica` | Second DC, left on NT5DS |
| `dc_resolvers` | Each DC resolves through its partner, then loopback |
| `member` | Joins |
| `exporter` | `windows_exporter` and its one firewall rule |
| `licence_clock` | The evaluation gauge, on the four servers only |

**No role hardens anything.** `ansible/verify.yml` asserts each item on
`build-the-lab-domain.md`'s "Do not harden this domain" list by name, along
with titan's unsigned SMB. A hardening role added by reflex therefore turns
`verify` red instead of passing quietly.

**5. Tags are stages.** The tags are `base`, `forest`, `replica`, `join`,
`exporter` and `licence`. One playbook serves a full rebuild and a one-stage
repair. [#449](https://github.com/Gerrrt/HomeLab/issues/449) adds the tiers,
users and deliberate weaknesses as further tags on the same playbook, and that
is where they belong. They are not in this ADR's roles.

**6. When the six come under `tofu/`, each one's MAC address is pinned there,
and `morpheus` holds a reservation for all six.** ADR-0076 decision 7 leaves
the six hand-managed and leaves bringing them in to #448. The guest module it
shipped takes no MAC yet, so adding one is part of that step. The four members
are on DHCP reservations already (ADR-0029). A rebuilt guest with a new MAC
would come up in the pool, where Ansible's inventory cannot find it.

The two DCs also get reservations, at their static addresses. A fresh clone
first boots on DHCP, and `base` then makes the same address static. That keeps
the inventory's addresses true from the first connection, without a discovery
step.

*2026-10-06:* implemented. The guest module takes `mac_address`, and
`tofu/guests.tf` pins the six to the MACs the hand-built ones had. Two more
are pinned the same way:

- each guest's SMBIOS UUID, because the endpoints' bought Windows 11 Pro
  activation is tied to the hardware ID;
- the servers' startup order.

*2026-10-07:* the startup order is not pinned by `tofu/` after all. Proxmox
wants `Sys.Modify` on `/` to set it, and `phoenix` holds nothing at `/`
(ADR-0043). The first rebuild's apply was refused with a 403 on it. The order
is recorded in `tofu/guests.tf` and set by root on `Saruman` after an apply;
the module ignores it.

The module also states q35, OVMF, the EFI disk and, on Windows, the TPM,
rather than leaving them to the provider's SeaBIOS default.

## Consequences

- **The runbook becomes the explanation, and the playbook becomes the
  procedure.** `build-the-lab-domain.md` keeps §0's decisions and the
  do-not-harden list, and its build sections become `ansible-playbook` calls.
- **The rebuild is the proof, and it waits for the six to be in `tofu/`.** The
  playbooks are proved idempotent against the hand-built six first: a second
  run reports nothing changed. #448 closes on `tofu destroy`, a rebuild, and
  `verify.yml` passing, because a first build only proves the playbooks ran
  once. Before that can run, the six have to be declared in `tofu/guests.tf`
  with pinned MACs (decision 6), and #440's first template build has to
  happen.
- **"The same tiers" in #448's verification means ADR-0029's machine tiers.**
  The DCs are Tier 0, the member servers Tier 1 and the endpoints Tier 2, and
  `verify.yml` asserts each guest's actual domain role against its inventory
  `lab_role`. The tier *accounts* and the GPO that keeps Tier 0 on the DCs
  belong to #449. They are not part of #448's rebuild proof, and #449 adds
  their own assertions when it adds them.
- **Every guest listens on 22**, scoped to `phoenix` and key-only. That is a
  new exposure on the segment, and `security.md` records it as a residual: on
  a segment built to hold attackers, someone who owns `phoenix` owns the lab
  domain. That was already true through the Proxmox token.
- **CI gains `ansible-lint`**, run by `scripts/lint.sh`, which includes
  `ansible-playbook`'s own syntax check. Like `packer validate`, it proves the
  tree parses. Only `phoenix` can prove it configures.
- **Three pins to keep:**
  - `ansible-core` in `ansible/requirements.txt`, bumped by Dependabot.
  - `ansible-lint` in `ansible/requirements-lint.txt`, bumped by Dependabot.
  - The collections in `ansible/requirements.yml`. These are a deliberate
    edit, like Packer's plugin pin.
- **The hand-built six need one manual step** before Ansible can reach them:
  `sshd` and the key, once each, by hand. The runbook records it. Every clone
  after them has both from the template.
