# Runbook: Update the UPS firmware

**Two updates with very different costs.** The card's firmware (Part A) is a
file copy and a reboot of the card. It cuts no power, and the only side effect
is about five minutes in which nothing can read the UPS. The UPS's own
firmware (Part B) can't be installed with the UPS output on, on this model,
so it means shutting down everything `mjolnir` powers. Do Part A when it
suits you. Do Part B only inside a whole-estate outage that is already
planned for something else.

Part A ran on 2026-11-24 under [#1698](https://github.com/Gerrrt/HomeLab/issues/1698),
now closed. Part B is tracked in [#1731](https://github.com/Gerrrt/HomeLab/issues/1731).

## Read this part first

- **What runs today** (recorded in
  [`hardware.md`](../hardware.md#management)): the AP9641 card runs AOS
  3.6.1.2 with Smart-UPS application 3.6.1.2, installed by Part A on
  2026-11-24 from 2.0.0.6. The Smart-UPS X (ID 20) runs `UPS 09.8`. Part A
  stays as the procedure for the card's next release.
- **Part A installs 3.6.1.2, by a plain file copy.** Schneider's release notes
  and its FAQ FA156047 say the 3.x line installs only through the Secure NMC
  System (SNS) tool, with a paid subscription. Schneider support said
  otherwise on 2026-11-24: 3.6.1.2 installs with the free NMC Firmware Update
  Utility, without SNS or a subscription, and directly over 2.0.0.6. The
  utility only unpacks the package and copies the `.nmc3` to the card, which
  A.4 does by hand. The 2.5.x packages are no longer downloadable, so 3.6.1.2
  is the only file there is. If the card refuses it, the card keeps running
  what it had and nothing is lost: stop, and take it back to Schneider,
  citing the owner's support case from 2026-11-24. Its number is kept with
  the owner, not in this public repository.
- **No checksum is published for 3.6.1.2.** Earlier versions had a SHA-256
  on Schneider's community page; this version's notes, there and in the PDF,
  have none. A.1 checks the package's Authenticode signature instead, and the
  card checks the `.sig` inside the `.nmc3` before it installs anything.
- **There is no going back.** Firmware 2.0 or later can't be downgraded below
  2.0. Downgrading from 2.4 or later to anything below 2.4 formats the card,
  erasing its certificates, keys, configuration and logs. Treat Part A as one
  way: a later 3.x release may need the subscription after all.
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
   `APC_NMC3_SU_EN`) and download the **EXE**, `apc_hw21_su_3-6-1-2.exe`,
   about 4.3 MB. Check its size before copying it: a download refused by
   Schneider's CDN saves a page of a few hundred bytes under the same name.
2. Copy it to `prometheus`:

   ```bash
   scp ~/Downloads/apc_hw21_su_3-6-1-2.exe robo@10.0.99.20:
   ```

3. On `prometheus`, check the signature. `osslsigncode` isn't installed, so
   run it in a throwaway container from the pinned Debian `archiver` image. It
   needs the bridge network to install the tool and fetch DigiCert's CRL:

   ```bash
   cd ~/code/Gerrrt/HomeLab
   docker run --rm --network bridge -v ~/apc_hw21_su_3-6-1-2.exe:/w/fw.exe:ro \
     "$(./scripts/image-for.sh archiver)" sh -c \
     'apt-get -qq update >/dev/null && apt-get -qq install -y osslsigncode ca-certificates >/dev/null &&
      osslsigncode verify -in /w/fw.exe -CAfile /etc/ssl/certs/ca-certificates.crt' 2>&1 |
     grep -E 'CN=SCHNEIDER|Signature verification'
   sha256sum ~/apc_hw21_su_3-6-1-2.exe
   ```

   You want `O=SCHNEIDER ELECTRIC USA, INC.` and `Signature verification: ok`.
   *Timestamp Server Signature verification: failed* is expected: Debian's
   bundle lacks GlobalSign's timestamping root. The copy downloaded on
   2026-11-24 hashed to
   `260e20e3c812e95cc5faed72bfd8802d1acb5955ffcc37e55a042a6a79887cb7`.
4. Unpack it. The `.exe` is a 7-Zip archive:

   ```bash
   mkdir -p ~/apc-fw && cd ~/apc-fw && 7z x ~/apc_hw21_su_3-6-1-2.exe
   ls -1 Bins/*.nmc3
   ```

   You want exactly one `Bins/apc_hw21_su_3-6-1-2.nmc3`. It carries the
   Smart-UPS application 3.6.1.2, boot monitor 2.1.0.3 and their signature.
   The package also holds the Windows update utility; ignore it.

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
    --data "$(printf '{"matchers":[%s],"startsAt":"%s","endsAt":"%s","createdBy":"#NNN card firmware","comment":"#NNN mjolnir card firmware upgrade: the card reboots. Delete at A.5."}' "$m" "$START" "$END")"
  echo
done
```

Replace `#NNN` with the issue for the update; the silence collector reads
its owner from a comment that begins with one.

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
uses SFTP by default. If `scp` stops at *no matching key exchange method
found*, the client's SSH configuration allows only curve25519, which the card
doesn't offer. `prometheus`'s does. Name the card's algorithms for this
command and A.4's:

```bash
scp -O -o KexAlgorithms=ecdh-sha2-nistp256 -o HostKeyAlgorithms=ecdsa-sha2-nistp256 \
  -o Ciphers=aes256-ctr -o MACs=hmac-sha2-256 <superuser>@10.0.99.10:config.ini ./config-before.ini
```

These four worked on 2.0.0.6 on 2026-11-24; 3.6.1.2 offers them too. **Don't print or commit this file.** It can hold
credentials. It's there to compare settings against if the upgrade loses any,
and you delete it in A.5.

### A.4 Copy the firmware to the card

```bash
scp -O Bins/apc_hw21_su_3-6-1-2.nmc3 <superuser>@10.0.99.10:apc_hw21_su_3-6-1-2.nmc3
```

The card installs the file on receipt and reboots on its own, more than once,
because the package updates the boot monitor as well. Allow up to ten
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
with `#1731` in the silence's comment in place of `#919`.

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
   and close #1731.

## If something goes wrong

| What | Do |
| --- | --- |
| `scp` is refused or hangs | SSH must be on under *Configuration → Network → Console → Access*. Try `ssh -v` to the card to see which algorithm it rejects. Don't turn on FTP instead |
| The card doesn't come back after A.4 | Wait the full ten minutes. Then press the card's reset button once and release it immediately, which reboots it. Don't hold the button down |
| The card is back, but the SNMP scrape fails | See A.5 step 2. The scrape credentials are in `secrets/observability.sops.yaml` and don't change with firmware; the card's profiles might |
| The UPS update fails in B.5 | Leave the output off. Retry once. If it fails again, bypass the UPS so the house isn't waiting on APC support. Move all three of its loads to wall outlets: the PDU (group 1), both laptops' chargers (group 2) and the MokerLink (group 3), as mapped in [`hardware.md`](../hardware.md). Plug the card's cable back into `neo`, then carry on from B.6 step 3. Nothing is on battery backup until the UPS is fixed, so open a case with APC the same day |
| The UPS reports a different ID | Don't load `SMX20UPS_15-0.enc`. Find the file for that ID in FA170679's table |
