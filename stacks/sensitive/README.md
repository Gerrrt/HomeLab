# Sensitive stack

ADR-0008's sensitive tier — the household's password manager, photos, documents
and home automation — on `trinity` (`10.0.99.40`, Winterfell / VLAN 99), the
ProDesk 600 G4 that [ADR-0034] made the tier's host after the firewall restore
was rehearsed on it. **Deployed there since 2026-09-28**, built by
[`build-the-sensitive-tier-host.md`](../../docs/runbooks/build-the-sensitive-tier-host.md)
under [#404]. It was authored ahead of the hardware, the way `stacks/lab` was, and
the first start found five things that the file could not show; the sections
below carry each of them. **It holds real data since 2026-09-28** — Immich's
first 615 photographs, which arrived before the off-estate copy that #404 step
10 gates them on; [*What backs Immich up*](#what-backs-immich-up-and-what-does-not-yet)
says what that leaves exposed.

```bash
make up STACK=sensitive
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| caddy | `caddy` | 443 (https) | The tier's published HTTPS port. Terminates TLS, routes by name to every service behind it ([#129]) |
| step-ca | `smallstep/step-ca` | *internal* (9000) | The tier's certificate authority — a root of its own with an intermediate beneath it, issuing to Caddy over ACME ([#130], [ADR-0037]) |
| home-assistant | `ghcr.io/home-assistant/home-assistant` | *internal* (8123) | Home automation, and what the `99 → 20` rule exists for — one pass, to the Hue bridge, scoped by [ADR-0035] ([#134]) |
| adguard | `adguard/adguardhome` | 53 (dns), on `10.0.99.40` only | The house's DNS filter, and since 2026-09-28 the **only** forwarder behind Unbound on `morpheus` ([ADR-0055], which replaces the fallback half of [ADR-0010]). It is never a client-facing resolver, and if it stops, outside names stop for the whole house. The one port besides Caddy's, published to the firewall's forwarder and the blackbox prober and answered for nothing else; the UI is behind Caddy at `adguard.matrix.elysium` ([#135]) |
| immich-server | `ghcr.io/immich-app/immich-server` | *internal* (2283) | The photo library — API and job workers in one container, reached as `https://immich.matrix.elysium` through Caddy ([#132]) |
| immich-machine-learning | `ghcr.io/immich-app/immich-machine-learning` | *internal* (3003) | Smart search, face detection and OCR for the server above. Behind the `ml` profile, on by default ([#132]) |
| immich-db | `ghcr.io/immich-app/postgres` | *internal* (5432) | Immich's Postgres, with VectorChord preloaded, on the internal SSD ([#132]) |
| immich-valkey | `valkey/valkey` | *internal* (6379) | Immich's job queue. Nothing durable — a tmpfs, rebuilt from the database on restart ([#132]) |
| paperless | `ghcr.io/paperless-ngx/paperless-ngx` | *internal* (8000) | The document archive: scan, OCR, index. On this tier by content — tax returns, passports, medical records — and the service [ADR-0023] classes as *durable* ([#133]) |
| paperless-db | `postgres` | *internal* (5432) | Paperless-ngx's own database. Metadata about documents; the documents themselves are files under `paperless-media` |
| paperless-broker | `valkey/valkey` | *internal* (6379) | Paperless-ngx's task queue and cache — the one volume in this stack whose loss costs nothing |
| vaultwarden | `vaultwarden/server` | *internal* (8080) | The household's password manager, at `https://vaultwarden.matrix.elysium` — Bitwarden's own clients and extensions, pointed at that URL ([#131]) |
| memos | `neosmemo/memos` | *internal* (5230) | The household's quick notes, at `https://memos.matrix.elysium`. Notes, not documentation — the second service beyond [ADR-0008]'s nine, by [ADR-0059] ([#145]) |
| homepage | `ghcr.io/gethomepage/homepage` | *internal* (3000) | The household's front page at `https://home.matrix.elysium`: what exists on the estate and where it lives, grouped by VLAN. A directory, not a status page — seven tiles read live numbers, with read-only tokens or from Prometheus; the rest are links ([#137]) |
| ntfy | `binwiederhier/ntfy` | *internal* (8080) | Where the estate's alerts arrive: Alertmanager on `prometheus` publishes to `https://ntfy.matrix.elysium` and the phones subscribe there. Deny-all, two declared users ([#136]) |
| miniflux | `miniflux/miniflux` | *internal* (8080) | The household's feed reader at `https://miniflux.matrix.elysium`, and the tier's first service beyond ADR-0008's nine ([ADR-0057], [#147]). It polls every subscription on a timer, so it is a steady source of outbound traffic from VLAN 99 |
| miniflux-db | `postgres` | *internal* (5432) | Miniflux's own database: subscriptions, read state, stars and entries |
| mealie | `ghcr.io/mealie-recipes/mealie` | *internal* (9000) | The household's recipes, meal plans and shopping list at `https://recipes.matrix.elysium`. Beyond ADR-0008's nine, decided by its own ADR, and **authored, not yet deployed** ([#146], [ADR-0060]) |
| linkding | `sissbruecker/linkding` | *internal* (9090) | The household's bookmarks, at `https://links.matrix.elysium`. One SQLite file, one account, no second factor. The fourth service beyond ADR-0008's nine ([ADR-0061], [#144]) |
| actual | `actualbudget/actual-server` | *internal* (5006) | The household's budget at `https://actual.matrix.elysium`: the sync server for Actual's local-first clients, password login only, no bank sync. The fifth service beyond ADR-0008's nine, after Miniflux, Memos, Mealie and linkding, by [ADR-0062] ([#142]) |
| stirling-pdf | `stirlingtools/stirling-pdf` | *internal* (8080) | The household's PDF editor at `https://pdf.matrix.elysium`: merge, split, sign, OCR, convert, so that none of it goes through a website. Keeps nothing, and its documents live only in memory ([#143], [ADR-0063]) |

Twenty-one services. Two are plumbing; Home Assistant and Vaultwarden are the first
household services and the shape every later one takes; AdGuard is the one the
household uses without ever knowing it; four are Immich, the service [ADR-0008]
names as the price of putting the tier on Winterfell at all; three are
Paperless-ngx, the archive of what the household cannot get back; Homepage
is the page that tells the household the rest exist; ntfy is the one the
estate uses, to tell the operator what is wrong with the rest; two are
Miniflux, the first of the tier extras, decided by an ADR of its own before it
was written here; Memos is the second; Mealie is the third, the one the
household is meant to open for its own sake; linkding is the fourth; Actual
is the household's budget, the fifth; and Stirling-PDF, the sixth, is the one
that keeps nothing. What is absent is as deliberate as what
is here:

- **No Prometheus, Loki or Grafana.** The lab has its own because its
  telemetry must never reach VLAN 99 ([ADR-0007]); this host *is* on VLAN 99,
  so it is watched the way `oracle` is — an Alloy agent shipped by
  `scripts/deploy-agent.sh`, pushing to `10.0.99.20`, needing no new rule and
  no new port. The agent is not in this compose file for the same reason it is
  not in the lab's: it is the estate's, deployed identically everywhere.
- **No other services planned.** The next one, whenever it comes, arrives as
  Home Assistant, Immich, Paperless-ngx, Vaultwarden, Homepage, ntfy,
  Miniflux, Memos, Mealie, linkding, Actual and Stirling-PDF did — and, beyond
  ADR-0008's nine, after an ADR of its own, as [ADR-0057], [ADR-0059],
  [ADR-0060], [ADR-0061], [ADR-0062] and [ADR-0063] were for the last six: a
  service with
  `expose:`, a block in the `Caddyfile`, a name on the leaf and in the resolver,
  its credential in SOPS where it takes one from outside, and a sentinel for its
  volume in `scripts/backup-volumes.sh`. A service in this file with `ports:`
  of its own is the one thing a review of it should refuse — AdGuard is the
  single argued exception, and `compose.yaml` makes the argument at DIFFERENCE 7
  so that the next one has to be made too.
- **No shared database.** Immich, Paperless-ngx and Miniflux each run a
  Postgres of their own — Immich's needs the vector extension and therefore a different
  image — and one database per service is what lets `backup-volumes.sh`
  attribute every volume to the one service that owns it and stop only that.
- **No Supervisor, no add-ons, no MQTT broker, no Zigbee coordinator.** Home
  Assistant *Container* has no add-on store, which is why it was chosen: an
  add-on is a second package manager outside `compose.yaml` and outside digest
  pinning. What an add-on would have supplied becomes a pinned service here
  on the day a device needs it, and today none does — Ring is cloud, the Hue
  bridge is its own radio, the speakers are Wi-Fi. No USB radio means where
  `trinity` sits is not this service's concern.

## Layout

```text
compose.yaml               twenty services, one network, health-gated ordering
Caddyfile                  every route the tier serves; validated in CI
home-assistant/            configuration.yaml and packages/, mounted read-only
                           over the volume Home Assistant writes its state to
.env.example               non-sensitive tunables — edit this, not .env:
                             the library's mount point, and the ML switch
adguard/AdGuardHome.yaml   AdGuard Home's whole configuration, blocklists included
homepage/                  settings, services, widgets and bookmarks YAML and
                           custom.css — its whole configuration, mounted read-only
ntfy/server.yml            ntfy's settings; its users and access list come from SOPS
consume/                   untracked: drop a scan here and Paperless-ngx imports
                           and deletes it. Created by render-config.sh
export/                    untracked: where document_exporter writes. Likewise
```

Secrets are `secrets/sensitive.sops.yaml`, encrypted to this stack's own rule
in `.sops.yaml` — `trinity`'s key opens this file and nothing else of the
estate's (`secrets/sensitive.example.yaml` says why, and lists every key). The one file under
`certificates/` this stack reads is `tier-ca.pem`, the tier's root
certificate, written by `make tier-ca ARGS="--install …"` from the bundle
minted on the monitoring host; every leaf is obtained from step-ca at run
time and lives in Caddy's `/data` volume, never on disk here.

## Things worth knowing before editing

- **Caddy runs as root with one capability**, and every other container in
  the estate does not. `compose.yaml` measures why — the image's `/data` and
  `/config` are root-owned and a named volume inherits that — and names the
  command that re-checks the premise when the image moves. `cap_drop: [ALL]`
  plus `no-new-privileges` is what makes it acceptable; do not add capabilities
  to make something else work. step-ca keeps the same one capability for a
  different, also measured, reason: its binary ships with the
  `NET_BIND_SERVICE` file capability, and the kernel refuses to exec such a
  file against a bounding set without it — the first boot failed on
  `operation not permitted` before the process existed. It still runs as
  `1000:1000`.
- **No admin API.** `admin off` in the `Caddyfile` means a routing change is
  `make up STACK=sensitive`, which recreates the container, not `caddy reload`.
  The socket would have been unauthenticated and on the same network as every
  service it fronts.
- **step-ca is a CA of the tier's own, and its tree is not made here.** Not
  an intermediate beneath the estate's CA, which this file once claimed: that
  root carries `pathlen:0`, and a leaf beneath any intermediate of it fails
  `path length constraint exceeded` — measured, and decided in [ADR-0037].
  `make tier-ca ARGS=--mint` on the monitoring host mints the root and
  intermediate in this image and writes a bundle *without the root key*;
  `make tier-ca ARGS="--install …"` here populates the `step-ca-data` volume
  from it and writes `certificates/tier-ca.pem`. The image's entrypoint will
  not start without `config/ca.json`, and `DOCKER_STEPCA_INIT_*` is never
  set, because either would mint a root of its own. The key password is
  `STEPCA_PASSWORD` in SOPS, written to a private tmpfs at start and nowhere
  on disk. [`build-the-tier-ca.md`](../../docs/runbooks/build-the-tier-ca.md)
  is the procedure.
- **Every certificate is obtained over ACME, and every name is also an
  alias.** The `Caddyfile`'s `cert_issuer acme` block points at step-ca's
  directory and trusts the tier's root; leaves are seven days and Caddy
  renews them. step-ca validates the `tls-alpn-01` challenge by dialling the
  requested name on 443 from inside the compose network, so a name served in
  the `Caddyfile` must also appear under the `caddy` service's network
  `aliases` in `compose.yaml` — one line each, added together. A name with a
  block and no alias fails its first issuance with a DNS error at the CA.
- **The phones have to trust the tier's root.** The mobile app is the whole
  reason Immich was chosen over PhotoPrism ([#132]), and it talks to
  `https://immich.matrix.elysium` on a certificate a phone has never heard
  of. `certificates/tier-ca.pem` — the tier's root, not the estate's
  `ca.pem`, which vouches for nothing here ([ADR-0037]) — goes onto each
  phone as a user-installed root before the app is pointed at the server;
  Android's Immich app honours a user root, iOS needs the profile installed
  and then *enabled* under Certificate Trust Settings, which is the step
  people miss ([`build-the-tier-ca.md`](../../docs/runbooks/build-the-tier-ca.md)
  §6). Nothing about this changes when a leaf renews — the root is the same
  one.
- **Immich runs as the deploying user, and the library disk has to be owned
  by that user.** `immich-server` carries `${RENDER_UID}:${RENDER_GID}` the
  way Alertmanager does in the estate's stack, and writes only under
  `IMMICH_UPLOAD_LOCATION`; the format-and-chown of the USB disk is [#404]'s
  step, done once when the disk is prepared. The machine-learning container
  is the exception and runs as root with every capability dropped, for the
  measured reason `compose.yaml` gives: its image has no `/cache`, so the
  volume mounted there is created root-owned and nothing else could fetch a
  model into it. Both run read-only; the three places the two images write
  outside their volumes were found by running them, not by reading, and each
  is a `tmpfs` or an environment variable in `compose.yaml` with the finding
  beside it.
- **Machine learning is on, bounded, and one line from off.** `.env.example`
  sets `COMPOSE_PROFILES=ml`; blank it and `make up` starts five services
  instead of six. [#132] asked for the option because the ML is the most
  memory-hungry thing that will run in the estate, and [ADR-0034] chose a
  32 GB host over an N100 partly so that it need not be taken. A 4 GiB
  ceiling is what makes running it before there is data acceptable. If it
  is switched off, disable machine learning under *Administration ›
  Settings* too, or every upload queues jobs against a container that is not
  there.
- **The database password is set once.** Postgres reads `IMMICH_DB_PASSWORD`
  when it initialises its volume and never again; the server reads it on
  every connection. Rotating it in `secrets/sensitive.sops.yaml` therefore
  changes what the server sends and not what the database expects — `ALTER
  USER` inside the container is the other half, and `secrets/sensitive.example.yaml`
  says so beside the key.
- **80 is not published.** ADR-0012: a port is published when something
  off-host consumes it, and nothing consumes 80 — browsers on Hicks type
  `https`, and ACME's `tls-alpn-01` challenge runs over 443; the provisioner
  accepts no other challenge, and the `Caddyfile` disables the redirect
  listener Caddy would otherwise open on 80. A redirect is a later choice,
  made in `.env.example`, `compose.yaml` and the `Caddyfile` together.
- **Every routed name needs a host override.** `homeassistant.matrix.elysium`
  — and each name after it, `vaultwarden.matrix.elysium` included — has to be
  in `morpheus`'s resolver, pointed at `10.0.99.40`
  ([`add-a-host-override.md`](../../docs/runbooks/add-a-host-override.md)) —
  a name the resolver does not know never arrives. The certificate side is
  the alias bullet above, not a SAN: there is no leaf to put one on.
- **Home Assistant is an ordinary member of the network, not `network_mode:
  host`.** Upstream's example uses host networking and `privileged` for
  discovery and USB. Discovery is mDNS and SSDP, which are link-local, and
  every device it controls is on Skids, a VLAN away — nothing on 20 would be
  found from 99 however the container were attached. Devices are added by
  address, through the one pass [ADR-0035] writes down. It runs with every
  capability dropped, a read-only root and two tmpfs mounts, as root because
  the image has no other mode; `compose.yaml` numbers the differences.
- **Home Assistant's credentials are not in SOPS, and cannot be.** The Hue
  application key, the Ring token and everything else a config flow produces
  are written by Home Assistant into `/config/.storage`, inside the
  `home-assistant-config` volume. Nothing this repository renders can hand
  them in, so the volume is where the tier's most numerous credentials live,
  protected by [#404]'s disk-encryption decision and by the encrypted volume
  archive rather than by SOPS. [ADR-0035] records the deviation. A long-lived
  access token minted for another service goes in *that* service's SOPS file
  — none exists yet — and TOTP is enrolled at first login, as [#404] step 6
  says.
- **Automations are YAML in `home-assistant/packages/`, not the UI editor.**
  `configuration.yaml` is mounted read-only from this directory and loads the
  packages directory beside it; there is no `automations.yaml`, because the
  UI editor's include fails hard on a file that does not exist and the file
  is one Home Assistant writes rather than one this repository ships. The
  packages README says the rest. Integrations and devices are still added
  through the UI: a config flow has no YAML form.
- **Home Assistant's HTTP settings are seeded into its volume, not written in
  `configuration.yaml`.** Since 2026.9 they live in `.storage/http`. A YAML
  `http:` block is imported once, as a *pending* config that reverts to
  defaults unless an admin promotes it within five minutes, and from 2027.2 it
  is not read at all. The defaults trust no proxy. So the store is written
  before Home Assistant's first start by `scripts/seed-ha-http.sh`, which
  `make up STACK=sensitive` runs first. It writes the *stable* slot with
  `pending` empty, which Home Assistant runs as-is: no trial, nothing to
  promote. It builds the file in the pinned image, from Home Assistant's own
  schema and store version.
  - **A fresh volume is seeded.** Proved 2026-09-29 against the real
    `compose.yaml` under a throwaway project: a request with
    `X-Forwarded-For` from `172.28.99.2` got `302`, from `.3` got `400`, and
    an unseeded control got `400` from both.
  - **An existing store is never overwritten.** A restored volume brings its
    own `.storage/http` back, and a live one may have been changed in the UI.
    `make up` only checks it, and warns if it does not trust Caddy.
  - **`scripts/seed-ha-http.sh --check`** reads it without changing anything.
  - **`--force`**, with Home Assistant stopped, rewrites it. That is the fix
    for the one symptom this prevents: `400: Bad Request` on
    `homeassistant.matrix.elysium`, with *"your HTTP integration is not set-up
    for reverse proxies"* in its log, as on `trinity`'s first start on
    2026-09-28.
- **Caddy has a fixed address, `172.28.99.2`, for one reader.** Home
  Assistant's `trusted_proxies` names the proxy it will believe
  `X-Forwarded-For` from, and a Docker-assigned address is not a name.
  `seed-ha-http.sh` reads the address from `compose.yaml`'s one `ipv4_address:`, so
  the two cannot drift. The
  network's subnet is fixed for that one line and nothing else. Its
  `ip_range` keeps Docker's own assignments in `.128` and up, because Caddy
  starts last and on 2026-09-28 found `.2` already taken by Vaultwarden.
- **AdGuard's configuration is the tracked file, every time.** `compose.yaml`
  copies `adguard/AdGuardHome.yaml` into a tmpfs on each start, with the admin
  hash substituted from `ADGUARD_ADMIN_PASSWORD_HASH`. A blocklist enabled in
  the UI is enabled until the next restart; the one that lasts is a commit —
  the same rule the estate's dashboards live by ([ADR-0004]). Two settings in
  that file are the ones to know before touching it: `ratelimit: 0`, because
  every query arrives from one address and the default 20 qps would throttle
  the whole house; and `allowed_clients`, which is `morpheus` and the blackbox
  prober on `prometheus` and drops everything else without a reply.
- **The admin password is a bcrypt hash, made once.** `make hash-password`
  prompts for it — never an argument, never in history — and the hash is what
  goes into `secrets/sensitive.sops.yaml`. AdGuard cannot carry a second
  factor ([ADR-0022]), which `security.md` already records.
- **Port 53 is published on `10.0.99.40`, not `0.0.0.0`.** `.env.example`
  says why: the host's own stub resolver holds `127.0.0.53:53`, and a wildcard
  bind fails on it. The forwarder edit on `morpheus` that makes any of this
  matter is [`forward-dns-to-adguard.md`](../../docs/runbooks/forward-dns-to-adguard.md),
  and it is the whole client-side change.
- **Nothing converges this stack.** It is deployed by hand, from a checkout
  on `trinity` ([#533] is the change that would converge it). The one timer
  here is the nightly backup, `homelab-backup-sensitive`, which
  `make install-timers PROFILE=sensitive` installs. `make validate` on
  `trinity` fails until it is installed.
- **Memory limits are set from day one, and now a CPU ceiling too.** [#129]'s
  ask, and the one place this file departs from the lab's reasoning — a proxy
  and a CA have working sets a limit can be stated for without a machine to
  measure. Immich's four are ceilings rather than derivations, and
  `compose.yaml` says what was measured underneath them and when to
  re-derive. Paperless-ngx's were set before the box existed — `cpus: 4` of
  the ProDesk's six because OCR takes every core it is given for minutes, and
  `3072m` because upstream's floor is 2 GB for the whole install — and were
  first measured on the monitoring host on 2026-09-09 from the pinned images:
  747 MiB working set idle, 825 MiB consuming a one-page 200 dpi scan, 22
  processes. **On `trinity` on 2026-09-28** they held under a synthetic
  backlog — five one-page scans and one of 50 pages, all 300 dpi and
  image-only: a peak of 1716 MiB, no OOM kill, 3.0 cores at the busiest
  minute and 0.2 s throttled in total, 3 min 54 s for the 50 pages, and
  Vaultwarden through Caddy never slower than 19 ms meanwhile. Both limits
  stand. Re-derive from `container_memory_rss` once `trinity` has run a month.
- **Caddy joins the operator's group.** `gen-certs.sh` writes the leaf's key
  `0640`, owned by whoever ran it, and root inside a container that has dropped
  `CAP_DAC_OVERRIDE` is bound by that mode like any other uid — measured: the
  pinned image died on `key.pem: permission denied` until `group_add` carried
  `RENDER_GID`, the way the estate's Grafana already does ([#131]).

### Paperless-ngx in particular

- **It runs as the operator, with nothing left to escalate to.** Upstream's
  rootless form — `user:` set, no `USERMAP_*` — as `${RENDER_UID}`, the uid
  that ran `make up`, with `cap_drop: [ALL]`. Measured on the boot above:
  `CapEff` and `CapBnd` both zero, `NoNewPrivs` set, the migrations and the
  index rebuild ran, a scan dropped into `consume/` was OCR'd to PDF/A and
  deleted afterwards as that uid. That last step is why the uid is the
  operator's: `consume/` is a bind mount owned by whoever runs the stack, and
  a file put there over SSH by that user is removable only by them.
- **`init: false`, twice, in a stack whose default is `init: true`.** The
  estate's reason for a real init as PID 1 is an image whose PID 1 never calls
  `wait()`; Paperless-ngx's PID 1 is s6-overlay, which is an init, and refuses
  to be anything else — with `docker-init` in the slot the container exits at
  once with `s6-overlay-suexec: fatal: can only run as pid 1`. Valkey's
  entrypoint is `tini` for the same reason. One init each is enough.
- **Not `read_only`, on purpose.** OCR renders every page to an image under
  `/tmp/paperless` and the working set scales with the document; a tmpfs there
  is charged to the container's memory limit, so a long scan would arrive as
  an OOM kill instead of a slow consume. What the container writes outside its
  volumes, from `docker diff`: s6's state under `/run/s6` and that scratch
  directory, and nothing else.
- **The ingest path is the existing one.** The web UI and the mobile apps
  upload over 443, on the pass Hicks already has. A backlog goes in over SSH,
  which the same named list carries — `rsync` into `stacks/sensitive/consume/`
  on `trinity` and the consumer picks it up on inotify. No share is exported
  and no port is published for it, and a scanner's scan-to-folder would need
  both: [#133] flags that as a device with hard-coded credentials on this
  segment, worth its own decision before it is a `ports:` line here.
- **The superuser is created from the environment, once.** `PAPERLESS_ADMIN_USER`
  in `.env.example` and its password in SOPS, the `GRAFANA_ADMIN_*` shape. The
  variable never changes an existing account, so a rotation is done in the UI
  first and recorded in SOPS after. **Enrol TOTP on that account at first
  login** — Paperless-ngx carries its own, under the user's profile in the
  web UI — before a single real document arrives; that is [ADR-0022]'s floor
  for this service, and it is the floor the SSO deferral rests on.
- **Storage is not the constraint; the photo library is.** A scanned page is
  a few hundred kilobytes, stored twice — the original and a PDF/A copy — plus
  a thumbnail, so ten thousand pages is on the order of 5–10 GB. The ProDesk's
  512 GB holds that many times over; ADR-0034's second drive is for Immich.

### Backing Paperless-ngx up

An OCR index can be rebuilt; the originals cannot. `backup-volumes.sh` covers
both halves [#133] asks for, and it needed two things to do so: an entry per
volume in its sentinel table — the string that proves an archive holds *that*
volume, read off the volumes after the boot above — and one for every other
volume in this stack, none of which had one, so a stack backup here refused
on the first of them — [#428]'s first half, landed the same day as its second,
the age recipient the script picks, which [#131] moved to the stack's own
secrets file. On `trinity`:

```bash
STACK=sensitive make backup
```

That stops the three Paperless containers, archives `paperless-media` (the
originals, the PDF/A copies, the thumbnails — the part that cannot be
rebuilt), `paperless-db-data` (the database: tags, correspondents, every
document's metadata), `paperless-data` (the index and the classifier, both
rebuildable) and `paperless-broker-data` (the queue, disposable), verifies
each by its sentinel, and starts them again. A restore is
[`restore-the-sensitive-tier.md`](../../docs/runbooks/restore-the-sensitive-tier.md);
the Postgres sentinel carries the major version in its path, so a bump from 18
has to move it, loudly.

The version-portable form is the exporter — `docker compose exec paperless
document_exporter ../export`, into `export/` — which writes every document with
a `manifest.json` that a fresh install of the *same* version re-imports.
Upstream is explicit that an export does not cross versions, so it is the
form to send off-estate rather than the form to rely on across an upgrade.

One thing this does **not** do, stated rather than implied. It is
scheduled: `homelab-backup-sensitive` runs it nightly on `trinity` and copies
each set to `oracle` ([#404] step 9). But **nothing here is the off-estate copy**
[ADR-0023] requires before the first real document — encrypted, keyed to a
second holder, with visible freshness. That is the precondition on the data
arriving, not on the container starting, and it is still open.

## Vaultwarden

The vault, and the service [#131] was mostly not about deploying: *"a
password vault
is the one service here where 'it is running' and 'it is recoverable' are
entirely different claims, and only the second one counts on the day it
matters."* What the service does is in `compose.yaml`; what has to be true
around it is here.

- **Every capability dropped, and root.** The same measurement Caddy records —
  `/data` is root-owned in the image and a named volume inherits it — with one
  difference: `ROCKET_PORT` is `8080`, so there is no privileged bind and
  nothing to keep. Started under exactly the compose file's options before this
  was written: healthy, `/alive` and `/admin` answering, nothing written outside
  `/data`, under 10 MiB resident.
- **Sign-up is off from the first start.** [#131] said "after the two accounts
  exist"; there is no such window. Accounts are created by invitation from
  `/admin`, and with no SMTP configured the invited address registers itself at
  the vault — so no SMTP credential exists to protect, and nothing on Hicks can
  ever open an account of its own.
- **The admin token is a hash.** `VAULTWARDEN_ADMIN_TOKEN` in SOPS is an
  Argon2id PHC string, so `docker inspect` shows a hash where on Grafana it
  shows the password. Generate it from the pinned image, on any machine with
  docker:

  ```bash
  docker run --rm -it "$(COMPOSE_FILE=stacks/sensitive/compose.yaml ./scripts/image-for.sh vaultwarden)" /vaultwarden hash --preset owasp
  ```

  The string is five `$`-delimited fields, and compose reads a `$` in `.env`
  as a variable reference — written raw, the value reaches the container as
  `=19=65540,t=3,p=4` behind five warnings `make up` scrolls past.
  `render-config.sh` doubles every `$` on the way in; that was latent for every
  secret it writes, a Grafana password with a `$` in it included, and is fixed
  for all of them. The token itself is held nowhere in the estate. Keep it with
  the operator's other credentials: it is precisely the thing this vault cannot
  hold for you.
- **The name has its own certificate, and needs a host override.** The browser
  checks the certificate's SANs before Caddy sees a Host header, and
  `vaultwarden.matrix.elysium` gets a leaf of its own from step-ca because it
  is a site block in the `Caddyfile` and an alias on Caddy in `compose.yaml`
  (the alias bullet above). What it still needs from outside this stack is
  the host override
  ([`add-a-host-override.md`](../../docs/runbooks/add-a-host-override.md)).
- **TOTP on both accounts at first login.** [ADR-0022]'s floor — the thing
  [ADR-0008] offered *in place of* SSO, and the one service in the tier where
  that substitute exists and matters most. Settings → Security → Two-step login
  in the web vault, and the recovery code goes where the admin token goes.
- **Before it holds anything real, three things fall due at once**, and they
  are the same moment observed three times:
  1. A verified restore — [`restore-the-sensitive-tier.md`](../../docs/runbooks/restore-the-sensitive-tier.md),
     which also records what has already been rehearsed and what has not.
  2. [ADR-0022]'s decision recorded: an identity provider, or the deferral
     re-accepted with reasons.
  3. [ADR-0023]'s *Independent* class met: the household's own credentials
     recoverable without this vault, and opened once from the other person's
     device without the operator present. The recommendation there is that the
     family's vault is hosted Bitwarden and this one keeps the operator's.

## Memos

The household's notes, and the second *Tier extras* service —
[ADR-0059] decided it before it was written. What the service does is in
`compose.yaml`; what has to be true around it is here.

- **Notes, not documentation.** Nothing about rebuilding or recovering the
  estate lives in Memos as its home; `docs/` is that, and [#124] is a `docs/`
  problem. A note on `trinity` is exactly as down as `trinity` is.
- **Not root, and no capabilities.** The image's data directory is
  `10001:10001`, so it starts as that uid and skips the entrypoint's `chown`
  and `su-exec`. Measured on the pinned image with exactly the compose file's
  options: healthy on `/healthz`, a user created, an upload stored, 15 MiB
  resident.
- **Close registration at first login.** The first account registered becomes
  the admin, and sign-up is a setting in the database rather than the
  environment, so it cannot be closed from this file. Register the admin at
  `https://memos.matrix.elysium`, then as that admin set *disallow user
  registration* in the instance's general settings before anything else. The
  household's accounts are created from the admin settings after that. Check
  it held, on `trinity` — the setting is readable without logging in, and the
  line should contain `"disallowUserRegistration":true`:

  ```bash
  docker exec sensitive-memos wget -qO- http://127.0.0.1:5230/api/v1/instance/settings/GENERAL
  ```

- **Password only.** Memos has no TOTP. [ADR-0022] records the tier's other
  services without one, and [ADR-0059] puts Memos beside them.
- **Not one file.** The database is WAL-mode — while it runs, a fresh
  `memos_prod.db` is a 4 KB header and everything else is in the `-wal`, which
  a clean stop checkpoints back — and attachments are files under `./assets`.
  The backup names all three.
- **Durable, under [ADR-0023].** No real notes before the off-estate copy the
  class requires, for the same reason as Paperless-ngx.

## Homepage

The household's page, at `https://home.matrix.elysium` — the one address on
this tier that people who are not the operator are given. [#137] asked that it
stay honest about what it is, and the files under `homepage/` are where that
is kept:

- **A directory, not a status page.** No status dots, no `siteMonitor`, no
  `ping` (`settings.yaml` says why). Uptime is Grafana's question; a green dot
  that means "a socket opened" is worse than no dot. Grafana is linked from the
  page so the two are not strangers.
- **Household first, then the estate by VLAN.** *Household* — photos,
  documents, passwords, the house, Jellyfin and ntfy — comes first. Every
  other tile sits under its host's segment, in the order and with the rack
  colour of [`docs/network.md`](../../docs/network.md)'s table:
  *🔴 Winterfell · VLAN 99* (Grafana, Prometheus, AdGuard, the firewall, the
  UPS, the wiki) is open; *🟢 ImaginationLAN · VLAN 30* (Proxmox, iLO, the lab's
  Grafana, Wazuh, Velociraptor), *🟡 CasaBonita · VLAN 40* (the NAS) and
  *⚪ Switch LAN* start collapsed. Every console link is a login page Hicks
  already reaches through a named pass; listing it grants nothing. Below the
  tiles, `bookmarks.yaml` holds the house wiki and where to
  get each app. It is tracked because without it Homepage serves its own
  sample — GitHub, Reddit and YouTube, which the first deploy did.
- **Seven tiles read live numbers, and only with read-only credentials or
  none.** Immich (a key with the single permission `server.statistics`) and
  Paperless-ngx (the token of a view-only `homepage` user) are read from their
  own APIs. Prometheus, the UPS (charge, runtime, load), the firewall (pf
  states), the iLO (watts) and the NAS (pool free) are read from Prometheus,
  which has no credential ([#182]) and shares a /24 with `trinity`. That is how
  tiles on VLANs `trinity` cannot reach show numbers with no new rule:
  Prometheus already scrapes them, and each query is one a Grafana dashboard
  already runs. Numbers only, never up/down. Home Assistant, AdGuard, Vaultwarden and Grafana are links,
  because none of them can issue a token that reads without also being able to
  change something. `services.yaml` has the per-service reasoning.
- **Weather is the one third-party call, and a coarse one.** `widgets.yaml`
  has Open-Meteo (no key), fetched server-side from `trinity` over
  Winterfell's existing egress, for Bellevue rounded to one decimal place —
  about 10 km — because this repository is public.
- **Tokyo Night, frosted.** `custom.css` redefines the `slate` palette that
  `settings.yaml` names and draws a gradient behind translucent cards
  (`cardBlur: md`); no image or font is fetched. It is tracked and mounted for
  the bookmarks reason: without it Homepage serves its own (empty) sample. Its
  selectors come from the pinned bundle, not a documented contract, so a
  Dependabot bump is where to look if the cards go flat.
- **No Docker socket**, although upstream's example mounts one — the full
  Docker API behind a page with no login ([ADR-0022]). `compose.yaml` says so
  at the service.
- **Deploy order.** The two tokens can be minted only once Immich and
  Paperless are up, and the compose guards refuse `make up` until both are in
  SOPS — so: mint them (`secrets/sensitive.example.yaml` has the clicks),
  `make secrets-edit STACK=sensitive`, add the host override for
  `home.matrix.elysium` on `morpheus`
  ([`add-a-host-override.md`](../../docs/runbooks/add-a-host-override.md)),
  then `make up STACK=sensitive`.
- **Measured before it was written**, on `trinity`, from the pinned digest with
  exactly the compose options: healthy, CapEff 0, nothing written outside its
  tmpfs mounts, 101 MiB and 12 tasks; with placeholder tokens the Immich and
  Paperless widgets got a 401 from the real services through Caddy and the tier
  CA, which is the whole path short of a valid token.

## ntfy

Where the estate's alerts are delivered since [#136], replacing ntfy.sh for
every channel but two. `compose.yaml` has the service, its measurements, and
DIFFERENCE 12. [`verify-the-alert-path.md`](../../docs/runbooks/verify-the-alert-path.md)
has the routing it serves and the cutover. What has to be true around it is
here.

- **Deny-all, and two users who can each do one thing.** `alertmanager`
  publishes to the three topics by bearer token and cannot read them. `phone`
  reads them by password and cannot publish. Nobody else can do either,
  anonymous or not, and nobody can sign up. The list lives in SOPS and is
  applied on every start, so a rotation is `make secrets-edit STACK=sensitive`
  and `make up`. Rotating the token means the monitoring host's copy too,
  `ALERTMANAGER_NTFY_TOKEN`.
- **Urgent and security go to ntfy.sh as well.** A phone off the home network
  cannot reach this service: nothing on the tier is exposed, and the WireGuard
  path goes to the lab. So the two channels that page carry a second webhook to
  their old ntfy.sh topics. `default` does not, and a warning raised while you
  are out waits in the twelve-hour cache until the phone is back on Wi-Fi.
- **The iPhone is woken through ntfy.sh, and learns nothing else from it.**
  iOS delivers only through APNs, which only ntfy.sh can reach. So
  `upstream-base-url` makes this server post a content-free poll request there:
  the SHA-256 of the topic's URL, and nothing else, as the pinned image's own log
  showed. The phone then fetches the message from here. ntfy.sh therefore
  learns that a message exists, and when. It never learns what the message
  says, and without this the iPhone sees an alert only when the app is opened.
- **The phones need the tier's root, the same as for Immich.** Each phone
  needs the root installed and, on iOS, enabled
  ([`build-the-tier-ca.md`](../../docs/runbooks/build-the-tier-ca.md) §6).
  Then, in the ntfy app on each phone:
  1. Add the three in-house topics, with server
     `https://ntfy.matrix.elysium` and user `phone`. The password is in the
     password manager; the topic names are in `secrets/sensitive.sops.yaml`.
  2. Keep the two ntfy.sh subscriptions. They are the off-network pager.
  3. On iOS, leave the app's *default server* at `ntfy.sh`. The upstream
     wake-ups arrive through it.
  4. Give `urgent` a sound that wakes you and `default` none. That per-topic
     difference is why [#66] split the channels.

  Android's app has to honour a user-installed root for the first step to
  work, and it does: on 2026-09-28 the Pixel (Android 13) subscribed with the
  tier's root installed under *Encryption & credentials › CA certificate* and
  no setting in the app, and both phones received a test message published
  with Alertmanager's token.
- **A dead ntfy is reported through ntfy.sh.** A blackbox probe of
  `/v1/health`, verified against the tier's root, raises `EndpointUnreachable`,
  and the failed deliveries raise `AlertmanagerNotificationsFailing`. Both are
  critical, so both route to `urgent` and its ntfy.sh copy. The probe is the
  only HTTPS check any of this tier's sites has from outside.
- **Nothing to back up.** `ntfy-data` holds `user.db`, rebuilt from SOPS on
  every start, and `cache.db`, at most twelve hours of notifications that were
  already delivered. [ADR-0023] classes ntfy as unclassed for the same reason.
  `backup-volumes.sh` skips the volume by name, which also keeps ntfy up
  through a backup, the moment a failed backup would want to page.
- **Alerts arrive as a title and a line.** `ntfy/templates/homelab.yml`
  renders each Alertmanager payload with a severity marker and the summary as
  the title, the description's first sentence and the host as the message,
  and a priority that follows severity. Critical is 5, which on Android is the
  loud channel and on iOS is time-sensitive. The full text stays in
  Alertmanager and Grafana. The ntfy.sh copies look the same. ntfy.sh
  cannot load a template file, so `render-config.sh` on the monitoring host
  passes this one inline, as URL parameters built from the file at every
  render. Change the file and `make render` there as well as `make up` here.
- **No second factor.** ntfy has passwords and tokens. The only human account
  is `phone`, which can read three topics of alert text and nothing else.
  [ADR-0022] leaves ntfy out of its table for that reason: it authenticates no
  household identity.

## Miniflux

The household's feed reader since [#147], and the first service on this tier
that [ADR-0008] did not name. [ADR-0057] decided it before it was written:
the placement, the outbound traffic, and why the account has no second
factor. `compose.yaml` has what was measured on the pinned image.

- **Adding it to the running tier.** `trinity` was built before Miniflux was
  written, so it arrives as a later service does rather than by
  [`build-the-sensitive-tier-host.md`](../../docs/runbooks/build-the-sensitive-tier-host.md),
  which carries it for a rebuild. On `trinity`:
  1. `make secrets-edit STACK=sensitive`, and add `MINIFLUX_DBPASS` and
     `MINIFLUX_ADMIN_PASSWORD`, each from `make gen-secret`. The admin
     password goes in the password manager too. Commit the encrypted file.
  2. On `morpheus`, add `miniflux` to `trinity`'s *Additional Names for this
     Host* ([`add-a-host-override.md`](../../docs/runbooks/add-a-host-override.md)).
  3. `make up STACK=sensitive`. Caddy is recreated for its new alias and
     site block, and step-ca issues the name's leaf on the first request.
  4. `make backup STACK=sensitive ARGS=--list` after the next nightly run:
     `miniflux-db-data` is in the set.
- **First login.** Sign in at `https://miniflux.matrix.elysium` as
  `MINIFLUX_ADMIN_USER` (`admin` by default), with `MINIFLUX_ADMIN_PASSWORD`
  from SOPS. The account is created on the first start and never touched by
  the variable again. Rotate the password under *Settings*, or from the
  host if the UI is lost:

  ```bash
  docker exec -it sensitive-miniflux /usr/bin/miniflux -reset-password
  ```

  Then record the new value in `secrets/sensitive.sops.yaml`, the way
  Paperless's admin password is kept.
- **No second factor, and none to enrol.** Miniflux has no TOTP. Its passkeys
  (`WEBAUTHN`) are a second way to log in, not a second step — the password
  still logs in on its own — so they are left off. The one route to a factor
  is its OpenID Connect login, which waits on the identity provider [ADR-0022]
  keeps deferring. `docs/security.md` names Miniflux beside Immich and AdGuard
  for that reason.
- **The REST API is off.** It accepts the admin's own password over basic
  auth, which would be a second door to the account that nothing here uses.
  With it off, Homepage's tile is a link rather than an unread count.
- **The sync APIs stay off until a phone wants them.** Fever and Google
  Reader are what third-party mobile clients speak. Each is turned on per
  user under *Settings › Integrations*, with a username and password of its
  own that bypasses the login page. Turning one on is [ADR-0057]'s decision 5:
  use a generated password, keep it in the password manager, and record here
  which client and when.
- **It reaches outward all the time, and never inward.** Every subscription
  is fetched on a timer (`POLLING_FREQUENCY`, sixty minutes by default), so
  this container is a steady source of outbound HTTPS from VLAN 99 on the
  firewall's graphs. The fetcher refuses every private, loopback and
  link-local address after DNS, so a feed URL cannot be pointed at the
  gateway, step-ca or anything else on Winterfell.
- **Export the subscriptions now and then.** `miniflux-db-data` is in the
  nightly set, and an OPML export is the portable half that survives a
  version the database cannot come back to:

  ```bash
  docker exec sensitive-miniflux /usr/bin/miniflux -export-user-feeds admin > miniflux-feeds.opml
  ```

  It is a reading list, not a secret. Keep it with the household's documents
  rather than in git.

## Mealie

The household's recipes, at `https://recipes.matrix.elysium`. It is on this
tier because the phones that use it are on Hicks, not because recipes are
sensitive ([ADR-0060]). Reaching it needs no rule beyond the `443` Hicks
already has.

- **Root with every capability dropped, as Vaultwarden runs.** `/app/data` is
  root-owned in the image. `PUID=0` and `PGID=0` make the entrypoint's
  user-switch a no-op, so it neither `chown`s nor `gosu`s. Measured before this
  was written, under exactly the compose file's options: healthy, a login
  answered, three recipes imported by URL, and nothing written outside
  `/app/data`. It used 224 MiB idle and 396 MiB at the peak.
- **SQLite, no database container, no SOPS secret.** The signing secrets are
  generated into the volume on the first start and backed up with it. The admin
  password is a hash in the database.
- **Sign-up is off from the first start.** The registration endpoint answers
  `403`. Accounts are made by the admin, and are for the two people ADR-0008
  assumes. A third person's account is [ADR-0022]'s trigger 3.
- **No second factor exists**, so there is none to enrol. [ADR-0060] records
  it beside Immich and AdGuard. OIDC is the route, the day an identity
  provider exists.
- **The first login is the default admin**, `changeme@example.com` /
  `MyPassword`, and it must be renamed and re-passworded before anyone else
  is told the address
  ([`build-the-sensitive-tier-host.md`](../../docs/runbooks/build-the-sensitive-tier-host.md#deploy-a-later-service)).
  Forgotten afterwards, the image's own script resets it on the running
  container:

  ```bash
  docker exec -it sensitive-mealie python3 \
    /opt/mealie/lib/python3.14/site-packages/mealie/scripts/change_password.py
  ```

  The path names the image's Python version. If a bump moves it,
  `docker exec sensitive-mealie find /opt/mealie -name change_password.py`
  finds it.
- **URL import fetches the page a user pastes**, from `trinity`, over
  Winterfell's existing egress, and never inward. Its `safehttp` transport
  refuses private, loopback and link-local addresses after DNS. That was
  measured against a container on this network, `10.0.99.1` and
  `10.0.99.20`, and no request arrived. `HTTP_ALLOW_LIST` is the one setting
  that opens it, and `compose.yaml` writes it out empty. Adding a host to it
  is a hole into Winterfell.

## linkding

The household's bookmarks, at `https://links.matrix.elysium` ([#144]). It is
the fourth service here that [ADR-0008] does not name, and [ADR-0061] is the
decision that put it on this tier. `compose.yaml` has the service and what was
measured on the pinned image. What has to be true around it is here.

- **Root for the bootstrap, uid 33 for everything that serves.** The image's
  `bootstrap.sh` runs as root, migrates, creates the superuser, and chowns the
  volume to `www-data`. Then uwsgi drops to 33. It keeps four capabilities out
  of `ALL` for that half and holds none afterwards. `compose.yaml` says what
  each one is for, including the one that only matters on the second start:
  without `DAC_OVERRIDE`, a migration fails and the container still reports
  healthy.
- **One account, and nobody signs up.** linkding has no self-registration. The
  superuser is created on first start from `LINKDING_SUPERUSER_NAME` in `.env`
  and `LINKDING_SUPERUSER_PASSWORD` in SOPS. After that, the variables do
  nothing, so a rotation is done in linkding's settings and recorded in SOPS
  afterwards. A second person's account is made in `/admin`, and it counts
  toward [ADR-0022]'s third trigger like any other account on the tier.
- **No second factor.** linkding has none of its own. It offers OIDC, or trust
  in a proxy header, and neither exists here yet. It sits with Immich,
  AdGuard Home, Miniflux, Memos and Mealie in `security.md`'s list of
  services that cannot carry one.
  [ADR-0061] records why that is accepted for a list of links, and that OIDC is
  how it would get one if [ADR-0022]'s decision brings an identity provider.
- **No favicons, on purpose.** `LD_DISABLE_BACKGROUND_TASKS` keeps linkding
  from asking a third party for an icon for every site in the list. Adding a
  bookmark still fetches that page's own title and description.
- **Archiving pages is not what this is.** The `-plus` image, with Chromium,
  would save snapshots. [ADR-0061] leaves that want to a different service and
  a new decision.
- **Adding it to the running tier**, as Miniflux is added. On `trinity`:
  1. `make secrets-edit STACK=sensitive`, and add `LINKDING_SUPERUSER_PASSWORD`
     from `make gen-secret`. It goes in the password manager too. Commit the
     encrypted file.
  2. **Done 2026-09-29.** `links` is one of `trinity`'s *Additional Names for
     this Host* on `morpheus`
     ([`add-a-host-override.md`](../../docs/runbooks/add-a-host-override.md)).
     It answered `10.0.99.40` from `morpheus` that day, with the reverse entry
     still `trinity`. Until step 3, HTTPS to it fails at the handshake: the
     running Caddy has no site for the name yet.
  3. `make up STACK=sensitive`. Caddy is recreated for its new alias and site
     block, and step-ca issues the name's leaf on the first request.
  4. `make backup STACK=sensitive ARGS=--list` after the next nightly run:
     `linkding-data` is in the set.
- **Backed up with the tier.** `linkding-data` is archived nightly with the
  other volumes. The sentinel is `secretkey.txt`, because `db.sqlite3` is
  already Vaultwarden's. The database and its `-wal` are reported beside it.
  A restore without the key logs everyone out, and loses nothing else. A Netscape HTML export from linkding's settings
  also imports into any browser, which makes it a copy nothing here is needed
  to read.

## Actual

The household's budget ([#142]), and the fifth service here beyond [ADR-0008]'s nine, after Miniflux,
Memos, Mealie and linkding.
[ADR-0062] is the decision and why it is Actual rather than Firefly III.
`compose.yaml` has the service and what was measured on the pinned image.
What has to be true around it is here.

- **Claimed before it is reachable.** Actual has no password setting. A fresh
  server offers "set a password" to the first client that reaches it, and
  accepts the answer once. `make up` runs `scripts/seed-actual-password.sh`
  first. It claims an empty volume with `ACTUAL_SERVER_PASSWORD` from SOPS,
  inside the pinned image with `--network none`, before the service ever
  starts, and on every run after that it logs in with the SOPS value as a
  check. The value is never handed to the container, so `docker inspect`
  does not show it and it is not in `.env`. `--check` checks the running
  service and changes nothing.
- **One password for the household, and one session for every device.** In
  password mode Actual has a single user. Every device that logs in is handed
  the same session token, and by default it never expires. Measured on
  26.9.0: a changed password leaves that token valid, so every device stays
  signed in. To sign every device out, stop the service, delete the sessions,
  and start it again:

  ```bash
  docker compose -f stacks/sensitive/compose.yaml stop actual
  docker run --rm --network none --user 1001:1001 --read-only --cap-drop ALL \
    -v sensitive_actual-data:/data --entrypoint node \
    "$(COMPOSE_FILE=stacks/sensitive/compose.yaml ./scripts/image-for.sh actual)" \
    -e "console.log(new (require('better-sqlite3'))('/data/server-files/account.sqlite').prepare('DELETE FROM sessions').run().changes)"
  make up STACK=sensitive
  ```

  It prints the number of sessions deleted (one). The old token then gets
  401, and the next login is issued a new one. Measured on a throwaway volume.
- **Changing the password.** Change it in Actual (*Settings › Change
  password*), or on `trinity` with
  `docker exec -it sensitive-actual node src/scripts/reset-password.js`, which
  needs a terminal. Then put the same value in SOPS. Change SOPS alone and the
  next `make up` warns that the SOPS password no longer logs in, and changes
  nothing. Follow a change made because the password leaked with the sign-out
  above.
- **Password login only.** `ACTUAL_ALLOWED_LOGIN_METHODS` is `password`.
  Header login would take the password in a header from any "trusted proxy",
  and the image trusts every private range by default. OpenID would be
  [ADR-0022]'s decision. Logins and the first-run claim allow five failures per
  client per fifteen minutes, and `ACTUAL_TRUSTED_PROXIES` names Caddy alone,
  so the client counted is the phone rather than the proxy.
- **No bank sync.** GoCardless and SimpleFIN are configured in the app, and
  neither is. Transactions come in as imported files (OFX, QFX, QIF, CSV,
  CAMT). Turning bank sync on is a decision ([ADR-0062] §4). It puts a third
  party's credentials in `account.sqlite` and has the server reach out on a
  schedule.
- **Clients are a copy, not a backup.** Every client holds the whole budget,
  which survives losing this server. It does not survive a bad sync, which
  arrives on every client. The nightly set archives `actual-data` with the
  service stopped. The sentinel is `./server-files/account.sqlite`, and the
  budgets are in `./user-files`.
- **Durable, and no second factor.** [ADR-0023] classes Actual with Immich
  and Paperless-ngx: it may be down, it may not be lost. [ADR-0022]'s table
  has it among the services with no second factor. Actual has none short of
  OpenID.
- **The name needs a host override.** `actual.matrix.elysium` is a site block
  in the `Caddyfile` and an alias on Caddy, so step-ca issues it a leaf. The
  override on `morpheus` is
  [`add-a-host-override.md`](../../docs/runbooks/add-a-host-override.md)'s.

## Stirling-PDF

The household's PDF editor since [#143]. It does the jobs that otherwise go to
a free converter website: merge, split, rotate, convert, OCR, sign, compress.
[ADR-0063] is the decision. `compose.yaml` has the service, the measurements
and DIFFERENCE 13. What has to be true around it is here.

- **Documents never reach a disk.** Uploads, intermediates and results live in
  `/tmp`, a 1 GiB tmpfs counted against the container's 3 GiB limit.
  Stirling deletes a job's files when the job ends, sweeps anything a failed
  job left every ten minutes, and a restart erases the rest. The one volume,
  `stirling-pdf-configs`, holds accounts and settings. If a document ever
  turns up there, something has gone wrong.
- **A big enough job fails instead of spilling.** A scan that fills the
  tmpfs, or an OCR that pushes the container past its limit, fails with an
  error, and the fix is to split the document. Caddy refuses uploads over
  256 MB before they reach it. On 2026-09-29 a 40-page 300 dpi OCR peaked at
  1.4 GiB. No household document is near the limit.
- **The admin comes from SOPS, once.** `STIRLING_ADMIN_USER` in `.env.example`
  and `STIRLING_ADMIN_PASSWORD` in SOPS, read on the first start against an
  empty volume and never again. A rotation is done in the UI first and
  recorded in SOPS after. SOPS matters here more than for Paperless, because
  the volume is not backed up and a rebuild recreates the admin from it.
  **Enrol TOTP at first login**, in the account settings, before the first
  real document. Stirling marks the seeded admin as MFA-required. That is
  [ADR-0022]'s floor.
- **Nothing phones home, and the hardening was checked, not just set.**
  Analytics, PostHog, Scarf, the update check, URL-to-PDF, the AI engine and
  the mobile QR upload are off. CORS is pinned to the one name, and the heap
  dump on OOM is off because it would write a document to `/configs`. The
  running app's `/api/v1/config/app-config` showed each of these on a boot
  with no route out.
- **Its hardening had two costs, both found by running it.**
  - The entrypoint `ln -s`es diagnostics shortcuts into `/usr/local/bin`
    under `set -e`, which kills the container on a read-only root. `/dev/null`
    mounted over the script it links makes it skip that step.
  - The PDF engine unpacks shared libraries into `/tmp`, so that tmpfs is
    `exec`. Without it the container is healthy and every pdfium tool
    answers 500, which is why CI and the check below run a tool rather than
    trusting the healthcheck.
- **LibreOffice runs sandboxed, as the same uid.** The service starts as
  `stirlingpdfuser` (1001), so the entrypoint cannot give LibreOffice a uid of
  its own. It keeps its Landlock and seccomp sandbox, and
  `STIRLING_LO_SANDBOX=required` refuses a conversion on a kernel that cannot
  provide it. Its startup log line says which: *"LibreOffice sandbox active
  (lo-sandbox: landlock ABI 8, seccomp active)"*.
- **Nothing to back up.** `backup-volumes.sh` skips the volume by name, and
  [ADR-0023] classes the service as unclassed. A rebuild costs the admin a
  TOTP re-enrolment.

CI does this on every change to the service or its image.
[`stirling-pdf/smoke.sh`](stirling-pdf/smoke.sh) runs after the hardened boot:
it logs in as the seeded admin, merges two pages through pdfium, and fails on
anything but a PDF back. On `trinity`, after a deploy, do the same by hand:
merge two PDFs in the UI, then

```bash
docker logs sensitive-stirling-pdf 2>&1 | grep -E 'sandbox active|UnsatisfiedLink'
```

The first line should appear; the second should not.

## Backup and restore

```bash
make backup STACK=sensitive
make restore STACK=sensitive ARGS="--dry-run --from latest"
```

`backup-volumes.sh` derives the volume list from `compose.yaml` and refuses a
volume it cannot verify, so each of the fifteen volumes it archives has a
sentinel entry there — `db.sqlite3` for Vaultwarden and `memos_prod.db` for
Memos, each read off a boot of the pinned image, beside the entries [#133]
read off boots of every other — and
`restore-volumes.sh` knows the uid each must come back owned by where that
uid is a constant. Three are skipped by name. `ntfy-data` is skipped because
ntfy rebuilds its users from SOPS on every start and its cache is notifications
already delivered. `adguard-work` is skipped because
archiving it would stop the house's only DNS forwarder, and nothing in it is
worth restoring. `immich-model-cache` is skipped because a
downloadable cache is not data, and a fresh host whose models have not been
fetched yet would otherwise fail the whole run on an empty archive. Both
scripts encrypt to **every recipient of
`secrets/sensitive.sops.yaml`**, read from the file itself: `trinity`'s key,
and the technical second's once it joins the rule. Until [#131] they took the
first key in `.sops.yaml` whichever rule it belonged to, which would have
encrypted the estate's weekly backup to `trinity`'s key the day the placeholder
was filled — the two defects [#428] describes.

**When it runs, and where the sets go.** `homelab-backup-sensitive` runs it
every night at 04:30 ([#404] step 9). Each set is copied to `oracle` and
checked there by sha256 ([#535]). The run's outcome is the `backup-sensitive`
job in the estate's `ScheduledJob*` alerts, with a two-day threshold. The
unit and its installer are in
[`schedule-maintenance.md`](../../docs/runbooks/schedule-maintenance.md#on-trinity-the-sensitive-profile).
What this does **not** give is a copy off the estate. `oracle` is in the same
room and on the same power, and [ADR-0023] requires that copy before Immich or
Paperless-ngx hold a real file. It is step 10's.
And the volumes are not the photographs: the library is a bind mount, and
no set contains it.

## What backs Immich up, and what does not yet

The photographs are the household data most likely to be irreplaceable, and
[ADR-0023] classes Immich as *durable*: it may be down, it may not be lost,
and an off-estate copy whose staleness is visible was to exist before the
first real photo arrived. It did not; the warning below is the record. Three
things hold the data, and they are protected by two different mechanisms —
one of which, the off-estate copy that covers the first two rows, does not
exist yet.

> [!WARNING]
> **The first real photographs arrived before that copy did.** Two accounts
> uploaded 615 assets between 16:59 and 17:01 UTC on 2026-09-28 — the day the
> host was built, with [#455] undelivered and [ADR-0022]'s record and
> [ADR-0023]'s *Independent* test still open. Until [#455] exists, the USB disk
> is the only copy of the originals anywhere. The restore below proves the
> metadata comes back; it cannot bring back a photograph that is on no other
> disk.

| What | Where | Protected by |
| --- | --- | --- |
| The originals, thumbnails and transcodes | `IMMICH_UPLOAD_LOCATION` — the USB disk | The off-estate copy [ADR-0023] requires. **Not built**: its destination, a WD Elements 5 TB, was bought on 2026-09-22 under [#455] and has not been delivered. [ADR-0023] made it the precondition on the first real photo; the photos came first, as the warning above records |
| Immich's own nightly database dump | `IMMICH_UPLOAD_LOCATION/backups/`, `.sql.gz`, fourteen kept, 02:00 by default | The same copy — it is on the same disk, on purpose, so one copy of the disk is a copy of the metadata beside the originals |
| The live database | The `immich-db` named volume, on the SSD | `make backup STACK=sensitive`, since [#131] closed [#428]: sentinel `PG_VERSION`, owner `999`, encrypted to `trinity`'s own recipients, and copied to `oracle` by the same run. Immich's dump on the USB disk is the second route to the same metadata |

The restore that [#132] asks to see proven once is Immich's own: a fresh
install, the library tree back on its disk, and a dump fed to `psql` inside
`immich-db` before the server first starts. **Rehearsed on `trinity` on
2026-09-28** against copies of the real library, by both routes in the table —
Immich's dump, and the `immich-db` volume out of a `make backup` set — with
every one of the 615 originals hashed against the checksum the restored
database holds for it. The procedure, what it proved and what it did not are
[`restore-the-sensitive-tier.md` § Restore Immich](../../docs/runbooks/restore-the-sensitive-tier.md#restore-immich).
Upstream calls the database-first order a hard rule; on v3.2.2 the rehearsal
found it is a safety rule instead, and the runbook says why it is kept anyway.

## Validate before deploying

```bash
make validate
```

Every checker in `scripts/validate.sh` iterates `scripts/stacks.sh`, so this
stack is covered by everything the estate's is: `docker compose config`, the
image-pin and digest checks, `check_compose_health.py --probe` (which execs
each healthcheck binary inside the pinned image — `wget` in Caddy's, `step` in
step-ca's, `curl`, `pg_isready` and `valkey-cli` in Paperless-ngx's three), and
`check_caddyfile.sh`, which runs `caddy validate` and
`caddy fmt --diff` against the `Caddyfile` in the pinned image with a
throwaway keypair where the real one will be mounted.

What `make validate` still does **not** prove about this stack, in the order
it matters:

- **That it runs on `trinity`.** That is proved by running it there, which
  it has since 2026-09-28 under [#404], by
  [`build-the-sensitive-tier-host.md`](../../docs/runbooks/build-the-sensitive-tier-host.md)
  §9. Before the host existed, what had been run was the pieces in isolation,
  on the monitoring host: the Immich services on 2026-09-09 with these exact
  settings, an admin created, an upload made and the ML models fetched, which
  is how the read-only findings in `compose.yaml` were made; Paperless-ngx and
  its two dependencies the same way, a scan consumed and deleted as the
  operator's uid; Caddy with this `Caddyfile` under the compose file's options;
  Vaultwarden likewise; and a full `make backup` / `make restore` round trip of
  four of the volumes with a seeded account in the vault — the runbook says
  exactly what that proved. That was a rehearsal of the file, not of the host.
- **That the CA tree exists.** `step-ca` starts only against a populated
  volume, and the volume is populated by a procedure run on two hosts. A fresh
  `make up` on a bare `trinity` fails on `config/ca.json`, loudly and on
  purpose.
- **That ACME issuance works.** `caddy validate` provisions the issuer against
  a throwaway root and dials nothing. Whether step-ca answers, validates the
  challenge and signs is proved by the first `make up` — Caddy's log says
  `certificate obtained successfully` and the served chain verifies against
  `certificates/tier-ca.pem` — and it was proved once on the monitoring host
  under a throwaway project before this was written
  ([`build-the-tier-ca.md`](../../docs/runbooks/build-the-tier-ca.md) §*Verify*).
- **That the limits fit the workload.** 4 cores and 3 GiB for OCR are a
  statement about the ProDesk made on a different machine.
- **That Home Assistant keeps booting under its hardening.** It was booted
  once, on the monitoring host on 2026-09-09, from the pinned digest with the
  exact `compose.yaml` settings — read-only root, every capability dropped,
  the two tmpfs mounts, this directory's `configuration.yaml` — on an
  internal Docker network with no route out. It served onboarding, wrote only
  to `/config`, and logged one error it will log on every start: the `dhcp`
  discovery integration wants `CAP_NET_RAW` to sniff for devices, which on a
  bridge network a VLAN away from every device would sniff nothing, so the
  capability stays dropped and the line is expected. That was one boot of one
  digest, and Dependabot moves the digest monthly, so since 2026-09-23 CI
  re-runs it: `scripts/check_hardened_boot.sh` boots the service from this
  `compose.yaml` on an internal network, waits for its healthcheck, and reads
  read-only root, `CapDrop=ALL` and no-new-privileges back from the running
  container ([#534](https://github.com/Gerrrt/HomeLab/issues/534)). A bump
  that does not boot hardened cannot merge. A service whose healthcheck can
  pass while its work fails also carries a `smoke.sh` in its config
  directory, which the check runs next; Stirling-PDF is the first. What it still cannot tell you is
  whether the integrations you add later load under the same hardening;
  `make check-hardened-boot` is the same boot, run by hand.
- **That AdGuard filters.** Its blocklists are downloaded on first start and
  live in the `adguard-work` volume from then on, so the first `make up` needs
  the internet and every later one does not. `make validate` checks the file
  parses as YAML and nothing about what it says; the blackbox filtering probe
  from `prometheus` is what checks the service actually blocks the canary, and
  enabling it is a step in the forwarder runbook.

[ADR-0004]: ../../docs/adr/0004-one-compose-stack-per-host.md
[ADR-0007]: ../../docs/adr/0007-defensive-estate-and-offensive-range.md
[ADR-0008]: ../../docs/adr/0008-place-services-by-data-trust.md
[ADR-0010]: ../../docs/adr/0010-keep-the-resolver-on-the-gateway.md
[ADR-0022]: ../../docs/adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md
[ADR-0023]: ../../docs/adr/0023-keep-the-household-recovery-path-outside-the-estate.md
[ADR-0034]: ../../docs/adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md
[ADR-0037]: ../../docs/adr/0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md
[ADR-0055]: ../../docs/adr/0055-forward-to-adguard-alone.md
[ADR-0057]: ../../docs/adr/0057-add-miniflux-to-the-sensitive-tier-with-its-fetcher-kept-off-winterfell.md
[ADR-0059]: ../../docs/adr/0059-add-memos-to-the-sensitive-tier-for-notes-and-keep-documentation-in-docs.md
[ADR-0061]: ../../docs/adr/0061-add-linkding-to-the-sensitive-tier-behind-one-factor.md
[#124]: https://github.com/Gerrrt/HomeLab/issues/124
[ADR-0060]: ../../docs/adr/0060-add-mealie-to-the-sensitive-tier-as-recipes.md
[ADR-0062]: ../../docs/adr/0062-add-actual-to-the-sensitive-tier.md
[ADR-0063]: ../../docs/adr/0063-add-stirling-pdf-to-the-sensitive-tier-and-keep-its-documents-in-memory.md
[#129]: https://github.com/Gerrrt/HomeLab/issues/129
[#130]: https://github.com/Gerrrt/HomeLab/issues/130
[#131]: https://github.com/Gerrrt/HomeLab/issues/131
[#132]: https://github.com/Gerrrt/HomeLab/issues/132
[#133]: https://github.com/Gerrrt/HomeLab/issues/133
[#134]: https://github.com/Gerrrt/HomeLab/issues/134
[#135]: https://github.com/Gerrrt/HomeLab/issues/135
[#136]: https://github.com/Gerrrt/HomeLab/issues/136
[#137]: https://github.com/Gerrrt/HomeLab/issues/137
[#142]: https://github.com/Gerrrt/HomeLab/issues/142
[#144]: https://github.com/Gerrrt/HomeLab/issues/144
[#145]: https://github.com/Gerrrt/HomeLab/issues/145
[#147]: https://github.com/Gerrrt/HomeLab/issues/147
[#146]: https://github.com/Gerrrt/HomeLab/issues/146
[#143]: https://github.com/Gerrrt/HomeLab/issues/143
[#182]: https://github.com/Gerrrt/HomeLab/issues/182
[#66]: https://github.com/Gerrrt/HomeLab/issues/66
[ADR-0035]: ../../docs/adr/0035-scope-the-99-to-20-rule-to-the-hue-bridge.md
[#404]: https://github.com/Gerrrt/HomeLab/issues/404
[#428]: https://github.com/Gerrrt/HomeLab/issues/428
[#455]: https://github.com/Gerrrt/HomeLab/issues/455
[#533]: https://github.com/Gerrrt/HomeLab/issues/533
[#535]: https://github.com/Gerrrt/HomeLab/issues/535
