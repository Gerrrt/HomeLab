# Runbook: Build the lab's VM templates with Packer, from `phoenix`

**Target:** templates 901, 911 and 912 on `Saruman`, built from `phoenix`
through the Proxmox API. 902, Kali, is written here and built on `ifrit` once
that host exists.

**Time:** an evening the first time, most of it Windows Setup running
unattended. After that, a rebuild is one command per template and about forty
minutes of waiting for each Windows one.

**You will need:**

- a shell on `phoenix` as the user that owns `~/.config/proxmox/phoenix.env`;
- a root shell on `Saruman`, for §2 only;
- the installer ISOs already on `local:iso/`, the ones
  [`build-the-lab-domain.md`](build-the-lab-domain.md) §1 used:
  `windows-11.iso`, `windows-server-2025-eval.iso`, `virtio-win.iso`, and the
  Ubuntu 26.04 live-server ISO.

**Before this:** `phoenix`, built by
[`build-the-jumpbox.md`](build-the-jumpbox.md), with the token from its §4
working.

**After this:** [`LabWindowsEvaluationExpiring`](../../stacks/lab/prometheus/rules/lab.rules.yaml)
has an answer that is a command (§8), and #445's OpenTofu has templates to
clone.

This builds what
[ADR-0071](../adr/0071-build-the-lab-templates-with-packer-from-phoenix.md)
decided for [#440](https://github.com/Gerrrt/HomeLab/issues/440). The HCL is in
[`packer/`](../../packer/README.md).

---

## 0. What is decided, and why

| | Decision | Why this and not the obvious alternative |
| --- | --- | --- |
| Where it runs | `phoenix`, through the API on 8006 | It is the only host admitted to the hypervisor's API, and the only one meant to build machines (ADR-0043). There is no SSH to `Saruman` from here, and nothing in this runbook needs it |
| VMIDs | 901 Ubuntu, 902 Kali, 911 Windows 11 Pro, 912 Server 2025 eval | The 900s hold no address. Guests keep "VMID is the last octet" |
| Clones | **Full, never linked** | A rebuild runs `packer build -force`, which destroys the template at the same VMID. A linked clone would stop that, or break |
| Windows SID | `sysprep /generalize` as each build's last step | Every clone takes a new machine SID at first boot. Two DCs cloned from one template would otherwise share one, and a member whose SID matches a DC's cannot join |
| Answer files | On a generated CD (`cidata` for Ubuntu, `ANSWERS` for Windows) | Nothing has to listen on `phoenix`. Kali is the exception, see §5 |
| Credential | `phoenix.env`, mode 600, not in git | `phoenix` holds no age key (ADR-0043), so a SOPS file is one it could not read |
| What a template holds | OS, VirtIO drivers, guest agent, cloud-init (Linux) | Addresses, names, joins and the licence gauge belong to the guest. They are #448's |

## 1. Packer, on `phoenix`

```bash
sudo apt-get install -y gnupg curl jq xorriso
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y packer
packer version
```

- **`xorriso`** builds the answer discs. Without it Packer fails with "could
  not find a supported CD ISO creation command" after it has already created
  the VM.
- **`jq`** is for `scripts/packer-smoke.sh` in §6.
- **If HashiCorp's repository has no suite yet** for this Ubuntu release, the
  `apt-get update` says so. Take the `linux_amd64` zip for the version
  `stacks/observability/compose.yaml` pins for `packer` from
  `releases.hashicorp.com`, check it against the `SHA256SUMS` file published
  beside it, and put the binary in `/usr/local/bin`.

Then fetch the plugin `packer/versions.pkr.hcl` pins:

```bash
cd ~/HomeLab && git pull && packer init packer/
```

## 2. What the token is missing, on `Saruman`

`PhoenixBuilder` as `build-the-jumpbox.md` §4 made it reaches `local` and
`local-lvm`, and every guest disk here is on `large_data`. Packer also asks the
guest agent for the address, which Proxmox VE 9 gates behind a privilege of
its own:

```bash
pveum acl modify /storage/large_data --users phoenix@pve --roles PhoenixBuilder
pveum role modify PhoenixBuilder --append 1 --privs "VM.GuestAgent.Audit"
pveum acl list | grep phoenix
```

That is ADR-0043's rule applied: **privileges are added to the role, and the
role is never granted at `/`**. If a build fails with
`Permission check failed (/…, Some.Privilege)`, add that privilege the same
way, rerun, and **write the privilege into this section** before closing the
terminal. That list is the token's scope, and nobody can argue about a scope
that was never written down.

Found on the first build (fill in):

| Privilege | Path | What asked for it |
| --- | --- | --- |
| `Datastore.AllocateSpace` (role) | `/storage/large_data` | every disk, EFI disk and TPM state |
| `VM.GuestAgent.Audit` | `/vms` | Packer's address lookup, `scripts/packer-smoke.sh` |

## 3. The build password, on `phoenix`

The Windows builds log in as the built-in Administrator to provision, and a
clone boots with the same password until #448 rotates it. Add it to the file
that already holds the token:

```bash
umask 077
printf 'PKR_VAR_build_password=%s\n' "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)Aa1!" \
  >> ~/.config/proxmox/phoenix.env
```

`packer/variables.pkr.hcl` refuses one shorter than 14 characters or holding
any of `< > & " '`, because it is pasted verbatim into two XML answer files.
Every build validates every variable, so the Linux builds need it set too.

## 4. Build

```bash
cd ~/HomeLab
set -a; . ~/.config/proxmox/phoenix.env; set +a
packer build -only='ubuntu.*' packer/
packer build -only='windows.proxmox-iso.ws2025-eval' packer/
packer build -only='windows.proxmox-iso.win11-pro' packer/
```

One at a time. Two Windows installers at once is the IOPS burst ADR-0029
budgets against, on the pool the domain's guests live on.

What each one does, so a stall can be placed:

- **Ubuntu** drops to GRUB's prompt and types the kernel line. Subiquity then
  finds `cidata`, installs unattended, and reboots. Packer waits for SSH as
  `packer` with `phoenix`'s key, upgrades, and wipes cloud-init's state,
  machine-id and host keys. It then deletes the `packer` user.
- **Windows** presses a key at "Press any key to boot from CD". Setup loads
  `vioscsi` and `NetKVM` from the VirtIO disc, installs, and logs in once as
  Administrator. `bootstrap.ps1` from the answer disc installs the guest
  tools, then opens WinRM. Packer finds the address through the agent,
  uploads the clone's answer file and `SetupComplete.cmd`, and runs sysprep.

**When a Windows build stalls at "Waiting for WinRM",** open the VM's console
in the Proxmox UI from Hicks:

- **No disk to install to:** the driver paths missed. Check the VirtIO disc's
  folder names against `driver_dir` in `packer/windows.pkr.hcl`.
- **Sitting at the desktop with no network:** `NetKVM` did not load.
- **Desktop, network up, still no WinRM:** `bootstrap.ps1` failed. Run it
  from the `ANSWERS` drive in a PowerShell window to see why.

**If sysprep fails,** `C:\Windows\System32\Sysprep\Panther\setuperr.log` names
the culprit. On Windows 11 it is almost always a Store app updated for
Administrator during the build, which `bootstrap.ps1` exists to prevent.

## 5. Kali, once `ifrit` exists

Tracked as [#790](https://github.com/Gerrrt/HomeLab/issues/790). Not on `Saruman`: the attack VM lives on `ifrit`, and a template belongs to one
node. The preseed is served over Packer's HTTP server on port 8800 of
`phoenix`, because Debian's installer reads one from a URL or its own medium,
not from a second disc.

1. Admit the guest to that port on `phoenix` for the length of the build. If
   `ufw` is active, run `sudo ufw allow from 10.0.30.0/24 to any port 8800 proto tcp`,
   and delete the rule afterwards.
2. Grant `PhoenixBuilder` on `ifrit`'s storage and bridge, as §2 did on
   `Saruman`.
3. Set `kali_iso_file` to the ISO actually on `ifrit`, then build:

   ```bash
   packer build -only='kali.*' -var kali_iso_file=local:iso/<the iso> packer/
   ```

## 6. Prove each template

```bash
scripts/packer-smoke.sh 901
scripts/packer-smoke.sh 912
scripts/packer-smoke.sh 911
```

Each run makes a full clone at VMID 999. For Linux, it gives the clone user
`smoke`, `phoenix`'s key and DHCP through cloud-init, boots it, and waits for
the agent to report an address. It then checks the hostname and SSHes in.
Finally it destroys the clone.

A Windows clone runs specialize and OOBE first. Allow ten minutes before the
agent answers. Its hostname is sysprep's random one, because the real name
belongs to #448.

## 7. The SID check — what generalising was for

Two clones of the Server template, kept running:

```bash
scripts/packer-smoke.sh 912 --vmid 998 --name sid-a --keep
scripts/packer-smoke.sh 912 --vmid 999 --name sid-b --keep
```

In each one's console, log in as Administrator with the build password and
run:

```powershell
(New-Object System.Security.Principal.NTAccount('Administrator')).Translate([System.Security.Principal.SecurityIdentifier]).AccountDomainSid.Value
```

**The two must differ.** If they match, the build did not generalise, and the
template must not be used for the domain. Then destroy both clones: run
`qm destroy 998 --purge` and `qm destroy 999 --purge` on `Saruman`, or use
the UI.

## 8. Rebuild — the real test, and the answer to the licence alert

The acceptance test for #440 is building the same template twice. Repeat §4 with
`-force`, which destroys the template at its VMID first:

```bash
packer build -force -only='windows.proxmox-iso.ws2025-eval' packer/
scripts/packer-smoke.sh 912
```

Then do the same for 901 and 911.

**When `LabWindowsEvaluationExpiring` fires,** this is the first half of the
answer. Rebuild 912, then rebuild the server from it as `build-the-lab-domain.md`
§2 onwards describes. On build day, record the new guest's `slmgr /dlv`
rearm count there, per ADR-0029. Sysprep's generalise spends a rearm on the
image, so the count a clone reports is the one to write down. The template's
count is not.

## 9. Write it down

On the day of the first successful build:

- §2's table: every privilege the build asked for.
- `docs/changelog.md`: the build and smoke times, the SID pair from §7, and
  the second build from §8.
- `docs/roadmap.md`: mark #440 done. Close #440 with a link to that entry.

## 10. Take it out

In the Proxmox UI, or from `phoenix`, destroy VMIDs 901, 911 and 912. No guest
depends on a template once cloned, because every clone is full. Then remove
the `large_data` ACL and `VM.GuestAgent.Audit` from §2 if nothing else uses
them, and `PKR_VAR_build_password` from `phoenix.env`.
