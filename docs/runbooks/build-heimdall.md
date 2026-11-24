# Runbook: Build `heimdall`, the office wall dashboard

Turn a Raspberry Pi 5 into the kiosk behind the office television: a
reserved address on Hicks, key-only SSH, updates on their own, Chromium
full-screen on a page served by `trinity`, and `node_exporter` scraped by
`prometheus`
([ADR-0119](../adr/0119-put-the-office-wall-dashboard-on-a-pi-5-on-hicks.md)).

**Target:** `heimdall` over SSH, `morpheus`'s web UI, and `prometheus`
**Time:** ~45 minutes, plus a reboot
**Needs:** Hicks, an SSH key already on the Pi, and the micro-HDMI cable
**Reversible:** §9

---

## Why this exists

The Pi keeps no state worth backing up, so this runbook is how it is
replaced: a new card, flashed from `oracle`, and these steps in order. It
holds no credentials. Anything a page needs is added on `trinity`, so losing
the Pi loses nothing but the time this takes.

## 0. The starting point

Flash Raspberry Pi OS (64-bit, with desktop) with Raspberry Pi Imager. Set the
hostname to `heimdall`, the user, an SSH public key and the Hicks Wi-Fi in the
Imager's settings. The first boot lands on an autologin desktop under labwc.

Read the Pi back before changing it. On 2026-11-17 this was:

| Check | Command | Read |
| --- | --- | --- |
| Model and OS | `tr -d '\0' < /proc/device-tree/model; head -1 /etc/os-release` | Raspberry Pi 5 Model B Rev 1.1, Debian 13 (trixie) |
| Health | `vcgencmd measure_temp; vcgencmd get_throttled` | 47.7 °C, `throttled=0x0` |
| Desktop | `systemctl get-default; pgrep -a labwc` | `graphical.target`, `labwc -m` |
| Wi-Fi | `cat /proc/net/wireless; nmcli -f IN-USE,CHAN,RATE dev wifi \| grep '^\*'` | 5 GHz, −45 dBm, 433 Mbit/s |
| CEC | `ls /dev/cec*` | `/dev/cec0  /dev/cec1` |

`throttled` must read `0x0`. Anything else means the supply is short.
Use the official 27 W USB-C supply: a television's USB port cannot run a Pi 5.
Raspberry Pi OS does not ship `iw`. `/proc/net/wireless` gives the level in
dBm, and `nmcli` gives the channel and the rate of the network in use.

## 1. SSH by key only

Prove a key login works from a second terminal first. Then:

```bash
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nX11Forwarding no\nAllowTcpForwarding no\n' \
  | sudo tee /etc/ssh/sshd_config.d/10-keys-only.conf
sudo sshd -t && sudo systemctl reload ssh
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin|pubkeyauthentication|x11forwarding|allowtcpforwarding) '
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
ssh-keygen -lf ~/.ssh/authorized_keys    # every line a key you can name
```

Expect `passwordauthentication no`, `permitrootlogin no`,
`pubkeyauthentication yes`, `x11forwarding no` and `allowtcpforwarding no`.
Open a new session before closing the old one. A kiosk forwards nothing, so
the two Debian defaults that forward X11 and TCP are switched off too.

### sudo asks for the password

The Imager's cloud-init gives the user passwordless sudo, in
`/etc/sudoers.d/90-cloud-init-users`. That user is logged in on `tty1` and
on the desktop at all times, so with that file a keyboard plugged into the Pi
is root, and so is the SSH key. Remove it, with a root shell held open in a
second session in case the password is not the one you think:

```bash
sudo -i                                   # second session: leave it open
sudo rm /etc/sudoers.d/90-cloud-init-users  # first session
sudo -k; sudo true                        # asks for the Imager's password
```

If the password is refused, set a new one from the root shell with
`passwd <user>`. Keep it in your password manager. It is the operator's
login, not something a page uses, so the Pi still holds no credential of
the lab's.

### Nothing left on the boot partition

The Imager's settings reach the Pi as cloud-init seed files on the FAT boot
partition. Any local user can read them, and they are plain text on the card:
`user-data` holds the password's hash and `network-config` holds the Wi-Fi
passphrase. They did their job at the first boot. NetworkManager keeps its
own copy of the Wi-Fi settings at mode 600 under `/etc/netplan`, so the Pi
still joins Hicks without them. Turn cloud-init off first, so a boot without
its seed does not run it again:

```bash
sudo touch /etc/cloud/cloud-init.disabled
sudo rm /boot/firmware/user-data /boot/firmware/network-config
```

After §3's reboot, `nmcli -t -f DEVICE,STATE dev | grep '^wlan0'` reads
`wlan0:connected`.

## 2. Updates and the exporter

```bash
sudo apt update
sudo apt install -y --no-install-recommends unattended-upgrades \
  prometheus-node-exporter prometheus-node-exporter-collectors libnss3-tools
systemctl is-active prometheus-node-exporter    # active
systemctl --failed --no-legend                  # nothing
```

The collectors package adds the textfile metrics for pending upgrades and a
pending reboot. Without `--no-install-recommends`, apt also brings in what
it recommends for a server: `ipmitool`, which pulls in `openipmi`, and
`smartmontools`. A Pi has no management controller and its card reports no
SMART data, so `openipmi.service` and `smartmontools.service` fail at every
boot. The first build, on 2026-11-17, left both failed. On a Pi built that
way:

```bash
sudo apt purge -y openipmi ipmitool smartmontools \
  libopenipmi0t64 libfreeipmi17 freeipmi-common
sudo systemctl reset-failed openipmi.service smartmontools.service
systemctl --failed --no-legend                  # nothing
```

### Raspberry Pi's packages update too

`unattended-upgrades` installs Debian's updates daily, but its default
origins are Debian's alone. Chromium, the kernel, the firmware and the
EEPROM come from `archive.raspberrypi.com`, and Raspberry Pi's Chromium
outranks Debian's by its epoch. So none of them update without this:

```bash
echo 'Unattended-Upgrade::Origins-Pattern:: "origin=Raspberry Pi Foundation,codename=${distro_codename}";' \
  | sudo tee /etc/apt/apt.conf.d/52heimdall-unattended-upgrades
apt-config dump | grep -c 'origin=Raspberry Pi Foundation'    # 1
```

An upgraded Chromium runs only once Chromium restarts, and a new kernel only
once the Pi does. Nothing on the Pi does either by itself, and a Chromium
upgrade leaves no reboot-required flag. So the Pi reboots every night. At
04:30 it picks up the previous morning's upgrades, while nobody is looking
at the wall:

```bash
sudo tee /etc/systemd/system/nightly-reboot.service >/dev/null <<'UNIT'
[Unit]
Description=Reboot, so upgraded Chromium, kernel and firmware run
[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
UNIT
sudo tee /etc/systemd/system/nightly-reboot.timer >/dev/null <<'UNIT'
[Unit]
Description=Reboot heimdall every night at 04:30
[Timer]
OnCalendar=*-*-* 04:30
[Install]
WantedBy=timers.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now nightly-reboot.timer
systemctl list-timers nightly-reboot.timer --no-legend    # next at 04:30
```

### A journal that survives a reboot

Raspberry Pi OS keeps the journal in memory, to spare the card
(`/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf`). That
loses the reason for any reboot it did not plan. Keep it on the card, capped:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\nSystemMaxUse=64M\n' \
  | sudo tee /etc/systemd/journald.conf.d/50-persistent.conf
sudo systemctl restart systemd-journald
```

After §3's reboot, `journalctl --list-boots` lists more than one boot.

### Only 22 and 9100 listen

The desktop brings services a kiosk does not use, and the Pi has no host
firewall, so anything on Hicks reaches what they publish. rpcbind, from
`nfs-common`, listens on 111, and avahi on 5353. Bluetooth is on and
pairable, CUPS listens locally, and three remote-desktop packages are
installed. The desktop's metapackages depend on `nfs-common` and `cups`, so
mask those rather than purge them. Nothing depends on the remote-desktop
packages:

```bash
sudo systemctl mask --now rpcbind.service rpcbind.socket nfs-blkmap.service \
  avahi-daemon.service avahi-daemon.socket \
  cups.service cups.socket cups.path bluetooth.service
sudo apt purge -y realvnc-vnc-server wayvnc rpi-connect
sudo ss -tulnH | awk '{print $1, $5}' | sort -u    # tcp 22 and 9100, nothing else
```

## 3. The reservation

On `morpheus`, under Services → DHCP Server → Hicks, add a static mapping:
`heimdall`, `10.0.50.15`, and the MAC `ip link show wlan0` prints on the Pi.
`.15` is below the `.100–.200` pool, beside `wearable-01`. Reboot the Pi
rather than bouncing Wi-Fi over SSH, then:

```bash
ip -br addr show wlan0    # 10.0.50.15/24
```

The address in use carries Raspberry Pi's OUI (`88:a2:9e`), so it is the
hardware MAC and not a randomised one, and the reservation holds.

## 4. The firewall pass, and the scrape

On `morpheus`, under Firewall → Rules → Winterfell, add a pass **above** the
row that blocks access to Hicks, beside the `eeros` echo pass:

| Field | Value |
| --- | --- |
| Protocol | TCP |
| Source | `10.0.99.20` |
| Destination | `10.0.50.15`, port `9100` |
| Description | `prometheus scrapes heimdall node_exporter` |

From `prometheus`:

```bash
curl -s 10.0.50.15:9100/metrics | grep -m3 node_
```

Done on 2026-11-17: it returned `node_arp_entries{device="wlan0"} 1`. The
`heimdall` target in `stacks/observability/prometheus/targets/node.yaml` is
picked up once `prometheus` has converged on `main` (ADR-0021) and reloaded
the file, within five minutes of that. Check `up{instance="heimdall"}` reads 1.

## 5. HDMI

Use the micro-HDMI port **next to the USB-C power port** (`HDMI-A-1`). Make
the Pi drive 1080p even when the television is off at boot. Otherwise it
finds no display and the kiosk comes up on nothing:

```bash
sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak
sudo sed -i '1 s/$/ video=HDMI-A-1:1920x1080@60D/' /boot/firmware/cmdline.txt
cat /boot/firmware/cmdline.txt    # still ONE line, ending in the video= part
```

`cmdline.txt` must stay a single line, or the Pi does not boot. If it does
not boot, put the card in `oracle` and restore the `.bak`. After the reboot:

```bash
cat /sys/class/drm/card1-HDMI-A-1/status    # connected
```

**The desktop's mode comes from `kanshi`, not from that line.** `video=`
sets the boot console and forces the output on. labwc takes whatever mode
the television's EDID calls *preferred*. This Changhong's EDID is a generic
one ("DMTF", model `CHHWJT*`, serial 1, and a 710 × 400 mm size that is not
a 40" panel's), and it prefers **1280 × 720**, while 1920 × 1080 at 60 Hz is
also in its list. Raspberry Pi OS runs `kanshi` to set modes, and an empty
`~/.config/kanshi/config` leaves the preferred one. Give it a profile:

```bash
cp ~/.config/kanshi/config ~/.config/kanshi/config.bak
cat > ~/.config/kanshi/config <<'KANSHI'
profile wall {
    output HDMI-A-1 mode 1920x1080@60.000 position 0,0
}
KANSHI
sudo reboot
# after the reboot:
WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 wlr-randr | grep current
# 1920x1080 px, 60.000000 Hz (current)
```

Measured on 2026-11-18: sharp at 1080p, no edge cut off (the set's aspect
setting is *Full*, under Picture), and the mode survived a reboot. The page
scales its 1920 × 1080 stage to whatever mode it gets, so a wrong mode only
softens the text. It never crops the page.

## 6. Trust the tier's root, in Chromium's store

Chromium on Linux reads its own NSS database, not the system's store, so
`update-ca-certificates` does nothing for it. First print the root's
fingerprint from a copy you already trust, on `prometheus` or `trinity`
([`build-the-tier-ca.md`](build-the-tier-ca.md) §6):

```bash
openssl x509 -in certificates/tier-ca.pem -noout -sha256 -fingerprint
```

On the Pi, fetch it once without verification and compare before trusting:

```bash
curl -kfsS -o ~/tier-ca.crt https://home.matrix.elysium/tier-ca.crt
openssl x509 -in ~/tier-ca.crt -noout -sha256 -fingerprint    # must match
mkdir -p ~/.pki/nssdb
certutil -d sql:$HOME/.pki/nssdb -N --empty-password 2>/dev/null
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "matrix.elysium tier CA" -i ~/tier-ca.crt
certutil -d sql:$HOME/.pki/nssdb -L    # lists it, trust C,,
```

If the fingerprints differ, delete the file and find out what answered on 443.

## 7. The kiosk

```bash
mkdir -p ~/.config/labwc
echo '/usr/bin/lwrespawn chromium --kiosk --noerrdialogs --disable-infobars --password-store=basic https://start.matrix.elysium/homelab &' \
  >> ~/.config/labwc/autostart
sudo raspi-config nonint do_blanking 1
sudo reboot
```

Use the wall page, `https://wall.matrix.elysium/`, in place of the Glance
URL above. It is the page the kiosk has shown since 2026-11-17
(`stacks/sensitive/README.md`, *The wall page*). If the wall page is down,
put the Glance URL back by hand: nothing fails over on its own. Switching
either way is this line's URL and a reboot, nothing else. `--password-store=basic` stops Chromium
asking for a keyring at boot, which would otherwise sit on the screen.
Blanking off keeps the desktop from turning the screen off. The screen stays
on day and night (§8).

`lwrespawn` is the wrapper the desktop's own autostart uses for its panel. It
starts Chromium again a second after it exits, so a crash costs a second
instead of the rest of the day. On a Pi whose line was written without it,
put `/usr/bin/lwrespawn ` in front of `chromium` and reboot.

Raspberry Pi OS's Chromium also loads two extensions of its own through
`/etc/chromium.d/extensions`: h264ify and uBlock Origin Lite. The second
updates itself from the Chrome Web Store. The wall page needs neither, and
neither holds anything. They are left as the OS ships them.

**Verify at the wall:** after a reboot, the page fills the screen with no
address bar, no padlock warning and no keyring prompt.

## 8. The television, on and off

**This set has no HDMI-CEC.** Its manual (FCC ID 2ABNO40YD1100UA) never
mentions it, and on 2026-11-18 the Pi's probe found nothing. `cec-ctl -d
/dev/cec0 --playback -S` gave the Pi's own adapter the physical address
`1.0.0.0`, taken from the television's EDID: it says which HDMI input the Pi
is on, not that the set answered. The television, which would be `0.0.0.0`,
never replied. No logical address was allocated, and the topology was empty.
So nothing on the Pi can turn the set off or wake it.

What the manual does say, and what follows from it:

- **Without a signal it switches itself off,** after 5 minutes ("TV mode")
  or 60 seconds ("PC mode"). So switching the Pi's output off at night
  (`wlr-randr --output HDMI-A-1 --off`) would put it in standby with nothing
  to wake it in the morning but the remote.
- **Time menu → Auto Sleep must be Off,** and so must Sleep. Auto Sleep puts
  the set in standby after a set time with "no operation", meaning no
  remote press, so it would blank the wall part-way through every day while
  the picture is fine.

**The screen therefore stays on, day and night.** The page is dark and still
when nothing is wrong, and an LED panel does not burn in. Turning it off on a
schedule would take a smart plug (only if the set comes back on by itself
when power returns, which is untested) or an infrared LED on the Pi
replaying the remote's power code. Either is a purchase, so it goes through
the roadmap's *Everything still to buy* and an ADR of its own.

## 9. Undo

- **The pass:** delete the Winterfell row from §4, and remove the `heimdall`
  target from `node.yaml` in the same change. Otherwise the scrape stays at
  `up == 0` for good. Nothing alerts on that: `InstanceDown` excludes
  `role="display"`, so a target left behind is silently dead, not loud.
- **The reservation:** delete the static mapping. The Pi falls back to a pool
  lease.
- **The kiosk:** remove the line from `~/.config/labwc/autostart`.
- **The root:** `certutil -d sql:$HOME/.pki/nssdb -D -n "matrix.elysium tier CA"`.
- **The boot line:** restore `/boot/firmware/cmdline.txt.bak`.
- **The mode:** restore `~/.config/kanshi/config.bak`. The desktop falls back
  to the television's preferred 1280 × 720.
- **The nightly reboot:** `sudo systemctl disable --now nightly-reboot.timer`,
  then delete both `nightly-reboot.*` units from `/etc/systemd/system`.
- **Raspberry Pi's updates:** delete
  `/etc/apt/apt.conf.d/52heimdall-unattended-upgrades`.
- **The journal:** delete `/etc/systemd/journald.conf.d/50-persistent.conf`
  and restart `systemd-journald`.
- **The masked services:** `sudo systemctl unmask` the units §2 masked, then
  `enable --now` them. The purged remote-desktop packages are reinstalled with
  `apt`.
- **sudo without a password, and the seed files:** neither comes back. A
  fresh card from the Imager has both.
