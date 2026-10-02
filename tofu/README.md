# tofu

The lab's guests, cloned from [`packer/`](../packer/README.md)'s templates
through `Saruman`'s API, from `phoenix` ([ADR-0076]). How to run it is
[`provision-lab-guests.md`][runbook]. This page is the map.

```bash
set -a; . ~/.config/proxmox/phoenix.env; set +a
tofu -chdir=tofu init
tofu -chdir=tofu plan -out=next.tfplan
tofu -chdir=tofu apply next.tfplan && rm tofu/next.tfplan
```

## What is here

- `versions.tf` pins tofu, `bpg/proxmox` and `random`, and sets the local
  backend at `state/lab.tfstate`. `.terraform.lock.hcl` pins the providers'
  hashes and is committed.
- `encryption.tf` encrypts state and plans with a passphrase from
  `phoenix.env`, and refuses to write either unencrypted. It is
  self-contained, because CI copies it as it stands to prove it.
- `providers.tf` reads the endpoint and the token from the environment, so
  neither is ever written to state.
- `guests.tf` lists the guests. The pools are derived from them, so a pool
  lives exactly as long as a guest in it does. Today it holds only the proof
  guest, 998, and only under `-var proof=true`.
- `modules/guest/` makes one full clone, with the flags the hand-built guests
  have.

## Rules this tree keeps

- **State is never plaintext, and never tracked.** `enforced = true` refuses a
  plaintext write. `.gitignore`, `scripts/check-tracked-artefacts.sh` and the
  `tfstate-plaintext` rule in `.gitleaks.toml` each catch a state that got
  out. `scripts/check-tofu-state-encryption.sh --self-test` proves every one
  of those can fail.
- **Full clones only**, because `packer build -force` rebuilds a template at
  the same VMID (ADR-0074).
- **The six domain guests are not here.** They were built by hand, and #448
  decides when they move.
- **CI proves that the tree parses and that the encryption holds. `phoenix`
  proves that it applies.** `scripts/lint.sh` runs `fmt -check` and
  `validate`, and `scripts/self-tests.sh` runs the encryption proof. Both use
  the image `stacks/observability/compose.yaml` pins. A change here is only
  finished once the runbook's §4 has passed against a real apply.

[ADR-0076]: ../docs/adr/0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md
[runbook]: ../docs/runbooks/provision-lab-guests.md
