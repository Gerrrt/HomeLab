# ADR-0059: Add Memos to the sensitive tier for notes, and keep documentation in docs

**Status:** Accepted · 2026-09 · adds a service to the tier
[ADR-0008](0008-place-services-by-data-trust.md) created, the second from the
*Tier extras* milestone after
[ADR-0057](0057-add-miniflux-to-the-sensitive-tier-with-its-fetcher-kept-off-winterfell.md)'s Miniflux; decides [#145](https://github.com/Gerrrt/HomeLab/issues/145)

## Context

[#145](https://github.com/Gerrrt/HomeLab/issues/145) proposed
[Memos](https://usememos.com/), a markdown notes service, for a need nothing in
the estate meets: a quick note, typed on a phone or a laptop on Hicks, kept in
the house. It chose Memos as deliberately the smallest thing in its category —
MIT, one Go binary, SQLite. The alternatives are heavier in different
directions. SilverBullet is scriptable and more to learn. TriliumNext is a
hierarchical knowledge base, right for a large structured corpus and overkill
for jotting. Joplin is client-side with a sync target, so it wants Nextcloud
or similar behind it — a dependency the estate otherwise avoids.

[`roadmap.md`](../roadmap.md) puts every service beyond ADR-0008's nine in
*Tier extras*, where "each needs its own decision before it is authored". This
is that decision for the second of them, after Miniflux
([ADR-0057](0057-add-miniflux-to-the-sensitive-tier-with-its-fetcher-kept-off-winterfell.md)).

**The placement.** ADR-0008 places by the trust of the data, not the function.
Nothing about a notes service demands the higher-trust segment. What does is
what notes accumulate: addresses, account numbers, the half of a credential
copied while setting something up. That is the same kind of data as
Paperless-ngx's scans, held less carefully by the people writing it, and
VLAN 99 is where that kind of data lives.

**The path.** Hicks already reaches `trinity` on `443/tcp`
([`network.md`](../network.md)), and Caddy routes by name. A service behind
Caddy is one more name on a port that is already open, so **no rule is added**
— the one property that made Audiobookshelf's
([ADR-0050](0050-add-audiobookshelf-to-the-media-tier-behind-a-fifth-hicks-pass.md))
an ADR in its own right does not arise here.

Measured on the pinned image on 2026-09-29, started read-only as `10001` with
every capability dropped:

- `/var/opt/memos` is `10001:10001` in the image, and a named volume inherits
  it. The entrypoint's root-to-`su-exec` block is skipped when it starts as
  that uid, so the service needs no capability and no root — unlike Vaultwarden.
- The database is `memos_prod.db` in **WAL mode**. While it runs, a fresh one
  is a 4 KB header and the admin account and the first notes exist only in
  `memos_prod.db-wal`. A clean `docker stop` checkpoints them into the main
  file and leaves the `-wal` empty; a killed process does not.
- **It is not one file.** The default storage is `LOCAL`, and every attachment
  is written under `./assets`. #145 called this "the easiest backup on the
  list"; it is a database and a directory, and the backup has to know both.
- Sign-up is an instance setting held in the database, not an environment
  variable. The first account registered becomes the admin.
- It has **no second factor** of its own, only passwords and SSO.
- 15 MiB resident idle, and the same after an upload.

## Decision

1. **Memos joins `stacks/sensitive` on `trinity`**, at
   `https://memos.matrix.elysium`, in Vaultwarden's shape: `expose:` only,
   `read_only`, `cap_drop: ALL`, `no-new-privileges`, pinned by digest,
   healthchecked with what the image ships, and a memory ceiling over a
   measured number. It runs as the image's own `10001`.

2. **Notes, not documentation.** `docs/` stays this repository's record: CI
   lints it and `git log` explains it, and neither is true of a note.
   Nothing about the estate — how to rebuild it, who to call, where the keys
   are — is written into Memos as its home. Memos does not answer
   [#124](https://github.com/Gerrrt/HomeLab/issues/124). A successor operator
   needs an entry point that survives the estate being down, and a note on
   `trinity` is exactly as down as `trinity` is.

3. **A password, and registration closed behind the first account.** The
   operator registers the admin at first start and, before anything else, sets
   the instance's `disallowUserRegistration` (its general settings, as the
   admin), then creates the household's accounts from the admin settings. The window between first start and that setting
   is minutes on a segment only Hicks reaches. Memos has no TOTP, so
   [ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)'s
   floor is not met by the service itself. It stands where Immich and AdGuard
   Home stand in that record's table, and the identity provider ADR-0022 is
   waiting on would cover it.

4. **No secret.** Nothing is read from the environment that a person would
   need to keep, so `secrets/sensitive.sops.yaml` does not change.

5. **The volume is backed up whole, nightly, with the rest of the tier.**
   `memos_prod.db` is its sentinel, and `memos_prod.db-wal` and `./assets` are
   named beside it, for the reason Vaultwarden's WAL is. The nightly run stops
   the container first, which checkpoints; the `-wal` is what carries the last
   writes when the stop was not clean.

## Consequences

- **ADR-0008's service list is amended,** by a note in it as ADR-0057 left
  one: the sensitive tier is the nine it named, Miniflux and Memos. ADR-0008's reasoning about the tiers is untouched, and
  this does not make the other *Tier extras* decided. Each still needs its own
  decision.
- **Under [ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md),
  Memos is *Durable*,** the same as Paperless-ngx. This record is that row;
  ADR-0023's own table is not edited. It may be
  down, it may not be lost, and it holds nothing real until the off-estate copy
  exists and its staleness is visible. Nothing in it may be the only copy of
  something the household needs to recover *from* an outage. That is what
  *Independent* would mean, and a note on `trinity` cannot be it.
- **ADR-0022's list of services with no second factor grows by one,** in a
  note beside Miniflux's; the table is not edited. The
  deferral's expiry is unchanged: it is keyed to real data on the tier, which
  Vaultwarden, Immich and Paperless-ngx reach first.
- **One more host override.** `memos.matrix.elysium` is a Caddyfile site, a
  Caddy alias and a pfSense override, the three places
  [`build-the-sensitive-tier-host.md`](../runbooks/build-the-sensitive-tier-host.md)
  says every later service's name goes.
- **One more service stopped for the length of the nightly archive.** It holds
  kilobytes, so the stop is not measurably longer.
- **Reopened if attachments grow into a library.** If `./assets` starts to
  hold what Paperless-ngx or Immich exists for, the answer is to move it
  there, not to give Memos a disk of its own.
