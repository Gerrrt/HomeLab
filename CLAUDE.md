# CLAUDE.md

Working rules for an AI session in this repository. The README is the tour;
this is what a session gets wrong without being told.

## Before you push

- Run `make validate`, the local validation suite. It is not all of CI: CI
  also runs the hardened boots, the secret scan and the close-keyword check,
  and runs lint with `--require-all`, where a local run counts an unavailable
  tool as a skip. A skipped check has not passed, so say which were skipped.
  When the change is docs only, run `python3 scripts/check_docs.py` and
  `./scripts/lint.sh` at least.
- Start from a fresh `main`. Docs here move daily, and a branch cut from a
  stale checkout fixes lines that are already fixed.
- Fill in `.github/pull_request_template.md`'s four sections in every PR body.

## Close keywords

GitHub closes an issue for a close keyword anywhere in a PR body or a commit
that lands on `main`. An intended close is its own sentence that starts with
the keyword: `Closes #N.` Work that is not finished is `Refs #N`. Never put
close, fix or resolve in front of an issue number in prose.
`scripts/check_close_keywords.py` enforces this and lists the phrases that
went wrong.

## Records and current-state documents

Two kinds of document, edited differently:

- **Records** are never rewritten. `docs/changelog.md` is dated and newest
  first, and a correction is a new entry that names the one it corrects. An
  accepted ADR in `docs/adr/` is immutable: a changed decision is a new ADR
  that supersedes it. An old ADR that says something has not happened yet
  stays as written. An exercise in `docs/exercises/` is a record too: a re-run
  is a new file.
- **Current-state documents** must stay true: `README.md`,
  `docs/hardware.md`, `docs/network.md`, `docs/architecture.md`,
  `docs/security.md`, `docs/roadmap.md`, `docs/runbooks/` and
  `docs/diagrams/`. When a fact changes, grep for every
  current-state document that states it and change them all in one PR.

`docs/roadmap.md` states its own rules at the top. Two that bite:

- A purchase enters or leaves only through *Everything still to buy*. README's
  "N items now, M later" is checked against that table by `scripts/check_docs.py`.
- When an issue closes, its entry leaves the roadmap and anything worth
  keeping goes to the changelog in the same PR.

## Where the truth lives

- `docs/network.md` is the authority for hosts and addresses, and
  `docs/hardware.md` for the rack and the parts. The diagram restates them.
  `docs/diagrams/current/network.svg` is hand-written SVG. After editing it,
  re-render the PNG with
  `rsvg-convert --zoom=1.5 docs/diagrams/current/network.svg -o docs/diagrams/current/network.png`
  and commit both.
- Image versions live only in `stacks/<stack>/compose.yaml`. Prose never pins a
  version; `scripts/check_docs.py` fails it.
- Counts in prose (alert rules, dashboards, ADRs, runbooks) are checked
  against the files. Adding one means updating the count.

## Secrets and what is never published

- Secrets live only in `secrets/*.sops.yaml`. Never print, commit or paste a
  decrypted value, and never track a rendered `.env` or key file.
- What stays out of every file is set by `docs/security.md`, *What this
  repository deliberately does not publish*. Read that section before writing
  anything about the network or the house; it is the authority, and this
  file does not restate it.
