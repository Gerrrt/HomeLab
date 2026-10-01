# ADR-0071: Build the lab templates with Packer from phoenix

**Status:** Accepted · 2026-10

## Context

[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
puts the four lab servers on 180-day Windows Server 2025 evaluation licences,
and `LabWindowsEvaluationExpiring` fires thirty days before one lapses. When it
fires, the only answer today is
[`build-the-lab-domain.md`](../runbooks/build-the-lab-domain.md) §1–§4 by hand,
which is about a day of clicking through six Windows installers.
[#440](https://github.com/Gerrrt/HomeLab/issues/440) asks for that answer to
be a command.

[ADR-0043](0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)
built `phoenix` for exactly this. It holds a Proxmox token, `phoenix@pve!builder`,
with the `PhoenixBuilder` role. It is admitted to `Saruman` on 8006 and nothing
else. It left two things for the first toolchain issue to settle:

- where the token lives in encrypted form, and
- which privileges the role is missing.

Four facts constrain the design.

- **The repository has no infrastructure-as-code tree.** Everything under
  `stacks/` is a compose stack, and `scripts/stacks.sh` fails on a directory
  there with no `compose.yaml`.
- **`phoenix` holds no age key.** ADR-0043 part 2 is explicit about this. A
  `secrets/*.sops.yaml` file it has to read is a file it cannot decrypt.
- **The role does not reach the SSD pool.** Every lab guest's disk is on
  `large_data`, the pool that #527's measurements moved them to. The role is
  granted on `/storage/local` and `/storage/local-lvm` only.
- **Clones of one Windows image share a machine SID**, and the domain has two
  controllers, `bahamut` and `leviathan`. A member whose SID matches a DC's
  cannot join. The issue proposed rebuilding and renaming the template as the
  fix. That does not work: every clone of the rebuilt template still shares the
  rebuilt template's SID.

## Decision

**1. Packer lives in a top-level `packer/`, not under `stacks/`.** It is not a
stack: nothing in it runs as a container, and `make up` never touches it. It
holds one source per operating system:

- Ubuntu Server 26.04 (autoinstall on a `cidata` disc, the `nocloud` datasource)
- Kali (Debian preseed)
- Windows 11 Pro (Autounattend)
- Windows Server 2025 evaluation (Autounattend)

The answer files reach the installer on a generated CD, not over Packer's HTTP
server. That way nothing needs to listen on `phoenix`, and nothing on VLAN 30
needs to reach it. **Kali is the one exception.** Debian's installer reads a
preseed from its own medium or from a URL, never from a second disc, so Kali's
build serves its preseed over HTTP on one fixed port. The runbook admits that
port only for the length of that build.

**2. Templates get fixed VMIDs in the 900s, and a rebuild replaces in place.**

| VMID | Template | Built |
| ---- | -------- | ----- |
| 901 | `tpl-ubuntu-2604` | on `Saruman` |
| 902 | `tpl-kali` | not yet: its consumer, [#421](https://github.com/Gerrrt/HomeLab/issues/421)'s attack VM, lives on `ifrit`, which is not bought, and a template belongs to one node |
| 911 | `tpl-win11-pro` | on `Saruman` |
| 912 | `tpl-ws2025-eval` | on `Saruman` |

Guests keep the "VMID is the last octet" rule. The 900s hold no address, which
is the point. `packer build -force` destroys and recreates the template at the
same VMID. That is only safe if no linked clone hangs off it, so **guests are
full clones**, and the OpenTofu work in
[#445](https://github.com/Gerrrt/HomeLab/issues/445) inherits that constraint.

**3. Every Windows template is generalised by sysprep as its last step.**
`sysprep /generalize /oobe /shutdown` gives each clone a fresh SID at first
boot, and that is what the two-DC domain needs. Rebuilding from Packer is the
answer to licence expiry, not to the SID problem. The two were conflated in the
issue.

**4. The credential stays in `~/.config/proxmox/phoenix.env`, and this is now
the decision, not a deferral.** The file is mode 600 and outside git. Packer's
variables default to the file's own names (`PROXMOX_URL`, `PROXMOX_TOKEN_ID`,
`PROXMOX_TOKEN_SECRET`), so the file written in
[`build-the-jumpbox.md`](../runbooks/build-the-jumpbox.md) §4 is read as it
stands. The Windows build password is `PKR_VAR_build_password` in the same
file. It does more than drive the build: it is also a clone's Administrator
password at first boot, because an unattended OOBE has to set one. It stays
in force until whatever converges the guest rotates it
([#448](https://github.com/Gerrrt/HomeLab/issues/448)), and that is the reason
it lives beside the token and nowhere else.

The encrypted-in-repo form ADR-0043 anticipated is rejected, because it needs
an age key on `phoenix`, and ADR-0043 rules that out for reasons that still
hold.

**5. `PhoenixBuilder` gains what the build needs, on paths, never at `/`.** The
first additions are the role on `/storage/large_data`, and
`VM.GuestAgent.Audit`, which Proxmox VE 9 requires before Packer can ask the
guest agent for an address. Anything else the first build finds missing is added to the role and recorded in
[`build-the-lab-templates.md`](../runbooks/build-the-lab-templates.md), which
is ADR-0043's rule applied.

**6. A template is an operating system and nothing more.** The template holds:

- the VirtIO drivers and `qemu-guest-agent`
- `phoenix`'s SSH key for Linux
- cloud-init for Linux

Domain configuration stays out:

- the licence-gauge scheduled task
- the `role` label that `LabWindowsEvaluationExpiring` selects on
- static addresses, DNS, joining

All of that belongs to the guest, not the image. It goes to
[#448](https://github.com/Gerrrt/HomeLab/issues/448). The unattend files also
leave LLMNR, NetBIOS, IPv6 and WPAD alone, per ADR-0029.

## Consequences

- **The answer to `LabWindowsEvaluationExpiring` is a command**:
  `packer build -force -only=…` for the template, then a new clone. Rebuilding
  the guest itself still means re-promoting or re-joining it, so this makes the
  rebuild cheaper but not free.
- **CI gains a linter it can run without Proxmox.** `packer fmt -check` and
  `packer validate -syntax-only` run in `scripts/lint.sh` from an image pinned
  in `stacks/observability/compose.yaml`, like actionlint. A real build can only
  be proved on `phoenix`, and the runbook records the proof.
- **Kali's source is checked but unproven** until `ifrit` exists. A follow-up
  issue builds it there.
- **Full clones cost disk.** On `large_data` that means about 60–80 GiB per
  Windows guest, the same as the hand-built guests use today.
- **The token's scope grows by one storage path**, and each later addition goes
  in the runbook. ADR-0043's last consequence anticipated exactly this.
