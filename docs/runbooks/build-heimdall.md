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
sudo apt update
sudo apt install -y --no-install-recommends unattended-upgrades \
  prometheus-node-exporter prometheus-node-exporter-collectors libnss3-tools
systemctl is-active prometheus-node-exporter    # active
systemctl --failed --no-legend                  # nothing
```

`unattended-upgrades` installs security updates daily, Chromium among them.
The collectors package adds the textfile metrics for pending upgrades and a
pending reboot. Without `--no-install-recommends`, apt also brings in what
it recommends for a server: `ipmitool`, which pulls in `openipmi`, and
`smartmontools`. A Pi has no management controller and its card reports no
SMART data, so `openipmi.service` and `smartmontools.service` fail at every
boot. The first build, on 2026-11-17, left both failed. On a Pi built that
way:

```bash
sudo apt purge -y openipmi ipmitool smartmontools
sudo systemctl reset-failed
systemctl --failed --no-legend                  # nothing
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
echo 'chromium --kiosk --noerrdialogs --disable-infobars --password-store=basic https://start.matrix.elysium/homelab &' \
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
