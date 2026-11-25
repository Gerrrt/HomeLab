# ADR-0137: Leave the lab domain unpatched, and refresh it by rebuild

**Status:** Accepted · 2026-11 · within
[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)

## Context

Nothing in the repository says whether ADR-0029's six Windows guests are
patched. A read-only audit of `titan` on 2026-11-13 found the newest hotfix
dated 2026-01-14, the template's baseline. On 2026-11-25 Windows Update listed
five pending, including the 2026-11 cumulative update and the 2026-10 .NET
security update. Windows Update on the guest downloads and notifies
(`AUOptions` 3), so nothing installs. The patch-state alerts of
[#1544](https://github.com/Gerrrt/HomeLab/pull/1544) read apt, so nothing
reports it either.

Three things make in-place patching a poor fit for this domain:

- **It exists to be attacked as Windows ships.** §0 of
  [`build-the-lab-domain.md`](../runbooks/build-the-lab-domain.md) forbids
  hardening it, and §5 already warns that a servicing update can move a
  default the exercises depend on, such as SMB signing on `titan`. A
  cumulative update is exactly that kind of change, arriving unannounced.
- **The servers are evaluation-licensed and cannot be rearmed.** They must be
  rebuilt from the template before each expiry: `titan`'s ends about
  2027-04-05, and `LabWindowsEvaluationExpiring` warns 30 days ahead. The
  rebuild is scripted ([#448](https://github.com/Gerrrt/HomeLab/issues/448)).
  So every guest is replaced on a cycle of at most 180 days whatever this
  decides.
- **Patching the DCs means reboots** on a 7.2K mirror whose boot storm §0
  already plans around.

## Decision

**The six are not patched in place.** Windows Update stays as the template
leaves it. Pending updates on a lab guest are expected, and are not an audit
finding.

**The refresh is the rebuild.** Each rebuild before a licence expiry starts
from the template's install media, and whatever that media carries is the
patch level for the next cycle. This decision adds no update step to the
template build.

**A deliberate patch is recorded, like a hardening switched off.** When an
exercise needs a specific patch level, it is installed on purpose and the
exercise's record says so (§0's rule, applied in the other direction).

## Alternatives considered

- **Monthly `win_updates` from `phoenix`.** Keeps the guests current, at the
  cost of a monthly run, DC reboots, and an exercise environment that moves
  under the exercises. `verify.yml` would catch a moved signing default
  afterwards, but only after it had moved.
- **Patch the template before sysprep.** Each rebuild would then start
  current, with no in-place patching. Worth revisiting if the install media
  falls far behind, but it adds a long, network-bound step to a build that is
  already the slow part.

## Consequences

- **The lab domain runs known vulnerabilities by decision.** It lives on
  VLAN 30, the lab segment, built for the techniques ADR-0014 names, and
  reaches nothing VLAN 30 is not already allowed to reach. Its guests do
  reach the internet, so a guest is no safer than its unpatched browser and
  SMB client. Browsing from a lab guest is part of that risk, and the lab is
  not for browsing.
- **Future audits read pending updates as expected**, and look instead at
  whether the rebuild cycle is being kept: the licence clock is the measure.
- **`#1544`'s alerts stay apt-only.** No Windows patch-state collector is
  planned while this decision holds.
