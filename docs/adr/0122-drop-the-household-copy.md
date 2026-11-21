# ADR-0122: Drop the household copy

**Status:** Accepted · 2026-11 · supersedes
[ADR-0073](0073-carry-the-household-copy-on-a-drive-the-holder-keeps.md);
amends
[ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md),
[ADR-0024](0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)
and
[ADR-0064](0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)

## Context

[ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)
classes Immich and Paperless-ngx as **Durable**, and Actual joined them on
2026-09-29 ([ADR-0062](0062-add-actual-to-the-sensitive-tier.md)). Each was to
have an encrypted copy outside the estate, with visible staleness, opened once
from another person's device. Issue
[#455](https://github.com/Gerrrt/HomeLab/issues/455) was that copy.
[ADR-0073](0073-carry-the-household-copy-on-a-drive-the-holder-keeps.md)
built it: a WD Elements drive kept by a household holder at their own
address, sets encrypted at the source to `stacks/sensitive/household.recipients`,
`make household-copy` every ninety days, `make household-proof` once a year,
and `HouseholdCopyStale` watching both. [ADR-0024](0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)'s
second recipient was in that file as the fallback.

No holder was ever chosen. The drive held a rehearsal and nothing else, both
deadline jobs sat in `ScheduledJobNeverRan` from the day they were declared,
and the library has been copied nightly to `oracle` under
[ADR-0064](0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)
since 2026-09-29.

On 2026-11-21 the operator said: "I don't want it and I want the requirement
removed." They do not want a household holder, visits to a drive at another
address, or a holder's proof. A requirement nobody intends to meet is a
standing alert and a gate in the roadmap that never clears.

## Decision

**The household copy is dropped, and so is the requirement for it.**

- **ADR-0073 is superseded.** `scripts/carry-household-copy.sh`,
  `scripts/household-recipients.sh`, `stacks/sensitive/household.recipients`,
  `stacks/sensitive/household-age.sha256`, the `household-copy` and
  `household-proof` Makefile targets and their two runbooks are deleted.
- **The jobs and the alert go.** `household-copy` and `household-proof`
  leave `SENSITIVE_JOBS` in `scripts/install-timers.sh`, and
  `HouseholdCopyStale` leaves `backup.rules.yaml` with its tests.
  `ScheduledJobStale`, `ScheduledJobStaleCritical`, `ScheduledJobNeverRan` and
  `ScheduledJobFailed` skip both names, so a `trinity` whose
  `homelab-jobs.prom` predates this stays quiet until `make install-timers`
  rewrites it. [ADR-0120](0120-drop-the-age-key-proof-deadline.md) did the
  same for the age-key proof.
- **ADR-0023 is amended.** No copy outside the estate is required for the
  **Durable** class. Immich, Paperless-ngx and Actual may be down and should
  not be lost, and what stands between them and loss is the host, the
  nightly sets and the copies on `oracle`. The rest of ADR-0023 stands:
  Vaultwarden's **Independent** class, Home Assistant's **Fail-safe** class,
  and keeping step-ca and Caddy off every household recovery step.
- **ADR-0064's copy stays, and is no longer interim.** The nightly
  encrypted library set to `oracle` is the library's copy off the host. It is
  not waiting for #455, and nothing supersedes it.
- **ADR-0024's second recipient loses its household role.** It was the
  fallback key in `household.recipients`. That file is gone. The recipient
  stays on the `sensitive` rule for ADR-0024's own reasons.
- **Library sets are encrypted to the sensitive rule's recipients only.**
  `backup-library.sh` no longer adds the household file's keys.
  `check_sops_rules.py` loses its household check; its other checks are
  unchanged, and so is every rule in `.sops.yaml`.
- **The drive is spare.** The WD Elements bought for this is not used for
  anything ([`hardware.md`](../hardware.md)).

## Consequences

- **The photographs, documents and budget have no copy outside the house.**
  They are on `trinity` and, encrypted, on `oracle`, in the same room and on
  the same power. A fire, flood or theft that takes the rack loses them. The
  operator accepts that.
- **The Paperless export form has no carrier.** `paperless-documents` was an
  archive name for the drive's sets alone, and it leaves
  `backup-volumes.sh`'s sentinel tables. Paperless's volume sets are
  unchanged.
- **`scripts/medium.sh` has one caller again**, `backup-offsite.sh`. It
  keeps the arguments it was given for two, because they cost nothing.
- **The estate's offsite copy is unchanged.**
  [ADR-0048](0048-carry-the-estates-backup-sets-with-the-second-recipient.md)'s
  `offsite-copy` and `OffsiteCopyStale` are a separate decision about a
  separate medium.
- **Bringing the copy back is a new decision**, and the deleted tooling is in
  this repository's history if it is wanted.
