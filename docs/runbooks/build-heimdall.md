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
| Wi-Fi | `iw dev wlan0 link` | 5 GHz, −45 dBm, 433 Mbit/s |
| CEC | `ls /dev/cec*` | `/dev/cec0  /dev/cec1` |

`throttled` must read `0x0`. Anything else means the supply is short.
Use the official 27 W USB-C supply: a television's USB port cannot run a Pi 5.

## 1. SSH by key only

Prove a key login works from a second terminal first. Then:

```bash
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' \
  | sudo tee /etc/ssh/sshd_config.d/10-keys-only.conf
sudo sshd -t && sudo systemctl reload ssh
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin|pubkeyauthentication) '
```

Expect `passwordauthentication no`, `permitrootlogin no` and
`pubkeyauthentication yes`. Open a new session before closing the old one.

## 2. Updates and the exporter

```bash
sudo apt update && sudo apt install -y unattended-upgrades prometheus-node-exporter libnss3-tools
systemctl is-active prometheus-node-exporter    # active
```

`unattended-upgrades` installs security updates daily, Chromium among them.

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
echo 'chromium --kiosk --noerrdialogs --disable-infobars --password-store=basic https://start.matrix.elysium/homelab &' \
  >> ~/.config/labwc/autostart
sudo raspi-config nonint do_blanking 1
sudo reboot
```

The page is the wall page, `https://wall.matrix.elysium/`, once `morpheus`
has its host override (`stacks/sensitive/README.md`, *The wall page*). Until
then the line above shows Glance's Homelab page. Moving between them is this
line's URL and a reboot, nothing else. `--password-store=basic` stops Chromium
asking for a keyring at boot, which would otherwise sit on the screen.
Blanking off keeps the desktop from turning the screen off. §8 turns the
television off instead.

**Verify at the wall:** after a reboot, the page fills the screen with no
address bar, no padlock warning and no keyring prompt.

## 8. The television, on and off

Ask whether the television takes orders over HDMI-CEC:

```bash
cec-ctl -d /dev/cec0 --playback -S                  # the TV appears as device 0
cec-ctl -d /dev/cec0 --to 0 --standby               # it goes off
cec-ctl -d /dev/cec0 --to 0 --image-view-on         # it comes back
```

If it obeys, schedule those two commands for the hours the office is empty.
If it does not, switch the Pi's output off instead. The television then shows
"no signal" and, on most sets, sleeps:

```bash
wlr-randr --output HDMI-A-1 --off
wlr-randr --output HDMI-A-1 --on
```

`wlr-randr` talks to the running compositor, so run it as the desktop's user
with `WAYLAND_DISPLAY` set (`wayland-0` under labwc). Record which one worked
in the changelog.

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
