# ADR-0001: Record architecture decisions

**Status:** Accepted · 2025-11

## Context

This lab has been rebuilt several times. Each rebuild re-litigated decisions
that had already been made and forgotten — why the IoT VLAN is terminal, why
Loki instead of an ELK stack, why one compose file instead of five. The
reasoning lived in memory, so it evaporated.

The configs record *what* is deployed. Nothing recorded *why*, or what was
rejected and for what reason. Six months later that distinction is the whole
difference between maintaining a system and re-deriving it.

## Decision

Record every architecturally significant decision as a short Markdown file in
`docs/adr/`, numbered sequentially, in the format popularised by Michael Nygard:
context, decision, consequences.

A decision is "architecturally significant" if reversing it would mean changing
more than one file, or if a reasonable person would ask "why is it done that
way?"

ADRs are immutable once accepted. A decision that changes gets a new ADR that
supersedes the old one, and the old one is marked Superseded rather than edited.
The history of what was believed and when is the point.

## Consequences

- Every non-obvious choice has a written justification, so a reader — including
  a future me — can evaluate it rather than guess at it.
- Reversing a decision requires articulating why, which raises the bar slightly
  and usefully.
- There is a small ongoing cost: a new ADR per significant change. Skipping it
  is easy and self-punishing.
