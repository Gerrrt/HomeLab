# ADR-0108: Move the wiki to Wiki.js 3.x by export and import

**Status:** Accepted · 2026-11 · carries out
[ADR-0089](0089-keep-the-wiki-on-wikijs-2-until-a-named-trigger-fires.md),
whose trigger 3 fired on 2026-11-01. It supersedes nothing.

## Context

ADR-0089 kept the household wiki on Wiki.js 2.x until a named trigger fired,
and named 3.x as the first successor to weigh. Two triggers have now fired:

- **Trigger 3 fired** on 2026-11-01, when `requarks/wiki` published 3.0.1,
  its first stable 3.x.
- **Trigger 1 has a date.** GHSA-35r7-33j8-ghwg (high) was published on
  2026-11-05, and affects every 2.x up to the pinned 2.5.317. Its only fix
  is 3.1.0. If no 2.x release patches it, trigger 1 fires on 2026-12-05.

[#1339](https://github.com/Gerrrt/HomeLab/issues/1339) set two gates.

**Gate 1: 3.x must keep ADR-0089's three requirements.** Read against the
3.3.0 source, it does:

- It is still one container on 3000, behind Caddy, so the wiki stays
  internal ([ADR-0011](0011-keep-the-wiki-internal.md)).
- It runs on Postgres 17 or 18 only, so
  [ADR-0065](0065-pull-the-wikis-database-to-prometheus-as-a-dump.md)'s
  `pg_dump` pull still works. It needs `ltree` and `pg_trgm`, and still
  reads `DB_PASS_FILE`.
- It has a `git` storage module with SSH authentication, `sync`, `push` and
  `pull` modes, and a branch setting, so the mirror to
  `Gerrrt/Lemmiwinks` survives.

**Gate 2: a restore rehearsal.** It ran on `oracle` on 2026-11-09, in a
scratch project:

1. The morning's ADR-0065 set was restored into a scratch Postgres.
2. A scratch 2.5.317 exported the restored database.
3. 3.3.0's own importer took the export into a fresh 3.3.0 under this
   stack's hardening.

The counts held: 108 pages, the 762 of 806 history rows whose page still exists, 3
accounts and Guest, the navigation, and every Lemmiwinks file mapped one to
one. It also found what this record has to decide.

- **There is no in-place upgrade.** 2.x exports a `.wkbackup` package, and a
  fresh 3.x on an empty database imports it in the browser. The package does
  not carry module settings, so the git target, and its deploy key, are
  entered again.
- **The tables move schema.** 3.x keeps its tables in the schema `wiki`, not
  `public`.
- **3.x hard-codes `_` to `-` in a stored path.** About 74 of 108 page URLs
  change, and the old ones do not redirect. The first git sync renames 75
  files in `Lemmiwinks` and rewrites the links in about 98 pages.
- **The git module runs ssh with `StrictHostKeyChecking=no`.** It does not
  verify GitHub's host key, and an option on its command line overrides
  anything in `known_hosts`.
- **There is no health route.** `/healthz` is a 404 in 3.x.
- **The built-in Guests group keeps 3.x's default DENY.** The import does
  not touch built-in groups, so anonymous reading, which 2.x allowed, is lost
  until it is set by hand.
- **The release cadence is fast.** Twelve 3.x advisories were published
  between 2026-11-02 and 2026-11-09, each fixed in the next release. 3.3.0 is
  the first version with none open.

## Decision

**The wiki moves to Wiki.js 3.x, at 3.3.0 or later, by 2.x's export and 3.x's
import.**

**3.x gets a new Postgres volume, `pgdata-wiki3`.** The 2.x cluster in
`pgdata` stays declared, mounted by nothing and untouched. Pointing `db` back
at it, with the 2.5.317 pin, is the whole rollback until the household has
written to 3.x. The follow-up to #1339 retires it.

**The first git sync goes to a branch.** The target is set to `wikijs-3` in
push-only mode. The rename and the rewritten links are then reviewed as a
`Lemmiwinks` PR, together with the mermaid diagrams turned into 3.x's diagram
block. Only after that is the target pointed at `main` in sync mode. Two-way
sync is never pointed at `main` before its first commit has been read.

**The host-key check is accepted as lost, and named.**

- **What changes.** The deploy key can push to one repository, and
  `Lemmiwinks` is a mirror of what the database holds. So a spoofed GitHub
  could read the pages, which are in a public repository anyway, and could
  answer a pull with content of its own.
- **What contains it.** A pull that changes a page leaves the page's
  previous version in its 3.x history. ADR-0065's nightly dump is the record
  that does not go through GitHub.
- **When it is reopened.** If 3.x makes the check configurable, it is turned
  back on.

**`/healthz` stays the wiki's health URL.** Caddy maps it to
`/_site/lemmiwinks.matrix.elysium/favicon`, a route the server answers
itself, which is also the app's own healthcheck. Blackbox's targets and their
rule tests do not change.

**The site's hostname stays `*`.** 3.x resolves a request to a site by its
Host header. Caddy serves the wiki as `lemmiwinks.matrix.elysium`,
`oracle.matrix.elysium` and `10.0.99.30`, and only the wildcard answers all
three.

**Anonymous reading is put back.** Guests get an ALLOW rule for
`read:pages`, `read:assets` and `read:comments`, as in 2.x. Family gets back
`read:source` and `read:history`, which 2.x gave it group-wide and the import
does not carry.

**`scripts/wiki_watch.py` keeps reading the advisories.**

- On a 3.x pin, an advisory with a later 3.x fix is a bump.
- One with no 3.x fix after 30 days is a decision for a person.
- ADR-0089's triggers 2 and 3 were about leaving 2.x. They are spent, and not
  reported.

**`scripts/backup-wiki.sh` counts with `search_path` set to `wiki, public`.**
The same query then reads either engine, so the nightly pull keeps working
between this record's merge and the cutover.

## Alternatives considered

**BookStack, ADR-0089's fallback.** Rejected, because 3.x passed both gates.
BookStack would also change every URL. It would add a second database engine,
and it would need ADR-0065's pull rewritten as a `mysqldump` with its own
proof.

**Restoring the 2.x dump into the 3.x cluster's database and letting 3.x
migrate it.** Not possible. 3.x's migrations start from an empty schema of its
own, and requarks documents no in-place path.

**Importing into the existing cluster, beside 2.x's tables.** 3.x's schema
`wiki` would sit next to 2.x's `public` in the same database. That would avoid
a new volume, but it leaves no clean rollback, and every dump would carry both
engines. Rejected for the new volume.

**Pointing the git target at `main` from the start.** That is one fewer step.
But the first sync would land a 75-file rename and about 98 rewritten pages on
the branch the household's wiki syncs two-way, unread. Rejected.

**Waiting for the 3.x release cadence to settle.** Every 3.x release so far
has fixed the advisories of the one before it. Waiting leaves the wiki on
2.5.317, which has an advisory with no 2.x fix. Rejected: 2026-12-05 is the
latest the move can wait.

## Consequences

- **Readers' deep bookmarks break.** The card on the fridge names only the
  host ([ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)),
  so it still works, and links inside the wiki are rewritten.
- **The move is a hand procedure with a freeze.** It is
  [`stacks/wiki/README.md`](../../stacks/wiki/README.md) § The move to 3.x.
  The export package holds every password hash and TOTP secret, and it is
  deleted from both places it lands.
- **Pin bumps will be frequent for a while.** Dependabot proposes them
  weekly, and `wiki-watch` reports any the pin is missing.
- **`Lemmiwinks`' own conventions change with the engine.** That repository
  records them for itself: its mermaid note is written for 2.x's mermaid
  8.8.2, and its paths use underscores. Its `wikijs-3` PR is where that
  happens, not here.
- **The 2.x volume is a second copy of the household's accounts until it is
  retired.** It holds password hashes and TOTP secrets, like the dumps. It
  sits on the same host as the live cluster, so it is not a backup. It
  exists only for the rollback.
