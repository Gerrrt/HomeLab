# CLAUDE.md

Working rules for an AI session in this repository. The README is the tour;
this is what a session gets wrong without being told.

## Before you push

- Run `make validate`, which is every check CI runs. When the change is docs
  only, run `python3 scripts/check_docs.py` and `./scripts/lint.sh` at least.
  CI's markdownlint uses `.markdownlint-cli2.yaml`.
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
  stays as written.
- **Current-state documents** must stay true: `README.md`, `docs/hardware.md`,
  `network.md`, `architecture.md`, `security.md`, `roadmap.md`, the
  runbooks and `docs/diagrams/`. When a fact changes, grep for every
  current-state document that states it and change them all in one PR.

`docs/roadmap.md` states its own rules at the top. Two that bite:

- A purchase enters or leaves only through *Everything still to buy*. README's
  "N items now, M later" is checked against that table by `check_docs.py`.
- When an issue closes, its entry leaves the roadmap and anything worth
  keeping goes to the changelog in the same PR.

## Where the truth lives

- `docs/network.md` is the authority for hosts and addresses, and
  `docs/hardware.md` for the rack and the parts. The diagram restates them.
  `docs/diagrams/current/network.svg` is hand-written SVG. After editing it,
  re-render the PNG with
  `rsvg-convert --zoom=1.5 docs/diagrams/current/network.svg -o docs/diagrams/current/network.png`
  and commit both.
- Image versions live only in each stack's `compose.yaml`. Prose never pins a
  version; `check_docs.py` fails it.
- Counts in prose (alert rules, dashboards, ADRs, runbooks) are checked
  against the files. Adding one means updating the count.

## Secrets and what is never published

- Secrets live only in `secrets/*.sops.yaml`. Never print, commit or paste a
  decrypted value, and never track a rendered `.env` or key file.
- `docs/security.md`, *What this repository deliberately does not publish*,
  lists what stays out of every file: the WAN address, the WireGuard endpoint
  and port, firewall rule bodies, Wi-Fi configuration, full MAC addresses,
  camera placement, and owner names on personal devices.
