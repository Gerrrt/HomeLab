# ADR-0126: Monitor `gandalf` now that it stays on

**Status:** Accepted · 2026-11 · supersedes the *No monitoring* clause of
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)

## Context

[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) gave the
range host no monitoring, and its reason was the host's schedule: "off by
design between sessions", so every rule watching it "would be permanently
firing or permanently silenced". [ADR-0125](0125-keep-gandalf-on-and-stop-ragnarok-on-a-timer.md)
ended that schedule. `gandalf` now stays on, and the attack VM `ragnarok` is
what stops on a timer. A host that is up by design has a normal state, and a
rule about it has a shape.

Three facts make the gap concrete:

- **Nothing checks the host firewall.** It is the one barrier between a rooted
  range target and the host (the 2026-11-22 audit, `vmbr1_host_in`). The only
  check is [`build-the-playground.md`](../runbooks/build-the-playground.md)
  §7's per-session read-back, which runs when a person starts a session. On an
  always-on host that is a window of days. `Saruman`'s firewall has an alert
  for exactly this (`PveFirewallDisabled`, `PveFirewallPolicyAccept`,
  `PveFirewallStateStale`, from the `pve-firewall-state` collector, #566/#576);
  `gandalf` has none.
- **The timer is the only thing stopping `ragnarok`, and nothing watches the
  timer.** §7's read-back checks it is enabled, once a session. If the timer is
  disabled or broken, the attack VM runs on VLAN 30 unbounded until someone
  looks — the fault ADR-0125 set out to end, returned one level up.
- **The slow faults have no eye on them.** The range SSD is aged (49,443
  power-on hours, 8 reallocated sectors on 2026-11-22) and now runs every hour.
  Proxmox's own updates are applied by hand. Both were audit findings that only
  a person re-reading SMART or `apt` will catch.

What this is not is a reversal of [ADR-0007](0007-defensive-estate-and-offensive-range.md)
or [ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md).
[ADR-0028](0028-let-guest-liveness-cross-but-not-guest-telemetry.md) already
drew the line this decision sits on: a hypervisor's own state — its firewall,
its uptime, which guests exist and whether they run — is **hypervisor state,
not guest telemetry**, and it may cross. `Saruman`, also on VLAN 30, already
pushes exactly this to `prometheus` at `10.0.99.20`, and
[ADR-0070](0070-let-guest-disk-capacity-cross-read-through-the-hypervisor.md)
and [ADR-0088](0088-let-a-named-lab-services-health-cross-read-through-the-guest-agent.md)
widened the same seam without opening a path into the lab. What stopped
`gandalf` from joining them was ADR-0017's schedule and the worry that an agent
on the attacker-adjacent isolation host is attack surface. The first is gone.
The second is smaller than it was: after the 2026-11-22 audit the host drops
everything the range bridge sends it, takes SSH by key only with no forwarding,
and carries no workstation tooling.

## Decision

**`gandalf` gets the same agent `Saruman` has, reporting hypervisor state to
`prometheus`, and the range gains alerts for the faults a person used to catch
by hand.** ADR-0017's *No monitoring* clause is superseded; the rest of
ADR-0017 stands.

- **The agent is the estate's Alloy agent and `node_exporter`, with a
  host-only subset of the collectors**, installed by
  `scripts/install-agent-collectors.sh` with `--only` naming exactly:
  `pve-firewall-state` (firewall status, rule counts and policy),
  `guest-state` (which guests exist and whether they run — read from `qm list`
  on the host, the ADR-0028 class), `smart-state` (the range SSD),
  `patch-state` and `pve-version` (Proxmox updates and version). It does **not**
  take the installer's full default set: `guest-disk-state` and
  `guest-service-state` reach *inside* a guest through its agent
  (`qm guest cmd … get-fsinfo`), which on the range would read a target's
  filesystem — guest telemetry from the attacker's segment, which this decision
  does not allow. `guest-state` is the line ADR-0028 draws: run-state crosses,
  contents do not. Nothing is read from inside a target.
- **It pushes metrics only, outbound to `10.0.99.20:9090`**, over one
  host-scoped pass on `morpheus` beside the two that already carry
  ImaginationLAN there
  ([ADR-0031](0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md)).
  That pass is the one boundary crossing this decision authorizes, and ADR-0014
  counts it: `10.0.30.30 → 10.0.99.20` on `9090`, metrics, and nothing toward
  the range. **Not the standard Alloy config**: that ships journal and file
  logs to `10.0.99.20:3100` as well, and `deploy-agent.sh` checks both arrived.
  A range host's logs can carry what happens on the attacker's segment, so
  `#1651` writes a metrics-only Alloy config — no `loki.*` push, no `3100` —
  and a deploy check that requires metrics alone. No listener is opened on
  `gandalf`, no path is opened *into* the segment, and the attack VM gains no
  reach it did not have.
- **The alerts are three faults, not four.**
  - **The host firewall is off or open.** Three existing `pve-firewall-state`
    alerts (`host.rules.yaml`) begin evaluating `instance="gandalf"` the day
    the collector reports: `PveFirewallDisabled`, `PveFirewallPolicyAccept` and
    `PveFirewallStateStale`. They do **not** yet catch an enabled firewall with
    empty rule files under a `DROP` policy — the collector exports the count
    (`homelab_pve_firewall_rules`) but no rule reads it — so `#1651` adds that
    alert. Together these cover the *host firewall* half of §7's read-back.
    The §2 controls §7 also reads — the `vmbr1_host_in` ingress table and
    `ip-forward off` — are a separate nftables table that this collector does
    not see, so `#1651` extends the host collector to export their state and
    adds the matching alerts; until it does, those stay in §7's manual
    read-back. This is the main gap.
  - **The timer stopped working.** ADR-0125 lets a session re-extend
    `ragnarok` repeatedly, up to twelve hours *from now* each time, so there is
    no fixed runtime cap to compare against — an alert on "ran past twelve
    hours" would page on a legitimately extended session. The fault is the
    timer failing, so the alert watches the timer, not the clock: `ragnarok`
    running while `homelab-ragnarok-stop.timer` is not `active`, or running
    past the *effective deadline* the timer itself wrote under
    `/run/homelab-ragnarok-stop` (which already folds in every extension and
    `dpkg` deferral) by a margin. `#1651` exports that deadline and the timer's
    state. `DisposableGuestOutlived` (#438) already covers the other end — a
    disposable guest that *exists* too long, running or stopped — for any guest
    tagged `disposable` on `gandalf` once the collector is there, at no extra
    cost.
  - **The slow faults.** The range SSD's reallocated-sector count rising
    (the [ADR-0047](0047-collect-smaug-smart-through-a-root-cron-and-the-textfile-collector.md)
    SMART pattern) and Proxmox updates waiting. Warnings, because the answer is
    maintenance, not a page.
- **Not "the host is up too long".** ADR-0125 made `gandalf` on by design, so
  host uptime has no fault shape — an uptime alert would be the permanently
  firing rule ADR-0017 warned of. The thing with a bound is the attack VM, and
  that is the `ragnarok` alert above. The host is watched for *what it is
  doing* — its firewall — not for *being on*.

The script, the rules and the `morpheus` pass are built under
[#1651](https://github.com/Gerrrt/HomeLab/issues/1651).

## Consequences

- **The firewall is watched while the box is on.** The window ADR-0125 left —
  "nothing still watches the host firewall while the box is on" — closes. A
  firewall turned off by an upgrade or a debugging session is a page, not a
  thing the next session's read-back might catch days later.
- **A broken timer is caught.** ADR-0125's read-back checks the timer is
  enabled at power-on; this catches it going wrong between sessions, by
  watching its effect — `ragnarok` still running — rather than its config.
- **The range host now runs a standing agent and pushes to the estate.** That
  is attack surface and a path the attacker's segment did not have, and it is
  the cost ADR-0017 declined to pay. It is paid now because the schedule that
  made it avoidable is gone and the host is hardened. The pass is outbound and
  host-scoped, metrics only; it is not a way into the range, which is what
  ADR-0014 protects.
- **ADR-0017's "not backed up" is untouched.** This decision reverses only *No
  monitoring*. A deliberately-vulnerable image in the estate's backup store is
  still a path the range does not get (ADR-0017), and nothing here adds PBS.
- **The estate's rules now span the range host.** `DisposableGuestOutlived`,
  the firewall alerts and the SMART rules begin evaluating `instance="gandalf"`
  the day the agent reports. A rule that assumed only `Saruman` on VLAN 30 is
  worth re-reading against a second hypervisor on the segment.
- **This is reopened** if the range host stops being hardened enough to carry
  an agent — if a rooted target can reach it again — in which case the agent is
  surface that should come back off, and the firewall read-back is the
  fallback it was before.

## Alternatives considered

- **A minimal collector, firewall-state only, no `node_exporter`.** Less
  surface on the isolation host, and it covers the main gap. Rejected as the
  standing choice because the uptime, guest-run-state and SMART facts are the
  same ADR-0028 class, cost nothing more once the agent is there, and let the
  estate's existing rules (`DisposableGuestOutlived`, the SMART pattern) cover
  `gandalf` without a second, bespoke shape. The smaller footprint is not worth
  a second kind of agent to maintain.
- **External and passive only — infer `gandalf` from `morpheus`.** `morpheus`
  already sees the segment (the `RangeSubnetLeaked` tripwire), and uptime or
  presence could be read there without touching the host. Rejected because the
  fault that matters most — the host firewall off — cannot be read from off the
  host; only `pve-firewall status` on the box tells `enabled` from `disabled`,
  and that is the whole point of the `pve-firewall-state` collector.
- **Keep the read-back, add nothing.** Rejected: it is what ADR-0125 left, and
  it checks the firewall only when a person starts a session, which on an
  always-on host is a gap of days. The read-back stays as the power-on check;
  it is no longer the only one.
