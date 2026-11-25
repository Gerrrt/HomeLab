# ADR-0121: Accept the UPS shutdown sequence without a live test

**Status:** Accepted · 2026-11 · amends
[ADR-0049](0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md) and
[ADR-0107](0107-subscribe-trinity-to-the-ups-and-bound-saruman-s-guest-stop.md)

## Context

ADR-0049 decided who halts on the UPS's signal, and ADR-0107 added `trinity`
and bounded `Saruman`'s guest stop. Every configuration step is applied:
steps 0 to 4 of
[`shut-down-on-the-ups.md`](../runbooks/shut-down-on-the-ups.md) on
2026-09-23, `Saruman`'s 3.6 and 3.7 on 2026-11-13, and step 4b, `HOSTSYNC
600` and the 16-minute low-battery duration on 2026-11-20. Each secondary
reads `OL` from `morpheus`.

The runbook's steps 5 and 6 were left as the proof. Step 5 forces the
sequence with `upsmon -c fsd`, halting every subscribed host on purpose.
Step 6 pulls the mains to measure the pack. The operator will not run either.
A forced halt of the whole rack, and a deliberate power cut, cost more than
the certainty they would buy for a home lab, and a test that stays listed as
owed and is never run is noise.

## Decision

**The UPS shutdown sequence is accepted as configured, without a live test.**

- Steps 5 and 6 of the runbook are not owed. They stay in the runbook as
  a procedure anyone may run, and nothing lists them as outstanding.
- [#574](https://github.com/Gerrrt/HomeLab/issues/574) closes on the applied
  configuration.
- The pack's runtime stays the card's estimate, about 47 minutes at 21 %
  load. The 16-minute low-battery duration was sized from the worst-case
  bound in step 3.8, not from a measurement, so it does not depend on one.

**Unchanged:** every rule, alert and setting ADR-0049 and ADR-0107 put in
place. `UpsOnBattery`, `UpsBatteryLow` and the self-test alerts still watch
the pack.

## Consequences

- A fault in the sequence would first show in a real outage that outlasts
  the pack. The operator accepts that.
- The UPS's outlet-group turn-off and load-shedding settings stay unread.
  That is a look at the card's web page, not a test. A shed on group 1
  would cut the PDU before or during the halt, and the card's page is where
  to check.
- `SmartDriveUnsafeShutdownsGrowing` is a conditional power-loss signal,
  not a verdict on the sequence. It also pages when the UPS cuts its output
  after a clean halt, and its one-day comparison with a one-hour pending
  period can miss a host that stays down for a long outage. Whether the
  sequence ran and finished is in each host's shutdown log, and
  `shut-down-on-the-ups.md` *If something goes wrong* says how to read it.
