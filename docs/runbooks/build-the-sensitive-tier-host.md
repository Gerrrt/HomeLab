# Runbook: Build `trinity`, the host that runs `stacks/sensitive`

**Target:** the HP ProDesk 600 G4 Micro, `trinity`, at `10.0.99.40` on
Winterfell (VLAN 99)
**Time:** an evening for §§1–9; the first logins and the forwarder are a
second sitting
**You will need:**

- A monitor and keyboard on the box for §§1–3.
- An Ubuntu Server 26.04 LTS installer stick.
- The 2 TB USB drive.
- A shell on `prometheus` with this repository's main checkout.
- The pfSense UI from Hicks.
- Your password manager, for four new entries: the root disk's recovery
  passphrase, the photo disk's recovery passphrase, the BIOS password and your
  login on the box.

This is [#404](https://github.com/Gerrrt/HomeLab/issues/404)'s procedure, and
it leans on four others rather than repeating them:

- [`build-the-tier-ca.md`](build-the-tier-ca.md) for the CA.
- [`add-a-host-override.md`](add-a-host-override.md) for the names.
- [`forward-dns-to-adguard.md`](forward-dns-to-adguard.md) for the forwarder.
- [`restore-the-sensitive-tier.md`](restore-the-sensitive-tier.md) for the
  backup and its proof.

The stack's own README,
[`stacks/sensitive/README.md`](../../stacks/sensitive/README.md), is the
acceptance list. Its *What `make validate` still does not prove* section is
what §9 below proves on the real host.

> [!IMPORTANT]
> **The box arrives here from #92's rehearsal, not from the seller.** pfSense
> is on it, Windows is gone, and Secure Boot and legacy boot are both off.
> **The I226 card stays fitted** in the second M.2 slot
> ([`hardware.md`](../hardware.md)). Ubuntu sees it as `enp1s0`, and nothing
> here configures it: it is there so that the day `trinity` becomes the
> firewall is a straight-through restore
> ([ADR-0034](../adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md),
> [`restore-the-firewall.md`](restore-the-firewall.md) §3). Everything below
> overwrites the rehearsal.

## 0. What is decided, and why

| | | |
| --- | --- | --- |
| OS | Ubuntu Server 26.04 LTS | Newer than `prometheus` and `oracle` (24.04), and supported two years longer. It builds its initramfs with dracut, which is what lets §4 use `systemd-cryptenroll`. Docker publishes packages for it (`resolute`) |
| Address | `10.0.99.40/24`, static, plus a Kea reservation | Chosen on 2026-09-09 and already in the stack's `.env.example` as `DNS_BIND_ADDR` |
| Root disk | LUKS2 under LVM; the key enrolled in the TPM against PCR 7 by `systemd-cryptenroll`; the installer's passphrase kept as recovery | [ADR-0054](../adr/0054-encrypt-trinitys-disks-and-seal-the-root-key-to-the-tpm.md) |
| Photo disk | LUKS2 on the 2 TB USB drive, opened at boot by a keyfile on the root, plus a recovery passphrase | ADR-0054 |
| Immich's library | `/srv/immich`, the stack's `IMMICH_UPLOAD_LOCATION` default | [#132](https://github.com/Gerrrt/HomeLab/issues/132) |
| Secrets | `secrets/sensitive.sops.yaml`, encrypted to `trinity`'s own age key | The `sensitive` rule in `.sops.yaml` |
| CA | The tier's own root, minted on `prometheus`; only the bundle travels | [ADR-0037](../adr/0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md) |
| Telemetry | An Alloy agent, pushing to `10.0.99.20`, like `oracle` | The stack README |
| Wireless | Not configured | The box has an Intel Wireless-AC 9560 that pfSense had to be told to ignore. Linux drives it happily, which is exactly why netplan gets no Wi-Fi stanza |

**Who does what.** Anything that types a secret, answers a `sudo` prompt or
clicks in pfSense is the operator's. The rest can be done over SSH from
`prometheus` once §3 has authorised a key, including by a Claude Code session
there. Nothing in this runbook needs a secret to cross that SSH session.

## 1. Firmware, at the bench

Power on and press **F10**.

- **Advanced → Secure Boot Configuration:** Secure Boot **Enable**, legacy
  support **Disable**. HP asks for a four-digit confirmation code on the next
  boot, as it did during the rehearsal. Type it.
- **Security → TPM Embedded Security:** TPM device **Available**, TPM state
  **Enabled**. Do not clear it.
- **Advanced → Power-On Options → After Power Loss:** **Power On.** Without
  this, the box stays off after a power cut, and the TPM unlock in §4 saves
  nothing.
- **Security → Administrator Tools → Create BIOS Administrator Password.**
  Save it in the password manager. ADR-0054 relies on it: without it, anyone
  at the console can boot a signed live stick that measures the same PCR 7.
- Leave USB boot on for now. §2 needs it and turns it off at the end.

## 2. Install Ubuntu Server

**Unplug the 2 TB drive first.** The installer offers every disk it can see,
and that one is formatted in §5, not here.

- **Hostname `trinity`.** `render-config.sh` labels every metric and log line
  with it.
- **Your account is the first user, so uid `1000`.** Immich and Paperless-ngx
  run as `${RENDER_UID}`, the uid that runs `make up`. Nothing requires
  exactly 1000, but §5 chowns the library disk to whoever this is, so do not
  create a second login later and deploy from that one.
- **Static addressing on the onboard NIC** (`eno1`, the I219-LM). The
  installer defaults to DHCP, and on 2026-09-28 that default was kept by
  accident: Kea handed out `10.0.99.100`, the first address in the pool.
  Edit `eno1`, set IPv4 to *Manual*, and fill in:

  | | |
  | --- | --- |
  | Subnet | `10.0.99.0/24` |
  | Address | `10.0.99.40` |
  | Gateway | `10.0.99.1` |
  | Name servers | `10.0.99.1` — Unbound on the gateway ([ADR-0010](../adr/0010-keep-the-resolver-on-the-gateway.md)) |
  | Search domains | `matrix.elysium` |

  Leave the wireless interface (`wlp0s20f3`) and the I226 (`enp1s0`)
  unconfigured. If the box came up on DHCP anyway, *If something goes wrong*
  has the fix.
- **Storage: custom is not needed.** Choose *Use an entire disk* on the
  512 GB Timetec NVMe, tick **Set up this disk as an LVM group** and **Encrypt
  the LVM group with LUKS**, and give it a passphrase generated in the
  password manager. That passphrase is the recovery key for the life of the
  box. Skip the recovery-key option the installer offers beside it, which
  writes a key file you would then have to find a home for.
- **Give `ubuntu-lv` the whole volume group.** On the storage summary, edit
  `ubuntu-lv` and set it to the maximum. The guided layout leaves half the
  volume group unallocated, and `build-the-lab-guest.md` §2 records what that
  cost last time.
- **Install OpenSSH server.** Import no keys here; §3 does it. Skip every
  snap the installer offers, Docker included. 26.04 installs `snapd` and two
  base snaps regardless, which is harmless.

When it asks you to remove the stick, go back into **F10**: **Advanced →
Boot Options**, untick USB storage boot, and leave the NVMe first. Rack the
box on a UPS-fed outlet and cable its onboard port into the unmanaged switch
on the U4 shelf. That switch hangs off `neo`'s port 3 and is untagged
Winterfell, like `prometheus` and `oracle`, so the switch needs no change.

## 3. First boot, the key, and the reservation

The first boot stops at the LUKS prompt. Type the passphrase once: §4 is
what makes this the last time.

From `prometheus`, in your own terminal:

```bash
ssh-copy-id <you>@10.0.99.40
ssh <you>@10.0.99.40 'hostname; id -u; ip -br link; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT; mokutil --sb-state; ls /sys/class/tpm'
```

Expect:

- `trinity` and `1000`.
- `eno1` UP.
- A `crypto_LUKS` partition on `nvme0n1` with the volume group inside it.
- `SecureBoot enabled`.
- `tpm0`.

Anything else stops the build here. A disabled Secure Boot makes §4's seal
meaningless, and a missing TPM makes it impossible.

**Tell networkd to leave the other two interfaces alone.** 26.04's dracut
leaves a catch-all, `zzzz-dracut-default.network`, that runs DHCP on every
interface netplan does not name. That is the I226 (`enp1s0`) and the Wi-Fi
(`wlp0s20f3`), so a cable in the wrong port would quietly take a lease:

```bash
printf '[Match]\nName=enp1s0 wlp0s20f3\n\n[Link]\nUnmanaged=yes\n' | sudo tee /etc/systemd/network/10-trinity-unmanaged.network
sudo networkctl reload
networkctl list
```

Both show `unmanaged`, and `eno1` shows `configured`.

**The Kea reservation.** On `morpheus`: *Services → DHCP Server →
WINTERFELL*, add a static mapping with `eno1`'s MAC (the line above prints
it), `10.0.99.40`, hostname `trinity`, and description "Sensitive tier —
ADR-0034". The address is static on the host already; the reservation is what
stops Kea handing `.40` to anything else.

**Hicks's pass to the tier.** Hicks reaches Winterfell by a named list
([ADR-0031](../adr/0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md)),
and on 2026-09-27 that list had SSH to the whole segment but **no HTTPS to
`10.0.99.40`**. Every browser and phone reaches the tier on 443, so add it:

- *Firewall → Rules → HICKS*.
- Pass, TCP, source *HICKS subnets*, destination single host `10.0.99.40`,
  port HTTPS.
- Description "Allow HTTPS to trinity".
- Drag it **above** *Block access to Winterfell*, beside *Allow HTTPS to the
  wiki*.
- Save, then Apply.

## 4. Tooling, and the seal to the TPM

One block, pasted on `trinity`. It asks for your `sudo` password once:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git make age tpm2-tools
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo install -d -m 0755 /etc/docker
echo '{ "features": { "containerd-snapshotter": false } }' | sudo tee /etc/docker/daemon.json
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker "$USER"
curl -fsSLo /tmp/sops.deb https://github.com/getsops/sops/releases/download/v3.9.4/sops_3.9.4_amd64.deb
sudo apt-get install -y /tmp/sops.deb && rm /tmp/sops.deb
```

`sops` is `3.9.4` because that is what `prometheus` runs (`sops --version`
there). Take whatever it says on the day.

**`daemon.json` comes before Docker, on purpose.** A fresh Docker 29 stores
images through containerd (`docker info` says `overlayfs`). The Alloy
agent's cAdvisor half cannot read that store, and logs `cannot unix dial
containerd` every few seconds with no per-container metrics. `prometheus` and
`oracle` were installed on older Docker and kept `overlay2`. On 2026-09-28 this
was found after the first `make up`; switching then cost a `make down`, a Docker
restart and every image downloaded again. The volumes survived it.
`docker info --format '{{.Driver}}'` must print `overlay2`.

Then the seal. Find the LUKS partition, rather than assuming `p3`, and
enrol the TPM into a keyslot of its own:

```bash
LUKS=$(sudo blkid -t TYPE=crypto_LUKS -o device | grep nvme)
echo "$LUKS"
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$LUKS"
sudo sed -i '/^dm_crypt-0 /s/ luks$/ luks,tpm2-device=auto/' /etc/crypttab
echo 'add_dracutmodules+=" tpm2-tss "' | sudo tee /etc/dracut.conf.d/tpm2.conf
sudo update-initramfs -u -k all
```

`systemd-cryptenroll` asks for the LUKS passphrase. That is the only time it
is typed outside a recovery. On 26.04, `update-initramfs` is dracut's
wrapper, not initramfs-tools. The `tpm2-tss` line makes sure the TPM
libraries go into the image, rather than relying on dracut to notice them.
Then check all three halves:

```bash
sudo systemd-cryptenroll "$LUKS"
cat /etc/crypttab
sudo lsinitrd | grep -c -E 'tss2|systemd-cryptsetup'
```

1. The first lists two slots, `password` and `tpm2`.
2. The second ends `luks,tpm2-device=auto`. The installer names the mapping
   `dm_crypt-0`; if yours differs, the `sed` matched nothing, so edit that
   line to match.
3. The third prints a number above zero.

**Now prove it. This is the step the whole ADR rests on:**

```bash
sudo reboot
```

Do not touch the console. Within two minutes, `ssh <you>@10.0.99.40` from
`prometheus` must answer. If the box sits at the passphrase prompt instead,
type the passphrase, and read *If something goes wrong* before going further.
A box that needs the console after every reboot is ADR-0054's rejected
option, arrived at by accident.

The repository, as you, after logging in again so the docker group applies:

```bash
git clone https://github.com/Gerrrt/HomeLab.git ~/code/Gerrrt/HomeLab
docker ps > /dev/null && echo docker-ok
```

Deploy from this checkout: `make render` writes into the tree it runs from.

## 5. The photo disk

Plug in the 2 TB drive and find it by size and transport, not by letter:

```bash
lsblk -d -o NAME,SIZE,TRAN,MODEL
```

It is the `usb` row at about `1.8T`. Everything below destroys what is on it,
which is a games console's storage and nothing anyone wants. Set `DISK` to
that row's device and paste the block:

```bash
DISK=/dev/sdX
sudo wipefs -a "$DISK"
sudo parted -s "$DISK" mklabel gpt mkpart immich 0% 100%
sudo install -d -m 0700 /etc/cryptsetup-keys.d
sudo dd if=/dev/urandom of=/etc/cryptsetup-keys.d/immich.key bs=512 count=1 status=none
sudo chmod 0400 /etc/cryptsetup-keys.d/immich.key
sudo cryptsetup luksFormat --type luks2 --batch-mode \
  --key-file /etc/cryptsetup-keys.d/immich.key "${DISK}1"
sudo cryptsetup luksAddKey --key-file /etc/cryptsetup-keys.d/immich.key "${DISK}1"
```

`luksAddKey` prompts for a **new** passphrase. Generate it in the password
manager and file it beside the root disk's. It is what opens the photos on
any other Linux machine, with the keyfile gone, and the day it is needed is
the day `trinity`'s SSD has died.

Then open it at every boot, format it, and mount it behind the same guard
`odin`'s data disk has:

```bash
echo "immich UUID=$(sudo blkid -s UUID -o value "${DISK}1") /etc/cryptsetup-keys.d/immich.key luks,nofail,x-systemd.device-timeout=30s" \
  | sudo tee -a /etc/crypttab
sudo systemctl daemon-reload
sudo systemctl start systemd-cryptsetup@immich.service
sudo mkfs.ext4 -L immich /dev/mapper/immich
sudo mkdir -p /srv/immich
sudo chattr +i /srv/immich
echo "/dev/mapper/immich /srv/immich ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2" \
  | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /srv/immich
sudo chown "$(id -u):$(id -g)" /srv/immich
df -h /srv/immich
```

**`chattr +i` on the empty mountpoint is the guard.** With the disk unplugged
or locked, nothing can create a directory under `/srv/immich`. Docker then
refuses to start `immich-server` where it would otherwise write the library
onto the root SSD. `nofail` keeps the box bootable, and reachable, without
the drive.

Label the drive itself "trinity — photos, encrypted". Then reboot once more,
hands off again, and `df -h /srv/immich` must show about 1.8T on
`/dev/mapper/immich`. That proves the `crypttab` and `fstab` lines together,
before any photograph depends on them.

## 6. Its own age key, and the seven secrets

In your own terminal on `trinity`. None of this goes into a shared session.

```bash
cd ~/code/Gerrrt/HomeLab
make secrets-init STACK=sensitive
```

That writes `trinity`'s public key into `.sops.yaml`'s `sensitive` rule, over
the placeholder, and creates `secrets/sensitive.sops.yaml` from the example.
[`secrets/sensitive.example.yaml`](../../secrets/sensitive.example.yaml) says
what each key is for. The values:

| Key | Made with | Also kept in the password manager |
| --- | --- | --- |
| `STEPCA_PASSWORD` | `make gen-secret` | No. It lives in SOPS, and §7 carries it once |
| `ADGUARD_ADMIN_PASSWORD_HASH` | `make hash-password` — prompts for the password | **The password** |
| `IMMICH_DB_PASSWORD` | `make gen-secret` | No |
| `VAULTWARDEN_ADMIN_TOKEN` | the `vaultwarden hash --preset owasp` line in the stack README | **The token you typed** — the vault cannot hold its own admin token |
| `PAPERLESS_SECRET_KEY` | `make gen-secret` | No |
| `PAPERLESS_DBPASS` | `make gen-secret` | No |
| `PAPERLESS_ADMIN_PASSWORD` | `make gen-secret` | **Yes**, it is a login |

```bash
make secrets-edit STACK=sensitive
```

Then put `trinity`'s age private key on the offline copy, beside the
estate's, as [`back-up-the-age-key.md`](back-up-the-age-key.md) describes, and
check it the same way:

```bash
make secrets-verify-backup STACK=sensitive KEY=/path/to/the/copy/keys.txt
```

**Get the two files into git.** `.sops.yaml` and
`secrets/sensitive.sops.yaml` hold a public key and ciphertext, and nothing
else. The checkout on `trinity` has no push credentials, so copy both to a
checkout that does (`scp` from `prometheus` is one hop), open a PR, and check
the rule matches:

```bash
python3 scripts/check_sops_rules.py
```

`secrets/sensitive.sops.yaml` must resolve to the `secrets/sensitive...`
rule, not to the catch-all. Once it merges, fast-forward `trinity`'s
checkout. If git refuses because the two files are already there,
`git diff origin/main -- .sops.yaml` printing nothing is the proof they are
the same bytes. Move the local copies aside, pull, and delete them.

## 7. The CA

[`build-the-tier-ca.md`](build-the-tier-ca.md), as written, across the two
hosts. The one decision it leaves open is how `STEPCA_PASSWORD` crosses to
`prometheus`: paste it into a file in memory, never into an editor.

On `prometheus`, in the **main checkout**, because that is where the tree
lives from now on:

```bash
cat > /dev/shm/stepca-pw          # paste, Enter, Ctrl-D
make tier-ca ARGS="--mint --password-file /dev/shm/stepca-pw"
shred -u /dev/shm/stepca-pw
```

Keep the `root SHA256` line it prints. Add
`certificates/tier-ca/secrets/root_ca_key` to the offline copy, as that
runbook's step 2 says. §§3–4 of that runbook (the `scp`, the `--install`, the
fingerprint comparison and the `shred`) need no secret and no `sudo`.

## 8. The names, `bifrost`, and the one pass into Skids

Take the export first, from `prometheus`:

```bash
make backup-firewall
```

**Host overrides**, as [`add-a-host-override.md`](add-a-host-override.md)
describes. One entry, host `trinity`, domain `matrix.elysium`, address
`10.0.99.40`. The other five names go under *Additional Names for this Host*:

`homeassistant`, `immich`, `paperless`, `vaultwarden`, `adguard`

These are exactly the `Caddyfile`'s site names and the `caddy` service's
aliases in `compose.yaml`. A later service adds its name in all three places.

**`bifrost`'s reservation, before the rule**
([ADR-0035](../adr/0035-scope-the-99-to-20-rule-to-the-hue-bridge.md) step
4).

1. Find the bridge by its MAC, not its address: *Status → DHCP Leases*, the
   `ec:b5:fa:…` row, hostname `ecb5fa…`. Skids reserves nothing else, so it
   drifts. It was at `.104` on 2026-09-09 and at `.113` on 2026-09-28, with
   `.104` held by another device.
2. *Services → DHCP Server → SKIDS*, add a static mapping: that MAC,
   **`10.0.20.20`**, below the `.100–.200` pool so no lease can ever hold it,
   hostname `bifrost`.
3. Power-cycle the bridge, or wait for its hourly renewal; Kea moves it
   either way. Confirm it is on `.20` before writing the rule.

**The pass.**

- *Firewall → Rules → WINTERFELL*: Pass, TCP.
- Source single host `10.0.99.40`, destination single host `10.0.20.20`.
- Destination ports 80 and 443. Either a port alias holding both, or two
  rows. On 2026-09-28 it was two rows.
- Description "Home Assistant to the Hue bridge (ADR-0035)".
- Drag it **above** *Block access to Skids*, beside the two SNMP passes that
  already sit there.
- Save, then Apply.

**Then read the tripwire immediately**, from `prometheus`, before anything
has used the rule:

```bash
ssh admin@10.0.99.1 'pfctl -vsr' | grep -A2 -E 'Home Assistant to the Hue|Block access to Skids'
```

1. The pass must print on `igc0.99`, and before the Winterfell *Block access
   to Skids*.
2. [#223](https://github.com/Gerrrt/HomeLab/issues/223)'s tripwire counter
   on Skids must stay `0` after Home Assistant has paired in §10. The return
   traffic rides state, and a non-zero count means it does not.
3. `make check-firewall` still passes. The claims file states postures, not
   rule bodies, so the rule itself is recorded in `network.md`.

## 9. Bring it up, and prove what `make validate` cannot

On `trinity`:

```bash
cd ~/code/Gerrrt/HomeLab
make up STACK=sensitive
make ps STACK=sensitive
make check-container-health STACK=sensitive
```

All twelve services must be healthy, with the `ml` profile on as `.env.example` ships it.
Then the stack README's list, on the host it was written for:

- **The CA tree and ACME.** [`build-the-tier-ca.md`](build-the-tier-ca.md)
  §5, once for each of the six names: `certificate obtained` in Caddy's log,
  and `Verify return code: 0` against `certificates/tier-ca.pem`.
- **The library is on the USB disk.** `docker exec sensitive-immich-server df -h /data`
  shows the `/dev/mapper/immich` filesystem, not the root.
- **Home Assistant answers through Caddy.** On a fresh `home-assistant-config`
  volume it will not: since 2026.9, Home Assistant imports `configuration.yaml`'s
  `http:` block once, as a *pending* config, and reverts to defaults that trust
  no proxy unless an admin confirms it within five minutes. The symptom is
  `400: Bad Request` on `homeassistant.matrix.elysium`. The stack README's Home
  Assistant bullets have the fix, and it takes a minute. Apply it before
  onboarding.
- **Home Assistant keeps booting under its hardening.** It is healthy above;
  the `dhcp` integration's `CAP_NET_RAW` error is the one expected line.
- **AdGuard answers the prober and nobody else.** That is §11, step 1.
- **The limits.** Nothing to do today. The README says re-derive after a
  month.

The agent, from `prometheus`:

```bash
./scripts/deploy-agent.sh <you>@10.0.99.40
make install-agent-collectors AGENT=<you>@10.0.99.40
```

The first needs no privilege on `trinity`. The second asks for your `sudo`
password there, which is why it is separate. Within a minute
`up{instance=~"trinity.*"}` is 1 in Prometheus.

## 10. Trust the root, then the first logins

Distribute `certificates/tier-ca.pem` as
[`build-the-tier-ca.md`](build-the-tier-ca.md) §6 says: the Mac's keychain
(*Always Trust*), which Chrome and Safari use, Firefox's own store if
it is used, and each phone. To get it onto an iPhone, rename it `.crt` and AirDrop it. On iOS, install the
profile **and then** enable it under *Settings → General → About →
Certificate Trust Settings*.

Then each service, from Hicks, and **a second factor at the first login of
every account that can carry one**. That is
[ADR-0022](../adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)'s
floor, and recovery codes go in the password manager.

| Service | First login | Second factor |
| --- | --- | --- |
| `https://homeassistant.matrix.elysium` | Onboarding creates the owner | *Profile → Security → Multi-factor authentication* |
| `https://vaultwarden.matrix.elysium/admin` | The token from §6; invite each account; each registers at the vault | *Settings → Security → Two-step login*, per account |
| `https://paperless.matrix.elysium` | `admin` and the password from §6 | The profile's *Two-factor authentication* |
| `https://immich.matrix.elysium` | The first sign-up is the admin | None. ADR-0022 records Immich as unable |
| `https://adguard.matrix.elysium` | The password behind §6's hash | None — likewise |

Home Assistant's Hue integration is added **by address**, `10.0.20.20`,
pressing the bridge's button when asked. That is the first traffic §8's pass
carries. Read the tripwire again afterwards.

## 11. The forwarder

[`forward-dns-to-adguard.md`](forward-dns-to-adguard.md) from its step 1,
with **AdGuard as the only forwarder**
([ADR-0055](../adr/0055-forward-to-adguard-alone.md)): with the public resolvers
beside it, 38 of 60 blocked names leaked. From then on, AdGuard being down
means the house has no outside names, so `AdGuardNotAnswering` pages.
Step 4 takes AdGuard down to prove that page arrives. Do not silence it, and
pick ten minutes nobody needs the internet.

## 12. Backups, and the copy off the host

`make backup STACK=sensitive` copies each set to
`atropos@10.0.99.30:backups/volumes/sensitive`, so `trinity` needs a key
`oracle` accepts. On `trinity`:

```bash
ssh-keygen -t ed25519 -N '' -C "trinity backups" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

Append that one line to `~atropos/.ssh/authorized_keys` on `oracle`. Then
accept the host key once, and take the first set:

```bash
ssh atropos@10.0.99.30 true
make backup STACK=sensitive
make backup STACK=sensitive ARGS=--list
make restore STACK=sensitive ARGS="--dry-run --from latest"
```

Both sides must be listed, and the dry run must pass. Ten volumes are
archived. `immich-model-cache` and `adguard-work` are skipped by name, so AdGuard
keeps answering the house's DNS while the rest of the stack is stopped. On
2026-09-28, 150 of 150 lookups through `morpheus` succeeded during a backup.
[`restore-the-sensitive-tier.md`](restore-the-sensitive-tier.md) §0 is the
rest of what must be true.

**A weekly timer for it is its own change under #404**, because its outcome
has to reach the estate's staleness alerts under a job name of its own. The
estate's `homelab-backup-volumes` unit is the monitoring host's, and its paths
are `robo`'s. Until the timer is installed, a set exists only when someone
runs the line above. Converging the host is
[#533](https://github.com/Gerrrt/HomeLab/issues/533), after this.

## 13. Before the first real photo, document or vault item

The stack is up and holds nothing. These five are the gate on the data, not
on the containers, and each is written in a document that already exists:

1. **The Immich restore rehearsal.** Upstream's database-before-first-start
   order, on test photos, as the stack README's Immich section describes.
2. **The second recipient on the `sensitive` rule**
   ([ADR-0024](../adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)).
   Run `make secrets-add-recipient STACK=sensitive PUBKEY=age1…`, then one
   more `make backup STACK=sensitive`, so a set exists that the second key
   opens.
3. **The off-estate copy**
   ([ADR-0023](../adr/0023-keep-the-household-recovery-path-outside-the-estate.md),
   [ADR-0048](../adr/0048-carry-the-estates-backup-sets-with-the-second-recipient.md),
   [`copy-the-backups-offsite.md`](copy-the-backups-offsite.md)). This covers
   the library disk as well as the volume sets.
4. **ADR-0022's decision recorded.** Either an identity provider, or the
   deferral re-accepted with reasons.
5. **ADR-0023's *Independent* test.** The household's own credentials open
   from the other person's device, without the operator present.

## 14. Write it down

- [`hardware.md`](../hardware.md): the Compute row, and the USB drive's entry
  saying encrypted `ext4`.
- [`network.md`](../network.md): `trinity` in Winterfell's table,
  `bifrost`'s reservation, the Skids pass in force, and the Hicks pass
  counted in the named list.
- [`architecture.md`](../architecture.md) and the stack README: not "not
  built".
- `docs/firewall-claims.yaml`: the count of Hicks passes in its comment. It
  states postures, not rule bodies.
- `blackbox-dns.yaml`: the forwarder runbook's two targets.
- The issue: #129–#135 close by hand once §9–§11 verify (their PRs said
  `Refs`), and #404 closes on §13.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| The box waits at the LUKS prompt after §4's reboot | `crypttab` lacks `tpm2-device=auto`, the initramfs lacks the TPM libraries, or PCR 7 changed between enrolment and boot | Type the passphrase. Re-run §4's three checks. If all three pass, re-enrol: `sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 "$LUKS"` |
| It asks for the passphrase after a BIOS update or a Secure Boot change | PCR 7 moved — the designed failure (ADR-0054) | Type it, then re-enrol as above |
| The box came up on `10.0.99.1xx`, not `.40` | The installer's network screen was left on DHCP | At the console: write `/etc/netplan/50-cloud-init.yaml` with `eno1` static as in §2, add `network: {config: disabled}` to `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`, **delete** `/etc/netplan/00-installer-config.yaml` (it still says DHCP, and netplan merges both), then `sudo netplan try` and press Enter |
| `mokutil --sb-state` says disabled | §1's Secure Boot setting did not survive, or HP's code was not typed | Fix it in F10, then re-bind. A seal made with Secure Boot off unseals with it off |
| `/srv/immich` is empty after a reboot and `df` shows the root | The drive was unplugged or the `crypttab` line is wrong; `chattr` held | `systemctl status systemd-cryptsetup@immich`, fix, `sudo mount /srv/immich`. Immich refuses to start meanwhile, which is the point |
| `make render` stops with *do NOT run `make certs ARGS=--ca` here* | `certificates/tier-ca.pem` is missing | §7 is not done |
| A browser on Hicks times out on `https://*.matrix.elysium` | §3's Hicks pass is missing or below the block | Check *Firewall → Rules → HICKS* order |
| Home Assistant cannot find the bridge | The pass is below *Block access to Skids*, or `bifrost` is not on `.20` | `pfctl -vsr` as in §8; the reservation |
| `homeassistant.matrix.elysium` answers `400: Bad Request` | Home Assistant 2026.9+ reverted its imported `http:` config because nobody confirmed it within five minutes | The stack README's Home Assistant bullets: promote the pending config with the container stopped |
| Caddy fails to start: *Address already in use* | Something took `172.28.99.2` (fixed since 2026-09-28 by the network's `ip_range`) | `make down STACK=sensitive`, then `make up`. If it recurs, check the `ip_range` is still in `compose.yaml` |
| The Alloy agent logs `cannot unix dial containerd` and no container metrics arrive | Docker is on the containerd image store | §4's `daemon.json`, then `make down`, restart Docker, `make up` (the images download again), and `deploy-agent.sh` again |
| The house loses outside DNS while `trinity` is fine | AdGuard stopped. Only the backup used to do that, and it no longer does | `make ps STACK=sensitive`; `AdGuardNotAnswering` pages at five minutes. The workaround is in `forward-dns-to-adguard.md` step 4 |
| `make backup` fails on the copy | `oracle`'s `authorized_keys`, or `oracle` is off | §12. The set is still on `trinity`; `ARGS=--copy-only` catches up |
