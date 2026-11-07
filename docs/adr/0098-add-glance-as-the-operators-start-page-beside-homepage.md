# ADR-0098: Add Glance as the operator's start page, beside Homepage

**Status:** Accepted · 2026-10 · adds a service to the tier
[ADR-0008](0008-place-services-by-data-trust.md) created; decides
[#1223](https://github.com/Gerrrt/HomeLab/issues/1223)

## Context

The operator wants the page a browser opens to to show more than links: the
estate's state, the news, and what the accounts they follow have posted. Homarr
is the usual answer and was named as the model, with its weight named as the
reason not to run it. It is a Next.js application with its own database and a
background worker, several hundred MiB at rest.

The estate already has a front page. Homepage
([#137](https://github.com/Gerrrt/HomeLab/issues/137)) runs on `trinity` at
`home.matrix.elysium`, and it was decided as **a directory, not a status page**:
no status dots, because a dot that means "a socket opened" reads to the
household as "this works", and uptime is Grafana's question. It also cannot
do what is asked. Homepage has no widget that lists feed items, only counters
from a few readers' APIs.

Four ways to get there were weighed:

- **Turn Homepage into it.** Status dots reverse #137's decision on the one page
  the household is given, and the feeds still are not there.
- **Homarr.** What was asked for in function and declined for its footprint.
- **Dashy, Homer, Heimdall.** Link pages first, as Homepage is. Feeds are
  missing or an iframe away.
- **Glance.** One Go binary with one YAML file and no database. Built-in
  widgets for RSS, Reddit, Hacker News, YouTube, Twitch, weather and HTTP
  monitors, and a `custom-api` widget that renders any JSON API through a Go
  template. Measured on `trinity` at 13–14 MiB with every widget loaded.

Three facts about the estate shaped the rest.

- **`trinity` cannot see most of the estate.** VLANs 30 and 40 are closed to
  it. `prometheus` (10.0.99.20) can see them, and its reader proxy
  ([ADR-0067](0067-authenticate-the-ingest-ports-with-a-token-per-client.md))
  already serves Homepage and Home Assistant a token that can query and
  nothing else.
- **This repository is public.** A list of someone's Mastodon, Bluesky and
  YouTube subscriptions is about a person, not a homelab, and the instinct
  `security.md` applies to device names applies to it.
- **Miniflux already holds feeds, and its REST API is off.**
  [ADR-0057](0057-add-miniflux-to-the-sensitive-tier-with-its-fetcher-kept-off-winterfell.md)
  turned it off because it takes the admin's password without the login page.
  The same ADR pre-authorises a Fever credential per user, on three
  conditions. Read on the pinned 2.3.3 source: Fever is served whether or not
  the REST API is off, its key is the MD5 of `username:password` set in that
  user's settings, it can read and mark that user's items, and it cannot add a
  feed or reach another user. Its newest-items call returns the latest 50
  across all of a user's feeds and cannot filter by category. Miniflux's
  Google Reader API was also read, and rejected: it has no per-category stream
  and it can add subscriptions.

## Decision

1. **Glance joins `stacks/sensitive` on `trinity`**, at
   `start.matrix.elysium`, behind the tier's Caddy, with a step-ca leaf and a
   Caddy alias like every other name. It runs as the operator's uid, read-only
   with no tmpfs, every capability dropped, no Docker socket, under a 64 MiB
   ceiling. Nothing it holds needs backing up.

2. **Homepage stays a directory.** It gains a link to the start page and
   nothing else. The two pages answer different questions, and the one the
   household is given keeps #137's answer.

3. **Status comes from two places, and the page says which is which.**
   - *Estate*: the firing alerts, every blackbox probe
     (`min by (name, host) (probe_success)`) and every `up` series, from the
     reader proxy with the reader token, copied into the sensitive tier's
     secrets as Homepage's is. It covers every VLAN and agrees with Grafana
     because it is the same data. Alerts come first, because a host that stops
     pushing leaves no `up` series to read as 0. Only `warning` and
     `critical` alerts count, which are the ones Alertmanager delivers.
     Watchdog fires always, so its absence is shown as a fault: it means rule
     evaluation has stopped. An empty answer reads as "no data", never as
     "all clear".
   - *Household*: the tier's apps, each asked for its health path through
     Caddy, at the paths the blackbox probes already use. This is
     the "a socket opened" dot #137 kept off Homepage. It is accepted here
     because this page is the operator's, it sits beside the panel that says
     whether the app has stayed up, and the README says what green means.
   - Glance renders widgets only when the page loads, and a widget's cache
     only bounds how old that answer may be. An open tab would keep its first
     answer, so the page reloads itself once it is five minutes old, while it
     is visible and nothing is being typed. The Estate panel says how long ago
     it was checked.

4. **Personal feeds live in Miniflux, under a user of their own.** A non-admin
   user `glance` follows what the page should show. The page reads it over
   Fever, as one newest-first stream labelled by feed, because Fever cannot
   filter by category. The key is that user's alone, so it can only mark
   items read on a list of public feeds. ADR-0057's three conditions are met:
   generated passwords, kept in the password manager, and recorded in the
   stack README with the client and the date. Mastodon and Bluesky arrive as
   their profile or hashtag RSS, and YouTube as its channel feed. A home
   timeline has no feed, and nor do Instagram, Facebook or X. Scraping them is
   not done.

5. **What is written in `glance.yml` is what anyone running the estate would
   see**: the clock, a calendar, the weather at Homepage's coarse location,
   Hacker News, r/homelab and r/selfhosted, and a search box. The search box
   sends nothing until Enter, because Glance's has no suggestions. Glance's
   Twitch and YouTube widgets need channel names in this file, so they are not
   used.

6. **Every fetch is server-side.** Glance fetches over Winterfell's existing
   egress, as Homepage's weather and Miniflux do. No firewall rule changes.
   The browser loads the page and nothing else. That is why the monitor has no
   icons: Glance's icon prefixes are fetched by the browser from a CDN.

7. **No login**, as Homepage has none. Glance has an optional one. It is off
   because the page is reached from the same places as Homepage, shows no
   credential, and could act on nothing. What it shows that Homepage does not
   is the names of firing alerts. Grafana shows those to the same networks
   behind a login, and that difference is accepted.

8. **Checked before it lands.** CI runs Glance's own `config:validate` on the
   file in the pinned image (`scripts/check_glance_config.sh`). It is not
   booted under its hardening in CI, for Homepage's reason: its trust bundle
   holds the tier's root, which CI does not have.

## Consequences

- **A second front page.** The estate has two pages that list the tier's
  services. Glance's monitor list and the blackbox targets now name the same
  health paths in two files. A service added to the tier is added to both, as
  it already is to Homepage's tiles.
- **One more holder of the reader token.** Rotating it is four edits of one
  value instead of three. `secrets/sensitive.example.yaml` says where.
- **Outbound traffic from VLAN 99 grows a little.** Reddit, Hacker News and
  Open-Meteo are asked every few minutes while the page is open, and on
  Glance's cache schedule while it is not. The feeds themselves are Miniflux's
  traffic, which ADR-0057 already accepted.
- **A busy feed can crowd a quiet one off the page.** Fifty items across all
  of `glance`'s feeds is the window. The remedy is fewer chatty feeds on that
  user, not a second API.
- **The image was not clean when pinned.** Trivy found four HIGH and no
  CRITICAL in the Go standard library and `golang.org/x/net` of 0.8.7 on
  2026-10-19. All four are denial of service: HTTP/2 SETTINGS floods, Range
  headers and TLS ECH. Glance serves plain HTTP/1.1, and only to Caddy, so the
  HTTP/2 and ECH findings do not reach its server. The Range one does, for
  anyone who can open the page, because Caddy passes the header on. A hostile
  feed host could aim the client half at this container. Either way the cost
  is a start page restarting under its memory ceiling. The weekly CVE scan picks the digest up
  like any other, and the fix is an upstream release on a newer Go.
- **Nothing is backed up and nothing needs to be.** Glance is **Unclassed**
  under [ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)
  for Homepage's reason. The `glance` user's subscriptions are in Miniflux's
  database, which the tier's nightly backup already holds.
- **Deploy-gated.** The Miniflux user, two SOPS keys, the host override and a
  blackbox probe for the new name follow the merge. #1223 carries them, and
  the probe is added once the page answers, as every target in that file is.

> *Decisions 5 and 6 are superseded by
> [ADR-0100](0100-grow-glance-into-a-homelab-page-and-keep-the-operators-lists-in-sops.md):
> the operator's own lists now live in SOPS rather than being left out, and
> the browser fetches YouTube thumbnails. The rest of this ADR stands.*
>
> *Decision 2 is superseded by
> [ADR-0103](0103-retire-homepage-and-serve-the-household-page-from-glance.md):
> Homepage is retired, and the household's directory at `home.matrix.elysium`
> is now a page of Glance with no status on it. The rest of this ADR stands.*
