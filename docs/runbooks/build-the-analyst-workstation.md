# Runbook: Build `garuda`, the analyst workstation

**Target:** `garuda`, a Kali Purple guest on `Saruman` on ImaginationLAN
(VLAN 30), running [`stacks/analyst`](../../stacks/analyst) and the
[`dotfiles-Defense`](https://github.com/dotgibson/dotfiles-Defense) layer.

**Time:** an evening. The template build is about an hour of waiting. The
clone takes minutes, and Purple's tools are one long `apt`.

**You will need:**

- `phoenix`, for Packer and OpenTofu
- root on `Saruman`
- `morpheus`'s UI, for the reservation
- `alexander`, for the ingest token
- `Hicks`, for the desktop

**Before this:** the SOC on `odin`, and the lab stack on `alexander`. Both are
live.

This builds what
[ADR-0091](../adr/0091-put-a-kali-purple-analyst-workstation-on-saruman.md)
decided for [#921](https://github.com/Gerrrt/HomeLab/issues/921): a
defender's seat beside the SOC, not a second SOC. It follows
[`build-the-bloodhound-guest.md`](build-the-bloodhound-guest.md). Where a step
is the same, this runbook points there and does not keep a second copy that
drifts.

**Not here, and each is a change of its own on #921:**

- OpenVAS, with its scope and its silence;
- TheHive.

Enrolling `garuda` in Wazuh and Velociraptor is §12, phase 2.

---

## 0. What is decided, and why

| | Decision | Why this and not the obvious alternative |
| --- | --- | --- |
| Name | `garuda` | Continues the segment's summons |
| Address | `10.0.30.62/24` | Every `.x0` is taken. It sits in `odin`'s decade, beside the SOC it works from, as `diabolos` holds `.61` |
| VMID | `162` | The last octet, legible from `qm list` |
| Template | `910`, `tpl-kali-saruman` | `902` is `ifrit`'s, and a template belongs to one node (ADR-0091) |
| Declared in | `tofu/guests.tf`, pool `analyst` | Lab guests are OpenTofu's ([ADR-0076](../adr/0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md)) |
| Tags | `analyst`, **not** `on-demand` | Always on. `HypervisorGuestStopped` should find it stopped ([ADR-0079](../adr/0079-tag-on-demand-guests-and-leave-them-out-of-the-stopped-guest-alert.md)) |
| `onboot` | `1`, no startup order | Nothing waits for it, and it waits for nothing |
| vCPU / RAM | 4 / 8 GiB | A desktop, Wireshark on a capture, and Defense's `siemup` lab during an exercise |
| Disk | 80 GB on `large_data` | Captures, cases and scan results. The template's own disk is 64 |
| Domain | **Not joined** | The domain is the target and is reverted. A member would fall with it, notes and all (ADR-0091) |
| SIEM and sensors | **Off** | Wazuh, Zeek and Suricata already run. Their binaries stay, for offline work on a pcap; their daemons do not |
| Backup | **Yes**, `golem`'s nightly job | Its case notes are not in git |
| Login user | `analyst` | Not `operator`: Debian ships a system group of that name, which broke cloud-init on the dotfiles VMs |

## 1. Build template 910, from `phoenix`

[`build-the-lab-templates.md`](build-the-lab-templates.md) §5b. Prove it with
`scripts/packer-smoke.sh 910` before cloning it.

## 2. Reserve the address, and check the room

1. **On `morpheus`:** *Services → DHCP Server → ImaginationLAN*. Reserve
   `10.0.30.62` for the MAC in `tofu/guests.tf`'s `analyst` map. Do this
   before the first boot: below `.100`, the reservation is what gives a guest
   its address.
2. **On `Saruman`:** check `large_data`, as
   [`build-the-bloodhound-guest.md`](build-the-bloodhound-guest.md) §1 does.
   This guest adds 80 GiB to the thin allocation.

   ```bash
   pvesm status | grep -E 'large_data|local-lvm'
   lvs --noheadings --units g -o lv_size,pool_lv large_data \
     | awk '$2=="large_data"{s+=$1} END{print s " GiB allocated"}'
   free -g
   ```

   **If the written figure is past half, stop and ask why** before adding
   anything. Do not quietly move the disk to `local-lvm` instead. That is a
   decision for ADR-0091, not for a build night.
3. **Grant the pool.** Give `/pool/analyst` its grant as root on `Saruman`
   ([`provision-lab-guests.md`](provision-lab-guests.md) §2).

## 3. Create it, from `phoenix`

[`provision-lab-guests.md`](provision-lab-guests.md) §4, targeted:

```bash
umask 077
tofu -chdir=tofu plan -target='module.guest["garuda"]' -out=garuda.plan
tofu -chdir=tofu apply garuda.plan
```

The plan must add `garuda` and the `analyst` pool, and nothing else. A
`must be replaced` anywhere is a stop.

Check what was made:

```bash
api /nodes/Saruman/qemu/162/config | jq -c '.data | {name, tags, net0, onboot, efidisk0, memory, cores}'
```

It must show:

- `tags` as `analyst`
- `onboot` as `1`
- `efidisk0` with `pre-enrolled-keys=0`

Then, on `Saruman` as root, check that `qm config 162` shows no `startup` line.
This guest takes none.

## 4. First boot

The apply starts the guest, so cloud-init is already doing its first-boot
work: the user, the key, the host keys and the machine-id.

```bash
ssh analyst@10.0.30.62 'hostname; ip -br addr; id; systemctl is-active qemu-guest-agent'
```

Expect `garuda`, `10.0.30.62/24` on `eth0`, and `active`. If the address is not
`.62`, the reservation in §2 is wrong. Fix it there, not on the guest.

**If the login is refused,** check cloud-init through the agent before
anything else:

```bash
qm guest exec 162 -- cloud-init status
```

`not started` (with the hostname still `tpl-kali-saruman`) was
[#1127](https://github.com/Gerrrt/HomeLab/issues/1127): on a first boot,
cloud-init's generator could be cut off before it enabled
`cloud-init.target`. A template 910 built from `packer/kali.pkr.hcl` since
the fix for #1127 enables that target itself and masks the sslh generator that
aborted beside it, so a clone of it should not show this. On an older 910,
`qm reboot 162` once, and cloud-init runs. **Pin the host key only after
`cloud-init status` says `done`.** The first boot's sshd made keys of its own,
and cloud-init replaces them. Read the key through the agent
(`qm guest exec 162 -- cat /etc/ssh/ssh_host_ed25519_key.pub`), not on first
use.

**`/` should be about 79 GB of the 80.** A 910 built before
[#1128](https://github.com/Gerrrt/HomeLab/issues/1128)'s fix put its swap
partition after `/`, so growpart could not reach the clone's extra 16 GB, and
`/` stopped at about 60. A 910 built since lays out the ESP and then `/` to the
end of the disk, with no swap partition, and growpart takes the rest. On a
clone of an older 910, §11 has the in-place fix as run on 2026-10-10: snapshot
the guest, stopped, before using it. There is no swap unless one is added; a
4 GB `/swapfile`, as §11 made, suits an 8 GiB desktop.

**Give `analyst` a console password.** cloud-init made the account key-only,
which is enough for SSH but not for the desktop's login screen in §9. Set it
over SSH, at the prompt, never as an argument: a password on a command line
lands in shell history and process listings. Keep it in Garrett's password
manager, not in this repository or in OpenTofu's state:

```bash
ssh -t analyst@10.0.30.62 sudo passwd analyst
```

## 5. Kali Purple, without its SOC

On `garuda`:

```bash
sudo apt-get update && sudo apt-get -y full-upgrade
```

**Confirm the names first.** Kali is rolling, so check each package below with
`apt-cache policy <name>` before installing it, and correct this section if one
has moved.

**The desktop and the Purple theme:**

```bash
sudo apt-get -y install kali-desktop-xfce kali-themes-purple
```

**The analyst's tools.** These are host tools, not services:

```bash
echo 'wireshark-common wireshark-common/install-setuid boolean true' | sudo debconf-set-selections
sudo apt-get -y install cyberchef wireshark tshark jq yara \
  docker.io docker-compose suricata
sudo usermod -aG docker,wireshark analyst
```

The `debconf` line answers Wireshark's install question so that members of
`wireshark` may capture without root. **No `zeek`:** Kali's package (5.1.1 on
2026-10-10) depends on `libc6 (< 2.38)`, which Kali Rolling no longer has, and
one uninstallable name makes `apt` refuse the whole line. Zeek on `fenrir` is
the sensor. For offline work on a capture, run the `zeek/zeek` image pinned in
`stacks/sensor` against the file.

**Log out and reconnect** before going on. `usermod` does not change the
groups of a session that is already open, and §6's `make up` needs the
`docker` group:

```bash
exit
ssh analyst@10.0.30.62 id    # must list docker and wireshark
```

**Not Purple's tool metapackages** (`kali-tools-detect`, `-respond` and the
rest), and **no Elastic.** Those metapackages bring in the SOC that ADR-0091
leaves out. Add a single tool by name when it earns a place, and add it to the
list above.

**Turn the sensors' daemons off.** `suricata` is installed for offline work
on a capture (`suricata -r`), which is what `dotfiles-Defense` uses it for,
as it would `zeek` if Kali's package installed. They must never listen on the segment, where
they would duplicate `fenrir` and `morpheus`:

```bash
for u in suricata zeek; do sudo systemctl disable --now "$u" 2>/dev/null; done
systemctl list-unit-files | grep -Ei 'suricata|zeek|elastic|kibana|wazuh' || echo none
```

Every line printed must say `disabled`, or not exist. Record the output in §11.

## 6. Its token at the lab's ingest proxy, and its stack

`garuda`'s Alloy pushes to `alexander` with a token of its own
([#834](https://github.com/Gerrrt/HomeLab/issues/834)).
[`build-the-bloodhound-guest.md`](build-the-bloodhound-guest.md) §5 is the
procedure, with `GARUDA` for `EDEN`, `garuda agent` in the Caddyfile and
`STACK=analyst`.

1. **On `alexander`:** `openssl rand -hex 32`, then
   `make secrets-edit STACK=lab` to add it as `INGEST_TOKEN_GARUDA`.
2. **On `garuda`:** first `age` and `sops`. Kali packages `age`, but not
   `sops`, so take `sops`'s release binary at `alexander`'s version, as
   [`build-the-bloodhound-guest.md`](build-the-bloodhound-guest.md) §3 does
   (3.9.4 on 2026-10-10):

   ```bash
   sudo apt-get -y install age
   V=3.9.4
   curl -fsSLO https://github.com/getsops/sops/releases/download/v$V/sops-v$V.linux.amd64
   curl -fsSL https://github.com/getsops/sops/releases/download/v$V/sops-v$V.checksums.txt \
     | grep " sops-v$V.linux.amd64$" | sha256sum -c -
   sudo install -m 0755 sops-v$V.linux.amd64 /usr/local/bin/sops
   ```

   Then, as `analyst`:

   ```bash
   git clone https://github.com/Gerrrt/HomeLab ~/code/Gerrrt/HomeLab && cd ~/code/Gerrrt/HomeLab
   make secrets-init STACK=analyst
   make secrets-edit STACK=analyst    # INGEST_TOKEN, the same value
   ```

   `secrets-init` replaces `REPLACE_WITH_ANALYST_AGE_PUBLIC_KEY` in the
   `analyst` rule of `.sops.yaml` with `garuda`'s key. The rule sits above the
   catch-all, so `garuda` can open its own file and nothing else. If the
   placeholder is gone, stop: the file would fall through to the estate's
   rule, and `garuda` could not decrypt it.
3. **One branch, one pull request,** holding:
   - the `analyst` rule, with `garuda`'s key in place of the placeholder;
   - `secrets/analyst.sops.yaml`;
   - `INGEST_TOKEN_GARUDA` in the five lab places eden's went:
     - the `ingest_auth` map and header comment in `stacks/lab/Caddyfile`
     - the `caddy` environment in `stacks/lab/compose.yaml`
     - `COMPOSE_VARS` in `scripts/render-config.sh`
     - `scripts/seed-validation-env.sh`
     - `secrets/lab.example.yaml`
   - `secrets/lab.sops.yaml`;
   - the client count in `stacks/lab/README.md`.

   `stacks/lab/compose.yaml` requires every token it names. If the name merges
   before the value is in `secrets/lab.sops.yaml`, `alexander`'s next render
   fails, which is why it all goes in together.
4. **Once merged:** run `make up STACK=lab` on `alexander`, then
   `make up STACK=analyst` on `garuda`:

   ```bash
   docker compose -f stacks/analyst/compose.yaml ps
   ```

   Both containers must be `healthy`. `make up` also creates the textfile
   directory (`scripts/ensure-textfile-dir.sh`).

## 7. `dotfiles-Debian`, then `dotfiles-Defense`

Defense is a role layer: it installs no packages and stacks on an OS layer.
On Kali that layer is `dotfiles-Debian`, which targets Kali rolling. Install
the OS layer first, as `analyst`, and take each repository at its **latest
release tag**, not `main`. Both live under `~/code/dotgibson/`, named as on
GitHub. Each bootstrap links from wherever it is cloned, so moving a clone
means re-running its bootstrap:

```bash
deb=$(gh api repos/dotgibson/dotfiles-Debian/releases/latest --jq .tag_name)
def=$(gh api repos/dotgibson/dotfiles-Defense/releases/latest --jq .tag_name)
echo "Debian $deb, Defense $def"    # into §11

mkdir -p ~/code/dotgibson
git clone --branch "$deb" https://github.com/dotgibson/dotfiles-Debian ~/code/dotgibson/dotfiles-Debian
cd ~/code/dotgibson/dotfiles-Debian && ./bootstrap.sh; echo "bootstrap exit $?"

git clone --branch "$def" https://github.com/dotgibson/dotfiles-Defense ~/code/dotgibson/dotfiles-Defense
cd ~/code/dotgibson/dotfiles-Defense && ./bootstrap.sh; echo "bootstrap exit $?"

exec zsh
core doctor; echo "doctor exit $?"
```

Without `gh` on the guest, read the two tags from the releases pages.

A good run is:

- both bootstraps exit 0;
- `core doctor` reports no failures;
- Defense's host-tool probe finds `docker compose`, and lists what it found
  missing.

Its missing list is expected to include `zeek` (§5) and the tools Kali does
not package: `chainsaw`, `hayabusa`, `sigma-cli`, `velociraptor`, `vol` and
`log2timeline.py`. Record that list in §11. A failure is filed on the layer's
own repository with the guest, template 910's build date and the output, as
[`test-the-dotfiles-layers.md`](test-the-dotfiles-layers.md) §4 does.

**`siemup` stays down.** Defense's Dockerized detection lab is for an
exercise, and goes down after it with `siemdown`. Left up, it is the second
SIEM ADR-0091 refuses.

**Cases live in `~/cases/`,** outside every repository, by Defense's own
rule. That directory is the reason this guest is backed up.

## 8. Collectors and backup

1. **Patch state.** From a checkout, as
   [`schedule-maintenance.md`](schedule-maintenance.md) does for the other
   lab guests:

   ```bash
   make install-agent-collectors AGENT=analyst@10.0.30.62 ARGS='--only patch-state'
   ```

2. **Backup.** On `Saruman`, add `162` to the `golem` job's selection
   (*Datacenter → Backup*, the job from
   [`build-the-backup-guest.md`](build-the-backup-guest.md) §8). Take one
   backup by hand and read that it is **encrypted**:

   ```bash
   vzdump 162 --storage golem --mode snapshot
   ```

   **If that snapshot hangs the guest,** as fs-freeze has hung `ramuh`, use
   `qm reset 162`. Then switch this guest to `--mode stop` in the job, and say
   so in §11.

## 9. Verify

Each line is a pass or a stop:

- **Address and name.** `ssh analyst@10.0.30.62 hostname` prints `garuda`.
- **Always on, and watched.** In the estate's Prometheus:
  - `homelab_guest_running{vmid="162"}` is `1`;
  - `homelab_guest_on_demand{vmid="162"}` is absent or `0`.
- **Telemetry.** In the lab's Grafana on `alexander`:
  - `up{job="garuda-alloy"}` is `1`;
  - `{hostname="garuda"}` in Loki has journal lines from the last five minutes.
- **No second SOC.** On `garuda`:
  - `docker ps --format '{{.Names}}'` prints exactly `analyst-alloy` and
    `analyst-docker-socket-proxy`;
  - `ss -lntup` shows no Suricata, Zeek or Elastic listener.
- **dotfiles.** §7's two bootstrap exits and the `core doctor` exit.
- **Desktop.** From `Hicks`, `garuda`'s console in Proxmox shows the Purple
  XFCE session. Wireshark opens a capture, and CyberChef opens.
- **Reboot.** `qm reboot 162`. Within five minutes, every line above passes
  again with nothing typed.

## 10. Write it down

In the same pull request as §6, or one after it:

- `docs/network.md` and `docs/architecture.md`: `garuda`'s status changes from
  *not built* to built, with the date.
- `stacks/analyst/README.md`: the status badge.
- `docs/changelog.md`: the build.
- #921: a comment with §11's results. #921 stays open for its later phases.

## 11. As run

**2026-10-10, phase 1** (§1–§5 and §7), from
[#1116](https://github.com/Gerrrt/HomeLab/pull/1116)'s branch on `phoenix`.
§6, §8 and §9's telemetry, backup and desktop lines are not run yet, nor is
the console password.

- **§1, template 910.** Built from a worktree of the branch, since the shared
  checkout stayed on `main`, with port 8800 free and nothing else building.
  - `packer validate`/`fmt -check` passed.
  - The first build took 26m25s and `packer-smoke.sh 910` passed (agent
    address, hostname `smoke-910`, SSH as `smoke`).
  - The `-force` rebuild took 26m11s and its smoke test passed again.
  - Both builds print `userdel: user packer is currently used by process …`.
    `-f` removes it anyway.
- **§2.** `.62` was reserved on `morpheus` by Garrett. `large_data` was 44.17%
  written. `/pool/analyst` was granted to `phoenix@pve` as `PhoenixBuilder`.
- **§3.** The worktree was initialised against the shared state
  (`-backend-config=path=…/HomeLab/tofu/state/lab.tfstate`). The plan
  targeted `module.guest["garuda"]` and the `analyst` pool: **2 to add, 0 to
  change, 0 to destroy**. The apply created 162 in 3m45s.
  - `qm config 162`: tag `analyst`, `onboot: 1`, no `startup`,
    `pre-enrolled-keys=0`, 4 cores, 8192 MiB, balloon 0.
- **§4.** The first boot came up **without cloud-init**: status `not
  started`, hostname `tpl-kali-saruman`, no `analyst`, so SSH was refused.
  - The generator's log stopped after `checking for datasource`, though
    `ds-identify` found NoCloud and returned 0. Filed as
    [#1127](https://github.com/Gerrrt/HomeLab/issues/1127).
  - `qm reboot 162` fixed it: the hostname became `garuda`, `analyst`
    (uid 1000, sudo) was created and cloud-init reported `done`.
  - The host key changed across the reboot. It was re-pinned on `phoenix`
    after the fingerprint read through the agent matched
    (`SHA256:pj4KrgprKwxNxkrm1ZTXjT6o8UVinYYoMx0RdaI97f4`).
  - SSH as `analyst`: `10.0.30.62/24` on `eth0`, agent `active`, Kali
    GNU/Linux Rolling.
  - `/` is 59.7 GB of the 80 GB disk. Filed as
    [#1128](https://github.com/Gerrrt/HomeLab/issues/1128).
- **§5.** Every name resolved with `apt-cache policy`, but `zeek` (5.1.1-0kali3)
  could not be installed (`libc6 (< 2.38)`), and `apt` refused the tools line
  for it. That line was re-run without it.
  - Installed: `kali-desktop-xfce` 2026.3.9 and `kali-themes-purple` 2026.3.0
    (430 packages), then 49 more:
    - CyberChef 11.3.0
    - Wireshark and tshark 4.6.6
    - Suricata 8.0.7
    - YARA 4.5.8
    - jq 1.8.2
    - Docker 28.5.2 with Compose 2.40.3
  - `dumpcap` is `root:wireshark` with `cap_net_admin,cap_net_raw`.
    `analyst` is in `docker` and `wireshark`.
  - `suricata.service` is `disabled`, and `zeek.service` does not exist.
    `ss -lntup` shows no Suricata, Zeek, Elastic, Kibana or Wazuh listener.
    `docker ps` is empty.
  - **A stale group list after `usermod`** came from `phoenix`'s SSH
    multiplexing (`ControlPersist 10m`), not from the guest. A connection with
    `-o ControlPath=none` showed both groups.
- **§7.** `dotfiles-Debian` **v0.1.59** and `dotfiles-Defense` **v1.0.132**,
  under `~/code/dotgibson/`, run as `analyst`.
  - Both `git clone`s warn `refs/tags/… is not a commit`. These are
    annotated tags, and the checkout is correct.
  - Debian `bootstrap.sh` exited **0**:
    - 35 linked, 3 seeded, 1 backed up, 1 relinked;
    - it used the Kali tier's capabilities;
    - it set zsh as the login shell and enabled `unattended-upgrades`
      (security pocket only).
  - Defense `bootstrap.sh` exited **0**: 32 linked and 29 relinked over
    Debian's Core links.
    - The host-tool probe found `zsh docker jq tshark suricata yara`, and
      `docker compose available`.
    - It reported **7 missing**: `zeek chainsaw hayabusa sigma-cli
      velociraptor vol log2timeline.py`.
  - `core doctor` (dotfiles-core 7.14.0) exited **0**, with **nothing
    expected missing**. All of modern CLI, integrations, data/net and
    dev/repo's expected tools are present, including `sesh`, `yq` and
    `doggo`, which `dot-debian` lacked. Thirteen opt-in tools are not
    installed, by design.
- **#1128, fixed in place on `garuda`** (the template is unchanged).
  - **Snapshot first.** `garuda` was stopped and snapshotted as `pre-1128`.
    Stopped, not live: an fs-freeze has hung guests here before.
  - **The fix.** As root:
    - `swapoff /dev/sda3`, then comment out its `fstab` line;
    - `sfdisk --delete /dev/sda 3`;
    - `growpart /dev/sda 2`, then `resize2fs /dev/sda2` online;
    - a 4 GB `/swapfile` in place of the 3.3 GB partition;
    - `RESUME=none`, then `update-initramfs -u`.
  - **After a reboot:**
    - `/` is 79 GB, with 52 GB free;
    - swap is `/swapfile` (4 GB);
    - cloud-init reports `done`;
    - SSH and `core doctor` work (exit 0).
  - **One failed unit, on every boot before and after the fix:**
    `user@968.service`, for `lightdm`.
    - The package creates that account with an expiry of 1970-01-02, so PAM
      refuses its user manager, and the system reads `degraded`.
    - `lightdm` itself is `active`.
    - §9's desktop check from Hicks decides whether it matters.
- **§6, 2026-10-10** ([#1144](https://github.com/Gerrrt/HomeLab/pull/1144)).
  - **garuda's tools:** `age` 1.3.2 from Kali, and `sops` 3.9.4's release
    binary (checksum OK) at `alexander`'s version. The repository is at
    `~/code/Gerrrt/HomeLab`.
  - **garuda's key:** `make secrets-init STACK=analyst` wrote
    `age1pd3d…u9c9v` over the placeholder.
  - **The token:** one token, generated on Saruman. It was set as
    `INGEST_TOKEN_GARUDA` on `alexander` and `INGEST_TOKEN` on `garuda`
    through `make secrets-edit`, with `SECRETS_EDITOR` pointed at a script
    that takes the key and value from the environment. The value came in on
    each host's stdin and was never an argument. The two SHA-256s matched.
    The editor scripts were deleted afterwards.
  - **After the merge:** `alexander` went from 30 commits behind to `main`.
    The only other change that reached its lab stack was #1080's
    `syslog.alloy`, which the lab Alloy does not mount. `make up STACK=lab`
    left every container healthy, with no 401s at the proxy. On `garuda`,
    `make up STACK=analyst` passed both health checks.
- **§8, 2026-10-10.**
  - **patch-state:** installed from `phoenix`, timer enabled,
    `homelab_apt_upgrades_pending{host="garuda"} 0` in the lab's
    Prometheus.
  - **Backup:** `162` joined `golem-nightly` beside `160`. That job held only
    `odin`; the domain's six were already out of it, and were left so.
    - The test `vzdump 162 --mode snapshot` ran to `golem` in 9m03s,
      encrypted, with 60 of 80 GB sparse.
    - The guest-agent fs-freeze and thaw both went through, and the agent
      answered afterwards.
- **§9, 2026-10-10.** Every line passed, except the desktop:
  - `garuda` at `10.0.30.62`.
  - **Watched by the estate:** `homelab_guest_running` is 1 and
    `homelab_guest_on_demand` is 0, from Saruman's guest-state collector.
  - **Lab Prometheus:** `up{job="garuda-alloy"}` and
    `up{job="garuda-metrics"}` are both 1.
  - **Lab Loki:** `{hostname="garuda"}` has journal lines.
  - **No second SOC:** `docker ps` shows exactly `analyst-alloy` and
    `analyst-docker-socket-proxy`. The only off-loopback listener is SSH on
    22; Alloy's 12345 is on loopback, and there are no sensor listeners.
  - `core doctor` exited 0.
  - **Reboot:** `qm reboot 162` brought the agent back in 41s. After about
    2.5 minutes everything above passed again with nothing typed, including
    500 journal lines in Loki over 3 minutes.
  - **Not run: the desktop line.** It needs the console from Hicks, and the
    console password Garrett sets at a prompt (§4). `user@968.service`
    (`lightdm`) still fails on every boot.
- **§12, phase 2, 2026-10-10**
  ([#1163](https://github.com/Gerrrt/HomeLab/pull/1163),
  [ADR-0092](../adr/0092-enrol-garuda-in-odins-soc-with-debian-packages-staged-on-odin.md)).
  - **`odin`:**
    - The checkout was pulled to `main`, and `make up STACK=soc` left all
      seven services healthy.
    - `stage-agent-msis.sh` ran as root through the guest agent, because
      `barnabas` has no passwordless sudo. It re-verified both MSIs, matched
      the Wazuh `.deb` to its pin, and built
      `velociraptor-client_0.77.3_amd64.deb` (sha256
      `b89a412865058fc6b3025b78791b59215bae087c445ffdd9dd0e05df4ef5b1cc`).
  - **Fetching.** `8448` answered `garuda` (200; it was 403 before the
    reload).
    - Both packages verified on `garuda`: the Wazuh one against the pin, the
      Velociraptor one against the hash read from `odin` over SSH.
  - **Wazuh.**
    - `dpkg -i` with `WAZUH_MANAGER`, `WAZUH_AGENT_NAME=garuda` and
      `WAZUH_AGENT_GROUP=default`, and no password.
    - The password, `LAB_WAZUH_REGISTRATION_PASSWORD` from `phoenix.env`, went
      into `authd.pass` on standard input. Its hash matched `odin`'s
      `authd.pass` before the agent started.
    - The agent logged "Valid key received" and connected to `1514`. `odin`
      listed it as **009, `garuda`, Active**.
    - `authd.pass` was then removed.
  - **Velociraptor.**
    - `dpkg -i` gave `velociraptor_client` enabled and active, with an
      established connection to `odin:8000`.
    - The server's `client_comms_current_connections` read 7 (the six and
      `garuda`), and `frontend_enroll_response` counted 1, `garuda`'s.
    - A `query` against `clients()` from a second process on the server
      returned nothing, and was not pursued. The GUI check from Hicks is
      Garrett's.
  - **The lab.** `alexander` was pulled to `main` (the rule change), and
    `make up STACK=lab` reloaded Prometheus.
    - `homelab_wazuh_agent_active{agent="garuda"}` first read 0: the
      collector had run six seconds after the agent connected. It read 1 at
      the next run.
    - `WazuhAgentsNotConnected` was briefly pending for `garuda`, then
      inactive.
  - **Cleanup.** The downloaded packages were deleted from `garuda`, since
    the Velociraptor `.deb` carries the enrolment nonce. Installed:
    `wazuh-agent 4.14.8-1` and `velociraptor-client 0.77.3`.
- **Agents.** `guest-exec` timed out on both `garuda` (162) and `phoenix`
  (170) after commands carrying non-ASCII text or heredocs.
  `scripts/qga-resync.py` fixed each at once. Keep agent commands ASCII, and
  prefer SSH from `phoenix` for anything with a heredoc.

## 12. Phase 2: enrol it in odin's SOC

[ADR-0092](../adr/0092-enrol-garuda-in-odins-soc-with-debian-packages-staged-on-odin.md):
the Wazuh agent and the Velociraptor client, as Debian packages staged on
`odin` and served on its `8448`, which answers `garuda` since then.

1. **On `odin`,** as `barnabas`, with the change merged:

   ```bash
   cd ~/code/Gerrrt/HomeLab && git pull --ff-only
   make up STACK=soc                  # reloads Caddy with garuda in the 8448 allowlist
   sudo scripts/stage-agent-msis.sh   # adds the two .debs beside the MSIs
   ```

   The script checks the Wazuh `.deb` against `stacks/soc/linux-agents.yaml`
   and prints the Velociraptor `.deb`'s sha256. Note that hash.

2. **On `garuda`,** fetch both from `8448` and check each one. The Wazuh hash
   is the pin; the Velociraptor hash is the one staging printed, read again
   from `odin` over SSH, not from the HTTP origin the file came from:

   ```bash
   d=$(mktemp -d) && cd "$d"
   curl -fsSO http://10.0.30.60:8448/wazuh-agent_4.14.8_amd64.deb
   curl -fsSO http://10.0.30.60:8448/velociraptor-client_0.77.3_amd64.deb
   echo "6ed202e211fd8c544d1906c9b94dcd4b503d1829eef7d0a82ce4bcf4a1688967  wazuh-agent_4.14.8_amd64.deb" | sha256sum -c -
   sha256sum velociraptor-client_0.77.3_amd64.deb   # must equal staging's hash
   ```

3. **The Wazuh agent.** Install it pointed at `odin`, without the password.
   Then write the password to the agent's `authd.pass` from standard input,
   never as an argument, and restart it so that it enrols. The password is
   `odin`'s `authd.pass`, the six's `LAB_WAZUH_REGISTRATION_PASSWORD`
   (`phoenix.env`):

   ```bash
   sudo WAZUH_MANAGER=10.0.30.60 WAZUH_AGENT_NAME=garuda WAZUH_AGENT_GROUP=default \
     dpkg -i wazuh-agent_4.14.8_amd64.deb
   sudo sh -c 'umask 027; cat > /var/ossec/etc/authd.pass && chgrp wazuh /var/ossec/etc/authd.pass'   # paste, Enter, Ctrl-D
   sudo systemctl enable --now wazuh-agent && sudo systemctl restart wazuh-agent
   ```

   Once `odin` lists it as Active, remove the file:
   `sudo rm /var/ossec/etc/authd.pass`. The agent keeps its own key in
   `client.keys`. A re-enrolment writes the file again.

4. **The Velociraptor client.** The package carries `odin`'s server URL, CA and
   nonce, and installs and starts its own service:

   ```bash
   sudo dpkg -i velociraptor-client_0.77.3_amd64.deb
   systemctl is-active velociraptor_client
   ```

5. **Check from `odin`:**
   - `docker exec soc-wazuh-manager /var/ossec/bin/agent_control -l` lists
     `garuda` as Active.
   - The Velociraptor GUI, from Hicks, lists a client with hostname `garuda`.
   - In the lab's Prometheus, `homelab_wazuh_agent_active{agent="garuda"}` is
     1 after the collector's next run, every five minutes.
     `WazuhAgentsNotConnected` now expects it while garuda's Alloy is up.

6. **Not tuned.** `local_rules.xml` is the domain's Windows rules, and garuda
   gets Wazuh's stock Linux ruleset. An analyst's own tools will make some
   noise. Tune it in `local_rules.xml` when it matters, not before.

## 13. Take it out

1. Run `siemdown` if it is up, and copy anything in `~/cases/` that is wanted.
2. On `phoenix`:

   ```bash
   tofu -chdir=tofu destroy -target='module.guest["garuda"]' \
     -target='proxmox_virtual_environment_pool.this["analyst"]'
   ```

   Both targets, because the pool is its own resource: destroying the guest
   alone leaves it. Destroying the pool deletes its grant with it
   ([`provision-lab-guests.md`](provision-lab-guests.md) §2), so a rebuild
   needs that grant again. Then remove `garuda` from `tofu/guests.tf`, or the
   next untargeted apply recreates both.
3. Remove these and their lines, in one pull request:
   - `162` from `golem`'s job
   - the `.62` reservation on `morpheus`
   - `INGEST_TOKEN_GARUDA` from `alexander`
   - `garuda`'s key in the `analyst` rule of `.sops.yaml`, back to the
     placeholder or the rule removed with the stack
4. Destroy template 910 only if nothing else clones it.
