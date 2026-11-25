# ADR-0132: Carry the offsite copy on the spare drive, apart from the second key

**Status:** Accepted · 2026-11 · supersedes the choice of medium in
[ADR-0048](0048-carry-the-estates-backup-sets-with-the-second-recipient.md)
decision 1. The rest of ADR-0048 stands: one copy of record, the newest set of
each kind, `make backup-offsite`, and `OffsiteCopyStale` at ninety days.

## Context

ADR-0048 put the newest backup set of each kind on the medium that holds the
second age recipient. Two of its reasons were that the medium already visited
`prometheus` every ninety days to prove that key, and that a successor would
then hold the key and the sets in one hand. It accepted one cost: *"this
medium is now the one place where the estate's ciphertext sits beside a key
that opens it."*

Both reasons have gone:

- **The key medium no longer has a reason to visit.**
  [ADR-0120](0120-drop-the-age-key-proof-deadline.md) dropped the age-key
  proof deadline, so the offsite copy was the only remaining reason to bring
  that medium here. A carrier that comes only for the copy is not riding an
  existing visit.
- **A spare drive exists.** The 5 TB WD drive labelled `HOUSEHOLD` was bought
  for the household copy, and has been spare since
  [ADR-0122](0122-drop-the-household-copy.md) dropped that copy on
  2026-11-21 ([`hardware.md`](../hardware.md)).

On 2026-11-24 the copy was 62 days old, against a ninety-day deadline. The
operator plugged the spare drive into `prometheus` and chose it to carry the
copy from now on.

## Decision

**The offsite copy of record is the spare `HOUSEHOLD` drive. It holds no key.**
`make backup-offsite DEST=<the drive's mount>` writes to it unchanged: the same
layout, the same proofs, the same `offsite-copy` record and ninety-day
`OffsiteCopyStale`. The operator keeps the drive outside the house between
visits. Its location is not written in this repository, for the reason the
key medium's location is not.

The first copy to it was made on 2026-11-24.

## Alternatives considered

- **Keep the key medium as the carrier** (ADR-0048 as written). Declined by
  the operator. It puts ciphertext beside the key, and it now makes the key
  medium visit only for the copy.
- **Copy to both.** Declined, for ADR-0048's own reason: `run-scheduled.sh`
  writes one timestamp per job, so two media would share one proof, and the
  alert would vouch for whichever copy was not just made.

## Consequences

- **The sets and a key that opens them are now apart.** The drive alone opens
  nothing. A restore after losing the house needs the drive and one of the two
  age keys: the second recipient's medium, held off the estate, or the
  operator's offline copy of the first key. Losing the drive loses only
  ciphertext. That reverses the cost ADR-0048 accepted. The new cost: a
  successor needs two things, not one, and
  [`successor-handover.md`](../runbooks/successor-handover.md) says so.
- **The script cannot check that the drive leaves the house.** It reports as
  fixed, not removable, so every run prints the warning
  [`copy-the-backups-offsite.md`](../runbooks/copy-the-backups-offsite.md)
  describes. That is expected for this drive. Carrying it out is the
  operator's step, as ADR-0048's note already said.
- **The copy on the key medium is no longer of record.** Nothing reads it, and
  it stops being refreshed. Its holder may delete its `backups/` directory, or
  leave it as an older copy nothing vouches for.
- **The drive still carries the household rehearsal of 2026-10-01**
  (`household/`, `tools/` and two text files). It is left as it was, beside
  `backups/`, and is not part of the copy.
- **Reopen if** the drive is lost or fails its re-verify, or the key medium
  starts visiting again for a reason of its own.
