# ADR-0090: Test the dotfiles' OS layers on on-demand Saruman guests

**Status:** Accepted · 2026-10

> [!NOTE]
> 2026-10-09, phase 4: NixOS is not built with `nixos-rebuild build-image`
> in a `nixos/nix` container, as decision 2 says. `phoenix` runs no Docker,
> by design. Instead it is built the ISO way, like decision 2's first four
> layers: Packer boots the NixOS 26.05 minimal ISO, types phoenix's key and
> the fixed build address at its console shell, and runs `nixos-install`
> over SSH with a committed `configuration.nix` (`packer/nixos/`). That is a
> real install, and it adds no toolchain to `phoenix`. NixOS publishes no
> signature for its ISOs, so the pin is the SHA-256 that `channels.nixos.org`
> and `releases.nixos.org` both publish over HTTPS.
>
> 2026-10-09, phase 3: Alpine and Gentoo are built as decision 2 says.
> `scripts/import-cloud-template.sh` (root on `Saruman`) imports each
> project's signed cloud image, pinned by SHA-256, as a staging template, 917
> or 918. Packer's `proxmox-clone` builder then finishes it into 907 or 908.
>
> - **Build address.** The images carry no guest agent, so each build gives
>   its clone the fixed address `10.0.30.99`, and the two builds take turns.
> - **Gentoo's profile.** Gentoo publishes its cloud image only with the 23.0
>   systemd profile, so `dot-gentoo` tests dotfiles-Gentoo on systemd, not on
>   its OpenRC default.
> - **Staleness checks.** The pins are not yet checked for staleness the way
>   the toolchain pins are. That is still to do.
>
> The text here is left as written, per ADR-0001.

## Context

The [dotgibson dotfiles](https://github.com/dotgibson/dotfiles-core) have one
repository per operating system: Alpine, Arch, Debian, Fedora, Gentoo, NixOS,
openSUSE and Windows. Each repository's `bootstrap.sh` (`bootstrap.ps1` on
Windows) turns a fresh machine into a configured one. Their CI tests this in
containers, plus an advisory weekly real install. **No CI job runs a layer's
bootstrap on a booted machine.** Some things only show up there: services, a
real init system, a reboot between the two runs that a transactional edition
needs, and Windows at all, since nothing runs `install.ps1` end to end.

[#920](https://github.com/Gerrrt/HomeLab/issues/920) asks for one VM per
layer on `Saruman`. Its comment of 2026-10-06 settled four questions:

- **one VM per layer**, eight, with Debian running trixie;
- **standalone**, not lab-domain members;
- **a fresh install for every run**;
- **results read by hand** before any automation.

`Saruman` had 54.5 of 125.7 GiB free and about 630 GiB free on `large_data`
when measured. All eight fit at once, and they are not meant to run at once.

[ADR-0074](0074-build-the-lab-templates-with-packer-from-phoenix.md) builds
templates with Packer from installer ISOs, with the answer files on a
generated disc.
[ADR-0076](0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md)
clones guests from them with OpenTofu. Four of these seven Linux distributions
have an installer Packer can drive that way. **Three do not:**

- **Alpine's** `setup-alpine` is typed at a console.
- **Gentoo** has no installer. A stage3 is unpacked and the system is compiled
  by hand, which takes hours.
- **NixOS** is installed by evaluating a configuration, not by answering
  questions.

## Decision

**1. Eight guests, one per layer, cloned from eight templates.**

| Layer | Template | Built from | Guest | VMID, address | vCPU / RAM / disk | Secure Boot |
| --- | --- | --- | --- | --- | --- | --- |
| Debian | 903 `tpl-debian-13` | Debian 13 netinst, preseed | `dot-debian` | 191, `.91` | 2 / 4 GiB / 32 GiB | on |
| Fedora | 904 `tpl-fedora-server` | Fedora Server netinst, kickstart on an `OEMDRV` disc | `dot-fedora` | 192, `.92` | 2 / 4 GiB / 32 GiB | on |
| openSUSE | 905 `tpl-opensuse-tw` | Tumbleweed ISO, AutoYaST or Agama profile on a disc | `dot-opensuse` | 193, `.93` | 2 / 4 GiB / 32 GiB | on |
| Arch | 906 `tpl-arch` | archiso, its own cloud-init from a `CIDATA` disc | `dot-arch` | 194, `.94` | 2 / 4 GiB / 32 GiB | off |
| Alpine | 907 `tpl-alpine` | Alpine's official UEFI cloud image | `dot-alpine` | 195, `.95` | 1 / 1 GiB / 8 GiB | off |
| Gentoo | 908 `tpl-gentoo` | Gentoo's official cloud-init qcow2 | `dot-gentoo` | 196, `.96` | 4 / 8 GiB / 60 GiB | off |
| NixOS | 909 `tpl-nixos` | `nixos-rebuild build-image --image-variant proxmox` | `dot-nixos` | 197, `.97` | 2 / 4 GiB / 40 GiB | off |
| Windows | 911 `tpl-win11-pro`, the existing template | n/a | `dot-windows` | 198, `.98` | 4 / 8 GiB / 64 GiB | on, with a TPM |

- **Template IDs.** 903–909 fill the rest of ADR-0074's Linux run of the 900s.
- **Addresses.** `.91`–`.98` sit in `fenrir`'s decade. It is the one decade
  with eight free addresses, and every `.x0` is taken, as `diabolos` and
  `eden` already found. The VMID is 100 plus the last octet, as everywhere
  else. Each guest has a MAC pinned in `tofu/guests.tf` and a Kea reservation
  for it on `morpheus`.
- **Sizes** are #920's.
- **Secure Boot is off where the distribution ships no Microsoft-signed
  shim.** A Secure Boot refusal would test the firmware, not the dotfiles.

**2. An installer where there is one, and the publisher's image where there
is not.** Debian, Fedora, openSUSE and Arch are built the ADR-0074 way, from
their installer ISOs.

Alpine and Gentoo are imported from the official images their projects
publish. The SHA-256 of each image is pinned in this repository, checked on
import, and then provisioned into a template by Packer's `proxmox-clone`
builder, which adds the guest agent and clears per-machine state.

NixOS is built by NixOS's own image builder from a committed
`configuration.nix`.

Two things that look better each break something:

- Scripting a Gentoo install from a live ISO would cost hours per rebuild for
  no gain to the test, which starts after the install.
- Importing a cloud image for every distribution would test less of a "real
  install" than #920 asks, where an installer exists to drive.

**3. Debian joins Kali under ADR-0074's one exception.** Debian's installer
reads a preseed from its own medium or from a URL, never from a second disc.
So Debian's build serves its preseed over Packer's HTTP server on `phoenix`'s
port 8800, exactly as Kali's does, and the runbook admits that port for the
length of the build. The exception is now "the Debian installer", not "Kali".

Fedora reads a kickstart from a disc labelled `OEMDRV` with no boot argument,
so it keeps to the rule.

**4. Standalone guests in their own `dotfiles` pool.** They are not domain
members, take no Ansible role and get no lab-domain weakness.

- **Resolution.** They resolve at `10.0.30.1`.
- **Login.** The Linux guests' only login is cloud-init's `tester`, with
  `phoenix`'s key: the same name as the Windows guest's bootstrap user. Not
  the module's default `operator`, which Debian ships as a system group and
  Fedora as a system user, so cloud-init cannot create it.
- **Monitoring.** No Alloy, no scrape and no backup: each is rebuilt from its
  template, as `diabolos` is.
- **Tags.** Every guest is tagged `dotfiles` and
  [`on-demand`](0079-tag-on-demand-guests-and-leave-them-out-of-the-stopped-guest-alert.md),
  and none boots with the host.

**5. Every run starts from a `clean` snapshot taken while the guest is
stopped.** After a guest's first boot (cloud-init's user, keys and host keys
in place), it is shut down and snapshotted as `clean`. A run then goes:
rollback, start, bootstrap, read the result, shut down.

The snapshot is taken stopped because a live snapshot's fs-freeze has hung
guests on `Saruman` before. A stopped snapshot has no RAM to save either.
`PhoenixBuilder` already holds `VM.Snapshot` on `/vms`, so `phoenix` can roll
back without a new grant.

**6. The Windows guest is an unactivated clone of `tpl-win11-pro`.** The two
bought Windows 11 Pro licences belong to `carbuncle` and `siren`, keyed to
their SMBIOS UUIDs. `dot-windows` gets no pinned UUID and no key.

Unactivated Windows 11 refuses Personalization settings. A dotfiles step that
fails for that reason is a known limit of this test bed, not a dotfiles bug.

Its Administrator password is the template's build password, which `ansible/`
rotates on the domain's guests but which nothing rotates here. That is
acceptable because the clone's OpenSSH admits `phoenix` alone, key-only
(`packer/windows/scripts/openssh.ps1`). The bootstrap itself runs as a
standard local user, because scoop refuses an elevated shell.

**7. Built in phases, one PR each.**

1. Debian, Fedora and Windows, with this ADR, the module changes and the
   runbook.
2. openSUSE and Arch.
3. Alpine and Gentoo, with the image-import path.
4. NixOS.

Each phase is built, smoke-tested (`scripts/packer-smoke.sh`), applied,
snapshotted and run once before the next starts.

## Consequences

- **Every layer's bootstrap can be run on a real machine** with one rollback
  and one SSH session. Nothing does it automatically yet: #920 defers a make
  target that returns a verdict until the manual routine is boring.
- **Seven more installers or images to keep.** Each ISO goes on `smaug-iso`
  and into `scripts/collect-iso-store-state.sh`'s list from its publisher's
  signed hash. The two imported images get the same treatment in the import
  path, and are checked for staleness as the toolchain pins are. A point
  release is a new file name, never an overwrite.
- **The module's template list and disk floors grow with each phase**
  (`tofu/modules/guest/variables.tf`). Phase 2 adds a `secure_boot` input,
  since Arch, Alpine, Gentoo and NixOS boot without Secure Boot.
- **The Debian build needs `phoenix`'s port 8800 open for its length,** as
  Kali's will. It is the one listener a template build ever opens.
- **Upgrade testing is out of scope.** A kept guest that is upgraded release
  by release would test a different thing, and would need a second snapshot.
  It is added if it is ever wanted.
- **macOS and the two role layers are not here.** Apple's licence allows macOS
  guests only on Apple hardware. Offense belongs on `ifrit`'s Kali (#790) and
  Defense on `garuda`'s Kali Purple (#921).
