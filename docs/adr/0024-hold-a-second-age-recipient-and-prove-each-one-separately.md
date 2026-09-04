# ADR-0024: Hold a second age recipient, and prove each one separately

**Status:** Accepted · 2026-09

## Context

[#106](https://github.com/Gerrrt/HomeLab/issues/106) reopens a question
[`back-up-the-age-key.md`](../runbooks/back-up-the-age-key.md) had already
answered, and is right to. That runbook closes with:

> One key, one person. … It is worth doing on the day the lab stops being a
> one-person project, and not before — every extra recipient is another key that
> can leak.

The issue's objection is that **the risk being described is not about team
size**. Nobody joining is what makes a second *holder* worth having; it has
nothing to do with whether the key survives a disk failure. Losing the key does
not degrade anything — every encrypted value in git history becomes permanently
undecryptable, and the recovery path is re-deriving each credential from the
device it belongs to. That is four SNMP rotations on live hardware, one of which
(`neo`) cannot persist a community deletion and needs a reboot, which in turn
cannot happen during working hours because that switch carries every VLAN. The
cost of the failure is measured in scheduled outages on someone else's calendar,
not in effort.

[ADR-0015](0015-give-oracle-the-off-host-jobs.md) then answered the same
question the other way, four months later, and it is worth being precise about
what it actually rejected:

> **Not a second age recipient.** … A second key on a powered, network-attached
> host in the same room, administered by the same person, adds no person and no
> offline copy. It only adds a key. Worse, it would be *this* host. … Giving it
> a private key that decrypts the estate's secrets makes it the one place where
> the backups and the means to open them sit on the same 5400 rpm disk.

**Both of those paragraphs stand.** That argument is about `oracle`, and it does
not generalise: it turns on the machine being powered, network-attached, in the
same room, and already holding the ciphertext it would then be able to read.
[ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md) has
since sharpened the same point in a different context — `oracle` is "the same
VLAN, the same rack, the same power feed and the same room", and every failure
worth insuring against reaches both boxes in one event. A key held offline, off
this estate, shares none of those properties. `oracle` remains a machine that
holds ciphertext and no key.

### The argument #106 does not make, and it is the one that decides this

For a one-person lab, a second *recipient* and a second *copy of the existing
key* are almost the same object. Either way there are two secret artefacts, each
of which alone decrypts everything, and losing both is total loss. The
cryptography does not care which one is chosen, and the confidentiality cost —
"another key that can leak" — is identical, because a second copy is also
another thing that can leak.

They differ in exactly one respect, and it is not a cryptographic one:

**`.sops.yaml` records a recipient in git. Nothing records a copy.**

`verify-key-backup.sh` reads the public half out of the backup being tested and
matches it against the recipients of the encrypted file, so it can say *which*
recovery path a given run just proved. Two copies of one key are indistinguishable
to it and to everything else here — the same public half, the same match, the
same green result. Prove one and the tooling reports, accurately as far as it
can tell, that the backup works.

That is the distinction this repository has already decided it cares about, in
this exact domain. [`secrets/README.md`](../../secrets/README.md) rejects a
gitignored `.env` and gives the reason:

> A gitignored `.env` keeps secrets out of the repository, but it also keeps
> them out of any backup, review or history.

And [`run-scheduled.sh`](../../scripts/run-scheduled.sh) exists because:

> the requirement is not "run the job", it is "make NOT having run the job
> observable".

A second copy of the key in a drawer is the `.env` of key backup. It works, and
nothing in this repository can see it, check it, or notice when it goes bad.

### What that exposes about the existing deadline

`SecretsKeyBackupUnproven` fires on
`homelab_job_last_success_timestamp_seconds{homelab_job="verify-key-backup"}`,
which is one series. `run-scheduled.sh` writes it on every successful run
whatever `KEY=` pointed at. With one recipient that is exactly right and the
alert means what it says.

With two it stops being true. Proving either copy resets the ninety-day clock
for both, so the second can rot behind a green alert — and the alert would be
*more* wrong the more recovery paths existed, which is the opposite of what
adding them is for. This is not a consequence of the decision below; it is a
defect the decision would introduce if left alone, and it is the reason the
mechanism is not, as #106 puts it, free.

## Decision

**The estate's secrets are encrypted to more than one age recipient, and every
recipient carries its own ninety-day proof.** Three parts.

The mechanism and the per-recipient deadline are built with this ADR. **The
second keypair itself is not**, and cannot be: its private half must be
generated where it will live, which is somewhere this repository cannot reach —
see part 1. Until the operator does that, the estate has one recipient and every
check below behaves exactly as it did before, which is the honest state to leave
it in rather than pretending a key exists.

**1. A second recipient, held offline and off this estate.** Its private half is
generated on the medium or machine that will keep it and never touches the
monitoring host — `scripts/add-recipient.sh` refuses a public key whose private
half it can find at `~/.config/sops/age/keys.txt`, because a key generated here
and added here is a second copy on the disk being insured wearing the costume of
a second recovery path. It is not `oracle`, for ADR-0015's reasons, restated
above and unchanged. Where it goes instead is an operational choice recorded in
`back-up-the-age-key.md`; the only constraint this ADR imposes is that it must
not fail at the same time as the first copy, which rules out the same drawer as
firmly as it rules out the same disk.

**2. `make secrets-add-recipient PUBKEY=age1...` is how one is added.** Public
half only. It resolves which `creation_rule` governs the stack by looking at the
recipients the encrypted file *already uses*, rather than re-implementing sops'
first-match-wins `path_regex` resolution — which makes writing a key into the
wrong rule structurally impossible, and that matters because
[ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md) gives
`lab` a rule of its own precisely so a lab-guest key cannot decrypt the estate's
SNMP communities. It re-keys in the same run and rolls `.sops.yaml` back if that
fails, because the intermediate state — a recipient this repository advertises
as a recovery path which cannot decrypt anything — is worse than either end.

**3. The proof is per recipient, read out of the ciphertext.**
`scripts/key-recipients.sh` emits
`homelab_key_recipient_last_proof_timestamp_seconds` with one series per
recipient, and `SecretsKeyBackupUnproven` fires on that instead. A recipient
that has never been verified is recorded as `0`, not omitted, so it is loud
rather than invisible — the same choice `run-scheduled.sh` makes for a job that
has never run.

The recipient list comes from the `sops:` block inside
`secrets/<stack>.sops.yaml` and **not** from `.sops.yaml`. Those answer different
questions: `.sops.yaml` is the policy for the next encryption, and the file's own
metadata is the set of keys that can open the bytes on disk. They diverge for
exactly as long as it takes somebody to add a recipient and forget
`sops updatekeys`, which is a window in which the repository advertises a
recovery path that does not exist. Reading the ciphertext means every check here
is a statement about what can actually be recovered.

## Consequences

- **The confidentiality cost is real and is accepted.** There is now a second
  private key that decrypts every secret in this repository, and ADR-0015's
  "another key that can leak" applies to it in full. What changes the balance is
  that the alternative being compared against is not "one key" — it is "one key
  and an unaudited second copy of it", which carries the same exposure and
  cannot be checked.
- **Revocation is still rotation.** Removing a recipient and re-keying protects
  future values only; every historical ciphertext in git remains readable by the
  removed key. A leaked second recipient means rotating every credential, exactly
  as a leaked first one does. Nothing here improves that and the runbook says so.
- **The ninety-day deadline gets stricter on its own.** The threshold is still
  declared once, in the `JOBS` table in `install-timers.sh`, but it now applies
  to each recipient independently. Adding a recipient adds an alert that fires
  immediately and keeps firing until that specific copy has been mounted and
  tested. That is the intended behaviour and it is also the main ongoing cost:
  two copies means two trips to wherever they are kept, four times a year.
- **`ScheduledJobNeverRan` still covers the cold start.** Before any
  verification has ever happened, `key-recipients.sh` has not written its file
  and there are no per-recipient series to fire on, so the generic rule speaks —
  unchanged from today.
- **This does not close the "one person" half of #106.** The title says "one
  holder and one copy" and this ADR answers the copy. A second holder is still a
  question about who else should be able to open the estate's secrets, which is
  a decision about people and is not made here. What changes is that the
  mechanism for it now exists and is exercised: adding a second *holder* later is
  the same command with someone else's public key.
- **`make render` is the canary if sops changes.** Recipients are written one per
  line in a folded scalar, comma-separated, which relies on sops trimming each
  entry. That was measured on sops 3.9.4 rather than assumed, and
  `add-recipient.sh` re-reads the file after re-keying so a future regression
  fails at add time. If it ever regressed silently instead, decryption on the
  deployment host is where it would surface.
