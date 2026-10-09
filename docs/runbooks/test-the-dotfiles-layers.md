# Runbook: Test a dotfiles OS layer on its on-demand guest

**Target:** the `dot-*` guests on `Saruman`, VMIDs 191–198, ImaginationLAN
(VLAN 30). There is one per OS layer of the
[dotgibson dotfiles](https://github.com/dotgibson/dotfiles-core).

**Time:** an evening to build the first three. After that, a run is a
rollback, a bootstrap and a read: minutes, plus however long the layer takes
to install its packages.

**You will need:** a shell on `phoenix`, with `phoenix.env` sourced, and a
root shell on `Saruman` once, for the pool grant. A browser on Hicks is only
needed for Kea.

**Before this:**

- the templates, from
  [`build-the-lab-templates.md`](build-the-lab-templates.md) §2b, §4 and §6:
  903 and 904, and the existing 911;
- the pool grant, from
  [`provision-lab-guests.md`](provision-lab-guests.md) §2 (`/pool/dotfiles`).

This runs
[ADR-0090](../adr/0090-test-the-dotfiles-os-layers-on-on-demand-saruman-guests.md)
for [#920](https://github.com/Gerrrt/HomeLab/issues/920). Built so far: Debian
(191), Fedora (192) and Windows (198). The other five layers join in later
phases, and each phase adds its guests' rows below.

| Guest | VMID | Address | Template | Layer repo |
| --- | --- | --- | --- | --- |
| `dot-debian` | 191 | `10.0.30.91` | 903 `tpl-debian-13` | `dotgibson/dotfiles-Debian` |
| `dot-fedora` | 192 | `10.0.30.92` | 904 `tpl-fedora-server` | `dotgibson/dotfiles-Fedora` |
| `dot-windows` | 198 | `10.0.30.98` | 911 `tpl-win11-pro` | `dotgibson/dotfiles-Windows` |

The helpers below are used in every section. They call the API with the
token in `phoenix.env`, as `provision-lab-guests.md` §4 does:

```bash
set -a; . ~/.config/proxmox/phoenix.env; set +a
api()  { printf 'header = "Authorization: PVEAPIToken=%s"\n' "${PROXMOX_VE_API_TOKEN}" | curl -K - -fsS "${PROXMOX_URL}$1"; }
post() { printf 'header = "Authorization: PVEAPIToken=%s"\n' "${PROXMOX_VE_API_TOKEN}" | curl -K - -fsS -X POST "${PROXMOX_URL}$1" "${@:2}"; }
# Power, snapshot and rollback calls return a task's UPID and finish later.
# `task` waits for it and fails unless it ended OK, so the next call never
# meets a guest that is still locked (scripts/packer-smoke.sh does the same).
task() {
  upid=$(post "$@" | jq -r .data)
  while [ "$(api "/nodes/Saruman/tasks/$upid/status" | jq -r .data.status)" = running ]; do sleep 2; done
  api "/nodes/Saruman/tasks/$upid/status" | jq -e '.data.exitstatus == "OK"' >/dev/null || { echo "task failed: $upid" >&2; return 1; }
}
```

---

## 1. Reserve the addresses, on `morpheus`

In the UI, go to *Services → DHCP Server → ImaginationLAN* and add one
reservation per guest, with the MAC from `tofu/guests.tf`'s `dotfiles` map
and the address from the table above. The guests take DHCP from cloud-init
(Linux) or Windows' default. Below `.100` it is the reservation that gives
them their address, so do this before the first boot, not after.

## 2. Create them, from `phoenix`

[`provision-lab-guests.md`](provision-lab-guests.md) §4, unchanged:
`umask 077`, then `plan -out` and `apply`. The plan for the first phase is
four to add: the `dotfiles` pool and three guests. Anything that says
`must be replaced` on a lab-domain guest is a stop.

Check each one:

```bash
for id in 191 192 198; do api /nodes/Saruman/qemu/$id/config | jq -c '.data | {name, tags, net0, onboot}'; done
```

**Each must show `tags` as `dotfiles;on-demand`.** Without `on-demand`,
`HypervisorGuestStopped` fires an hour after the first shutdown.

## 3. First boot, then the `clean` snapshot

Boot each guest once, so that cloud-init (or Windows' OOBE) does its
per-machine work. The apply already did: the provider starts a guest when it
creates it, so after §2 all three are running their first boot. That work is the user, the key, the host keys and the
machine-id. Then shut the guest down and snapshot it **stopped**:

```bash
id=191
task /nodes/Saruman/qemu/$id/status/start
# Linux: wait until `ssh tester@10.0.30.91 true` succeeds, then:
task /nodes/Saruman/qemu/$id/status/shutdown
task /nodes/Saruman/qemu/$id/snapshot -d snapname=clean -d 'description=first boot, before any dotfiles (#920)'
```

**Stopped, never live.** A live snapshot freezes the guest's filesystems
through the agent, and the thaw has hung guests on `Saruman` before. A
stopped snapshot has no RAM state to save either. `PhoenixBuilder` already
holds `VM.Snapshot` on `/vms`, so this needs no new grant.

**For `dot-windows`, add the test user before you shut it down.** The
Windows bootstrap must not run elevated, because scoop's installer refuses
an admin shell. Over SSH, `Administrator` is always elevated, so the bootstrap
needs a standard user with `phoenix`'s key. As `Administrator`
(`ssh Administrator@10.0.30.98`):

```powershell
$ErrorActionPreference = 'Stop'
$pw = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
New-LocalUser -Name tester -Password (ConvertTo-SecureString $pw -AsPlainText -Force) -PasswordNeverExpires | Out-Null
Add-LocalGroupMember -Group Users -Member tester -ErrorAction SilentlyContinue
# The profile, made now: an account that has never logged on has none, and
# sshd finds no home, so no authorized_keys, for it.
Add-Type -Namespace W -Name U -MemberDefinition '[DllImport("userenv.dll", CharSet=CharSet.Unicode)] public static extern int CreateProfile(string sid, string name, System.Text.StringBuilder path, uint len);'
$sb = New-Object System.Text.StringBuilder 260
[W.U]::CreateProfile((Get-LocalUser tester).SID.Value, 'tester', $sb, 260)   # 0, and C:\Users\tester
New-Item -ItemType Directory -Force C:\Users\tester\.ssh | Out-Null
Copy-Item C:\ProgramData\ssh\administrators_authorized_keys C:\Users\tester\.ssh\authorized_keys
icacls C:\Users\tester\.ssh\authorized_keys /inheritance:r /grant 'tester:F' /grant 'SYSTEM:F' | Out-Null
icacls C:\Users\tester\.ssh /setowner tester /T /C | Out-Null
```

Run it as one `powershell -NoProfile -EncodedCommand`, so that no quoting
has to survive the SSH hop. Two things here are not optional, and each cost
the first build an attempt (2026-10-08):

- **The profile.** Without `CreateProfile`, `tester` has no entry under
  `ProfileList` until its first interactive logon. sshd then refuses the key
  without saying why. Do not create `C:\Users\tester` by hand first, or
  Windows makes the profile at `C:\Users\tester.<machine>` instead.
- **The owner.** Win32-OpenSSH refuses an `authorized_keys` owned by anyone
  but the user, SYSTEM or the Administrators group. A file copied by
  `Administrator` is owned by that account, which is none of them.

Check from `phoenix`: `ssh tester@10.0.30.98 'whoami /groups | findstr Mandatory'`
must show `Medium Mandatory Level`, which means not elevated. The password
is never written down. The account logs in by key alone, as `sshd` allows
nothing else here. Its default shell is PowerShell, so chain commands with
`;`, not `&`.

## 4. A run

Every run starts from `clean`:

```bash
id=191
task /nodes/Saruman/qemu/$id/snapshot/clean/rollback
task /nodes/Saruman/qemu/$id/status/start
```

Then, per layer:

- **Debian:** `ssh tester@10.0.30.91`, then:

  ```bash
  git clone https://github.com/dotgibson/dotfiles-Debian ~/dotfiles-Debian
  cd ~/dotfiles-Debian && ./bootstrap.sh
  exec zsh
  core doctor
  ```

  `curl`, `git` and `sudo` are in the template, so the preflight passes.
- **Fedora:** `ssh tester@10.0.30.92`, then the same with
  `dotfiles-Fedora`, and `./bootstrap.sh --no-flatpak`. It is a headless
  Server.
- **Windows: from the console, not over SSH.** The first run (2026-10-08)
  showed that the layer cannot be tested in an SSH session:
  - **`winget`.** It is not registered for an account that has never had an
    interactive logon. It can be registered by hand
    (`Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe`,
    then the `source2.msix` from `cdn.winget.microsoft.com/cache/`).
  - **MSIX installs.** PowerShell 7's MSIX package will not install in an
    SSH session (`0x80073D19`).
  - **`winget configure`.** It needs Store access, which an SSH session
    cannot get (`0x80070520`).
  - **scoop.** Windows 11 refuses to traverse scoop's `current` junctions
    from a network logon ("untrusted mount point"). `install.ps1` stopped
    at its second package with nothing linked.

  None of these is a dotfiles bug. Run it as the README says, at the
  console in the Proxmox UI (*dot-windows → Console*), logged in as
  `tester`. Its password is not known, so set one first over SSH as
  `Administrator`:

  ```powershell
  Set-LocalUser tester -Password (Read-Host -AsSecureString)
  ```

  The password is a run-time change, and the next rollback discards it.
  Then, at the console, in Windows PowerShell:

  ```powershell
  winget configure --enable
  winget install Git.Git Microsoft.PowerShell
  git clone https://github.com/dotgibson/dotfiles-Windows.git ~/dotfiles-Windows
  cd ~/dotfiles-Windows
  (Get-Content configuration.dsc.yaml) -replace 'allowPrerequisites','allowPrerelease' | Set-Content configuration.dsc.yaml
  winget configure -f configuration.dsc.yaml --accept-configuration-agreements
  ```

  Two lines here are not in the layer's README
  ([dotgibson/dotfiles-Windows#285](https://github.com/dotgibson/dotfiles-Windows/issues/285)):

  - **`winget configure --enable`.** A fresh install has configuration
    switched off.
  - **The `-replace` on `configuration.dsc.yaml`.** On 2026-10-08 the file's
    directives read `allowPrerequisites`, which winget does not know.
    `Microsoft.Windows.Developer` (`OsVersion`, `DeveloperMode`) is
    published only as prereleases, so without `allowPrerelease` the
    configure stops at "OsVersion [os-version] The configuration unit could
    not be found". Drop the line once the layer is fixed.

  **The console opens at OOBE's "Who's going to use this device?"**, because
  911's answer file declares no local account (a template bug, tracked
  separately). Create a throwaway account there, which the rollback
  discards. Then sign out and sign in as `tester` under *Other user*, because
  OOBE's account is an administrator.

  Approve the UAC prompts with the `Administrator` password, which is the
  template's build password from `phoenix.env`. Then, in a new `pwsh`:
  `cd ~/dotfiles-Windows; .\install.ps1`. After that, in another new `pwsh`,
  run the layer's doctor (`powershell/os/45-doctor`).

  **The guest is unactivated (ADR-0090 §6).** A step that fails on a
  Personalization setting is that, not a dotfiles bug. **WSL** is in
  `configuration.dsc.yaml`, and it needs nested virtualization, which this
  guest is not given. A WSL failure here is the test bed's, not the
  layer's.

To test a release rather than `main`, clone with `--branch <tag>`.

**Read the result.** A good run leaves:

- `bootstrap.sh` exiting 0;
- `core doctor` reporting no failures.

Anything else goes on the layer's own repository as an issue, with the
guest, the template's build date (in the template's description) and the
output. Then shut down:

```bash
task /nodes/Saruman/qemu/$id/status/shutdown
```

The guest is left stopped at whatever state the run reached. The next run
rolls back first, so it does not matter.

## 5. Rebuild

When a template is rebuilt (`build-the-lab-templates.md` §8), its guests still
hold the old install, because every clone is full. Re-clone one:

```bash
tofu -chdir=tofu apply \
  -target='module.guest["dot-debian"]' \
  -replace='module.guest["dot-debian"].proxmox_virtual_environment_vm.this'
```

`-target` as well as `-replace`: `-replace` does not narrow the plan, so on
its own it would also apply anything else pending in the state, as
`provision-lab-guests.md`'s rebuild rule says.

Then repeat §3: first boot, shut down, `clean`. Replacing a guest deletes its
snapshots with it.

## 6. Take it out

To remove the guests, delete their entries from `tofu/guests.tf`'s
`dotfiles` map and apply. The pool goes with the last one, and its grant
with the pool (`provision-lab-guests.md` §2). Then remove the Kea
reservations. The templates are `build-the-lab-templates.md` §10's.

## 7. As run

| Date | What | Result |
| --- | --- | --- |
| 2026-10-08 | Templates 903 and 904, `build-the-lab-templates.md` §2b–§8 | Both ISOs placed and `state="match"`. Fedora failed twice before it built: `services --enabled=cloud-init` names no unit since cloud-init 24.3 (Anaconda stopped), and f44's presets leave `cloud-init-network` off, so it is named. Debian's first build missed GRUB at `boot_wait` 10s and was typed in from the console; 20s then built unaided. Second `-force` builds: Debian 8 min, Fedora 10 min. Smoke: all PASS, both builds of each |
| 2026-10-08 | §2 apply, `-target`ed at the pool and the three guests | Plan 4 to add, 0 to change. The untargeted plan also showed `+ "lab-domain"` on 150–153, state catching up with tags root set by hand; left for an untargeted apply. All three on their reservations (.91, .92, .98), `dotfiles;on-demand`, `onboot 0` |
| 2026-10-08 | First boot, Linux | No login: cloud-init's `useradd operator` exited 9 on Debian (system group `operator`, gid 37); Fedora has a system user of that name. `username = "tester"` in `tofu/guests.tf`, then `-replace` of 191 and 192: 2 destroyed, 2 added. `tester` logs in by key with `sudo` on both |
| 2026-10-08 | First boot, Windows; §3's `tester` | `tester` was refused its key twice: no profile (fixed by `CreateProfile`), and the key file owned by `Administrator` (fixed by `/setowner`). Then `Medium Mandatory Level`, `C:\Users\tester` |
| 2026-10-08 | §3 `clean` snapshots | All three stopped, then `qm snapshot <id> clean`. `large_data` 36.7% used |
| 2026-10-08 | First runs, Debian and Fedora (dotfiles v7.14.0) | Debian: `bootstrap.sh` exit 0 in 1m44s, `core doctor` exit 0, "install missing" `sesh yq doggo`. Fedora (`--no-flatpak`): exit 0 in 8m20s, doctor exit 0, but 14 missing, `atuin mise uv jj` among them. Its `/tmp` is a 1.9 GiB tmpfs with `usrquota`. yazi's cargo build there hit `Disk quota exceeded`, and the downloads after it failed on the full `/tmp`. About 1.5 GiB of `cargo-install*` was left behind. `atuin`'s installer exited 1 before that, cause not shown. These are layer findings, not test-bed ones. Filed as [dotgibson/dotfiles-Fedora#208](https://github.com/dotgibson/dotfiles-Fedora/issues/208) |
| 2026-10-08 | First run, Windows, over SSH | Not a valid test. `winget`, MSIX, `winget configure` and scoop's junctions all fail in an SSH session (§4). PowerShell 7.6.6 went in by MSI as `Administrator`, and Developer Mode by registry. `install.ps1` as `tester` stopped at scoop's second package, "untrusted mount point", exit 1, nothing linked. Windows runs are at the console from now on |
| 2026-10-08 | Second run, Windows, at the console (Garrett) | Not finished. The console opened at OOBE's account page (911's answer file; [#1092](https://github.com/Gerrrt/HomeLab/issues/1092), PR #1093). `winget configure` needed `--enable` first, then stopped at `OsVersion`: the layer's `configuration.dsc.yaml` says `allowPrerequisites` where winget wants `allowPrerelease`. UAC asked for the Administrator password at every machine-wide install, PowerShell 7 could not be found after its install, and the guest was slow throughout. `install.ps1` never ran. The Windows run needs the prerequisites baked in, or a faster path, before it is worth repeating |
