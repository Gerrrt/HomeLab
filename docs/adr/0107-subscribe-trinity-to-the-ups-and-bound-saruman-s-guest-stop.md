# ADR-0107: Subscribe `trinity` to the UPS, and bound `Saruman`'s guest stop

**Status:** Accepted · 2026-11 · decides the `trinity` row
[ADR-0049](0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md)
left open, and amends its low-battery reasoning for the guest set `Saruman`
now carries

## Context

ADR-0049's *Who shuts down* table ends with a row it could not fill:
*"`trinity`, when built — to be recorded when it is placed — to be decided
when it is placed."* It has been placed. The move into the 32U rack on
2026-11-06 and 2026-11-07
([#919](https://github.com/Gerrrt/HomeLab/issues/919),
[`move-into-the-32u-rack.md`](../runbooks/move-into-the-32u-rack.md)) put
`trinity` on PDU outlet 7. The same move put `gandalf` on outlet 8, the
console's brick on 9 and the KVM on 10, and `hardware.md` records it. The PDU
is UPS outlet group 1. So `trinity` is on the pack, and nothing tells it to
stop. A cut that outlasts the pack stops it hard.

`trinity` is the host where that costs most. It holds the household's own
data: Immich's library on a USB disk strapped to its tray, Paperless,
Vaultwarden, Memos and Actual, each with a database. Both disks are LUKS. It
is also AdGuard, the one forwarder behind `morpheus`'s resolver
([ADR-0055](0055-forward-to-adguard-alone.md)).

The second change is on `Saruman`. ADR-0049 was written for a hypervisor
with two guests, and the runbook's step 3.6 read both as `order=any`. Read on
2026-10-09 ([#574](https://github.com/Gerrrt/HomeLab/issues/574)),
it runs thirteen, and four of the six lab-domain guests are ordered
(`order=1..4,up=120`). Proxmox stops ordered guests one stage at a time and
allows each stage its `down` timeout, 180 s by default, before it moves on. The
last real shutdown, on 2026-10-06, stopped ten guests in 2 min 10 s:
32 s for the unordered group, then about 1 min 35 s for the four ordered
stages. That is the typical case. The worst case is a hung guest in every
stage: 180 s for the unordered group plus 4 × 180 s, about **15 minutes**, against
the 8 minutes of low-battery duration the card held when step 0 read it.
`ramuh` has hung after live snapshots before, so this is not hypothetical.

## Decision

**`trinity` becomes a third NUT secondary, on `morpheus`'s Winterfell
address, behind a pass/block pair in the same shape as the other two. The
four ordered guests on `Saruman` get `down=90`. The card's final low-battery
duration is sized from the worst case that remains, not only from the one
measured run.**

### `trinity` subscribes

| Host | Powered by | Acts on the signal | How | Rule it costs |
| --- | --- | --- | --- | --- |
| `trinity` | PDU outlet 7 | **Yes, first** | `nut-client` secondary against `10.0.99.1:3493`; `shutdown -h` stops Docker, which stops every container | A pass from `10.0.99.40` above a block from Winterfell, both to `10.0.99.1:3493`, on `igc0.99` |
| `gandalf` | PDU outlet 8 | No | The range is disposable ([ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)) and off between sessions; nothing on it is the only copy of anything | None |
| The console and the KVM | PDU outlets 9 and 10 | No | No state to lose | None |
| The MokerLink at U14 | UPS outlet group 3 | No | Same as the TP-Link it replaced in ADR-0049's table | None |

Every other row of ADR-0049's table stands.

**It crosses nothing.** `trinity` and `morpheus` are both on Winterfell, so
the subscription reaches the firewall's own address on its own segment, as
`Saruman`'s and `smaug`'s do on theirs. `upsd` gains a third `LISTEN` line,
`10.0.99.1 3493`. It still binds no Hicks address and never the WAN.

**The pair narrows the listener, as ADR-0049's pairs do.** Without it, every
host on Winterfell could reach `10.0.99.1:3493` through the segment's egress
rule: `prometheus`, `oracle`, and the card itself. The pass from `10.0.99.40`
goes above a block from the Winterfell net, and both go above the egress
rule, beside *Block HTTPS to pfSense*. Hicks does not reach `10.0.99.1:3493`
either way: it reaches Winterfell on a named list
([ADR-0031](0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md)),
and 3493 is not on it.

**The same secondary login as the other two.** ADR-0049's argument holds: a
secondary can read status and cannot set `FSD`, so a second login would buy
separate revocation and nothing else. The primary's login stays on the
firewall.

### `Saruman`'s guest stop is bounded

Each of the four ordered guests gets `down=90` in its `startup:` line,
with its `order` and `up` kept as they are. A hung stage then costs 90 s, not
180. The worst case becomes 180 s (the unordered group, left at the default)
plus 4 × 90 s, plus the host's own halt: about **9½ minutes**. That is still
more than 8.

### The low-battery duration covers the worst case

ADR-0049 left the card's threshold to be read, then set from the measured
sequence. A measured run that went well, like 2026-10-06's, is shorter than
what a real cut can produce. So the runbook's §6.5 now sets the final
duration from the **larger** of the measured end-to-end time and the
worst-case bound above, plus half again, rounded up to a whole minute. With
today's numbers that is about 15 minutes. At the 23 % load read on
2026-10-09, the card claims about 44 minutes of runtime, so shutdown would
begin around half an hour into a cut. That still rides out every cut short of
that, which is the property the pack was bought for.

## Consequences

- **A third pass/block pair joins the ruleset**, on `igc0.99`. ADR-0013's
  table gains it. Position is again the failure mode, and the proof is the
  same as ADR-0049's: the block reads blocked from `prometheus`, with 53 open
  as the control.
- **The house loses DNS filtering, and its forwarder, at the start of the
  sequence instead of at the end.** `trinity` halts with the first group, and
  `morpheus`'s resolver forwards to AdGuard alone, so names outside the
  estate stop resolving while `Saruman`'s guests are still stopping. Nothing
  in a halt needs them. The domain guests resolve through their own domain
  controllers, and `morpheus`'s own records are local. Ordering `trinity`
  after `Saruman` would need `upssched` on a secondary, and that is not worth
  it for minutes of a cut that has already lasted half an hour.
- **`trinity` comes up second, after `morpheus`.** That is the order the move
  runbook's §7 already uses. If the TPM does not unseal, the passphrase
  prompt is on KVM port 7.
- **A hung guest is stopped hard after 90 s, not 180.** On a domain
  controller that is a dirty stop, but a bounded one. The alternative is
  the whole hypervisor losing power, which is worse.
- **This is a decision, not a build.** Nothing here is true on the hosts
  until the runbook's step 4b and the 3.6 timeouts are applied and step 5
  proves the order with three secondaries.
