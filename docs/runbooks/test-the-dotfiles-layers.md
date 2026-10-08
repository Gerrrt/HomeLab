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
per-machine work. That work is the user, the key, the host keys and the
machine-id. Then shut the guest down and snapshot it **stopped**:

```bash
id=191
post /nodes/Saruman/qemu/$id/status/start
# Linux: wait until `ssh tester@10.0.30.91 true` succeeds, then:
post /nodes/Saruman/qemu/$id/status/shutdown
# when api /nodes/Saruman/qemu/$id/status/current says "stopped":
post /nodes/Saruman/qemu/$id/snapshot -d snapname=clean -d 'description=first boot, before any dotfiles (#920)'
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
$pw = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
New-LocalUser -Name tester -Password (ConvertTo-SecureString $pw -AsPlainText -Force) -PasswordNeverExpires | Out-Null
New-Item -ItemType Directory -Force C:\Users\tester\.ssh | Out-Null
Copy-Item C:\ProgramData\ssh\administrators_authorized_keys C:\Users\tester\.ssh\authorized_keys
icacls C:\Users\tester\.ssh\authorized_keys /inheritance:r /grant 'tester:F' /grant 'SYSTEM:F' | Out-Null
```

The password is never written down. The account logs in by key alone, as
`sshd` allows nothing else here.

## 4. A run

Every run starts from `clean`:

```bash
id=191
post /nodes/Saruman/qemu/$id/snapshot/clean/rollback
post /nodes/Saruman/qemu/$id/status/start
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
- **Windows:** `ssh tester@10.0.30.98`, then:

  ```powershell
  winget install --accept-source-agreements --accept-package-agreements Git.Git Microsoft.PowerShell
  ```

  Open a new session, so the new `PATH` is read, and then:

  ```powershell
  git clone https://github.com/dotgibson/dotfiles-Windows $HOME\dotfiles-Windows
  cd $HOME\dotfiles-Windows; winget configure -f configuration.dsc.yaml --accept-configuration-agreements
  pwsh -NoProfile -File .\bootstrap.ps1
  ```

  Then run the layer's doctor in a new `pwsh`.

  **The guest is unactivated (ADR-0090 §6).** A step that fails on a
  Personalization setting is that, not a dotfiles bug. **If `winget` will
  not run over SSH,** use the console in the Proxmox UI as `tester`. Its
  password is not known, so reset it from the `Administrator` session first.
  That is a run-time change, and the rollback discards it.

To test a release rather than `main`, clone with `--branch <tag>`.

**Read the result.** A good run leaves:

- `bootstrap.sh` exiting 0;
- `core doctor` reporting no failures.

Anything else goes on the layer's own repository as an issue, with the
guest, the template's build date (in the template's description) and the
output. Then shut down:

```bash
post /nodes/Saruman/qemu/$id/status/shutdown
```

The guest is left stopped at whatever state the run reached. The next run
rolls back first, so it does not matter.

## 5. Rebuild

When a template is rebuilt (`build-the-lab-templates.md` §8), its guests still
hold the old install, because every clone is full. Re-clone one:

```bash
tofu -chdir=tofu apply -replace='module.guest["dot-debian"].proxmox_virtual_environment_vm.this'
```

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
