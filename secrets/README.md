# Secrets

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) using an
[age](https://github.com/FiloSottile/age) key, committed in encrypted form, and
decrypted only in memory at deploy time.

| File | In this repo? | Encrypted? | Contains |
| --- | --- | --- | --- |
| `observability.example.yaml` | yes | no | Key names and placeholder values |
| `observability.sops.yaml` | **not yet** — created by `make secrets-init`, then committed | **yes** | Real credentials |
| `~/.config/sops/age/keys.txt` | **never** | n/a | The private key |

> `observability.sops.yaml` is deliberately absent from the repository right
> now. Encrypting it requires an age keypair, and generating that keypair here
> would mean either committing a private key or encrypting to a key nobody
> holds. `make secrets-init` creates both on the machine that will run the
> stack; the encrypted result is then committed as normal. Until that has been
> run, `make up` fails with a clear error rather than starting a stack with
> default credentials.

## Why encrypted-in-git rather than a gitignored `.env`

A gitignored `.env` keeps secrets out of the repository, but it also keeps them
out of any backup, review or history. When the host dies, the secrets die with
it, and nothing records that a value ever changed.

Committing them encrypted keeps one copy alongside the config it belongs to.
`git log -p secrets/observability.sops.yaml` shows *when* a credential rotated
without showing what it rotated to: SOPS encrypts values and leaves keys in
plaintext.

The tradeoff is that the ciphertext is public. It is only as strong as age's
X25519 encryption and the secrecy of the private key — so the private key never
enters the repository, and losing it means re-keying every secret rather than
recovering them.

## First-time setup

```bash
make secrets-init
```

This generates an age keypair at `~/.config/sops/age/keys.txt`, writes the
public half into `.sops.yaml`, and encrypts `observability.example.yaml` into
`observability.sops.yaml` for you to fill in.

**Back up `~/.config/sops/age/keys.txt` somewhere outside this machine.**
Without it the encrypted file is unrecoverable.

## Editing

```bash
make secrets-edit
```

Decrypts to a temporary file, opens `$EDITOR`, re-encrypts on save. The
plaintext never lands on disk unencrypted.

## How they reach the containers

`scripts/render-config.sh` runs before `docker compose up`. It decrypts this
file, exports the values as environment variables, and:

- writes `stacks/observability/.env` with only the values compose interpolates
  (the Grafana credentials);
- renders `snmp-exporter/snmp.yaml`'s `${SNMP_COMMUNITY_*}` placeholders into
  `snmp-exporter/.rendered/snmp.yaml`, which is what the container mounts;
- writes `alertmanager/.rendered/webhook_url`, because Alertmanager does not
  expand environment variables and reads receiver URLs via `url_file`.

All three are gitignored, and each secret is written to exactly one of them.
Nothing writes a secret into a tracked file.

## Rotating

See [`docs/runbooks/rotate-snmp-community.md`](../docs/runbooks/rotate-snmp-community.md).

> **Note on this repository's history.** Earlier commits contained a plaintext
> SNMP community string shared across all four devices, and encrypted TLS
> private keys. Both must be treated as compromised regardless of the current
> file contents — removing a secret in a later commit does not remove it from
> git history. See
> [`docs/runbooks/purge-git-history.md`](../docs/runbooks/purge-git-history.md).
