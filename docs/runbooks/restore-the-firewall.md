# Runbook: Restore the firewall

**Target:** `morpheus` — the pfSense box every VLAN terminates on
**Time:** 20 minutes with a prepared spare; considerably longer without one
**You will need:** a recent backup (on `prometheus`, or its copy on `oracle`),
the age key (on `prometheus`, or its offline copy), the pfSense installer on
bootable media, and physical access to the rack

> [!NOTE]
> A USB stick holding the installer is on its way and belongs in the rack beside
> the KVM. **It is not there yet** — until it is, this runbook's first step is
> finding a machine that can write one, which is not a thing you want to
> discover during an outage.
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
a roof, and nothing yet copies anywhere a fire would not reach — see
[`roadmap.md`](../roadmap.md).

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
Mini. This is not fussiness. pfSense stores interface assignments by device
name (`igb0`, `em0`, …), so identical hardware restores straight through, while
different hardware drops you into the interface-assignment dialogue at the
console, at whatever hour this is happening. `morpheus` also uses a USB NIC for
the switch-management LAN, so the spare needs one too.

1. Install the same pfSense version the backup came from. **Restoring a config
   onto an older build can fail silently**; check the `<version>` field, which
   `make backup-firewall` prints on every verify.
2. Complete the installer with defaults. Do not configure interfaces or VLANs —
   the restore supplies all of it.
3. Restore per §2.
4. Move the cables: ISP gateway to WAN, trunk to the switch, USB NIC to switch
   port 1.

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
  "^pass in log quick on igc0\.(10|20|40) inet from <OPT[0-9]+__NETWORK> to <Internal_Segments>"'
# expect exactly 3 — one per terminal interface

# And that all three interfaces are represented, not one of them three times:
ssh root@10.0.99.1 'pfctl -sr \
  | sed -nE "s/^pass in log quick on (igc0\.(10|20|40)) .* to <Internal_Segments>.*/\1/p" \
  | sort -u'
# expect igc0.10, igc0.20, igc0.40
```

> [!NOTE]
> Step 4 matters more than it looks. A restore that brings back connectivity but
> not the rule set leaves the house on a flat network that *appears* to work
> perfectly. Nothing will alert you: every device has internet, and the failure
> is invisible until something uses the access it should not have. Verify the
> denials, not just the paths.

And once the denials are verified, verify the thing that watches them.

> [!IMPORTANT]
> Step 5 is the same trap one layer down. The three tripwire rules
> ([#223](https://github.com/Gerrrt/HomeLab/issues/223)) are what let
> `TerminalSegmentReachedInternalNetwork` fire at all: they are `pass` + `log`
> rules for `<terminal net> → Internal_Segments` on `igc0.10`, `igc0.20` and
> `igc0.40`, sitting below the block rules and above the `→ any` egress rule.
> They log nothing while segmentation holds, so a restore that drops them looks
> exactly like a restore that kept them — and the alert goes quietly back to
> being unable to fire for any input. Re-add them before calling the restore
> done.

---

## 5. Afterwards

- Take a fresh backup from the restored box — the old one is now historical.
- If a spare was consumed, order another. A spare used once and not replaced is
  a spare you no longer have.
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
the spare — and until that has been done once, this runbook is a hypothesis.

## Rehearse the restore on the spare

Nobody has done this yet. Its purpose is to find the questions §3 does not
answer — what a fresh install assigns to the one onboard NIC, whether the USB
NIC comes back under the same device name, how long the whole thing takes —
and to write the answers back into §3.

> [!CAUTION]
> Bench, not rack. The spare must never be on the production switch or on the
> WAN while it carries `morpheus`'s config. Two boxes serving DHCP on one
> segment, or two boxes claiming the WAN address, is a worse outage than the
> one being rehearsed.

1. Take the copy from `oracle`, not from `prometheus`: the rehearsal should
   exercise the copy that will matter on the day. Decrypt it per §2.
2. Spare on the bench, a laptop cabled directly to its onboard NIC, nothing
   else connected. Install pfSense from the USB stick, the same version as the
   backup's `<version>`, defaults throughout.
3. Restore per §2 — through the UI if the fresh install put a reachable LAN on
   that NIC, otherwise by writing `/cf/conf/config.xml` from the console
   shell. Record which one worked and what it asked.
4. After the reboot, at the console and then in the UI: every interface
   assigned with no assignment prompt, the rule count matching what
   `make backup-firewall` printed for that export, the three tripwire rules
   from §4 step 5, and every DHCP scope present. The segmentation checks in §4
   need the rack and stay for the day.
5. Write down the date, the pfSense version, the backup stamp, the time from
   power-on to verified, and everything that asked a question. Put it in
   [`roadmap.md`](../roadmap.md) under #92, fix §3, and delete the hypothesis
   sentence above.
6. Shred the plaintext, power the spare off, and rack it on the U4 shelf
   ([#110](https://github.com/Gerrrt/HomeLab/issues/110)) beside the switch —
   **off**. A restored spare on the shelf turns §3 into "move the cables and
   power on", at the cost of carrying a config that ages from the day it was
   restored; on the day, still restore the newest export from `oracle` over it
   before trusting it.
