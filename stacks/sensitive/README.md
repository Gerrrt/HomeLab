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
| step-ca | `smallstep/step-ca` | *internal* (9000) | The tier's certificate authority — an intermediate beneath the lab CA, so nothing that trusts `certificates/ca.pem` is re-pointed ([#130]) |
| home-assistant | `ghcr.io/home-assistant/home-assistant` | *internal* (8123) | Home automation, and what the `99 → 20` rule exists for — one pass, to the Hue bridge, scoped by [ADR-0035] ([#134]) |
| adguard | `adguard/adguardhome` | 53 (dns), on `10.0.99.40` only | The DNS filter Unbound on `morpheus` forwards to under [ADR-0010] — never a client-facing resolver. The one port besides Caddy's, published to the firewall's forwarder and the blackbox prober and answered for nothing else; the UI is behind Caddy at `adguard.matrix.elysium` ([#135]) |
| paperless | `ghcr.io/paperless-ngx/paperless-ngx` | *internal* (8000) | The document archive: scan, OCR, index. On this tier by content — tax returns, passports, medical records — and the service [ADR-0023] classes as *durable* ([#133]) |
| paperless-db | `postgres` | *internal* (5432) | Paperless-ngx's own database. Metadata about documents; the documents themselves are files under `paperless-media` |
| paperless-broker | `valkey/valkey` | *internal* (6379) | Paperless-ngx's task queue and cache — the one volume in this stack whose loss costs nothing |

Seven services. Two are plumbing; Home Assistant is the first household
service and the shape every later one takes; AdGuard is the one the household
uses without ever knowing it; Paperless-ngx, with its database and broker, is
the archive of what the household cannot get back. What is absent is as
deliberate as what is here:

- **No Prometheus, Loki or Grafana.** The lab has its own because its
  telemetry must never reach VLAN 99 ([ADR-0007]); this host *is* on VLAN 99,
  so it is watched the way `oracle` is — an Alloy agent shipped by
  `scripts/deploy-agent.sh`, pushing to `10.0.99.20`, needing no new rule and
  no new port. The agent is not in this compose file for the same reason it is
  not in the lab's: it is the estate's, deployed identically everywhere.
- **No other services yet.** Vaultwarden, Immich, ntfy and Homepage ([#131],
  [#132], [#136], [#137]) each arrive as Home Assistant and Paperless-ngx did:
  a service with `expose:`, a block in the `Caddyfile`, a name on the leaf and
  in the resolver. A service in this file with `ports:` of its own is the one
  thing a review of it should refuse — AdGuard is the single argued exception,
  and `compose.yaml` makes the argument at DIFFERENCE 7 so that the next one
  has to be made too.
- **No shared database.** Paperless-ngx has a Postgres of its own rather than
  one the tier shares, and Immich will too: it needs the vector extension and
  therefore a different image, and one database per service is what lets
  `backup-volumes.sh` attribute every volume to the one service that owns it
  and stop only that.
- **No Supervisor, no add-ons, no MQTT broker, no Zigbee coordinator.** Home
  Assistant *Container* has no add-on store, which is why it was chosen: an
  add-on is a second package manager outside `compose.yaml` and outside digest
  pinning. What an add-on would have supplied becomes a pinned service here
  on the day a device needs it, and today none does — Ring is cloud, the Hue
  bridge is its own radio, the speakers are Wi-Fi. No USB radio means where
  `trinity` sits is not this service's concern.

## Layout

```text
compose.yaml               seven services, one network, health-gated ordering
Caddyfile                  every route the tier serves; validated in CI
home-assistant/            configuration.yaml and packages/, mounted read-only
                           over the volume Home Assistant writes its state to
.env.example               non-sensitive tunables — edit this, not .env
adguard/AdGuardHome.yaml   AdGuard Home's whole configuration, blocklists included
consume/                   untracked: drop a scan here and Paperless-ngx imports
                           and deletes it. Created by render-config.sh
export/                    untracked: where document_exporter writes. Likewise
```

Secrets are `secrets/sensitive.sops.yaml`, encrypted to this stack's own rule
in `.sops.yaml` — `trinity`'s key opens this file and nothing else of the
estate's (`secrets/sensitive.example.yaml` says why, and lists the five keys).
Certificates live under `certificates/`, untracked, and are issued on the
monitoring host where the CA key stays.

## Things worth knowing before editing

- **Caddy runs as root with one capability**, and every other container in
  the estate does not. `compose.yaml` measures why — the image's `/data` and
  `/config` are root-owned and a named volume inherits that — and names the
  command that re-checks the premise when the image moves. `cap_drop: [ALL]`
  plus `no-new-privileges` is what makes it acceptable; do not add capabilities
  to make something else work.
- **No admin API.** `admin off` in the `Caddyfile` means a routing change is
  `make up STACK=sensitive`, which recreates the container, not `caddy reload`.
  The socket would have been unauthenticated and on the same network as every
  service it fronts.
- **step-ca is an intermediate, and its tree is not made here.** `step ca init`
  runs on the monitoring host against `certificates/ca.pem` and its key; the
  resulting `config/`, `certs/`, `secrets/` and `db/` populate the
  `step-ca-data` volume on `trinity`. The image's entrypoint will not start
  without `config/ca.json`, and `DOCKER_STEPCA_INIT_*` is never set, because
  either would mint a root of its own. The key password is `STEPCA_PASSWORD`
  in SOPS, written to a private tmpfs at start and nowhere on disk.
- **The certificate is hand-issued until ACME is wired.** `make certs
  ARGS="--host trinity.matrix.elysium --ip 10.0.99.40 --dns trinity --dns
  homeassistant.matrix.elysium --dns adguard.matrix.elysium --dns
  paperless.matrix.elysium"` on the monitoring host, three files copied over
  as `build-the-lab-guest.md` §5 does it — one `--dns` per name the
  `Caddyfile` routes by. `render-config.sh` refuses to render while any of
  them is missing.
  The `Caddyfile` carries the `tls { ca … }` block that replaces this once
  [#130]'s ACME provisioner is configured.
- **80 is not published.** ADR-0012: a port is published when something
  off-host consumes it, and nothing consumes 80 — browsers on Hicks type
  `https`, and ACME's `tls-alpn-01` challenge runs over 443. A redirect is a
  later choice, made in `.env.example` and `compose.yaml` together.
- **Every routed name needs a SAN and a host override.** The `Caddyfile`
  matches on Host, so `homeassistant.matrix.elysium`, `adguard.matrix.elysium`
  and `paperless.matrix.elysium` each have to be on the leaf
  (`compose.yaml`'s `make certs` line carries one `--dns` per name) and in
  `morpheus`'s resolver, pointed at `10.0.99.40`
  ([`add-a-host-override.md`](../../docs/runbooks/add-a-host-override.md)).
  A name missing from the leaf fails the handshake; one missing from the
  resolver never arrives.
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
  measure. Paperless-ngx's numbers are stated as *unmeasured on the hardware
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

### Backing it up

An OCR index can be rebuilt; the originals cannot. `backup-volumes.sh` covers
both halves [#133] asks for, and it needed two things to do so: an entry per
volume in its sentinel table — the string that proves an archive holds *that*
volume, read off the volumes after the boot above — and one for each of the
foundation's three, Home Assistant's and AdGuard's, which had none, so a
stack backup here refused before this landed. On `trinity`:

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

## Validate before deploying

```bash
make validate
```

Every checker in `scripts/validate.sh` iterates `scripts/stacks.sh`, so this
stack is covered by everything the estate's is: `docker compose config`, the
image-pin and digest checks, `check_compose_health.py --probe` (which execs
each healthcheck binary inside the pinned image — `wget` in Caddy's, Home
Assistant's and AdGuard's, `step` in step-ca's, `curl`, `pg_isready` and
`valkey-cli` in Paperless-ngx's three), and `check_caddyfile.sh`, which runs
`caddy validate` and
`caddy fmt --diff` against the `Caddyfile` in the pinned image with a
throwaway keypair where the real one will be mounted.

What `make validate` still does **not** prove about this stack, in the order
it matters:

- **That it runs on `trinity`.** The host is [#404]. Home Assistant, AdGuard
  Home, and Paperless-ngx with its two dependencies, have each been started
  from their pinned images on the monitoring host — a boot, not a deploy;
  Caddy and step-ca have not been started against a real certificate or a
  real CA tree anywhere. Every check here is static.
- **That the CA tree exists.** `step-ca` starts only against a populated
  volume, and the volume is populated by a procedure run on two hosts. A fresh
  `make up` on a bare `trinity` fails on `config/ca.json`, loudly and on
  purpose.
- **That the names resolve, or that the leaf carries them.** The host
  overrides are a firewall change; `caddy validate` loads a throwaway pair,
  and whether the real one carries `trinity.matrix.elysium`,
  `homeassistant.matrix.elysium`, `adguard.matrix.elysium` *and*
  `paperless.matrix.elysium` in its SANs is checked by the first browser, or
  by `openssl x509 -noout -ext subjectAltName` on the monitoring host before
  the files travel.
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
[ADR-0010]: ../../docs/adr/0010-keep-the-resolver-on-the-gateway.md
[ADR-0022]: ../../docs/adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md
[ADR-0023]: ../../docs/adr/0023-keep-the-household-recovery-path-outside-the-estate.md
[ADR-0034]: ../../docs/adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md
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
