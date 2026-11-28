# ADR-0143: Back up `phoenix` nightly, for its OpenTofu state

**Status:** Accepted · 2026-11 · amends
[ADR-0053](0053-run-pbs-on-saruman-with-its-datastore-on-smaug-over-nfs.md)

## Context

[ADR-0053](0053-run-pbs-on-saruman-with-its-datastore-on-smaug-over-nfs.md)
backs up the Windows domain, `odin` and, since
[ADR-0091](0091-put-a-kali-purple-analyst-workstation-on-saruman.md),
`garuda`. It leaves out "`phoenix` or `golem` itself, which are rebuilt from
this repository". `build-the-backup-guest.md` §8 repeats that, and the job on
`Saruman` holds no `170`. The one backup of `phoenix` ever taken was §9's
proof, and §9 deletes it.

The recheck of `phoenix` on 2026-11-25 found that one file on it is not in
this repository and cannot be rebuilt from it: `tofu/state/lab.tfstate`.
[ADR-0076](0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md)
encrypts it and keeps it out of git on purpose, and `.gitignore` and
`check-tracked-artefacts.sh` refuse it. The passphrase is escrowed in
`secrets/tofu.sops.yaml`, but the file the passphrase opens is not escrowed
anywhere. [`provision-lab-guests.md`](../runbooks/provision-lab-guests.md)'s
recovery section says "Take it from `phoenix`'s backup", and no such backup
exists.

Losing the state does not lose a guest. It loses OpenTofu's record of them:
every guest in `tofu/guests.tf` would have to be imported by hand, with its
VMID, disks and cloud-init, before the next `tofu plan` could be trusted. The
rest of `phoenix` is rebuilt by
[`build-the-jumpbox.md`](../runbooks/build-the-jumpbox.md), and its secrets
are restored from escrow or re-issued.

## Decision

**`phoenix` (VMID `170`) joins the nightly backup job on `Saruman`**, with
the Proxmox tag `backup`, in snapshot mode like the rest. Its guest agent is
running, so vzdump freezes its filesystems for the snapshot. `phoenix` is
hand-built, like `odin`, so the tag comes from `qm set 170 --tags`, keeping
its existing tags. `GuestNotInBackupJob` then fires if the VMID ever drops
out of the job.

The whole guest is backed up rather than the one file. It is 30 GB, PBS
deduplicates it across nights, and a restore is §9's `qmrestore`, which the
proof already ran once on this same VMID.

Applied by hand on `Saruman` from `build-the-backup-guest.md` §8, because the
job is not in OpenTofu.

This amends ADR-0053's list of what is backed up. Its target, encryption,
retention and verify job are unchanged.

## Alternatives considered

- **Copy only the state file off `phoenix` on a timer.** It would be smaller.
  Declined: it is new code, with its own schedule, target and check, that
  does what the existing job already does and watches. It would also need a
  credential on `phoenix` to reach somewhere to write, and `phoenix` should
  not gain one.
- **Commit the encrypted state.** Declined. ADR-0076 keeps it out of git so a
  passphrase leak does not hand over every past version, and git keeps every
  version.
- **Accept the loss and fix the runbook's sentence.** Declined. Re-importing
  every guest in the lab by hand is days of work, and a nightly backup that
  already exists removes that cost.

## Consequences

- **The backup holds every secret `phoenix` holds.** That means the Proxmox
  tokens, the domain's passwords, the SSH key and the state, as `security.md`
  lists them. vzdump encrypts the chunks on `Saruman` with `golem.enc` before
  they leave, so the datastore on `smaug` holds ciphertext. Whoever holds
  `golem.enc` and the datastore can read them, and `golem.enc` lives on
  `Saruman`, whose `root` already owns `phoenix` and everything it builds. It
  is also escrowed as `PBS_ENCRYPTION_KEY` in `secrets/lab.sops.yaml`. No new
  holder is created.
- **`provision-lab-guests.md`'s recovery sentence becomes true** once this is
  applied: the state comes back with a restore of `170`, or as one file
  through PBS's file restore.
- **`alexander`, `gandalf`, `golem` and `eden` stay out**, for ADR-0053's and
  ADR-0081's reasons.
- **Reopened by:**
  - the state moving off `phoenix`, for instance to a remote backend;
  - `phoenix`'s disk growing until the nightly backup's size matters on
    `erebor`.
