# ADR-0089: Keep the wiki on Wiki.js 2.x until a named trigger fires

**Status:** Accepted · 2026-10

> [!NOTE]
> **Trigger 1 is enforced from 2026-10-07.**
> [`wiki-watch.yml`](../../.github/workflows/wiki-watch.yml) reads
> `requarks/wiki`'s published advisories and releases every Monday, through
> [`scripts/wiki_watch.py`](../../scripts/wiki_watch.py). It keeps one issue,
> labelled `security` and `wiki`, open while an advisory affects the pin or a
> trigger has fired. So the first consequence below, "Trigger 1 is not
> enforced yet", describes the record as it was written. The same run also
> reads triggers 2 and 3. The text below is left as written, per ADR-0001.

## Context

The household wiki on `oracle` runs `ghcr.io/requarks/wiki:2.5.316` on
`postgres:17.11` (`stacks/wiki/compose.yaml`).
[ADR-0011](0011-keep-the-wiki-internal.md)
decided where it is exposed, and
[ADR-0065](0065-pull-the-wikis-database-to-prometheus-as-a-dump.md) how it is
backed up. Nothing decided the engine.
[#859](https://github.com/Gerrrt/HomeLab/issues/859) asked for that decision.
The worry was that Wiki.js 3.0 had sat in alpha since 2022, while 2.x looked
like maintenance only.

The wiki is the second tier of the household's documentation: the paper card,
then the wiki, then GitHub (ADR-0011). Its readers are the household. A forced
migration, such as a CVE with no 2.x fix, would happen on the worst schedule
for the readers least able to work around it. So the engine needs a decision,
and a decision on when to move, before the move is forced.

**Read on 2026-10-07, from the project's releases and advisories:**

- **3.0 is in beta, not alpha.** `3.0.0-beta.628` shipped on 2026-10-04. It is
  the fourth beta since mid-September, and the latest two are no longer
  marked pre-release.
- **2.x still gets security fixes, released alongside the advisories:**
  - 2.5.313 (April 2026) fixed a critical privilege escalation in
    `users.update`.
  - 2.5.315 (2026-09-21) fixed two highs, a stored XSS and an administrator
    takeover with a 2FA bypass.
  - The pinned 2.5.316 is past all of them.
- **The alternatives #859 named:**
  - **BookStack:** MIT, MySQL or MariaDB, a books/chapters/pages hierarchy.
  - **Docmost:** AGPL, Postgres, real-time collaborative editing.
  - **Outline:** needs an external identity provider and S3, so ADR-0075
    rules it out.

## Decision

**The wiki stays on Wiki.js 2.x. It moves when any one of these fires:**

1. **A 2.x advisory with no fix after 30 days.** That is a published GitHub
   security advisory against `requarks/wiki` whose affected range includes
   the pinned version, with no 2.x release patching it within 30 days of
   publication.
2. **No 2.x release for six months.** The project's 2.x line has stopped, even
   if nothing is known to be wrong with it yet.
3. **3.0 reaches a stable release.** Not a beta. Then the move is to 3.0 on
   the project's own schedule rather than on a forced one.

**The first successor to weigh is Wiki.js 3.0 itself.** It keeps Postgres, so
ADR-0065's `pg_dump` pull survives as it is, and it is the engine's own
upgrade path for the pages and users already there.

**BookStack is the fallback**, if 3.0 stalls or its migration from 2.x proves
poor. Its cost is named now so it is not re-derived later: a second database
engine on the estate (MySQL or MariaDB), and ADR-0065's pull rewritten as a
`mysqldump` pull with its own `verify()` sentinel and `--prove` restore.
**Docmost is passed over.** Its main advantage is real-time editing, and the
household is not asking for that.

**Whatever runs must keep three things:**

- internal-only exposure (ADR-0011);
- the nightly dump pulled to `prometheus`, proven by `scripts/backup-wiki.sh
  --prove` (ADR-0065);
- the pages' GitHub mirror, ADR-0011's third tier.

The signed deploys and HTTPS of
[#847](https://github.com/Gerrrt/HomeLab/issues/847) apply to whichever engine
it is.

## Alternatives considered

**Move to BookStack now.** Rejected. Nothing is wrong with 2.x today: its
advisories are fixed within days. And the move costs a second database engine
and a rewritten backup. Moving early buys the household nothing it can
see, and spends the migration before it is needed.

**Name BookStack as the successor and skip 3.0.** Rejected while 3.0 is in
active beta. A successor that keeps Postgres keeps ADR-0065 whole, and it is
the cheaper move if it arrives.

## Consequences

- **Trigger 1 is not enforced yet.** Nothing here watches `requarks/wiki`'s
  own advisories. The weekly CVE scan reads the image's packages, which is a
  different list. A pin bump or a new 2.x release would prompt a reading,
  but an advisory that never gets a fix produces neither. That is exactly
  the case the 30-day clock exists for, and nothing would start it. Until a
  recurring check reads the project's advisories, at least weekly so day 30
  cannot pass between two readings, this trigger depends on someone
  remembering to look. That recurring check is the follow-up this record
  leaves open. What the record itself adds is the clock, and that a missed
  clock is a move, not a wait.
- **Trigger 2 is a calendar fact, and nothing alerts on it.** It is read
  whenever the pin is bumped: a bump that finds no 2.x release in six months
  is the trigger firing.
- **When a trigger fires, the migration is its own issue**, with a restore
  rehearsal from an ADR-0065 set into the new engine before the household's
  pages move. This record is the scoping, not that work.
