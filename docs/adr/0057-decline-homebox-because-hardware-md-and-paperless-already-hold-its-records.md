# ADR-0057: Decline HomeBox because hardware.md and Paperless already hold its records

**Status:** Accepted · 2026-09 · decides [#148](https://github.com/Gerrrt/HomeLab/issues/148)

## Context

[#148](https://github.com/Gerrrt/HomeLab/issues/148) proposed
[HomeBox](https://homebox.software/), a home inventory app, for the sensitive
tier. It gave HomeBox two jobs: a household inventory, and somewhere for the
operational detail that [`hardware.md`](../hardware.md) was said to withhold.
That detail was serials, purchase dates, warranty windows and the iLO Advanced
licence key. The issue argued that "not in the repo" had meant "nowhere". It
cited `oracle` as the cost: the machine was recorded as an i5-1235U with 32 GB
when it is a dual-core A6-9200 with 4 GB, and ADR-0008 notes that the error was
load-bearing in planning.

The second job was answered before this record, and not by HomeBox. The
issue's own correction of 2026-09-19 says so. `hardware.md` now carries the
serials of the TS150, the boot SSD, the SM863a pair and the switch, and one
entry says outright that it "is where the serials live, which is the
question #148 asked". It carries warranty dates too (`trinity` to 2027-09-08). The
correction asked for the case that remained to be argued on its own before
anything was authored. The roadmap's *Tier extras* rule asks the same of every
service beyond ADR-0008's nine.

Laid against what the estate already runs, the jobs #148 named are these:

| Job | Where it lives |
| --- | --- |
| Serials, warranty windows | `hardware.md`, on each device's entry |
| Purchase dates, what is being bought | `hardware.md` for parts on hand; `roadmap.md` § *Everything still to buy* for the rest |
| Receipts and manuals, as attachments | Paperless-ngx, on this tier since [#133](https://github.com/Gerrrt/HomeLab/issues/133): OCR, search, tags, and custom fields that can carry a warranty-expiry date |
| The iLO Advanced licence key | A secret, and so Vaultwarden's ([#131](https://github.com/Gerrrt/HomeLab/issues/131)), not an inventory's |
| Household possessions that are not infrastructure | Nothing |

The last row is the only one HomeBox would fill. Filling it costs:

1. **Winterfell's population.** [ADR-0008](0008-place-services-by-data-trust.md)
   calls a busier management segment "the real cost" of the sensitive tier.
   Every service added there dilutes the most valuable trust boundary in the
   design. Immich was accepted against that cost because a photo library is
   the household's; a list of household objects is not in that class.
2. **A second and third inventory.** `roadmap.md` warns that "two places
   holding the same checkbox is how a checkbox stops being true". HomeBox
   would overlap `hardware.md` on dates and warranties and Paperless on
   receipts, and the overlap is where drift would start.
3. **Upkeep that does not shrink.** One more login to enrol in TOTP under
   [ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md),
   one more image to pin and bump, and one more volume to back up and rehearse
   restoring. The backup would be sensitive, because the point of the service
   is to hold serials and keys.

The `oracle` error does not argue for a second store either. It was caught and
corrected in `hardware.md`, which is the document that was wrong. A record kept
somewhere else would not have stopped the wrong one being read.

## Decision

**Do not deploy HomeBox.** `stacks/sensitive/` stays without it.

The split #148 asked for is recorded here. `hardware.md` keeps roles, specs,
topology, serials and warranty dates. Paperless-ngx keeps receipts, manuals
and purchase paperwork. Vaultwarden keeps licence keys.

## Consequences

- **ADR-0008's service list is unchanged.** HomeBox was never on it, and this
  record does not amend it.
- **No firewall change.** #148 needed none, since it would have been reached
  from Hicks under the existing 50→99 rule, and none is taken.
- **Receipts go to Paperless-ngx.** A part's receipt is filed there, tagged by
  the host it belongs to. Its warranty date goes on the part's `hardware.md`
  entry, which stays the one place anyone reads it from.
- **`roadmap.md`'s "Considered and declined" list gains an entry**, so the
  next time an inventory app is proposed, the argument starts from this
  record.
- **Reopened by a household need to track possessions that are not
  infrastructure, where Paperless's tags cannot meet it.** An example is an
  insurance-grade contents list with locations and photos. A proposal on that
  ground still has to say which fields leave `hardware.md`, so that there is
  one inventory and not two.
