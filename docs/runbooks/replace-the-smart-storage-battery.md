# Runbook: Replace the Smart Storage Battery in `shiva`

**One part, one power-down, and a comparison that has to be recorded before the
lid comes off — not after.**

> **Status — 2026-08-31: the fault is confirmed and the part is on order.**
>
> Chassis 0, battery 1: `cpqHeSysBatteryStatus` `13`
> (`shutdownPermanentFailure`), `cpqHeSysBatteryCondition` `4` (failed),
> `cpqHeSysBatteryPresent` `3` (present). **HPE spare `815983-001`**, option
> `727258-B21`, "HP Smart Storage Batt 96", serial `6EZBN0CB29N3YZ`.
>
> `13` is terminal. It is not a flat pack that will come back on charge and it
> is not a seating fault — the pack has permanently shut itself down, and
> reseating it does not clear the code. There is nothing to try before ordering.
>
> `IloBatteryCondition` and `IloWriteCacheDisabled` are silenced for `shiva`
> until 2026-10-01 (`3ffc313f-7154-459c-9f62-7c9a432bc97e`). **Delete that
> silence when the pack goes in, not when it expires** — see step 4.

`shiva` is the iLO, not the hypervisor. The host behind it is `Saruman` at
`10.0.30.110`; see [`../hardware.md`](../hardware.md). The pack is internal to
the ProLiant DL360 Gen9 and is not hot-swappable, so fitting it means taking
`Saruman` down.

## Why this is not urgent, and why it is not nothing

On a Gen9 the Smart Storage Battery is the chassis pack that backs the Smart
Array's flash-backed write cache. With it dead the controller has permanently
disabled the accelerator — `cpqDaAccelStatus` `5` (`permDisabled`),
`cpqDaAccelErrCode` `25` (`noCapacitorAttached`), read and write cache percent
both `0` — and the array is running write-through.

Write-through is **slower, not riskier.** There is no volatile dirty cache to
lose, which is precisely why the controller chose it. `cpqDaAccelBadData` reads
`2` (`none`), confirming nothing was lost when it dropped. What this costs is
write latency and IOPS on every VM on that array.

The thing to actually worry about is `cpqDaAccelBadData` reading `3`
(`possible`). That would mean dirty cache *was* lost, and it is a different
conversation from this runbook.

## 1. Record the baseline — before touching anything

This is the step that makes the fix provable rather than assumed. The UPS pack
was only ever proven because its before-values were written down first.

```bash
curl -sS -G http://127.0.0.1:9090/api/v1/query --data-urlencode 'query={__name__=~"cpqHeSysBattery(Condition|Status|Present)|cpqDaAccel(Status|ErrCode|Battery|BadData|WriteCachePercent|ReadCachePercent)|cpqDa(Cntlr|CntlrBoard)Condition",device="shiva"}' | python3 -m json.tool
```

Expected now — copy this into the issue before the visit:

| Metric | Now | After a good pack |
| --- | --- | --- |
| `cpqHeSysBatteryCondition` | `4` failed | `2` ok |
| `cpqHeSysBatteryStatus` | `13` shutdownPermanentFailure | `1` noError |
| `cpqHeSysBatteryPresent` | `3` present | `3` present |
| `cpqDaAccelStatus` | `5` permDisabled | `3` enabled |
| `cpqDaAccelErrCode` | `25` noCapacitorAttached | `1` other |
| `cpqDaAccelBattery` | `6` notPresent | `2` ok |
| `cpqDaAccelWriteCachePercent` | `0` | non-zero |
| `cpqDaAccelBadData` | `2` none | `2` none |
| `cpqDaCntlrCondition` | `3` degraded | `2` ok |

## 2. Order and fit

Spare `815983-001`. Power `Saruman` down — the pack is internal and not
hot-swappable. The battery sits on the Smart Array's cache module; seat it fully
and check the cable at the controller end.

Give it time on charge before judging it. A freshly fitted pack legitimately
reports `cpqDaAccelStatus` `4` (`tmpDisabled`) while it charges, which is why
`IloWriteCacheDisabled` waits an hour before firing.

## 3. Confirm the metrics actually moved

Re-run the step 1 query and compare against the table. Every row must move to
the right-hand column.

**A badly seated new pack reports exactly the same `25` /
`noCapacitorAttached` as an empty bay.** This is the same trap as the UPS
management card fabricating a healthy battery: "the alert stopped" and "the part
is working" are not the same claim, and only the comparison above tells them
apart. If `cpqDaAccelErrCode` still reads `25` after the pack has had time to
charge, the pack is not seated — do not delete the silence.

## 4. Delete the silence — immediately, not on expiry

The procedure is **step 3 of
[`fit-the-ups-battery.md`](fit-the-ups-battery.md)**, which is written to be
reused and is not duplicated here. Two things carry over unchanged:

- Delete the silence **before** you take the reading that proves the fix, not
  after. That runbook records the one time it was done the other way round: for
  29 minutes a faulty pack would have reported into a suppressed alert.
- Delete it rather than letting it expire. A silence left standing over a
  freshly fitted part suppresses exactly the thing you most want to hear about.

The silence to remove is `3ffc313f-7154-459c-9f62-7c9a432bc97e`, matching
`alertname=~"IloBatteryCondition|IloWriteCacheDisabled"` and `device="shiva"`.

Then update [`../roadmap.md`](../roadmap.md) and the section header comment in
`stacks/observability/prometheus/rules/network.rules.yaml`, both of which record
the silence by UUID and expiry.
