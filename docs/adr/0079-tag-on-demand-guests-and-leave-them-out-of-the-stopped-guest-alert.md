# ADR-0079: Tag on-demand guests on the hypervisor, and leave them out of the stopped-guest alert

**Status:** Accepted · 2026-10

## Context

`HypervisorGuestStopped` (`stacks/observability/prometheus/rules/host.rules.yaml`)
warns when a guest on `Saruman` has been off for an hour.
[ADR-0028](0028-let-guest-liveness-cross-but-not-guest-telemetry.md) let that
run state cross to the estate, and in doing so it rejected a table of which
guests are expected to be up. Such a table is a second copy of a fact that
changes whenever a VM is created.

[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
sized the lab domain with two endpoints, `carbuncle` and `siren`, that "start
per session". It saw that they would trip this rule, called that "correct
rather than a defect", and proposed no change, for ADR-0028's reason: the only
alternative it considered was the rejected table. It recorded the cost: "two
warnings a session".

The cost, measured over the week to 2026-10-04, was larger than that:

- **`carbuncle` and `siren` each spent 51 hours firing.** These are not
  per-session warnings. They are a standing pair of alerts that are true and
  say nothing.
- **Over the same week, every other guest that went down came back within
  the rule's hour.** `alexander`, `odin`, `phoenix`, `fenrir`, `titan`,
  `ramuh` and the Packer smoke clones were all only ever *pending*. So the
  firing set was these two endpoints, plus the templates that #885 has since
  removed.

A rule that fires for the same two guests every day teaches whoever reads it to
skip it, and the alert exists to catch the day `alexander` does not come back.

Two mechanisms already exclude guests from this rule without a table. The
hypervisor carries the fact on the guest itself, and
`scripts/collect-guest-state.sh` reads it:

- **The `disposable` tag**
  ([ADR-0071](0071-run-disposable-investigations-on-a-guest-that-is-destroyed.md)).
  It carries a lifecycle rule (`DisposableGuestOutlived`), so it is the wrong
  mark for long-lived endpoints: both would page at a fortnight old.
- **`template: 1`** ([#885](https://github.com/Gerrrt/HomeLab/issues/885)),
  which Proxmox writes itself.

## Decision

**A guest that is meant to be off between sessions carries the Proxmox tag
`on-demand`.** `HypervisorGuestStopped` excludes it, the same way it excludes
disposable guests and templates.

- **The tag is set on the guest**, with `qm set <vmid> --tags '<existing>;on-demand'`,
  where the guest is managed. The quotes matter: the shell would otherwise
  end the command at `;`. `--tags` replaces the whole list, so read the
  current one first with `qm config <vmid> | grep '^tags:'`. Nothing in this
  repository lists which guests
  carry it. That is the line ADR-0028 drew: the fact lives once, on the thing
  it describes.
- **`scripts/collect-guest-state.sh` exports `homelab_guest_on_demand`**, 1 or
  0, beside `homelab_guest_disposable` and `homelab_guest_template`. A guest
  whose config cannot be read loses the series, and `GuestConfigUnreadable`
  says so.
- **The rule adds `unless on (host, vmid) homelab_guest_on_demand == 1`.**
  promtool tests cover a stopped on-demand guest staying quiet, and a guest
  with the series at 0 still firing.
- **`carbuncle` (154) and `siren` (155) are the first two.** They are the
  guests ADR-0029's table already marks "on demand".

## Consequences

- **The estate stops saying anything when an on-demand guest is off.** It
  also stops noticing one that was meant to be on and did not start. That is
  accepted: their sessions are started by hand, by the person who would notice.
- **The tag is a promise that this guest being off is never news.** It is not
  a mute button for a guest that is noisy for some other reason. A guest that
  fails often wants fixing, not tagging.
- **This takes the other side of ADR-0029 on one point and leaves the rest
  standing.** ADR-0029 kept the noise because the alternative it saw was a
  table. A tag on the guest is not that table, so ADR-0028's objection does
  not reach it. ADR-0029 carries a note pointing here. Its text is left as
  written, per ADR-0001.
- **It takes effect in two places.** The rule ships with the observability
  stack. The tag and the collector are on `Saruman`: the collector arrives
  with `make install-agent-collectors AGENT=root@10.0.30.110 ARGS='--only guest-state'`,
  and the tags are two `qm set` commands. Until both are there, the
  rule behaves as before.
