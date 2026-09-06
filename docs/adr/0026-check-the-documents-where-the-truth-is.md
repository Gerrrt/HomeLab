# ADR-0026: Keep the documents hand-written, and check them where the truth is

**Status:** Accepted · 2026-09

## Context

[#153](https://github.com/Gerrrt/HomeLab/issues/153) asks whether the network
documentation should be discovered rather than hand-maintained, and lists what
hand-maintenance has cost: `oracle` recorded as an i5-1235U with 32 GB when it
is a dual-core A6-9200 with 4 GB — an entry ADR-0008 notes was load-bearing in
planning; `shiva` treated as the hypervisor for several revisions when it is the
iLO; `roadmap.md` saying of itself that it "has already been wrong about the
switch answering SNMP"; two inter-VLAN rules recorded where three existed; alert
and panel counts stale in eight places.

It offers three ways to close: adopt a tool, write a CI cross-check, or accept
hand-maintenance and say why. It also says the thing that made this worth an
ADR: *"leaving it undecided is what produced the list at the top."*

**The middle option was built the same day the issue was filed and never
recorded as the decision.** `scripts/check_docs.py` landed 2026-08-26, following
the pattern `scripts/snmp-targets.sh --check` established on 2026-08-17, and it
now carries seven assertions:

1. counted claims — rules, unit-test coverage, dashboards, panels, agents
2. SNMP targets — `snmp.yaml` against `docs/network.md`
3. host and stack table — `architecture.md` against `network.md` and `stacks/`
4. ports table — `architecture.md` against `compose.yaml`
5. compute table — `hardware.md` against `network.md`
6. version claims — `check_versions.py`, against the running hosts
7. ADR numbering — one ADR per number, H1 agreeing with the filename

So the question is not open in the way it was written. What is worth deciding is
what to do about the part those seven cannot reach.

## Decision

**No discovery tool, and no inventory service.** NetBox is a Postgres-backed
Django application and, as #153 says itself, "a source of truth you maintain,
not a discovery tool" — it moves the hand-maintenance rather than removing it.
Scanopy is closer to the want and worse for this estate: a discovery tool that
can see every VLAN is by construction a device that violates the segmentation
model this repository is built on. Four SNMP devices, seven VLANs and four hosts
is small enough that a Markdown table is the right tool.

**The documents stay hand-written, and every fact that also exists in a
machine-readable form in this repository is cross-checked by CI.** That is what
`check_docs.py` does and it is hereby the recorded decision rather than an
accident of timing.

**Facts that live outside the repository are checked where they live, not in
CI.** This estate already has that shape: `check_loki_coverage.py` asks the live
Loki, `check_alert_channels.py --live` asks the running container,
`check_versions.py` asks Prometheus, `check_mounted_config.py` asks Docker. None
of them can run in CI and none of them pretends to.

## Consequences

- **The residual is prose about the firewall, and it is real.** Two instances
  turned up on 2026-09-06 alone: ADR-0013's claim that default deny "does not
  hold for the switch LAN" went stale four days before anyone noticed
  ([#344](https://github.com/Gerrrt/HomeLab/issues/344)), and the correction for
  it asserted the switch LAN "still reaches every segment outbound", which had
  been false since 2026-09-02
  ([#229](https://github.com/Gerrrt/HomeLab/issues/229)). Both were claims about
  `pfctl` rules. Both passed `check_docs.py`, correctly — it has nothing to
  compare them against.

- **That gap cannot be closed the way the others were, and the reason is
  deliberate.** `scripts/backup-firewall.sh` explains it: `config.xml` carries
  the full rule set, the WAN address and user password hashes, and
  `docs/security.md` states that rule bodies and the WAN address are not
  published. `backups/` is gitignored, `make validate` asserts nothing under it
  is tracked, and CI asserts the same. Putting the ruleset in the repository so
  CI could read it would trade a documentation defect for "one age-key
  compromise hands over the complete blueprint of the network".

- **So the firewall wants a deploy-time check, not a CI one** — something on the
  monitoring host that reads `pfctl -sr` and compares it against the claims in
  `network.md`, `security.md` and the ADRs, failing where the truth is rather
  than where the repository is. That is the same answer this estate reached for
  Loki coverage, alert channels and mounted configs, and it is the only one
  compatible with not publishing the rules. Tracked as
  [#363](https://github.com/Gerrrt/HomeLab/issues/363); it is a check to design,
  not a line to add here.

- **Human review is still the backstop and should be credited as one.** Every
  error in #153's list was caught by a person reading the file, including both
  of 2026-09-06's. A check that catches the mechanical half makes the remaining
  half easier to see, which is the point — not that reading becomes unnecessary.
