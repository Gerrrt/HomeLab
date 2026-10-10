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

- enrolling `garuda` in Wazuh and Velociraptor;
- OpenVAS, with its scope and its silence;
- TheHive.

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
sudo apt-get -y install cyberchef wireshark tshark jq yara \
  docker.io docker-compose zeek suricata
sudo usermod -aG docker,wireshark analyst
```

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

**Turn the sensors' daemons off.** `zeek` and `suricata` are installed for
offline work on a capture (`zeek -r`, `suricata -r`), which is what
`dotfiles-Defense` uses them for. They must never listen on the segment, where
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
2. **On `garuda`:**

   ```bash
   git clone https://github.com/Gerrrt/HomeLab ~/HomeLab && cd ~/HomeLab
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
release tag**, not `main`:

```bash
deb=$(gh api repos/dotgibson/dotfiles-Debian/releases/latest --jq .tag_name)
def=$(gh api repos/dotgibson/dotfiles-Defense/releases/latest --jq .tag_name)
echo "Debian $deb, Defense $def"    # into §11

git clone --branch "$deb" https://github.com/dotgibson/dotfiles-Debian ~/dotfiles-Debian
cd ~/dotfiles-Debian && ./bootstrap.sh; echo "bootstrap exit $?"

git clone --branch "$def" https://github.com/dotgibson/dotfiles-Defense ~/dotfiles-Defense
cd ~/dotfiles-Defense && ./bootstrap.sh; echo "bootstrap exit $?"

exec zsh
core doctor; echo "doctor exit $?"
```

Without `gh` on the guest, read the two tags from the releases pages.

A good run is:

- both bootstraps exit 0;
- `core doctor` reports no failures;
- Defense's host-tool probe finds `docker compose`, and lists what it found
  missing.

Its missing list is expected to include tools Kali does not package:
`chainsaw`, `hayabusa`, `sigma-cli`, `velociraptor`, `vol` and
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

Not run yet.

## 12. Take it out

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
