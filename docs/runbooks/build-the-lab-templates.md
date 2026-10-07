# Runbook: Build the lab's VM templates with Packer, from `phoenix`

**Target:** templates 901, 911 and 912 on `Saruman`, built from `phoenix`
through the Proxmox API. 902, Kali, is written here and built on `ifrit` once
that host exists.

**Time:** an evening the first time, most of it Windows Setup running
unattended. After that, a rebuild is one command per template and about forty
minutes of waiting for each Windows one.

**You will need:**

- a shell on `phoenix` as the user that owns `~/.config/proxmox/phoenix.env`;
- a root shell on `Saruman`, for §2 and §2b only;
- the installer ISOs that [`build-the-lab-domain.md`](build-the-lab-domain.md)
  §1 uploaded to `local:iso/`, which §2b copies onto `smaug-iso` and lists:
  `windows-server-2025-eval.iso`, the VirtIO disc, and the Ubuntu 26.04
  live-server ISO. Windows 11 is downloaded again as 26H2, because the
  March ISO's hash is no longer published;
- a machine that can SSH to `Saruman` as root, for §2b's install of the daily
  checksum run. `phoenix` cannot.

**Before this:** `phoenix`, built by
[`build-the-jumpbox.md`](build-the-jumpbox.md), with the token from its §4
working.

**After this:** [`LabWindowsEvaluationExpiring`](../../stacks/lab/prometheus/rules/lab.rules.yaml)
has an answer that is a command (§8), and #445's OpenTofu has templates to
clone.

This builds what
[ADR-0074](../adr/0074-build-the-lab-templates-with-packer-from-phoenix.md)
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

The release CI lints with, and nothing newer: `packer/versions.pkr.hcl` requires
`~> 1.16.0`, and HashiCorp's apt repository would install whatever is newest on
the day (ADR-0074). Take the `linux_amd64` zip and check it against the
`SHA256SUMS` published beside it, as `provision-lab-guests.md` §1 does for tofu:

```bash
sudo apt-get install -y curl jq unzip xorriso
V=1.16.1   # the tag compose.yaml pins for packer
cd /tmp \
  && curl -fsSLO "https://releases.hashicorp.com/packer/${V}/packer_${V}_linux_amd64.zip" \
  && curl -fsSLO "https://releases.hashicorp.com/packer/${V}/packer_${V}_SHA256SUMS" \
  && grep " packer_${V}_linux_amd64.zip$" "packer_${V}_SHA256SUMS" | sha256sum -c - \
  && unzip -o "packer_${V}_linux_amd64.zip" packer \
  && sudo install -m 755 packer /usr/local/bin/packer \
  && packer version
```

One chain, so a failed download or a checksum that does not match stops it
before anything is unpacked or installed.

- **`xorriso`** builds the answer discs. Without it Packer fails with "could
  not find a supported CD ISO creation command" after it has already created
  the VM.
- **`jq`** is for `scripts/packer-smoke.sh` in §6.
- **If `packer` came from apt before**, remove it and its repository, or the
  next `apt upgrade` puts a second, unpinned binary on `PATH`:
  `sudo apt-get remove -y packer && sudo rm -f /etc/apt/sources.list.d/hashicorp.list /usr/share/keyrings/hashicorp.gpg`.
  Then `command -v packer` should print `/usr/local/bin/packer`.
- **A bump** starts with Dependabot moving the `packer` image in
  `stacks/observability/compose.yaml`. `required_version` and `V=` above move
  in the same PR; a new minor release fails `packer init` until they do.

Then fetch the plugin `packer/versions.pkr.hcl` pins:

```bash
cd ~/code/Gerrrt/HomeLab && git pull && packer init packer/
```

## 2. What the token is missing, on `Saruman`

`PhoenixBuilder` as `build-the-jumpbox.md` §4 made it reaches `local` and
`local-lvm`, and every guest disk here is on `large_data`. Packer also asks the
guest agent for the address, which Proxmox VE 9 gates behind a privilege of
its own:

```bash
pveum acl modify /storage/large_data --users phoenix@pve --roles PhoenixBuilder
pveum role modify PhoenixBuilder --append 1 --privs "VM.GuestAgent.Audit"
```

Packer uploads each build's answer disc to `local` and deletes it at the
end, and deleting a volume is `Datastore.Allocate`. That privilege also
deletes any volume and edits a storage's configuration, and `PhoenixBuilder`
is granted on `large_data`, where the domain's disks live. So it goes in a
role of its own, granted on `local` alone. Without it every build leaves its
answer disc behind, and the Windows one carries the build password (found
2026-10-02, when the first Ubuntu build could not clean up):

```bash
pveum role add PhoenixIsoCleanup --privs "Datastore.Allocate"
pveum acl modify /storage/local --users phoenix@pve --roles PhoenixIsoCleanup
pveum acl list | grep phoenix
```

**Then make `phoenix` verify the API's certificate.** Packer and
`scripts/packer-smoke.sh` both check TLS, because the token travels in a header,
and a guest on VLAN 30 answering for `10.0.30.110` would collect it otherwise.
The attack VM shares that segment.

**First, check what `Saruman` actually serves.** Its API certificate should
be the one signed by the cluster's own CA. If
`/etc/pve/local/pveproxy-ssl.pem` exists, `pveproxy` serves that custom
certificate instead, and on 2026-10-02 it did: a hand-made one from
September 2025, issued by OpenSSL's placeholder `Internet Widgits Pty Ltd`
and naming only `10.0.0.208`, the host's address before it moved. On
`Saruman`:

```bash
echo | openssl s_client -connect 10.0.30.110:8006 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName
```

The issuer must be `PVE Cluster Manager CA`, and the names must include
`10.0.30.110`. If either is wrong, keep a copy of any custom certificate,
regenerate the node's own from `/etc/hosts` (check the host's line there
first, because this reads it), and stop serving the custom one. Restarting
`pveproxy` drops open web-UI sessions and touches no guest:

```bash
cp -a /etc/pve/local/pveproxy-ssl.pem /etc/pve/local/pveproxy-ssl.key /root/ 2>/dev/null; pvecm updatecerts --force && pvenode cert delete && systemctl restart pveproxy
```

**Then trust the cluster CA on `phoenix`.** It is public, so copying it
carries no secret; only the key beside it in `/etc/pve` is secret. `phoenix`
cannot SSH to `Saruman`, so relay it from a workstation that reaches both:

```bash
ssh saruman cat /etc/pve/pve-root-ca.pem | ssh phoenix 'cat > ~/saruman-pve-root-ca.crt'
```

On `phoenix`, the subject must be the same `PVE Cluster Manager CA` the
`s_client` line printed as issuer. Then install it and prove it with no
`-k`:

```bash
openssl x509 -in ~/saruman-pve-root-ca.crt -noout -subject -enddate
sudo install -m 0644 ~/saruman-pve-root-ca.crt /usr/local/share/ca-certificates/saruman-pve-root-ca.crt && sudo update-ca-certificates && rm -f ~/saruman-pve-root-ca.crt
set -a; . ~/.config/proxmox/phoenix.env; set +a
curl -fsS -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "${PROXMOX_URL}/version"
```

A version, not `SSL certificate problem`. **Check this before a build, not
during one.** Packer checks the name before the chain, so a host serving the
wrong certificate *and* a `phoenix` without the CA shows only the name error,
and the second problem appears after the first is fixed.

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
| `Datastore.Allocate` (`PhoenixIsoCleanup`, its own role) | `/storage/local` | deleting the answer disc a build uploaded. Not added to `PhoenixBuilder`, which would grant it on `large_data` too |
| `Datastore.Audit` (`PVEAuditor`, read-only) | `/storage/smaug-iso` | attaching the installers from the ISO store, §2b step 5 |

## 2b. The installers, on `smaug-iso`, on `Saruman`

`packer/variables.pkr.hcl` names the installers on `smaug-iso`, the ISO store
[ADR-0072](../adr/0072-put-the-iso-store-on-smaug-over-nfs-to-saruman-alone.md)
put on `erebor/iso`, and not on `local`. Kali is the exception: it builds on
`ifrit`, which the store does not admit. The store's export trusts an
address, and Packer does not check an ISO it is handed from storage, so every
file on it is hashed once a day against the list in
[`scripts/collect-iso-store-state.sh`](../../scripts/collect-iso-store-state.sh),
and `IsoChecksumMismatch` pages if one changes. A build from the store is only
as trustworthy as that list, so the list is written here, once, with care.

1. **Copy them onto the share**, as root on `Saruman`. They were uploaded to
   `local` for `build-the-lab-domain.md` §1, and the copies there stay until a
   build from the store has worked:

   ```bash
   cd /var/lib/vz/template/iso && cp -n ubuntu-26.04.1-live-server-amd64.iso windows-server-2025-eval.iso /mnt/smaug-iso/template/iso/
   ```

   **Windows 11 is not copied, it is downloaded again.** The `windows-11.iso`
   on `local` is from March 2026, an earlier release whose hash Microsoft no
   longer publishes, so nothing outside this estate can vouch for it. Take
   the current English 64-bit ISO from Microsoft's Windows 11 download page
   in a browser. Upload it through the Proxmox UI to **`smaug-iso`**, then
   rename it on `Saruman` to the name the list and Packer use:

   ```bash
   cd /mnt/smaug-iso/template/iso && mv -n Win11_*English_x64*.iso windows-11-26h2.iso && sha256sum windows-11-26h2.iso
   ```

   The templates then carry a newer Windows than `carbuncle` and `siren`,
   which were built from the March ISO. That is expected, and it resolves
   when #448 rebuilds them from the templates.

   The VirtIO disc is already there as `virtio-win-0.1.302.iso`, from
   `build-the-nas.md` §5b's test upload. If `local` holds a `virtio-win.iso`,
   compare the two with `sha256sum`. If they differ, the domain was built with
   another driver version, and that is worth knowing before the templates
   change it.

2. **Hash them, and check each hash against its publisher.** On `Saruman`:

   ```bash
   cd /mnt/smaug-iso/template/iso && sha256sum -- *.iso
   ```

   | ISO | Check against |
   | --- | --- |
   | `ubuntu-26.04.1-live-server-amd64.iso` | `SHA256SUMS` beside it on `releases.ubuntu.com`, signed by Ubuntu's CD image key |
   | `virtio-win-0.1.302.iso` | Fedora publishes no ISO hash, only MD5s of its RPMs. Download the same ISO from `fedorapeople.org` over HTTPS **on another host**, hash it there, and compare. That vouches for the copy through a second network path |
   | `windows-11-26h2.iso` | The SHA-256 table on Microsoft's Windows 11 download page, English 64-bit. The list carries Microsoft's value itself, so a download that differs reads `mismatch` |
   | `windows-server-2025-eval.iso` | Microsoft publishes none for the evaluation media. Compare it with the copy on `local`, and record that it is trusted from its download, not from a published hash |

   **A hash that disagrees with its source does not go in the list.**
   Download the ISO again instead. Each line's comment in the list names
   what it was checked against, so the next reader knows how much to trust
   it. Where nothing outside this estate can vouch for a file, as with the
   evaluation media, the comment says that too.

3. **Write the list** into `EXPECTED` in
   `scripts/collect-iso-store-state.sh`, `sha256sum`'s own format, one line
   per ISO. Its self-test refuses a malformed line, and CI runs it. Commit it.

4. **Install the check**, from a machine that can SSH to `Saruman` as root.
   `phoenix` cannot:

   ```bash
   make install-agent-collectors AGENT=root@10.0.30.110 ARGS='--only iso-store-state'
   ```

   The installer starts one run straight away. That run reads every ISO, so
   it takes minutes, and the `.prom` appears when it finishes. Then:

   ```bash
   cat /var/lib/node_exporter/textfile_collector/iso-store-state.prom
   ```

   `homelab_iso_store_mounted` must be `1`, and every ISO must say
   `state="match"`. Any `unlisted` file is one step 3 missed.

5. **Let `phoenix` read the store, and nothing more.** Attaching an ISO needs
   `Datastore.Audit` on its storage. `PVEAuditor` carries that and no write
   privilege, so the only way onto the store stays root on `Saruman`:

   ```bash
   pveum acl modify /storage/smaug-iso --users phoenix@pve --roles PVEAuditor && pveum acl list | grep smaug-iso
   ```

6. **After the first build from the store works (§4),** remove the
   installers from `local`, the March `windows-11.iso` included. Two copies
   of an installer are two things to keep identical, and only one of them is
   checked. If an earlier copy put `windows-11.iso` on the share too, delete
   it there now: it is not on the list, so it reads `unlisted`.

**Changing an ISO later** is all six steps for that file, in the same
order: copy, hash, check it against its source, list, reinstall, build. What
the daily check says before the list is updated depends on the file's name:

- **A new name**, such as a new version, reads `unlisted`, and the name it
  replaces reads `missing`. Both are `IsoStoreUnexpected`, a warning.
- **The same name, overwritten**, reads `mismatch`, and `IsoChecksumMismatch`
  pages, critical. A deliberate replacement under the old name looks
  exactly like a tampered one, and that is intended. Put new versions under
  new names, as the four here are, and this case is only ever tampering.

## 3. The build password, on `phoenix`

The Windows builds log in as the built-in Administrator to provision, and a
clone boots with the same password until
[`ansible/`](../../ansible/README.md)'s `base` role rotates it. Nothing outside
the console can use it in the meantime: a clone's only way in is OpenSSH,
key-only, admitting `phoenix` alone ([ADR-0077](../adr/0077-configure-the-lab-domain-with-ansible-from-phoenix.md)).
Add it to the file that already holds the token:

```bash
umask 077
printf 'PKR_VAR_build_password=%s\n' "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"'Aa1!' \
  >> ~/.config/proxmox/phoenix.env
```

`packer/variables.pkr.hcl` refuses one shorter than 14 characters or holding
any of `< > & " '`, because it is pasted verbatim into two XML answer files.
Every build validates every variable, so the Linux builds need it set too.

## 4. Build

```bash
cd ~/code/Gerrrt/HomeLab
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
2. Grant `PhoenixBuilder` on `ifrit`'s storage and bridge, and trust
   `ifrit`'s CA on `phoenix`, as §2 did for `Saruman`. Unless `ifrit` joins
   `Saruman` in a cluster, it is its own API. Point `PROXMOX_URL` at it for
   this build, and admit `phoenix` to its 8006 the way ADR-0043 did on
   `Saruman`.
3. Build, naming the ISO actually on `ifrit` and **its** storage.
   `disk_storage` defaults to `large_data`, which is `Saruman`'s pool, and
   the disk creation fails without the override:

   ```bash
   packer build -only='kali.*' \
     -var kali_iso_file=local:iso/<the iso> \
     -var disk_storage=<ifrit's guest storage> \
     packer/
   ```

4. Prove it on `ifrit`, as §6 does on `Saruman`:

   ```bash
   PROXMOX_NODE=ifrit scripts/packer-smoke.sh 902
   ```

   Then run §8's second `-force` build and smoke test, which is #790's
   acceptance.

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

A Windows clone runs specialize and OOBE first. Its guest agent is disabled in
the template, and `SetupComplete.cmd` starts it as its last step, so the
agent's first answer means first-boot setup has finished. Allow ten minutes.
The script then SSHes in as `Administrator` with `phoenix`'s key, because that
is how [`ansible/`](../../ansible/README.md) reaches every guest
([ADR-0077](../adr/0077-configure-the-lab-domain-with-ansible-from-phoenix.md)).
A Windows 11 build that fails this has usually failed to fetch the OpenSSH
capability over the build's egress; `openssh.ps1` throws in that case. Its
hostname is sysprep's random one, because `ansible/` sets the real name.

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
them, the `smaug-iso` ACL from §2b, and `PKR_VAR_build_password` from
`phoenix.env`. The ISOs and their daily check stay: the store is ADR-0072's,
not this runbook's.
