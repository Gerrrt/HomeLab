# ADR-0120: Drop the age-key proof deadline

**Status:** Accepted · 2026-11 · amends [ADR-0024](0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)

## Context

[ADR-0024](0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)
part 3 gave every age recipient its own ninety-day proof. A human mounts an
offline copy of the key, runs `make secrets-verify-backup`, and
`SecretsKeyBackupUnproven` fires for any recipient whose last proof is older
than that. `SecretsKeyRecipientsUnrecorded` was added later (#400) for a host
that declared the deadline and had no per-recipient series. #1501 extended the
deadline to `trinity` as `verify-key-backup-sensitive`.

Neither key has ever been proved on `trinity`, and the operator does not
intend to start. A trinity audit on 2026-11-20 raised the proofs again. The
operator's position is that recurring offline and off-site key drills are too
much for a home lab. They also rule out bringing in anyone outside the family
as a technical second to hold or check a copy. An alert that is never acted on is noise, and it trains
the operator to ignore the channel the real alerts arrive on.

## Decision

**The age-key proof has no deadline and no alert.**

- `verify-key-backup` leaves `JOBS` and `verify-key-backup-sensitive` leaves
  `SENSITIVE_JOBS` in `scripts/install-timers.sh`.
- `SecretsKeyBackupUnproven` and `SecretsKeyRecipientsUnrecorded` are removed
  from `backup.rules.yaml`, with their tests.
- The Glance maintenance page stops listing the age-key proof.
- `ScheduledJobStale`, `ScheduledJobStaleCritical` and `ScheduledJobNeverRan`
  skip both names. A host whose `homelab-jobs.prom` predates this change then
  stays quiet until `make install-timers` rewrites it.

**`make secrets-verify-backup` stays, as an optional check.** It still proves
that a copy opens the secrets, and it still records which recipient was
checked. Nothing waits for it.

**`recipient-state` stays.** It still writes `key-recipients.prom` daily.
`remove-recipient.sh` reads the recipient list from that file, and keeping it
current costs nothing.

**Unchanged:** ADR-0024 parts 1 and 2 (the second recipient, and how one is
added) and `check_sops_rules.py`'s rule that a stack guarding data has two
recipients. The CA key's proof (`CaKeyBackupUnproven`, ADR-0043), the off-site
copy (`OffsiteCopyStale`, ADR-0048) and the household copy
(`HouseholdCopyStale`, ADR-0073) are also unchanged. Each has its own deadline
and is a separate decision.

## Consequences

- A lost or corrupted offline key copy is found only when someone goes to use
  it. The operator accepts that.
- One reason for `recipient-state` is gone. The timer stays for the file it
  writes.
- Proving a copy is still possible and is still recorded, so a later decision
  to bring the deadline back is a timer row and a rule, not new tooling.
