# ADR-0046: Record a known static SMART count as a baseline the rule reads, not as a silence

**Status:** Accepted · 2026-09

## Context

`SmartDriveBadSectors` fired on `homelab_smart_reallocated_sectors > 0`, and
that was right: a remapped sector never un-remaps, so the first one on a drive
is the finding, and it is how `oracle`'s laptop HDD was found to carry 32 of
them on 2026-09-07 ([#351](https://github.com/Gerrrt/HomeLab/issues/351)).
The count was read, judged — pending and uncorrectable both zero, the drive's
own assessment passing — and written into an Alertmanager silence, with the
trend split off into `SmartDriveBadSectorsGrowing` so that the silence could
not hide growth.

That silence expires on 2026-10-08 with no issue behind it
([#572](https://github.com/Gerrrt/HomeLab/issues/572)). On that day the rule
pages again with nothing to say that the silence's comment did not already
say — the shape [#531](https://github.com/Gerrrt/HomeLab/issues/531) was filed
to remove for the battery, arriving a second time for the disk. And
[`hardware.md`](../hardware.md) already promises a third: `smaug`'s Intel DC
S3520 boot disk carries four reallocated sectors, and *"will trip that alert
on the day SMART collection reaches `smaug`"*
([#483](https://github.com/Gerrrt/HomeLab/issues/483)).

A silence is the wrong tool for a fact, three ways over. It matches labels,
not values, so silencing 32 sectors silences 90 — which is why the trend had
to become a second alertname. It expires, and the expiry is a calendar nobody
keeps. And it lives in Alertmanager's state rather than in git, so nothing
reviews it, nothing restores it with the stack, and the reasoning for it is a
comment field. Three options were weighed:

- **Renew the silence** every thirty days, per drive, with an owner and an
  expiry. Cheapest, and what the estate did once; it scales as a chore.
- **Drop the static rule** and keep only the growth rule. Loses the
  first-sight page on a drive nobody has looked at — the page that found
  `oracle`'s 32.
- **A baseline the rule reads.** The rule fires on *more than the number we
  wrote down*; the number lives in git with the date it was read.

## Decision

A static reallocated count is a fact about a drive, not an event, and is
recorded — in `scripts/render-smart-baselines.sh`, one row per drive already
looked at: host, device, count, the day it was read, the issue that read it.
`make smart-state` renders the table on the monitoring host as
`homelab_smart_reallocated_sectors_baseline{host, device}`, and
`SmartDriveBadSectors` compares the live count to it, joined `on(host,
device)`. A drive with no row is compared against zero, which is what the rule
always did, so a new disk is covered with no edit and recording a count is
opt-in per drive.

The table is rendered centrally, not by the collector on each host, because
the collector on `oracle` is a copy installed once, `smaug` has no collector at
all, and `morpheus` is read over SSH; one file on the monitoring host covers
every drive because the join does not care which instance scraped the
baseline. It is the shape `homelab_job_max_age_seconds` already has: a
table in `scripts/install-timers.sh`, rendered into the same directory, that
the rules join against instead of naming jobs — or drives — themselves.

`SmartDriveBadSectorsGrowing` is unchanged and never reads the baseline. The
two rules now mean different things by construction — *above what was
recorded* and *moving now* — rather than by one being silenced.

The silence on `oracle`'s 32 is deleted, not left to expire. No
`SmartDriveBadSectors` silence is the correct number of them; the day one is
wanted again, the table is where the answer belongs.

## Consequences

- **The failure mode is loud.** A table that is not rendered, or a row naming
  the wrong host or device, matches nothing; the drive falls back to `> 0` and
  pages. A baseline cannot hide growth, because it is a ceiling and growth is
  above it. The mistake that a silence made possible — quieting a value it
  never read — is not available.
- **The key is `host` and `device`, and a device letter can move.** The
  sectors metric carries no `model`, and serials are never emitted by
  decision. On a host with several disks a reboot can rename one; the row
  stops matching, the drive pages, and the fix is one edit. That is accepted
  over teaching every SMART series a new label, and `smaug`'s row says its
  label is to be confirmed on the day #483 emits it.
- **Reallocated sectors only.** Pending sectors are transient by definition,
  and no drive here has a static uncorrectable or media-error count. The day
  one does, it gets a baseline of its own kind — the pattern is established —
  and not a silence.
- **Recording a count is a commit and a `make` target**, reviewed like any
  other change, with the date and the issue beside the number. A rising count
  is never answered with a row: that is the growth rule's finding, and the
  answer to it is a disk.
- **[#575](https://github.com/Gerrrt/HomeLab/issues/575) is what proves the
  silence stayed deleted.** Its gauge per active silence, and its rule for a
  silence that names no issue, are the mechanism side of the same complaint;
  this decision removes the one silence that would have tripped it.
