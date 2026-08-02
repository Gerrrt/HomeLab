# ADR-0005: Encrypt secrets in-repo with SOPS and age

**Status:** Accepted · 2025-11

## Context

The repository committed a plaintext SNMP community string shared across the
firewall, the switch, the UPS and the server's BMC, plus Grafana `admin`/`admin`
alongside anonymous Admin access. Both are now public forever, because git
history keeps everything.

Any replacement had to satisfy four constraints:

- No plaintext credential in a tracked file, ever.
- Recoverable if the monitoring host dies — a secret that exists only on the box
  it protects disappears with the box.
- Auditable: it should be possible to see *that* a credential rotated.
- Deployable by one person with `make up`, without standing up a secrets server.

Options considered:

1. **Gitignored `.env`.** Trivial, and what most homelabs do. But the secrets
   exist in exactly one place, are in no backup, and nothing records that they
   ever changed. It also fails silently — a missing `.env` produces a subtly
   misconfigured stack rather than an error.
2. **HashiCorp Vault.** The correct answer at organisational scale, and absurd
   here: a highly-available service, an unseal ceremony, and a hard dependency
   whose own failure takes down the thing meant to monitor failures.
3. **SOPS + age.** Encrypted files committed to the repo, decrypted at deploy
   time with a local key.
4. **git-crypt.** Similar, but encrypts whole files, so a diff shows only that
   the blob changed — no visibility into which key rotated.

## Decision

SOPS with an age key.

SOPS encrypts values and leaves keys in plaintext, so
`git log -p secrets/observability.sops.yaml` shows *which* credential changed
and when, without revealing what it changed to.

The age private key lives at `~/.config/sops/age/keys.txt` on the deployment
host and never enters the repository. `scripts/render-config.sh` decrypts in
memory at deploy time and writes only to gitignored paths.

Each device gets its own SNMP community rather than one shared string.

## Consequences

- The ciphertext is public. Security rests entirely on age's X25519 encryption
  and on the private key staying private — an explicit and understood tradeoff,
  and the reason the key is never committed.
- Losing `keys.txt` means every secret must be re-created, not recovered. The
  bootstrap script warns about this loudly; backing that file up off-host is a
  hard requirement.
- One extra tool on the deployment host (`sops`, plus `age` for bootstrap).
- `snmp_exporter` does no environment expansion and reads its config once at
  startup, so the community strings must be substituted into a real file. That
  file is written to a gitignored `.rendered/` directory — the tracked
  `snmp.yaml` keeps its `${PLACEHOLDERS}`, and CI asserts nothing rendered is
  ever tracked.
- Per-device communities mean four values to rotate instead of one. That is the
  point: one captured SNMPv2c packet no longer yields read access to every
  device on the network.
- CI can verify encryption without any ability to decrypt, by asserting each
  `secrets/*.sops.yaml` carries a `sops:` metadata block.
