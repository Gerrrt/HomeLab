# Secrets

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) using an
[age](https://github.com/FiloSottile/age) key, committed in encrypted form, and
decrypted only in memory at deploy time.

| File | In this repo? | Encrypted? | Contains |
| --- | --- | --- | --- |
| `observability.example.yaml` | yes | no | Key names and placeholder values |
| `observability.sops.yaml` | yes — created by `make secrets-init`, committed encrypted | **yes** | Real credentials |
| `~/.config/sops/age/keys.txt` | **never** | n/a | The private key |

> What is committed is ciphertext: the values are encrypted to the age
> recipients listed in [`.sops.yaml`](../.sops.yaml), and the key names are left
> in plaintext on purpose, so the set of required credentials is discoverable
> without holding a decryption key.
>
> On a host that holds none of those private keys, `make render` fails at
> decryption rather than starting the stack with defaults. To bring a second
> host in, run `make secrets-init` there to generate its keypair, add its public
> half to `.sops.yaml` as an additional recipient, and re-key the file with
> `sops updatekeys secrets/observability.sops.yaml` from a host that can already
> decrypt it. `secrets-init` refuses to overwrite an existing encrypted file.

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
Without it the encrypted file is unrecoverable — not "reset with some effort",
but gone, with every secret in it re-entered by hand on four devices. The
procedure, and the way to prove the backup actually decrypts, are in
[`docs/runbooks/back-up-the-age-key.md`](../docs/runbooks/back-up-the-age-key.md):

```bash
make secrets-verify-backup KEY=/path/to/the/copy
```

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
`make gen-secret` produces values safe for every consumer in this repo, and
`make snmp-verify` confirms a rotation landed without putting the community into
your shell history.

Which devices are actually rotated is recorded in
[`SECURITY.md`](../SECURITY.md), not here. One place to correct when it changes
is the only arrangement that survives the next rotation.

> **Note on this repository's history.** Earlier commits contained a plaintext
> SNMP community string shared across all four devices, and encrypted TLS
> private keys. Both must be treated as compromised regardless of the current
> file contents — removing a secret in a later commit does not remove it from
> git history. See
> [`docs/runbooks/purge-git-history.md`](../docs/runbooks/purge-git-history.md).
