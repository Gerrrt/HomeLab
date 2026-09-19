# Runbook: Replace the laptop cell in `prometheus`

**One glued-in cell, one power-down of the host that watches everything else,
and one test that only works with the machine running.**

> **Status — 2026-09-18: the cell is fitted. Step 8, the mains pull on the new
> cell, has not been run, so
> [#454](https://github.com/Gerrrt/HomeLab/issues/454) stays open.**
>
> The host was down from 14:53:37 to about 18:12 UTC — roughly three hours and
> eighteen minutes, over the two-hour bound this page sets below, and *not* the
> 184 minutes the series appear to show. Step 6 has why.
>
> The new pack reads `charge_full` 6.889 Ah against a `charge_full_design` of
> 6.8 Ah (101 %), `cyclecount` 1, `present` 1, `status` `Charging`. The cell it
> replaced, measured 2026-09-17, read 6.196 Ah of 6.6 Ah (94 %) after 108
> cycles, and went for recycling the same day it came out. **Both design
> figures moved** — 6.6 → 6.8 Ah, and `voltage_min_design` 11.21 → 11.4 V —
> which step 1's table said they could not. The correction is beneath that
> table.
>
> **Step 2 was never performed, and now cannot be.** The alert path was not
> proved on the old cell before it came out: `HostOnBattery` had never fired
> for `prometheus` across the whole 30-day retention. What fired on 2026-09-18
> was accidental — the machine came back from the swap unplugged at 41 %, so
> `HostOnBattery` went pending at 14:56 and firing at 14:57 *on the skewed
> clock*, for `prometheus` and nothing else, with `UpsOnBattery` quiet
> throughout. That is the discriminator step 2 wanted, arrived at by accident.
> It is not the bounded test, and it measured no runtime.
>
> `HostBatteryHealthLow` fired for **`oracle`** from 2026-09-14 and was
> silenced on 2026-09-17 until 2026-10-08
> (`01cb81d7-5e19-4e6d-b386-f5c8c843032b`). That is the other laptop, it is the
> finding [#454](https://github.com/Gerrrt/HomeLab/issues/454) produced rather
> than a fault in this procedure, and that cell is second in line. **Since
> 2026-09-19 it is identified — a Dell M5Y1K — and tracked by
> [#531](https://github.com/Gerrrt/HomeLab/issues/531), bought the same day
> and in transit**; what changes when this page is reused there is in
> *Reusing this page on `oracle`* below. The silence suppresses 72 % **and anything lower**, so that cell's
> further decay is not visible until it expires — see *What is still open*.
>
> **No silence is created anywhere in this runbook, and that is deliberate.**
> Both of the battery runbooks beside this one are largely about a silence that
> had to be deleted at the right moment, and both record deleting it late as
> their one regret. A silence never created cannot be forgotten.

The host is `prometheus` at `10.0.99.20` — the Apple MacBook Pro (2012, Retina
13") in the Compute table of [`../hardware.md`](../hardware.md), and the machine
the whole observability stack runs on. The cell is an A1437, the pack that fits
the `A1425`, bought new 2026-09-13 and recorded under Accessories. It is
**glued to the case**, which is why the purchase was the kit with tools and
adhesive solvent rather than the bare cell.

Budget an evening, most of it solvent soak and charge time, plus a bounded
window in which the estate has no monitoring at all. You will need the kit, and
something to read Prometheus from that is not this laptop — a phone on the same
network is enough for both mains-pull tests.

## Why this is not urgent, and why it is not nothing

The cell that came out read **94 % of design capacity after 108 cycles**,
which was *above* `HostBatteryHealthLow`'s 80 % line. **No alert asked for
this.** It was bought on age and on the failure mode, which is the exception
[`../roadmap.md`](../roadmap.md) names in the same breath as its *Never* line:
a consumable whose failure is a safety or availability event is not an upgrade.

Two stakes, and they are different from each other.

**Safety.** A thirteen-year-old lithium pouch cell, on a shelf, beside the
rack, in an occupied room. The failure mode of a cell this old is swelling and
then fire. Nothing in `host.rules.yaml` can see that coming:
`HostBatteryHealthLow` compares capacity against design capacity, and a cell
can sit at 94 % and still be bulging. Capacity and mechanical integrity are
different questions and only one of them is measured.

**Availability.** `prometheus` is the observability stack. Its cell is the last
link of the mains-cut path that [#93](https://github.com/Gerrrt/HomeLab/issues/93)
and [#110](https://github.com/Gerrrt/HomeLab/issues/110) built — the TP-Link in
U4 is on UPS power so the laptops stay *reachable* through a cut, and the cell
is what keeps this one *running* through it. That half has never been tested
since the machine was commissioned. Step 8 is where it stops being an
assumption.

What this is **not** is a fix for `oracle`, whose cell measures worse at 72 %
and is already firing. That cell is second in line, bought 2026-09-19 and in
transit ([#531](https://github.com/Gerrrt/HomeLab/issues/531)), and this runbook is
written to be reused for it — *Reusing this page on `oracle`* has the
differences between the two machines.

## What goes blind while the lid is off

The two battery runbooks beside this one did not need this section, because
`shiva` and `mjolnir` are not the monitoring host. This one is.

- **Everything stops.** Prometheus, Alertmanager, Loki, Grafana, the SNMP and
  blackbox exporters and this host's Alloy are one compose stack on this
  laptop. While it is down no rule is evaluated, so **no alert can fire and
  none can be recorded**, and Alertmanager could not notify even if something
  else knew. Loki is not ingesting; lines arriving in the window are lost, not
  queued.
- **Any `for:` in flight resets.** An alert that starts and ends inside the
  window leaves no trace anywhere at all. `HostBatteryHealthLow` on `oracle`
  needs a fresh hour after the stack returns before it fires again, and its
  absence for that hour is the rule restarting rather than the cell recovering.
- **Two kinds of hole, and only one of them fills in.** The SNMP and blackbox
  jobs are *scraped by* Prometheus — `morpheus`, `neo`, `mjolnir`, `shiva` and
  every probe — so those minutes are a true hole that nothing can backfill.
  Host metrics from the agent hosts arrive by **remote write** from their own
  Alloy, which buffers to a WAL and retries, so a short outage may backfill.
  Do not rely on it; step 6 measures which half actually did.
- **What keeps working.** `morpheus` keeps filtering — nothing about
  enforcement stops, only observation. The lab's own Prometheus on `alexander`
  keeps watching its guest and is unaffected. `oracle` keeps running the wiki
  and its own jobs.
- **One thing does notice, and it is supposed to.** The off-host healthcheck
  from [`verify-the-alert-path.md`](verify-the-alert-path.md) goes down roughly
  twenty minutes after the host powers off, and emails through a path that is
  not this stack's. **Do not pause it.** That email is the dead man's switch
  working, and a check you have only ever seen green is a check you have not
  tested. Note when it arrives; step 6 wants it back green.
- **Bound the window.** Keep it under two hours. Start after the half hour so
  the hourly converge has just run, and **not on a Sunday near 03:30**, which
  is when `backup-volumes` quiesces the stack —
  [`schedule-maintenance.md`](schedule-maintenance.md) has the timetable. The
  tightest staleness threshold that matters here is 90 minutes, so a window
  under two hours costs at most one late job on the way back.

  **2026-09-18 ran to about three hours and eighteen minutes, not two** —
  14:53:37 to roughly 18:12. Solvent soak and the clock confusion in step 6 are
  where it went. Budget three and a half hours and treat two as the target
  rather than the observed.

## Reusing this page on `oracle`

Added 2026-09-19 under [#531](https://github.com/Gerrrt/HomeLab/issues/531),
before that cell was bought, so the differences are written down while the
`prometheus` swap is fresh rather than discovered with the machine open. The
nine steps below are the same nine; this section is what changes in each. The
host is `oracle` at `10.0.99.30`, the Dell Inspiron 15-3565 in the Compute
table of [`../hardware.md`](../hardware.md), and the pack is a Dell M5Y1K —
14.8 V, 40 Wh, four cells — identified there from the machine's own
`model_name`.

**It is not the monitoring host, and that changes the shape of the window.**
The stack keeps running and every rule keeps evaluating. What goes quiet is
`oracle`'s own work: the wiki and its Postgres; the drift check
(`homelab-drift-check.timer`, about 06:40 daily) and the two collectors that
follow it; and `oracle`'s Alloy, whose metrics arrive by remote write from a
WAL that retries — step 6's `oracle-metrics` query measures whether the
minutes came back. It is also the copy target of `backup-firewall` at 04:30,
which **fails if it cannot copy**, so a `ScheduledJobFailed` for that job the
morning after is the window and not the export. Stay clear of 04:30 and of
06:30–07:00. The `for:` reset applies as before — `HostBatteryHealthLow`
needs a fresh hour after the host returns — and the off-host healthcheck
watches the stack, not this host, so nothing external notices; `InstanceDown`
does, from the stack that is still up. Budget half an hour, not an evening:
this is a latch, not glue.

**A latch, not solvent.** The pack sits behind a slide latch on the
underside: machine off, lid closed, turn it over, slide the latch to unlocked,
lift the pack out by its edge; the new one seats and the latch clicks back.
No screws, no base cover, no tools, no solvent, and no kit — a bare battery.
Step 3's hazard section still applies, and its tells on this machine are a
pack that no longer sits flat or a latch that will not engage. A pack can be
inspected out of the machine in seconds, so look at it.

**The clock is expected to survive, and step 6 checks that rather than
assuming it.** The reset that
[#519](https://github.com/Gerrrt/HomeLab/issues/519) records happened because
the MacBook's RTC is backed by the main cell. This Dell has a separate CR2032
coin cell, reached only by removing the pack, the optical drive, the keyboard
and the palmrest — a latch swap never touches it — and the kernel drives it
as `rtc_cmos`. So the post-swap boot should open at the true time and
`systemd-timesyncd` should have nothing to restore. The check, on `oracle`
once it is back:

```bash
journalctl --list-boots | tail -3
journalctl -b -u systemd-timesyncd --no-pager | grep -i 'jumped\|restored\|unset'
```

The new boot's first timestamp is the true time, and the grep prints nothing.
Anything else is the #519 failure on a machine that was not supposed to have
it, and `HostClockUnsynchronised` fires from the stack — which stays up — about
six minutes into any such window, seeing all of it on this host. The journal
check is still the record, because the rule reads the flag and not the size
of the step. Record the result on that issue either way: a pass here is the
datum it is short of.

**Every query changes `instance`, and one changes the supply.** Step 1's
loop, the ratio, and step 2's and step 8's alert queries all take
`instance="oracle"`; the mains supply is `AC`, not `ADP1`, so step 1's
`online` query reads
`node_power_supply_online{instance="oracle",power_supply="AC"}`. The
discriminator inverts: `HostOnBattery` fires for `oracle` and **not** for
`prometheus`, and `UpsOnBattery` stays quiet. Pull only `oracle`'s brick.

**Step 2 runs this time.** It was skipped on 2026-09-18 and can never be run
for that swap; *What is still open* says to do it properly here. The old cell
comes out at about 30 % rather than full, and the path is proven before the
new cell is asked to prove anything.

**The proof rows are different, and one of them is better.** This pack's
info series carries a `serial_number` — `1650` on the cell in it now — and
the MacBook's carries none, so a changed serial is the one row that cannot be
the old part reporting differently: the cleanest proof available on either
laptop. Against that, the firmware reports `cyclecount` as `0` and always
has, and exports no `temp_celsius`, so two of step 7's rows do not exist
here. The rest hold: `charge_full` rising toward `2.8`, `charge_ampere`
moving across a charge, and the design figures possibly moving if the pack is
third-party. A byte-identical info series still means the new pack is not
seen.

The baseline, read on 2026-09-19 from Prometheus with step 1's loop and the
cell that is about to come out — the **Reads** column step 7 compares
against, with **Observed** to be filled at the fit:

| Metric | Reads 2026-09-19, original cell | After a good new cell | Observed |
| --- | --- | --- | --- |
| `node_power_supply_charge_full` | `2.021`, unchanged across 30 days | at or near `2.8` | |
| `node_power_supply_charge_full_design` | `2.8` | `2.8`, or the pack's own figure | |
| `charge_full / charge_full_design` | `0.7218` | `0.98`–`1.0`, or above it | |
| `node_power_supply_cyclecount` | `0` — never reported | `0` — proves nothing here | |
| `node_power_supply_charge_ampere` | `2.021` | any value that **moves** | |
| `node_power_supply_capacity` | `100` | rises to `100` on charge | |
| `node_power_supply_current_ampere` | `0.001` | non-zero while discharging | |
| `node_power_supply_voltage_volt` | `16.179` on mains | `12`–`16.8`, and varying under load | |
| `node_power_supply_voltage_min_design` | `14.8` | `14.8`, or the pack's own figure | |
| `node_power_supply_temp_celsius` | not exported | not exported | |
| `node_power_supply_present` | `1` | `1` | |
| `node_power_supply_online{power_supply="AC"}` | `1` | `1` | |
| info `manufacturer` | `SMP-Sanyo2` | may or may not change | |
| info `model_name` | `DELL VN3N047` | may or may not change | |
| info `serial_number` | `1650` | **must change** | |
| info `status` | `Full` | `Charging`, then `Full` | |

The serial is exported with a leading space — `" 1650"` — because that is
what the firmware writes to `/sys`; a label matcher that forgets the space
matches nothing.

**Steps 4 and 6 are `oracle`'s own commands.** There is no `make backup` and
no `make down` for this host — those are the stack's. Note the time, take any
pending reboot for free as before, then `sudo systemctl poweroff` on
`oracle`. On the way back, `docker ps` there shows `wiki`, `db` and `alloy`
up, and from the stack the target and alert checks in step 6 read as written;
the hole query's `oracle-metrics` line is the one that matters, and `snmp` is
a control that should show no hole at all.

**Delete the silence when the host goes down, not after the numbers are
in.** Both older battery runbooks regret deleting late, and step 2's argument
against ever creating one applies to the one already standing:
`01cb81d7-5e19-4e6d-b386-f5c8c843032b`, matching
`alertname="HostBatteryHealthLow"`, `instance="oracle"`,
`power_supply="BAT0"`. With the host down for minutes and the rule at
`for: 1h`, nothing pages during the window; on return a good pack reads at or
above `0.8` and the alert never re-fires, and a bad pack firing is the
finding — a return to the seller, as step 7 says. From the monitoring host,
at step 4:

```bash
docker exec alertmanager amtool silence expire \
  01cb81d7-5e19-4e6d-b386-f5c8c843032b --alertmanager.url=http://localhost:9093
docker exec alertmanager amtool silence query --alertmanager.url=http://localhost:9093
```

The second command must still list `b06d032c-8150-47c1-8f46-ed7a8ed52b2e` —
[#351](https://github.com/Gerrrt/HomeLab/issues/351)'s silence on this
host's 32 reallocated sectors, which shares the expiry so one look covered
both. That one stays.

**Step 9 is the same.** Tape the terminals — there is no loose connector on a
latched pack, but the contacts are exposed — and the same disposal, within
days.

## 1. Record the baseline — before touching anything

This is the step that makes the fix provable rather than assumed. The UPS pack
was only ever proven because its before-values were written down first.

```bash
for m in node_power_supply_charge_full node_power_supply_charge_full_design \
         node_power_supply_charge_ampere node_power_supply_capacity \
         node_power_supply_cyclecount node_power_supply_present \
         node_power_supply_voltage_volt node_power_supply_voltage_min_design \
         node_power_supply_temp_celsius node_power_supply_current_ampere; do
  printf '%-44s ' "$m"
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode "query=${m}{instance=\"prometheus\",power_supply=\"BAT0\"}" |
    python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "no data")'
done
```

Two things the loop cannot carry, because one answer is a label set and the
other is a different supply:

```bash
curl -sS -G http://localhost:9090/api/v1/query \
  --data-urlencode 'query=node_power_supply_info{instance="prometheus"}' |
  python3 -m json.tool

curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=node_power_supply_online{instance="prometheus",power_supply="ADP1"}'
```

The ratio the rule itself reads, so the comparison is against the rule rather
than against arithmetic done by hand:

```bash
curl -sG http://localhost:9090/api/v1/query --data-urlencode \
  'query=node_power_supply_charge_full{instance="prometheus"}
         / node_power_supply_charge_full_design{instance="prometheus"}'
```

And the state of the world, so step 6 has something to compare against:

```bash
curl -sS http://localhost:9090/api/v1/alerts |
  python3 -c 'import json,sys; [print(a["labels"].get("alertname"), a["labels"].get("instance"), a["state"]) for a in json.load(sys.stdin)["data"]["alerts"]]'
```

The **Reads** column was measured on 2026-09-17, on the cell that came out.
**Observed** was filled on 2026-09-18, minutes after the fit and part-way
through the first charge — `status` was `Charging` and `capacity` still
climbing — so every row there is a first reading rather than a settled one.
`charge_full` in particular is the gauge's figure before it has learned this
pack across a cycle; step 8 is what settles it.

| Metric | Reads 2026-09-17, thirteen-year-old cell | After a good new cell | Observed 2026-09-18 |
| --- | --- | --- | --- |
| `node_power_supply_charge_full` | `6.196` | at or near its own design figure | `6.889` |
| `node_power_supply_charge_full_design` | `6.6` | **may move — see below** | `6.8` |
| `charge_full / charge_full_design` | `0.9388` | `0.98`–`1.0`, or above it | `1.013` |
| `node_power_supply_cyclecount` | `108` | low — `0` to a handful | `1` |
| `node_power_supply_charge_ampere` | `6.12`, drifting in the last digit | any value that **moves** | `3.48`, climbing |
| `node_power_supply_capacity` | `93` | rises to `100` on charge | `51` and climbing |
| `node_power_supply_current_ampere` | `0` | non-zero while discharging | `1.677`, charging |
| `node_power_supply_voltage_volt` | `12.43` on mains (24h span `12.425`–`12.438`) | `10.9`–`12.6`, and varying under load | `12.607` |
| `node_power_supply_voltage_min_design` | `11.21` | **may move — see below** | `11.4` |
| `node_power_supply_temp_celsius` | `32.7`–`39.2` over 24h, averaging `33.3` | a similar band, never far above it | `25.5`, and every sample since — the pack's gauge returns a constant, see step 3 |
| `node_power_supply_present` | `1` | `1` | `1` |
| `node_power_supply_online{power_supply="ADP1"}` | `1` | `1` | `1` |
| info `manufacturer` | `SMP` | may or may not change | `SMP` — unchanged |
| info `model_name` | `bq20z451` | may or may not change | `bq20z451` — unchanged |
| info `status` | `Full` | `Charging`, then `Full` | `Charging` |

> **The two "must not move" rows were wrong, and their moving is the strongest
> proof available that the pack is genuinely different.** This page asserted
> that `charge_full_design` (`6.6`) and `voltage_min_design` (`11.21`) are
> properties of the model and therefore fixed. They are not. They are figures
> the pack's own gas gauge reports, and an aftermarket A1437 reports its own:
> on 2026-09-18 they read `6.8` Ah and `11.4` V. **Read the expectation the
> other way round from here — a design figure that moves is evidence of a
> different pack, and one that does not is evidence of nothing.** That matters
> more on this machine than it would elsewhere, because it exports no serial
> number (step 7) and `manufacturer` and `model_name` came back byte-identical,
> `SMP` and `bq20z451`, exactly as step 7 warned they would.
>
> **Three names in this family are not what you would guess, and a wrong one
> returns an empty result — which on a command line is indistinguishable from
> "the cell is gone".** The cycle count is `node_power_supply_cyclecount`, one
> word, not `cycle_count`. The capacity family is `charge_*`, not `energy_*`:
> [#454](https://github.com/Gerrrt/HomeLab/issues/454)'s body asked for
> `energy_full` and `energy_full_design`, and neither exists on either laptop.
> And what would be `charge_now` is exported as
> `node_power_supply_charge_ampere`. The `or` branch in `HostBatteryHealthLow`
> keeps the `energy_*` spelling for a future machine whose driver reports
> watt-hours; nothing here reports them.

Query Prometheus rather than reaching for the host's own
`/sys/class/power_supply/`. The stack is what the alerts read and therefore
what is being compared against; the kernel agreeing with itself proves less.

## 2. Prove the alert path on the cell you are about to throw away

> **Not done on 2026-09-18, and it can never be done for this swap — the old
> cell is gone.** Read this step as written before reusing the page on
> `oracle`; what it costs to skip is in *What is still open*.

A lithium cell should come out discharged rather than full, and the only way to
discharge this one is to run the machine on it. That is the mains-pull test, so
do it **now, on the old cell**, and get a proven alert path out of the same
twenty minutes.

1. Have the phone in hand and note the time.
2. Pull `prometheus`'s power brick — **only that brick.** Not the shelf, not the
   TP-Link, not the UPS. This is the discriminator the rule was written for:
   `HostOnBattery` should fire for `prometheus` and for nothing else, and
   `UpsOnBattery` should stay quiet, because the rack did not lose power.
3. Watch it fire:

   ```bash
   curl -sG http://localhost:9090/api/v1/query --data-urlencode \
     'query=node_power_supply_online == 0 and on (instance, power_supply)
            node_power_supply_info{type="Mains"}'

   curl -sG http://localhost:9090/api/v1/query \
     --data-urlencode 'query=ALERTS{alertname="HostOnBattery"}'

   docker exec alertmanager amtool alert query \
     --alertmanager.url=http://localhost:9093 alertname=HostOnBattery
   ```

4. **Budget under four minutes to the notification.** Alloy scrapes the node
   exporter every 60s, the rule carries `for: 2m`, Prometheus evaluates every
   30s, and the power route has `group_wait: 0s`. Nothing arriving inside five
   minutes is a finding about the alert path rather than about the cell, and
   [`verify-the-alert-path.md`](verify-the-alert-path.md) is the runbook for it.
5. Let it run down to roughly **30 %** on `node_power_supply_capacity`, then
   plug back in and confirm the alert resolves and the notification clears. Do
   not run it flat: a deep discharge of a cell about to be removed buys nothing,
   and a hard shutdown of the monitoring host is the thing this whole page
   exists to keep controlled.

Record the times — brick pulled, first `online == 0` sample, alert pending,
alert firing, notification on the phone, brick back, resolved.

**Why this belongs here rather than only at the end:** when step 8 repeats it on
the new cell, the path is already known to work. A failure in step 8 after a
pass here is the cell or the adapter, and nothing about Prometheus,
Alertmanager or the route. That is a discrimination you cannot buy afterwards.

### Do not silence `HostOnBattery` for either test

It is `severity: critical` and `category: power`, which the routing sends to the
urgent receiver with `group_wait: 0s` and a 30-minute repeat. It will really
page. Let it, both times, deliberately — tell anyone else on that receiver
first, and stay out of the Sunday backup window.

The case against silencing, which is the one that wins here:

- The blast radius is one notification to the person standing at the machine
  holding the plug. A bounded twenty-minute test produces at most two.
- [`verify-the-alert-path.md`](verify-the-alert-path.md) proves the *transport*
  using `Watchdog`, which is `vector(1)` and carries no labels. It cannot prove
  this rule's `for: 2m`, its join against
  `node_power_supply_info{type="Mains"}`, or that `category: power` reaches the
  urgent receiver instead of sitting in the default 12h bucket. Nothing else in
  the estate exercises that specific path end to end, and the mains-cut path is
  the reason the cell was bought.
- **A silence created is a silence to remember to delete.**
  [`fit-the-ups-battery.md`](fit-the-ups-battery.md) records deleting one 29
  minutes late; [`replace-the-smart-storage-battery.md`](replace-the-smart-storage-battery.md)
  records the same inversion nine minutes late and says "delete first next time
  too". Both regrets are about a silence standing over a freshly fitted part —
  exactly what a silence created here would be. The way not to repeat it a
  third time is not to create one.

## 3. A thirteen-year-old lithium cell is the hazard, not the laptop

- **Inspect before you plan.** A swollen MacBook cell pushes the trackpad up
  from underneath. A trackpad that has stopped clicking properly, a lid that no
  longer closes flat, or a bottom case that rocks are the tells, and all three
  appear before anything electrical does. If any is present, treat the machine
  as a hazard from that moment: do not charge it further, do not leave it
  unattended, and bring step 4 forward rather than scheduling it.
- **The temperature baseline is the one number that speaks to this, and it
  is a band rather than a figure.** `node_power_supply_temp_celsius` ranged
  `32.7`–`39.2` over the 24 hours to 2026-09-17, averaging `33.3`, idling on
  mains, and never above `40.3` in thirty days of retention. Since
  [#532](https://github.com/Gerrrt/HomeLab/issues/532) `HostBatteryHot` reads
  it: critical, above `45` for five minutes, measured against that band. One
  instantaneous sample proves nothing on its own — a single reading near `39`
  is ordinary for this cell, which is why the rule wants five.
- **The pack now fitted does not measure its temperature, and neither does
  the other laptop's.** The A1437 has reported `25.5` on every one of its
  1,560 samples since it was fitted — zero changes, against 99 changes in the
  old cell's last 26 hours — and the SMC's own battery thermistors
  (`TB0T`/`TB1T`/`TB2T` under `node_hwmon_temp_celsius`) froze at the same
  moment, because the SMC reads them from the pack. `oracle`'s Dell exports no
  `temp_celsius` at all. `HostBatteryTempNotMeasured` (info: recorded, never
  notified) fires for both hosts and clears by itself the day a pack reports a
  moving figure, which is the day `HostBatteryHot` stops being blind. Until
  then the inspection in the first bullet is the only hot-cell detection this
  machine has, and a reading of `25.5` is not evidence that the cell is cool.
- **Order of operations, and it is not negotiable.** Machine off (step 4),
  bottom case off, then **disconnect the battery connector from the logic board
  before touching anything else.** A metal tool near a live cell's terminals is
  the failure this sequence prevents.
- **Never pry, fold or puncture a pouch.** The cells are glued flat across the
  case. Use the kit's adhesive solvent, give it the time the instructions say,
  and pull on the tabs. No metal spudger goes under a cell. If one tears or
  vents, stop, ventilate, and do not continue on that machine that evening.
- **This is not a repair guide, on purpose.** The mechanical procedure is the
  kit's own instructions and iFixit's A1425 battery guide. What is written down
  here is what this repository can be authoritative about: the readings, the
  alerts, the window and the disposal.

## 4. Take the stack down, and the machine with it

1. **Back up first.** The TSDB, Loki's chunks and Grafana's database are all on
   the disk inside the machine you are about to open.

   ```bash
   make backup
   ```

   It quiesces the stack, archives the volumes and verifies each archive
   readable. [`restore-the-stack.md`](restore-the-stack.md) is the other end of
   that, and it is the fallback if the machine does not come back.
2. Note the time. The window starts here, and the healthcheck email is keyed to
   it.
3. Stop the stack cleanly, then the host:

   ```bash
   make down
   sudo systemctl poweroff
   ```

   `make down` preserves volumes. Holding the power button on a running
   Prometheus is not the same thing and is not what this step says.
4. **Take any pending reboot for free.** `RebootRequired` waits three days
   precisely because rebooting this host blinds the estate for the duration —
   and this window is that duration, already being spent. Apply outstanding
   updates before the power-down if any are queued; step 6 checks the alert has
   cleared.

## 5. Fit the cell

Bottom case screws out, **battery connector off the logic board first**,
solvent under each cell in turn, lift by the tabs, clean the residue, seat the
new pack, connector back on, screws back in.

**Do not judge any number until it has had a full charge.** A new cell arriving
part-charged reports a `charge_full` that is not yet its true learned capacity;
the gas gauge learns across a charge cycle. This is the same reason the write
cache alert on `shiva` waits an hour after a pack is fitted. Charge to
`status="Full"` before believing the table in step 7.

## 6. Bring the stack back and confirm nothing else broke

```bash
make up
make ps
```

Then, in order:

- Every target healthy. No output is the pass:

  ```bash
  curl -sS http://localhost:9090/api/v1/targets |
    python3 -c 'import json,sys; [print(t["labels"]["job"], t["scrapeUrl"], t["health"]) for t in json.load(sys.stdin)["data"]["activeTargets"] if t["health"] != "up"]'
  ```

- The firing set matches the step 1 snapshot, minus `RebootRequired` if you
  took the reboot:

  ```bash
  curl -sS http://localhost:9090/api/v1/alerts |
    python3 -c 'import json,sys; [print(a["labels"].get("alertname"), a["labels"].get("instance"), a["state"]) for a in json.load(sys.stdin)["data"]["alerts"]]'
  ```

  On 2026-09-18 it came back identical to step 1's snapshot:
  `ScheduledJobFailed` (`backup-volumes`, exited 2), `SecretsKeyBackupUnproven`,
  `RebootRequired`, and `GatewayMonitorUnreliable` (`morpheus`, `WAN_DHCP6`).
  All four had been firing continuously for the four days before the swap, so
  none of them is this work. `HostBatteryNotReported` stayed quiet and every
  target came back up. The reboot in step 4 was not taken, so `RebootRequired`
  is still firing rather than cleared.

- The off-host healthcheck is green again within about ten minutes of
  Alertmanager starting. If it is still red after that, it is
  [`verify-the-alert-path.md`](verify-the-alert-path.md) and not this runbook.
- **Measure the hole, and measure which half of it filled in.** One query,
  twice, against two jobs that behave differently.

  > **After a battery swap, do not read this query as the window.**
  > Disconnecting the cell clears the RTC. On 2026-09-18 the post-swap journal
  > boot opens `2026-07-28 15:04:45`; `systemd-timesyncd` restored the clock to
  > `14:53:37` — the second the machine went down — and the stack then ran about
  > fourteen minutes writing samples at **backdated** timestamps, 14:54:30 to
  > 15:08, before NTP stepped the clock forward to the true 18:12. So the TSDB
  > holds a 184-minute hole from 15:08 to 18:12 that is *not* downtime, and
  > fourteen minutes of real post-swap operation filed inside the outage. The
  > true window was 14:53:37 to about 18:12. **Take it from
  > `journalctl --list-boots` and the recorded shutdown, not from
  > `query_range`.** Nothing noticed the backdated boot at the time:
  > `HostClockSkew` reads `node_timex_offset_seconds`, which held exactly `0`
  > once timesyncd had restored a wrong but stable clock. `HostClockUnsynchronised`
  > now reads `node_timex_sync_status`, the field that was `0` for precisely
  > that window ([#519](https://github.com/Gerrrt/HomeLab/issues/519)), and
  > would have fired about six minutes in. Read it for what it is: the
  > notification arrives on the phone in real time, the alert record it leaves
  > in the TSDB is stamped by the same wrong clock, and it sees nothing of the
  > hours the stack was down. It is a prompt to come to this paragraph, not a
  > measurement of the window. A further reboot at 18:28 is in the series too
  > and is not part of the swap.

  ```bash
  for j in snmp oracle-metrics; do
    printf '%-16s ' "$j"
    curl -sG http://localhost:9090/api/v1/query_range \
      --data-urlencode "query=count(up{job=\"${j}\"})" \
      --data-urlencode "start=$(date -u -d '-6 hours' +%s)" \
      --data-urlencode "end=$(date -u +%s)" \
      --data-urlencode 'step=60' |
      python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(len(r[0]["values"]) if r else 0, "minutes with data, of 360")'
  done
  ```

  With the window taken from the journal, this still separates the two jobs'
  behaviour. `snmp` is scraped by Prometheus, so its hole is the shape of the
  outage. `oracle-metrics` arrives by remote write and may be shorter, because
  that agent's WAL retried. A shorter `oracle-metrics` hole is the backfill
  working; an equal one means it did not. Either way the number is now known
  rather than assumed.
- **`HostBatteryNotReported` is the automatic verdict on "is there a cell at
  all", and it arrives fifteen minutes after the stack is back.** Silence at
  t+15m is the pass. Do not skip ahead to step 7's table before it has had that
  quarter of an hour.

## 7. Confirm the metrics actually moved

Re-run step 1's loop and fill the **Observed** column. It was filled on
2026-09-18 and the readings are there; what follows is how they were judged.

> **There is no serial number to appeal to.** `shiva`'s pack was proven by
> `cpqHeSysBatterySerialNumber` changing — the one row that could not be the old
> part reporting differently. This machine does not export one:
> `node_power_supply_info` on `prometheus` carries `manufacturer`,
> `model_name`, `technology`, `status` and `type`, and no serial. (`oracle`'s
> Dell does carry one, which is worth knowing when this runbook is reused
> there.) Worse, an aftermarket A1437 commonly reuses the same gas gauge, so
> `SMP` / `bq20z451` reading identically afterwards proves nothing either way.
> The honest proof is several rows together, not one. On 2026-09-18 it was
> **four**: `cyclecount` falling from `108` to `1`, `charge_full` rising from
> `6.196` to `6.889`, `charge_ampere` moving across a charge cycle, and — the
> row this page did not know it had — **both design figures changing**,
> `charge_full_design` `6.6` → `6.8` and `voltage_min_design` `11.21` → `11.4`.
> That last one turned out to be the strongest of them, and the table above now
> says so. A reading that is byte-for-byte identical to the baseline means the
> machine is reporting the old pack's stored values — treat that as "the new
> cell is not seen", not as "the numbers happen to match", and go back to the
> connector.

Two more failure shapes worth naming:

- **`charge_full` reads exactly its own `charge_full_design` and never moves.**
  That is the gauge reporting the design figure because it has not learned a
  capacity yet, not a cell at 100 % health. It becomes a measurement after one
  full charge and one substantial discharge, and step 8 provides the discharge.
  The 2026-09-18 reading is not this case: `6.889` is *above* the `6.8` design
  figure, so the gauge is reporting something it measured rather than something
  it was told.
- **`HostBatteryHealthLow` fires for `prometheus`.** The new cell is measurably
  worse than the thirteen-year-old one it replaced. That is a return to the
  seller, not a finding to write up.

## 8. Pull the mains again — the test the cell is there for

> This is the step that closes
> [#454](https://github.com/Gerrrt/HomeLab/issues/454). Everything before it
> makes a claim about capacity. Only this one makes the claim the cell was
> bought for.
>
> **Not done as of 2026-09-18.** The pack was still charging when the fit was
> recorded — `capacity` 51 % and rising — and this step needs it full. Until it
> runs, the property the cell was bought for is untested and that issue stays
> open. The accidental discharge on the day is not a substitute: it began at
> 41 %, was not bounded, measured no runtime, and its timestamps are the
> backdated ones step 6 describes.

Same procedure as step 2, now on the new cell and with the machine fully
charged. Because the numbers are finally meaningful, also **measure the runtime
rather than estimating it** — a figure the estate has never had. Since
[#532](https://github.com/Gerrrt/HomeLab/issues/532) the stack computes it for
you on every cut, from the pack's own instantaneous draw, and only while the
adapter reports no input:

```bash
# Seconds left at the draw the stack is presenting right now — recorded only
# while on battery, so an empty result on mains is correct, not broken
curl -sG http://localhost:9090/api/v1/query --data-urlencode \
  'query=homelab_battery_runtime_seconds{instance="prometheus"} / 60'

# The draw itself, in amps, for the record
curl -sG http://localhost:9090/api/v1/query --data-urlencode \
  'query=node_power_supply_current_ampere{instance="prometheus",power_supply="BAT0"}'
```

`HostBatteryRuntimeLow` pages under thirty minutes of that projection. A
healthy pack near full projects hours, so it should stay quiet through this
bounded test; if it fires, the cell or the draw is not what step 7 said.

Bound the test: **stop at twenty minutes or 50 % capacity, whichever comes
first.** The point is that the property holds and is measurable, not that the
cell can be flattened.

Confirm on the way back that the alert resolves, the notification clears,
`online` returns to `1` and `status` goes to `Charging`.

And check the same discriminator as step 2: `HostOnBattery` fires for
`prometheus` and not for `oracle`, and `UpsOnBattery` stays quiet throughout.
**If `UpsOnBattery` fired, you pulled the wrong plug.**

Record the measured runtime in the status banner at the top of this page, and
note that it is one measurement at one load on one day.

## 9. Retire the old cell

- **Tape the connector and any exposed terminals** the moment it is out.
- **Not the bin, and not back on the shelf.** A thirteen-year-old cell sitting
  beside the rack is the hazard this whole exercise was opened about; leaving
  the removed one there keeps the hazard and gives up the capacity.
- Keep it in a non-flammable container, away from the rack and away from
  anything that burns, and take it to a council household-waste battery point or
  a retailer take-back **within days, not months**. Note the date. **The cell
  removed on 2026-09-18 went for recycling the same day.**
- **Never post it.** A damaged lithium cell is not a mailable item.
- If it came out swollen or vented: outside, metal container, same day, and do
  not apply solvent to it.

## If something goes wrong

**The machine does not come back.** Nothing on the disk changed — the stack is
volumes plus a checkout. Re-seat the battery connector, and try mains with the
cell disconnected, because a MacBook runs on the adapter alone. `make up` once
it boots. The estate stays blind until it does, and
[`restore-the-stack.md`](restore-the-stack.md) is the path if the disk itself
turns out to be the problem.

**`HostBatteryNotReported` fires fifteen minutes after the lid closed.** The
connector, almost always. Then `/sys/class/power_supply/` on the host, to see
whether the kernel enumerates `BAT0` at all.

**Everything reads exactly as it did before.** Step 7's warning. That is not a
coincidence, and it is not the numbers happening to match.

**Step 8's pull produced nothing, but step 2's worked.** The path is proven, so
the difference is the new cell or the adapter. Check that
`node_power_supply_online{power_supply="ADP1"}` actually went to `0` — if it did
not, the brick is still feeding the machine and nothing was tested.

**The healthcheck email never arrived during the window.** That is more serious
than anything else on this page, because it is the one signal that survives this
host being down. [`verify-the-alert-path.md`](verify-the-alert-path.md).

## What is still open

- **Step 8 has not been run, and it is the whole of what keeps
  [#454](https://github.com/Gerrrt/HomeLab/issues/454) open.** Everything else
  the issue asked for is done and measured. The cell needs a full charge first.
- **Step 2 can never be run for this swap: the old cell is gone.** The
  discrimination it was written to buy — a step-8 failure being the cell or the
  adapter and nothing else, because the path was already proven — is
  unavailable. A failure in step 8 will be ambiguous between the pack, the brick
  and the rule. The only evidence the path works is the accidental firing on
  2026-09-18, which did at least exercise the real rule against the real
  adapter. Run step 2 properly when this page is reused on `oracle`.
- **`oracle`'s cell reads 72 %, its replacement is bought and in transit
  ([#531](https://github.com/Gerrrt/HomeLab/issues/531)), and its alert is
  silenced until 2026-10-08** — `01cb81d7-5e19-4e6d-b386-f5c8c843032b`, matching
  `alertname="HostBatteryHealthLow"`, `instance="oracle"`,
  `power_supply="BAT0"`. It shares an expiry with the `#351` disk silence on the
  same host so one look covers both. Because the rule is `< 0.8` and no label
  carries the ratio, that silence hides any *further* decay of the cell as well
  as the 72 % it was created for; re-read
  `node_power_supply_charge_full{instance="oracle"} /
  node_power_supply_charge_full_design{instance="oracle"}` rather than trusting
  the absence of an alert.

  This runbook is written to be reused for that cell, and since 2026-09-19
  *Reusing this page on `oracle`* above carries the differences, the Dell's
  baseline and the silence's deletion. The short form: its mains supply is
  `AC` and not `ADP1`; its firmware reports `cyclecount` as `0` and always
  has, so one of step 7's proof rows is unavailable there; it exports no
  `temp_celsius`; its info series *does* carry a `serial_number`, which is a
  proof row this machine lacks and the cleanest of them all; and its clock is
  expected to survive the disconnect, because the coin cell that backs it is
  separate from the pack — expected, and checked at the fit rather than
  assumed, for [#519](https://github.com/Gerrrt/HomeLab/issues/519). If it
  does not survive, `HostClockUnsynchronised` is what will say so, and because
  `oracle` is not the monitoring host it sees that whole window rather than
  the slice this one caught.
- **Runtime-on-battery is projected on every cut, but has still never been
  measured.** `homelab_battery_runtime_seconds` and `HostBatteryRuntimeLow`
  ([#532](https://github.com/Gerrrt/HomeLab/issues/532)) read the pack's draw
  whenever the adapter loses input, so the series that would notice the figure
  halving now exists. The bounded measurement step 8 asks for is what proves
  the projection against a clock, and it is still owed.
- **Cell temperature is unmeasured on both laptops, by the packs' own doing.**
  `HostBatteryHot` is loaded and cannot fire: the A1437 returns a constant and
  the Dell exports nothing (step 3). `HostBatteryTempNotMeasured` records that
  for each host and clears when a pack that measures is fitted; until then the
  trackpad inspection is the only detection for the failure mode
  [#454](https://github.com/Gerrrt/HomeLab/issues/454) opened with.

**Closed since this page was written:** `HostBatteryHealthLow`'s description
named [`fit-the-ups-battery.md`](fit-the-ups-battery.md) — the rack pack in
`mjolnir`, not this cell — because that was the only runbook there was when the
rule was written. [#506](https://github.com/Gerrrt/HomeLab/pull/506) retargeted
it at this file on 2026-09-17, moving the `exp_annotations` blocks in
`stacks/observability/prometheus/tests/host.test.yaml` with it. And **a battery
disconnect resets the RTC, and the TSDB records the result as a hole that is
not one** — [#519](https://github.com/Gerrrt/HomeLab/issues/519) asked whether
anything should notice. `HostClockUnsynchronised` in `host.rules.yaml` now reads
`node_timex_sync_status == 0` for five minutes: on the thirty days of retention
before it landed, eight ordinary boots produced no `0` sample at all and the
only run was this swap's backdated window. What it can and cannot see is in
step 6 and in the rule's own comment; the runbook instruction — take the window
from the journal — stands.
