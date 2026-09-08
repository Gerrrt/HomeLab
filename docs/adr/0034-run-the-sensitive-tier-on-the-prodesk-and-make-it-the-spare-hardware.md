# ADR-0034: Run the sensitive tier on the ProDesk, and make it the spare hardware

**Status:** Accepted · 2026-09

## Context

[ADR-0008](0008-place-services-by-data-trust.md) put the sensitive tier —
Vaultwarden, Immich, Paperless-ngx, Home Assistant, behind Caddy and step-ca,
with AdGuard Home, ntfy and Homepage alongside — on a mini PC on Winterfell,
and said in its consequences: *"New hardware is required … Two purchases where
the plan originally assumed zero."* Separately,
[#92](https://github.com/Gerrrt/HomeLab/issues/92) asked for a cold spare for
the firewall: the same ProDesk 600 G4 model as `morpheus`, so a pfSense restore
goes straight through, racked on a shelf and **left powered off** so that a
spare on the network is not exposed to whatever took the primary.

Those are two machines. Only one of them was ever on the shopping list.
`README.md`'s "current top items" sentence named the UPS pack, the shelf
switch and the spare ProDesk, and every session that answered "what should I
buy" answered from it. The tier's host lived in ADR-0008's consequences and,
from 2026-09-04, in one roadmap paragraph;
[#102](https://github.com/Gerrrt/HomeLab/issues/102) closed that day by
splitting into one issue per service, and the box itself got none. No spec
was ever written beyond "low-power mini PC" and, twice in passing,
"N100-class".

On 2026-09-08 one ProDesk 600 G4 was bought — i5-8500T, 32 GB, 512 GB SSD —
as the spare, because that was the only ProDesk anyone had been told to buy,
and in the belief that it would also host the tier. This ADR decides what it
is for, rather than treating a second purchase as the default.

**What the tier's workload actually is**, read from its issues rather than
from the phrase "low-power": Immich's machine learning is the most
memory-hungry thing that will run in the estate
([#132](https://github.com/Gerrrt/HomeLab/issues/132)); Paperless OCR takes
every core it is given for minutes at a time
([#133](https://github.com/Gerrrt/HomeLab/issues/133)); Postgres with the
vector extension, Redis and Home Assistant sit beside them; and seven more
services have been proposed for the same box since. Six cores and 32 GB fit
that. Four cores and 16 GB, which is what "N100-class" means in practice, is
the box on which #132 already expects to disable the machine learning on day
one.

**What the cold spare actually protects against.** A dead `morpheus`, restored
in twenty minutes at 1am rather than in an hour. The config it would restore
is exported nightly, encrypted, verified and copied to `oracle`
([ADR-0015](0015-give-oracle-the-off-host-jobs.md)); the restore path exists
without the spare, onto any hardware, with an interface-assignment dialogue in
it. And the drill that #92 exists for — proving the runbook is not a
hypothesis — needs the box on a bench once, not in a drawer for a year.

## Decision

**The ProDesk bought on 2026-09-08 is the sensitive tier's host.** It is
rehearsed on first, as the firewall spare, and it is the firewall's spare
hardware for as long as there is no other.

1. **Rehearse the firewall restore on it before it holds anything.**
   [`restore-the-firewall.md`](../runbooks/restore-the-firewall.md)'s bench
   procedure, on this box, closes the rehearsal half of #92 on exactly the
   hardware that would be the spare in a disaster. That is a better-tested
   restore path than a powered-off box nobody has booted.
2. **Then wipe it and build the tier**, under
   [#404](https://github.com/Gerrrt/HomeLab/issues/404), which is the tracker
   the host lost when #102 split. The order there is the one
   [ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)
   and [ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)
   require: disk encryption decided, the stack built empty, the off-estate
   copy proven, TOTP enrolled, and only then the first real photo.
3. **In a disaster the tier box is the spare hardware.** If `morpheus` dies,
   the tier box is wiped and the newest export restored onto it — same model,
   so the interface names match and the restore goes straight through. The
   tier is down until a replacement ProDesk arrives. ADR-0023 already says one
   mini PC cannot be made highly available and nothing the household needs in
   an emergency may run through it, so "the tier is allowed to be down" is a
   property this estate has already accepted, not a new one.
4. **The cold spare is deferred, not rejected.** #92's objection to a
   powered-on spare — a box holding the firewall's config, reachable on the
   network — does not apply to a box running Immich. What is given up is the
   twenty-minute restore. A dedicated spare is bought when the tier holding
   real data makes an hour of firewall downtime, and the household services
   down with it, unacceptable; that is a judgement to make then, with the data
   in hand, not now.

The 512 GB disk is enough for everything on the tier except the photo library.
The G4 has a free bay; a second drive is sized when the library's size is
known, under #404, and is the only purchase this decision leaves outstanding
for the host.

## Consequences

- **One box does two jobs, and the second job destroys the first.** A firewall
  restore onto this box is a wipe of the tier. That is the whole trade, and it
  is written into `restore-the-firewall.md`'s *Afterwards* section: order a
  replacement ProDesk the same day, because until it arrives the estate has no
  password manager, no photo library and no Home Assistant.
- **#92 narrows to the rehearsal.** The purchase half is done by this box; the
  "racked on the shelf, powered off" half is withdrawn.
  [`fit-the-ups-battery.md`](../runbooks/fit-the-ups-battery.md) step 2, item
  4 no longer applies; the shelf carries the switch and nothing else until
  #404 decides where the host lives — which is also where
  [#134](https://github.com/Gerrrt/HomeLab/issues/134)'s USB radio question
  is answered, since a rack in a closet is a poor place for one.
- **The shopping sentence in `README.md` names every outstanding purchase**,
  not the three coupled to the UPS work. A sentence that answers "what should
  I buy" and omits a machine is how this decision came to be needed, and it is
  the same defect class [ADR-0026](0026-check-the-documents-where-the-truth-is.md)
  describes: prose about what is outstanding that nothing checks.
- **ADR-0008 is not superseded.** Its placement and its "two purchases" hold;
  this ADR decides which machine one of them is and defers the other.
- **Reopened by:** the tier holding real data and a firewall failure costing
  more than an hour being judged unacceptable — buy the dedicated spare and
  restore #92's shelf paragraph; or the tier outgrowing this box, which is a
  second tier host and this box becoming the spare after all.
