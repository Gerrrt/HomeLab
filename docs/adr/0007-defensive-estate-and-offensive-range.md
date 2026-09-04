# ADR-0007: Split the security lab into a defensive estate and an offensive range

**Status:** Accepted · 2026-08

> [!NOTE]
> The isolation mechanism this ADR defers in its Consequences — where `ifrit`
> goes, and whether the lab's egress is filtered — is settled by
> [ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md).
> The text here is left as written, per ADR-0001.
>
> "Lab telemetry stays in the lab" (Decision, below) is amended by
> [#88](https://github.com/Gerrrt/HomeLab/issues/88), 2026-09: the
> hypervisor's *own* host agent on `Saruman` remote-writes to `10.0.99.20`
> over one unlogged pass, `10.0.30.110 → 10.0.99.20:9090,3100/tcp`, placed
> above the ADR-0014 tripwire. A DL360 with a mirrored pair of ageing disks
> is estate hardware whose health belongs with the rest of the estate's;
> what this ADR was protecting against is guest telemetry, and guests still
> get no such rule. `stacks/lab/` and its own stack are unchanged
> ([#101](https://github.com/Gerrrt/HomeLab/issues/101)). The text here is
> left as written, per ADR-0001.
>
> The two things the `stacks/lab/` sentence in the Decision leaves open — where
> a compose stack runs on a hypervisor that must not run Docker, and where
> `config.alloy`'s second `*_URL` points when no Prometheus is named — are
> settled by
> [ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md),
> 2026-09: the stack runs in a guest on `Saruman`, single-homed on VLAN 30, and
> carries its own Prometheus alongside Loki, Grafana and Alloy. Nothing here is
> amended — "lab telemetry stays in the lab" is what makes both answers follow.
> The text here is left as written, per ADR-0001.

## Context

This repository began as a place to practise security work. **ImaginationLAN
(30)** exists for that: it is the segment where things get broken on purpose.
[`roadmap.md`](../roadmap.md) has long carried an entry to procure a second
server, `ifrit`, for a deliberately-vulnerable playground.

`Saruman` — the ProLiant on VLAN 30 — has 48 threads and 128 GB and, at the time
of writing, runs no guests at all. So the question is not whether there is
capacity. It is what the lab is *for*, and how the pieces divide.

Three options:

1. **One box does everything.** Attack tooling and target estate share a
   hypervisor. Cheapest, and it needs no second machine. But the attacker and
   the victim then share a fault domain: a mis-scoped scan or a guest escape
   reaches the thing you were trying to observe, and you can never fully
   separate "my detection fired" from "my own tooling made that noise."
2. **`Saruman` as a general lab, `ifrit` as the vulnerable playground.** The
   roadmap's implicit plan. Better, but it leaves `Saruman` without a defined
   purpose — a hypervisor is not a role.
3. **`Saruman` as the defended estate, `ifrit` as the offensive range.** Each
   machine has one job, and the boundary between them is the thing being
   exercised.

There is a second, harder question underneath: whether lab telemetry should
reach the production log stack on VLAN 99. It would be convenient — Loki, the
dashboards and 40 alert rules already exist there. But
[`security.md`](../security.md) names "a lab VM escaping into the house" as a
threat this design defends against, and the control is that VLAN 30 is reachable
only *from* trusted, never *to* it. A remote-write path from the lab into
management inverts exactly that.

## Decision

**`Saruman` defends. `ifrit` attacks.**

- `Saruman` hosts the estate you practise defending: a small Windows domain,
  realistic endpoints, Wazuh, Velociraptor, and Proxmox Backup Server. It stays
  single-homed on VLAN 30 — no trunk, no VLAN-aware bridge.
- `ifrit` holds C2 and attack tooling, and the vulnerable targets. It is sized
  for on-demand use and powered off between sessions.
- **Lab telemetry stays in the lab.** `Saruman` runs its own Loki, Grafana and
  Alloy under `stacks/lab/`, reusing `alloy/config.alloy` unchanged — the two
  `*_URL` variables are the only difference. It does not remote-write to
  `10.0.99.20`. The lab's Grafana is reached from Hicks, which the existing
  50→30 rule already permits.
- Network detection scoped to the lab segment belongs on `Saruman`. Detection
  for the *house* does not, and lives on the firewall per
  [ADR-0006](0006-detect-at-the-chokepoint.md).

The vulnerable playground is deliberately the least important part. Popping a
box built to be popped teaches very little; detecting a real technique against a
realistic estate teaches a great deal.

## Consequences

- Attacker and target are separately owned, so "did the detection fire?" has a
  clean answer instead of a confounded one.
- The production log store never ingests potentially-hostile lab telemetry, and
  no inter-VLAN rule is needed to make the lab observable.
- **The lab runs a second observability stack.** That is duplicated
  infrastructure and duplicated upkeep, and it is the price of the isolation
  above. Mitigated by the stack being identical in form to the one that already
  exists — same agent config, same patterns, per ADR-0004.
- **It requires a second machine that does not yet exist.** Until `ifrit` is
  procured, the estate has nothing attacking it, so the loop this design exists
  to close stays open.
- `ifrit`'s isolation mechanism is **not settled here**. Whether it gets a
  dedicated VLAN or a physically separate network is deferred deliberately —
  adding a segment is a decision this project has declined once already, and it
  should be made on its own merits rather than assumed.
- The constraint on `Saruman` is storage, not compute: 128 GB and 48 threads
  against a single mirrored pair of 7.2K disks. The fleet is sized against
  spindles, not RAM.
- A DL360 Gen9 is loud and lives in an occupied office. Running the estate
  continuously has a comfort cost that a quieter box would not impose — which is
  a genuine argument for keeping house services off this machine entirely, and
  is part of why [ADR-0008](0008-place-services-by-data-trust.md) puts them
  elsewhere.
