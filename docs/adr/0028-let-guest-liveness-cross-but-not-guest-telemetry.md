# ADR-0028: Let guest liveness cross, but not guest telemetry

**Status:** Accepted · 2026-09

## Context

[ADR-0007](0007-defensive-estate-and-offensive-range.md) keeps the lab's
telemetry in the lab, and [ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)
gave it its own Prometheus so nothing has to point at `10.0.99.20`. That
isolation is sound and is not being reopened.

[#257](https://github.com/Gerrrt/HomeLab/issues/257) names what follows from it,
and it is a silent failure: **nothing here can tell a quiet lab from a dead
one.** `Saruman`'s own agent has reported into the estate's stack since
2026-09-02 ([#88](https://github.com/Gerrrt/HomeLab/issues/88)), so the
hypervisor is visible. Its guests are not. Verified 2026-09-07 —
`{instance=~".*alexander.*"}` returns nothing at all, while `stacks/lab/` has
been running on that guest since 2026-09-05.

`RemoteWriteJobStale` is the estate's net for a host that goes quiet, and it
keys on jobs that *arrive* here. That is precisely why it covered `Saruman` the
moment it started pushing, and precisely why it can never cover anything that
stays in the lab. #257 puts it plainly: *"the lab is being built to go quiet."*

The hypervisor's agent keeps reporting a healthy DL360 either way, which is what
makes the failure look fine.

## Decision

**A guest's run state is hypervisor state, not guest telemetry. It may cross.
Everything about what a guest is *doing* stays in the lab, unchanged.**

The distinction is the whole decision, so it is drawn explicitly:

| Crosses | Does not |
| --- | --- |
| That a guest exists, its VMID and name | Any metric produced inside it |
| Whether it is running | Any log line it writes |
| How many guests the hypervisor has | What services it runs, and their health |

"VM 100 exists and is running" is the same class of fact as "this host has four
CPUs", which the estate already collects from this host and has since #88. It is
read from `qm`/`pct` **on the hypervisor**, by the agent that is already there,
and it describes the hypervisor's workload rather than the workload's contents.

ADR-0007's Decision is about telemetry, and #257 anticipated this reading: *"a
heartbeat about the stack itself may not be telemetry in that sense."* This ADR
holds that it is not. **ADR-0007 is not amended and does not need to be** — no
new data leaves the lab, because none of this is read from inside it.

**Nothing new is opened to make this work.** No firewall pass, no route, no
listener. `Saruman` already pushes to `10.0.99.20` over a rule that exists;
`scripts/collect-guest-state.sh` writes a textfile the agent already reads. The
implementation cost is one row in the collectors table.

## Consequences

- **"The guest died" is now detectable and "the lab stack died" still is not.**
  This is the honest half of the decision. A guest powered on with a dead
  Prometheus inside it is indistinguishable from a healthy one, and
  `HypervisorGuestStopped` will say nothing. What has closed is the case where
  the whole guest goes away — which is the one that takes the lab's own
  monitoring with it, and therefore the one no amount of in-lab alerting could
  ever have caught.

- **Closing the other half needs a firewall change, and its price is named
  here so the next person does not re-derive it.** #257's first option is a
  handful of series from the lab stack — is it up, when did it last ingest —
  reaching `10.0.99.20`. The existing pass is `10.0.30.110 → 10.0.99.20:9090,
  3100`, and that is `Saruman`, not `alexander` at `10.0.30.40`. So it wants a
  new pass on the Lemmiwinks side. That remains open, and it is a smaller
  question now than it was, because the failure that used to hide behind it is
  covered.

- **The estate cannot tell a deliberate shutdown from a crash, and the alert
  says so.** `HypervisorGuestStopped` is a warning after an hour, not a page.
  #257 allows for "a machine that is powered off between sessions", which is
  this signal with a different cause. A table of which guests are expected to be
  up was rejected: it is a second copy of a fact that changes whenever a VM is
  created, and this repository has enough of those.

- **The collector going silent is itself alerted on**, because "no guests" is a
  legitimate answer and therefore a dangerous silence. `GuestStateStopped`
  fires for a hypervisor that *was* reporting and stopped — the same shape as
  `PatchStateStopped`, for the same reason.

- **It only reaches hypervisors where the collector is installed**, and that is
  a hand-run at the Mac: VLAN 99 cannot open TCP/22 to VLAN 30. `Saruman` is the
  only hypervisor in the estate today, so this is one command, once — but a
  second one would be silently uncovered until someone ran it, which is what
  `GuestStateStopped` cannot help with because it only knows hosts that have
  reported.
