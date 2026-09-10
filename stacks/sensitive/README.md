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
| immich-server | `ghcr.io/immich-app/immich-server` | *internal* (2283) | The photo library — API and job workers in one container, reached as `https://immich.matrix.elysium` through Caddy ([#132]) |
| immich-machine-learning | `ghcr.io/immich-app/immich-machine-learning` | *internal* (3003) | Smart search, face detection and OCR for the server above. Behind the `ml` profile, on by default ([#132]) |
| immich-db | `ghcr.io/immich-app/postgres` | *internal* (5432) | Immich's Postgres, with VectorChord preloaded, on the internal SSD ([#132]) |
| immich-valkey | `valkey/valkey` | *internal* (6379) | Immich's job queue. Nothing durable — a tmpfs, rebuilt from the database on restart ([#132]) |
| vaultwarden | `vaultwarden/server` | *internal* (8080) | The household's password manager, at `https://vaultwarden.matrix.elysium` — Bitwarden's own clients and extensions, pointed at that URL ([#131]) |

Nine services. Two are plumbing; Home Assistant and Vaultwarden are the first
household services and the shape every later one takes; AdGuard is the one the
household uses without ever knowing it; and four are Immich, the service
[ADR-0008] names as the price of putting the tier on Winterfell at all. What is
absent is as deliberate as what is
here:

- **No Prometheus, Loki or Grafana.** The lab has its own because its
  telemetry must never reach VLAN 99 ([ADR-0007]); this host *is* on VLAN 99,
  so it is watched the way `oracle` is — an Alloy agent shipped by
  `scripts/deploy-agent.sh`, pushing to `10.0.99.20`, needing no new rule and
  no new port. The agent is not in this compose file for the same reason it is
  not in the lab's: it is the estate's, deployed identically everywhere.
- **No other services yet.** Paperless-ngx, ntfy and Homepage ([#133], [#136],
  [#137]) each arrive as Home Assistant, Immich and Vaultwarden did: a service
  with `expose:`, a block in the `Caddyfile`, a name on the leaf, its credential
  in SOPS where it takes one from outside, and a sentinel for its volume in
  `scripts/backup-volumes.sh`. A service in this file with `ports:` of its own
  is the one thing a review of it should refuse — AdGuard is the single argued
  exception, and `compose.yaml` makes the argument at DIFFERENCE 7 so that the
  next one has to be made too.
- **No Supervisor, no add-ons, no MQTT broker, no Zigbee coordinator.** Home
  Assistant *Container* has no add-on store, which is why it was chosen: an
  add-on is a second package manager outside `compose.yaml` and outside digest
  pinning. What an add-on would have supplied becomes a pinned service here
  on the day a device needs it, and today none does — Ring is cloud, the Hue
  bridge is its own radio, the speakers are Wi-Fi. No USB radio means where
  `trinity` sits is not this service's concern.

## Layout

```text
compose.yaml               nine services, one network, health-gated ordering
Caddyfile                  every route the tier serves; validated in CI
home-assistant/            configuration.yaml and packages/, mounted read-only
                           over the volume Home Assistant writes its state to
.env.example               non-sensitive tunables — edit this, not .env:
                             the library's mount point, and the ML switch
adguard/AdGuardHome.yaml   AdGuard Home's whole configuration, blocklists included
```

Secrets are `secrets/sensitive.sops.yaml`, encrypted to this stack's own rule
in `.sops.yaml` — `trinity`'s key opens this file and nothing else of the
estate's (`secrets/sensitive.example.yaml` says why). Certificates live under
`certificates/`, untracked, and are issued on the monitoring host where the
CA key stays.

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
  immich.matrix.elysium --dns vaultwarden.matrix.elysium"` on the monitoring
  host, three files copied over as `build-the-lab-guest.md` §5 does it.
  `render-config.sh` refuses to render
  while any of them is missing.
  The `Caddyfile` carries the `tls { ca … }` block that replaces this once
  [#130]'s ACME provisioner is configured, and per-service names stop being
  a step.
- **The phones have to trust the lab CA.** The mobile app is the whole reason
  Immich was chosen over PhotoPrism ([#132]), and it talks to
  `https://immich.matrix.elysium` on a certificate a phone has never heard
  of. `certificates/ca.pem` goes onto each phone as a user-installed root
  before the app is pointed at the server; Android's Immich app honours a
  user root, iOS needs the profile installed and then *enabled* under
  Certificate Trust Settings, which is the step people miss. Nothing about
  this changes when step-ca issues the leaf — the root is the same one.
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
  `https`, and ACME's `tls-alpn-01` challenge runs over 443. A redirect is a
  later choice, made in `.env.example` and `compose.yaml` together.
- **Every routed name needs a SAN and a host override.** The `Caddyfile`
  matches on Host, so `homeassistant.matrix.elysium`, `adguard.matrix.elysium`,
  `immich.matrix.elysium` and `vaultwarden.matrix.elysium` have to be on the leaf
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
- **Memory limits are set from day one.** [#129]'s ask, and the one place this
  file departs from the lab's reasoning — a proxy and a CA have working sets a
  limit can be stated for without a machine to measure. Immich's four are
  ceilings rather than derivations, and `compose.yaml` says what was measured
  underneath them and when to re-derive.
- **Caddy joins the operator's group.** `gen-certs.sh` writes the leaf's key
  `0640`, owned by whoever ran it, and root inside a container that has dropped
  `CAP_DAC_OVERRIDE` is bound by that mode like any other uid — measured: the
  pinned image died on `key.pem: permission denied` until `group_add` carried
  `RENDER_GID`, the way the estate's Grafana already does ([#131]).

## Vaultwarden

The second household service, and the one [#131] was mostly not about: *"a
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
- **The name has to be in the leaf.** The browser checks the certificate's SANs
  before Caddy sees a Host header, so `vaultwarden.matrix.elysium` is on the
  `make certs` line in `compose.yaml` and needs a host override
  ([`add-a-host-override.md`](../../docs/runbooks/add-a-host-override.md)). Each
  service adds its name there until step-ca's ACME provisioner issues per-name
  leaves.
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

## Backup and restore

```bash
make backup STACK=sensitive
make restore STACK=sensitive ARGS="--dry-run --from latest"
```

`backup-volumes.sh` derives the volume list from `compose.yaml` and refuses a
volume it cannot verify, so each of the seven volumes it archives has a
sentinel entry there — `instance.uuid` and `autosave.json` for the two Caddy
volumes, `config/ca.json` for step-ca, `db.sqlite3` for Vaultwarden, the
recorder's `home-assistant_v2.db` for Home Assistant, `data/stats.db` for
AdGuard, `PG_VERSION` for Immich's Postgres — and `restore-volumes.sh` knows
the uid each must come back owned by. The eighth, `immich-model-cache`, is
skipped by name: a downloadable cache is not data, and a fresh host whose
models have not been fetched yet would otherwise fail the whole run on an
empty archive. Both scripts encrypt to **every recipient of
`secrets/sensitive.sops.yaml`**, read from the file itself: `trinity`'s key,
and the technical second's once it joins the rule. Until [#131] they took the
first key in `.sops.yaml` whichever rule it belonged to, which would have
encrypted the estate's weekly backup to `trinity`'s key the day the placeholder
was filled — the two defects [#428] describes.

What this does **not** do, and [#404] step 5 still owes: nothing schedules
`make backup STACK=sensitive` on `trinity` — the `homelab-*` timers are the
estate's — and nothing copies a set off the host, let alone off the estate,
which is the copy [ADR-0023] requires before Immich or Paperless-ngx hold a
real file. A set in `backups/volumes/` on `trinity` protects against a bad
upgrade and a mistyped command, and against nothing that happens to `trinity`.

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
| The live database | The `immich-db` named volume, on the SSD | `make backup STACK=sensitive`, since [#131] closed [#428]: sentinel `PG_VERSION`, owner `999`, encrypted to `trinity`'s own recipients. Immich's dump on the USB disk is the second route to the same metadata |

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
step-ca's), and `check_caddyfile.sh`, which runs `caddy validate` and
`caddy fmt --diff` against the `Caddyfile` in the pinned image with a
throwaway keypair where the real one will be mounted.

What `make validate` still does **not** prove about this stack, in the order
it matters:

- **That it runs on `trinity`.** Nothing here has been deployed there — the
  host is [#404]. What has been run is the pieces in isolation, on the
  monitoring host: the Immich services on 2026-09-09 with these exact
  settings, an admin created, an upload made and the ML models fetched, which
  is how the read-only findings in `compose.yaml` were made; Caddy with this
  `Caddyfile` under the compose file's options; Vaultwarden likewise; and a
  full `make backup` / `make restore` round trip of four of the volumes with a
  seeded account in the vault — the runbook says exactly what that proved.
  That is a rehearsal of the file, not of the host.
- **That the CA tree exists.** `step-ca` starts only against a populated
  volume, and the volume is populated by a procedure run on two hosts. A fresh
  `make up` on a bare `trinity` fails on `config/ca.json`, loudly and on
  purpose.
- **That the leaf matches the names.** `caddy validate` loads a throwaway
  pair; whether the real one carries `trinity.matrix.elysium`,
  `homeassistant.matrix.elysium`, `adguard.matrix.elysium`,
  `immich.matrix.elysium` *and* `vaultwarden.matrix.elysium` in its SANs is
  checked by the first browser,
  or by `openssl x509 -noout -ext subjectAltName` on the monitoring host
  before the files travel.
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
