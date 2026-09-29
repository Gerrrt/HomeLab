# ADR-0057: Add Miniflux to the sensitive tier, with its fetcher kept off Winterfell

**Status:** Accepted · 2026-09 · adds a service to the tier
[ADR-0008](0008-place-services-by-data-trust.md) created, beyond the nine it
counted, and a row to the table
[ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)
keeps; decides [#147](https://github.com/Gerrrt/HomeLab/issues/147)

## Context

[#147](https://github.com/Gerrrt/HomeLab/issues/147) proposed Miniflux, a
feed reader: one Go binary, a deliberately fixed feature set, and the Fever
and Google Reader APIs that third-party phone clients speak. FreshRSS was the
alternative, with a fuller UI and a plugin system, and PHP and a web server
to keep patched. A feed reader is a background service, and the smallest one
that works is the right one.

ADR-0008 does not name it, and the roadmap's *Tier extras* section says that
every service beyond its nine needs a decision of its own before it is
written. That is this document. ADR-0008's test is the trust of the data, not
the function. A subscription list is a fair proxy for what someone reads and
cares about, which puts it beside a bookmark collection and not beside a film
library. So the placement is the sensitive tier on `trinity`, and it is not
in question.

The issue said it needed **no new rule**, and it is right. Hicks reaches
`trinity` on `443/tcp` under the pass [`network.md`](../network.md) lists, and
Caddy routes by name behind that one port.

What the issue named but did not weigh is direction. **Miniflux is the first
service on this tier whose whole job is to reach outward on a timer.** Every
subscription is fetched every sixty minutes by default, from sixteen workers,
out of VLAN 99. The segment has internet egress, so that is not a firewall
change. But Winterfell is the segment
[ADR-0002](0002-vlan-segmentation-strategy.md) calls the one where compromise is total,
and a fetcher that dials whatever URL it is handed is a way of making
`trinity` open connections to the firewall's admin UI, step-ca, the UPS card
or `prometheus`. A feed URL is user input. On any other segment that is a
nuisance. On this one it is the property the segment exists to protect.

Measured on the pinned image (2.3.3) on 2026-09-29, booted with the stack's
options against the stack's pinned Postgres:

- **Runtime.** It runs as `65534`, the image's own user. It is read-only with
  no tmpfs at all: `docker diff` after migrations, admin creation and a
  restart showed nothing written but docker-init's mount point. It uses
  13 MiB idle, and its Postgres 42 MiB. The image has no shell, curl or wget,
  and the binary's own `-healthcheck auto` is the healthcheck.
- **The fetcher refuses private addresses by default.**
  `FETCHER_ALLOW_PRIVATE_NETWORKS` is `0` in `-config-dump`. The refusal is
  made at dial time, after DNS, so a name does not get around it. Discovery
  of `http://miniflux-db:5432/` was refused as `refusing to access private
  network host "172.18.0.2"`, and `http://localhost:8080/` as `"::1"`.
  `INTEGRATION_ALLOW_PRIVATE_NETWORKS` is the same guard for its outbound
  integrations, and is also `0`.
- **The admin is created once.** `CREATE_ADMIN` with `ADMIN_USERNAME` and
  `ADMIN_PASSWORD` creates the account on the first start. Every later start
  logs "Skipping admin user creation because it already exists" and leaves
  the account alone.
- **The REST API accepts the admin's own password.** `/v1/me` answered 200 to
  basic auth with it. With `DISABLE_API=1` the same request is redirected to
  the login page.
- **The two sync APIs are per user.** The Google Reader endpoint refused the
  admin's password: it knows only credentials set under *Settings ›
  Integrations*, and none are set until someone sets them. Fever is the same
  and needs a key of its own.
- **There is no TOTP.** The only second-step candidate is WebAuthn, which is
  off by default (`WEBAUTHN=0`). Turned on, it registers passkeys as a second
  way to log in, beside the password and not after it. The route to a real
  second factor is its OpenID Connect login, which needs an identity
  provider.

## Decision

1. **Miniflux joins `stacks/sensitive` on `trinity`**, in Paperless's shape:
   `expose:` and no `ports:`, a site block at `miniflux.matrix.elysium`, the
   name as an alias on Caddy and a host override on `morpheus`. It is pinned
   by digest, runs non-root and read-only with every capability dropped,
   takes a memory ceiling, and is healthchecked with its own binary.
   **Postgres is its own container**, `miniflux-db`, in `paperless-db`'s
   shape: a second database inside Paperless's Postgres would make a restore
   of either one a question about both.

2. **No firewall change.** It is reached from Hicks under the existing
   `vlan50 → 10.0.99.40:443` pass, and it leaves through Winterfell's existing
   egress rule.

3. **The outbound traffic is accepted, and named where it will be seen.**
   `network.md` and `security.md` say that this container polls on a timer.
   Anyone reading the firewall's graphs for VLAN 99 then knows one steady
   source of outbound HTTPS from `trinity` by name. The precedent is
   [#166](https://github.com/Gerrrt/HomeLab/issues/166)'s probes, which made
   the same kind of path deliberate rather than incidental.

4. **The fetcher stays off every private range, and `compose.yaml` says so
   explicitly.** `FETCHER_ALLOW_PRIVATE_NETWORKS` and
   `INTEGRATION_ALLOW_PRIVATE_NETWORKS` are set to `0` rather than left to
   default, so that a version whose default changed would change nothing
   here. A future wish to read a feed served from inside the house is
   answered by that service publishing it somewhere Miniflux can reach
   publicly, or by a new ADR. It is never answered by flipping this flag,
   because the flag has no scope: it opens every address on Winterfell at
   once.

5. **The account has one factor, and the doors to it are counted.**
   - Miniflux joins Immich and AdGuard Home in `security.md`'s list of tier
     services that cannot carry a second factor, and ADR-0022's table gains
     its row through a pointer note.
   - WebAuthn stays off. A passkey beside a password is a second key to the
     same door, not a second lock.
   - The REST API is off (`DISABLE_API=1`), because it takes the same
     password without the login page and nothing here calls it.
   - The Fever and Google Reader APIs stay unset until a phone client is
     actually wanted. **Setting one is a per-user decision this ADR
     pre-authorises on three conditions:**
     - a generated password;
     - kept in the password manager;
     - noted in the stack README with the client and the date.

     Those credentials bypass the login page by design, which is the whole
     point of them. Scoped to feeds, they are no worse than the password they
     stand beside.

6. **Backups are the nightly quiesced volume tarball**, with `miniflux-db-data`
   given a sentinel in `backup-volumes.sh` and a uid in `restore-volumes.sh`,
   exactly as `paperless-db-data` has. There is no `pg_dump`. The OPML export
   in the stack README is the portable copy of the part that matters:
   subscriptions come back from it, and read state and stars do not.

7. **Two keys in `secrets/sensitive.sops.yaml`**: `MINIFLUX_DBPASS`, read by
   both containers so that they cannot drift, and `MINIFLUX_ADMIN_PASSWORD`,
   read once. The database password is spliced into `DATABASE_URL`'s
   connection string, so it is `make gen-secret`'s alphanumeric output and
   never a typed value.

## Consequences

- **The tier has its first extra, and the roadmap's *Tier extras* section has
  its first decided entry.** The next extra arrives the same way: an ADR
  first, then the service, as Audiobookshelf did for the media tier
  ([ADR-0050](0050-add-audiobookshelf-to-the-media-tier-behind-a-fifth-hicks-pass.md)).
- **Winterfell gains a standing outbound appetite.** It is small (about one
  request per subscription per hour), it goes only to the addresses the
  household chose to subscribe to, and it is by name in the docs. It also
  means the feeds' operators, and the ISP, learn the reading list's shape
  from `trinity`'s address. That is the ordinary price of reading feeds at
  all.
- **The containment rests on a flag, not a rule.** If Miniflux's private-range
  check had a flaw — a redirect it followed, a resolution it trusted twice —
  the firewall would not catch it, because Winterfell's hosts reach each other
  without crossing it. That is the same position every container on this tier
  is in with respect to its own code. It is recorded rather than engineered
  around because the alternative, a forward proxy with an allowlist in front
  of one feed reader, is more moving parts than the risk is worth.
- **One more service is on the single-factor list**, so one more reason exists
  to stand an identity provider up when ADR-0022's triggers fire. Miniflux's
  OIDC login is the route then, and it changes nothing today.
- **An admin password rotated in SOPS alone does nothing.** The variable is
  read on the first start only, as Paperless's is. The stack README has the
  command that actually rotates it.
- **ADR-0008 and ADR-0022 are not superseded.** ADR-0008's tier gains a
  service it did not count, by its own test, and ADR-0022's table gains a row
  of a kind it already has. Both gain a pointer here.
