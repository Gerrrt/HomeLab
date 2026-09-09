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
| caddy | `caddy` | 443 (https) | The one published port on the tier. Terminates TLS, routes by name to every service behind it ([#129]) |
| step-ca | `smallstep/step-ca` | *internal* (9000) | The tier's certificate authority — an intermediate beneath the lab CA, so nothing that trusts `certificates/ca.pem` is re-pointed ([#130]) |
| paperless | `ghcr.io/paperless-ngx/paperless-ngx` | *internal* (8000) | The document archive: scan, OCR, index. On this tier by content — tax returns, passports, medical records — and the service [ADR-0023] classes as *durable* ([#133]) |
| paperless-db | `postgres` | *internal* (5432) | Paperless-ngx's own database. Metadata about documents; the documents themselves are files under `paperless-media` |
| paperless-broker | `valkey/valkey` | *internal* (6379) | Paperless-ngx's task queue and cache — the one volume in this stack whose loss costs nothing |

Five services: two are plumbing, three are the first household service. What is
absent is as deliberate as what is here:

- **No Prometheus, Loki or Grafana.** The lab has its own because its
  telemetry must never reach VLAN 99 ([ADR-0007]); this host *is* on VLAN 99,
  so it is watched the way `oracle` is — an Alloy agent shipped by
  `scripts/deploy-agent.sh`, pushing to `10.0.99.20`, needing no new rule and
  no new port. The agent is not in this compose file for the same reason it is
  not in the lab's: it is the estate's, deployed identically everywhere.
- **No `ports:` on anything but Caddy.** Paperless-ngx is reached as
  `https://paperless.matrix.elysium`, through Caddy, on the pass for 443 that
  Hicks already has into Winterfell. Vaultwarden, Immich, Home Assistant,
  AdGuard Home, ntfy and Homepage ([#131], [#132], [#134]–[#137]) each arrive
  the same way — a service with `expose:` and a block in the `Caddyfile` — and
  only after the foundation runs. A service in this file with `ports:` of its
  own is the one thing a review of it should refuse.
- **No shared database.** Paperless-ngx has a Postgres of its own rather than
  one the tier shares, and Immich will too: it needs the vector extension and
  therefore a different image, and one database per service is what lets
  `backup-volumes.sh` attribute every volume to the one service that owns it
  and stop only that.

## Layout

```text
compose.yaml               five services, one network, health-gated ordering
Caddyfile                  every route the tier serves; validated in CI
.env.example               non-sensitive tunables — edit this, not .env
consume/                   untracked: drop a scan here and Paperless-ngx imports
                           and deletes it. Created by render-config.sh
export/                    untracked: where document_exporter writes. Likewise
```

Secrets are `secrets/sensitive.sops.yaml`, encrypted to this stack's own rule
in `.sops.yaml` — `trinity`'s key opens this file and nothing else of the
estate's (`secrets/sensitive.example.yaml` says why, and lists the four keys).
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
- **The certificate is hand-issued until ACME is wired, and it needs every
  name.** `make certs ARGS="--host trinity.matrix.elysium --ip 10.0.99.40
  --dns trinity --dns paperless.matrix.elysium"` on the monitoring host, three
  files copied over as `build-the-lab-guest.md` §5 does it — one `--dns` per
  service routed by name, or the browser refuses the handshake for the names
  that are missing. `render-config.sh` refuses to render while any of the
  files is missing. The `Caddyfile` carries the `tls { ca … }` block that
  replaces this once [#130]'s ACME provisioner is configured.
- **Each name needs a host override on `morpheus`.** Caddy routes on the
  `Host` the browser sent, so `paperless.matrix.elysium` has to resolve to
  `10.0.99.40` before anything is served under it — a seventh entry in the
  list [ADR-0010] counts six of, made on the firewall and recorded here, not
  the other way round. Without it the stack is healthy and unreachable.
- **80 is not published.** ADR-0012: a port is published when something
  off-host consumes it, and nothing consumes 80 — browsers on Hicks type
  `https`, and ACME's `tls-alpn-01` challenge runs over 443. A redirect is a
  later choice, made in `.env.example` and `compose.yaml` together.
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
foundation's three, which had none, so a stack backup here refused before
this landed. On `trinity`:

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
each healthcheck binary inside the pinned image — `wget` in Caddy's, `step` in
step-ca's, `curl`, `pg_isready` and `valkey-cli` in Paperless-ngx's three),
and `check_caddyfile.sh`, which runs `caddy validate` and `caddy fmt --diff`
against the `Caddyfile` in the pinned image with a throwaway keypair where the
real one will be mounted.

What `make validate` still does **not** prove about this stack, in the order
it matters:

- **That it runs on `trinity`.** The host is [#404]. Paperless-ngx and its two
  dependencies were booted from the pinned images on the monitoring host and
  consumed a document; Caddy and step-ca have not been started against a real
  certificate or a real CA tree anywhere. Every check here is static.
- **That the CA tree exists.** `step-ca` starts only against a populated
  volume, and the volume is populated by a procedure run on two hosts. A fresh
  `make up` on a bare `trinity` fails on `config/ca.json`, loudly and on
  purpose.
- **That the names resolve, or that the leaf carries them.** The host override
  is a firewall change; the SANs are checked by the first browser, or by
  `openssl x509 -noout -ext subjectAltName` on the monitoring host before the
  files travel.
- **That the limits fit the workload.** 4 cores and 3 GiB for OCR are a
  statement about the ProDesk made on a different machine.

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
[#137]: https://github.com/Gerrrt/HomeLab/issues/137
[#404]: https://github.com/Gerrrt/HomeLab/issues/404
