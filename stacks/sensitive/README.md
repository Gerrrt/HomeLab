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
| step-ca | `smallstep/step-ca` | *internal* (9000) | The tier's certificate authority — a root of its own with an intermediate beneath it, issuing to Caddy over ACME ([#130], [ADR-0037]) |
| home-assistant | `ghcr.io/home-assistant/home-assistant` | *internal* (8123) | Home automation, and what the `99 → 20` rule exists for — one pass, to the Hue bridge, scoped by [ADR-0035] ([#134]) |

Two of the three are plumbing; the third is the first household service and
the shape every later one takes. What is absent is as deliberate as what is
here:

- **No Prometheus, Loki or Grafana.** The lab has its own because its
  telemetry must never reach VLAN 99 ([ADR-0007]); this host *is* on VLAN 99,
  so it is watched the way `oracle` is — an Alloy agent shipped by
  `scripts/deploy-agent.sh`, pushing to `10.0.99.20`, needing no new rule and
  no new port. The agent is not in this compose file for the same reason it is
  not in the lab's: it is the estate's, deployed identically everywhere.
- **No other services yet.** Vaultwarden, Immich, Paperless-ngx, AdGuard Home,
  ntfy and Homepage ([#131]–[#133], [#135]–[#137]) each arrive as Home
  Assistant did: a service with `expose:`, a block in the `Caddyfile`, a name
  on the leaf. A service in this file with `ports:` of its own is the one thing
  a review of it should refuse.
- **No Supervisor, no add-ons, no MQTT broker, no Zigbee coordinator.** Home
  Assistant *Container* has no add-on store, which is why it was chosen: an
  add-on is a second package manager outside `compose.yaml` and outside digest
  pinning. What an add-on would have supplied becomes a pinned service here
  on the day a device needs it, and today none does — Ring is cloud, the Hue
  bridge is its own radio, the speakers are Wi-Fi. No USB radio means where
  `trinity` sits is not this service's concern.

## Layout

```text
compose.yaml               three services, one network, health-gated ordering
Caddyfile                  every route the tier serves; validated in CI
home-assistant/            configuration.yaml and packages/, mounted read-only
                           over the volume Home Assistant writes its state to
.env.example               non-sensitive tunables — edit this, not .env
```

Secrets are `secrets/sensitive.sops.yaml`, encrypted to this stack's own rule
in `.sops.yaml` — `trinity`'s key opens this file and nothing else of the
estate's (`secrets/sensitive.example.yaml` says why). The one file under
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
- **80 is not published.** ADR-0012: a port is published when something
  off-host consumes it, and nothing consumes 80 — browsers on Hicks type
  `https`, and ACME's `tls-alpn-01` challenge runs over 443; the provisioner
  accepts no other challenge, and the `Caddyfile` disables the redirect
  listener Caddy would otherwise open on 80. A redirect is a later choice,
  made in `.env.example`, `compose.yaml` and the `Caddyfile` together.
- **Every routed name needs a host override.** `homeassistant.matrix.elysium`
  has to be in `morpheus`'s resolver, pointed at `10.0.99.40`
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
- **That ACME issuance works.** `caddy validate` provisions the issuer against
  a throwaway root and dials nothing. Whether step-ca answers, validates the
  challenge and signs is proved by the first `make up` — Caddy's log says
  `certificate obtained successfully` and the served chain verifies against
  `certificates/tier-ca.pem` — and it was proved once on the monitoring host
  under a throwaway project before this was written
  ([`build-the-tier-ca.md`](../../docs/runbooks/build-the-tier-ca.md) §*Verify*).
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

[ADR-0007]: ../../docs/adr/0007-defensive-estate-and-offensive-range.md
[ADR-0034]: ../../docs/adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md
[ADR-0037]: ../../docs/adr/0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md
[#129]: https://github.com/Gerrrt/HomeLab/issues/129
[#130]: https://github.com/Gerrrt/HomeLab/issues/130
[#131]: https://github.com/Gerrrt/HomeLab/issues/131
[#133]: https://github.com/Gerrrt/HomeLab/issues/133
[#134]: https://github.com/Gerrrt/HomeLab/issues/134
[#135]: https://github.com/Gerrrt/HomeLab/issues/135
[#137]: https://github.com/Gerrrt/HomeLab/issues/137
[ADR-0035]: ../../docs/adr/0035-scope-the-99-to-20-rule-to-the-hue-bridge.md
[#404]: https://github.com/Gerrrt/HomeLab/issues/404
