# Runbook: Replace a disk in `erebor`

**One faulted Exos, two trays and no spare, and a dataset that had no copy
anywhere else — so the copy came first, on 2026-09-20, and the tray waits
for the copy, the wipe and the return label.**

> **Status — 2026-09-20, evening: steps 1–3 are done and the runbook waits
> where the return does.** Step 1 is read and it is the drive; step 2 is
> done by path A; step 3 is open: the eBay return was started on 2026-09-20,
> the label is due by **2026-09-24**, the seller has not yet chosen refund or
> replacement, and Seagate's warranty by serial is unchecked. The pool runs
> on one disk, `erebor/apps` has a copy off it since 2026-09-20, and since
> the exporter came back nothing in the estate is paging for the pool —
> though TrueNAS's own alert did reach a mailbox, see below. **What does not
> wait is step 4**: the faulted disk is offlined, wiped and shipped before
> any replacement exists, because the return runs that way round; step 5 is
> what happens when a drive arrives, from the seller or from a purchase.
>
> | When (PDT, 2026-09-19) | What |
> | --- | --- |
> | 20:46 | `up{job="node",instance="smaug"}` went 1 → 0 and stayed there. TCP 9100 still accepts; `GET /metrics` never returns — `curl -m 30` gives up with exit 28. A collector is blocked behind the faulted device. |
> | 20:50 | `InstanceDown` firing, critical, routed to `urgent`. Still firing. |
> | 20:55 (03:55 UTC 2026-09-20) | TrueNAS: *"Pool erebor state is ONLINE: One or more devices are faulted in response to persistent errors. Sufficient replicas exist for the pool to continue functioning in a degraded state. Disk ST18000NM003D-3DL103 ZVTBSDL3 is FAULTED"* |
>
> `ZVTBSDL3` is `sdb`, at about **lifetime hour 27** — one day after it
> arrived, and about an hour after the extended self-test
> [`build-the-nas.md`](build-the-nas.md) §2 started had completed without
> error at hour 26. The other half of the mirror, `ZVTBS4NL` (`sda`), carries
> everything.
>
> **`erebor/apps` had zero copies off `smaug` when this was written.**
> `scripts/backup-nas.sh` had merged on 2026-09-19
> ([#554](https://github.com/Gerrrt/HomeLab/pull/554)), but on the
> monitoring host `backups/nas` did not exist, `homelab-backup-nas.timer`
> was not installed, `ssh frodo@10.0.40.30` was refused, and §6.2 was marked
> *Not yet done*. That was step 2, and it was why the tray waited.
> **Done 2026-09-20, path A:** §6.2 steps 1–8 ran; the first set is
> `20260920T060234Z` — 76 entries, `./data/jellyfin.db` present, Jellyfin
> never stopped — copied to `oracle` and hashed there in the same run,
> `make verify-backups` re-read it, and the timer is installed.
> [#484](https://github.com/Gerrrt/HomeLab/issues/484) closed on it, so the
> tray no longer waits on this.
> [#558](https://github.com/Gerrrt/HomeLab/issues/558) carries the swap.
>
> **Step 1 read at the console, 2026-09-19 23:19 PDT. It is the drive, and
> the return is the answer.** `zpool status -v erebor`: pool `ONLINE`,
> `mirror-0` `ONLINE`, the `24c4970d…` leaf `FAULTED` with **3 read, 99
> write, 0 checksum** errors, "too many errors", `errors: No known data
> errors`. `dmesg` from 20:47:12 onward is one shape only: `Sense Key: Not
> Ready`, *Logical unit not ready, cause not reportable*, commands timing
> out at 60 s and aborted, a target reset that succeeded and changed
> nothing, reads and writes failing at sector 0, at 2080, and at the far end
> of the disk alike — the drive going away, not the path. No link resets, no
> `SError`, no CRC. SMART at lifetime hour 32: overall `PASSED`, **850
> pending and 850 offline-uncorrectable sectors** where both read 0 on
> 2026-09-18, `Command_Timeout` normalised to **1**, no reallocations, error
> log empty, the extended self-test still logged as completed clean at hour
> 26. FARM says which head: **all 850 reallocation candidates are on head
> 5**, 124 command timeouts, 179 hardware resets, 12 V and 5 V rails inside
> spec, 28 °C. The fault was at about **lifetime hour 27**, one hour after
> the self-test that passed.
>
> **The exporter came back on `docker restart media-node-exporter`** at
> 23:26 PDT (06:26 UTC 2026-09-20): `/metrics` in 46 ms, every collector
> reporting success, `up` back to 1 on the next scrape, `InstanceDown`
> resolved. **And that is the problem.** The kstat behind
> `node_zfs_zpool_state` reads `online` for `erebor` — the pool state, which
> `zpool status` also prints as `ONLINE` — so `ZpoolNotOnline` sees nothing,
> and from 23:27 PDT **no alert in the estate is firing for a mirror running
> on one disk.** The only thing that noticed is TrueNAS's own alert — and it
> reached further than the web UI, which this block said until 2026-09-20:
> TrueNAS Connect emailed it to the operator's mailbox at 03:55:49 UTC, 37 s
> after it fired, and it was read there the next day. Whether a mailbox is a
> phone channel is in *What is still open*.

`smaug` is the TrueNAS host at `10.0.40.30` on CasaBonita, which is terminal
outward ([ADR-0016](../adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)):
the monitoring host reaches `9100` and, since §6.2 was done on 2026-09-20,
`22`, and nothing else. So the console steps below are done **at the machine** (option 8, *Open
Linux Shell*) or in the TrueNAS UI at `https://10.0.40.30` from a Hicks
workstation, and the monitoring host's part is reading the result. The pool
is a mirror of two Seagate Exos X20 18 TB in the TS150's two 3.5" trays;
`sda` is `ZVTBS4NL` and `sdb` is `ZVTBSDL3`, but **the serial on the drive
label settles which tray is which, not the letter** — letters are assigned
at enumeration and a reboot can swap them.

## Why this is urgent, and why it is not an emergency

Urgent: a mirror of two with one device out has no redundancy. Everything on
`erebor` is on one spinning disk, and `erebor/apps` — Jellyfin's users,
watch history, resume positions, and its password hashes — is the half
[ADR-0008](../adr/0008-place-services-by-data-trust.md) ruled irreplaceable
and it is on nothing else. The return clock is running too: the pair was
delivered on 2026-09-18 and the eBay Money Back Guarantee is thirty days from
delivery, so a return has to be opened by **2026-10-18**.

Not an emergency: the pool is serving, `erebor/media` is replaceable by
decision (§4 of the build runbook), and with two trays and no spare there is
nothing that can be done today that adds redundancy — the pool runs on
`ZVTBS4NL` alone until a replacement drive is in the house, whatever the
order of the steps. That is the argument for doing the copy carefully rather
than the swap quickly.

## 1. Triage at the console, and get the exporter back

At the console, before anything else, and every reading goes into the
status block above:

```bash
zpool status -v erebor
```

Record the pool's `state:` line verbatim. TrueNAS's alert said the pool is
`ONLINE` with a `FAULTED` leaf; if `zpool status` says `DEGRADED`, the
kstat `node_zfs_zpool_state` reads will say so too and `ZpoolNotOnline` can
see it. If it also says `ONLINE`, the pool-level metric cannot see a faulted
mirror leaf at all, and that goes in *What is still open*.

```bash
readlink /sys/block/sdb
dmesg -T | grep -iE 'ata[0-9]|sdb'
```

The `readlink` names the `ataN` port `sdb` is on, so the `dmesg` lines can
be matched to it. Two shapes, read differently:

- **`hard resetting link`, `SError`, `link is slow to respond`, `failed
  command: READ FPDMA QUEUED` with a status of `DRDY` and no media error** —
  the path, not the platter: cable, port, or power. §1 of the build runbook
  records that this supply has no 3.3 V on pin 3, so the Power Disable trap
  does not apply, but a data cable seated on the day the drive went in is a
  real suspect. Power down, reseat both connectors on that drive, power up,
  `zpool clear erebor`, and watch `zpool status` for an hour. If it stays
  clean, this runbook ends at step 6 with a cable named instead of a disk.
- **`UNC`, `media error`, `I/O error`, `Buffer I/O error on dev sdb`** —
  the platter. Continue.

```bash
smartctl -a /dev/sdb
smartctl -l selftest /dev/sdb
smartctl -l farm /dev/sdb
```

`SMART overall-health`, `Reallocated_Sector_Ct`, `Current_Pending_Sector`,
`Offline_Uncorrectable`, and the *SMART Error Log* are the lines. All four
read `0` and `PASSED` on 2026-09-18 and the self-test log read clean at
hour 26; what has changed since is the finding. `-l farm` is for the hours
counter, so the lifetime hour of the fault is a number rather than an
estimate.

Then the exporter. Its container is `media-node-exporter`
([`stacks/media/compose.yaml`](../../stacks/media/compose.yaml)):

```bash
docker restart media-node-exporter
```

and from the monitoring host:

```bash
curl -s -m 15 http://10.0.40.30:9100/metrics | grep 'node_zfs_zpool_state{.*zpool="erebor"' | grep ' 1$'
```

If it answers, `up` returns to 1 on the next scrape and the pool-state rule
is live from that scrape on. If it hangs again, the collector is blocked
behind the device and will stay blocked until step 4 takes the device out;
say so in the status block. **Do not silence `InstanceDown`**: while the
exporter is down it is the only signal there is, and Alertmanager's inhibit
rule means a silence on it hides nothing else. **Do not disable the zfs
collector** to make the scrape green — a green scrape with no pool state is
worse than a red one.

## 2. Copy `erebor/apps` off, before anything touches a tray

Path A is the design, and it is preferred: do
[`build-the-nas.md`](build-the-nas.md) §6.2 steps 1–6, then on the
deployment checkout of the monitoring host:

```bash
make backup-nas && make backup-nas ARGS=--list && make verify-backups
```

and §6.2 step 7, `make install-timers`, once the first pull has passed, so
this copy is the first of a series rather than the only one.

> **Done 2026-09-20 for this fault, by path A.** The set is
> `20260920T060234Z`, on the monitoring host and on `oracle`; the timer's
> next run is Sat 2026-09-26 03:30 UTC.

Path B is for the evening §6.2 cannot be done. A USB stick at the console,
reading from the **newest snapshot** (§4.1) so that Jellyfin never stops and
the SQLite files are captured at one instant:

```bash
lsblk
mkdir -p /mnt/usb && mount /dev/sdX1 /mnt/usb
ls -1 /mnt/erebor/apps/.zfs/snapshot/
tar --numeric-owner -czf "/mnt/usb/erebor-apps-$(date -u +%Y%m%dT%H%MZ).tar.gz" \
  -C /mnt/erebor/apps/.zfs/snapshot/<newest> . && sync
tar -tzf /mnt/usb/erebor-apps-*.tar.gz | grep 'jellyfin/config/data/jellyfin.db'
umount /mnt/usb
```

`sdX` is the stick — `lsblk` shows it as the device that is neither an
18 TB Exos nor the 223.6 G boot SSD — and the `grep` is the sentinel
that #554 chose: no `jellyfin.db` in the listing, no backup. Say plainly what
path B is: **plaintext, on a stick, including Jellyfin's password hashes.**
It is encrypted on the monitoring host or destroyed the day path A exists,
and it does not leave the house in between.

## 3. Start the return, and decide the replacement

The pair is eBay item
[237056026029](https://www.ebay.com/itm/237056026029). Open a return under
the Money Back Guarantee as *item not as described / defective* **before
2026-10-18**; the seller chooses refund or replacement, and either is fine
for the pool. Check Seagate's own warranty at
<https://www.seagate.com/support/warranty-and-replacements/> — the form
wants the serial and the **BPID** off the drive label, so this is done with
the tray out at step 4; an "0HR" lot may be OEM stock Seagate will not
cover, and the answer, either way, goes in
[`hardware.md`](../hardware.md)'s Exos entry.

> **Done 2026-09-20, as far as this house can do it.** The return was opened
> under the guarantee on 2026-09-20 as *defective*, and eBay says the label
> arrives by **2026-09-24**. The seller has not yet chosen refund or
> replacement, so the decision below is pending on them, not on this
> runbook. Seagate's warranty check could not be done from the console:
> the form asks for the **BPID**, which is printed on the drive label
> between the QR code and *verify.seagate.com* and is in no SMART or FARM
> field, so it is read at step 4 with the tray out — scanning the label's
> QR code opens the verification page with it filled in — and the answer
> is still owed to `hardware.md`. Nothing was bought, so
> [`roadmap.md`](../roadmap.md)'s buy list did not move.

The decision point, and the seller answers it first: a replacement from
the seller means no purchase; a refund, or a return that will take weeks,
means buying an 18 TB outright to close the redundancy gap sooner — and a
purchase means a row in [`roadmap.md`](../roadmap.md)'s buy list in the same
commit, which is its rule. A third drive as a cold spare is the same question asked once more,
and the answer is recorded here when it is made.

Ship the faulted drive only after step 2's copy is verified and step 4's
wipe is done, or its refusal recorded. The pool loses nothing by keeping it
in the tray until the label is in hand; it is contributing nothing.

## 4. Offline, wipe, and ship

This runs now, before any replacement exists, because the return runs that
way round: the seller receives the faulted disk first and chooses afterwards.
The pool is not encrypted (§3 of the build runbook) and the disk held the
library and Jellyfin's password hashes, so it is wiped — or its refusal to be
wiped is recorded — before it goes in the box.

In the UI: **Storage → `erebor` → Manage Devices → the disk showing
FAULTED (`ZVTBSDL3`) → Offline.** Then, at the console, **find the device by
serial and not by letter**, because a reboot can swap `sda` and `sdb`, and
`shred` on the wrong one is the pool:

```bash
lsblk -o NAME,SIZE,SERIAL
smartctl -i /dev/sdX | grep -i serial
```

Only when both read `ZVTBSDL3` for the same `sdX`:

```bash
shred -n 1 -v /dev/sdX
```

One pass over 18 TB is about a day on a healthy drive. On this one, know what
stalling looks like: the fault's `dmesg` was sixty-second command timeouts
and *Logical unit not ready* on reads and writes alike, at sector 0 and at
the far end, so a `shred` whose progress line does not move for minutes is
the drive refusing writes, not a slow pass — and the MegaRAID spends a minute
on each one before it gives up. If it stalls, or never starts:

```bash
zpool labelclear -f /dev/sdX
dd if=/dev/zero of=/dev/sdX bs=1M count=1024 status=progress
dd if=/dev/zero of=/dev/sdX bs=1M count=1024 status=progress \
  seek=$(( $(blockdev --getsz /dev/sdX) / 2048 - 1024 ))
```

That removes the pool labels and the partition table, which is what makes
the disk mountable elsewhere; the data blocks remain, on a drive that would
not read them for its own controller. If the drive takes no writes at all,
the choice — ship it as it is, or keep it and take the refund fight — is the
operator's. Which of the three paths ran, and the date, go in the status
block and in [`hardware.md`](../hardware.md)'s Exos entry either way.

Then **System → Shut Down.** Power lead out, five seconds on the button to
drain the supply, ground yourself (§1 of the build runbook). Pull the tray
whose drive label reads `ZVTBSDL3` — read the label, not the letter — and
slide the tray back empty. **With the label in hand, photograph it and scan
its QR code**: that opens Seagate's verification page with the BPID filled
in, which is the warranty check step 3 could not do from the console, and
the answer goes in [`hardware.md`](../hardware.md). `ZVTBS4NL`'s label is
not read — its tray stays in, because the pool is on it. Leave the `AUX1_FAN` cage fan alone; it is the
airflow over both trays and §1 says why it is not optional. Power on:
`zpool status erebor` still reads `ONLINE` on one member with the other
`OFFLINE` or `REMOVED`, and `lsblk` shows one 18 TB device. Ship on eBay's
label, and the date it shipped goes in the status block.

## 5. Fit the replacement, resilver, scrub

When a drive arrives — the seller's replacement or a purchase, whichever
step 3 ends in. Power down as above. Fit it in the tray `ZVTBSDL3` left, on
the same data and power leads, so a cable that was the fault is found by the
next reading rather than hidden by a fresh one. **While the machine is at
POST, read the card's firmware version off its banner, or from *Ctrl-R* →
controller properties** — it is the one reading
[#571](https://github.com/Gerrrt/HomeLab/issues/571) is still owed, and
there is no other way to get it.

Power on, and **check that the new drive is there at all**: `lsblk` must
show a second 18 TB device. The bays are behind a MegaRAID SAS3008, not the
chipset (see *What is still open*), and a RAID card that is not in JBOD
mode holds a fresh disk as *Unconfigured Good* and shows the operating
system nothing. If `lsblk` has no new device, the card's own boot-time
utility (`Ctrl-R` during POST on a MegaRAID) is where the disk is made a
JBOD, and that reading — the card's firmware, its mode — goes in
[`hardware.md`](../hardware.md) the same evening. Then **read the new drive
before trusting it**, §2-style:

```bash
smartctl -a /dev/sdX
smartctl -l farm /dev/sdX
```

Serial, firmware, SMART and FARM hours into `hardware.md` — the FARM
counter is the one a reset cannot touch. Then in the UI: **Storage →
`erebor` → Manage Devices → the OFFLINE member → Replace → pick the new
disk → Replace.** `zpool status erebor` shows `resilver in progress`. A
mirror resilver copies allocated blocks only, so it is hours rather than the
day a full 18 TB would take, and `ZpoolNotOnline` fires for the whole of it
— that is the intended reading, not a fault. When it completes:

```bash
zpool scrub erebor
zpool status -v erebor
```

Wait for the scrub. The status must read `ONLINE` and `errors: No known
data errors` with `0 0 0` on every row. Start `smartctl -t long /dev/sdX`
on the new disk; it takes about 28 hours, and the result is a `hardware.md`
line.

## 6. Verify, and write it down

- `zpool status -v erebor` reads `ONLINE`, zeros on every row, scrub
  completed with 0 errors
- From the monitoring host, `curl -s -m 15 http://10.0.40.30:9100/metrics`
  carries `node_zfs_zpool_state{state="online",zpool="erebor"} 1`, and
  `up{job="node",instance="smaug"}` reads 1
- `ZpoolNotOnline` and `InstanceDown` are both resolved in Alertmanager,
  with no silence in place
- `make backup-nas ARGS=--list` on the monitoring host shows the set from
  step 2 (path A), and `homelab-backup-nas.timer` is in `systemctl
  list-timers`
- [`hardware.md`](../hardware.md)'s Exos entry carries the new serial, its
  readings, the outcome of the return and which wipe path step 4 took;
  [`build-the-nas.md`](build-the-nas.md) §7's `zpool status` line is true
  again
- [#558](https://github.com/Gerrrt/HomeLab/issues/558) closes on this list

## What is still open

- **Settled 2026-09-19: `zpool status` says `ONLINE` for a faulted mirror
  leaf, and so does the kstat.** `ZpoolNotOnline` cannot see this class of
  fault. It still catches a pool that is genuinely degraded, suspended or
  unavailable — a resilver, a second disk gone — but the one fault that has
  actually happened is below its resolution.
- **No vdev-level metric, and now nothing fires.** node_exporter exports
  pool state and nothing per device; [#483](https://github.com/Gerrrt/HomeLab/issues/483)
  is why nothing on `smaug` can push more. With the exporter restarted,
  `InstanceDown` has resolved and no alert in the estate covers the
  degraded mirror. **What does cover it, read 2026-09-20: TrueNAS Connect
  emailed the alert to the operator's mailbox 37 s after it fired**, so the
  line this runbook and #558 carried — that the alert reaches the web UI and
  nothing else — was wrong. It is a mailbox, not a phone, and it is a cloud
  service `smaug` initiates a connection to, which is
  [#483](https://github.com/Gerrrt/HomeLab/issues/483)'s subject. Two ways
  to something that pages were named here, and #483 chose the second for
  SMART:
  [ADR-0047](../adr/0047-collect-smaug-smart-through-a-root-cron-and-the-textfile-collector.md)
  runs the estate's collector as a root cron job on `smaug` and the exporter
  serves the file, so once [`build-the-nas.md`](build-the-nas.md) §6.4 runs,
  `SmartDriveBadSectors` fires per device on this host — and on this disk's
  850 pending sectors it would have, thirty minutes in, while the pool still
  said `ONLINE`. The faulted disk gets **no** baseline row; only the boot
  SSD's four static sectors are recorded, and that row is confirmed on the
  day (§6.4). The other half — a
  periodic task writing `zpool status` vdev states into the same textfile
  directory — rides the mechanism the ADR built and is its own follow-up.
  TrueNAS's own alert service stays where it is, a mailbox and the web UI,
  by decision rather than by default: the ADR declines it as the paging path.
- **The exporter's hang was the fault, not a habit.** It came back on a
  restart within seven minutes of the console session, so `InstanceDown` is
  the NAS disk alert only while the device is still timing out I/O. The
  runbook now says so at the top.
- **Settled 2026-09-19: the pair is behind a RAID card.** `lspci -nn` reads
  a **Broadcom / LSI MegaRAID SAS-3 3008 "Fury"**, `1000:005f`, at
  `01:00.0`, and both `sda` and `sdb` resolve under its `host0`; the
  chipset AHCI carries the boot SSD alone. [`build-the-nas.md`](build-the-nas.md)
  §1's `SATA2`/`SATA3` was wrong and now says so;
  [`hardware.md`](../hardware.md) carries the card. **Read the same
  night:** driver `megaraid_sas`, controller type `iMR(0MB)` — cacheless,
  no battery — subsystem `9340`, and `JBOD sequence map : enabled`, so the
  disks are **JBOD pass-through**, not virtual drives, which is why
  `smartctl` reaches them by their own model without `-d megaraid`. That is
  the better of the two answers a MegaRAID offers and still not the IT-mode
  HBA ZFS is designed for: the sixty-second timeouts, task aborts and the
  21:03:51 controller reset in the fault's `dmesg` are its firmware's error
  path, and ZFS waited on them. The firmware version is the one reading
  still owed, and it is not in sysfs — `/sys/class/scsi_host/host0/fw_ver`
  does not exist, and TrueNAS ships no `storcli` — so it is read off the
  card's POST banner or its *Ctrl-R* controller properties, at step 4 or 5,
  when the machine is at POST anyway. Whether to leave the
  card as it is, flash the 3008 to IT firmware (`1000:0097`), or cable the
  bays to the chipset's free `SATA0`–`SATA3` and take the card out is a
  decision for [#558](https://github.com/Gerrrt/HomeLab/issues/558) after
  the swap, not before it.
- **The replacement decision is the seller's first.** The return is open
  since 2026-09-20; refund or replacement is chosen after the faulted disk
  lands with them. A replacement means no purchase; a refund means an 18 TB
  bought outright and a row in [`roadmap.md`](../roadmap.md)'s buy list in
  the same commit. Whether a third drive follows as a cold spare is the same
  question asked once more.
- **Seagate's warranty is unchecked, and cannot be from the console.** The
  form wants the BPID off the drive label, which SMART and FARM do not
  carry, so the lookup is a step 4 reading with the tray out; whether an
  "0HR" lot is covered goes in [`hardware.md`](../hardware.md)'s Exos entry
  either way.
