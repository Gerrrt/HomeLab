# ADR-0116: Build the range's attack VM with OpenTofu, and prove it with a script

**Status:** Accepted · 2026-11 · amends [ADR-0076](0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md)

## Context

[ADR-0076](0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md)
put "#421's attack VM and targets" in OpenTofu's scope, and expected the range
to be "a second node's guests in this tree rather than a second tree". When
the range was built on `gandalf`
([ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md),
[ADR-0106](0106-name-the-range-host-gandalf-and-leave-ifrit-to-its-disabled-amt.md)),
its attack VM, `ragnarok`, was made by `scripts/make-attack-vm.sh` instead,
outside the pipeline. The 2026-11-11 audit found that, and the owner chose to
bring it into `tofu/`
([#1443](https://github.com/Gerrrt/HomeLab/issues/1443)).

Two things stood in the way.

- **The tree had one provider, read from the environment.**
  `PROXMOX_VE_ENDPOINT` and `PROXMOX_VE_API_TOKEN` in `phoenix.env` name
  `Saruman`. `gandalf.env` names `gandalf`, but in the curl scripts' own
  variables (`PROXMOX_URL`, `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET`).
- **`ragnarok` is more than a clone.** Its isolation is in three parts:
  - `net1` on `vmbr1` with no gateway;
  - forwarding off, persistently, in `99-no-forward.conf`;
  - a proof after every make that forwarding is off and nothing NATs.

  That proof runs over SSH, against a host key read through the guest agent
  ([ADR-0085](0085-check-the-lab-domains-host-keys-against-keys-read-through-the-guest-agent.md)).

## Decision

**One tree and one state, with an aliased provider for `gandalf`.**
`provider "proxmox" { alias = "gandalf" }` takes its endpoint and token from
`TF_VAR_gandalf_endpoint` and `TF_VAR_gandalf_api_token`, two new lines in
`phoenix.env`. Their names collide with nothing there, so every runbook step
that sources `phoenix.env` before a plan works unchanged. `gandalf.env`, which
overrides the curl scripts' `PROXMOX_*` names, is not needed for a plan. The
token is then in two mode-600 files on `phoenix` rather than one. A provider's
variables are not written to state. TLS is verified against `gandalf`'s CA, which `phoenix`
already trusts.

**OpenTofu makes the VM.** `ragnarok` is `module.range_guest` in
`tofu/guests.tf`: the same guest module as every other lab guest, called with
the `gandalf` provider. It is a full clone of 902 on `range` with:

- `net0` on `vmbr0`, DHCP, its MAC pinned;
- `net1` on `vmbr1` at `172.30.30.10/24` with no gateway, through the module's
  new `extra_networks`;
- both firewall flags off;
- cloud-init user `kali` with `phoenix`'s key.

It is in no pool, because the token on `gandalf` holds no pool grant and this
keeps it so.

**A script finishes and proves it, after every apply.**
`scripts/make-attack-vm.sh` becomes `scripts/finish-attack-vm.sh`. It no
longer clones or configures, and refuses to run if 130 does not exist. It:

- reads the config back, including `net1`'s address and the absent gateway;
- starts the guest if it is stopped;
- writes `99-no-forward.conf` over the host-key-checked SSH;
- runs §8's third check.

The sysctl file stays in the script rather than in cloud-init. A cloud-init
snippet would have tofu upload it to `gandalf` over SSH, a second credential
path into the range host for one file.

**The range is still rebuilt, not repaired.** ADR-0017's rule is unchanged.
What changes is the tool: a change to `ragnarok` is a destroy and apply of
130, then `finish-attack-vm.sh`.

This amends ADR-0076 in two places. Its single, environment-read provider
gains an alias. Its expectation that the range is "a second node's guests in
this tree" is carried out, for the attack VM.

## Alternatives considered

- **A second tree for the range,** with its own state and its own passphrase
  to escrow, and the provider's environment variables from `gandalf.env`. A
  `Saruman` plan would never need `gandalf` powered on. Declined by the owner
  for one state and one plan, at the cost below.
- **All of it in cloud-init,** the sysctl file included, with the script
  reduced to the proof. Declined for the credential it needs, as above.
- **Leave `ragnarok` script-built,** and supersede that part of ADR-0076's
  scope. Declined: the guest the range's isolation depends on would be the
  one guest the pipeline cannot rebuild.

## Consequences

- **Every plan reads `gandalf`.** `gandalf` must be up, even for a plan that
  touches only `Saruman`. `gandalf` is off between sessions (ADR-0017), so a `Saruman`-only
  change waits for it, or is planned with `-target`.
- **The script's §8 proof still runs after every make.** An apply that is not
  followed by `finish-attack-vm.sh` leaves a VM whose forwarding has not been
  turned off. `build-the-playground.md` §5 says so, in that order.
- **The `/vms/130` grant goes with every destroy.** It was already the case
  with the script, and the script still checks for it first.
- **The first apply replaces the script-built `ragnarok`.** Importing a guest
  that tofu did not clone plans a replace, because `clone` cannot be read back
  ([`build-the-lab-domain.md`](../runbooks/build-the-lab-domain.md)). The
  range is disposable, so the runbook destroys 130 and applies, and does not
  import.
- **Reopened by:**
  - the targets of #421 joining the tree, which would make the range a larger
    share of every plan;
  - `gandalf` gaining the snippet storage and SSH access that a cloud-init
    sysctl file would need, for some other reason.
