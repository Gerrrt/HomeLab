# ADR-0073: Carry the household's copy on a drive the holder keeps

**Status:** Accepted · 2026-10 · settles the first of
[ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)'s two
conditions for [#455](https://github.com/Gerrrt/HomeLab/issues/455). The
second, the proof from the other person's device, is a person's to run, and
this record says how it is recorded, not that it has happened.

## Context

ADR-0023 classes Immich and Paperless-ngx as **Durable**. Each needs a copy
outside the estate, and its staleness must be visible. The copy must be
encrypted to a key that is not the one only the operator holds, and it must
be opened once from the other person's own device, signed into their own
account, without the operator there. Actual joined that class on 2026-09-29.

The drive exists. A WD Elements Portable 5 TB was bought on 2026-09-22 and
arrived on 2026-09-29 ([`hardware.md`](../hardware.md)). It has no vendor
encryption, which is why it qualified: a drive password is a secret one
person holds, behind a vendor utility. The real photographs arrived first,
on 2026-09-28, and
[ADR-0064](0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)
has copied the library nightly to `oracle` since. That copy is off the host
and still in this house, and it is encrypted to `trinity`'s key alone.

Issue #455 asked whether the drive's key should be
[ADR-0024](0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)'s
second recipient or a separate one. Its 2026-09-22 comment showed that the
question comes in the wrong order. A key is held by a person, and the
household's holder has not been chosen. The technical second has been chosen
([#294](https://github.com/Gerrrt/HomeLab/issues/294)), already holds a
removable medium and already visits on a cadence. "Reuse the second
recipient" is therefore the easy path, and it picks a person for a role
nobody decided they should have. That is
[ADR-0034](0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)'s
failure one layer up.

The holder is still not chosen, and nobody knows what device they will use.
This record is written so that neither fact has to wait.

## Decision

**The copy is encrypted to two kinds of key: the household holder's, and the
technical second's as a fallback.** Either private half opens it, which is
the mechanism ADR-0024 chose for the estate's secrets, one layer up.

- **If they are different people,** the household opens its own photographs
  without a technician, and the technician is the way back if the household's
  key is lost.
- **If they turn out to be the same person,** it becomes one recipient. There
  is no extra key and nothing to undo.

**The technical second's key alone is rejected.** It would make the household's
photographs recoverable only through a technician, which is ADR-0023's
complaint with the names changed. It would also put the estate's ciphertext,
the estate's key and the household archive's key on one removable medium, and
[`copy-the-backups-offsite.md`](../runbooks/copy-the-backups-offsite.md)
already says to treat losing that medium as losing the key.

**The household's keys live in `stacks/sensitive/household.recipients`, not in
a sops rule.** The obvious alternative is `make secrets-add-recipient
STACK=sensitive` with the holder's key, and that would also give the holder
`secrets/sensitive.sops.yaml`: the tier's passwords and Vaultwarden's admin
token. The holder needs none of it, and ADR-0048 already ruled that one key
doing two jobs means one leak takes both.

- **The file.** Each key carries a role comment, `household` or
  `technical-second`. The file is valid input to `age -R` as it stands.
  `scripts/household-recipients.sh` reads it and refuses a key with no role, a
  role with no key, an unknown role and a duplicate.
- **The check.** `scripts/check_sops_rules.py` fails if a `household` key
  appears in any creation rule. It also fails if the `technical-second` key is
  not one the catch-all rule carries, because only that rule's keys are proved
  by ADR-0024's ninety-day proof.

**Sets are encrypted once, at the source.** `backup-library.sh` encrypts each
Immich set to the sensitive rule's recipients plus this file's, and the
Paperless set gets the same. The carry to the drive copies ciphertext and
reads no key, which is `backup-offsite.sh`'s posture. `trinity` stays a
recipient, so the existing `verify()` still proves each archive opens when it
is written. A copy re-encrypted at carry time to the household's keys alone
could not be proved by anything on this side.

**The drive is exFAT, and the sets are `.tar.gz.age`.** The holder's operating
system is unknown. The `age` binary runs on Windows, macOS and Linux, and
`tar` ships with all three. LUKS opens on Linux only, so it would choose the
holder's computer for them. The drive also carries:

- the `age` binaries, checked against committed hashes;
- a plain-text copy of the holder's runbook.

**Paperless travels in `document_exporter` form, not as volumes.** The volume
set holds all fifteen of the tier's volumes, Vaultwarden's among them, and
reading Paperless's own would need its database at the same version. The
export is the original files plus a manifest. The holder can browse it as
files, and it re-imports into Paperless.

**Freshness is a deadline, not a timer.** A drive at another address cannot be
on a schedule. ADR-0023's "a scheduled job that reports, not a habit" is met
the way the estate's own offsite copy meets it:

- The nightly ADR-0064 set is the scheduled part.
- The drive's visit is a deadline job, `household-copy`, due every ninety days.
- The holder's proof is a second one, `household-proof`, due once a year.

  That fits ADR-0011's annual drill, which ADR-0023 already extended to
  checking that the household's path still opens.

A stale job of either kind is an alert, and so is one that never ran.

**There is no recorded copy until there is a holder.** A copy recorded with
only the technical second's key would silence the deadline for ninety days on
something that does not meet condition one. A rehearsal can be written to the
drive and checked, and it is never recorded.

**The holder keeps their key apart from the drive:** on their own device, plus
a paper copy. ADR-0023 speaks of "a key nobody outside this house holds" and
"a key that never leaves the house". That was written when the house and the
household were the same address. Here "house" means the household: the key is
the holder's, and it never comes to this estate. Only its public half does.

**Actual is deferred, by name.** It is Durable and holds no real data until
this copy exists. Its set is the next kind the drive carries, under the same
recipients, and adding it needs no new decision.

## Alternatives considered

- **LUKS on the drive.** Rejected because it opens on Linux only, and the
  holder's device is unknown. It would also add a passphrase that one person
  holds.
- **Re-encrypting on `trinity` at carry time, to the household's keys alone.**
  Rejected because it reads the library with the host's key in hand, adds a
  second full pass over 2 TB, and leaves nothing on this side that can prove
  the result opens.
- **The household key in the sensitive sops rule.** Rejected: the holder would
  get the tier's secrets as well (see above).
- **The technical second's key alone.** Rejected: the household would recover
  only through a technician (see above).
- **Generalising `OffsiteCopyStale` to cover this drive.** Rejected: it has a
  different medium, host and reader, and its advice ("mount the second
  recipient's medium") would be wrong here.
- **Paperless's volume tar plus a database dump.** Rejected: no household
  reader can run Postgres 18 and Paperless at a matching version.

## Consequences

- **`oracle`'s sets become openable by the household's keys.** This is the
  same ciphertext the drive carries under the same keys, so it adds very
  little exposure. It is named here so that it is not discovered later.
- **The technical second's key now opens two things,** the estate's sets and
  the household's archive. That is accepted as the fallback. If the
  household's holder and the technical second turn out to be one person, it
  is also the moment ADR-0048 names to reopen the medium question.
- **The Paperless export carries Paperless's own user table** (password
  hashes) and any mail-account passwords configured in it. Whoever can open
  the copy can read those, as they can read the documents.
- **The recovery point on the drive is up to ninety days.** Between visits,
  ADR-0064's nightly copy still covers the disk failing. It does not cover
  the house burning down.
- **The drive's ceiling is about 2.4 TB of library.** A new set lands before
  the old one is pruned, so the drive needs room for two. The refusal names
  the ceiling when it is reached.
- **The deadline alerts fire until a holder exists.** That is correct: it is
  the honest state, as `verify-key-backup` showed before its first proof.
- **The household's copy sits in someone else's building, with its key.** The
  key is kept apart from the drive, but a burglary at the holder's address
  could take both. [`security.md`](../security.md) records this residual.
- **ADR-0064 is superseded as the stand-in only on the first
  `household-proof`.** Its nightly copy to `oracle` carries on as the
  off-host layer and as the source of the sets the drive carries.
- **Until then, #455 stays open.** Condition one is settled by this record.
  Condition two needs a person.
