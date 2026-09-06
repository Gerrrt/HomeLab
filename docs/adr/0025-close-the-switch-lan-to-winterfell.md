# ADR-0025: Default deny holds everywhere except Hicks

**Status:** Accepted · 2026-09 · supersedes
[ADR-0013](0013-segment-access-as-implemented.md)

## Context

[ADR-0013](0013-segment-access-as-implemented.md) is titled *"Default deny holds
everywhere except Hicks and the switch LAN"*, and says:

> **It does not hold for the switch LAN (`10.7.7.0/24`) either.** That interface
> carries pfSense's stock *Default allow LAN to any* rule and no blocks, so the
> switch's management address can reach every segment.

The second half of that title stopped being true on 2026-09-06.
`Gerrrt/Lemmiwinks#177` added a rule on the Winterfell interface:

```text
block drop in log quick on igc0.99 inet
  from <OPT1__NETWORK> to <LAN__NETWORK>
  descr="Block access to the untagged LAN"
```

placed directly above the interface's catch-all `pass` and below the SNMP
passes. Read off the firewall on 2026-09-06, it is rule 174 of the running set
and the catch-all is 175.

Winterfell no longer reaches `10.7.7.0/24` except through the passes that sit
above the block. That is default deny, with an exception — which is what every
other segment already had, and is exactly what ADR-0013 said this segment
lacked.

This ADR exists rather than a note on ADR-0013 because the change is the
decision and not a detail. ADR-0013 already carries a note for a row added
later, which is the right treatment for a table gaining an entry; a title that
has become false is not that. [ADR-0001](0001-record-architecture-decisions.md)
is explicit: *"ADRs are immutable once accepted. A decision that changes gets a
new ADR that supersedes the old one."*

## Decision

**Default deny holds on every segment except Hicks.**

The switch LAN is no longer an exception. Winterfell's access to `10.7.7.0/24`
is now the same shape as its access to anything else: blocked, with named passes
above the block for the traffic that has a reason.

The explicit cross-segment passes in force on 2026-09-06, read from `pfctl -sr`
rather than from the web UI:

| On interface | Rule | Purpose |
| --- | --- | --- |
| 99 | `10.0.99.20 → 10.0.30.10:161-162/udp` | SNMP-Exporter scrapes the iLO |
| 99 | `10.0.99.20 → 10.7.7.2:161-162/udp` | SNMP-Exporter scrapes the switch |
| 99 | *block* `10.0.99.0/24 → 10.7.7.0/24` | **new** — the rule this ADR is about |
| 30 | `10.0.30.10 → 10.0.99.20/udp` | the iLO's return path |
| LAN | `10.7.7.2 → 10.0.99.20:161-162/udp` | the switch's return path |
| 50 | `vlan50 → 10.0.99.1:22/tcp` | SSH to the firewall itself |
| 50 | `10.0.50.1 → 10.7.7.0/24:80/tcp` | the firewall to the switch's web UI |

Hicks is unchanged and is still the one exception: its catch-all is reached, so
`50 → 30` and `50 → 99` remain wholesale paths that no rule grants and no rule
denies. Whether that should stay is [#228](https://github.com/Gerrrt/HomeLab/issues/228),
and it is deliberately not decided here.

## Consequences

- `network.md`'s claim that the switch LAN reaches "Nothing" is true for the
  first time. ADR-0013 recorded it as false; it is now a description rather
  than an aspiration.
- **The switch's cleartext management plane is closed to the management
  segment.** [ADR-0018](0018-name-the-switch-and-leave-its-ui-on-plain-http.md)
  accepted plain HTTP on the switch UI because the segment was small and
  trusted; the surface for that trade is now smaller again, since 10.0.99.0/24
  can no longer reach it at all.
- **One monitoring capability was lost and deliberately not restored.** The
  `switch-ui` blackbox probes went with it, removed in
  [#343](https://github.com/Gerrrt/HomeLab/pull/343) rather than kept alive by a
  hole punched for them. `targets/blackbox.yaml` records why in place of the
  targets.
- **A pass rule outlived its consumer.** `10.0.99.20 → 10.7.7.2:80/tcp`, added
  to keep those probes working while the block landed, is still on the firewall
  and now grants access nothing uses — verified on 2026-09-06: no probe targets
  `10.7.7.2` and `targets/blackbox.yaml` names it zero times. Removing it is a
  firewall change and belongs on the Lemmiwinks side; until it is gone, the
  block above is one exception wider than this ADR describes.
- SNMP remains the single functional exception, and it is the one thing that
  must keep working: `up{job="snmp"}` for `neo` is how the switch is monitored
  at all.
