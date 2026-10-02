# ADR-0076: Provision lab guests with OpenTofu, and encrypt its state from the first apply

**Status:** Accepted · 2026-10

## Context

[ADR-0074](0074-build-the-lab-templates-with-packer-from-phoenix.md) makes
templates. Something has to turn them into guests:

- ADR-0029's six domain guests
- [#421](https://github.com/Gerrrt/HomeLab/issues/421)'s attack VM and targets
- whatever Linux guest comes next

These are repeated shapes, and the estate has no way to express them.
[#445](https://github.com/Gerrrt/HomeLab/issues/445) asks for one.

The tool comes with a hazard that decides the design. **A Terraform state file
stores every value a provider touched, in cleartext.** For this estate that
means the cloud-init password of every Linux guest and anything read from a
secrets store. Ephemeral values do not yet cover the Proxmox provider's data
sources. If that file landed in this repository unchanged, it would undo three
ADRs in one commit:

- [ADR-0005](0005-secrets-with-sops-and-age.md): values encrypted, keys left in
  plaintext.
- [ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md):
  a recipient per stack.
- [ADR-0024](0024-hold-a-second-age-recipient-and-prove-each-one-separately.md):
  a proof per recipient.

It would also do it **quietly**. A plaintext state looks like any other JSON
file until someone reads it.

Four facts constrain the answer.

- **OpenTofu encrypts state, and Terraform does not.** That is the property
  this ADR picks OpenTofu for. The licence change is incidental.
- **OpenTofu has no age key provider.** Its key providers are `pbkdf2` (a
  passphrase), three cloud KMSes, OpenBao, and `external` (a program).
- **`phoenix` holds no age key.**
  [ADR-0043](0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)
  part 2 rules it out, and ADR-0074 §4 relied on that when it kept the
  Proxmox token in `~/.config/proxmox/phoenix.env`.
- **The six domain guests already exist.** They were built by hand on
  2026-09-24 and 25, and two of them are domain controllers.

## Decision

**1. OpenTofu, in a top-level `tofu/`.** It is not a stack, for ADR-0074 §1's
reason: `scripts/stacks.sh` fails on a directory under `stacks/` with no
`compose.yaml`. The tree is:

- **`versions.tf`**: the pins. The local backend is at `tofu/state/lab.tfstate`
  on `phoenix`.
- **`encryption.tf`**: the encryption, self-contained (§3).
- **`providers.tf`**: the provider. It reads `PROXMOX_VE_ENDPOINT` and
  `PROXMOX_VE_API_TOKEN` from `phoenix.env`.
- **`modules/guest/`**: one guest.
- **`guests.tf`**: the guests and their pools.

The provider is `bpg/proxmox`, pinned exactly. Provider configuration is never
written to state, so the token stays where ADR-0074 put it.

**2. The state key is a passphrase, kept beside the token, and escrowed to the
estate's age recipients.**

- **Where it lives.** The `pbkdf2` key provider reads `TF_VAR_state_passphrase`
  from `phoenix.env`. That is the same file, mode and host as the token, and
  ADR-0074 §4's argument covers it.
- **Its escrow copy.** `secrets/tofu.sops.yaml` matches the catch-all rule in
  `.sops.yaml`, so it is encrypted to the estate key and to ADR-0024's second
  recipient, the same two that hold `observability.sops.yaml`.
- **Who can read the escrow.** Writing it needs only the public keys, so
  `phoenix` writes the escrow copy and can never read it. `prometheus` and the
  offline medium can. This is "keyed from the same age material the estate
  already holds", as the issue asked, without moving that material.

Two alternatives were rejected.

- **An age key on `phoenix`, unwrapped through the `external` key provider.**
  That would have followed the issue's wording to the letter. It is rejected
  because it reverses ADR-0043 part 2 and ADR-0074 §4 for a property the escrow
  already gives. ADR-0043's reason still holds: `phoenix` builds machines and
  converges nothing, and a host with the age key can render any stack.
- **A passphrase with no escrow.** That makes losing `phoenix`'s disk the same
  as losing the state. The guests could be re-imported, so that loss would be
  recoverable, but it would not be free.

**3. Encryption is enforced on state and plan, and proved rather than assumed.**

- **Enforcement.** `encryption.tf` sets `enforced = true` in both blocks and
  declares no `unencrypted` method and no `fallback`. A configuration that
  would write plaintext is refused at `init`.
- **The proof file.** The file holds everything the encryption needs, so that
  `scripts/check-tofu-state-encryption.sh --self-test` can copy it unchanged
  next to a built-in `terraform_data` canary. That test needs no provider and
  no Proxmox.
- **What the self-test proves**, in CI, through `scripts/self-tests.sh`:
  - The canary is absent from the encrypted state.
  - The plan is ciphertext.
  - A wrong passphrase cannot read the state.
  - `enforced` refuses an unencrypted method.
  - **Without the file, the canary is present.** A grep that has never been
    seen to fail proves nothing by staying quiet.

**4. Four guards land before the first apply, not after.**

- **`.gitignore`**: `*.tfstate`, `*.tfstate.*`, `*.tfplan`, `**/.terraform/`
  and `tofu/state/`.
- **`scripts/check-tracked-artefacts.sh`**: the same patterns, unanchored like
  its others. It gains a `--self-test` that force-adds each one to a scratch
  repository and requires it to be named. `git add -f` walks past
  `.gitignore`, and the check had never been seen to fail.
- **`.gitleaks.toml`**: a `tfstate-plaintext` rule on
  `"terraform_version": "<digit>`. It keys on content, so it catches a
  plaintext state under any name. OpenTofu's encrypted wrapper does not carry
  the field, so the encrypted state in `phoenix`'s checkout scans clean without
  an allowlist entry. If the rule goes red there, encryption is off.
- **[`docs/security.md`](../security.md) § Secrets**: `phoenix` is recorded as
  a secret-bearing host, the way `prometheus` is.

**5. Guests are full clones.** `full = true` is written in the module, not
exposed as a variable. ADR-0074 §2 rebuilds a template in place, and a linked
clone would block or orphan that rebuild.

**6. A pool exists exactly while it groups a guest.** Pools are derived from
the guests' `pool` field, not declared beside them:

- a new pool name creates the pool;
- the last guest leaving a pool destroys it.

`PhoenixBuilder` gains `Pool.Allocate` on `/pool/<name>` for each pool. It is
granted on that path and never at `/`, which is ADR-0043's rule, and each grant
is recorded in [`provision-lab-guests.md`](../runbooks/provision-lab-guests.md).
It is not granted on `/pool` either. That would let the token create, empty
and delete any pool, including ones this tree does not own, to save a
re-grant.

**7. The six domain guests are left alone.** Importing a domain controller into
a tool whose next plan might replace it is the wrong first apply. The six stay
hand-managed until [#448](https://github.com/Gerrrt/HomeLab/issues/448), or an
evaluation rebuild from 911 or 912, brings them in. The first guest this tree
manages is a proof guest:

- **What it is.** VMID 998, cloned from 901, in a `proof` pool, tagged
  `disposable`.
- **When it exists.** Only under `-var proof=true`.
- **Why it exists.** Its cloud-init password is a `random_password`. That puts
  a real secret, sent by the real provider, into the real state, so the
  runbook can grep for it and find nothing.

## Consequences

- **Two proofs run on `phoenix` after the first apply, and the issue stays
  open until they have.**
  - The proof guest's password does not occur in `tofu/state/lab.tfstate`, and
    `scripts/check-tofu-state-encryption.sh` says so.
  - `git add` of that file is refused, and with `-f` it turns `make validate`
    red.

  The runbook records both as run.
- **The escrow copy rides on the catch-all rule's recipients.** A change to
  that rule needs `sops updatekeys secrets/tofu.sops.yaml` as well as the
  observability file. Proving either recipient through ADR-0024 proves this
  file can be opened, because it is the same keys.
- **Losing `phoenix` costs the passphrase's round trip, not the state.** The
  state can only be recovered if its file is: it is on `phoenix`'s disk, and in
  `phoenix`'s backups once ADR-0053's PBS takes them. The passphrase is
  recovered from escrow on `prometheus`.
- **`phoenix` now holds four secrets:**
  - the API token
  - the Windows build password
  - the state passphrase
  - the encrypted state

  None of them is an age key. `docs/security.md` lists them.
- **A destroyed pool takes its grant with it.** Proxmox's pool delete removes
  the ACL on `/pool/<name>`. Recreating a pool that this tree destroyed
  therefore needs root on `Saruman` to grant the path again first. For the
  proof pool that is a line in the runbook, run before each proof. For a pool
  that lives with long-lived guests, it happens only if the pool empties. That
  cost is accepted, rather than widening the grant to `/pool`.
- **CI runs tofu without Proxmox.** `scripts/lint.sh` runs `fmt -check`, and
  `validate` after `init -backend=false -lockfile=readonly`.
  `scripts/self-tests.sh` runs the encryption proof. Both use the image pinned
  in `stacks/observability/compose.yaml`. `tofu/versions.tf` requires
  `~> 1.13.0`, so a minor bump of that image turns lint red until the version
  that encrypts the state is moved on purpose.
- **#421's range is not expressible yet.** `ifrit` is not bought, and a
  template belongs to one node. The module takes `node`, so the range is a
  second node's guests in this tree rather than a second tree.
- **Reopened by:**
  - OpenTofu gaining an age key provider, at which point §2's escrow becomes
    the key itself;
  - `phoenix` acquiring an age key for some other reason;
  - the six coming under this tree, which is #448's to decide.
