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
| vaultwarden | `vaultwarden/server` | *internal* (8080) | The household's password manager, at `https://vaultwarden.matrix.elysium` — Bitwarden's own clients and extensions, pointed at that URL ([#131]) |

Three services: two are plumbing, and the third is the first household one,
which sets the shape for the rest. What is absent is as deliberate as what is
here:

- **No Prometheus, Loki or Grafana.** The lab has its own because its
  telemetry must never reach VLAN 99 ([ADR-0007]); this host *is* on VLAN 99,
  so it is watched the way `oracle` is — an Alloy agent shipped by
  `scripts/deploy-agent.sh`, pushing to `10.0.99.20`, needing no new rule and
  no new port. The agent is not in this compose file for the same reason it is
  not in the lab's: it is the estate's, deployed identically everywhere.
- **One service so far.** Immich, Paperless-ngx, Home Assistant, AdGuard Home,
  ntfy and Homepage ([#132]–[#137]) each arrive the way Vaultwarden did: a
  service with `expose:`, a block in the `Caddyfile`, its name on the
  `make certs` line, its credential in SOPS, and a sentinel for its volume in
  `scripts/backup-volumes.sh` — in that order of build, and only after the
  foundation runs. A service in this file with `ports:` of its own is the one
  thing a review of it should refuse.

## Layout

```text
compose.yaml               two services, one network, health-gated ordering
Caddyfile                  every route the tier serves; validated in CI
.env.example               non-sensitive tunables — edit this, not .env
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
  ARGS="--host trinity.matrix.elysium --ip 10.0.99.40 --dns trinity"` on the
  monitoring host, three files copied over as `build-the-lab-guest.md` §5
  does it. `render-config.sh` refuses to render while any of them is missing.
  The `Caddyfile` carries the `tls { ca … }` block that replaces this once
  [#130]'s ACME provisioner is configured.
- **80 is not published.** ADR-0012: a port is published when something
  off-host consumes it, and nothing consumes 80 — browsers on Hicks type
  `https`, and ACME's `tls-alpn-01` challenge runs over 443. A redirect is a
  later choice, made in `.env.example` and `compose.yaml` together.
- **Nothing converges this stack.** The `homelab-*` timers are the estate's;
  `make validate` notes their absence here as a skip, not a failure. This stack
  is deployed by hand, from a checkout on `trinity`.
- **Memory limits are set from day one.** [#129]'s ask, and the one place this
  file departs from the lab's reasoning — a proxy and a CA have working sets a
  limit can be stated for without a machine to measure.
- **Caddy joins the operator's group.** `gen-certs.sh` writes the leaf's key
  `0640`, owned by whoever ran it, and root inside a container that has dropped
  `CAP_DAC_OVERRIDE` is bound by that mode like any other uid — measured: the
  pinned image died on `key.pem: permission denied` until `group_add` carried
  `RENDER_GID`, the way the estate's Grafana already does ([#131]).

## Vaultwarden

The first service, and the one [#131] was mostly not about: *"a password vault
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
volume it cannot verify, so each of the tier's four has a sentinel entry there
— `instance.uuid` and `autosave.json` for the two Caddy volumes, `config/ca.json`
for step-ca, `db.sqlite3` for Vaultwarden — and `restore-volumes.sh` knows the
uid each must come back owned by. Both encrypt to **every recipient of
`secrets/sensitive.sops.yaml`**, read from the file itself: `trinity`'s key,
and the technical second's once it joins the rule. Until [#131] they took the
first key in `.sops.yaml` whichever rule it belonged to, which would have
encrypted the estate's weekly backup to `trinity`'s key the day the placeholder
was filled.

What this does **not** do, and [#404] step 5 still owes: nothing schedules
`make backup STACK=sensitive` on `trinity` — the `homelab-*` timers are the
estate's — and nothing copies a set off the host, let alone off the estate,
which is the copy [ADR-0023] requires before Immich or Paperless-ngx hold a
real file. A set in `backups/volumes/` on `trinity` protects against a bad
upgrade and a mistyped command, and against nothing that happens to `trinity`.

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

- **That it runs.** Nothing here has been deployed — the host is [#404]. Every
  check is static. What has been run is the pieces in isolation, on the
  monitoring host: Caddy with this `Caddyfile` under the compose file's options,
  Vaultwarden likewise, and a full `make backup` / `make restore` round trip of
  the four volumes with a seeded account in the vault — the runbook says
  exactly what that proved.
- **That the CA tree exists.** `step-ca` starts only against a populated
  volume, and the volume is populated by a procedure run on two hosts. A fresh
  `make up` on a bare `trinity` fails on `config/ca.json`, loudly and on
  purpose.
- **That the leaf matches the name.** `caddy validate` loads a throwaway pair;
  whether the real one carries `trinity.matrix.elysium` in its SANs is checked
  by the first browser, or by `openssl x509 -noout -ext subjectAltName` on the
  monitoring host before the files travel.

[ADR-0007]: ../../docs/adr/0007-defensive-estate-and-offensive-range.md
[ADR-0008]: ../../docs/adr/0008-place-services-by-data-trust.md
[ADR-0022]: ../../docs/adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md
[ADR-0023]: ../../docs/adr/0023-keep-the-household-recovery-path-outside-the-estate.md
[ADR-0034]: ../../docs/adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md
[#129]: https://github.com/Gerrrt/HomeLab/issues/129
[#130]: https://github.com/Gerrrt/HomeLab/issues/130
[#131]: https://github.com/Gerrrt/HomeLab/issues/131
[#132]: https://github.com/Gerrrt/HomeLab/issues/132
[#137]: https://github.com/Gerrrt/HomeLab/issues/137
[#404]: https://github.com/Gerrrt/HomeLab/issues/404
