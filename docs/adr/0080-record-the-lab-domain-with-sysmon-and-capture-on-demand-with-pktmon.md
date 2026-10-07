# ADR-0080: Record the lab domain with Sysmon, and capture on demand with Pktmon

**Status:** Accepted · 2026-10 · adds to
[ADR-0077](0077-configure-the-lab-domain-with-ansible-from-phoenix.md) (a role
and two playbooks in `ansible/`)

## Context

[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
has the lab domain's six guests scraped by the lab Prometheus on 9182, which
gives metrics. It says nothing about their logs.
[#266](https://github.com/Gerrrt/HomeLab/issues/266)'s Wazuh agent is already
on all six (`roles/soc_agents`), and it can only forward what Windows records.

**Windows' default event logging does not record what this domain exists to
exercise** ([#450](https://github.com/Gerrrt/HomeLab/issues/450)).

- Process creation without its command line says *that* something ran.
- No image loads, no network connections attributed to a process, and no
  named-pipe activity are recorded at all.

Kerberoasting, NTLM relay and the tooling that drives them are visible in
exactly those. Turning on `dcsync` from #449's weakness tags to see what fires
is pointless while the endpoint records nothing of it.

Read from the six on 2026-10-06:

- none had Sysmon, by hand or by GPO;
- all six have `pktmon` (four Server 2025, two Windows 11);
- each C: had about 40 GiB free.

## Decision

Decided on #450, 2026-10-06.

1. **Sysmon on every guest in `lab_domain`, as an Ansible role.**
   `roles/sysmon` is a stage in `lab-domain.yml` (tag `sysmon`), so it applies
   to the six and to any guest added to the inventory later, and `verify.yml`
   fails on any guest where it is not running the pinned version with the
   vendored config.
2. **sysmon-modular's balanced profile, not SwiftOnSecurity's.**
   [olafhartong/sysmon-modular](https://github.com/olafhartong/sysmon-modular)
   tags its rules with ATT&CK technique IDs and logs filtered image loads
   (event 7) and named pipes (17/18). Both are things #450 names.
   SwiftOnSecurity's config is quieter and as widely used, but it excludes
   image loads entirely and logs few pipe events. The lab is a place to see
   things fire, so the louder profile is the right one.
3. **The config is vendored, from a release, byte for byte.**
   `scripts/vendor-sysmon-config.sh` fetches `sysmonconfig-<target>.xml` from
   one `configs-<commit>` release. That is where sysmon-modular now publishes
   its merged profiles, built by CI for each Sysmon version. The script checks
   the file against that release's `SHA256SUMS` and records the release and
   sha256 in `VENDORED`. Every change to what the guests record is a diff in a
   PR, as [ADR-0069](0069-vendor-the-ja4-scripts-into-the-sensor-stack-rather-than-build-an-image.md)
   did for the JA4 scripts.
   - The file keeps upstream's CRs, tabs and trailing spaces.
     `.gitattributes` marks it `-text` and the EditorConfig checker skips it.
   - Sysmon records the sha256 of the file it was configured from as
     `ConfigHash`. The role reapplies the config when that differs, and
     `verify.yml` fails when it does. A config changed by hand on a guest is
     drift, like a stale one.
4. **The Sysmon binary is pinned by version and sha256.** It is downloaded
   from Microsoft's one URL, like `windows_exporter`'s MSI, rather than from a
   copy staged somewhere. That URL is not versioned, so the pin goes stale
   when Microsoft ships a release. Until then a stale pin costs nothing: a
   guest already on the pinned version downloads nothing. After that, a
   rebuild or a new guest fails at the checksum, before anything is
   uninstalled, and the fix is a two-line bump in `group_vars/all.yaml`.
   - Upstream builds the profile for 15.21 (schema 4.91). The pinned binary
     is 15.22, which reads that schema.
5. **The Sysmon channel is 256 MiB, not the 64 MiB Sysmon leaves.** Until
   #266 ships the events off the guest, the channel is the only copy.
   `bahamut` wrote 8.6 MiB an hour in its first quarter-hour, install burst
   included. At that rate the channel holds about a day, where the default
   held about seven hours.
6. **Pktmon is on demand, not standing.** `pktmon-start.yml` and
   `pktmon-stop.yml` start a capture on one guest and bring it back to
   `phoenix` as pcapng. Both require `--limit`.
   - It is Windows' own capture: nothing to install, and nothing left running
     or on disk afterwards.
   - It captures at the NIC (`--comp nics`), circular at 512 MB, with an
     optional port or address filter.
   - [#437](https://github.com/Gerrrt/HomeLab/issues/437)'s Zeek on `fenrir`
     is the always-on view of the lab bridge, and it keeps logs, not packets.
     Pktmon is the packets, from inside one guest, for the minutes an
     investigation asks for.

### Rejected

- **A hand-rolled Sysmon config.** It would be the lab's own blind spots,
  written down. A maintained profile carries other people's detections, and
  re-vendoring picks up their fixes.
- **Downloading the config at run time.** sysmon-modular's `latest` alias moves
  on every push to its default branch, so the guests' config would change
  without a commit here.
- **Staging the Sysmon zip on `odin` or `phoenix`**, as `soc_agents` does for
  its MSIs. Those MSIs have no standing URL; Sysmon has one. Staging would
  trade a pin that goes stale loudly for a file that has to be put back after
  every rebuild.
- **A standing capture on each guest.** Six circular captures would duplicate
  what `fenrir` sees, on disks that were not sized for it, and nobody would
  read them.

## Consequences

- **The guests log much more.** That is the point, but the Sysmon channel is
  the first thing on these guests whose size depends on activity. Re-read
  its fill rate on the DCs once Wazuh forwards it (#266).
- **Wazuh does not read the channel yet.** Adding
  `Microsoft-Windows-Sysmon/Operational` to the agents' `localfile`
  configuration belongs to #266's manager-side work, not to this role.
- **A Sysmon release breaks a rebuild until the pin moves.** That is the price
  of decision 4, and the failure names the cause: a checksum mismatch on
  `Sysmon.zip`.
- **Re-vendoring is a reapply on all six.** A new `configs-*` release changes
  the vendored file's sha256. The next `--tags sysmon` run then runs
  `sysmon -c` on every guest, and `verify.yml` fails on any guest it has not
  reached.
- **An unfiltered capture includes `phoenix`'s own SSH session.** Pktmon's
  filters are include-only, so there is no "everything but 22". Filter by port
  or address, or drop it in Wireshark.
