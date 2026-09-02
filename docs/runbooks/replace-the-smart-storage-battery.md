# Runbook: Replace the Smart Storage Battery in `shiva`

**One part, one power-down, and a comparison that has to be recorded before the
lid comes off — not after.**

> **Status — 2026-09-02: the pack is in and proven. Two readings did not move.**
>
> Fitted 2026-09-02. `Saruman` was off from 22:30 to 22:58 UTC, and the first
> scrape after it came back, at 23:02 UTC, read chassis 0 battery 1 as
> `cpqHeSysBatteryCondition` `2` (ok), `cpqHeSysBatteryStatus` `1` (noError),
> serial **`6EZBN0FB2431YM`** — the old pack was `6EZBN0CB29N3YZ`, so a
> different part is being read, not the old one reporting differently. The
> Smart Array re-enabled the cache on the same scrape: `cpqDaAccelStatus` `3`
> (enabled), `cpqDaAccelBackupPowerSource` `1` → `4` (smartbattery),
> `cpqDaAccelBattery` `2` (ok), and all three controller rollups back to `2`.
> The full comparison is in step 3.
>
> **The silence was deleted at 23:11 UTC** rather than left to run to
> 2026-10-01, and both alerts are live again. Nine minutes after the proving
> reading, not before it — see step 4 for why that cost nothing this time.
>
> **What did not move.** `cpqDaAccelWriteCachePercent` and
> `cpqDaAccelReadCachePercent` still read `0` / `0` where this runbook
> expected non-zero, and `cpqDaAccelFailedBatteries` still reads `1`, as it has
> for the whole retained window. Both were read again at 23:12 UTC, ten minutes
> after the pack was first seen. Neither is alerted on, and the status code
> says the controller believes it is caching. See "What is still open" at the
> end.

`shiva` is the iLO, not the hypervisor. The host behind it is `Saruman` at
`10.0.30.110`; see [`../hardware.md`](../hardware.md). The pack is internal to
the ProLiant DL360 Gen9 and is not hot-swappable, so fitting it means taking
`Saruman` down.

## Why this is not urgent, and why it is not nothing

On a Gen9 the Smart Storage Battery is the chassis pack that backs the Smart
Array's flash-backed write cache. With it dead the controller had permanently
disabled the accelerator — `cpqDaAccelStatus` `5` (`permDisabled`),
`cpqDaAccelErrCode` `25` (`noCapacitorAttached`), read and write cache percent
both `0` — and the array ran write-through from 2026-08-18, the start of the
retained window, until the pack was replaced on 2026-09-02.

Write-through is **slower, not riskier.** There is no volatile dirty cache to
lose, which is precisely why the controller chose it. `cpqDaAccelBadData` read
`2` (`none`) throughout, confirming nothing was lost when it dropped. What it
cost was write latency and IOPS on every VM on that array.

The thing to actually worry about is `cpqDaAccelBadData` reading `3`
(`possible`). That would mean dirty cache *was* lost, and it is a different
conversation from this runbook.

## 1. Record the baseline — before touching anything

This is the step that makes the fix provable rather than assumed. The UPS pack
was only ever proven because its before-values were written down first.

```bash
curl -sS -G http://127.0.0.1:9090/api/v1/query --data-urlencode 'query={__name__=~"cpqHeSysBattery(Condition|Status|Present)|cpqDaAccel(Status|ErrCode|Battery|BadData|WriteCachePercent|ReadCachePercent)|cpqDa(Cntlr|CntlrBoard)Condition",device="shiva"}' | python3 -m json.tool
```

Recorded before the visit, and what was read after it. The **Observed** column
is the 23:02 UTC scrape on 2026-09-02, the first after `Saruman` came back,
and every value was unchanged at 23:12 UTC:

| Metric | Before, failed pack | After a good pack | Observed 2026-09-02 |
| --- | --- | --- | --- |
| `cpqHeSysBatteryCondition` | `4` failed | `2` ok | **`2`** |
| `cpqHeSysBatteryStatus` | `13` shutdownPermanentFailure | `1` noError | **`1`** |
| `cpqHeSysBatteryPresent` | `3` present | `3` present | `3` |
| `cpqHeSysBatterySerialNumber` | `6EZBN0CB29N3YZ` | different | **`6EZBN0FB2431YM`** |
| `cpqDaAccelStatus` | `5` permDisabled | `3` enabled | **`3`** |
| `cpqDaAccelErrCode` | `25` noCapacitorAttached | `1` other or `2` invalid | **`2`** |
| `cpqDaAccelBattery` | `6` notPresent | `2` ok | **`2`** |
| `cpqDaAccelBackupPowerSource` | `1` other | `4` smartbattery | **`4`** |
| `cpqDaAccelWriteCachePercent` | `0` | non-zero | `0` — **did not move** |
| `cpqDaAccelBadData` | `2` none | `2` none | `2` |
| `cpqDaCntlrCondition` | `3` degraded | `2` ok | **`2`** |

Two rows were added after the fact. The serial number is the strongest proof
in the table — every other row could in principle be the old pack reporting
differently, and this one cannot. `cpqDaAccelBackupPowerSource` is the
controller saying what it is backed by, which is the claim the whole exercise
is about. The `cpqDaAccelErrCode` row originally expected `1`; `1` (other) and
`2` (invalid) are both what a controller with nothing wrong reports, which is
why `IloWriteCacheDisabled` reads `cpqDaAccelStatus` rather than this column.

## 2. Order and fit

Spare `815983-001`. Power `Saruman` down — the pack is internal and not
hot-swappable. The battery sits on the Smart Array's cache module; seat it fully
and check the cable at the controller end.

Give it time on charge before judging it. A freshly fitted pack legitimately
reports `cpqDaAccelStatus` `4` (`tmpDisabled`) while it charges, which is why
`IloWriteCacheDisabled` waits an hour before firing.

## 3. Confirm the metrics actually moved

> **Done 2026-09-02.** Every row in the table moved to its right-hand column
> except the cache ratio, which is recorded as open below rather than claimed.

Re-run the step 1 query and compare against the table. Every row must move to
the right-hand column.

**A badly seated new pack reports exactly the same `25` /
`noCapacitorAttached` as an empty bay.** This is the same trap as the UPS
management card fabricating a healthy battery: "the alert stopped" and "the part
is working" are not the same claim, and only the comparison above tells them
apart. If `cpqDaAccelErrCode` still reads `25` after the pack has had time to
charge, the pack is not seated — do not delete the silence.

## 4. Delete the silence — immediately, not on expiry

> **Done 2026-09-02**, at 23:11 UTC. `bfdfff66-d9c3-4df4-9495-f1f38ebf93c1`
> reads `expired` with `endsAt` 2026-09-02T23:11:53Z instead of its original
> 2026-10-01, so it was deleted rather than left to lapse. Nothing was firing
> for `shiva` in Prometheus or Alertmanager at that moment.
>
> **The order was inverted again.** The proving reading was at 23:02 UTC; the
> silence went at 23:11. It cost nothing here for a reason the UPS case did not
> have: both rules carry a `for:` (30m and 1h), so no notification about a
> faulty new pack could have existed inside those nine minutes, suppressed or
> otherwise. That is luck of the rule shape, not the procedure working — delete
> first next time too.

The procedure is **step 3 of
[`fit-the-ups-battery.md`](fit-the-ups-battery.md)**, which is written to be
reused and is not duplicated here. Two things carry over unchanged:

- Delete the silence **before** you take the reading that proves the fix, not
  after. That runbook records the one time it was done the other way round: for
  29 minutes a faulty pack would have reported into a suppressed alert.
- Delete it rather than letting it expire. A silence left standing over a
  freshly fitted part suppresses exactly the thing you most want to hear about.

The silence to remove is `bfdfff66-d9c3-4df4-9495-f1f38ebf93c1`, matching
`alertname=~"IloBatteryCondition|IloWriteCacheDisabled"` and `device="shiva"`.

Then update [`../roadmap.md`](../roadmap.md) and the section header comment in
`stacks/observability/prometheus/rules/network.rules.yaml`, both of which record
the silence by UUID and expiry.

## What is still open

Two values did not move when everything else did, and neither has an alert
watching it, so this section is the only place they are recorded.

- **`cpqDaAccelWriteCachePercent` / `cpqDaAccelReadCachePercent` read `0` /
  `0`.** The controller says the cache is enabled and backed by the new pack,
  and reports no ratio. A P440ar with a 2 GB module normally reports something
  like `10` / `90` here. Either the iLO's agentless view refreshes this column
  more slowly than the status codes, the controller kept the ratio unset after
  weeks with the cache permanently disabled, or the pack is still on its first
  charge. Ten minutes of history cannot tell those apart. If it is still `0` /
  `0` after the pack has had an hour, the next step is on `Saruman` itself and
  not through SNMP, because VLAN 30 is not reachable from the monitoring host:

  ```bash
  ssacli ctrl all show config detail
  ```

  Look at *Cache Ratio*, *Cache Status* and *Battery/Capacitor Status*. A
  ratio that reads "not configured" is set with `ssacli ctrl slot=0 modify
  cacheratio=10/90`; that is a change to the array and is not made from this
  runbook.
- **`cpqDaAccelFailedBatteries` reads `1`**, unchanged from the failed pack. It
  is an octet-string bitmap of failed batteries, and it did not clear when
  `cpqDaAccelBattery` went to `2` (ok). Whether the controller latches it until
  a reset, or the iLO caches it, is not known. It is not alerted on, and it is
  listed here so the next reader does not have to rediscover it.

Both are re-read with the step 1 query. The runbook is done when the first
reads non-zero; the second is a curiosity until it disagrees with something.
