# Runbook: Generate the internal CA and leaf certificates

**Target:** the lab's own PKI, under `certificates/`
**Time:** a couple of minutes
**You will need:** nothing but `openssl` and this repository

The previous CA and leaf keys were committed to this public repository and had
to be removed by rewriting every commit — see
[`purge-git-history.md`](purge-git-history.md). Treat anything issued before
that rewrite as compromised, including the CA. What follows replaces it.

> **Nothing in the stack terminates TLS yet.** Prometheus, Alertmanager, Loki
> and Grafana all publish plain HTTP on the management VLAN. Putting Grafana
> behind TLS is tracked separately in [`roadmap.md`](../roadmap.md), and it is
> the first thing that will consume a certificate from here. The CA exists now
> so that it is created deliberately, once, rather than improvised on the day
> something needs it.

## Where things live

Everything lands in `certificates/`, which is gitignored — as are `*.pem` and
`*.key`. That is the control that matters. File modes are useful; not being a
tracked file is what stops a repeat of the last leak, and both `make validate`
and CI assert it.

| File | Mode | Secret? |
| --- | --- | --- |
| `certificates/ca-key.pem` | 0600 | **yes** — never copy it off this host |
| `certificates/ca.pem` | 0644 | no — this is what clients trust, distribute freely |
| `certificates/<host>-key.pem` | 0600 | **yes** — belongs only to that service |
| `certificates/<host>.pem` | 0644 | no |

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
make certs ARGS="--host grafana.matrix.elysium --ip 10.0.99.20"
```

Include `--ip` for anything reached by address. `docs/roadmap.md` still lists
internal DNS as unresolved, so in practice most services here are reached by IP,
and a certificate without a matching IP SAN will be rejected at the point you
most want it to work.

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
lab with one certificate is better served by a calendar reminder than by a
renewal daemon nobody maintains.

```bash
make certs ARGS="--host grafana.matrix.elysium --ip 10.0.99.20 --force"
```

Then restart whatever serves it. The CA does not change, so nothing needs
re-trusting.

Adding blackbox-exporter for TLS-expiry checks is on
[`roadmap.md`](../roadmap.md); until that exists, expiry is something you find
out about from a browser warning.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `x509: certificate relies on legacy Common Name field` | No SAN | Reissue; the script always sets one, so this is an older certificate |
| `x509: certificate is valid for <name>, not <other>` | Reached by a name or IP not in the SANs | Reissue with the right `--host`/`--ip` |
| `x509: certificate signed by unknown authority` | The client does not trust the CA | Install `ca.pem` — step 4 |
| Browser rejects a certificate that `openssl verify` accepts | Leaf lifetime over 825 days, or an old cert | Reissue with the default lifetime |
| `no CA yet` | No `certificates/ca.pem` | Step 1 |
| `already exists` | Guard against clobbering a CA or leaf | `--force`, once you are sure |

## Also worth knowing

The CA key is **not** passphrase-protected, which is a deliberate trade. A
passphrase is what made the previous leak survivable, but it also makes every
issuance interactive — which is how a lab ends up with one ancient certificate
nobody dares reissue. The exposure is bounded instead by the key never leaving
this host and never becoming a tracked file. To change that, add `-aes256` to
the CA key generation in [`gen-certs.sh`](../../scripts/gen-certs.sh) and accept
the prompt on every issue.
