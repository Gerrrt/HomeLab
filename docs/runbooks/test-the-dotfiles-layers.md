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
  903–909 for the guests you are creating, and the existing 911;
- the pool grant, from
  [`provision-lab-guests.md`](provision-lab-guests.md) §2 (`/pool/dotfiles`).

This runs
[ADR-0090](../adr/0090-test-the-dotfiles-os-layers-on-on-demand-saruman-guests.md)
for [#920](https://github.com/Gerrrt/HomeLab/issues/920). Built so far: Debian
(191), Fedora (192) and Windows (198) in phase 1, openSUSE Tumbleweed (193)
and Arch (194) in phase 2, Alpine (195) and Gentoo (196) in phase 3, and
NixOS (197) in phase 4: all eight layers.

| Guest | VMID | Address | Template | Layer repo |
| --- | --- | --- | --- | --- |
| `dot-debian` | 191 | `10.0.30.91` | 903 `tpl-debian-13` | `dotgibson/dotfiles-Debian` |
| `dot-fedora` | 192 | `10.0.30.92` | 904 `tpl-fedora-server` | `dotgibson/dotfiles-Fedora` |
| `dot-opensuse` | 193 | `10.0.30.93` | 905 `tpl-opensuse-tw` | `dotgibson/dotfiles-openSUSE` |
| `dot-arch` | 194 | `10.0.30.94` | 906 `tpl-arch` | `dotgibson/dotfiles-Arch` |
| `dot-alpine` | 195 | `10.0.30.95` | 907 `tpl-alpine` | `dotgibson/dotfiles-Alpine` |
| `dot-gentoo` | 196 | `10.0.30.96` | 908 `tpl-gentoo` | `dotgibson/dotfiles-Gentoo` |
| `dot-nixos` | 197 | `10.0.30.97` | 909 `tpl-nixos` | `dotgibson/dotfiles-NixOS` |
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
`umask 077`, then `plan -out` and `apply`. A guest whose template does not
exist yet cannot be cloned, so apply with `-target='module.guest["dot-…"]'`
for the ones whose templates are built, one at a time if you like; the pool
comes with the first. The plan should add exactly those, and change nothing
else. Anything that says `must be replaced` on a lab-domain guest is a stop.

Check each one:

```bash
for id in 191 192 193 194 195 196 197 198; do api /nodes/Saruman/qemu/$id/config | jq -c '.data | {name, tags, net0, onboot, efidisk0}'; done
```

**Each must show `tags` as `dotfiles;on-demand`.** `dot-arch`'s, `dot-alpine`'s, `dot-gentoo`'s and `dot-nixos`'s `efidisk0` must show `pre-enrolled-keys=0`: they boot without Secure Boot. Without `on-demand`,
`HypervisorGuestStopped` fires an hour after the first shutdown.

## 3. First boot, then the `clean` snapshot

Boot each guest once, so that cloud-init (or Windows' OOBE) does its
per-machine work. The apply already did: the provider starts a guest when it
creates it, so after §2 each new guest is running its first boot. That work is the user, the key, the host keys and the
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

**Then bake in what the layer's `configuration.dsc.yaml` installs, still
before the shutdown** (#1108). `tester` is a standard user, so at the console
every machine-wide install asks for the `Administrator` password, and the
first run (2026-10-08) was mostly UAC prompts. Installed here, machine-wide,
`winget configure` finds each package present and skips it.

Run it as SYSTEM through the guest agent, as root on `Saruman`, and **not**
as `Administrator` over SSH. The last line, `winget configure --enable`,
fails from an SSH network logon (`0x80070520`, §4), and SYSTEM is the route
that was verified (2026-10-09). Save the block below as `bake.ps1`, then:

```bash
qm guest exec 198 --timeout 1780 -- powershell -NoProfile \
  -EncodedCommand "$(iconv -t UTF-16LE bake.ps1 | base64 -w0)"
```

`exitcode` 0 means every step ran. Anything else names the step in
`err-data`.

```powershell
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$d = Join-Path $env:WINDIR 'Temp\bake'; New-Item -ItemType Directory -Force $d | Out-Null
# Each from its publisher, with the SHA-256 the publisher states (GitHub's
# release digest; Wireshark's SIGNATURES file). Current on 2026-10-09.
$items = @(
  @{ n='PowerShell-7.6.6-win-x64.msi'; u='https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.msi'; h='958838ff55091e1c8705d89efed0cc7e8245a3a6ef6c0ccfae20015227108ad8' },
  @{ n='Git-2.56.0.2-64-bit.exe'; u='https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/Git-2.56.0.2-64-bit.exe'; h='52188f917b378f00c70ec136bcf090005f30d44fbc4eba0bce759cc6592d60f6' },
  @{ n='wsl.3.0.1.0.x64.msi'; u='https://github.com/microsoft/WSL/releases/download/3.0.1/wsl.3.0.1.0.x64.msi'; h='28b1a0d013640a2ac95898ea705fa186e5b4ff767a1c1b49257161bc106599c6' },
  @{ n='Wireshark-4.6.9-x64.exe'; u='https://www.wireshark.org/download/win64/Wireshark-4.6.9-x64.exe'; h='bf9b5ce8a89f244c376a9b1a946276eaa06463dde3e33069a34d7f102f5878cf' }
)
foreach ($i in $items) {
  $f = Join-Path $d $i.n
  Invoke-WebRequest -UseBasicParsing -Uri $i.u -OutFile $f
  if ((Get-FileHash -Algorithm SHA256 $f).Hash.ToLower() -ne $i.h) { throw "hash mismatch: $($i.n)" }
}
# Not $args: that name is PowerShell's own, and a parameter called it is empty.
function Run($exe, $argv) { $p = Start-Process -FilePath $exe -ArgumentList $argv -Wait -PassThru; if ($p.ExitCode -notin 0, 3010) { throw "$exe exited $($p.ExitCode)" } }
Run msiexec.exe "/i `"$d\PowerShell-7.6.6-win-x64.msi`" /qn /norestart ADD_PATH=1 ENABLE_PSREMOTING=0 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1"
Run "$d\Git-2.56.0.2-64-bit.exe" "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /NOCANCEL /SP- /COMPONENTS=gitlfs,assoc,assoc_sh"
Run msiexec.exe "/i `"$d\wsl.3.0.1.0.x64.msi`" /qn /norestart"
Run "$d\Wireshark-4.6.9-x64.exe" "/S /desktopicon=no /quicklaunchicon=no"
# Developer Mode: what the layer's DeveloperMode resource sets.
New-Item -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock -Force | Out-Null
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock -Name AllowDevelopmentWithoutDevLicense -Type DWord -Value 1
Remove-Item -Recurse -Force $d
# winget configure is off on a fresh install, and turning it on is elevated.
# As SYSTEM this works; from an SSH logon it fails (0x80070520).
$wg = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe' | Sort-Object FullName | Select-Object -Last 1
& $wg.FullName configure --enable
```

What it leaves out, on purpose:

- **Windows Terminal** ships with Windows 11 and is registered at each
  user's first logon.
- **GNU Wget2** installs per user, so it asks for nothing.
- **Npcap.** Wireshark's silent install skips it, because Npcap's free
  edition has no silent install. Capture is not part of the test.
- **WSL** is installed but cannot start, because the guest has no nested
  virtualization (§4).

The versions are the current ones on 2026-10-09. At a re-clone, take the
current release of each and its publisher's SHA-256. winget's `configure`
only asks for each package to be present, not for a version, so an older
pin is still skipped.

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
- **openSUSE:** `ssh tester@10.0.30.93`, then the same with
  `dotfiles-openSUSE`. Tumbleweed, not Leap or a transactional edition, so
  one run with no reboot.
- **Arch:** `ssh tester@10.0.30.94`, then the same with `dotfiles-Arch`.
  The template has `sudo`, `git` and an `en_US.UTF-8` locale, which the
  layer's README asks for. It installs no AUR helper; paru stays the
  README's manual step.
- **Alpine:** `ssh tester@10.0.30.95`, then the same with
  `dotfiles-Alpine`. `bash` and `git` are in the template, which is the
  README's first step. Privilege is `doas`, not `sudo`. The template has no
  `sudo` on purpose: the bootstrap would pick it first, and the clone's user
  has no rule for it.
- **Gentoo:** `ssh tester@10.0.30.96`, then the same with
  `dotfiles-Gentoo`, and afterwards `make assert-provisioned` in the
  checkout. The template is Gentoo's systemd cloud image, so the layer runs
  on systemd, not its OpenRC default. Expect a long run: the bootstrap emerges
  from the binary host where it can, and builds the rest.
- **NixOS:** `ssh tester@10.0.30.97`, in the layer's own order, which is
  `nix` first. Its README names the 25.05 channels; take the release that
  matches the guest, 26.05:

  ```bash
  git clone https://github.com/dotgibson/dotfiles-NixOS ~/dotfiles-NixOS
  sudo nix-channel --add https://github.com/nix-community/home-manager/archive/release-26.05.tar.gz home-manager
  sudo nix-channel --update
  # nix/nixos.nix: set username = "tester" and uncomment users.users.${username}.shell
  ```

  Then add a `/etc/nixos/dotfiles.nix`, and `./dotfiles.nix` to the imports
  in `/etc/nixos/configuration.nix`. It imports `nix/nixos.nix` and
  `<home-manager/nixos>`, the README's recommended way, and declares
  `users.users.tester.isNormalUser = true`, because the module needs the user
  declared. Its home is `home-manager.users.tester = import …/nix/home.nix`.
  Then:

  ```bash
  sudo nixos-rebuild switch
  cd ~/dotfiles-NixOS && ./bootstrap.sh
  exec zsh
  core doctor
  ```

  `bootstrap.sh` here links and never escalates. home-manager activates
  inside `nixos-rebuild switch`, so there is no separate `home-manager
  switch`.
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
  Then, at the console, in PowerShell 7 (`pwsh`). `clean` already has Git,
  PowerShell 7, the configuration's other packages, Developer Mode and
  `winget configure` switched on (§3):

  ```powershell
  git clone https://github.com/dotgibson/dotfiles-Windows.git ~/dotfiles-Windows
  cd ~/dotfiles-Windows
  (Get-Content configuration.dsc.yaml) -replace 'allowPrerequisites','allowPrerelease' | Set-Content configuration.dsc.yaml
  winget configure -f configuration.dsc.yaml --accept-configuration-agreements
  ```

  One line here is not in the layer's README
  ([dotgibson/dotfiles-Windows#285](https://github.com/dotgibson/dotfiles-Windows/issues/285)).
  It is the `-replace` on `configuration.dsc.yaml`:
  - On 2026-10-08 the file's directives read `allowPrerequisites`, which
    winget does not know.
  - `Microsoft.Windows.Developer` (`OsVersion`, `DeveloperMode`) is published
    only as prereleases.
  - So without `allowPrerelease` the configure stops at "OsVersion
    [os-version] The configuration unit could not be found".

  Drop the line once the layer is fixed.

  The console opens at the sign-in screen (#1092, fixed by #1093 and 911's
  2026-10-09 rebuild). Sign in as `tester` under *Other user*.

  The configure should ask for no UAC approval. If it does, that package is
  one the bake in §3 does not cover: approve it with the `Administrator`
  password (the template's build password, from `phoenix.env`) and add it to
  the bake. Then, in a new `pwsh`:
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
| 2026-10-09 | Phase 2: templates 905 (openSUSE Tumbleweed) and 906 (Arch) | Both built twice and smoke-tested, in about 11 min and 2.5 min. **openSUSE:** three builds stopped at "a profile for this machine could not be found or retrieved", which looked like a location problem but wasn't. YaST's schema check had rejected `install_recommends` (it is `install_recommended`); y2log on tty2 showed it. Then the profile had to name the `openSUSE` base product, and the default user needed a sudo drop-in (openSUSE's `cloud.cfg` gives it none). **Arch:** the live ISO's cloud-init wrapped root's key in a forced command until `disable_root: false`; `ln` of resolv.conf fails inside `arch-chroot`; `inetutils` is needed for `hostname` |
| 2026-10-09 | Phase 2 guests, `-target`ed one at a time | `dot-arch` (194, .94, Secure Boot off) and `dot-opensuse` (193, .93). `tester` logs in with `sudo`, DNS works, `clean` taken stopped |
| 2026-10-09 | First runs, Arch and openSUSE (dotfiles v7.14.0) | Arch: `bootstrap.sh` exit 1, `core doctor` exit 0. The one failure is the Flathub remote: it is added system-wide without `$BLIB_SU`, and polkit refuses it with no agent (`EnsureRepo not allowed for user`); filed as [dotgibson/dotfiles-Arch#199](https://github.com/dotgibson/dotfiles-Arch/issues/199). Six AUR-only tools are missing, as the layer says. openSUSE: exit 2 for the same Flathub step (`ConfigureRemote not allowed for user`); doctor exit 0, `jj` and `difft` missing |
| 2026-10-09 | Phase 3: templates 907 (Alpine) and 908 (Gentoo), from cloud images | `scripts/import-cloud-template.sh` imported Alpine 3.24.2-r2 and Gentoo `di-amd64-cloudinit-20261004T164559Z` as staging templates 917 and 918. Both images verified against keys found off the image, then pinned by SHA-256. Packer's `proxmox-clone` built each twice, and each passed its smoke test both times: Alpine in about 1 min, Gentoo in about 11. The first builds found the builder's `lsi` controller (no boot under OVMF), its `ostype other`, cloud-init's first-boot upgrade holding the package lock, Alpine's missing `resolv.conf` on a static address, and `apk upgrade` tripping a `limine-efi-updater` trigger. `build-the-lab-templates.md` §4b has each |
| 2026-10-09 | Phase 3 guests, `-target`ed together | `dot-alpine` (195, .95) and `dot-gentoo` (196, .96), Secure Boot off. `tester` logs in with `doas` (Alpine) or `sudo` (Gentoo), DNS works, and Gentoo's root grew to 60G. `clean` taken stopped |
| 2026-10-09 | First runs, Alpine and Gentoo (dotfiles v7.14.0) | Alpine: `bootstrap.sh` exit 0 in 26 min (mostly cargo builds), `core doctor` exit 0 with nothing missing, opt-in tools included; the first layer to run clean end to end. Gentoo: exit 0 in 2 h (`emerge --sync`, then 98 packages, most as binaries), doctor exit 0 with only `gum` missing, which `install/packages.txt` leaves out on purpose; `make assert-provisioned` OK, 39 required and 0 best-effort absent. On systemd, not the layer's OpenRC default |
| 2026-10-09 | 907 rebuilt for review (`cloud-init clean --machine-id`) | Built twice and smoke-tested again, then `dot-alpine` re-cloned with `-target`ed `-replace` and `clean` retaken. Alpine (OpenRC) has no `/etc/machine-id` at all, so the flag is for parity with the other templates, not a fix |
| 2026-10-09 | Phase 4: template 909 (NixOS) and `dot-nixos` | 909 built twice from the NixOS 26.05 minimal ISO and smoke-tested both times, about 5 min a build. The first two builds stopped at mounting the new root: once on a `/dev/disk/by-label` link udev had not made yet, and once because the ISO had not loaded ext4, so `mount` tried the partition as FAT. Both are fixed by mounting by device, with the type named. `dot-nixos` (197, .97) was applied with `-target`. `tester` has `sudo`, the `nixos-26.05` channel is present, root grew to 39G, and `clean` was taken stopped |
| 2026-10-09 | First run, NixOS (dotfiles v7.14.0) | In the layer's order: the `home-manager` channel (release-26.05), `nix/nixos.nix` with `tester` and the home-manager module, then `nixos-rebuild switch`, which took about 1 min and activated `home-manager-tester.service`. Then `./bootstrap.sh`, exit 0 in 1 s (links only, no escalation), and `core doctor` exit 0, with nine missing: `viddy gron sd xh doggo op ast-grep uv difft`. None of them is in `nix/home.nix`'s `home.packages`, so the layer's package set lags what Core expects |
| 2026-10-09 | `dot-windows` re-cloned from the rebuilt 911 (#1093), §3 again, then the new prerequisite bake (#1108) | First boot rested at the sign-in screen: `AutoAdminLogon=0`, no `DefaultPassword`, no `Panther\unattend-original.xml`. `tester` logs in by key at Medium Mandatory Level. The bake ran as SYSTEM through the guest agent: all four downloads matched their published SHA-256, and every installer exited 0. Afterwards winget (as SYSTEM) lists Git.Git 2.56.0.2, Microsoft.PowerShell 7.6.6, Microsoft.WSL 3.0.1 and WiresharkFoundation.Wireshark 4.6.9. `configure --enable` exited 0. `clean` retaken stopped. The console run has not been done yet |
