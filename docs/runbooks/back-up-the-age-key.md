# Runbook: Back up the age private key

**Target:** `~/.config/sops/age/keys.txt` on the monitoring host (10.0.99.20)
**Time:** five minutes, once
**You will need:** shell access to the monitoring host, and somewhere durable to
put a copy — a password manager, or paper and a place to keep it

This is the highest-value five minutes in the repository, and the only one whose
downside is unbounded.

## Why

That file is the sole copy of the private key that decrypts
[`secrets/observability.sops.yaml`](../../secrets/observability.sops.yaml). The
public half in [`.sops.yaml`](../../.sops.yaml) is committed and can only
encrypt; nothing in this repository, and nothing in any backup of this
repository, can recover the private half.

What is lost with that disk is not really the secrets — a password can be reset
and a community string can be changed. What is lost is every device visit needed
to do it: the Grafana admin password, the Alertmanager webhook, and four SNMP
communities re-entered by hand on pfSense, the APC NMC, HPE iLO and the
MokerLink switch. The switch is the one that hurts. Its firmware will not
persist a deletion from the community table and drops its SNMP agent on each
attempt, which is why [`SECURITY.md`](../../SECURITY.md) still records an
accepted residual there from the last rotation. Doing that a second time,
unplanned, because a 2012 MacBook Pro's disk failed, is the scenario this
avoids.

Background on the scheme itself is in
[`secrets/README.md`](../../secrets/README.md).

## 1. Copy the key

```bash
cat ~/.config/sops/age/keys.txt
```

Two lines of plain ASCII: a `# public key: age1…` comment and one
`AGE-SECRET-KEY-1…` line. The secret line alone is sufficient — the comment is a
convenience, and `age-keygen -y` can regenerate it from the secret half at any
time.

Put it somewhere that is not this machine:

| Where | Good for | Watch out for |
| --- | --- | --- |
| Password manager, as a secure note | The default choice — encrypted, backed up, searchable | Losing the master password loses this too. Title it so you can find it in five years |
| Printed, in a safe or with documents | Survives every digital failure at once | A printer with a spool, and a photocopier's memory |
| Encrypted USB stick, stored elsewhere | Fast restore | Flash cells fade unpowered; re-verify yearly |

Record *what it is and what it unlocks* alongside it. A bare
`AGE-SECRET-KEY-1…` string found in a password manager in three years is
indistinguishable from junk.

The location itself is deliberately **not** written down in this repository. A
public pointer to where the only key lives is worth less than the reminder it
would provide.

## 2. Verify it actually decrypts

Not optional, and not the same as looking at it. From a checkout of this repo:

```bash
make secrets-verify-backup KEY=/path/to/the/copy
```

Expect:

```console
-- recipient matches .sops.yaml: age1yrdu996…
-- decrypting observability.sops.yaml with the backup key only
ok — keys.txt decrypts secrets/observability.sops.yaml (6/6 keys)
```

What it proves: the key parses, its public half is the recipient the file was
encrypted to, it decrypts the real ciphertext, and the result contains all six
keys `render-config.sh` requires. No secret value is printed, written to a
temporary file, or passed to another process.

What it deliberately does not prove: that where you put the copy will still
exist after a fire, a theft, or a forgotten master password. That part is
judgement, not a check.

> **Why not just run `sops -d` by hand.** Because on the host that already holds
> the key, it passes no matter what. `SOPS_AGE_KEY_FILE=<backup> sops -d …` also
> consults `SOPS_AGE_KEY` and the default `~/.config/sops/age/keys.txt`; pointed
> at a freshly generated, completely unrelated keypair it exits 0 and prints
> every secret. [`verify-key-backup.sh`](../../scripts/verify-key-backup.sh)
> clears `SOPS_AGE_KEY`, redirects `HOME` and `XDG_CONFIG_HOME` at an empty
> directory, and refuses to run against the live key file at all — so a pass
> means the backup did the work.

### Do not open the copy in an editor

Both flows below write the key to a file with `cat >`, not with `vi`. That is
not a style preference.

`sops` decrypts to a temp file and opens `$EDITOR` on it, and a vim or neovim
configured with `undofile` writes the buffer — the full text — into a permanent
undodir. The same is true of any file you open to paste a key into. `shred -u`
on the tmpfs file then removes the copy you can see and leaves the one you
cannot, on the unencrypted disk, indefinitely.

This was not hypothetical: it is how three live SNMP community strings came to
be sitting in `~/.local/state/nvim/undodir/` on the monitoring host, which is
why [`make secrets-edit`](../../scripts/secrets-edit.sh) now hardens the editor
before handing it plaintext. `cat >` has no such machinery — it writes what you
give it and nothing else.

If you genuinely need an editor, `vim -u NONE -i NONE -n` skips the config that
turns those features on.

### Verifying a password-manager backup

Verify what came back **out** of the vault, not what you put in — verifying the
copy you pasted from verifies your clipboard.

```bash
umask 077
cat > /dev/shm/restore-test.txt       # paste from the vault, then Ctrl-D
make secrets-verify-backup KEY=/dev/shm/restore-test.txt
rm -f /dev/shm/restore-test.txt
```

`/dev/shm` is tmpfs, so the copy lives in RAM and never reaches the disk. That
is also why `rm` is enough here and `shred`'s overwrite would be theatre —
tmpfs has no stable blocks to overwrite.

### Verifying a paper backup

Type it **back in** and verify that file. Verifying the copy you typed is
verifying your handwriting, which is the thing that will actually fail.

```bash
umask 077
cat > /dev/shm/restore-test.txt       # transcribe from the paper, then Ctrl-D
make secrets-verify-backup KEY=/dev/shm/restore-test.txt
rm -f /dev/shm/restore-test.txt
```

age keys transcribe better than most secrets: uppercase Bech32, so the data part
contains no lowercase, and no `1`, `b`, `i` or `o` at all. The `0`/`O` and
`1`/`l` confusions that ruin handwritten passwords cannot occur here. A
mis-transcription is caught by the checksum in the key itself, and the script
reports it as "not a readable age identity file" rather than a decrypt failure.

## 3. Confirm the copy is not republishing itself

The third thing that goes wrong: a backup that is durable and also public.

- **Not in a git repository.** `.gitignore` here matches `keys.txt` and
  `age.key`, which protects nothing outside this tree and nothing under a
  different filename. `make secrets-verify-backup` refuses outright if the copy
  is inside *this* repository, and warns if it is inside any other working tree
  — a dotfiles repo, a notes repo, a scratch clone. That one is a warning rather
  than a refusal because the script cannot see whether that repository has a
  remote, and a git-tracked repo that never leaves the machine is a legitimate
  place to keep this.
- **Not in plaintext in a synced folder.** Dropbox, OneDrive, Google Drive,
  iCloud, Nextcloud, Syncthing — a plaintext copy there is a readable copy on
  someone else's disk. `make secrets-verify-backup` warns when the path looks
  like one, but it can only see the path, not what the folder actually syncs to,
  which is why it warns rather than refuses.

  A password manager syncing an **end-to-end-encrypted** vault is a different
  thing and is not disqualified by this — it is the default choice recommended
  above. The provider holds a blob it cannot read. Its real failure modes are
  losing the master password and losing the account recovery material, which is
  the next bullet.
- **Not recoverable only from the host you are insuring.** If the vault's own
  recovery material — a 1Password Emergency Kit, a Bitwarden export, the TOTP
  seed guarding the account — exists nowhere but this machine, the backup is
  circular: the disk that dies takes the means of opening the copy with it.
- **Not on the monitoring host.** A second copy on the same disk is not a
  backup. The script refuses to verify the live key for this reason.

## Restoring on a new host

```bash
mkdir -p ~/.config/sops/age
vi ~/.config/sops/age/keys.txt        # paste the backup
chmod 600 ~/.config/sops/age/keys.txt
git clone https://github.com/Gerrrt/HomeLab.git && cd HomeLab
make render                           # decrypts; this is the proof it worked
make up
```

**Do not run `make secrets-init` to restore.** It generates a *new* keypair
whose public half does not match `.sops.yaml`, and then nothing decrypts. It
refuses to overwrite an existing key or an existing encrypted secrets file, so
the damage is recoverable — but the error it produces afterwards
(`sops metadata not found`, or a failed decrypt) sends you looking in the wrong
place. Restore is a file copy, nothing more.

## The ninety-day deadline

Verifying the backup is the only thing in this repository that proves the secrets
are recoverable from anywhere but the monitoring host — every other scheduled
job runs on that machine, with the key that is on it, against its disk. It is
also the only one that cannot be put on a timer, because the check above refuses
the live key by device and inode on purpose: what gets tested has to be a copy on
removable media, and no timer can mount that.

So it is enforced from the other end. `make secrets-verify-backup` records the
timestamp of a successful run **against the recipient it just proved**, and
`SecretsKeyBackupUnproven` fires when any recipient's proof passes ninety days
old — routed to the normal alert channel like any other warning. Until the first
verification there is no timestamp at all and `ScheduledJobNeverRan` says so
instead, which is the honest reading of a key backup nobody has ever tested.

The per-recipient part is [ADR-0024](../adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)
and it only starts to matter once there is more than one. With one recipient
this is the same alert it always was. With two, one timestamp for both would
mean that proving either copy vouched for the other — which is exactly backwards,
because the point of the second copy is that it fails independently.

Nagging is not as good as running it. It is a great deal better than remembering.
The threshold lives in the `JOBS` table in
[`install-timers.sh`](../../scripts/install-timers.sh); the mechanism is in
[`schedule-maintenance.md`](schedule-maintenance.md).

## Adding a second recipient

The section this replaces said a second recipient was "worth doing on the day
the lab stops being a one-person project, and not before".
[#106](https://github.com/Gerrrt/HomeLab/issues/106) pointed out that this
frames a loss problem as a headcount problem. Nobody joining is what makes a
second *holder* worth having; it has nothing to do with whether the key survives
a disk dying. [ADR-0024](../adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)
decides the question on the loss grounds and explains why a second *recipient*
beats a second *copy* — briefly: `.sops.yaml` records a recipient and nothing
records a copy, so the tooling can name and separately nag about a recipient and
cannot tell two copies of one key apart.

Generate the keypair **on the machine or the medium that will keep it**. Not
here. A key generated on the monitoring host and then added as a recipient is a
second copy on the disk you are insuring, and `make secrets-add-recipient`
refuses it for that reason.

```bash
# ...somewhere that is not this host:
umask 077
age-keygen -o /path/to/its/keys.txt
age-keygen -y /path/to/its/keys.txt        # the PUBLIC half — this is what travels
```

Then, on the monitoring host, with only that public half:

```bash
make secrets-add-recipient PUBKEY=age1...
```

That writes the key into the `creation_rule` this stack's file already uses and
re-keys the file in the same run. sops shows the group change and asks before
committing to it; answering no rolls `.sops.yaml` back, so the two never
disagree. Both files change and belong in one commit:

```bash
git add .sops.yaml secrets/observability.sops.yaml
```

The new recipient starts unproven, and says so: `SecretsKeyBackupUnproven` fires
against it immediately and names it. Clear it the same way as the first —
`make secrets-verify-backup KEY=/path/to/the/new/copy` — and note that this is
the point of the whole exercise. **Proving one recipient does not clear another.**
Each copy has to be mounted and tested on its own, which is four trips a year
rather than two.

The table in [Copy the key](#1-copy-the-key) and the disqualifiers in
[Confirm the copy is not republishing itself](#3-confirm-the-copy-is-not-republishing-itself)
apply to the second copy as much as the first, plus one rule that only exists
once there are two: **it must not fail
at the same time as the first.** Two USB sticks in the same drawer is one copy
with extra steps, and so is a second recipient whose private half is in the same
password-manager vault as the first — the failure mode of a vault is losing the
master password, and that takes everything in it at once.

## What this still does not solve

**One person.** ADR-0024 answers the copy and deliberately does not answer the
holder: whether somebody else should be able to open the estate's secrets is a
question about people, not about mechanism. What has changed is that the
mechanism is now built and exercised — a second holder is the same
`make secrets-add-recipient` with their public key, not a procedure to work out
on the day it matters.

**Revocation is still rotation.** Removing a recipient and re-keying protects
values encrypted from then on. Every historical ciphertext in git stays readable
by the removed key, because the commits are still there. A second recipient that
leaks means rotating every credential — four SNMP communities on hardware, the
Grafana password, the four notification URLs and the renderer token — exactly as
a leaked first one does. That is why "every extra recipient is another key that
can leak" is still the right thing to weigh; ADR-0024 weighs it and accepts it
against an alternative that carries the same exposure unaudited.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `that is the live key on this host, not a backup of it` | `KEY=` points at `~/.config/sops/age/keys.txt`, or a symlink or hard link to it | Point it at the copy. This is the check working |
| `this is a valid age key, but not one the secrets are encrypted to` | A different keypair — usually one `age-keygen` made by accident | Find the right backup. If there is none, the secrets must be rotated on the devices |
| `is not a readable age identity file` | Truncated, wrapped, or mis-transcribed secret line | Re-copy. Check the whole `AGE-SECRET-KEY-1…` line landed on one line |
| `decryption failed with this key` after the recipient matched | Right public half, damaged secret half — a partial copy | Re-copy from the original while the host still exists |
| `the backup is inside this repository` | The copy was written into the working tree | Move it out, then `git log --all -- <path>` to confirm it was never committed |
| `the backup is inside a git working tree` | The copy is in some *other* repository, which `.gitignore` here cannot help with | Check it is ignored — or better, move it somewhere no repository covers. Harmless if that repo has no remote |
| `no encrypted secrets at secrets/observability.sops.yaml` | Wrong working directory, or a fresh clone that never ran `make secrets-init` | Run from the repo root |
| `mode 644 — group or other can read this copy` | A copy written without `umask 077` | `chmod 600` it, and consider it seen by anything else on that machine |
