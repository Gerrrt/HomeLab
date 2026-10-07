# tofu

[![host: phoenix](https://img.shields.io/badge/host-phoenix-30363d?style=plastic)](../docs/network.md#imaginationlan--vlan-30--lab)
[![VLAN 30: ImaginationLAN](https://img.shields.io/badge/VLAN%2030-ImaginationLAN-2ea043?style=plastic)](../docs/network.md#imaginationlan--vlan-30--lab)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-FFDA18?style=plastic&logo=opentofu&logoColor=black)](https://opentofu.org)
[![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-E57000?style=plastic&logo=proxmox&logoColor=white)](https://www.proxmox.com/en/proxmox-virtual-environment)

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
  lives exactly as long as a guest in it does. It holds ADR-0029's six domain
  guests (150–155), in the `lab-domain` pool, and the proof guest, 998, only
  under `-var proof=true`.
- `modules/guest/` makes one full clone, with the flags the hand-built guests
  have: q35, OVMF and an EFI disk, a TPM on Windows, and the MAC, SMBIOS UUID
  and startup order each guest is given.

## Rules this tree keeps

- **State is never plaintext, and never tracked.** `enforced = true` refuses a
  plaintext write. `.gitignore`, `scripts/check-tracked-artefacts.sh` and the
  `tfstate-plaintext` rule in `.gitleaks.toml` each catch a state that got
  out. `scripts/check-tofu-state-encryption.sh --self-test` proves every one
  of those can fail.
- **Full clones only**, because `packer build -force` rebuilds a template at
  the same VMID (ADR-0074).
- **The six domain guests keep their MACs and SMBIOS UUIDs.** `morpheus`'s
  reservations are keyed by MAC, and the endpoints' activation by the UUID.
  A rebuild is
  [`build-the-lab-domain.md`'s](../docs/runbooks/build-the-lab-domain.md#rebuild-from-the-pipeline),
  and it destroys with `-target=module.guest` so the pool's grant survives.
- **CI proves that the tree parses and that the encryption holds. `phoenix`
  proves that it applies.** `scripts/lint.sh` runs `fmt -check` and
  `validate`, and `scripts/self-tests.sh` runs the encryption proof. Both use
  the image `stacks/observability/compose.yaml` pins. A change here is only
  finished once the runbook's §4 has passed against a real apply.

[ADR-0076]: ../docs/adr/0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md
[runbook]: ../docs/runbooks/provision-lab-guests.md
