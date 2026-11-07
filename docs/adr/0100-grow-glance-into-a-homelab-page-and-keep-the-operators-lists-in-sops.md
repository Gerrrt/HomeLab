# ADR-0100: Grow Glance into a homelab page, and keep the operator's lists in SOPS

**Status:** Accepted · 2026-10 · supersedes decisions 5 and 6 of
[ADR-0098](0098-add-glance-as-the-operators-start-page-beside-homepage.md);
refs [#1223](https://github.com/Gerrrt/HomeLab/issues/1223)

## Context

Glance went live on 2026-10-21 as ADR-0098 left it: one page with the
estate's alerts, a household monitor, followed feeds, Hacker News, two
subreddits and the weather. The operator compared it with a fuller Glance page
and asked for most of what that page had, and more:

- a ticker strip, YouTube and Reddit tabs, bookmarks, scores, trending
  repositories, a random fact and the year's progress;
- console shortcuts by category, uptime badges, container and VM counts,
  per-host CPU, memory and disk, pool health and free space, network traffic,
  and media and storage figures.

It is the same software. The difference was configuration, and two of
ADR-0098's decisions stood in the way:

- **Decision 5** kept the file to what anyone running the estate would see,
  and so left out Glance's YouTube and Twitch widgets, which need channel
  names in the file. A ticker list, a bookmark list or a list of subreddits
  has the same shape: it describes a person, and the repository is public.
- **Decision 6** had the browser load nothing but the page. YouTube rows with
  thumbnails need the browser to fetch images from `i.ytimg.com`, and icons
  from Glance's `di:` and `si:` prefixes come from a CDN.

Most of the homelab half needed no new collector. Read from Prometheus on
2026-10-21:

- node_exporter series for trinity, prometheus, oracle and smaug;
- `container_last_seen` from the Docker agents, and smaug's
  `homelab_container_running`;
- `homelab_zpool_state` for smaug's pools, and SMART verdicts;
- `homelab_guest_*` from Saruman's collector, stale since 2026-10-19,
  which is itself worth showing;
- pfSense's per-interface byte counters over SNMP, with the interface names
  hex-encoded (`em0` is the WAN, `igc0.10` to `igc0.99` the VLANs);
- the UPS over SNMP, and speedtest-tracker's last result.

Jellyfin's stream count is the exception. Jellyfin is on smaug, VLAN 40, and
`trinity` has no route there.

## Decision

1. **Two pages.**
   - *Home* is the start page: markets, bookmarks, the year, search, YouTube
     tabs, Following, Reddit tabs, NBA scores, trending repositories, the
     estate in brief, hosts, Hacker News and a random fact.
   - *Homelab* is the estate: every console by category, a headline strip,
     the Estate panel, uptime badges, hosts, storage, network, Saruman's VMs,
     the household monitor, the UPS and upstream releases.

   Each page is its own file under `stacks/sensitive/glance/pages/`, spliced
   in by Glance's `$include`. The three files are mounted one by one, so
   `check_mounted_config.py` recreates Glance when any of them changes.

2. **The operator's lists live in SOPS, as one-line JSON.** These are
   `GLANCE_MARKETS`, `GLANCE_BOOKMARKS`, `GLANCE_VIDEO_TABS` and
   `GLANCE_REDDIT_TABS` in `secrets/sensitive.sops.yaml`. They are not
   credentials. They are kept there because SOPS is where this repository
   keeps what it does not publish, as it does the TV's MAC (ADR-0097).

   Compose hands them to Glance like any guarded value, and Glance
   substitutes them into the YAML before parsing, where JSON is valid flow
   YAML. No new file, renderer or SOPS rule is needed. The cost is that they
   are edited as JSON with `make secrets-edit`, with no single quotes, because
   `secrets-env.sh` unescapes nothing.

   This supersedes decision 5: personal lists are no longer left out, they
   are kept out of the repository. Followed feeds stay in Miniflux.

3. **The browser fetches YouTube thumbnails, and nothing else from a third
   party.** That is accepted because the operator watches those channels on
   YouTube already, so what the image requests tell Google is already known
   to it. Icons are vendored instead: Apache-2.0 SVGs from
   `homarr-labs/dashboard-icons`, under `glance/assets/icons` with a NOTICE,
   served by Glance itself. NBA logos are left out for the same reason. This
   supersedes decision 6.

4. **Homelab status comes from Prometheus, not from Glance.** `trinity`
   cannot reach VLANs 30 and 40, so a direct check of a console there would
   always read down. Uptime is the blackbox probes' `probe_success`, now and
   averaged over 24 hours and 7 days.

   Memory leaves out ZFS's ARC, which counted showed smaug at 90%. Pool space
   is erebor's free bytes, as Homepage reads it, because node_exporter sees
   only the root dataset's own usage. Saruman's VMs say when Saruman was last
   heard from, instead of showing zeros.

5. **No Jellyfin stream count, for now.** It would need a pass from
   `trinity` to `smaug:8096` and a Jellyfin API key on this page. That is a
   firewall decision of its own, not a side effect of a dashboard. The page
   shows Jellyfin's container state from smaug's collector instead.

6. **Unchanged from ADR-0098:** no login, no Docker socket, read-only with
   no tmpfs, credentials scoped to query or to one Miniflux user. CI runs
   Glance's own `config:validate`, now on the whole directory, with the
   seeded validation values.

## Consequences

- **More outbound fetches from VLAN 99**, all server-side and on Glance's
  cache schedule: Yahoo Finance for the tickers, ESPN's scoreboard, GitHub's
  search and releases APIs (unauthenticated, well inside the anonymous
  limits at an hour and six hours), YouTube's feeds, more of Reddit, and
  uselessfacts.
- **YouTube's feeds fail now and then.** On 2026-10-21 every form of the feed
  URL answered 404 from `trinity`
  ([glanceapp/glance#910](https://github.com/glanceapp/glance/issues/910) is
  open). A tab whose channels all fail shows an error until the next fetch
  that works.
- **Editing the lists is a secrets edit.** That is clumsier than editing a
  YAML file, and it is the price of a public repository. The stack README
  and the example file give the shape of each list.
- **Two copies of the console list.** Homepage's tiles and Glance's
  bookmarks both list the estate's consoles. A console that moves is changed
  in both, as the blackbox targets already are.
- **yamllint sees fragments.** The page files have no `---` and use anchors
  defined in `glance.yml`, so `.yamllint.yaml` exempts that directory from
  those two rules alone. The combined document is checked by Glance itself.
- **Measured:** 13–14 MiB with both pages loaded, read-only, CapEff 0. The
  memory ceiling rises from 64m to 96m for large Reddit or Fever answers.
