# Runbook: Fit the two SSDs in `Saruman`

**Two drives, no maintenance window, and a number that has to be measured on
both arrays — not assumed from either.**

> **Status — 2026-09-19: logical drive 2 and the thin pool exist, `alexander`
> is still on the spinners, and the number is still not measured.**
>
> Both SM863a drives were fitted on 2026-09-18 (step 4; the reading is kept in
> step 11's table). On 2026-09-19 they became **logical drive 2** — RAID 1,
> `cpqDaLogDrvPhyDrvIDs` `0x0203`, `915683` MB, stripe 256 — created through
> **step 2's path 3, the offline Smart Storage Administrator**, and not through
> `ssacli`, which is still not on the host. The iLO showed index `2` in the
> 13:40 UTC scrape, absent at 13:39, reading `Condition` and `Status` `2` ok
> from that first scrape with `PercentRebuild` never populated; both SSDs went
> `notConfigured(3)` → `configured(2)` in the same minute. Proxmox booted at
> 13:43 UTC and saw the new `LOGICAL_VOLUME` as `sdb`. The thin pool is
> **`large_data`** — that is the volume group, the pool and the storage id,
> which is what `pvesh create ... lvmthin --name` makes of one word — and its
> three device-mapper volumes appeared between 15:46 and 15:47 UTC, with one
> write burst of roughly 2.6 GB to `sdb` for the metadata and nothing since.
> [#527](https://github.com/Gerrrt/HomeLab/issues/527) tracks the rest.
>
> **Steps 4, 5 and 7 are done; 2, 3, 6, 8, 9, 10 and 11 are not.** Path 3
> means no `ssacli`, so the controller has never been read from the host and
> the cache reading owed to
> [#76](https://github.com/Gerrrt/HomeLab/issues/76) is still owed. Step 2's
> premise was wrong, though: HPE does publish a `trixie` suite, read from the
> SDR on 2026-09-19, so path 1 is an `apt-get` and is the next thing to run.
> LD 2 has
> `HasAccel` `1` other and `SSDSmartPathStatus` `1` other, the same as LD 1:
> step 6's two `modify` lines have not run. No fio on either array, no
> `move-disk`: `sda` reads are flat at the host's own ~50 KB/s and `sdb` has
> carried nothing since the pool was made. Step 1's silences were never
> created, and nothing needed them — `IloHardwareDegraded` never went pending.
>
> **What did fire was not what the runbook said would.** Step 2 said a reboot
> shorter than twenty minutes is quiet. Path 3 was not a reboot: the iLO power
> meter reads `0` W from about 23:00 UTC on 2026-09-18 to 13:43 UTC on
> 2026-09-19, so the host was off for fourteen and a half hours, and
> `RemoteWriteJobStale` (twice), `GuestStateStopped` and `PatchStateStopped`
> — all `warning`, all routed — fired and stayed up until the boot resolved
> them, with `HostRebooted` (`info`, unrouted) for eight minutes after. Step 2
> now says so, and what to silence if path 3 is taken again.
>
> **The label check was not done.** The serials in [`../hardware.md`](../hardware.md)
> are the iLO's, and the window step 4 described closed at 13:39 UTC when the
> drives joined an array. That is recorded, not argued about.
>
> **The wear columns are still blank now the drives are configured** —
> `cpqDaPhyDrvSSDWearStatus` `1`, endurance, power-on hours and estimated
> remaining hours all `4294967295`, `HasMonInfo` false, on both SSDs. That was
> the condition [#529](https://github.com/Gerrrt/HomeLab/issues/529) was
> filed against, and it holds: wear on the newest drives in the estate needs
> `smartctl` through `hpsa`, and #529 is no longer gated.
>
> **The layout is decided and the measurement is still not taken.** The SSDs
> are the *second* logical drive on the P440ar, RAID 1, Smart Array managed;
> the two 7.2K disks keep Proxmox, the ISOs and the backups. What that does
> not answer is the one thing the purchase exists for: the write IOPS this
> machine actually has. Step 8 measures it, on both arrays, with the
> parameters ADR-0029 derived its number from — and until that reading exists,
> no ADR here changes. The 2026-09-17 baseline in step 0 is still the *Before*
> column of every table here; the controller rows in it have not moved.

`shiva` is the iLO, not the hypervisor. The host behind it is `Saruman` at
`10.0.30.110`; see [`../hardware.md`](../hardware.md). Both are on VLAN 30.

## Where each step runs, and why it matters

VLAN 30 is not reachable from the monitoring host. That is not an inconvenience
to work around in this runbook — it is the reason the runbook is split the way
it is.

| Steps | Host | Who runs them |
| --- | --- | --- |
| 0, 1, 10, 11 | `prometheus`, `10.0.99.20`, VLAN 99 | the monitoring host — Prometheus and Alertmanager are here |
| 2–9 | `Saruman`, `10.0.30.110`, VLAN 30 | **you, from the Mac.** Nothing on VLAN 99 can reach this host |

Run the `Saruman` half inside `tmux`. A dropped SSH session during step 9's
disk move leaves a half-mirrored disk, and that is a worse afternoon than a
reconnect.

## Why this is not a maintenance window

The SFF bays are hot-plug and `qm move-disk` on a running guest is an online
operation, so **no guest stops and no alert needs to be scheduled around**.
[`schedule-maintenance.md`](schedule-maintenance.md) is not the shape of this
job. Two alerts still get silenced in step 1, not because anything is going
down but because a freshly created logical drive may legitimately report
`degraded` while the controller syncs it, and `IloHardwareDegraded` is
`severity: critical` with a ten-second `group_wait` on the `urgent` receiver.

## What this deliberately does not do

- **It does not change the controller-wide cache ratio.**
  `ssacli ctrl slot=0 modify cacheratio=` flushes and re-partitions the whole
  2 GiB module, and that pause lands on the logical drive holding Proxmox and
  every guest. Fitting two drives into empty bays is not the occasion to
  re-partition the cache the rest of the machine runs on. Step 6 *reads* the
  ratio — which is the reading
  [#76](https://github.com/Gerrrt/HomeLab/issues/76) has been waiting for since
  2026-09-02 — and hands the finding over. #76 owns the change.
- **It does not edit ADR-0029 or ADR-0007.** They are stale the day the
  measurement lands, not the day the drives land. See "Flipping the documents".
- **It does not touch the existing mirror.** No `delete`, no `modify raid=`,
  no `erase`, and nothing is pulled from bay 1 or bay 2.

---

## 0. Record the baseline — on `prometheus`, before anything

This is the step that makes the fit provable rather than assumed, and it is the
same argument [`replace-the-smart-storage-battery.md`](replace-the-smart-storage-battery.md)
makes: every other row in the after-table could in principle be the old
hardware reporting differently.

```bash
curl -sS -G http://127.0.0.1:9090/api/v1/query --data-urlencode 'query={__name__=~"cpqDa(Accel|Cntlr|LogDrv|PhyDrv).*",device="shiva"}' | python3 -m json.tool
```

Two more, because they are the only readings that come from the *host* rather
than the iLO, and they are how you prove in step 11 that the guest's writes
actually moved:

```bash
curl -sS -G http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=scrape_duration_seconds{device="shiva"}'
curl -sS -G http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=rate(node_disk_writes_completed_total{instance="Saruman"}[30m])'
```

**What that read on 2026-09-17**, and what each value is doing in this runbook:

| Reading | Value | Why it is here |
| --- | --- | --- |
| `cpqDaCntlrHwLocation` | `Slot 0` | every `slot=0` below depends on it |
| `cpqDaCntlrOperatingMode` | `2` smartArrayMode | not HBA mode — the chosen layout is the one the controller is already in |
| `cpqDaCntlrModel` / `FWRev` | `75` / `7.00` | the controller this runbook was written against |
| `cpqDaLogDrv*` index set | **`1` only** | the new one should become `2`; step 5 verifies rather than assumes |
| `cpqDaLogDrvFaultTol{1}` | `3` mirroring | the existing RAID 1 |
| `cpqDaLogDrvSize{1}` | `953837` MB | |
| `cpqDaLogDrvHasAccel{1}` | **`1` other** | not `3` enabled — see step 6 |
| `cpqDaPhyDrv*` index set | **`0` and `1`** | the new drives should become `2` and `3` |
| `cpqDaPhyDrvLocationString{0,1}` | `Port 1I Box 1 Bay 1` / `Bay 2` | bays 3 and 4 are the target |
| `cpqDaPhyDrvModel{0,1}` | `MM1000GBKAL` | |
| `cpqDaPhyDrvSerialNum{0,1}` | `9XG62LSC` / `9XG72NXP` | the rows that cannot be faked |
| `cpqDaPhyDrvMediaType{0,1}` | `2` rotatingPlatters | the SSDs must read `3` solidState |
| `cpqDaPhyDrvRotationalSpeed{0,1}` | `2` rpm7200 | the SSDs must read `5` rpmSsd |
| `cpqDaPhyDrvType{0,1}` | **`3` sata** | see "What this runbook does not know", item 12 |
| `cpqDaPhyDrvSmartStatus{0,1}` | `2` ok | |
| `cpqDaPhyDrvSmartCarrierAppFWRev{0,1}` | `11` | the existing drives are in HPE SmartDrive carriers, which have their own firmware — step 4's carrier precondition is not hypothetical |
| `cpqDaAccelStatus` | `3` enabled | must not move |
| `cpqDaAccelTotalMemory` | `2097152` KB | 2 GiB fitted |
| `cpqDaAccelMemory` (write) | **`0`** | 0 KB allocated, against 2 GiB fitted |
| `cpqDaAccelReadMemory` | **`0`** | |
| `cpqDaAccelWriteCachePercent` | **`0`** | #76 |
| `cpqDaAccelReadCachePercent` | **`0`** | |
| `cpqDaAccelBadData` | `2` none | must not move; `3` is a different conversation |
| `cpqDaAccelBattery` / `BackupPowerSource` | `2` ok / `4` smartbattery | the pack fitted 2026-09-02 |
| `cpqDaAccelFailedBatteries` | `1` | a known curiosity from #76, not a target here |
| `cpqDaCntlrDriveWriteCacheState` | `1` other | step 6 leaves this alone deliberately |
| `scrape_duration_seconds{device="shiva"}` | `11.8` s | against `SnmpScrapeSlow`'s 30 s |
| guests | one — `alexander`, vmid `140`, qemu | step 9 is one command, not a campaign |

**Four columns, not one.** #76 has been open on `cpqDaAccelWriteCachePercent`
reading `0`. The baseline above shows `cpqDaAccelMemory`,
`cpqDaAccelReadMemory`, `cpqDaAccelWriteCachePercent` and
`cpqDaAccelReadCachePercent` *all* reading `0` while
`cpqDaAccelTotalMemory` reports 2 GiB fitted, and `cpqDaLogDrvHasAccel{1}`
reading `other` rather than `enabled`. Four independent columns agreeing that
nothing is allocated is much weaker support for "the iLO simply does not
populate the ratio" than one column was. Step 6 is where that gets settled.

## 1. Silence the two alerts a new array legitimately trips — on `prometheus`

The repo documents *deleting* a silence
([`fit-the-ups-battery.md`](fit-the-ups-battery.md) §3) and has never written
down creating one. This is that call.

**Create these immediately before step 5, not before step 4.** On 2026-09-18
the drives went into bays 3 and 4 with no silence standing and nothing fired:
an unassigned drive in an empty bay moves no condition column, and the two
silences below name a logical drive and a sync that do not exist until
`create` runs. A silence made at the fit would have expired unused.

> **Not created on 2026-09-19 either, and not missed.** Logical drive 2 read
> `Condition` `2` in the first scrape it appeared in and `IloHardwareDegraded`
> never went pending — see item 4 of "What this runbook does not know". One
> observation at 60 s granularity is not a rule, so the step stays; but the
> alerts that *did* fire that day were the ones step 2 said a reboot would not
> trip, and they are the ones to silence next time. Step 2 has the list.

```bash
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u -d '+5 hours' +%Y-%m-%dT%H:%M:%SZ)
```

```bash
curl -sS -X POST http://localhost:9093/api/v2/silences -H 'Content-Type: application/json' --data "$(printf '{"matchers":[{"name":"alertname","value":"IloHardwareDegraded","isRegex":false,"isEqual":true},{"name":"device","value":"shiva","isRegex":false,"isEqual":true},{"name":"cpqDaLogDrvIndex","value":"2","isRegex":false,"isEqual":true}],"startsAt":"%s","endsAt":"%s","createdBy":"#418 fit the SSDs in Saruman","comment":"New RAID 1 logical drive on the P440ar may report degraded while the controller syncs it. Scoped to the NEW logical drive index so temperature, supplies, the controller and LD 1 stay live. Delete BEFORE the proving reading."}' "$START" "$END")" | python3 -m json.tool
```

```bash
curl -sS -X POST http://localhost:9093/api/v2/silences -H 'Content-Type: application/json' --data "$(printf '{"matchers":[{"name":"alertname","value":"IloHardwareDegraded","isRegex":false,"isEqual":true},{"name":"device","value":"shiva","isRegex":false,"isEqual":true},{"name":"cpqDaPhyDrvIndex","value":"2|3","isRegex":true,"isEqual":true}],"startsAt":"%s","endsAt":"%s","createdBy":"#418 fit the SSDs in Saruman","comment":"Two newly inserted physical drives on the P440ar. Scoped to the NEW drive indexes so drives 0 and 1 stay live. Delete BEFORE the proving reading."}' "$START" "$END")" | python3 -m json.tool
```

Record both UUIDs — they go in the roadmap and in the rules-file comment
afterwards:

```bash
curl -sS http://localhost:9093/api/v2/silences | python3 -c 'import json,sys; [print(s["id"], s["status"]["state"], s["endsAt"], [(m["name"],m["value"]) for m in s["matchers"]]) for s in json.load(sys.stdin)]'
```

**Three properties, each of which this repository already argues for somewhere.**

**Narrower than the precedent.** The battery silence on 2026-08-31 could only
manage `alertname` + `device`, and for five weeks a power-supply fault on the
same box would have been suppressed with the battery.
`IloHardwareDegraded`'s expression is an `or` of six series, so the firing
alert inherits the labels of whichever series matched — which means the
matcher can name `cpqDaLogDrvIndex` or `cpqDaPhyDrvIndex` and leave
temperature, supplies, the controller and the *existing* mirror completely
live. Use it.

**Five hours, not a month.** The battery silence was written to
2026-10-01 and deleted on 2026-09-02. A silence should expire embarrassingly
soon rather than outlive the job.

**`cpqDaLogDrvIndex` `2` is a prediction.** It is the most likely index and it
is not read yet. Step 5 verifies it within a minute of creating the drive; if
it comes back different, create the correct silence and delete this one
immediately. A silence keyed on the wrong index is a silence that does nothing
while you believe it is doing something.

**Three alerts are deliberately *not* silenced.** See the verdict table before
step 10 for why each one is better left live.

## 2. Get `ssacli` onto the hypervisor — the step most likely to stop you

> **This is the largest unknown in this runbook and it is written as one.**
> `ssacli` is not in Debian and not in the Proxmox repositories. It comes from
> HPE's MCP SDR, ~~which is not known to publish a Debian 13 `trixie` suite,~~
> and **nothing in this repository is evidence that it has ever been installed
> on this host.** Proxmox VE 9 is Debian 13. ~~None of the three paths below
> has been watched working on this box.~~ Path 3 has; see below.
>
> **2026-09-19, read from the SDR itself: HPE publishes `bookworm` and `trixie`
> suites.** `dists/trixie/current/` carries a signed `Release` dated
> 2026-09-08 and one `ssacli` stanza — `6.60-8.0`, `Depends: libc6 (>= 2.7)`
> and nothing else — so the struck clause above was wrong, and the libc
> question that path 1 used to raise was never going to bind. The key this
> step used to fetch, `hpPublicKey2048_key1.pub`, is HPE's 2015 key and
> expired 2024-11-16; the two that sign anything current are
> `hpePublicKey2048_key1.pub` and `hpePublicKey2048_key2.pub`, and a package
> published in 2026 is signed by the second. Path 1 is rewritten below and is
> the first move: it costs an `apt-get` and nothing else if it fails. What is
> still unknown is not whether the package installs but whether the binary
> finds the P440ar through `hpsa` on this host — item 1 of "What this runbook
> does not know", narrowed.

Path 1 — the `trixie` suite, which exists:

```bash
for k in key1 key2; do curl -fsSL "https://downloads.linux.hpe.com/SDR/hpePublicKey2048_$k.pub" | gpg --dearmor; done > /usr/share/keyrings/hpe-mcp.gpg
echo "deb [signed-by=/usr/share/keyrings/hpe-mcp.gpg] https://downloads.linux.hpe.com/SDR/repo/mcp trixie/current non-free" > /etc/apt/sources.list.d/hpe-mcp.list
apt-get update && apt-get install -y ssacli
ssacli version
ssacli ctrl all show status     # the real test: it must print "Smart Array P440ar in Slot 0 (Embedded)"
```

`ssacli` is a largely self-contained vendor binary; its only declared
dependency is `libc6`. Two dearmored keyrings concatenated into one file is a
valid keyring, which is why the loop writes both into it.

Path 2 — take the `.deb` directly from
`https://downloads.linux.hpe.com/SDR/repo/mcp/pool/non-free/` —
`ssacli-6.60-8.0_amd64.deb` is the one the `trixie` index names — and
`dpkg -i`, resolving whatever it complains about.

Path 3 — **no host package at all.** Reboot into Intelligent Provisioning and
use the offline Smart Storage Administrator through the iLO remote console.
This works with certainty and costs a reboot. The iLO 4 web UI's Storage page
is read-only and **cannot** create a logical drive, so it is not a fourth
option.

~~A reboot changes the alert picture a little and not much: `HostRebooted` is
`severity: info` and routes to the `null` receiver; `RemoteWriteJobStale` needs
roughly twenty minutes of absence before it fires. A reboot shorter than that
is quiet.~~ If path 3 is taken, steps 7 and 9 still need a shell, so you are
installing nothing and rebooting twice — prefer paths 1 and 2, and record
which one worked.

> **Path 3 is the one that worked, on 2026-09-19, and the struck paragraph
> above is what it cost.** Neither `ssacli` path was tried, so item 1 of "What
> this runbook does not know" is exactly as open as it was. The offline SSA
> session was not a twenty-minute reboot: the iLO power meter reads `0` W from
> about 23:00 UTC on 2026-09-18 until the host came back at 13:43 UTC on
> 2026-09-19, and in that window **four routed `warning` alerts fired** —
> `RemoteWriteJobStale` for both of `Saruman`'s remote-write jobs,
> `GuestStateStopped` and `PatchStateStopped` (both pending from 04:05 UTC,
> firing from 04:35) — plus `HostRebooted` at `info` for eight minutes after
> the boot. Every one resolved on its own at 13:44 UTC. Nothing was silenced,
> because nothing here said to. The struck paragraph described a reboot and
> this was a power-off; both are true, and the second is the one path 3 costs.
>
> **Path 3 will be needed again**, because step 3 and step 6 — the controller
> readings, and the cache reading #76 has waited on since 2026-09-02 — need
> either `ssacli` on the host or another SSA session. Try path 1 once first: it
> costs an `apt-get` and nothing else if it fails. If it is path 3 again,
> silence `RemoteWriteJobStale{instance="Saruman"}`, `GuestStateStopped{host="Saruman"}`
> and `PatchStateStopped{host="Saruman"}` for the length of the session before
> powering off, in the shape of step 1's silences, and delete them on the way
> back in.

## 3. Read the controller before touching a bay

```bash
ssacli ctrl all show status
ssacli ctrl all show config
ssacli ctrl slot=0 show detail
ssacli ctrl slot=0 pd all show detail
ssacli ctrl slot=0 ld all show detail
```

`ctrl all show` must print `Smart Array P440ar in Slot 0 (Embedded)`. If it
prints a different slot, every `slot=0` below is wrong. That is the one thing
to check rather than copy.

Capture verbatim and keep it — several of these lines are readings nothing in
this estate has ever taken:

- **Cache Ratio**, **Total Cache Size**, **Total Cache Memory Available**
- **No-Battery Write Cache**, **Drive Write Cache**
- **Battery/Capacitor Status** and **Count**
- from `ld 1 show detail`: the **Caching** line
- from `pd all show detail`: the **Interface Type** of drives 1I:1:1 and
  1I:1:2 — see item 12 at the end

## 4. Fit the drives

The SFF bays are genuinely hot-plug, and inserting drives into **empty** bays
while logical drive 1 serves the running OS is a supported operation. Two
preconditions, stated here rather than discovered at the rack:

- **HPE Gen8/Gen9 SFF SmartDrive carriers — bought 2026-09-11, arrived and
  fitted 2026-09-18.** Two `651687-001`; both came, both took a drive, and
  `cpqDaPhyDrvSmartCarrierAppFWRev` reads `11` with
  `cpqDaPhyDrvSmartCarrierBootldrFWRev` `6` on all four bays, so they are the
  firmware-carrying kind the existing drives sit in and not a Gen10 or 3.5"
  LFF part. [`../hardware.md`](../hardware.md) carries them. Kept as a
  precondition because the next fit on this chassis needs the same check: a
  bare 2.5" drive does not seat in a ProLiant bay, and one tray short is one
  SSD fitted and one on a shelf.
- **Both drives, physically.** The delivery notice covered one order for the
  pair, not two units. Settled at the bays on 2026-09-18: two drives in, two
  new `cpqDaPhyDrv` indexes out, with different serials.
- **Bays 3 and 4 are cabled.** Unknown until 2026-09-18 — the backplane
  variant is recorded nowhere — and now observed: `Port 1I Box 1 Bay 3` and
  `Bay 4` on the same connector as bays 1 and 2.

**Read both serial numbers off the drive labels before they go in.** They are
the one row in step 11's table that cannot be produced by the old hardware
reporting differently, and they are what
[`../hardware.md`](../hardware.md)'s *"Serials go here when they land"* is
waiting for. Writing them down after the drives are in a chassis means reading
them back through the tool you are trying to verify.

> **This was not done on 2026-09-18, and not on 2026-09-19 either; the window
> is closed.** The serials in `hardware.md` are the iLO's — `S3F3NX0K601487`
> in Bay 3, `S3F3NX0K806107` in Bay 4 — read over SNMP after the fact. Two
> drives with different Samsung serials in the right bays is strong evidence
> and not the proof this paragraph asked for. While both drives read
> `Unassigned` a label check was still cheap: a drive that is a member of
> nothing can be pulled, read and reseated without the controller caring.
> That stopped being true at 13:39 UTC on 2026-09-19, when step 5 made them
> logical drive 2. The serials stay as the iLO's, and the next fit on this
> chassis reads the labels first.

Insert into bays 3 and 4, then:

```bash
ssacli ctrl slot=0 pd all show
ssacli ctrl slot=0 pd 1I:1:3 show detail
ssacli ctrl slot=0 pd 1I:1:4 show detail
```

Both must appear as `1I:1:3` and `1I:1:4`, `Status: OK`, `Drive Type:
Unassigned Drive`. Confirm the model string and that **the serials match the
labels** before creating anything.

Give the iLO time before reading Prometheus. The scrape is every 60 s, but the
iLO's own agentless refresh is not, and a drive absent from Prometheus five
minutes after insertion is not necessarily a fault.

## 5. Create the logical drive

```bash
ssacli ctrl slot=0 create type=ld drives=1I:1:3,1I:1:4 raid=1
```

**Type the bay list. Never `drives=all`, never `drives=allunassigned`.** The two
HDDs are already assigned and would not be selected by either keyword — and the
cost of being wrong about that is the array holding every guest. A keyword one
letter from a different meaning is not worth the saving.

```bash
ssacli ctrl slot=0 ld all show
ssacli ctrl slot=0 ld 2 show detail
```

**Verify the new index now**, against the silence created in step 1:

```bash
# from prometheus
curl -sS -G http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=cpqDaLogDrvCondition{device="shiva"}'
```

> **Done 2026-09-19, from the offline SSA rather than this command.** The
> index is `2`, as step 1 predicted. `cpqDaLogDrvCondition{cpqDaLogDrvIndex="2"}`
> was absent in the 13:39 UTC scrape and read `2` ok at 13:40, with `Status`
> `2` and `PercentRebuild` `4294967295` from the first sample onwards —
> whatever sync a fresh RAID 1 does on this controller, the iLO never showed
> it. `FaultTol` `3` mirroring, `Size` `915683` MB, `StripeSize` `256`,
> `PhyDrvIDs` `0x0203`. Both physical drives moved `ConfigurationStatus`
> `3` → `2` in the same scrape. `cpqDaLogDrvCondition{1}` stayed `2`.

### Safe while logical drive 1 is in use, and not

| Safe | Not safe, ever, in this runbook |
| --- | --- |
| Pulling a bay blank; inserting a drive into an empty bay | Pulling bay 1 or bay 2 |
| Any `ssacli ... show` | `ssacli ctrl slot=0 delete ...`, `modify raid=`, any `erase` |
| `create type=ld` from an explicit bay list | `create` with `drives=all` or `drives=allunassigned` |
| `ld 2 modify aa=enable`, `array B modify ssdsmartpath=` | `ctrl slot=0 modify cacheratio=` — see step 6 |
| `pvcreate` / `pvesh ... lvmthin` on the new device | Controller firmware update |
| `fio` against a purpose-made LV | `fio --filename=/dev/sda` or `/dev/sdb` |
| `qm move-disk` on the running guest | Anything at all while a `move-disk` is mirroring |

## 6. The cache: read it, hand it to #76

Two cache commands are in scope here, and both are scoped to the new array.
Neither touches logical drive 1:

```bash
ssacli ctrl slot=0 ld 2 modify aa=enable
ssacli ctrl slot=0 array B modify ssdsmartpath=enable
ssacli ctrl slot=0 ld 2 show detail
```

Check the spellings against the installed version before trusting them —
`ssacli ctrl slot=0 help create` and `help modify` are the authority, and these
options have moved between versions. Read **both** the `Caching` and the
`SSD Smart Path` lines out of `ld 2 show detail` afterwards rather than
predicting how they interact.

Then take the reading that settles #76:

```bash
ssacli ctrl slot=0 show detail | grep -iE "cache ratio|cache size|cache memory|drive write cache|no-battery"
ssacli ctrl slot=0 ld 1 show detail | grep -i caching
```

**State which answer you expect before you look**, so the reading can
contradict you:

- **(a) `ssacli` reports a real ratio** — say `10% Read / 90% Write` — while
  SNMP reports `0`/`0`. Then the iLO's agentless view does not populate those
  columns on iLO 4 2.82, **#76 resolves as "this column is not readable on this
  hardware"**, no rule may ever be written on it, and `IloWriteCacheDisabled`
  reading `cpqDaAccelStatus` instead was right all along.
- **(b) `ssacli` agrees — `0% / 0%`, or `ld 1 ... Caching: Disabled`.** Then the
  array has been running write-through since the pack went in *despite
  reporting the accelerator enabled*, ADR-0029's *"That figure assumes no write
  cache, which is the honest assumption here"* was literally true rather than
  conservative, and the fix is `modify cacheratio=`.

**The four columns in step 0 lean towards (b).** Either answer resolves #76.

**The fix, if it is (b), is not taken here.** `modify cacheratio=` is
controller-wide: it flushes and re-partitions the 2 GiB module, and the pause
lands on logical drive 1 — Proxmox and `alexander`. It would also move two
variables at once underneath step 8's measurement, which is the one thing this
runbook exists to get right. Hand #76 the reading; #76 takes the change.

For when it does: the ratio that suits an SSD logical drive is also the ratio
that suits the HDD mirror, so the mixed-media controller forces no compromise.
Read-ahead buys an SSD essentially nothing — which is why HPE built SSD Smart
Path to bypass the cache entirely for reads on RAID 0/1/1+0 SSD arrays — and
posted writes buy it little, because the drive services a 4 KiB write in well
under 100 µs and the controller's cache path is not an order of magnitude
faster than that. On the HDD mirror, write cache is the single largest lever
available on this machine. Low read, high write: `10/90`.

### Drive-level cache: leave it alone

```bash
ssacli ctrl slot=0 modify dwc=enable      # do NOT run this
```

`cpqDaCntlrDriveWriteCacheState` reads `1` (other) today. The SM863a's own DRAM
buffer is capacitor-backed — that is the property the part was bought for, and
it means enabling the drives' caches would be safe *for these two drives*. But
`dwc` is **controller-wide** on this generation, so it would also enable the
caches on the two 7.2K spinners, whose buffers have no capacitor and whose only
protection is `mjolnir` — a UPS whose runtime reading has sat on the fabricated
`63` for the whole retained window
([`fit-the-ups-battery.md`](fit-the-ups-battery.md)). The SSDs lose almost
nothing; the HDDs would lose a guarantee resting on a pack whose runtime is not
yet proven.

If `ssacli ctrl slot=0 help modify` shows a per-array form on the installed
version, that changes the answer and this runbook should take it. Check; do not
assume either way.

## 7. Give Proxmox the new logical drive

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL
ls -l /dev/disk/by-id/
```

If the new device does not appear, rescan rather than reboot:

```bash
echo "- - -" > /sys/class/scsi_host/host0/scan
lsblk -o NAME,SIZE,MODEL,SERIAL
```

Then create the thin pool the way the GUI does, substituting the device that
actually appeared:

```bash
pvesh create /nodes/Saruman/disks/lvmthin --name large_data --device /dev/sdb --add_storage 1
pvesm status
```

> **Done 2026-09-19, and the name is `large_data`, not `ssd`.** One word to
> `--name` becomes the volume group, the thin pool and the PVE storage id, so
> every `ssd` this runbook used to write in steps 8 and 9 now reads
> `large_data`. **Lowercase.** This runbook, `hardware.md` and the roadmap
> wrote it as `Large_data` for a day, and step 8 was run once against that
> spelling the same evening: the `lvcreate` and every fio line naming the SSD
> pool failed on a volume group that does not exist, while the `pve` side
> ran. LVM and PVE storage ids are case-sensitive; copy the name out of
> `pvesm status`, not out of a document. The device was `sdb`: Proxmox came up at 13:43 UTC after the
> SSA session with a second `LOGICAL_VOLUME` there — no rescan needed, because
> the host booted fresh, which is why item 10 below is still not settled. The
> pool's three device-mapper volumes (`_tmeta`, `_tdata`, `-tpool`) appeared in
> `node_disk_info` between 15:46 and 15:47 UTC, and `sdb` took one burst of
> roughly 2.6 GB of writes in that five minutes — the metadata being laid out —
> and nothing since. `pvesm status` was not captured; if it was not run, run
> it before step 8.

**Why LVM-thin, as a decision rather than a default.** Plain LVM is disqualified
outright: PVE cannot snapshot it, and ADR-0027 leaves the lab with *revert and
not backup*, so snapshots are the only rollback this estate has for
`alexander`. A directory with qcow2 would give snapshots too, but stacks ext4
plus qcow2 metadata on top of a logical drive that is already an abstraction,
and adds write amplification on flash for a capability this host does not use.
LVM-thin gives snapshots, thin provisioning and discard pass-through, and is
what [`build-the-lab-guest.md`](build-the-lab-guest.md) already assumes.

> **One new blind spot, recorded rather than fixed.** A thin pool is not a
> filesystem, so `node_filesystem_*` never sees it — `Saruman` reports only
> `/`, `/boot/efi` and `/etc/pve`. `HostDiskCritical` and
> `HostDiskWillFillIn24h` are therefore **structurally blind** to the new pool,
> and a thin pool that fills makes every guest on it read-only. Either do not
> overprovision, or give the pool a textfile collector beside the existing
> `collect-guest-state.sh`. This is the same shape of gap as
> [#351](https://github.com/Gerrrt/HomeLab/issues/351) and deserves its own
> issue, not a step here: [#538](https://github.com/Gerrrt/HomeLab/issues/538),
> opened 2026-09-19 with `large_data` live and nothing on it yet, which is the
> cheapest moment to close it.

## 8. Measure what the array actually does — both of them

This is the step the purchase exists for. **ADR-0029's number is derived, not
measured**, and replacing a derived number with a differently-shaped measured
one would be worse than leaving it alone.

**What ADR-0029's figure implies.** *"A 7.2K SAS drive is roughly 83 random
IOPS at queue depth 1"* is a mechanical derivation — average seek plus half a
rotation at 7200 rpm is about 12 ms, which is about 83 operations a second. It
therefore carries **queue depth 1, one stream, no concurrency**, and no block
size at all, because seek-plus-rotate does not depend on block size at small
sizes. The comparable reconstruction is **4 KiB, `iodepth=1`, `numjobs=1`,
`direct=1`, random write**, and the comparison is only honest if those exact
parameters are used on both logical drives. A queue-depth-32 run is a
*different benchmark* — worth having as the new ceiling, not as the
re-derivation.

```bash
apt-get install -y fio
vgs                                        # expect VFree near 0 on large_data: pvesh gave the pool the whole VG
lvs -a -o +data_percent,metadata_percent   # pve/data and large_data/large_data, and their headroom
lvcreate -V 8G -T large_data/large_data -n fiotest
lvcreate -V 8G -T pve/data -n fiotest
```

> **Thin volumes, not linear ones — corrected 2026-09-19, before the step
> ran.** `pvesh create ... lvmthin` sizes the pool to the whole volume group
> less its metadata, so the `lvcreate -L 8G` linear form this step used to
> write would have failed for lack of free extents on `large_data`, and `pve`
> was never checked. A thin volume in each pool is the same overhead on both
> sides — and `pve/data` is literally the pool `vm-140-disk-0` lives in, so
> M1 measures the path the guest actually takes. The fill below is now
> load-bearing twice: it puts the SSD in steady state, and it allocates every
> chunk of both thin volumes before the 4 KiB run, so neither array is
> measured against unallocated space. Record which form was used.

Precondition both targets identically, so the SSD is measured in steady state
rather than on fresh flash:

```bash
fio --name=fill --filename=/dev/large_data/fiotest --rw=write --bs=1M --iodepth=8 --ioengine=libaio --direct=1 --size=8G
fio --name=fill --filename=/dev/pve/fiotest --rw=write --bs=1M --iodepth=8 --ioengine=libaio --direct=1 --size=8G
```

The ADR-0029 comparison, run identically on both:

```bash
fio --name=adr0029 --filename=/dev/pve/fiotest --rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --ioengine=libaio --direct=1 --size=8G --time_based --runtime=60 --ramp_time=10 --randrepeat=0 --norandommap --group_reporting
```

The new ceiling, on the SSD array only:

```bash
fio --name=ceiling --filename=/dev/large_data/fiotest --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 --ioengine=libaio --direct=1 --size=8G --time_based --runtime=60 --ramp_time=10 --group_reporting
```

Record IOPS, `clat` mean and `clat` p99 from every run.

**Three runs, and the ordering is the design:**

| | Target | State | What it is for |
| --- | --- | --- | --- |
| **M1** | HDD `pve` | guest running | what the array delivers *today, under its real load*. Deliberately a loaded number |
| **M2** | SSD `large_data` | idle, before any guest data | the number that replaces ADR-0029's |
| **M3** | HDD `pve` | idle, **after step 9's move** | the clean re-derivation of the 83. Only obtainable once the array is quiet |

M3 is why the measurement is not finished when step 8 ends. Until `alexander`
has moved off, this array is never idle, and a loaded HDD number compared
against an idle SSD number would flatter the SSDs by an unknown amount. Run the
queue-depth-32 variant against the HDD here too, and nowhere else.

**The risk, plainly.** A queue-depth-1 4 KiB random write stream consumes
essentially the whole of the machine's ~90 IOPS budget for its sixty seconds,
so M1 **will** visibly stall `alexander`. Do it deliberately and briefly. A
queue-depth-32 run against the HDD mirror with a guest live would queue 32 deep
on a 90-IOPS array and hand the guest multi-second IO latency — which is why
that variant is confined to M3.

Clean up. This is part of the step, not a footnote:

```bash
lvremove /dev/large_data/fiotest
lvremove /dev/pve/fiotest
```

## 9. Move the guest

There is exactly one guest, so this is one command rather than a campaign.

```bash
qm config 140
qm listsnapshot 140
```

**`qm listsnapshot` must come back empty.** LVM-thin's export format carries no
snapshots and an online mirror cannot carry them either, so a snapshot present
here is a refusal halfway through rather than an error up front. Delete them
first if there are any.

```bash
qm move-disk 140 scsi0 large_data
```

**It is genuinely online.** `qm move-disk` on a running VM drives a QEMU
`drive-mirror`: the guest keeps running throughout, with a brief pivot at the
end. `HypervisorGuestStopped` needs a full hour of `homelab_guest_running == 0`
and never sees anything. The honest cost is that copying the disk *off* a
90-IOPS mirror saturates it for the duration — the disk is 64 GiB as built
([`build-the-lab-guest.md`](build-the-lab-guest.md) §1; confirm with
`qm config 140`, it may have grown), and the copy is sequential, so likely ten
to twenty minutes — and the guest is slow while it runs. `--bwlimit` is there
if that matters.

**`--delete` is omitted deliberately.** The source becomes `unused0`. Verify
the guest is healthy on the new storage first, then remove it:

```bash
qm config 140
qm set 140 --delete unused0
```

Prove, then destroy — the same order as step 5's refusal to use `drives=all`.

Then tell the guest it is on flash, using the exact volid `qm config` now
reports and preserving the flags
[`build-the-lab-guest.md`](build-the-lab-guest.md) §1 already sets:

```bash
qm set 140 --scsi0 large_data:vm-140-disk-0,discard=on,iothread=1,ssd=1
```

`ssd=1` sets the emulated rotation rate so the guest's own scheduler and TRIM
behave; it takes effect at the guest's next start — so give it one:

```bash
qm reboot 140                                   # the agent is enabled (build-the-lab-guest.md §1): a clean restart
qm status 140
qm guest exec 140 -- lsblk -d -o NAME,ROTA,SIZE  # ROTA 0 on the disk is the guest seeing flash
```

**The reboot is part of the step, not a courtesy.**
[#527](https://github.com/Gerrrt/HomeLab/issues/527)'s done condition is
`alexander` *booting* from the pool, and `ssd=1` is a start-time flag. No
silence for it: `HypervisorGuestStopped` needs an hour of `== 0`,
`GuestStateStopped` reads the collector's timer and not the guest, and the
lab stack's own `InstanceDown` fires inside `alexander` and routes nowhere
outside the lab, which is what ADR-0007 means by lab telemetry staying in the
lab.

**Backups.** `vzdump` jobs are per-VM, not per-storage, so nothing here changes
them — confirm with `cat /etc/pve/jobs.cfg`. Existing backups stay restorable,
but a restore defaults back to the storage recorded in the archive, so pass
`--storage large_data` explicitly when the time comes.

**Now run M3** from step 8: the HDD mirror is finally idle, and that is the
reading ADR-0029's `83` gets compared against.

## 10. Delete the silences — immediately, not on expiry

Both rack runbooks in this repository record getting this order inverted —
23:14 against a 22:45 self-test, 23:11 against a 23:02 proving reading — and
both cost nothing only by luck. **Delete first, then read.** A silence standing
over freshly fitted hardware suppresses exactly the thing you most want to hear
about.

```bash
curl -sS -X DELETE http://localhost:9093/api/v2/silence/<id>
```

```bash
curl -sS http://localhost:9093/api/v2/silences | python3 -c 'import json,sys; [print(s["id"], s["status"]["state"], s["endsAt"]) for s in json.load(sys.stdin)]'
```

Both must read `expired` with an `endsAt` at the moment you deleted them rather
than the five-hour mark — that is the difference between deleted and lapsed,
and it is what the roadmap entry should record.

### Which alerts were silenced, and which were deliberately left live

| Alert | What it does during this job | Silenced? |
| --- | --- | --- |
| `IloHardwareDegraded` (critical, 5m) | **May fire.** Reads `cpqDaLogDrvCondition > 2`. RAID 1 has no parity to initialise, but `cpqDaLogDrvStatus` carries `recovering(5)`, `rebuilding(7)` and `rapidParityInit*(18/19)` and the condition column tracks them. Critical, and it pages. **Did not fire on 2026-09-19**: LD 2 read `2` from its first scrape and never went pending | **Yes** — two, both scoped to the new indexes. Neither was created on the day, and neither was needed |
| `RemoteWriteJobStale` ×2, `GuestStateStopped`, `PatchStateStopped` (warning) and `HostRebooted` (info) | **Not in this table until 2026-09-19, when all five fired.** Path 3 of step 2 powered the host off for fourteen and a half hours, not the twenty-minute reboot the step described; the four warnings were routed and the `info` was not. All resolved at the boot | **No**, and they should have been — step 2 now says which to silence if path 3 is taken again |
| `IloDrivePredictiveFailure` (warning, 15m) | Should not fire. `cpqDaPhyDrvSmartStatus` `4` is `replaceDriveSSDWearOut` — on *used* enterprise SSDs that is a **true finding**, not noise | **No.** Silencing it would suppress precisely what you have just introduced. If it fires, read `cpqDaPhyDrvSSDPercntEndrnceUsed` and `cpqDaPhyDrvSSDWearStatus` at that index |
| `IloDriveSmartUnreadable` (info, 1h) | May fire — whether a new non-HPE SATA SSD reports `SmartStatus` `1` before the controller configures it is unknown. `severity: info` routes to the `null` receiver, so it pages nobody | **No.** Let it fire; the fit is the experiment that settles it. Still firing an hour after the drive reads `ok` is a finding about SMART visibility, not an alerting problem |
| `IloWriteCacheDisabled` (warning, 1h) | Will not fire. Reads `cpqDaAccelStatus > 3`; it reads `3`, and with the ratio change deferred to #76 there is no flush to blip it to `tmpDisabled(4)` | **No** — it is the most informative rule for this job |
| `HypervisorGuestStopped` (warning, 1h) | Will not fire — the move is online and needs a full hour of `== 0` | **No** |
| `GuestStateStopped` (warning, 30m) | Will not fire — nothing here touches `homelab-guest-state.timer` | **No** |
| `SnmpScrapeSlow` | Will not fire. The walk gains two drives and one logical drive: expect roughly 13–17 s against a 30 s threshold | **No**, but put before and after in the table |
| `SmartDrive*` (`host.rules.yaml`) | Will not fire — `collect-smart-state.sh` excludes `Saruman` by design, because the iLO already walks its array | **No** |
| `HostDiskCritical` / `HostDiskWillFillIn24h` | Cannot fire for the new pool — see step 7's blind spot | **No** |

## 11. Confirm the metrics actually moved — on `prometheus`

Re-run step 0's queries and fill the Observed column. Every row must reach its
right-hand value.

| Metric | Before, 2026-09-17 | After a successful fit | Observed |
| --- | --- | --- | --- |
| `cpqDaPhyDrv*` index set | `0`, `1` | `0`, `1`, `2`, `3` | `0`–`3` from 20:11 UTC 2026-09-18, both in one scrape |
| `cpqDaPhyDrvLocationString{2,3}` | absent | `Port 1I Box 1 Bay 3` / `Bay 4` | as predicted |
| `cpqDaPhyDrvSerialNum{2,3}` | absent | **the two label serials — the row that cannot be faked** | `S3F3NX0K601487` / `S3F3NX0K806107` — **from the iLO, not the labels**; see step 4 |
| `cpqDaPhyDrvModel{2,3}` | absent | ~~an `MZ7KM960...` string~~ `SAMSUNG` | `SAMSUNG`, vendor only. The iLO reports a third-party SATA drive by vendor where it gives the HPE drives their part number; the part is proved by size, `cpqDaPhyDrvFWRev` `GXM5304Q` and the serial prefix instead |
| `cpqDaPhyDrvMediaType{2,3}` | absent (`{0,1}` = `2`) | `3` solidState | `3` |
| `cpqDaPhyDrvRotationalSpeed{2,3}` | absent (`{0,1}` = `2`) | `5` rpmSsd | `5` |
| `cpqDaPhyDrvType{2,3}` | absent | `3` sata | `3` — the same value the HDDs read, so item 12 is no nearer settled |
| `cpqDaPhyDrvNegotiatedLinkRate{2,3}` | absent (`{0,1}` = `4`) | `4`. A `3` means the drive negotiated down to 3 Gb/s | `4` |
| `cpqDaPhyDrvConfigurationStatus{2,3}` | absent | `3` notConfigured after step 4 → `2` configured after step 5 | `3` from 2026-09-18 20:11 UTC; `2` from 2026-09-19 13:40 UTC, both drives in the same scrape as LD 2 appeared |
| `cpqDaPhyDrvCondition{2,3}` / `Status{2,3}` | absent | `2` ok / `2` ok | `2` / `2` from the first scrape |
| `cpqDaPhyDrvSmartStatus{2,3}` | absent | `2` ok. `1` trips `IloDriveSmartUnreadable` after 1 h, unrouted. **`4` is SSD wear-out and is a true finding** | `2` from the first scrape — no `other(1)` phase while unconfigured, `IloDriveSmartUnreadable` never fired |
| `cpqDaPhyDrvSSDWearStatus{2,3}` | absent (`{0,1}` = `1` other) | `2` ok, or `1` if the controller will not read a third-party SSD | `1` other, unconfigured. **Re-read after step 5, 2026-09-19: still `1` other, configured**, `cpqDaPhyDrvHasMonInfo` still false on all four. Wear is blind on these drives through the iLO; [#529](https://github.com/Gerrrt/HomeLab/issues/529) was filed against exactly this condition and is no longer gated |
| `cpqDaPhyDrvSSDPercntEndrnceUsed{2,3}` | absent (`{0,1}` = `4294967295`) | a percentage, or `4294967295` — unknown is this box's norm | `4294967295`, and `PowerOnHours` and `SSDEstTimeRemainingHours` the same. **Re-read 2026-09-19, configured: unchanged, all three** |
| `cpqDaLogDrv*` index set | `1` | `1`, `2` | `1`, `2` from 13:40 UTC 2026-09-19; absent at 13:39 |
| `cpqDaLogDrvCondition{2}` / `Status{2}` | absent | `2` ok / `2` ok (`5`, `7`, `18`, `19` while syncing) | `2` / `2` from the first scrape; `PercentRebuild` `4294967295` throughout. No syncing state was ever shown |
| `cpqDaLogDrvFaultTol{2}` | absent | `3` mirroring | `3` |
| `cpqDaLogDrvSize{2}` | absent | roughly `915700` MB | `915683` MB; `PhyDrvIDs` `0x0203`, `StripeSize` `256` |
| `cpqDaLogDrvHasAccel{2}` | absent (`{1}` = `1` other) | `3` enabled — **or `1` other, if the existing drive's reading is the iLO's habit rather than a fault.** Which one it is, is itself the #76 answer arriving from a second direction | `1` other — the same as LD 1, before step 6's `aa=enable` has run. Not yet a #76 answer from either direction |
| `cpqDaLogDrvSSDSmartPathStatus{2}` | absent | `4` ssdSmartPathEnabled | `1` other — step 6's `ssdsmartpath=enable` has not run |
| `cpqDaLogDrvCondition{1}` | `2` ok | `2` ok — **must not move** | `2` |
| `cpqDaAccelStatus` | `3` enabled | `3` enabled — **must not move**; no `modify cacheratio=` means no flush | `3` |
| `cpqDaAccelBadData` | `2` none | `2` none. `3` means dirty cache was lost and is a different conversation | `2` — through a 14.5 h power-off as well |
| `cpqDaAccelWriteCachePercent` | `0` | **`0`, expected unchanged** — the ratio is not set here. If `ld 2 modify aa=enable` alone moves it, that is itself a finding for #76 | `0` |
| `cpqDaAccelMemory` / `ReadMemory` | `0` / `0` | `0` / `0`, same reasoning | `0` / `0` |
| `cpqDaAccelTotalMemory` | `2097152` | unchanged | `2097152` |
| `cpqDaAccelFailedBatteries` | `1` | unchanged — a #76 curiosity, not a target | `1` |
| `cpqDaCntlrCondition` / `BoardCondition` | `2` / `2` | `2` / `2` | `2` / `2` |
| `cpqDaCntlrDriveWriteCacheState` | `1` other | `1` other — **unchanged is the pass condition** | `1` |
| `ssacli ctrl slot=0 show detail` → Cache Ratio | never read | a real ratio, or `0/0` — **this is the #76 reading, and either answer resolves it** | still never read — no `ssacli`; path 3 |
| `ssacli ctrl slot=0 ld 1 show detail` → Caching | never read | `Enabled`, or the (b) branch of step 6 | still never read |
| `scrape_duration_seconds{device="shiva"}` | `11.8` s | ~~roughly 13–17 s~~ unchanged, and well under 30 | `11.4` s averaged over two hours either side of the fit. Two more drives cost the walk nothing measurable; the estimate was wrong. `12.0` s with the second logical drive in the walk |
| `rate(node_disk_writes_completed_total{device="sda"}[1h])` | current | falls to the host's own writes | unchanged — `alexander` is still here |
| the same for `sdb` | absent | present, carrying `alexander`'s writes | present since 13:43 UTC 2026-09-19 as the second `LOGICAL_VOLUME`, carrying nothing: one 2.6 GB burst when the pool was made, zero since |
| **fio 4k QD1 randwrite, HDD** | ADR-0029's **derived** `83` | **measured** — M1 loaded, M3 idle | |
| **fio 4k QD1 randwrite, SSD** | n/a | **measured** — M2. The number that replaces ADR-0029's | |
| **fio 4k QD32 randwrite** | n/a | measured on both — the new ceiling, a different benchmark | |

The runbook is done when every row has moved, `cpqDaAccelBadData` still reads
`2`, `cpqDaLogDrvCondition{1}` still reads `2`, and the walk is still
comfortably under 30 s.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ssacli` will not install | ~~No trixie suite from HPE's MCP SDR~~ The suite exists since 2026-09-08, so it is the keyring or the network | Path 2 in step 2, then path 3 — with the three silences step 2 names. Record which one worked |
| `ssacli` installs, `ctrl all show` finds no controller | The binary cannot reach the P440ar through `hpsa` on this kernel — item 1 of "What this runbook does not know", the part that is still open | Path 3, with the silences. Record the exact error |
| `lvcreate -L` refuses for lack of free extents | The volume group is all thin pool: `pvesh ... lvmthin` gives it everything but the metadata | The `-V ... -T` form in step 8 |
| `ctrl all show` prints a slot other than 0 | This chassis is not wired as assumed | Stop. Every `slot=0` in this runbook is wrong; re-derive them all |
| Drives do not seat in the bays | No HPE SmartDrive carriers | Stop at step 4. This is a purchase, and a purchase edits the roadmap's buy table |
| Drives seat but never appear to `ssacli` | Bays 3–4 not cabled on this backplane | Try bays that are known-good; if none, this layout is not available on this chassis |
| New drives appear, `create` refuses | Drives not `Unassigned`, or a leftover configuration on a used drive | `pd 1I:1:3 show detail`. Do **not** reach for `erase` without re-reading step 5's table |
| `IloHardwareDegraded` pages anyway | The silence named the wrong `cpqDaLogDrvIndex` | Read the real index, silence that, delete the wrong one. Then check whether the alert is *true* |
| `cpqDaAccelStatus` moves to `4` tmpDisabled | The controller parked the cache | Wait — the rule's 1 h `for:` exists for this. If it persists, it is real and #76 wants to know |
| `qm move-disk` refuses | Snapshots on vmid 140 | `qm listsnapshot 140`, delete them, retry |
| Move completes, guest will not boot | Storage moved, guest config did not | `qm config 140` — `scsi0` must name the `large_data` storage. `unused0` is still the intact original |
| The new pool fills | Thin overprovisioning, and nothing alerts on it | Step 7's blind spot, arriving. `pvesm status`, `lvs` |
| fio numbers are wildly high | Caching somewhere in the path | `--direct=1` on every run, and a raw LV target — never a file, never `/dev/sda` |

## Flipping the documents

The fit does not finish when the drives are in. These are the documents it makes
stale, in the order they should be touched:

- **[`../hardware.md`](../hardware.md)** — the Compute table's Storage column
  for `Saruman`, which reads `2× 1 TB SAS HDD, RAID 1` and is the reason the
  accessories entry says *"The Compute table's Storage column changes when #418
  fits them, and not before."* Model, capacity and **both serials** go into the
  accessories entry, which answers
  [#148](https://github.com/Gerrrt/HomeLab/issues/148)'s question about where
  serials live.
- **ADR-0029** — *"By spindle"* and *"The duty cycle is a spindle decision"*
  both rest on ~90 write IOPS. Once step 8 has measured otherwise, the endpoints
  running per session are a **choice** rather than a constraint. A dated
  `[!NOTE]` on the ADR, status left `Accepted`, in the shape of the one already
  at the top of ADR-0029 and the three on ADR-0007. **Never a silent edit** —
  [ADR-0001](../adr/0001-record-architecture-decisions.md) makes ADRs immutable.
- **ADR-0007**'s constraint sentence, quoted in #266 and #414, and **ADR-0017**,
  which quotes it verbatim to justify NVMe for the range. ADR-0017's argument
  was a separate fault domain and not only IOPS, so it survives — but the
  sentence it leans on has moved and the note should say so.
- **[`../roadmap.md`](../roadmap.md)** — the #414 paragraph that repeats the
  ninety-IOPS reasoning, the #418 entry, and #76 with whichever branch of step 6
  turned out to be true.
- **`stacks/observability/prometheus/rules/network.rules.yaml`** — the iLO
  section-header comment records silences by UUID and expiry. Both silences from
  step 1 get a paragraph there, in the shape of the 2026-08-31 one already
  present.
- **`stacks/observability/prometheus/tests/network.test.yaml`** — the
  `IloDrivePredictiveFailure` and `IloDriveSmartUnreadable` fixtures are
  single-drive, `cpqDaPhyDrvIndex="0"`. The rule expressions are index-agnostic
  so nothing is broken, but the tests stop describing the machine the day this
  runbook succeeds.
- **[`build-the-lab-guest.md`](build-the-lab-guest.md)** and
  **[`build-the-lab-domain.md`](build-the-lab-domain.md)** — both tell the
  reader to leave the Proxmox disk cache at the default *because #76 is open and
  nobody has confirmed the controller absorbs writes*. Whichever branch step 6
  lands on changes that argument.
- **`README.md`** — the runbook count, if this file was the one that moved it.

## What this runbook does not know

Written down rather than asserted, in the shape of
[`replace-the-smart-storage-battery.md`](replace-the-smart-storage-battery.md)'s
*"What is still open"*. Every item here is something the fit can settle, and
settling it is most of the value of doing the fit carefully.

1. **Whether `ssacli` can be installed on Proxmox VE 9 at all.** Debian 13
   trixie; HPE's MCP SDR is not known to publish a trixie suite; nothing in this
   repository is evidence it has ever run here. Three paths in step 2. *Still
   open after 2026-09-19:* path 3 was used and neither `ssacli` path was
   attempted, so this is exactly as unknown as it was, and steps 3 and 6 are
   waiting on it. *Narrowed the same evening:* the SDR does publish a
   `trixie` suite, and the package in it depends on `libc6` alone, so
   "installable" is no longer the question — "runs against the P440ar
   through `hpsa`" is.
2. ~~**When the drive trays arrive, and whether both do.**~~ **Settled
   2026-09-18.** Both `651687-001` arrived, both took a drive, and the iLO reads
   the same carrier firmware (`11` / `6`) on all four bays.
3. ~~**Whether bays 3 and 4 are cabled.**~~ **Settled 2026-09-18.** They are:
   `Port 1I Box 1 Bay 3` and `Bay 4`, same connector as the mirror.
4. ~~**Whether a newly created RAID 1 transits `cpqDaLogDrvCondition = 3`.**
   This is the whole reason step 1 creates a silence rather than skipping one,
   and the fit should record the answer so the next one need not guess.~~
   **Settled 2026-09-19, as far as one 60 s scrape can settle it: it did
   not.** LD 2 read `Condition` `2`, `Status` `2` and `PercentRebuild`
   `4294967295` in the first scrape it appeared in and every one after.
   Either a fresh RAID 1 on a P440ar has no sync the iLO reports, or it
   finished inside the minute before the walk reached it. `IloHardwareDegraded`
   never went pending and no silence was standing.
5. ~~**Whether a brand-new non-HPE SATA SSD reports `cpqDaPhyDrvSmartStatus = 1`**
   before the controller configures it.~~ **Settled 2026-09-18: it does not.**
   Both read `2` ok from the first scrape they appeared in, unconfigured, and
   `IloDriveSmartUnreadable` never went pending. The test fixture's `other(1)`
   case describes a state this drive did not pass through.
6. **Whether `cpqDaAccelWriteCachePercent = 0` is a reporting gap or a real
   0 % allocation.** Four columns lean towards real. Only step 6's `ssacli`
   reading decides, and it has never been run on this machine.
7. **Whether SSD Smart Path and the array accelerator conflict** on a P440ar —
   specifically whether enabling Smart Path disables caching for that logical
   drive. Read both lines out of `ld 2 show detail`; do not predict.
8. **Whether `dwc` has a per-array form** on the installed `ssacli`. The
   recommendation to leave drive write cache alone depends on it being
   controller-wide.
9. **Whether `qm move-disk` refuses with snapshots present**, and whether
   `alexander` has any. Check; do not learn it from the error message.
10. **Whether `hpsa` surfaces the new logical drive without a SCSI rescan.**
    *Not settled on 2026-09-19:* the host booted fresh after the offline SSA
    session and `sdb` was there at boot, which says nothing about a live
    rescan. Path 1 or 2 next time would answer it.
11. **Whether discard reaches the SSDs** through LVM-thin → hpsa → P440ar, or
    stops at the thin pool. It affects long-term steady-state write performance
    and nothing in the first day's readings will show it.
12. **Whether the existing drives are SAS or SATA.** `cpqDaPhyDrvType` reads
    `3` (sata) for both, on a metric whose enumeration carries a distinct
    `4: sas`, and the model string is `MM1000GBKAL` — while
    [`../hardware.md`](../hardware.md) and ADR-0007 both say **SAS**. Step 3's
    `pd all show detail` prints the interface type authoritatively, and settling
    it is a free by-product of a visit that is happening anyway. **Do not
    correct either document from an SNMP enum alone**, and note that ADR-0007
    is immutable — if it is wrong, it gets a dated note like everything else.
13. ~~**That the new logical drive's index will be `2`.** Predicted, load-bearing
    for step 1's silence, and verifiable within a minute of creating it.~~
    **Settled 2026-09-19: it is `2`.** The silence it was load-bearing for was
    never created.
14. ~~**How long the iLO takes to reflect a configuration change.** The 60 s
    scrape is not the bound; the iLO's own agentless refresh may be minutes.~~
    **Settled 2026-09-19.** A physical insertion showed up within one scrape
    interval on 2026-09-18 — both drives in the 20:11 UTC scrape, absent at
    20:10 — and a `create` did the same on 2026-09-19: LD 2 absent at 13:39
    UTC, present at 13:40, with both drives reading `configured` in the same
    walk, and all of it while the host was still in the SSA session, four
    minutes before Proxmox booted. The iLO reports the controller, not the OS.
15. **The exact option spellings** on the installed `ssacli` — `aa=`,
    `ssdsmartpath=`, `dwc=` have all moved between versions.
    `ssacli ctrl slot=0 help create` and `help modify` are the authority.

Two things the fit showed that nothing here had asked about:

- **The iLO names a third-party SATA drive by vendor only.** `cpqDaPhyDrvModel`
  reads `SAMSUNG` where the HPE drives read their part number `MM1000GBKAL`.
  Anything that wanted to match the model string — a rule, a dashboard label,
  a future `hardware.md` check — has firmware (`GXM5304Q`), size and serial to
  work with instead.
- **`cpqDaPhyDrvMaximumTemperature` is a lifetime figure, and it is above the
  threshold on one drive.** Bay 3 reads a maximum of `62` °C against a
  `cpqDaPhyDrvTemperatureThreshold` of `60`; Bay 4 reads `51`. Both are at
  `30`–`32` °C now. These are second-hand enterprise drives and the number is
  their previous life's, not this chassis's — but it is exactly the kind of
  reading only direct SMART would have shown at purchase, which is the closing
  paragraph's argument made for it.

One thing that belongs beyond this runbook rather than in it:
`collect-smart-state.sh` skips `Saruman` because the iLO covers its array — but
the iLO already reports `4294967295` for the HDDs' endurance columns and
`cpqDaPhyDrvSSDWearStatus` `1` (other), and on 2026-09-18 it did the same for
the two SSDs while they were unconfigured. That would leave wear monitoring
blind on the newest and most wear-sensitive parts in the estate, on drives
bought second-hand. `smartctl -d cciss,N /dev/sda` reads the drives directly
through the `hpsa` path and would close it. The reading was re-taken after step
5, on 2026-09-19 with both drives configured, and it is still blank — so it is
an issue, not a step here: [#529](https://github.com/Gerrrt/HomeLab/issues/529),
filed against that condition before it was known to hold, and gated on nothing
now.
