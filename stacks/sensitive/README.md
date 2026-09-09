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
| adguard | `adguard/adguardhome` | 53 (dns), on `10.0.99.40` only | The DNS filter Unbound on `morpheus` forwards to under [ADR-0010] — never a client-facing resolver. The one port besides Caddy's, published to the firewall's forwarder and the blackbox prober and answered for nothing else; the UI is behind Caddy at `adguard.matrix.elysium` ([#135]) |

Three services: two are plumbing, and the third is the first thing here the
household uses, without ever knowing it. What is absent is as deliberate as
what is here:

- **No Prometheus, Loki or Grafana.** The lab has its own because its
  telemetry must never reach VLAN 99 ([ADR-0007]); this host *is* on VLAN 99,
  so it is watched the way `oracle` is — an Alloy agent shipped by
  `scripts/deploy-agent.sh`, pushing to `10.0.99.20`, needing no new rule and
  no new port. The agent is not in this compose file for the same reason it is
  not in the lab's: it is the estate's, deployed identically everywhere.
- **The household services are still to come.** Vaultwarden, Immich,
  Paperless-ngx, Home Assistant, ntfy and Homepage ([#131]–[#134], [#136],
  [#137]) each arrive as a service with `expose:` and a block in the
  `Caddyfile`, in that order of build, and only after the foundation runs. A
  service in this file with `ports:` of its own is the one thing a review of it
  should refuse — AdGuard is the single argued exception, and `compose.yaml`
  makes the argument at DIFFERENCE 5 so that the next one has to be made too.

## Layout

```text
compose.yaml               three services, one network, health-gated ordering
Caddyfile                  every route the tier serves; validated in CI
.env.example               non-sensitive tunables — edit this, not .env
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
  ARGS="--host trinity.matrix.elysium --ip 10.0.99.40 --dns trinity"` on the
  monitoring host, three files copied over as `build-the-lab-guest.md` §5
  does it. `render-config.sh` refuses to render while any of them is missing.
  The `Caddyfile` carries the `tls { ca … }` block that replaces this once
  [#130]'s ACME provisioner is configured.
- **80 is not published.** ADR-0012: a port is published when something
  off-host consumes it, and nothing consumes 80 — browsers on Hicks type
  `https`, and ACME's `tls-alpn-01` challenge runs over 443. A redirect is a
  later choice, made in `.env.example` and `compose.yaml` together.
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
  limit can be stated for without a machine to measure.

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
  check is static.
- **That the CA tree exists.** `step-ca` starts only against a populated
  volume, and the volume is populated by a procedure run on two hosts. A fresh
  `make up` on a bare `trinity` fails on `config/ca.json`, loudly and on
  purpose.
- **That the leaf matches the name.** `caddy validate` loads a throwaway pair;
  whether the real one carries `trinity.matrix.elysium` and
  `adguard.matrix.elysium` in its SANs is checked by the first browser, or by
  `openssl x509 -noout -ext subjectAltName` on the monitoring host before the
  files travel.
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
[ADR-0034]: ../../docs/adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md
[#129]: https://github.com/Gerrrt/HomeLab/issues/129
[#130]: https://github.com/Gerrrt/HomeLab/issues/130
[#131]: https://github.com/Gerrrt/HomeLab/issues/131
[#134]: https://github.com/Gerrrt/HomeLab/issues/134
[#135]: https://github.com/Gerrrt/HomeLab/issues/135
[#136]: https://github.com/Gerrrt/HomeLab/issues/136
[#137]: https://github.com/Gerrrt/HomeLab/issues/137
[#404]: https://github.com/Gerrrt/HomeLab/issues/404
