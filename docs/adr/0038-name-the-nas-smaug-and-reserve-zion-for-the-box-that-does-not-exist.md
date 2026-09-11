# ADR-0038: Name the NAS `smaug`, and reserve `zion` for the box that does not exist

**Status:** Accepted · 2026-09 · amends the naming clause of
[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md)

## Context

[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md) named
the NAS `zion` and gave it `10.0.40.30` on CasaBonita. **Nothing was ever built
with that name.** The TS150 was bought 2026-09-09 and is in transit, so `zion`
has only ever existed in seventeen lines of documentation and two issue titles.

The operator's own naming was different, and nobody found out until 2026-09-11:
`zion` was the services host, and `trinity` was the firewall's cold spare. Read
against this repository — where `trinity` is the one ProDesk and `zion` is the
NAS — that produced a conclusion neither document supports:

> "I had no idea the cold spare firewall and the services host were going to be
> two separate boxes, when I was tracking they would be one box that handled
> both. I'm not getting two boxes, and one box is already on the way."

**The substance was never in dispute.**
[ADR-0034](0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)
is titled *"Run the sensitive tier on the ProDesk, **and make it the spare
hardware**"*, and decides one box for both jobs. A second ProDesk has never
been on the buy list; it is on the deferred list, behind a reopen condition
that has not fired, and [#404](https://github.com/Gerrrt/HomeLab/issues/404)
says *"**Not** a second ProDesk, unless…"*. One box, two jobs, exactly as the
operator believed.

So the disagreement was **entirely nominal** — two names for one machine, and a
third name on a machine the operator called something else. That is worth an
ADR rather than a quiet find-and-replace, because a name attached to the wrong
machine is a documented cost of hand-maintenance here:
[ADR-0026](0026-check-the-documents-where-the-truth-is.md) lists `shiva`
"treated as the hypervisor for several revisions when it is the iLO" alongside
`oracle`'s wrong CPU, and this is the same failure caught earlier.

**Earlier is the whole argument for doing it now.** Neither box is racked.
Renaming a host that exists means its Kea reservation, its firewall rules, its
scrape target, its Alloy config and its age recipient; renaming one that is in
a cardboard box means a document sweep.

## Decision

**1. The NAS is `smaug`**, at `10.0.40.30` on CasaBonita
([ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md),
[#413](https://github.com/Gerrrt/HomeLab/issues/413)). The address, the three
inbound rules, the metrics-and-no-logs decision and the terminal-outward
direction are all untouched. **Only the label moves.**

**2. `trinity` keeps the ProDesk**, and keeps both jobs — ADR-0008's sensitive
tier at `10.0.99.40`, and the firewall's spare hardware in a disaster per
ADR-0034. It carries 123 references, including `.sops.yaml`,
[`stacks/sensitive/compose.yaml`](../../stacks/sensitive/compose.yaml),
[`scripts/tier-ca.sh`](../../scripts/tier-ca.sh),
[`scripts/backup-volumes.sh`](../../scripts/backup-volumes.sh) and
[`scripts/gen-certs.sh`](../../scripts/gen-certs.sh). Renaming it would reach
into the secrets tooling and the age recipients to buy nothing operational.

**3. `zion` is reserved, not retired.** It names the **dedicated firewall cold
spare, if ADR-0034's reopen condition ever fires** — "until the tier holding
real data makes an hour of firewall downtime unacceptable". That is the only
future in which a second box exists, and it is precisely the box the operator
meant by the name. Until then **no host answers to `zion`**, and a `zion` found
in a document from now on is a bug rather than a machine.

**4. The ADRs are not edited.** [ADR-0001](0001-record-architecture-decisions.md)
says a record is superseded rather than rewritten, and no ADR here has ever been
retroactively renamed. ADR-0016, ADR-0027, ADR-0029 and ADR-0030 keep their text
and gain a note pointing here, in the shape
[ADR-0007](0007-defensive-estate-and-offensive-range.md) already uses.

### The naming scheme ADR-0016 appealed to does not exist

ADR-0016 justified `zion` as *"the Matrix naming the infrastructure hosts
already use"*. That overstated a rule the estate does not follow. `morpheus`,
`trinity`, `neo`, `oracle` and `prometheus` are Matrix; `Saruman` is Tolkien;
`mjolnir` and `odin` are Norse; `shiva` is Hindu; `ifrit` is neither. `smaug`
sits beside `Saruman` without anything having to change, because there was no
rule to break — a dragon on a hoard is a reasonable thing to call the box that
holds everything.

## Consequences

- **Seventeen references swept** across `hardware.md`, `network.md`,
  `roadmap.md` and [`build-the-soc-guest.md`](../runbooks/build-the-soc-guest.md).
  The ADRs keep their text and carry notes.
- **Two issue titles change** — [#413](https://github.com/Gerrrt/HomeLab/issues/413)
  and [#446](https://github.com/Gerrrt/HomeLab/issues/446) name `zion` in the
  title. Their bodies still do, and are left as filed; the titles are what a
  list view shows.
- **The one-box fact gets said where it was missable.** The machine is "the
  tier's host" in ADR-0034, #404 and the roadmap, and "the spare" in
  [`restore-the-firewall.md`](../runbooks/restore-the-firewall.md) — different
  words, adjacent pages, one machine. Someone tracking both phrases counts two
  boxes, which is what happened. The deferred-purchase bullet and `trinity`'s
  hardware entry now say one box in as many words.
- **`smaug` collides with nothing.** It appears nowhere in the repository or in
  any issue before this ADR, so no rename is half-done.
- **`.sops.yaml` is untouched**, and deliberately: the age recipients are the
  operator's to change, and nothing here needs them changed.
- **This ADR is the reason a buy list exists.** The section it feeds says
  purchases "kept appearing one at a time … and the person paying for them
  found out about each by surprise". The list did carry the box, and
  `hardware.md` did carry both its jobs — and it was still possible to read two
  machines out of them. A complete list is necessary and was not sufficient;
  what was missing is that **one machine had two descriptions and no single
  sentence saying so**.
- **Reopened by:** ADR-0034's reopen condition firing. That is the event which
  gives `zion` a machine, and the ADR that buys the second ProDesk is where the
  name is spent.
