# Sensitive stack

ADR-0008's sensitive tier — the household's password manager, photos, documents
and home automation — on `trinity` (`10.0.99.40`, Winterfell / VLAN 99), the
ProDesk 600 G4 that [ADR-0034] made the tier's host after the firewall restore
has been rehearsed on it. **The host is not built yet**; [#404] is the build,
and this directory is the stack it deploys, authored ahead of the hardware the
way `stacks/lab` was.

```bash
make up STACK=sensitive
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| caddy | `caddy` | 443 (https) | The tier's published HTTPS port. Terminates TLS, routes by name to every service behind it ([#129]) |
| step-ca | `smallstep/step-ca` | *internal* (9000) | The tier's certificate authority — a root of its own with an intermediate beneath it, issuing to Caddy over ACME ([#130], [ADR-0037]) |
| home-assistant | `ghcr.io/home-assistant/home-assistant` | *internal* (8123) | Home automation, and what the `99 → 20` rule exists for — one pass, to the Hue bridge, scoped by [ADR-0035] ([#134]) |
| adguard | `adguard/adguardhome` | 53 (dns), on `10.0.99.40` only | The DNS filter Unbound on `morpheus` forwards to under [ADR-0010] — never a client-facing resolver. The one port besides Caddy's, published to the firewall's forwarder and the blackbox prober and answered for nothing else; the UI is behind Caddy at `adguard.matrix.elysium` ([#135]) |
| immich-server | `ghcr.io/immich-app/immich-server` | *internal* (2283) | The photo library — API and job workers in one container, reached as `https://immich.matrix.elysium` through Caddy ([#132]) |
| immich-machine-learning | `ghcr.io/immich-app/immich-machine-learning` | *internal* (3003) | Smart search, face detection and OCR for the server above. Behind the `ml` profile, on by default ([#132]) |
| immich-db | `ghcr.io/immich-app/postgres` | *internal* (5432) | Immich's Postgres, with VectorChord preloaded, on the internal SSD ([#132]) |
| immich-valkey | `valkey/valkey` | *internal* (6379) | Immich's job queue. Nothing durable — a tmpfs, rebuilt from the database on restart ([#132]) |
| paperless | `ghcr.io/paperless-ngx/paperless-ngx` | *internal* (8000) | The document archive: scan, OCR, index. On this tier by content — tax returns, passports, medical records — and the service [ADR-0023] classes as *durable* ([#133]) |
| paperless-db | `postgres` | *internal* (5432) | Paperless-ngx's own database. Metadata about documents; the documents themselves are files under `paperless-media` |
| paperless-broker | `valkey/valkey` | *internal* (6379) | Paperless-ngx's task queue and cache — the one volume in this stack whose loss costs nothing |

Eleven services. Two are plumbing; Home Assistant is the first household
service and the shape every later one takes; AdGuard is the one the household
uses without ever knowing it; four are Immich, the service [ADR-0008] names as
the price of putting the tier on Winterfell at all; and three are
Paperless-ngx, the archive of what the household cannot get back. What is
absent is as deliberate as what is here:

- **No Prometheus, Loki or Grafana.** The lab has its own because its
  telemetry must never reach VLAN 99 ([ADR-0007]); this host *is* on VLAN 99,
  so it is watched the way `oracle` is — an Alloy agent shipped by
  `scripts/deploy-agent.sh`, pushing to `10.0.99.20`, needing no new rule and
  no new port. The agent is not in this compose file for the same reason it is
  not in the lab's: it is the estate's, deployed identically everywhere.
- **No other services yet.** Vaultwarden, ntfy and Homepage ([#131], [#136],
  [#137]) each arrive as Home Assistant, Immich and Paperless-ngx did: a
  service with `expose:`, a block in the `Caddyfile`, a name on the leaf and
  in the resolver. A service in this file with `ports:` of its own is the one
  thing a review of it should refuse — AdGuard is the single argued exception,
  and `compose.yaml` makes the argument at DIFFERENCE 7 so that the next one
  has to be made too.
- **No shared database.** Immich and Paperless-ngx each run a Postgres of
  their own — Immich's needs the vector extension and therefore a different
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
compose.yaml               eleven services, one network, health-gated ordering
Caddyfile                  every route the tier serves; validated in CI
home-assistant/            configuration.yaml and packages/, mounted read-only
                           over the volume Home Assistant writes its state to
.env.example               non-sensitive tunables — edit this, not .env:
                             the library's mount point, and the ML switch
adguard/AdGuardHome.yaml   AdGuard Home's whole configuration, blocklists included
consume/                   untracked: drop a scan here and Paperless-ngx imports
                           and deletes it. Created by render-config.sh
export/                    untracked: where document_exporter writes. Likewise
```

Secrets are `secrets/sensitive.sops.yaml`, encrypted to this stack's own rule
in `.sops.yaml` — `trinity`'s key opens this file and nothing else of the
estate's (`secrets/sensitive.example.yaml` says why, and lists the six keys). The one file under
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
  — and each name after it, `paperless.matrix.elysium` included — has to be
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
- **Caddy has a fixed address, `172.28.99.2`, for one reader.** Home
  Assistant's `trusted_proxies` names the proxy it will believe
  `X-Forwarded-For` from, and a Docker-assigned address is not a name. The
  network's subnet is fixed for that one line and nothing else.
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
- **Nothing converges this stack.** The `homelab-*` timers are the estate's;
  `make validate` notes their absence here as a skip, not a failure. This stack
  is deployed by hand, from a checkout on `trinity`.
- **Memory limits are set from day one, and now a CPU ceiling too.** [#129]'s
  ask, and the one place this file departs from the lab's reasoning — a proxy
  and a CA have working sets a limit can be stated for without a machine to
  measure. Immich's four are ceilings rather than derivations, and
  `compose.yaml` says what was measured underneath them and when to
  re-derive. Paperless-ngx's numbers are stated as *unmeasured on the hardware
  they are for*: `cpus: 4` of the ProDesk's six because OCR takes every core
  it is given for minutes, and `3072m` because upstream's floor is 2 GB for
  the whole install. What was measured, on the monitoring host on 2026-09-09
  from the pinned images: 747 MiB working set idle, 825 MiB consuming a
  one-page 200 dpi scan, 22 processes. Re-derive from `container_memory_rss`
  once `trinity` has run a month.

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
on the first of them ([#428]'s first half; the second, the age recipient the
script picks, is still open there — do not trust a run until it lands). On
`trinity`:

```bash
STACK=sensitive make backup
```

That stops the three Paperless containers, archives `paperless-media` (the
originals, the PDF/A copies, the thumbnails — the part that cannot be
rebuilt), `paperless-db-data` (the database: tags, correspondents, every
document's metadata), `paperless-data` (the index and the classifier, both
rebuildable) and `paperless-broker-data` (the queue, disposable), verifies
each by its sentinel, and starts them again. A restore is
[`restore-the-stack.md`](../../docs/runbooks/restore-the-stack.md) with
`STACK=sensitive`; the Postgres sentinel carries the major version in its
path, so a bump from 18 has to move it, loudly.

The version-portable form is the exporter — `docker compose exec paperless
document_exporter ../export`, into `export/` — which writes every document with
a `manifest.json` that a fresh install of the *same* version re-imports.
Upstream is explicit that an export does not cross versions, so it is the
form to send off-estate rather than the form to rely on across an upgrade.

Two things this does **not** do, stated rather than implied. **Nothing
schedules it**: the `homelab-backup-volumes` unit carries
`STACK=observability` and the timers are the estate's; a timer for this stack
arrives with the host under [#404]. And **nothing here is the off-estate copy**
[ADR-0023] requires before the first real document — encrypted, keyed to a
second holder, with visible freshness. That is the precondition on the data
arriving, not on the container starting, and it is still open.

## What backs Immich up, and what does not yet

The photographs are the household data most likely to be irreplaceable, and
[ADR-0023] classes Immich as *durable*: it may be down, it may not be lost,
and before the first real photo arrives an off-estate copy has to exist whose
staleness is visible. Three things hold the data, and they are protected by
three different mechanisms — two of which do not exist yet.

| What | Where | Protected by |
| --- | --- | --- |
| The originals, thumbnails and transcodes | `IMMICH_UPLOAD_LOCATION` — the USB disk | The off-estate copy [ADR-0023] requires. **Not built**: it needs a destination chosen and paid for, and it is the precondition on the first real photo, not on the container starting |
| Immich's own nightly database dump | `IMMICH_UPLOAD_LOCATION/backups/`, `.sql.gz`, fourteen kept, 02:00 by default | The same copy — it is on the same disk, on purpose, so one copy of the disk is a copy of the metadata beside the originals |
| The live database | The `immich-db` named volume, on the SSD | `make backup STACK=sensitive` — **half-built**: `scripts/backup-volumes.sh` now has a sentinel for every volume in this stack, and still picks the estate's age key rather than `trinity`'s ([#428]) |

The restore that [#132] asks to see proven once is Immich's own: a fresh
install, the library tree back on its disk, and the newest dump fed to
`psql` inside `immich-db` — the procedure is upstream's *Backup and Restore*
page, and its one hard rule is that the database is restored **before** the
server first starts against the empty volume. It has not been rehearsed,
because there is no host; it is [#404] step 5, and this section is what that
step reads.

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

- **That it runs on `trinity`.** Nothing here has been deployed there — the
  host is [#404]. The Immich services were booted on the monitoring host on
  2026-09-09 with these exact settings, an admin created, an upload made and
  the ML models fetched, which is how the read-only findings in `compose.yaml`
  were made; that is a rehearsal of the file, not of the host. Paperless-ngx
  and its two dependencies were booted the same way, a scan consumed and
  deleted as the operator's uid — the same class of rehearsal.
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
  digest. Dependabot moves the digest monthly; nothing here re-runs the boot.
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
[#129]: https://github.com/Gerrrt/HomeLab/issues/129
[#130]: https://github.com/Gerrrt/HomeLab/issues/130
[#131]: https://github.com/Gerrrt/HomeLab/issues/131
[#132]: https://github.com/Gerrrt/HomeLab/issues/132
[#133]: https://github.com/Gerrrt/HomeLab/issues/133
[#134]: https://github.com/Gerrrt/HomeLab/issues/134
[#135]: https://github.com/Gerrrt/HomeLab/issues/135
[#136]: https://github.com/Gerrrt/HomeLab/issues/136
[#137]: https://github.com/Gerrrt/HomeLab/issues/137
[ADR-0035]: ../../docs/adr/0035-scope-the-99-to-20-rule-to-the-hue-bridge.md
[#404]: https://github.com/Gerrrt/HomeLab/issues/404
[#428]: https://github.com/Gerrrt/HomeLab/issues/428
