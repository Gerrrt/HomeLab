# Runbook: Restore the firewall

**Target:** `morpheus` — the pfSense box every VLAN terminates on
**Time:** 20 minutes with a prepared spare; considerably longer without one
**You will need:** a recent backup, the age key, the pfSense installer on the USB
stick kept in the rack beside the KVM, and physical access to the rack

`morpheus` is the single point of failure in this lab. It routes all seven
VLANs, serves DHCP on every tagged interface, and is the only path to the
internet. When it is down the house has no network — not degraded, none. The
firewall is also the one device whose loss cannot be worked around from the
network, because the network is the thing it provides.

> [!CAUTION]
> Read the whole procedure before starting. A partially-restored firewall that
> is handing out DHCP leases on the wrong interfaces is worse than one that is
> switched off, because devices will renew against it and cache the result.

---

## 0. Before anything breaks

Two things must be true, and neither is automatic.

**A current backup exists.**

```bash
make backup-firewall        # pull, encrypt, verify
make backup-firewall ARGS=--list
```

The output lands in `backups/firewall/`, which is gitignored. It is
SOPS-encrypted with the same age recipient as everything else in
[`.sops.yaml`](../../.sops.yaml).

**It lives somewhere other than the machine that made it.** A backup on
`prometheus` protects against `morpheus` failing and nothing else. Copy it to
the backup target and offsite. This is the step that gets skipped, and it is the
step that matters — see [`roadmap.md`](../roadmap.md).

Re-run the backup **after every firewall change**, not on a schedule. A config
that predates the change you are trying to recover from restores you into the
problem.

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

Decrypt the backup somewhere that has the age key:

```bash
sops --decrypt --input-type binary --output-type binary \
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

That proves the file decrypts and parses. It does **not** prove it restores.
For that, restore it onto the spare, boot it, and confirm §4 on a bench — with
the WAN cable unplugged and the spare off the production switch, so two devices
never serve DHCP on the same segment. Until that has been done once, this
runbook is a hypothesis.
