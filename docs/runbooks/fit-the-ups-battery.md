# Runbook: Fit the UPS battery and rack the shelf switch

**One rack visit, in an order that matters — and one alert that has to be
un-silenced by hand at the right moment.**

> **Status — 2026-09-03: the pack is in, proven, and testing on a schedule.
> The shelf is not racked.**
>
> The APCRBC115 was fitted, the silence was deleted, and a self-test passed:
> `upsTestResultsSummary` went `4` (aborted) to `1` (donePass) at 22:45 UTC.
> Step 5's comparison holds on one metric of the three — `upsBatteryVoltage`
> left its fabricated `480` for a float reading that moves across `540`–`549`.
> Runtime does not carry that weight: it has sat on exactly `63`, the fabricated
> value, for 744 of 764 samples since the fit. Charge still reads exactly `100`,
> which is what a pack at float voltage looks like rather than a card that
> cannot see one.
>
> **Step 6 is done — checked 2026-09-03, and it was already true when checked.**
> The card reads `upsAdvTestDiagnosticSchedule` `8` (biweeklySinceLastTest),
> `upsAdvTestLastDiagnosticsDate` `08/28/2026` and
> `upsAdvTestDiagnosticsResults` `1` (ok). Whether the schedule was set during
> the rack visit or has been the card's default all along is not something the
> NMC will tell you after the fact; what is checkable is that it is on now. The
> next unattended test falls due on or about **2026-09-11**, and it is that date
> advancing on its own — not the setting reading `8` — that proves the schedule
> actually runs.
>
> **Nothing in the stack can see any of that.** All three are PowerNet OIDs
> under `1.3.6.1.4.1.318`, and the `apc_ups` module walks the standard UPS-MIB
> only, so no rule in `ups.rules.yaml` can detect a card that has quietly
> stopped testing. That is
> [#249](https://github.com/Gerrrt/HomeLab/issues/249); until it lands, step 6
> is verified by hand with `scripts/snmp-walk.sh` and by nothing else.
>
> **One reading that was not reset.** `upsBasicBatteryLastReplaceDate` is
> `08/15/2026` — thirteen days before the pack went in, on a date when this
> card's own self-test was still aborting over an empty bay. Step 2, item 5 asks
> for that date to come back reset and it did not, so the card's battery-age
> accounting, and the replacement date it projects from it, are keyed to
> something that did not happen. Harmless today; wrong in four years, when it is
> the only record of how old the pack is.
>
> The shelf and the switch move (step 2, items 1–4) were not done, so
> [#110](https://github.com/Gerrrt/HomeLab/issues/110) is untouched and
> `prometheus` and `oracle` still go deaf on a mains cut.
>
> **One thing to do differently next time.** The silence was deleted at 23:14
> UTC — *after* the 22:45 self-test, not before it. It cost nothing here because
> the test passed, but for those 29 minutes a faulty pack would have been
> reported into a suppressed alert. That inversion is the single failure mode
> step 3 exists to prevent.

`mjolnir` ran with no battery pack for the whole life of this stack. A mains
loss was an immediate hard shutdown of the entire rack. The management card
never reported the missing pack; it fabricated a healthy one, so every alert
keyed on charge, runtime or alarm count was quietly dead. Only
`UpsSelfTestFailed` and `UpsBatteryUnproven` in `ups.rules.yaml` can see the
real condition, because they read the one value the card will not fake.

Fitting a pack does not by itself end any of that. A card that cannot see a pack
which *is* present reports the same fabricated values as one over an empty bay,
so the steps below are what turns a fitted battery into a proven one.

The pack alone is not the whole fix.

## Why the shelf is part of this, not a follow-up

`prometheus` and `oracle` hang off an unmanaged TP-Link that has no battery at
all. Both are laptops with their own batteries, so on a mains cut they stay
*running* and go *deaf* — the monitoring host survives the event it exists to
observe and cannot report it.

Fitting the pack protects the rack and does nothing for that switch. Racking the
switch in U4 and moving it onto UPS power is what closes the gap, which is why
[#93](https://github.com/Gerrrt/HomeLab/issues/93) and
[#110](https://github.com/Gerrrt/HomeLab/issues/110) were bought together and
are done together.

## Before you start

Two boxes, checked before either is opened:

- **The cartridge is an APCRBC115.** Not a compatible-with listing that turns
  out to be a different form factor once the front bezel is off.
- **The shelf matches the spec measured at the rack on 2026-08-21:** 4-post
  frame, square mounting holes, a **full 1U shelf with rear support** rather
  than a cantilever, and **cage nuts plus screws** — most shelves include them,
  not all.

Depth is not a constraint. U4 is empty only because nothing had been chosen for
it, so there is no service clearance to preserve.

You will also need the stack up on `prometheus`, and access to the management
card's web UI for `mjolnir` at `10.0.99.10`.

## 1. Record the baseline before touching anything

The point of this step is that the after-state is *provably* different rather
than assumed to be. If the pack is already in and this was not run first, use
the recorded pre-fit values in the table below as the baseline — they are the
observed readings from this UPS, and `ups.rules.yaml` carries the same five.

Capture what the card claims:

```bash
for m in upsBatteryStatus upsEstimatedChargeRemaining \
         upsEstimatedMinutesRemaining upsBatteryVoltage \
         upsAlarmsPresent upsTestResultsSummary; do
  printf '%-32s ' "$m"
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode "query=${m}{device=\"mjolnir\"}" |
    python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "no data")'
done
```

Observed on this UPS with no pack fitted — every one of these was derived,
not measured:

| Metric | Reads | Means |
| --- | --- | --- |
| `upsBatteryStatus` | `2` | batteryNormal |
| `upsEstimatedChargeRemaining` | `100` | percent |
| `upsEstimatedMinutesRemaining` | `63` | minutes of runtime it does not have |
| `upsBatteryVoltage` | `480` | 48.0 V |
| `upsAlarmsPresent` | `0` | no alarm raised |
| `upsTestResultsSummary` | `4` | aborted — **the one honest value** |

Write the numbers down. In step 5 you compare against them, and a charge still
reading exactly `100` with a runtime still at exactly `63` is the signature of a
card that is still fabricating because it does not see the new pack.

Query Prometheus rather than reaching for `snmpget`: the community would sit on
your command line where `ps` can read it. `scripts/snmp-verify.sh` exists for
the cases that genuinely need the wire, and reads the credential from SOPS.

## 2. At the rack, in this order

1. **Rack the 1U vented shelf in U4.** Cage nuts front and rear, screws through
   the shelf, rear support engaged.
2. **Move the TP-Link onto the shelf** and re-seat its uplink to port 3 of the
   main switch, plus the runs to `prometheus` and `oracle`.
3. **Move the TP-Link's power onto a UPS-fed outlet.** This is the step that
   closes #110. A switch that has been relocated onto a shelf but left on a wall
   socket is tidier and no better protected — the laptops still go deaf on a
   mains cut.
4. **Rack the cold-spare ProDesk from
   [#92](https://github.com/Gerrrt/HomeLab/issues/92) beside it**, cabled for
   its cold-spare role and **left powered off**. A spare that is plugged in and
   on the network is exposed to whatever took the primary.
5. **Fit the APCRBC115 pack** last, per the Smart-UPS front-bezel procedure, and
   confirm the card comes back with the battery-replacement date reset.

## 3. Delete the silence — immediately, not on expiry

> **Done 2026-08-28**, at 23:14 UTC. The procedure below is kept for the next
> time a pack is changed and a silence is standing over it.

`UpsSelfTestFailed` was silenced in Alertmanager until **2026-09-20**
(`54f1715c-e57b-4322-8a6d-5435bc8e1bd8`). It routes on `category=power` to the
`urgent` receiver with `group_wait: 0s` and `repeat_interval: 30m`, so leaving
it firing meant paging every half hour about a condition already known — which
is how an urgent receiver stops being read. The silence was correct while
nothing could be done about it.

It stops being correct the moment the pack is in. Between fitting and 20
September it would suppress `UpsSelfTestFailed` on a UPS that can finally report
honestly — **including a new pack that is faulty or badly seated**, which is
precisely the thing you have just introduced and most want to hear about.

```bash
curl -sS -X DELETE \
  http://localhost:9093/api/v2/silence/54f1715c-e57b-4322-8a6d-5435bc8e1bd8
```

Confirm it is gone rather than merely expired:

```bash
curl -sS http://localhost:9093/api/v2/silences |
  python3 -c 'import json,sys; [print(s["id"], s["status"]["state"]) for s in json.load(sys.stdin)]'
```

Delete it **before** the self-test, not after. Run in the other order, the one
result you most need to see is the one that is suppressed.

## 4. Run one self-test, and read it from both ends

From the management card's diagnostics page, start a single self-test. Then
confirm the result twice:

- **On the NMC** — the page that read "Refused — internal fault" should now
  report a pass.
- **In Prometheus** — because the NMC agreeing with itself proves nothing about
  the scrape path:

  ```bash
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode 'query=upsTestResultsSummary{device="mjolnir"}'
  ```

`upsTestResultsSummary` must read `1` (donePass). The full enumeration, from
`ups.rules.yaml`:

| Value | Meaning |
| --- | --- |
| `1` | donePass |
| `2` | doneWarning |
| `3` | doneError |
| `4` | aborted |
| `5` | inProgress |
| `6` | noTestsInitiated |

Anything in `2`–`4` means `UpsSelfTestFailed` should fire within 5 minutes, and
it now will, because you deleted the silence first. That is the system working.

## 5. Confirm the fabricated metrics became real

Re-run the loop from step 1 and compare against the baseline. Charge, runtime
and voltage should now reflect an actual pack — a partially charged new
cartridge typically reads *below* 100% for the first hours, which is itself
evidence the value is measured.

If they are byte-for-byte identical to the baseline, the card is still
fabricating. Treat that as "the pack is not seen", not as "the pack is fine and
the numbers happen to match" — go back to seating and the battery-replacement
date before believing anything else on the dashboard.

**Read voltage first, and do not read too much into runtime.** Measured over the
six days after this pack went in, `upsBatteryVoltage` moved across `540`–`549`
and `upsEstimatedMinutesRemaining` sat on exactly `63` for 744 of 764 samples,
leaving it only for excursions to `45`, `60` and `137` under changing load. `63`
is also the number the card fabricated over an empty bay, so on any single
reading runtime cannot tell the two apart — a float voltage that varies can, and
charge cannot either, because it has read exactly `100` on every sample since
the fit.

## 6. Enable scheduled self-tests

A value of `1` is the *last* result, not a fresh one. If the NMC stops testing
entirely the metric simply stops changing, and nothing in `ups.rules.yaml`
detects that — `upsTestStartTime` is `sysUpTime`-relative and does not survive
an agent restart, so it is not a usable staleness signal.

Scheduled tests on the device are the control. Enable them on the NMC so
`UpsBatteryUnproven` — which reads `min_over_time`/`max_over_time` over 7 days
rather than a `for:` that a Prometheus restart would reset — has live evidence
to read instead of an absence of it. The reasoning is argued in full in the
header of `ups.rules.yaml`; this step is where it gets acted on.

Do not go on running self-tests by hand to keep the metric warm. A test
transfers the load to battery, and on a pack that is weak that is the outage the
alert exists to warn about.

### Check it rather than assume it — and the check is not in Prometheus

The setting lives in PowerNet, not in the UPS-MIB the `apc_ups` module walks, so
no Prometheus query can answer this. Read it off the card:

```bash
scripts/snmp-walk.sh --device mjolnir 1.3.6.1.4.1.318.1.1.1.7.2
```

Three of those rows are the answer:

| OID | Object | On `mjolnir`, 2026-09-03 |
| --- | --- | --- |
| `…7.2.1.0` | `upsAdvTestDiagnosticSchedule` | `8` — biweeklySinceLastTest |
| `…7.2.3.0` | `upsAdvTestDiagnosticsResults` | `1` — ok |
| `…7.2.4.0` | `upsAdvTestLastDiagnosticsDate` | `08/28/2026` |

`upsAdvTestDiagnosticSchedule` reads `1` unknown, `2` biweekly, `3` weekly, `4`
atTurnOn, `5` never, `6` fourWeeks, `7` twelveWeeks, `8` biweeklySinceLastTest,
`9` weeklySinceLastTest — from APC's own PowerNet-MIB, not from the older
enumeration that stops at `7`. Anything in `1`, `4` or `5` means the card is not
testing on a schedule whatever the web UI last appeared to say. The two
`SinceLastTest` values are the ones to prefer: they count from the last test
rather than from power-on, so a reboot does not restart the clock.

**The setting being on is not the same as the schedule running.** What proves it
is `upsAdvTestLastDiagnosticsDate` advancing with nobody at the card — on a
biweekly schedule, roughly fourteen days after the date it currently shows. Note
the date, come back after it, and read it again.

Nothing watches any of this on your behalf: these OIDs are not scraped, so a
card that silently drops back to `never` produces no alert and no changed
metric. That gap is named in the header of `ups.rules.yaml` and filed as
[#249](https://github.com/Gerrrt/HomeLab/issues/249) — closing it takes two
files, not one: `scripts/snmp-mibs.sh` has to fetch APC's MIB before
`make snmp-generate` can resolve the new OIDs, and that is where the pinning
decision lives, alongside the walk added to `snmp-exporter/generator.yaml`. A
new vendor source with no first-party git ref to point at is why it is an issue
rather than a step in this runbook. When it lands, this section becomes a
PromQL query.

## 7. What becomes true afterwards

`UpsBatteryLow`, `UpsChargeLow` and `UpsRuntimeCritical` become meaningful rules
rather than decorative ones, reading values that finally correspond to hardware.
**No rule edits are needed** — the file was written so that its rules become
correct the moment a pack exists, and nothing in it changes today.

## If something goes wrong

**The self-test still reports `4` (aborted).** Do not re-create the silence. A
still-aborted test with a pack fitted is a finding: check the cartridge is fully
seated and its connector latched, and reset the battery-replacement date on the
NMC so the card re-evaluates. If it persists, the alert firing every 30 minutes
is the correct state of the world until it is resolved.

**The self-test reads `5` (inProgress) and stays there.** `UpsSelfTestFailed` is
bounded below `5` deliberately so a test in flight does not trip it. Wait for it
to settle before concluding anything.

**`prometheus` or `oracle` came back unreachable after the shelf move.** The
uplink to port 3 of the main switch, not the UPS. Nothing in this runbook
touches VLAN configuration.

## Flipping the documents — all three passes are done

This happened in three passes, because "a pack is fitted", "the UPS works" and
"the UPS keeps proving it works" are different claims and became true — or were
found to be true — at different times.

**Done on 2026-08-28**, when the pack went in: every file that asserted there is
no battery said something false from that moment, so they were moved to what was
actually true — a pack is fitted and unproven, with the outstanding silence and
self-test named. That is `ups-power.json`, `ups.rules.yaml`, `docs/security.md`,
`docs/observability.md`, `README.md`, `docs/roadmap.md` and `docs/hardware.md`.

**Done on 2026-08-28**, once the self-test passed: the same files moved from
*fitted and unproven* to *proven*, with the two things that outlast the fix
named in each — that history before 2026-08-28 is fabricated rather than
measured, and that scheduled self-tests are still off. That is `ups-power.json`,
`ups.rules.yaml`, `docs/security.md`, `docs/observability.md`, `README.md` and
`docs/roadmap.md`.

One deliberate departure from the plan above. The banner panel was **rewritten
rather than deleted**, because there is still something true and non-obvious for
it to say and keeping it left the panel count where it was, so the
`scripts/check_docs.py` panel-count coupling stayed untriggered.

**Done on 2026-09-03**, when step 6 was checked rather than performed: the card
was already set to `biweeklySinceLastTest`, so every file saying scheduled
self-tests are off was asserting something the device contradicts. The same set
moved again — `ups-power.json`, `ups.rules.yaml`, `docs/security.md`,
`README.md`, `docs/hardware.md` and `docs/roadmap.md` — this time to *on, and
unwatched*: the schedule is set, no rule can see it, and the proof is
`upsAdvTestLastDiagnosticsDate` advancing on its own around 2026-09-11. #93
moved into Done in the same pass, because its third step is now satisfied.

**Still to do:**

| File | What changes |
| --- | --- |
| `docs/images/ups-power.png` | Re-capture the set with `make screenshots`. The committed image is from 2026-08-22 and shows the original no-battery banner; it needs the decrypted Grafana password, so it is a human step |
| The NMC | Reset `upsBasicBatteryLastReplaceDate`, which still reads `08/15/2026` for a pack fitted on the 28th. A human step at the card's web UI: every SNMP path in this repository reads and none of them writes |

And when the shelf is racked, which is a separate visit and separate issue:

| File | What changes |
| --- | --- |
| `docs/hardware.md` | The 1U shelf into the rack table at U4, and into Accessories |
| `docs/network.md` | The TP-Link note — now racked and on UPS power |
| `docs/roadmap.md` | Move #110 into Done |

One coupling to know about before you start editing: **deleting the banner panel
changes the dashboard's panel count**, and `scripts/check_docs.py` asserts every
panel count quoted in prose against the live JSON. The banner was retitled
rather than removed on 2026-08-28 for exactly that reason — the count did not
move. When you do delete it, 119 becomes 118 in both `README.md` and
`stacks/observability/README.md`, in the same commit, or CI will fail. Run
`make validate` before pushing.

Then close [#93](https://github.com/Gerrrt/HomeLab/issues/93), and
[#110](https://github.com/Gerrrt/HomeLab/issues/110) when the shelf follows.
