# packer

[![host: phoenix](https://img.shields.io/badge/host-phoenix-30363d?style=plastic)](../docs/network.md#imaginationlan--vlan-30--lab)
[![VLAN 30: ImaginationLAN](https://img.shields.io/badge/VLAN%2030-ImaginationLAN-2ea043?style=plastic)](../docs/network.md#imaginationlan--vlan-30--lab)
[![Packer](https://img.shields.io/badge/Packer-02A8EF?style=plastic&logo=packer&logoColor=white)](https://developer.hashicorp.com/packer)
[![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-E57000?style=plastic&logo=proxmox&logoColor=white)](https://www.proxmox.com/en/proxmox-virtual-environment)

The lab's VM templates, built from `phoenix` through `Saruman`'s API
([ADR-0074]). How to run them is [`build-the-lab-templates.md`][runbook]; this
page is the map.

| VMID | Template | Source | Installer driven by | Node, and status |
| --- | --- | --- | --- | --- |
| 901 | `tpl-ubuntu-2604` | `ubuntu.pkr.hcl` | autoinstall, `cidata` disc | `Saruman`, built and usable |
| 902 | `tpl-kali` | `kali.pkr.hcl` | Debian preseed, Packer HTTP | `ifrit`, waits for the host ([#790](https://github.com/Gerrrt/HomeLab/issues/790)) |
| 903 | `tpl-debian-13` | `debian.pkr.hcl` | Debian preseed, Packer HTTP | `Saruman`, built twice and smoke-tested, 2026-10-08 ([#920](https://github.com/Gerrrt/HomeLab/issues/920)) |
| 904 | `tpl-fedora-server` | `fedora.pkr.hcl` | Kickstart, `OEMDRV` disc | `Saruman`, built twice and smoke-tested, 2026-10-08 ([#920](https://github.com/Gerrrt/HomeLab/issues/920)) |
| 905 | `tpl-opensuse-tw` | `opensuse.pkr.hcl` | AutoYaST, Packer HTTP | `Saruman`, first build pending ([#920](https://github.com/Gerrrt/HomeLab/issues/920)) |
| 906 | `tpl-arch` | `arch.pkr.hcl` | the live ISO's cloud-init on `cidata`, then `arch/install.sh` over SSH | `Saruman`, first build pending ([#920](https://github.com/Gerrrt/HomeLab/issues/920)) |
| 911 | `tpl-win11-pro` | `windows.pkr.hcl` | Autounattend, `ANSWERS` disc | `Saruman`, built and smoke-tested (rebuilt 2026-10-07, #846); also the base for `dot-windows` |
| 912 | `tpl-ws2025-eval` | `windows.pkr.hcl` | Autounattend, `ANSWERS` disc | `Saruman`, built and smoke-tested (rebuilt 2026-10-07 with the `SetupComplete.cmd` fix, #846) |

```bash
set -a; . ~/.config/proxmox/phoenix.env; set +a
packer init packer/
packer build -force -only='windows.proxmox-iso.ws2025-eval' packer/
scripts/packer-smoke.sh 912
```

## What is here

- `versions.pkr.hcl`: the Proxmox plugin, pinned exactly.
- `variables.pkr.hcl`: node, storage, bridge and ISO names. The credential
  defaults read `phoenix.env`'s own variable names, so nothing is spelled
  twice. Nothing secret has a default.
- `ubuntu/user-data.pkrtpl`: autoinstall. The `packer` build user is
  key-only and deleted at the end of the build.
- `kali/preseed.cfg.pkrtpl`: the same shape for Debian's installer.
- `debian/preseed.cfg.pkrtpl`: Kali's preseed with Debian trixie's mirror,
  for the dotfiles-Debian VM ([ADR-0090]). Served over HTTP, as Kali's is.
- `fedora/ks.cfg.pkrtpl`: the kickstart for Fedora Server, on a disc
  labelled `OEMDRV`, which Anaconda reads with no boot argument.
- `opensuse/autoinst.xml.pkrtpl`: the AutoYaST profile for Tumbleweed's
  NET installer, served over Packer's HTTP server as Debian's preseed is. YaST
  cannot be pointed at a second CD reliably (`opensuse.pkr.hcl` says why).
- `arch/user-data.pkrtpl` and `arch/install.sh`: Arch has no installer to
  answer. The first lets Packer into the live ISO, and the second installs
  the disk over that session. Secure Boot is off for Arch, the one template
  so far without a Microsoft-signed shim.
- `windows/autounattend.xml.pkrtpl`: one file for both editions, rendered
  with the image name, the VirtIO driver folder and the product key.
- `windows/unattend-oobe.xml.pkrtpl`: the answer file a clone's OOBE reads
  after sysprep.
- `windows/scripts/bootstrap.ps1`: runs at the build's one autologon. It
  installs the guest tools first, because Packer finds the address through
  the agent, and opens WinRM second: HTTPS on 5986 with a self-signed
  certificate, admitting `phoenix` alone. The HTTP listener and Windows' own
  5985 rules that `Enable-PSRemoting` adds are removed
  ([#846](https://github.com/Gerrrt/HomeLab/issues/846)). Read through
  `templatefile()` for `phoenix`'s address, so it may not contain `${` or `%{`.
- `windows/scripts/openssh.ps1`: installs the OpenSSH server, disabled and
  key-only, with `phoenix`'s key and a firewall rule admitting `phoenix`
  alone. It is how [`ansible/`](../ansible/README.md) reaches a clone
  ([ADR-0077]).
- `windows/scripts/SetupComplete.cmd`: runs once on each clone, closes
  that WinRM again (listener, certificate, rule and service), and starts
  `sshd`, which generates the clone's own host keys.
- `windows/scripts/sysprep.ps1`: starts sysprep `/generalize /oobe
  /shutdown` as a one-off scheduled task as SYSTEM, and returns once it is
  running. Not over WinRM: generalising removes the network adapter, and
  Windows then kills whatever the dead session started, sysprep included.
  `SetupComplete.cmd` deletes the task on each clone.
- `windows/scripts/wait-for-sysprep.sh`: runs on `phoenix` (`shell-local`)
  and polls the API until the guest has powered itself off, which is sysprep
  saying it finished. The builder then converts it. Its shutdown of an
  already-stopped VM is a no-op that Proxmox ends `OK`.

## Rules this tree keeps

- **Full clones only.** `-force` rebuilds a template at the same VMID, which a
  linked clone would block.
- **A template is an OS, not a guest.** No address, no name, no domain join,
  no licence gauge. Those are [`ansible/`](../ansible/README.md)'s ([#448]),
  and ADR-0029 says what they are. The one exception is the way in: `sshd`
  and `phoenix`'s key are in the image, because a clone with no way in cannot
  be configured by anything.
- **LLMNR, NetBIOS, IPv6 and WPAD are left alone** in every answer file. The
  lab domain exists to have them (ADR-0029).
- **CI proves it parses, `phoenix` proves it builds.** `scripts/lint.sh` runs
  `packer fmt -check` and `packer validate -syntax-only` from the image
  `stacks/observability/compose.yaml` pins. Neither needs a plugin or a
  Proxmox. A change here is only finished once the runbook's §6 smoke test has
  passed against a real build.

[ADR-0074]: ../docs/adr/0074-build-the-lab-templates-with-packer-from-phoenix.md
[ADR-0090]: ../docs/adr/0090-test-the-dotfiles-os-layers-on-on-demand-saruman-guests.md
[ADR-0077]: ../docs/adr/0077-configure-the-lab-domain-with-ansible-from-phoenix.md
[runbook]: ../docs/runbooks/build-the-lab-templates.md
[#448]: https://github.com/Gerrrt/HomeLab/issues/448
