# ADR-0047: Collect `smaug`'s SMART through a root cron job and the exporter's textfile collector, and do not collect its patch state

**Status:** Accepted · 2026-09

> [!NOTE]
> **A second collector uses this mechanism, 2026-09-22.** The TrueNAS
> product version, which `check-versions` compares against the documents and
> which `node_os_info` cannot supply — it reports the Debian base
> ([#616](https://github.com/Gerrrt/HomeLab/issues/616)). The same shape: a
> root cron job in TrueNAS's UI, a script on the pool, a `.prom` in the
> directory the exporter serves
> ([`build-the-nas.md`](../runbooks/build-the-nas.md) §6.7). The decision
> below is unchanged; it simply has two tenants.

## Context

Every host-level fact this estate collects — SMART attributes, package patch
state, the drift check — arrives by **push**: an agent collector installed
beside Alloy writes a `.prom` into Alloy's textfile directory and Alloy
carries it to Prometheus. `smaug` runs no Alloy, and
[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
says why: nothing on CasaBonita initiates upward, so Prometheus reaches down
and scrapes instead. [#256](https://github.com/Gerrrt/HomeLab/issues/256)
settled what it scrapes — `node_exporter` as a container in
`stacks/media/compose.yaml`, uid 65534, read-only, every capability dropped,
no `smartctl` in the image — and closed on 2026-09-19 handing
[#483](https://github.com/Gerrrt/HomeLab/issues/483) the consequence: SMART
is not free off the back of that container, and the push every other host
uses is the thing this host may not make.

The cost was already written down before it was paid. `hardware.md` recorded
the boot disk, an Intel DC S3520 read with `smartctl` before the install, at
**four reallocated sectors**, static, with the sentence *"this drive will
trip `SmartDriveBadSectors` on the day SMART collection reaches `smaug`"* —
and [ADR-0046](0046-record-a-known-static-smart-count-as-a-baseline-not-a-silence.md)
answered that the same day this was decided, with a baseline row for the
drive already in `scripts/render-smart-baselines.sh`, marked inert until
this issue delivered the series. Then on 2026-09-19 the Exos `sdb` FAULTED with **850 pending and 850
uncorrectable sectors** while its overall SMART assessment still read
`PASSED` and `zpool status` still said `ONLINE` for the leaf
([`replace-the-nas-disk.md`](../runbooks/replace-the-nas-disk.md)). Nothing
fired. `SmartDriveBadSectors` is written for exactly that reading and would
have paged within thirty minutes, had the series existed. The one host whose
job is holding data was the one whose disks nobody was watching.

The issue named the candidates, and #256's answer narrowed them:

- **A privileged sidecar** — `smartctl_exporter` or the estate's own script in
  a container with raw device access. The exact shape
  `scripts/collect-smart-state.sh`'s header and this stack's compose file
  argue against: the one container reversing `cap_drop: [ALL]`, non-root and
  `read_only`, to read a value the host reads for free.
- **TrueNAS's own S.M.A.R.T. service and scheduled tests** as `smaug`'s SMART
  path. Already running by default, and on the faulted disk it did notice —
  its alert reached the web UI and, through TrueNAS Connect, the operator's
  mailbox 37 seconds later (`replace-the-nas-disk.md`). A mailbox is not a
  phone, and pointing TrueNAS's alert service at ntfy would be a second
  alerting path with none of this repository's rules, tests, inhibitions or
  silences behind it. TrueNAS Connect is also a connection `smaug` initiates
  to a vendor cloud: egress to the internet, which this host has for its
  image pulls, and not the upward path into the estate ADR-0016 refuses —
  but a second channel this repository neither configures nor tests.
- **The collector's `--ssh` mode from the monitoring host**, the way
  `morpheus` is read. SSH on `smaug` is on since
  [ADR-0045](0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md), for one
  user with one key and no sudo — and `smartctl` needs root. That ADR named
  a passwordless-sudo wrapper as its fallback and declined to build it, and
  the collector's own header says why a sudoers entry for `smartctl` is a
  sudoers entry for `--set` and `-t select` too. It would also mean the key
  on the monitoring host could run a root-privileged command on the NAS, and
  the series would carry `instance="prometheus"`, the price the `--ssh` mode
  states for `morpheus` and one this host does not need to pay.
- **A host-side textfile job**: something on TrueNAS, as root, writing a
  `.prom` into a directory the container reads. TrueNAS ships `smartctl`
  (§2 of [`build-the-nas.md`](../runbooks/build-the-nas.md) used it at the
  console), `bash` and `python3`, and its UI has cron jobs that run as a
  chosen user and live in its config database. The container already mounts
  the whole root read-only; a directory it can read is one line.

Patch state is a different question. TrueNAS is an appliance: there is no
`apt` to ask, its updates arrive as an image from its own UI, and the estate's
`homelab_apt_*` rules — `SecurityUpdatesPending`, `RebootRequired`,
`PatchStateStopped` — have no referent on it. A collector could be written to
report nothing.

## Decision

**1. The estate's own collector runs on `smaug` as a root cron job in
TrueNAS's UI, and `node_exporter` serves what it writes.**
`scripts/collect-smart-state.sh` — the same script, with no fork for this
host — is fetched
to `/mnt/erebor/apps/stack` the way the compose file is, and
**System → Advanced Settings → Cron Jobs** runs it daily as `root` with
`PATH` set (cron's default has no `/usr/sbin`, where `smartctl` lives),
`TEXTFILE_DIR=/mnt/erebor/apps/textfile`, `--host smaug` so the label matches
the `instance` the scrape gives, and `timeout 600`, because a faulted disk
answers each command in sixty-second I/O timeouts and the script has no
timeout of its own. The container gains one read-only bind mount of that
directory at `/textfile` and one flag,
`--collector.textfile.directory=/textfile`, and nothing else: it stays uid
65534, read-only and cap-dropped. The series ride the `99 → 40:9100` scrape
that already exists as
`homelab_smart_*{host="smaug", device=…, instance="smaug", job="node"}`. Every
SMART rule in `host.rules.yaml` keys on `host` and applies unchanged, and the
`InstanceDown` inhibition, which matches on `instance`, covers them for the
first time on a host without an agent. Nothing on 40 initiates anything: the
file is local, and Prometheus reads it. The cron entry lives in TrueNAS's
config database and the script on the pool, so a TrueNAS upgrade — which
replaces the immutable root — touches neither.

**2. The boot disk's four sectors are a recorded baseline, confirmed on the
day, and nothing is silenced.** ADR-0046's row — `smaug /dev/sdc 4`, read
2026-09-16 under this issue — is rendered on the monitoring host and joined
`on(host, device)`, so `SmartDriveBadSectors` is quiet on the S3520 from the
first scrape *if the letter is right*. The S3520 sits on the chipset AHCI and
the Exos pair on the MegaRAID; `node_disk_info` named the one non-rotational
disk `sdc` on 2026-09-20, and the first `--print` run at the console is what
confirms it, before the redeploy that turns the series on. A wrong letter
fails loud — the drive falls back to `> 0` and pages — and the fix is one
row and `sudo make smart-state`, not a silence. `SmartDriveBadSectorsGrowing`
never reads the baseline and stays armed above it. **The faulted Exos gets
no row.** Its 850 pending sectors firing is the first alert in this estate
that covers the degraded mirror, and
[#558](https://github.com/Gerrrt/HomeLab/issues/558) is the swap that
resolves it; a baseline is for a count that has been judged static, and
that one is a disk on its way out.

**3. A stale collector is a finding.** `SmartStateStale` fires when a
`smart-state-*.prom` has not been rewritten in two days, read from the
mtime `node_exporter` exports per file. Presence would not do: a dead cron
does not delete its last output, and every number in it stays plausible.
Every other collector is a systemd timer with a failed unit to say so;
`smaug`'s has no unit, no `homelab_job_*`, and nothing on the monitoring host
that knows it should run. The rule names no host, so it also covers the two
files on the monitoring host and `oracle`'s the day it collects.

**4. TrueNAS's S.M.A.R.T. service and scheduled self-tests stay on, and are
not the alerting path.** They run the tests; this decision publishes the
attributes. Their alerts reach the web UI and, through TrueNAS Connect, a
mailbox; that stays what it is — a second, informational channel — rather
than being wired to a phone, so the estate keeps one path that pages and one
set of rules that is tested. Whether `smaug` should keep initiating a
connection to TrueNAS Connect at all is egress policy for the segment and
is not decided here.

**5. Patch state is not collected on `smaug`, and this is the record of
that.** There is nothing to ask. The reopen condition is a TrueNAS update
advisory the operator needs on a phone; the mechanism above would carry
`midclt call update.check_available` into `homelab_pkg_system_update_available`
in one more cron line, and `SystemUpdateAvailable` already exists for it.

**6. The collector learns the two Intel attributes the S3520 reports and it
ignored.** `Unsafe_Shutdown_Count` becomes
`homelab_smart_unsafe_shutdowns_total`, the ATA twin of the NVMe counter it
already emits — the number [#574](https://github.com/Gerrrt/HomeLab/issues/574)
asks for. `Media_Wearout_Indicator`, normalised, becomes
`homelab_smart_percentage_used`, so `SmartDriveWearHigh` reads this drive
too. Done here because the script reaches `smaug` by a walk to the console,
and once is enough.

## Consequences

- **One alerting path, and the five SMART rules now cover the disks that
  matter most.** `SmartDriveBadSectors` on `smaug` is live from the first
  scrape after the redeploy; the reading the pool called `ONLINE` would have
  paged.
- **A root job runs a script from the pool.** The script is fetched once from
  `main` and run from its copy — never `curl | bash` in cron — and it lives on
  `erebor/apps`, which root writes, `frodo` reads and the SMB share does not
  reach. The `.prom` it writes is world-readable, deliberately: uid 65534 has
  to read it, and it carries no serial numbers by the script's design. That
  and the unauthenticated `9100` are the residuals `docs/security.md` records.
- **The device letter is the baseline row's weak point, and it fails the
  right way.** The row names `/dev/sdc`, and only `homelab_smart_healthy`
  carries `model`. After #558's swap, or any reboot that reorders the AHCI
  and MegaRAID enumeration, the S3520 can draw a different letter — at which
  point the row matches nothing, the boot disk pages at `> 0`, and an Exos
  that drew `sdc` is held to 4 rather than to 0, which is four sectors of
  slack on a drive that reports none. Re-run the `--print` after any disk
  change and correct the row; the growth rule is the backstop either way.
- **Changes to the collector reach `smaug` only by re-fetch.** As with the
  compose file: nothing on that host pulls from `main`.
- **The mechanism is reusable.** A periodic task writing `zpool status` vdev
  states into the same directory is the other half of what
  `replace-the-nas-disk.md` asked for, and it is a follow-up rather than part
  of this decision.
- **Reopened by any of these**, each with its own decision first: TrueNAS
  publishes an update advisory the operator wants paged; a zvol or a USB
  device appears in `/sys/block` and the enumeration needs a rule; #574
  decides the unsafe-shutdown counter is worth a rule of its own; or the
  cron job proves unreliable across a TrueNAS upgrade, in which case the
  privileged-sidecar shape gets weighed again against what it costs.
