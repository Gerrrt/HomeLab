# ADR-0115: Mark partial supersession with a note, and check the back-links

**Status:** Accepted · 2026-11 · amends [ADR-0001](0001-record-architecture-decisions.md)

## Context

[ADR-0001](0001-record-architecture-decisions.md) says a changed decision gets
a new ADR, "and the old one is marked Superseded rather than edited". It says
nothing about the common case: a later ADR that changes **part** of an earlier
one, which is how most decisions here have moved. An audit on 2026-11-11 found
that case marked two ways
([#1444](https://github.com/Gerrrt/HomeLab/issues/1444)):

- ADR-0002 and ADR-0013 read `Superseded`, though only one claim in each was
  replaced and the rest of each is still the design. A reader who filters on
  status drops two live decisions, and `network.md` still cites ADR-0002 as
  live.
- ADR-0010, 0016, 0017, 0018, 0046 and 0098 stayed `Accepted` with a note
  under the status naming what changed them.

It also found the notes missing where they were needed. Eight later ADRs say
in their status line that they amend, add to, supersede part of or carry out
an earlier one, and that earlier one never mentions them. ADR-0102's
acceptance date had been overwritten by its supersession date, while ADR-0002
and ADR-0013 kept theirs. Nothing checked any of it: `check_docs.py` looked at
numbering and headings only.

## Decision

**Partial supersession leaves the earlier ADR `Accepted`, with a note.** When a
later ADR changes part of an earlier one (supersedes a clause, amends,
narrows, widens, adds to or carries it out), the earlier ADR keeps
`**Status:** Accepted · <date accepted>` and gains a `> [!NOTE]` directly
under its status that names the later ADR and says what it changed. Its body
is never edited. ADR-0002 and ADR-0013 move to this form, and the six above
already follow it.

**Whole supersession is the only `Superseded`.** It reads
`**Status:** Superseded · <date superseded> · by ADR-N · accepted <date accepted>`,
so neither date is lost, plus a note saying the text is left as written.
ADR-0102 is restored to that form, accepted 2026-10.

**The link runs both ways, and a check enforces it.** Whenever an ADR's status
line says it supersedes, amends, adds to, widens, narrows, replaces, reverses,
revises, overrides or carries out ADR-N, then ADR-N must mention it.
`scripts/check_docs.py` fails otherwise, inside its existing ADR check. A
status line that only names an earlier ADR as precedent ("as ADR-0070 did") or
for context ("adds a service to the tier ADR-0008 created") is not a change to
it, and is not held to this.

This amends ADR-0001's sentence on supersession. The rest of ADR-0001, an
immutable body and a new ADR for a changed decision, is unchanged.

## Consequences

- A reader who opens an ADR learns from its first lines whether a later one
  changed it, and which, without searching the directory.
- Filtering ADRs by `Accepted` returns every decision that is still at least
  partly in force. `Superseded` means wholly replaced.
- Adding a NOTE to an accepted ADR is not editing its decision: the note sits
  outside the body, and says only that a later ADR exists. This is the one
  change to an accepted ADR that ADR-0001's immutability allows.
- The check covers what a status line declares. A relation stated only in an
  ADR's body is not detected. The audit found three (ADR-0025 by 0031, 0012 by
  0067 and 0086, 0003 by 0016), and they got their notes by hand.
