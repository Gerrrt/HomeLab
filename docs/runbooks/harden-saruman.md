# Runbook: Close what `Saruman`'s installer and its history left open

**The hypervisor holds every lab guest. Its firewall is the only control
in front of a root password, and its apt sources trust vendors that the
host does not need.**

> **Status — 2026-11-14: written, and nothing applied yet.** A read-only
> audit of `Saruman` on 2026-11-13 found each item below. Every section ends
> with the check that proves it was applied.

`Saruman`'s Proxmox firewall admits `22`, `8006` and `8007` from Hicks and
`8006` from `phoenix`, and drops everything else
([ADR-0014](../adr/0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md),
[`network.md`](../network.md)). `PveFirewallDisabled` pages if it goes off.
Behind it, sshd still accepts root's password, and so does `8006`. A
workstation on Hicks, or the whole of VLAN 30 if the firewall stops, is one
guessed password from root on the host. `gandalf`
([`build-the-playground.md`](build-the-playground.md) §4) and `golem`
([`build-the-backup-guest.md`](build-the-backup-guest.md) §2) are both closed
the same way. This runbook does the same for `Saruman`.

## 0. Before you start

- **Have the console to hand.** `shiva`'s remote console is the way back if
  SSH locks you out. It needs root's password, which this runbook leaves set.
- **Root logs in by key from Hicks.** Every workstation that runs
  `deploy-agent.sh` or `install-agent-collectors.sh` against `Saruman` needs
  its key in `/root/.ssh/authorized_keys` before §1. Prove it from each one:

  ```bash
  ssh -o PasswordAuthentication=no root@10.0.30.20 true
  ```

  It must return with no password prompt.

## 1. SSH: keys only, no X11

Open a root shell on `Saruman` from Hicks with a key, and leave it open until
the checks pass. `sshd` keeps sessions that are already open, so this shell
is the way back. In it:

```bash
printf '%s\n' \
  '# harden-saruman.md §1: keys only. Root logs in by key, never by password.' \
  'PermitRootLogin prohibit-password' \
  'PasswordAuthentication no' \
  'KbdInteractiveAuthentication no' \
  'X11Forwarding no' \
  > /etc/ssh/sshd_config.d/10-keys-only.conf
sshd -t && systemctl reload ssh
sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|x11forwarding) '
```

**You should see** `permitrootlogin without-password`, `passwordauthentication
no`, `kbdinteractiveauthentication no` and `x11forwarding no`. The drop-in
wins over the main file's `PermitRootLogin yes` because `Include` comes first
in `sshd_config` and `sshd` keeps the first value it reads.

Then, from a second terminal on Hicks:

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password root@10.0.30.20 true
ssh -o PasswordAuthentication=no root@10.0.30.20 true
```

The first must fail with `Permission denied (publickey)` and no password
prompt. The second must succeed. If it fails, go back to the open shell,
remove the drop-in and run `systemctl reload ssh`.

## 2. A second factor on `root@pam`

`root@pam` on `8006` can do everything the host can. In the web UI:
*Datacenter → Permissions → Two Factor → Add → TOTP*, user `root@pam`. Then
add *Recovery Keys* for the same user, and keep them with root's password,
not in this repository.

API tokens do not take a second factor, so `phoenix`'s `builder` token is
unaffected. Neither are `qm` and `pvesh` from a root shell, or the console
login.

**Check:** log out, and log in again as `root@pam`. It must ask for the
code. If a phone is lost and the recovery keys with it, a root shell can
remove the factor: `pveum user tfa delete root@pam`.

## 3. One API token for `phoenix`, not two

[`build-the-jumpbox.md`](build-the-jumpbox.md) declares one token,
`phoenix@pve!builder`, and `tofu/` and Packer use it. `Saruman` also holds
`phoenix@pve!builder2`, with no expiry and privilege separation off, so it
carries all of `phoenix`'s rights. Nothing in this repository or its
history names it, nothing in the journal records its creation, and
`pveproxy`'s access logs show no request from it between 2026-10-12 and
2026-11-14. `builder` made hundreds in the same period.

```bash
pveum user token remove phoenix@pve builder2
pveum user token list phoenix@pve
```

**You should see** one row, `builder`. If something breaks afterwards, it
used the token. Record what it was before giving it a token of its own.

## 4. What the host runs, and the apt sources it trusts

This is what `Saruman` needs:

| Source | For |
| --- | --- |
| Debian `trixie`, `trixie-updates`, `trixie-security` | The base system |
| `download.proxmox.com` `pve-no-subscription` | Proxmox VE |
| `download.proxmox.com` `ceph-tentacle` `no-subscription` | `ceph-common` and `ceph-fuse`. `libpve-storage-perl` and `pve-qemu-kvm` depend on them, so they stay, even with no Ceph cluster |
| HPE `mcp` | `ssacli`, which reads the P440ar ([`fit-the-saruman-ssds.md`](fit-the-saruman-ssds.md)) |

Alloy, the native agent
([ADR-0020](../adr/0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)),
needs no source: `deploy-agent.sh` installs a pinned `.deb` from Grafana's
releases.

Anything else is a vendor running code as root on the host that holds every
guest. The audit found three:

- `1password.list`, for `1password-cli`;
- `charm.list`, for `glow` and `gum`;
- `pve-dbgsym.sources`, with no debug-symbol package installed from it.

It also found Debian listed twice in `debian.sources`, once from
`deb.debian.org` and once from `ftp.us.debian.org`.

```bash
apt-get purge 1password-cli glow gum
rm /etc/apt/sources.list.d/1password.list /etc/apt/sources.list.d/charm.list \
   /etc/apt/sources.list.d/pve-dbgsym.sources \
   /etc/apt/keyrings/1password.gpg /etc/apt/keyrings/charm.gpg
```

Edit `/etc/apt/sources.list.d/debian.sources` so that each suite appears once,
from `deb.debian.org`. Then:

```bash
apt-get update && ls /etc/apt/sources.list.d/
```

**You should see** `apt-get update` finish with no warning about duplicate
targets, and only `ceph.sources`, `debian.sources`, `hpe-mcp.list` and
`proxmox.sources`.

## 5. `rpcbind` off

The ISO store is mounted over NFSv4.2
([ADR-0072](../adr/0072-put-the-iso-store-on-smaug-over-nfs-to-saruman-alone.md)),
and NFSv4 needs no portmapper on the client. Proxmox's NFS check queries
`smaug`'s portmapper, not this host's. `rpcbind` listens on `111` on every
address anyway. The firewall drops it, but nothing on the host needs it.

```bash
systemctl disable --now rpcbind.socket rpcbind.service
```

**Check:** reboot in a maintenance window, then `findmnt -t nfs4` shows the
ISO share, `pvesm status` shows its storage `active`, and `ss -tlnp | grep
:111` prints nothing.

## 6. Leftovers in `/root`, and old kernels

The audit found these in `/root`, none of them in use:

- `ca.pem`, `ca-key.pem`, `cert.pem` and `cert-key.pem` from 2025-09-14: a
  self-made CA and its leaf. `pveproxy` serves the Proxmox CA's certificate.
- The `pveproxy-ssl.*` copies that
  [`build-the-lab-templates.md`](build-the-lab-templates.md) makes.
- `cluster.fw.new`, which is identical to the live firewall file.

Read each one before you delete it. Keep `pre-421-s3/` only if it is still
wanted.

Five removed kernels left `rc` packages behind. One more,
`proxmox-kernel-6.8.12-9-pve-signed`, is still installed, and
`proxmox-boot-tool kernel list` does not select it:

```bash
apt-get purge proxmox-kernel-6.8.12-9-pve-signed
dpkg -l | awk '/^rc/ && /proxmox-kernel/ {print $2}' | xargs -r apt-get purge -y
proxmox-boot-tool refresh
```

**Check:** `dpkg -l | grep -c '^rc'` counts no kernels, and `ls /boot` holds
only kernels in `proxmox-boot-tool kernel list`.

## 7. Write down what is now true

Record each applied section in [`changelog.md`](../changelog.md) on the day,
with what its check printed, and update this runbook's status line.
