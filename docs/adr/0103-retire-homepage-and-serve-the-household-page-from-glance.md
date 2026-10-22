# ADR-0103: Retire Homepage, and serve the household's page from Glance

**Status:** Accepted · 2026-10 · supersedes decision 2 of
[ADR-0098](0098-add-glance-as-the-operators-start-page-beside-homepage.md)
and the choice of software in
[#137](https://github.com/Gerrrt/HomeLab/issues/137); refs
[#1250](https://github.com/Gerrrt/HomeLab/issues/1250)

## Context

Two front pages run on `trinity`. Homepage ([#137](https://github.com/Gerrrt/HomeLab/issues/137))
is the household's page at `home.matrix.elysium`, the one address on the tier
that people other than the operator are given. It is a directory, not a
status page. Glance is the operator's start page at `start.matrix.elysium`
([ADR-0098](0098-add-glance-as-the-operators-start-page-beside-homepage.md),
[ADR-0100](0100-grow-glance-into-a-homelab-page-and-keep-the-operators-lists-in-sops.md)).
ADR-0098's decision 2 kept them apart so that the household's page would keep
the answer #137 gave.

Glance has since grown a page per subject, and the operator asked whether
Homepage was still needed. What it did that Glance does not was little:

- **The household's page itself.** Twelve tiles of links, each with a line,
  the house wiki, and where to get each app.
- **Two live numbers.** Immich's photos and videos, on a key with only
  `server.statistics`, and Paperless-ngx's documents, on a view-only user's
  token.
- **Everything else was already Glance's.** Its console links are on
  Glance's Homelab page, and its other figures came from Prometheus, which
  Glance reads.

Keeping both cost:

- **Memory:** 191 MiB measured for Homepage on 2026-10-22, against 31 MiB for
  Glance with every page loaded.
- **Upkeep:** a second list of consoles to keep in step, and a Node.js image
  with its own stream of CVEs.
- **Trust:** a second trust bundle (`homepage-ca.pem`), and a third copy of
  the Prometheus reader token.

The one argument for two pieces of software is the one ADR-0098 relied on.
Glance has no per-page login, so a household member on a Glance page can
reach the operator's pages too: the feeds, the bookmarks and the alert
names.

## Decision

1. **The household's page becomes a page of Glance.** It is
   `glance/pages/household.yml`, slug `household`, slim, with the bar of tabs
   hidden on desktop. It carries the household's apps as links with a line
   each, the house wiki, where to get each app, the time and the coarse
   weather, and the Immich and Paperless numbers. It keeps #137's answer:
   no up/down, no alerts, no feeds, and nothing of the operator's.

2. **`home.matrix.elysium` keeps its name and serves that page.** Caddy
   redirects the bare `/` to `/household`. It passes everything else to
   Glance, so the page's assets and `/api/healthz` resolve, and it keeps the
   tier-root download at `/tier-ca.crt`. The household's bookmark, the
   address on the break-glass material and the host override all stay as
   they are.

3. **Homepage is removed:** the service, `stacks/sensitive/homepage/`,
   `homepage-ca.pem`, and `HOMEPAGE_PROMETHEUS_TOKEN`. The two read-only
   credentials are not reminted. Their values move in SOPS from
   `HOMEPAGE_IMMICH_API_KEY` and `HOMEPAGE_PAPERLESS_TOKEN` to
   `GLANCE_IMMICH_API_KEY` and `GLANCE_PAPERLESS_TOKEN`. Paperless's view-only
   user keeps its name, `homepage`, so nothing in Paperless changes.

4. **The household can reach the operator's pages, and that is accepted.**
   This repository counts the household as people with physical access to
   the house, and each of them already reaches every app here. What the other
   pages add is the operator's own reading lists and tickers, and the
   estate's alert names. Nothing on any page can act, and no page shows a
   credential. If that changes, Glance's login can be turned on for the whole
   instance. That would put a password in front of the household's page too,
   and would be a new decision.

5. **The blackbox target follows the name, not the software.** It is renamed
   `household-page`, with `/api/healthz` in place of Homepage's
   `/api/healthcheck`.

## Consequences

- **One front-page application.** One image, one trust bundle, one list of
  consoles, and two copies of the reader token instead of three.
- **About 160 MiB back on `trinity`.**
- **Order matters at deploy.** Until `trinity` runs the new compose,
  `home.matrix.elysium/api/healthz` reaches Homepage, which has no such path.
  So `trinity` is deployed first and `prometheus` pulls the new target after,
  or the `household-page` probe reads down until it does.
- **The household sees a new-looking page at the address it knows.** The
  same apps are there, in Glance's look instead of Homepage's.
- **Paperless keeps a user named after software that is gone.** That is
  cosmetic, and renaming it would mean reminting the token. The example
  secrets file says why the name stayed.
- **ADR-0022 and ADR-0023 named Homepage.** ADR-0022 left Homepage out of its
  table because it has no login, and ADR-0023 classed it Unclassed. Both now
  hold for the Household page, for the same reasons. Each gains a pointer
  here.
