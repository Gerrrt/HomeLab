# Runbook: Restore the firewall

**Target:** `morpheus` — the pfSense box every VLAN terminates on
**Time:** about 40 minutes onto the spare — 42 on the 2026-09-27 rehearsal,
firmware surprises included; considerably longer without a spare
**You will need:** a recent backup (on `prometheus`, or its copy on `oracle`),
the age key (on `prometheus`, or its offline copy), the pfSense installer on
bootable media, and physical access to the rack

> [!NOTE]
> The USB stick holding the installer lives in the rack beside the KVM. It is
> the **Netgate Installer**, not a pfSense image: CE has had no offline
> installer since 2.7.2, so the stick downloads the release during the install
> and **needs the internet on the onboard port while it runs** — on the day,
> that is the ISP gateway, cabled straight in (§3).
> See [`hardware.md`](../hardware.md#accessories).

`morpheus` is the single point of failure in this lab. It routes six VLANs and
the untagged switch-management LAN — seven internal networks in total — serves
DHCP on every tagged interface, and is the only path to the internet. When it is down the house has no network — not degraded, none. The
firewall is also the one device whose loss cannot be worked around from the
network, because the network is the thing it provides.

> [!CAUTION]
> Read the whole procedure before starting. A partially-restored firewall that
> is handing out DHCP leases on the wrong interfaces is worse than one that is
> switched off, because devices will renew against it and cache the result.

---

## 0. Before anything breaks

Two things must be true. The nightly `homelab-backup-firewall` timer does both
([`schedule-maintenance.md`](schedule-maintenance.md)); run it by hand **after
every firewall change** as well, because a config that predates the change you
are trying to recover from restores you into the problem.

**A current backup exists.**

```bash
make backup-firewall        # pull, encrypt, verify, copy to oracle
make backup-firewall ARGS=--list
```

The output lands in `backups/firewall/`, which is gitignored. It is
SOPS-encrypted with the same age recipient as everything else in
[`.sops.yaml`](../../.sops.yaml).

**It lives somewhere other than the machine that made it.** A backup on
`prometheus` protects against `morpheus` failing and nothing else, so the same
run copies every export to `oracle` — `atropos@10.0.99.30:backups/firewall` by
default, `FW_OFFHOST` to change it — and **fails if it cannot**. A local file
with no copy is reported as a failed job, not a partial success, so the nightly
timer's `ScheduledJobFailed` is also the alarm for "the config has stopped
leaving this host". `oracle` holds ciphertext only. The age key is not there and
must never be put there; the copy is verified by pulling the bytes back and
comparing them with the file that was just proven to decrypt.

```bash
make backup-firewall ARGS=--verify-only   # newest export decrypts here, and is byte-identical there
```

That is off-host, not offsite. Both laptops share a shelf, a mains circuit and
a roof. The copy beyond them is the newest export on the second age
recipient's medium, carried there on its ninety-day visit
([ADR-0048](../adr/0048-carry-the-estates-backup-sets-with-the-second-recipient.md),
[`copy-the-backups-offsite.md`](copy-the-backups-offsite.md)); restoring from it starts by
copying that one file back into `backups/firewall/`.

**How far back you can reach.** The same run applies retention: the newest
`FW_KEEP` exports survive on each side and the rest are removed, so a nightly
job cannot grow without bound. The default is thirty, which at one export a
night is about a month — long enough to reach back past a bad firewall change
nobody noticed for a fortnight, which is the window that actually matters here.
Raise it with `FW_KEEP` in `/etc/default/homelab-timers` if you want longer; an
export is a couple of hundred kilobytes, so this is cheap. `FW_KEEP` and not
`KEEP`, because every unit reads that same file and `make backup` already uses
`KEEP` for volume sets, which are measured in gigabytes.

Retention never removes the newest export, never touches a file this script did
not write, and on `oracle` also clears the `.part` fragments a copy that died
mid-transfer leaves behind. `ARGS=--list` is its dry run — it marks exactly what
the next run would remove — and `ARGS=--prune` applies it without taking a new
export:

```bash
make backup-firewall ARGS=--list
```

The copy needs two things once, both done on `prometheus` as `robo`. Accept
`oracle`'s host key, so `BatchMode` has something to check against:

```bash
ssh atropos@10.0.99.30 true
```

Then authorise this host's key there — it prompts for `oracle`'s password one
time:

```bash
ssh-copy-id atropos@10.0.99.30
```

The next `make backup-firewall` seeds `oracle` with every retained export
already on disk, not just the new one, and every later run copies whatever
`oracle` is missing — a night it was switched off is caught up the night after,
and a stretch longer than `FW_KEEP` converges in a single run. Until both
steps are done every nightly run fails on its copy step, which is the correct
reading of the situation. If the user or path on `oracle` differ, set
`FW_OFFHOST=user@host:dir` in `/etc/default/homelab-timers`, which the unit
reads.

---

## 1. Decide which failure you have

| Symptom | Likely cause | Go to |
| --- | --- | --- |
| No link, no console, no power LED | Hardware | §3, full rebuild |
| Boots, console responds, no traffic passes | Config or interface assignment | §2 |
| Boots to a bootloader prompt or panics | Filesystem or upgrade damage | §3 |
| Reachable but rules behave wrongly | Config only | §2 |

Reach the console through the KVM at rack **U6**. Do not skip this — a box that
looks dead on the network is often fine at the console, and §2 is far faster
than §3.

---

## 2. Restore the configuration onto working hardware

If `prometheus` is what died, or is unreachable, take the copy from `oracle`
first. The age key is not there; bring it from its offline copy
([`back-up-the-age-key.md`](back-up-the-age-key.md)):

```bash
ssh atropos@10.0.99.30 ls -1r backups/firewall
```

```bash
scp atropos@10.0.99.30:backups/firewall/config-<STAMP>.sops.yaml backups/firewall/
```

Decrypt the backup somewhere that has the age key. `--input-type yaml`, not
`binary`: the file is a YAML document holding an encrypted blob, and the
`binary` form this runbook carried until 2026-09-03 fails on the first byte
with *Error unmarshalling input json*. `make backup-firewall` decrypts the same
way on every run, which is how the runbook was found to disagree with it.

```bash
sops --decrypt --input-type yaml --output-type binary \
  backups/firewall/config-<STAMP>.sops.yaml > /tmp/config.xml
```

> [!CAUTION]
> `/tmp/config.xml` is the complete firewall in cleartext: WAN address, every
> rule, user password hashes. Delete it the moment you are done —
> `shred -u /tmp/config.xml` — and never place it anywhere tracked by git.
> [`scripts/validate.sh`](../../scripts/validate.sh) and CI both assert that
> nothing under `backups/` is tracked, but they cannot see `/tmp`.

Then in the pfSense UI: **Diagnostics → Backup & Restore → Restore
configuration**, choose *ALL*, upload the file. It reboots itself.

If the UI is unreachable, copy the file to `/cf/conf/config.xml` over the
console or SSH and reboot. The file must be owned by `root` and mode `0600`.

---

## 3. Rebuild onto a spare

**The spare should be the same model as `morpheus`** — an HP ProDesk 600 G4
Mini — **with the same second NIC fitted.** This is not fussiness. pfSense
stores interface assignments by device name, so identical hardware restores
straight through, while different hardware drops you into the
interface-assignment dialogue at the console, at whatever hour this is
happening. What `morpheus` actually has, read off the box on 2026-09-09:

| Device | Hardware | Carries |
| --- | --- | --- |
| `em0` | The onboard Intel I219-LM | WAN |
| `igc0` | An Intel I226-V 2.5 GbE card on an M.2 B+M-key adapter, in the G4's second M.2 slot ([`network.md`](../network.md#lan)) | The untagged switch-management LAN, and every VLAN (`igc0.10` … `igc0.99`) |

There is no USB NIC. This runbook said there was until 2026-09-09, borrowing
the label from the footnote in `network.md` that called the M.2 card a "USB
NIC adapter", and [#404](https://github.com/Gerrrt/HomeLab/issues/404) put one
on the shopping list on the strength of it. A USB adapter comes up as `ure0`
or `axge0`, a Realtek card as `re0`; either way the config's `igc0` does not
exist at boot, and pfSense stops at the console to ask which interface is
which — the exact outcome the same-model rule exists to avoid. The card is
the part that makes the restore go straight through; the box only has to
have a slot for it. Any card the `igc` driver claims (an I225 or I226) will
do, because a single such card is `igc0` whichever slot it sits in.

The same model does not give you the WAN MAC. Nothing in the config pins a
MAC to any interface, so the spare presents its own onboard MAC to the ISP;
if the lease `morpheus` held is tied to it, expect to power-cycle the modem
and expect a different public address.

**The spare is the sensitive tier's host**, by
[ADR-0034](../adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md):
the same model, running Immich and the rest. Step 0 is therefore wiping it,
and everything on it is gone until a replacement ProDesk arrives — order one
the same day (§5). **This section was rehearsed on that box on 2026-09-27**
([#92](https://github.com/Gerrrt/HomeLab/issues/92); the record is
[below](#rehearse-the-restore-on-the-spare)), and the steps are the ones that
worked, not the ones that were expected to.

0. **Fit the I226 card.** Since the rehearsal it is kept in the drawer, not
   in `trinity` ([`hardware.md`](../hardware.md)); it goes in the G4's second
   M.2 slot. Without it there is no `igc0`, and the restore stops to ask.
   **Then the firmware, before the stick will boot.** Two things on the G4 stop the
   installer, and both were found the hard way:
   - **Secure Boot.** The stick is refused with *"Selected boot image did not
     authenticate"*. F10 → Advanced → Secure Boot Configuration → *Legacy
     Support Disable and Secure Boot Disable*, F10 to save — and **type the
     four-digit code HP shows on the next boot**. Without the code the change
     is silently discarded and the same error comes back.
   - **The Wi-Fi.** `trinity` carries an Intel Wireless-AC 9560 the listing
     did not mention. FreeBSD's `iwm` claims it, fails to load its firmware
     (`iwm9000fw: could not load firmware image, error 6`), and the kernel
     panics in `firmware taskq` — on the installer and on the installed
     system alike. Switching Wireless LAN off in the BIOS does **not** stop
     it: the 9560 is CNVi, part of the chipset at PCI `20.3`. What does: at
     the loader menu press **3**, then `set hint.iwm.0.disabled=1` and
     `boot`. After the install, make it permanent from the console shell
     (option 8) before anything else —
     `echo 'hint.iwm.0.disabled="1"' >> /boot/loader.conf.local` —
     because pfSense rewrites `loader.conf` but not `.local`.
1. Install a pfSense release at least as new as the one the backup came from.
   **Restoring a config onto an older build can fail silently.** The
   `<version>` that `make backup-firewall` prints on every verify is the
   *config schema* — `24.6` on 2026-09-09 — not the release, and no installer
   is labelled with it. The release is `/etc/version` on `morpheus`:
   **pfSense CE 2.9.0-RELEASE**, build `20260817-1836`, on the same day, and
   recorded in [`hardware.md`](../hardware.md#compute) for the day `morpheus`
   cannot be asked. 2.9.0's own schema is `24.6`, so 2.9.0 is the floor for
   that export. The stick carries no release to check: the Netgate Installer
   lists what it can download, and on 2026-09-27 that was **2.9.0** — build
   `20260925-1514`, newer than `morpheus`'s build of the same release.
2. Cable the onboard port (`em0`) to something with DHCP and the internet —
   the ISP gateway on the day, any house port on a bench — and leave the card
   empty. The installer asks for WAN and then LAN, listing `igc0 (no carrier)`
   and `em0 (active)`: choose **WAN = `em0`, LAN = `igc0`**, keep DHCP on
   WAN and `192.168.1.1/24` on LAN, choose **Install CE**, the release, and
   ZFS on GPT across the one disk (`nda0`). Do not configure VLANs — the
   restore supplies all of it.
3. Restore per §2. The UI path works: a laptop on the card's port gets a
   `192.168.1.x` lease from the fresh install, and
   `https://192.168.1.1/diag_backup.php` takes the file (area *All*, not
   encrypted). On the rehearsal the box rebooted **straight to the console
   menu with every interface assigned — no assignment prompt** — WAN on `em0`,
   LAN on `igc0` at `10.7.7.1`, and all six VLANs on `igc0.10` … `igc0.99`.
   It then tries to reinstall the config's packages in the background, which
   needs the WAN; on a bench with the WAN unplugged it cannot, and a package
   the rules depend on is worth checking once the WAN is back.
4. Move the cables — there are two: ISP gateway to the onboard port (`em0`,
   WAN), and the trunk from switch port 1 to the I226 card's port (`igc0`).

---

## 4. Verify

Work down this list. Each step depends on the one above it.

```bash
# 1. Does it route at all?
ping -c3 10.0.99.1

# 2. Do the tagged interfaces exist? Expect a .1 on each VLAN.
for v in 10 20 30 40 50 99; do ping -c1 -W1 10.0.$v.1 >/dev/null \
  && echo "VLAN $v up" || echo "VLAN $v DOWN"; done

# 3. Is DHCP serving? From a client, release and renew, then confirm
#    the lease came from the right scope for that VLAN.

# 4. Is segmentation actually back? This is the one people forget.
#    From an IoT-segment device, both must FAIL:
ping -c1 -W1 10.0.99.20    # must not reach the observability stack
ping -c1 -W1 10.0.50.20    # must not reach a trusted workstation
```

Then confirm monitoring recovered:

```bash
# On prometheus — all four SNMP targets should return to up
curl -s http://localhost:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | select(.labels.job=="snmp")
           | "\(.labels.device)\t\(.health)"'
```

```bash
# 5. Are the segmentation tripwires back? A config restored from a backup taken
#    before 2026-09-01 does not have them, and their absence is silent.
#    Match the whole shape, not just "a logged pass rule" — another rule may
#    legitimately log one day, and a count alone would then pass while a
#    tripwire was missing.
ssh root@10.0.99.1 'pfctl -sr | grep -cE \
  "^pass in log quick on igc0\.(10|20|30|40) inet from <OPT[0-9]+__NETWORK> to <(Internal_Segments|House_Segments)>"'
# expect exactly 4 — one per terminal interface, plus the lab's (#234)

# And that all four interfaces are represented, not one of them four times:
ssh root@10.0.99.1 'pfctl -sr \
  | sed -nE "s/^pass in log quick on (igc0\.(10|20|30|40)) .* to <(Internal_Segments|House_Segments)>.*/\1/p" \
  | sort -u'
# expect igc0.10, igc0.20, igc0.30, igc0.40

# The lab's rule must point at House_Segments, not Internal_Segments: the
# latter names 10.0.30.0/24 itself, and against it every DNS query from the lab
# to its own gateway logs as a crossing.
ssh root@10.0.99.1 'pfctl -sr | grep -E "^pass in log quick on igc0\.30 " | grep -c "<House_Segments>"'
# expect 2 since 2026-09-22 (#442): the lab's own tripwire and the WireGuard
# peers'. 1 means the tunnel's tripwire did not survive the restore.

# 6. ADR-0042's rules, built 2026-09-22 (#442). The check above counts
#    tripwires by their shape and the four in step 5 are sourced from an
#    interface network macro, which the tunnel's is not — so the tunnel's
#    tripwire and its blocks need asking after separately, or a restore drops
#    them as silently as it drops the other four.
ssh root@10.0.99.1 'pfctl -sr | grep -c "<Tunnel_Peers>"'
# expect 12 as of 2026-09-22 — one tripwire plus eleven blocks (six inet, one
# per house segment, and five inet6 that a v4-only tunnel never matches) — and
# `pfctl -t Tunnel_Peers -T show` must print the peer
# subnet rather than an empty table — an alias that survived with no contents
# makes every rule using it match nothing, which reads as "no leaks".
```

> [!NOTE]
> Step 4 matters more than it looks. A restore that brings back connectivity but
> not the rule set leaves the house on a flat network that *appears* to work
> perfectly. Nothing will alert you: every device has internet, and the failure
> is invisible until something uses the access it should not have. Verify the
> denials, not just the paths.

And once the denials are verified, verify the thing that watches them.

> [!IMPORTANT]
> Step 5 is the same trap one layer down. The four tripwire rules
> ([#223](https://github.com/Gerrrt/HomeLab/issues/223),
> [#234](https://github.com/Gerrrt/HomeLab/issues/234)) are what let
> `TerminalSegmentReachedInternalNetwork` and `LabSegmentReachedInternalNetwork`
> fire at all: they are `pass` + `log` rules for
> `<terminal net> → Internal_Segments` on `igc0.10`, `igc0.20` and `igc0.40`,
> and `<lab net> → House_Segments` on `igc0.30`, sitting below the block rules
> and above the `→ any` egress rule. They log nothing while segmentation holds,
> so a restore that drops them looks exactly like a restore that kept them — and
> the alerts go quietly back to being unable to fire for any input. Re-add them
> before calling the restore done. A restore older than 2026-09-06 also brings
> back `Internal_Segments` without `10.7.7.0/24` and without the
> `House_Segments` alias at all, so check the aliases, not only the rules.

---

## 5. Afterwards

- Take a fresh backup from the restored box — the old one is now historical.
- If the spare was consumed, order another ProDesk the same day. Since ADR-0034
  the spare is the sensitive tier's host, so consuming it took the password
  manager, the photo library and Home Assistant down with the firewall, and
  they stay down until the replacement is built. A spare used once and not
  replaced is a spare you no longer have — and here it is also a tier you no
  longer have.
- Record what happened in [`roadmap.md`](../roadmap.md) if the cause is
  something the design should prevent.

---

## Verify the backup without a disaster

The restore path above is untested until you test it. The honest check, worth
doing once when nothing is on fire:

```bash
make backup-firewall ARGS=--verify-only
```

That proves the newest export decrypts and parses here, and that `oracle` holds
the same bytes. It does **not** prove it restores. For that, restore it onto
the spare, as below — done once, on 2026-09-27, and worth doing again whenever
the spare's hardware or the pfSense release changes.

## Rehearse the restore on the spare

**Done on 2026-09-27 ([#92](https://github.com/Gerrrt/HomeLab/issues/92)), and
it restored.** Its purpose was to find the questions §3 did not answer; the
answers are written back into §3, and this is the record.

| | |
| --- | --- |
| Box | `trinity`, the ProDesk 600 G4 DM (serial `MXL9243TVV`), I226-V card in the second M.2 slot, proved before the wipe ([`hardware.md`](../hardware.md)) |
| Export | `config-20260926T043704Z.sops.yaml`, **taken from `oracle`**, byte-identical to `prometheus`'s; schema `24.6`, 112 rules |
| Release | pfSense CE **2.9.0-RELEASE**, build `20260925-1514`, from the Netgate Installer |
| Time | **42 minutes** from power-on to verified, including finding the two firmware problems below |
| Result | Booted straight to the console menu — **no interface-assignment prompt** — with every interface where `morpheus` has it |

What it asked, in order, that §3 had not said:

1. *"Selected boot image did not authenticate"* — Secure Boot. Turning it off
   takes effect only after typing the four-digit code HP shows on the next
   boot; the first attempt skipped that and the error came back unchanged.
2. A kernel panic in `firmware taskq` — the Wireless-AC 9560 and `iwm`. The
   BIOS Wireless LAN switch did not stop it; `hint.iwm.0.disabled=1` did.
3. The installer needs the internet (there is no offline CE installer). It
   listed `igc0 (no carrier)` and `em0 (active)`, and was told WAN = `em0`,
   LAN = `igc0`.

What it showed, checked on the bench from the console shell and a laptop
(a MacBook on a USB adapter) on the card's port:

| Check | Expected | Got |
| --- | --- | --- |
| Interfaces | WAN `em0`, LAN `igc0`, six VLANs | WAN `em0`, LAN `igc0` `10.7.7.1/24`, `igc0.99` `.50` `.40` `.30` `.20` `.10` each on its `.1/24` |
| `grep -c '<rule>' /cf/conf/config.xml` | 112 | 112 |
| Tripwires (§4 step 5) | 4 | 4 |
| `pfctl -sr \| grep -c '<Tunnel_Peers>'` | 12 | 12, and the table holds `172.31.0.0/24` |
| Kea DHCP scopes | 6 | 6 — DHCP is **Kea**, not ISC `dhcpd`, on 2.9.0 |
| A client on a VLAN | a lease from that scope | the laptop, tagged into VLAN 99, leased `10.0.99.100` and pinged `10.0.99.1` |

Not covered on the bench, and left for the day: §4's segmentation checks and
the SNMP targets, which need the rack; and the package reinstall the restore
starts in the background, which needs a WAN the bench did not have.

> [!CAUTION]
> Bench, not rack. The spare must never be on the production switch or on the
> WAN while it carries `morpheus`'s config. Two boxes serving DHCP on one
> segment, or two boxes claiming the WAN address, is a worse outage than the
> one being rehearsed. The onboard port is on a house network **only during
> the install**, before the restore, and is unplugged before the restore.

To run it again:

1. Prove the machine first if it could still go back to a seller — spec,
   serial, NICs, disk health — because the install is the step that cannot
   be undone. Windows setup's own shell (Shift+F10) answers all of it without
   finishing setup or touching a network.
2. Take the newest export from `oracle`, not from `prometheus`, check
   `make backup-firewall ARGS=--verify-only` for its rule count, and decrypt
   it per §2 only once the bench is ready.
3. §3 steps 0–3 on the bench: firmware, install with the onboard port on a
   house network, **unplug it**, then restore from a laptop on the card's port.
4. The checks in the table above, then shred every plaintext copy
   (`shred -u`, or `rm -P` on macOS) and halt the box.
5. Write the date, the release, the stamp, the time and whatever asked a
   question into [`roadmap.md`](../roadmap.md) and into this section.
6. Hand the box back to what it is for. On 2026-09-27 that was
   [#404](https://github.com/Gerrrt/HomeLab/issues/404): it is wiped and built
   as the sensitive tier's host (ADR-0034), and nothing from the rehearsal
   survives on it. The powered-off shelf spare that used to be this step is
   deferred by that ADR; if it is ever bought, it racks on the U4 shelf beside
   the switch, **off**, and on the day the newest export from `oracle` is
   still restored over whatever it carries.
