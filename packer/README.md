# packer

The lab's VM templates, built from `phoenix` through `Saruman`'s API
([ADR-0074]). How to run them is [`build-the-lab-templates.md`][runbook]; this
page is the map.

| VMID | Template | Source | Installer driven by | Node, and status |
| --- | --- | --- | --- | --- |
| 901 | `tpl-ubuntu-2604` | `ubuntu.pkr.hcl` | autoinstall, `cidata` disc | `Saruman`, first build pending |
| 902 | `tpl-kali` | `kali.pkr.hcl` | Debian preseed, Packer HTTP | `ifrit`, waits for the host ([#790](https://github.com/Gerrrt/HomeLab/issues/790)) |
| 911 | `tpl-win11-pro` | `windows.pkr.hcl` | Autounattend, `ANSWERS` disc | `Saruman`, first build pending |
| 912 | `tpl-ws2025-eval` | `windows.pkr.hcl` | Autounattend, `ANSWERS` disc | `Saruman`, first build pending |

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
- `windows/autounattend.xml.pkrtpl`: one file for both editions, rendered
  with the image name, the VirtIO driver folder and the product key.
- `windows/unattend-oobe.xml.pkrtpl`: the answer file a clone's OOBE reads
  after sysprep.
- `windows/scripts/bootstrap.ps1`: runs at the build's one autologon. It
  installs the guest tools first, because Packer finds the address through
  the agent, and opens WinRM second.
- `windows/scripts/openssh.ps1`: installs the OpenSSH server, disabled and
  key-only, with `phoenix`'s key and a firewall rule admitting `phoenix`
  alone. It is how [`ansible/`](../ansible/README.md) reaches a clone
  ([ADR-0075]).
- `windows/scripts/SetupComplete.cmd`: runs once on each clone, closes
  that WinRM again, and starts `sshd`, which generates the clone's own host
  keys.
- `windows/scripts/sysprep.ps1`: generalise and `/quit`. The builder then
  shuts the guest down and converts it.

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
[ADR-0075]: ../docs/adr/0075-configure-the-lab-domain-with-ansible-from-phoenix.md
[runbook]: ../docs/runbooks/build-the-lab-templates.md
[#448]: https://github.com/Gerrrt/HomeLab/issues/448
