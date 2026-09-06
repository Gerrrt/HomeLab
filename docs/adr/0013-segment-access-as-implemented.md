# ADR-0013: Default deny holds everywhere except Hicks and the switch LAN

**Status:** Superseded · 2026-09 · by
[ADR-0025](0025-close-the-switch-lan-to-winterfell.md) · supersedes
[ADR-0002](0002-vlan-segmentation-strategy.md)

> [!NOTE]
> Superseded only in its claim about the switch LAN. *"It does not hold for the
> switch LAN"*, below, stopped being true on 2026-09-06, when
> `Gerrrt/Lemmiwinks#177` added a logged block from Winterfell to
> `10.7.7.0/24`. Default deny now holds there too, with SNMP as the named
> exception, and the title above is wrong by half.
> [ADR-0025](0025-close-the-switch-lan-to-winterfell.md) records what is
> actually enforced. Everything else here — the Hicks catch-all, the rule that
> matches nothing, the reasoning about which interface a rule is evaluated on —
> is unchanged and still correct. The text is left as written, per ADR-0001.
>
> The table of explicit cross-segment passes below gained one row after this
> was written: `30 | 10.0.30.110 → 10.0.99.20:9090,3100/tcp | Saruman's Alloy
> agent`, added for [#88](https://github.com/Gerrrt/HomeLab/issues/88) and
> recorded in `network.md`. The text here is left as written, per ADR-0001.

## Context

[ADR-0002](0002-vlan-segmentation-strategy.md) says:

> Exactly two inter-VLAN rules exist: trusted → management (administration), and
> trusted → lab (usability). Everything else is egress-only.

That was accurate in 2025-06. Since then four documents have disagreed about the
number, each in good faith:

| Source | Claim |
| --- | --- |
| ADR-0002 | exactly two |
| `README.md` | three, "each directional and documented" |
| `security.md` | "Default deny between every segment. Three exceptions" |
| ADR-0008 | "the rule count rises from three to five" |
| ADR-0010 | "the rule count stays at the five ADR-0008 established" |

ADR-0008's two are not a contradiction — they are tracked as
decided-but-not-built in [#102](https://github.com/Gerrrt/HomeLab/issues/102),
and the firewall is correctly in the pre-0008 state. The rest is drift.

[#104](https://github.com/Gerrrt/HomeLab/issues/104) asked for a superseding ADR
recording "the current count and the full list". Producing it meant reading the
enforced ruleset rather than recounting the prose, and **counting rules turned
out to be the wrong instrument**. What a segment can reach is decided by the
ordered interaction of its block rules, its catch-all, and which interface a
rule sits on. Two segments reach more than any count of "inter-VLAN rules"
suggests, and one explicit rule reaches nothing at all.

Method: `pfctl -sr` on `morpheus` with the interface tables resolved, cross-read
against `config.xml`. No floating rules exist, so per-interface first-match
(`quick`) evaluation is the whole story. Verified from `10.0.99.20`:
`10.0.50.1`, `10.0.30.1`, `10.0.20.1` and `10.0.10.1` are all unreachable, while
the two SNMP exceptions poll healthily.

## Decision

Record segment access as implemented, in the form that decides it — reachability
per source segment, not a rule count.

**Default deny holds, with narrow exceptions, for Winterfell (99),
ImaginationLAN (30), CasaBonita (40), Skids (20) and Degens (10).** Each blocks
every other segment explicitly before its egress rule.

**It does not hold for Hicks (50).** Hicks blocks CasaBonita, Skids and Degens,
and then passes to `any`. There is no block for ImaginationLAN or Winterfell, so
**Hicks reaches all of both, on every protocol and port** — not the narrow
management path ADR-0002 and `security.md` describe. `network.md` has recorded
this correctly all along ("Internet, 99, 30"); it is the ADR and `security.md`
that describe a rule set narrower than the one deployed.

**It does not hold for the switch LAN (`10.7.7.0/24`) either.** That interface
carries pfSense's stock *Default allow LAN to any* rule and no blocks, so the
switch's management address can reach every segment. `network.md` says this
segment reaches "Nothing".

The explicit cross-segment passes that are actually in force:

| On interface | Rule | Purpose |
| --- | --- | --- |
| 99 | `10.0.99.20 → 10.0.30.10:161-162/udp` | SNMP-Exporter scrapes the iLO — **this is the third rule #104 was about** |
| 99 | `10.0.99.20 → 10.7.7.2:161-162/udp` | SNMP-Exporter scrapes the switch |
| 30 | `10.0.30.10 → 10.0.99.20/udp` | the iLO's return path |
| LAN | `10.7.7.2 → 10.0.99.20:161-162/udp` | the switch's return path |
| 50 | `vlan50 → 10.0.99.1:22/tcp` | SSH to the firewall itself |
| 50 | `10.0.50.1 → 10.7.7.0/24:80/tcp` | the firewall to the switch's web UI |

Plus two implicit paths — `50 → 30` and `50 → 99`, wholesale — which no rule
grants and no rule denies; they exist because Hicks's catch-all is reached.

**One explicit rule matches nothing.** *Allow Hicks access to ImaginationLAN*
(`vlan50 → vlan30`) sits on the **ImaginationLAN** interface. pfSense evaluates
a rule on the interface a packet *enters*, and Hicks traffic enters on the Hicks
interface, so that rule can never match. The access it describes is real, but it
comes from the catch-all above, not from this rule. It is left in place rather
than removed as part of this ADR: deleting it changes nothing, and doing it
blind — while writing the document that explains why it does nothing — is how
the next surprise gets built.

The third rule was added with the monitoring stack, in the same change that made
`shiva`'s iLO a scrape target. It was not recorded because it was understood as
wiring up a monitoring target rather than as a change to the segmentation design
— which is exactly the shape of omission ADR-0001 exists to catch, and it went
unnoticed for as long as it did because every document that could have
contradicted it was itself a count rather than a list.

ADR-0002 is marked **Superseded**. Its reasoning — segment by trust, not by
function — is unchanged and still correct; only its claim about the rule set is
retired.

## Consequences

- **A compromised Hicks workstation reaches all of Winterfell and all of
  ImaginationLAN.** `security.md` already accepts a narrower version of this —
  that such a workstation reaching `10.0.99.20` can write to the metric and log
  stores without a credential, per ADR-0012 — but the real exposure is the whole
  segment, not one host. This ADR does not decide whether to narrow it. Doing so
  means enumerating what Hicks legitimately needs and would break management
  access and the lab if got wrong, so it is a decision of its own.
- **A compromised switch reaches every segment.** Bounded by that segment
  holding one device, but that device still answers its previous SNMP community
  ([#84](https://github.com/Gerrrt/HomeLab/issues/84)).
- **Counts in prose are replaced by lists.** A count cannot be checked against
  a firewall and cannot express "reachable via a catch-all"; four documents
  holding four numbers is what that costs. `README.md` and `security.md` now
  point here rather than restating a total.
- **The terminal segments are the part that held.** VLANs 10, 20 and 40 block
  every internal destination explicitly, and since
  [#223](https://github.com/Gerrrt/HomeLab/issues/223) each carries a tripwire
  that logs anything which gets past those blocks. The design worked where it
  was written down.
- ADR-0008's two rules stay tracked in
  [#102](https://github.com/Gerrrt/HomeLab/issues/102). When they land they
  belong in this list, not in a new number.
