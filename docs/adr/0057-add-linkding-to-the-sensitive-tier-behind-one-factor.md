# ADR-0057: Add linkding to the sensitive tier, behind one factor

**Status:** Accepted · 2026-09 · adds a service to the tier
[ADR-0008](0008-place-services-by-data-trust.md) created, and one to the list
[ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md) keeps
of services that cannot carry a second factor; decides
[#144](https://github.com/Gerrrt/HomeLab/issues/144)

## Context

[#144](https://github.com/Gerrrt/HomeLab/issues/144) proposed a bookmark
manager, and named linkding: MIT, one container, SQLite, browser extensions and
a REST API. It does one thing and stops. It named two alternatives:

- **Karakeep** archives the full text of each page and tags it with a model.
  That is several times the footprint, plus a model runtime to feed.
- **Wallabag** sits between the two, and is built for reading articles later
  rather than for finding a link again.

The want as stated is "I can find the link again", not "the page still exists
when the site is gone". linkding is the smallest answer to the first.

ADR-0008 does not name it. As with
[ADR-0050](0050-add-audiobookshelf-to-the-media-tier-behind-a-fifth-hicks-pass.md),
its test is the trust of the data, not the function. **A bookmark collection is
a browsing history by another name**: modest one entry at a time, revealing in
aggregate. That is the same kind of data as AdGuard Home's query log, which the
tier already holds. It belongs on Winterfell and not on a segment shared with
the televisions. Hicks reaches it under the existing 50→99, so there is no new
rule, and it sits behind Caddy with `expose:` only, like everything else here.

**So the placement is not what makes this an ADR.** The issue's own correction
of 2026-09-19 set two reasons:

1. It is beyond ADR-0008's nine. The *Tier extras* milestone exists so that
   the tier measured on `trinity` is the one ADR-0008 decided, and so that
   each extra is a decision rather than drift.
2. **linkding cannot carry a second factor.** Its logins are Django's
   password, OIDC, or trust in a header set by an authenticating proxy. There
   is no TOTP and no WebAuthn. ADR-0022 counted the tier's services that
   cannot carry a factor (Grafana, Immich, AdGuard Home), and adding one to that
   count is a decision to take in the open.

Measured on the pinned image (1.47.0) on 2026-09-29, under the options
`compose.yaml` gives it:

- The image declares no user. `bootstrap.sh` runs as root, then migrates,
  switches SQLite to WAL, creates the superuser from the environment, and runs
  `chown -R www-data:` on the data directory. uwsgi then drops to `www-data`
  (33). Every serving process reads `Uid 33` and `CapEff 0` in `/proc`.
- `/etc/linkding/data` is `0:0 755` in the image, so a fresh named volume is
  root's.
- With `cap_drop: ALL` and nothing added, uwsgi exits at its `setgid`. With
  `CHOWN`, `SETUID` and `SETGID` it boots once. On the **second** start, root
  cannot write the database, which is now 33's, and `migrate` fails with
  "attempt to write a readonly database". The script has no `set -e`, so
  uwsgi starts anyway and the healthcheck passes. `DAC_OVERRIDE` is the fourth
  capability. With all four, two boots in a row are clean with the network
  off.
- Running as `user: 33` needs no capabilities and boots clean, but only on a
  volume already owned by 33.
- `docker diff` shows no write outside the volume, apart from the pidfile in
  `/tmp`.
- Memory: 77 MiB idle, and a 188 MiB peak while importing 3,000 bookmarks.
- Behind a proxy that sets `X-Forwarded-Proto: https`, a login POST from
  `https://links.matrix.elysium` passes Django's CSRF check with no
  trusted-origins setting.

## Decision

1. **linkding joins `stacks/sensitive` on `trinity`**, at
   `links.matrix.elysium`. It uses the plain image, not `-plus`, which adds
   Chromium to archive pages. Its shape follows Vaultwarden's:
   - pinned by digest;
   - `read_only`, `no-new-privileges`, and `/tmp` as a tmpfs;
   - `expose:` only;
   - the image's own healthcheck;
   - a memory ceiling over the measured number.

   It runs as root with `cap_drop: ALL` and four capabilities added back:
   `CHOWN`, `DAC_OVERRIDE`, `SETUID` and `SETGID`. The root half is the
   bootstrap. Every process that serves a request is uid 33 with none.
   `user: 33` was the cleaner shape, and it was declined because it needs a
   step that chowns a fresh volume before first start. That step runs
   nowhere else, `check_hardened_boot.sh`'s fresh volume included, and it is
   the hand-run command the stack's DIFFERENCE 2 already turned down for
   Caddy. This is revisited if the image ever ships the data directory owned
   by 33.

2. **One superuser, from SOPS, on first start only.** This is Paperless's
   shape. `LINKDING_SUPERUSER_PASSWORD` is the tier's sixteenth key, and the
   user name defaults in `.env.example`. linkding has no self-registration, so
   there is no sign-up to turn off. A second person's account is made in
   `/admin`, and it counts toward ADR-0022's third trigger like any other.

3. **Behind one factor, and named as such.** `docs/security.md` lists linkding
   with Grafana, Immich and AdGuard Home as unable to carry a second factor.
   This is accepted for three reasons:
   - The data is a list of links. It is the least sensitive content on the
     tier after Homepage's.
   - It is reachable only from Hicks.
   - Its one password is generated and kept in the password manager.

   **It does not fire any of ADR-0022's triggers.** A bookmark is not a
   credential, a photo or a document, and adding linkding makes nothing
   reachable from outside and gives no third person an account. It is one more
   entry in the argument for an identity provider when that decision is
   taken. If that decision stands one up, `LD_ENABLE_OIDC` is how linkding
   gets a second factor. It is a setting, not a migration.

4. **Background tasks are off.** Their job is to fetch favicons and previews,
   which means a request from `trinity` to a third party for every site in the
   list. That hands out, one hostname at a time, the very list this tier is
   holding back. The cost is a list with no icons. Adding a bookmark still
   fetches that page's title and description from the site itself, which the
   browser adding it has just visited.

5. **[ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)
   class: Unclassed.** No household recovery step runs through a bookmark, so
   nothing has to exist outside the estate before it holds real data. Its loss
   is covered by the nightly volume backup and its copy on `oracle`:
   `db.sqlite3` is the sentinel, with its `-wal` and `secretkey.txt` beside
   it. A Netscape HTML export imports into any browser, and it is the copy
   that needs nothing of this estate to read.

6. **Links, not pages.** If the want turns out to be "the page still exists
   when the site is gone", that is Karakeep, Wallabag or linkding's `-plus`
   image. It is a different service with a model runtime or a browser in it,
   and it gets a new decision rather than a tag bump here.

## Consequences

- **The tier has a fifteenth service and an eleventh archived volume.** The
  stack README, the build and restore runbooks, the backup tables and the
  Homepage page each gain a row.
- **One more name on the leaf and in the resolver.** `links` needs a host
  override on `morpheus` when it is deployed. Until then the service is
  authored and unreachable, which is the order ADR-0023 wants.
- **Four capabilities is more than Vaultwarden holds**, and the reason is
  upstream's bootstrap rather than anything linkding does while serving. The
  capabilities are held only by the root process that runs the migrations.
  The `compose.yaml` comment names the one-line `stat` that shows whether the
  premise still holds after an image bump.
- **The "cannot carry a factor" list grows from three to four.** Each entry
  makes an identity provider a little more worth its cost when ADR-0022's
  decision comes due. None of them brings that decision forward.
- **No icons, by choice.** Someone who wants them turns on background tasks,
  accepts the third-party requests that come with them, and edits this ADR's
  successor to say so.
- **ADR-0008, ADR-0022 and ADR-0023 are not superseded.** Each gains a forward
  pointer here: ADR-0008's list of services, ADR-0022's table of factors, and
  ADR-0023's table of classes.
