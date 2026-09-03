# Runbook: Generate the internal CA and leaf certificates

**Target:** the lab's own PKI, under `certificates/`
**Time:** a couple of minutes
**You will need:** nothing but `openssl` and this repository

The previous CA and leaf keys were committed to this public repository and had
to be removed by rewriting every commit — see
[`purge-git-history.md`](purge-git-history.md). Treat anything issued before
that rewrite as compromised, including the CA. What follows replaces it.

> **The stack does not start without these.** Grafana serves https from the
> leaf issued below, and Prometheus verifies that certificate with `ca.pem` when
> it scrapes the `grafana` job, as does blackbox-exporter when it probes Grafana
> from the outside — so both files are a prerequisite of
> [`deploy-stack.md`](deploy-stack.md), not a someday step. `make render`
> refuses to run until they exist, because before it did, `make up` bind-mounted
> the absent files and Docker created directories in their place
> ([#69](https://github.com/Gerrrt/HomeLab/issues/69)). Grafana is the only
> service that terminates TLS. Prometheus, Alertmanager and Loki publish plain
> HTTP on the management VLAN, and that is an accepted residual with firewall
> default-deny as the control — not work in progress; see
> [`security.md`](../security.md).

## Where things live

Everything lands in `certificates/`, which is gitignored — as are `*.pem` and
`*.key`. That is the control that matters. File modes are useful; not being a
tracked file is what stops a repeat of the last leak, and both `make validate`
and CI assert it.

| File | Mode | Secret? |
| --- | --- | --- |
| `certificates/ca-key.pem` | 0600 | **yes** — never copy it off this host |
| `certificates/ca.pem` | 0644 | no — this is what clients trust, distribute freely |
| `certificates/<host>-key.pem` | 0640 | **yes** — belongs only to that service |
| `certificates/<host>.pem` | 0644 | no |

The leaf key is 0640 rather than 0600 on purpose, and `gen-certs.sh` is right
where a stricter reading would say it is wrong. Grafana runs as `472:0` and the
key is owned by whoever ran `make certs`, so compose gives the container that
operator's gid as a supplementary group
([`compose.yaml`](../../stacks/observability/compose.yaml)) and the group read
bit is what lets it open its own key. The alternatives are worse: a
world-readable private key, or running Grafana as the operator's uid and
stranding it from its own 472-owned data volume. It also costs nothing —
`certificates/` is itself 0700, so no other local user can traverse to the file
whatever its own mode says. Tightening this to 0600 stops Grafana from starting.

## 1. Create the CA

Once, ever. Skip if `certificates/ca.pem` already exists.

```bash
make certs ARGS=--ca
```

Valid for ten years, `CN=Matrix Elysium Internal CA`. It refuses to overwrite an
existing CA: regenerating it invalidates every leaf it has signed and every
trust store holding it, so that has to be deliberate (`--force`).

## 2. Issue a leaf

```bash
make certs ARGS="--host grafana.matrix.elysium --ip 10.0.99.20 --dns grafana"
```

Include `--ip` for anything reached by address. `docs/roadmap.md` still lists
internal DNS as unresolved, so in practice most services here are reached by IP,
and a certificate without a matching IP SAN will be rejected at the point you
most want it to work.

`--dns grafana` is not decoration. Prometheus scrapes the `grafana` job over the
compose network, where the service answers to its short name, so
[`prometheus.yaml`](../../stacks/observability/prometheus/prometheus.yaml) sets
`server_name: grafana` and verifies that name against the leaf. Issue this
certificate with the FQDN alone and Grafana still serves fine in a browser while
the scrape fails with `x509: certificate is valid for grafana.matrix.elysium,
not grafana` — one target down, for a reason that reads like a trust problem.

Two limits the script enforces rather than lets you discover later:

- **A certificate with no `subjectAltName` is rejected outright** by every
  current browser and by Go's `crypto/tls` — which is what Prometheus,
  Alertmanager and Grafana are built on. The error, `x509: certificate relies on
  legacy Common Name field`, reads like a trust problem rather than a missing
  field.
- **Leaf lifetimes above 825 days are rejected by browsers.** A ten-year leaf
  looks like less future work and produces something nothing will trust.

Every issued certificate is verified against the CA before the script reports
success, so a chain that does not build fails here rather than at deploy time.

## 3. Check what exists

```bash
make certs ARGS=--list
```

Shows each certificate, its subject and its expiry, and marks expired ones. Worth
running before you debug a TLS error — an expired leaf and a misconfigured one
look identical from the client side.

## 4. Trust the CA where you need it

Distribute `certificates/ca.pem` — never the key.

```bash
# Debian/Ubuntu
sudo cp certificates/ca.pem /usr/local/share/ca-certificates/matrix-elysium.crt
sudo update-ca-certificates
```

Firefox keeps its own store and will not read the system one; import it under
**Settings → Privacy & Security → Certificates → View Certificates → Authorities**.

## Renewal

Leaves expire in 825 days. There is no automation and deliberately no cron: a
lab with one certificate is better served by a reminder than by a renewal
daemon nobody maintains. The reminder is an alert, not a calendar entry.
blackbox-exporter probes Grafana by name and by address, verifies the chain
against `ca.pem`, and reads the expiry off the handshake — so what is watched
is the certificate actually being served, not a file on disk.
`TlsCertificateExpiringSoon` fires at 30 days and `TlsCertificateExpiryImminent`
at 7, one alert per certificate however many URLs serve it
([#91](https://github.com/Gerrrt/HomeLab/issues/91)). The same two rules read
the APC card's self-signed certificate, which is not trusted but does expire.

```bash
make certs ARGS="--host grafana.matrix.elysium --ip 10.0.99.20 --dns grafana --force"
```

Then restart whatever serves it. The CA does not change, so nothing needs
re-trusting. The alert resolves on the next probe of the new leaf, within a
couple of minutes of the restart.

Let it lapse and the failure is loud rather than quiet: the lab-CA probe
verifies, so an expired leaf fails it outright and `EndpointUnreachable` fires
for Grafana — alongside `up{job="grafana"}` going to 0, since Prometheus
verifies the same chain on its scrape.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `x509: certificate relies on legacy Common Name field` | No SAN | Reissue; the script always sets one, so this is an older certificate |
| `x509: certificate is valid for <name>, not <other>` | Reached by a name or IP not in the SANs | Reissue with the right `--host`/`--ip` |
| `x509: certificate signed by unknown authority` | The client does not trust the CA | Install `ca.pem` — step 4 |
| Browser rejects a certificate that `openssl verify` accepts | Leaf lifetime over 825 days, or an old cert | Reissue with the default lifetime |
| `no CA yet` | No `certificates/ca.pem` | Step 1 |
| `already exists`, and the path is a real certificate | Guard against clobbering a CA or leaf | `--force`, once you are sure |
| `already exists`, but you never issued one | The path is a *directory*, not a certificate — see below | `rmdir` it, then reissue. `--force` will not help |

### `already exists` for a certificate that does not exist

`certificates/` is gitignored, so a clean clone has nothing in it. Docker does
not fail on a missing bind-mount source — it creates a **directory** — so a
`make up` that ran before the certificates were issued leaves
`certificates/ca.pem` and the Grafana leaf behind as empty directories
([#69](https://github.com/Gerrrt/HomeLab/issues/69)).

`gen-certs.sh` then refuses to issue anything, because it tests for an existing
certificate with `-s`, and `-s` is true of a directory:

```console
$ ls -ld certificates/grafana.matrix.elysium-key.pem
drwxr-xr-x 2 you you 4096 ... certificates/grafana.matrix.elysium-key.pem
$ make certs ARGS="--host grafana.matrix.elysium --ip 10.0.99.20 --dns grafana"
error: certificates/grafana.matrix.elysium-key.pem already exists — pass --force to replace it
```

`--force` does not get you out of this, and it fails *worse*: it gets past the
guard, `openssl` then cannot write its output to a directory, and because the
script sends `openssl`'s stderr to `/dev/null` the run dies with no message at
all — it prints `issuing …` and exits 1.

Remove the directories first — `rmdir` rather than `rm -rf`, since it refuses
anything non-empty and these should be empty:

```bash
rmdir certificates/*.pem
```

Then issue them from step 1.

## Also worth knowing

The CA key is **not** passphrase-protected, which is a deliberate trade. A
passphrase is what made the previous leak survivable, but it also makes every
issuance interactive — which is how a lab ends up with one ancient certificate
nobody dares reissue. The exposure is bounded instead by the key never leaving
this host and never becoming a tracked file. To change that, add `-aes256` to
the CA key generation in [`gen-certs.sh`](../../scripts/gen-certs.sh) and accept
the prompt on every issue.
