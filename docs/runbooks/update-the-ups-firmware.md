# Runbook: Update the UPS firmware

**Two updates with very different costs.** The card's firmware (Part A) is a
file copy and a reboot of the card. It cuts no power, and the only side effect
is about five minutes in which nothing can read the UPS. The UPS's own
firmware (Part B) can't be installed with the UPS output on, on this model,
so it means shutting down everything `mjolnir` powers. Do Part A when it
suits you. Do Part B only inside a whole-estate outage that is already
planned for something else.

Tracked in [#1698](https://github.com/Gerrrt/HomeLab/issues/1698).

## Read this part first

- **What runs today** (read 2026-11-23, recorded in
  [`hardware.md`](../hardware.md#management)): the AP9641 card runs AOS
  2.0.0.6 with Smart-UPS application 2.0.0.5. The Smart-UPS X (ID 20) runs
  `UPS 09.8`.
- **The card's free ceiling is the 2.5 line.** Schneider's 3.x firmware for
  the NMC3 (3.6.1.2 on 2026-11-17, with six CVEs fixed) installs only through
  its Secure NMC System (SNS) tool, which runs on Windows, and with a paid
  Secure NMC subscription. A one-year subscription comes with a new AP9641, and
  whether this card's has already run out is unknown. 2.5.x is the last line
  that installs by a plain file copy. Part A installs the newest 2.5.x. Moving
  to 3.x is a purchase decision; record it on #1698 if you make it.
- **There is no going back.** Firmware 2.0 or later can't be downgraded below
  2.0. Downgrading from 2.4 or later to anything below 2.4 formats the card,
  erasing its certificates, keys, configuration and logs. Treat Part A as one
  way.
- **The UPS update needs its output off** for this model (APC's table:
  *SMX, ID 20, firmware update with output on: No*). With the output off, `neo`
  is dark too, so the card can only be reached over a cable from the Mac
  straight into the card's network port (Part B, step 4).
- **What 09.8 to 15.0 buys:** better handling of very weak batteries and a
  more accurate replace-battery indicator (09.9), Modbus over USB and serial
  (10.1), and a front-panel setting that limits which ports can load new
  firmware (15.0). Worth one planned outage, but not one of its own.

---

## Part A. The card's firmware (no outage)

### A.1 Get the file

1. On the Mac, open Schneider's download page for *Network Management Card 3
   (NMC3) Firmware for Smart-UPS (SU) with AP9640/41/43* (document reference
   `APC_NMC3_SU_EN`). Download the newest **2.5.x** package, a self-extracting
   `apc_hw21_su_2-5-x-x.exe`. If the page offers only 3.x, look for older
   versions on the same page. If no 2.5 package can be found, stop here: Part A
   then depends on the subscription decision above.
2. Copy it to `prometheus` and unpack it there. The `.exe` is a 7-Zip archive,
   and `prometheus` has `7z`:

   ```bash
   scp ~/Downloads/apc_hw21_su_2-5-*.exe robo@10.0.99.20:
   ```

   Then on `prometheus`:

   ```bash
   mkdir -p ~/apc-fw && cd ~/apc-fw && 7z x ~/apc_hw21_su_2-5-*.exe
   ls -1 *.nmc3
   ```

   You want exactly one `apc_hw21_su_2-5-x-x.nmc3`. The package may also hold a
   Windows upgrade utility; ignore it.

### A.2 Silence the card and NUT

The card reboots during the upgrade. Its SNMP scrape and HTTPS probe fail,
and NUT's clients report *data stale* and then, after five minutes, *is
unavailable*. On `prometheus`:

```bash
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
for m in '{"name":"role","value":"ups","isRegex":false,"isEqual":true}' \
         '{"name":"alertname","value":"Nut.*","isRegex":true,"isEqual":true}'; do
  curl -sS -X POST http://localhost:9093/api/v2/silences -H 'Content-Type: application/json' \
    --data "$(printf '{"matchers":[%s],"startsAt":"%s","endsAt":"%s","createdBy":"#1698 card firmware","comment":"#1698 mjolnir card firmware upgrade: the card reboots. Delete at A.5."}' "$m" "$START" "$END")"
  echo
done
```

**Record both silence IDs.** A.5 deletes them.

Pick a calm moment: while the card reboots, nothing can tell NUT about a
mains cut. If one happens in those minutes, the pack still carries the load,
but no host is told to shut down until the card is back.

### A.3 Save the card's configuration first

Still on `prometheus`, in `~/apc-fw`, as the card's super user:

```bash
scp -O <superuser>@10.0.99.10:config.ini ./config-before.ini
```

`-O` forces the legacy SCP protocol, which the card speaks; current OpenSSH
uses SFTP by default. **Don't print or commit this file.** It can hold
credentials. It's there to compare settings against if the upgrade loses any,
and you delete it in A.5.

### A.4 Copy the firmware to the card

```bash
scp -O apc_hw21_su_2-5-*.nmc3 <superuser>@10.0.99.10:$(ls apc_hw21_su_2-5-*.nmc3)
```

The card installs the file on receipt and reboots on its own. Allow up to ten
minutes. Don't power-cycle the UPS or pull the card while it works.

### A.5 Verify, then clear up

1. **The version.** In the card's web interface, *About → Network* shows the
   new AOS and Smart-UPS application versions. From `prometheus`, the same is
   in the system description:

   ```bash
   cd ~/code/Gerrrt/HomeLab && scripts/snmp-walk.sh --device mjolnir 1.3.6.1.2.1.1.1
   ```

2. **SNMPv3 still answers.** In Prometheus, `up{job="snmp", device="mjolnir"}`
   is `1` again, and `uioSensorStatusTemperatureDegC{device="mjolnir"}` has a
   fresh value. If the scrape fails with an authentication error, the upgrade
   changed the SNMPv3 profiles: compare *Configuration → Network → SNMPv3 →
   User Profiles* with `config-before.ini` before changing anything in the
   repository.
3. **NUT reads it.** On `morpheus`, `upsc mjolnir ups.status` prints `OL`.
4. **Settings survived.** *Configuration → Shutdown*, *Low Battery Duration*
   is still 16 minutes. `UpsLowBatteryDurationShort` would fire if it isn't.
5. **Delete both silences** (`curl -sS -X DELETE
   http://localhost:9093/api/v2/silence/<id>` for each), then delete
   `~/apc-fw` and the `.exe` in your home directory.
6. **Write it down.** Update the card's line in
   [`hardware.md`](../hardware.md#management) and add a changelog entry.

---

## Part B. The UPS's own firmware (whole-estate outage)

Only inside an outage already planned for something else, such as a rack
visit. Everything `mjolnir` powers goes down, including `morpheus` and `neo`,
so the house has no internet for the duration.

### B.1 Before the day

1. Download `SMX20UPS_15-0.enc` from APC's FAQ *How do I update my Smart-UPS
   firmware using the web interface of my Network Management Card?*
   (FA170679), which lists it for *SMX, ID 20*. Check that the ID matches the
   one in *About → UPS* on the card before using it.
2. The Mac needs a wired Ethernet port or adapter, and a patch cable.
3. Read the whole of this part and the outage it shares.

### B.2 Silence the estate and pause deploys

Follow [`move-into-the-32u-rack.md`](move-into-the-32u-rack.md) §2 and §3,
with `#1698` in the silence's comment in place of `#919`.

### B.3 Shut the hosts down, in order

**Use addresses, not names, from here on.** DNS goes with `trinity`.

| Order | Host | How | You should see |
| --- | --- | --- | --- |
| 1 | `Saruman` and its guests | The Proxmox UI at `https://10.0.30.20:8006` from the Mac on Hicks, *node → Shutdown*. It stops its guests first | The iLO at `10.0.30.10` shows the server off |
| 2 | `gandalf` and its guests | The Proxmox UI at `https://10.0.30.30:8006`, *node → Shutdown*. It stops `ragnarok` and the range guests first | The M80q's power light goes out |
| 3 | `smaug` | The TrueNAS UI, *Power → Shut Down* | The tower's power light goes out. `erebor` is exported on the way down |
| 4 | `trinity` | `ssh rabbit@10.0.99.40 sudo systemctl poweroff` | The ProDesk's light goes out. AdGuard goes with it |
| 5 | `morpheus` | The pfSense console on the KVM, option *Halt system* | The house loses internet, DNS and DHCP |

**Stop there.** Leave `neo` and the UPS on: B.4 still needs the card.
`prometheus` and `oracle` keep running on their own batteries.

**If a hypervisor won't shut down** within five minutes, a guest is holding
it. Shut that guest down from its own console first. Don't hold the power
button on a hypervisor with running guests.

### B.4 Connect the Mac straight to the card

1. Unplug the card's network cable from `neo` and plug it into the Mac.
2. On the Mac, set the Ethernet adapter to *Manually*: address `10.0.99.50`,
   subnet mask `255.255.255.0`, no router.
3. Open `https://10.0.99.10` and log in.

### B.5 Turn the output off and update

1. *Control → UPS*, *Turn UPS Output Off*. Every outlet on `mjolnir` goes dead,
   `neo` with them. The card stays up on the UPS's own power.
2. *UPS → Configuration → Firmware Update*. Choose `SMX20UPS_15-0.enc` and
   click *Update UPS*. It takes several minutes. Don't touch the UPS until
   *Last Update Result* reports success and *Current Version* reads `UPS 15.0`.
3. If the file transfers but the update never starts, APC's FAQ000258690
   covers finishing it.

### B.6 Bring everything back

1. *Control → UPS*, *Turn UPS Output On*. Every outlet is live again, and
   `neo` boots on its own.
2. Plug the card's cable back into `neo`. Set the Mac's adapter back to DHCP.
3. Power the hosts up, in this order:

   | Order | Host | How | You should see |
   | --- | --- | --- | --- |
   | 1 | `morpheus` | From the KVM, pressing its power button if it hasn't started on its own | The console reaches its menu. The house gets DHCP and internet. `nc -z -w2 10.0.99.1 22` from `prometheus` succeeds |
   | 2 | `trinity` | It powers on by itself (*After Power Loss: Power On*) | It boots unattended; the TPM unseals its root disk. If it stops at a passphrase prompt, read ADR-0054 before typing anything |
   | 3 | `Saruman` | *Momentary Press* in the iLO at `10.0.30.10` | Its guests start on their own |
   | 4 | `smaug` | Its front button | `erebor` imports, and the shares are back |
   | 5 | `gandalf` | Its front button. It's set to stay off after a power loss | The Proxmox UI at `https://10.0.30.30:8006` answers. `ragnarok` stays off until its timer or you start it |

4. **Delete the silence before reading anything,** then resume what B.2
   paused: the healthchecks.io check, and the converge timer:

   ```bash
   curl -sS -X DELETE http://localhost:9093/api/v2/silence/<UUID from B.2>
   sudo sed -i '/^HOMELAB_CONVERGE_APPLY=0$/d' /etc/default/homelab-timers
   ```

5. **Verify,** on `prometheus`, five minutes after the last host is up:

   ```bash
   cd ~/code/Gerrrt/HomeLab
   make ps
   make ps STACK=sensitive
   make check-firewall
   curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=up == 0'
   ```

   Every container is healthy, no target is down, and the only alerts are
   the ones that were standing before the window.
6. On `morpheus`, `upsc mjolnir ups.firmware` reads `UPS 15.0 (ID20)`, and
   `UpsLowBatteryDurationShort` and `UpsRideThroughShort` are quiet.
7. Update [`hardware.md`](../hardware.md#management), add a changelog entry,
   and close #1698 if Part A is also done.

## If something goes wrong

| What | Do |
| --- | --- |
| `scp` is refused or hangs | SSH must be on under *Configuration → Network → Console → Access*. Try `ssh -v` to the card to see which algorithm it rejects. Don't turn on FTP instead |
| The card doesn't come back after A.4 | Wait the full ten minutes. Then press the card's reset button once and release it immediately, which reboots it. Don't hold the button down |
| The card is back, but the SNMP scrape fails | See A.5 step 2. The scrape credentials are in `secrets/observability.sops.yaml` and don't change with firmware; the card's profiles might |
| The UPS update fails in B.5 | Leave the output off. Retry once. If it fails again, bypass the UPS so the house isn't waiting on APC support. Move all three of its loads to wall outlets: the PDU (group 1), both laptops' chargers (group 2) and the MokerLink (group 3), as mapped in [`hardware.md`](../hardware.md). Plug the card's cable back into `neo`, then carry on from B.6 step 3. Nothing is on battery backup until the UPS is fixed, so open a case with APC the same day |
| The UPS reports a different ID | Don't load `SMX20UPS_15-0.enc`. Find the file for that ID in FA170679's table |
