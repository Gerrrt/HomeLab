# Runbook: Build the sensitive tier's certificate authority

**Target:** step-ca on `trinity` (`10.0.99.40`), minted on `prometheus` (`10.0.99.20`)
**Time:** twenty minutes, across two hosts
**You will need:** a shell on both hosts, this repository checked out on each,
and `secrets/sensitive.sops.yaml` already created on `trinity`
(`make secrets-init STACK=sensitive`)

This is the tier's own CA — **not** the estate's, and not beneath it.
[`generate-certificates.md`](generate-certificates.md) opens with the table
that tells the two apart, and
[ADR-0035](../adr/0035-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md)
is why they are two: the estate's root carries `pathlen:0`, so a leaf beneath
any intermediate of it fails `path length constraint exceeded` in every client
this estate runs. Once this runbook is done, no certificate on the tier is
ever issued by hand again: Caddy asks step-ca over ACME for every name it
serves and renews each seven-day leaf on its own.

## What moves where, and what never does

| Artefact | Made on | Lives on | Travels? |
| --- | --- | --- | --- |
| `certificates/tier-ca/` — the whole tree, root key included | `prometheus` | `prometheus` | **No.** This is the CA |
| `certificates/tier-ca/secrets/root_ca_key` | `prometheus` | `prometheus`, and the age key's offline copy | **Never to `trinity`.** The install refuses a bundle that carries it |
| `certificates/tier-ca-bundle.tar` — config, both certificates, the intermediate's encrypted key | `prometheus` | `trinity`'s `step-ca-data` volume | Yes, once, by `scp`; delete the copy on `trinity` afterwards |
| `certificates/tier-ca.pem` — the root certificate | `prometheus` | Both hosts, and every device that reaches the tier | Yes, freely. Public |
| `STEPCA_PASSWORD` | You, with `make gen-secret` | `secrets/sensitive.sops.yaml` on `trinity` | To `prometheus` once, in a file, for the mint; shredded after |

The intermediate's key is encrypted at rest with `STEPCA_PASSWORD`, and so
is the root's. `trinity`'s age key opens the tier's secrets and `prometheus`'s
does not, so the root key on `prometheus` is inert without a password that
host cannot decrypt — using it is a two-host operation on purpose.

## 1. The password, on `trinity` first

```bash
make gen-secret
make secrets-edit STACK=sensitive      # STEPCA_PASSWORD: paste it
```

It has to be in SOPS *before* the mint, because the mint is where a second
copy is easiest to get wrong: `--mint` takes the password from a file and
step encrypts both keys with it, and if the value in SOPS differs by so much
as a trailing newline, step-ca on `trinity` cannot open its own key and the
container never goes healthy. Write it to a file for the trip to
`prometheus` — the script strips a trailing newline, so `printf` or an
editor both work — and shred that file when the mint is done.

## 2. Mint, on `prometheus`

```bash
make tier-ca ARGS="--mint --password-file /path/to/password"
```

Omit `--password-file` to be prompted instead. The script runs `step ca init`
in the pinned step-ca image — nothing is installed on the host — against
`certificates/tier-ca/`, mounted where the service will later run from, and
then adds the ACME provisioner against the resulting `config/ca.json` with
the three restrictions ADR-0035 decided: `tls-alpn-01` only, seven-day
leaves, nothing longer. It refuses to run over an existing tree without
`--force`, because a new root invalidates every device that trusts the old
one.

Before it reports success it proves the result rather than trusting step:
the intermediate verifies against the root, the root is a CA, the
provisioner in `ca.json` carries exactly those claims, every path in
`ca.json` is one the service container will see, and the bundle it builds
does not contain the root key. It prints the root's SHA-256 fingerprint;
keep that line, you compare against it in step 4.

```text
ok — minted
  tree     certificates/tier-ca   (stays here; holds the root key)
  root     certificates/tier-ca.pem   (public — this is what devices trust)
  bundle   certificates/tier-ca-bundle.tar   (what travels to trinity; no root key)
  root SHA256 5C:35:…
```

Then, still on `prometheus`:

```bash
shred -u /path/to/password
```

> [!CAUTION]
> **`certificates/tier-ca/secrets/root_ca_key` stays on this host.** The
> bundle is built by listing files by name and never `secrets/` as a
> directory; `--install` refuses a bundle that carries the root key whatever
> built it. Copy the bundle. Do not `scp -r certificates/tier-ca`.

Add the root key to the offline copy that holds the age key
([`back-up-the-age-key.md`](back-up-the-age-key.md)). It is useless without
`STEPCA_PASSWORD`, which is in SOPS, so the backup of the tier's root is
that copy plus this file — and losing both costs a new root and a re-trust on
every household device, not an outage: the intermediate on `trinity` keeps
issuing for its whole lifetime without it.

## 3. Carry the bundle to `trinity`

Both hosts are on Winterfell, so unlike the lab guest's certificate this is
one hop and no Mac. From `prometheus`:

```bash
ssh <you>@10.0.99.40 'mkdir -p HomeLab/certificates && chmod 700 HomeLab/certificates'
scp -p certificates/tier-ca-bundle.tar <you>@10.0.99.40:HomeLab/certificates/
```

`-p` keeps the mode (`0600`). The bundle holds the intermediate's key,
encrypted; treat it as a secret in transit and delete the copy on `trinity`
once step 4 has read it.

## 4. Install, on `trinity`

```bash
make tier-ca ARGS="--install certificates/tier-ca-bundle.tar"
```

That creates the `step-ca-data` volume with the labels compose stamps on its
own volumes — so `make up` adopts it silently rather than warning that it
"was not created by Docker Compose" — extracts the bundle into it as root,
hands the tree to step's uid with `secrets/` closed to `0700`, and writes
`certificates/tier-ca.pem` from the bundle's root certificate, which is what
`compose.yaml` mounts into Caddy as the trusted root for the ACME directory.
It refuses a volume that already holds a CA without `--force`, because
installing over one replaces the intermediate every leaf on the tier chains
to.

It ends by reading the intermediate back out of the volume as the service's
own uid and printing the root's fingerprint:

```text
  root SHA256 5C:35:…   (compare with what --mint printed)
```

**Compare it.** Same fingerprint, same root; anything else and the bundle is
not the one you minted.

```bash
shred -u certificates/tier-ca-bundle.tar
make up STACK=sensitive
```

`make render` now passes — the tier's root is the only file under
`certificates/` this stack mounts — and `make up` starts step-ca, waits for
it to go healthy, then starts Caddy, which asks it for a certificate before
serving a byte.

## 5. Verify — the certificate Caddy is serving, not the files on disk

On `trinity`:

```bash
docker logs sensitive-caddy 2>&1 | grep -i 'certificate obtained'
```

One line per name in the `Caddyfile`, within a few seconds of the start.
Then the handshake itself, verified against the tier's root:

```bash
openssl s_client -connect 127.0.0.1:443 -servername trinity.matrix.elysium \
  -CAfile certificates/tier-ca.pem </dev/null 2>/dev/null \
  | grep -E 'Verify return|^issuer='
```

`Verify return code: 0 (ok)` and an issuer of `Matrix Elysium Sensitive Tier
Intermediate CA`. The `notAfter` a week out is the design, not a mistake:

```bash
openssl s_client -connect 127.0.0.1:443 -servername trinity.matrix.elysium \
  </dev/null 2>/dev/null | openssl x509 -noout -dates
```

From Hicks, in a browser, `https://trinity.matrix.elysium/` should warn until
step 6 and answer `404` after it — nothing is routed yet, and the 404 is the
tier's own text, which proves the whole path: name, firewall, Caddy, CA.

This was proved once on the monitoring host, against a throwaway root, under
a throwaway compose project name, before the runbook was written. The stack
booted, step-ca went healthy, Caddy obtained a leaf for
`trinity.matrix.elysium` over `tls-alpn-01` from inside the compose network,
and the handshake verified against `tier-ca.pem`. `TIER_CA_PROJECT` in
`scripts/tier-ca.sh` exists for repeating that rehearsal without touching a
volume the real project would adopt.

## 6. Trust the root on every device that reaches the tier

Distribute `certificates/tier-ca.pem` — never anything else out of
`certificates/tier-ca/`. The operator's devices end up trusting two roots,
the estate's and this one; the household's trust only this one.

```bash
# Debian/Ubuntu
sudo cp certificates/tier-ca.pem /usr/local/share/ca-certificates/matrix-elysium-tier.crt
sudo update-ca-certificates
```

Firefox keeps its own store: **Settings → Privacy & Security → Certificates →
View Certificates → Authorities → Import**. On a phone, install it as a
certificate profile and — on iOS — enable full trust for it under
**General → About → Certificate Trust Settings**, without which the profile
sits installed and untrusted.

## Adding a service

Three lines, in one commit, or the first issuance fails:

1. A site block in the `Caddyfile` under the service's name.
2. That name under the `caddy` service's `networks.sensitive.aliases` in
   `compose.yaml` — step-ca validates the challenge by dialling the name on
   443 from inside the compose network, and Docker's resolver answers with
   Caddy's address only for names Caddy carries. Missing this fails with a
   DNS error at the CA, in Caddy's log, on the first `make up`.
3. A host override on `morpheus` so browsers resolve it
   ([`add-a-host-override.md`](add-a-host-override.md)).

No certificate step. That is the point of this runbook.

## When things change

| Situation | What to do |
| --- | --- |
| `trinity` is rebuilt, or its disk is lost | Step 4 again with the bundle still on `prometheus`; step 5 to confirm. The ACME accounts and issued leaves in step-ca's database are disposable — every leaf is re-issued within a week regardless |
| The intermediate is suspected compromised | On `prometheus`, `make tier-ca ARGS="--mint --force"` mints a new root **and** intermediate — the root changes too, so every device re-trusts. Re-minting only the intermediate beneath the existing root is `step certificate create` against `certificates/tier-ca/` and is not scripted; ADR-0035 leaves it to the day it is needed |
| The root key on `prometheus` is lost | Nothing stops. The intermediate issues until 2036 without it. Before then, a new root: `--mint --force`, step 3 onward, and a re-trust on every household device |
| `STEPCA_PASSWORD` is lost | Both keys are unrecoverable; treat as the row above |
| step-ca is down | Caddy keeps serving each leaf until it expires, at least two days and at most seven after the CA stopped answering. Nothing pages on it yet ([#426](https://github.com/Gerrrt/HomeLab/issues/426)) — `docker ps` on `trinity` is the check until it does |

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `make render` stops with *do NOT run `make certs ARGS=--ca` here* | `certificates/tier-ca.pem` is missing on `trinity` | Step 4. Do not do what the estate's error message would have said |
| step-ca never goes healthy; log says it cannot decrypt the key | `STEPCA_PASSWORD` in SOPS differs from what `--mint` was given | Fix SOPS if the file was right, or `--mint --force` with the SOPS value and step 3 onward |
| step-ca log: `open /tree/…: no such file` or any path outside `/home/step` | The tree was minted at the wrong mount point (a script older than this runbook) | `--mint --force` with the current script; it refuses to report a tree whose paths are wrong |
| Caddy log: `no such host` for a name, from the CA | The name is in the `Caddyfile` and not in `compose.yaml`'s aliases | Add the alias, `make up STACK=sensitive` |
| Caddy log: `x509: certificate signed by unknown authority` dialling `step-ca` | `/etc/caddy/tls/ca.pem` is not this CA's root — the estate's `ca.pem` was copied in by hand | Step 4 rewrites `tier-ca.pem` from the bundle |
| `--install` refuses: *already holds a CA* | The volume was populated before | `--force` only if replacing the intermediate is what you mean |
| `--install` refuses: *contains secrets/root_ca_key* | Someone tarred the tree by hand | Rebuild with `--mint` on `prometheus`; delete this copy |
| Browser warns after step 6 | The wrong root was imported, or Firefox's own store was skipped | Import `tier-ca.pem`, and into Firefox separately |
