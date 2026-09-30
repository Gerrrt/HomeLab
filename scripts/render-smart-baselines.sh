#!/usr/bin/env bash
#
# The reallocated-sector counts this estate has already looked at, as a metric.
#
# WHAT A STATIC COUNT IS. A remapped sector never un-remaps, so the first one on
# a drive is a finding and SmartDriveBadSectors fires on it — correctly, since
# that first sight is how oracle's 32 were found at all (#351). But once the
# count has been read, judged and written down, it is a fact about the drive
# and not an event, and a rule that keeps paging on it says nothing the reader
# does not already know. Until 2026-09-20 the answer was an Alertmanager
# silence, and a silence is the wrong tool for a fact three ways over: it
# matches LABELS and not values, so silencing 32 sectors also silences 90; it
# expires, and the expiry is a calendar nobody keeps (#572, #531); and it lives
# in Alertmanager's state, not in git, so nothing reviews it and nothing
# restores it with the stack.
#
# THIS TABLE IS THE RECORD. One row per drive whose count has been looked at:
# the number, the day it was read, and the issue that read it. `make
# smart-state` — the daily job on the monitoring host — renders it as
#
#     homelab_smart_reallocated_sectors_baseline{host, slot}
#
# and SmartDriveBadSectors compares the live count to it, so the rule means
# "more than the number we wrote down". SmartDriveBadSectorsGrowing keeps
# meaning "moving now" and never reads this file. A drive with no row here is
# compared against zero, which is what the rule always did — so recording a
# count is opt-in per drive and a new disk is covered with no edit.
#
# WHY IT FAILS LOUD. If this file is not rendered, or a row names the wrong
# host or slot, the join finds nothing and the drive falls back to `> 0`:
# oracle pages again with its 32, which is visible and one edit away from
# right. The mistake that would matter — a baseline hiding growth — cannot
# happen, because a baseline is a ceiling and growth is above it.
#
# WHY IT IS RENDERED HERE AND NOT BY THE COLLECTOR. collect-smart-state.sh runs
# on each host: oracle carries a copy installed once and not updated, smaug's
# is a root cron job in TrueNAS's UI with no `make` to render a table (#483,
# ADR-0047), and morpheus is read over SSH. One table rendered
# on the monitoring host covers all of them, because the alert joins on
# `on(host, slot)` and does not care which instance scraped the baseline —
# the same shape homelab_job_max_age_seconds already has (install-timers.sh).
# The series carries instance="prometheus" for that reason, as morpheus's own
# SMART series do, and the collector says why.
#
# WHY host AND slot, NOT device, model OR serial (#745, ADR-0066). `slot` is
# the drive's /dev/disk/by-path name — the port it is cabled to — which the
# collector puts on every series. Until 2026-09-30 this table was keyed on the
# device letter, and a letter is whatever the kernel handed out on this boot:
# smaug's boot SSD was sdc, then sdb, on two boots on one day with nothing
# moved, and each time the row stopped matching and the drive paged on its
# recorded four. A port moves only when a cable does, and then paging is
# right, because that is a hardware change. model is not unique (the Exos
# pair), and serials are never emitted (collect-smart-state.sh, "NO SERIAL
# NUMBERS").
#
# A COLLECTOR THAT EMITS NO slot STILL MATCHES. A copy installed before #745 —
# oracle's is installed once and not updated — emits `device` alone, and the
# rule uses `device` as the slot for such a series. So a row for one of those
# drives names the device label, as oracle's does below; when that host's
# collector is reinstalled, `--print` shows the new slot and the row changes
# to it in the same commit, or the drive pages at `> 0` — loud, as above.
#
# RECORDING A COUNT. Read it and its slot (`collect-smart-state.sh --print` on
# the host, or the live series), add the row with today's date and the issue that looked, then on the
# monitoring host `sudo make smart-state`. The rule goes quiet on the next
# evaluation. Do not raise a row because the count went up — that is
# SmartDriveBadSectorsGrowing's finding, and the answer to it is a disk.
#
# Usage: scripts/render-smart-baselines.sh [--print]
set -euo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/smart-baselines.prom"

# host      slot      sectors  read-on     issue   note
#
# oracle    ST500LT012 laptop HDD, 5400 rpm, ~3100 power-on hours when read.
#           Pending and uncorrectable both 0, overall assessment passing. Its
#           collector predates #745 and emits no slot, so the row names the
#           device label, which the rule falls back to; see above.
# smaug     Intel DC S3520 boot disk (docs/hardware.md). Nothing pending or
#           uncorrectable; normalised 099 against a threshold of 000. INERT
#           until build-the-nas.md §6.4 runs the collector on smaug (#483,
#           ADR-0047): the device label is whatever it emits, and /dev/sdc is
#           node_disk_info's name for the one non-rotational disk there on
#           2026-09-20. §6.4 step 1 confirms it and step 4 corrects this row.
#           Moved to /dev/sdb on 2026-09-29 (#599). The pool went onto the
#           chipset that day (ADR-0052), and after that the letters moved
#           again on a boot that changed only the memory. So on smaug a
#           letter is not stable across reboots, and since #745 the row names
#           the port: the S3520 is on the chipset AHCI's ata6 (hardware.md).
#           The count, 4, has not changed since 2026-09-16.
BASELINES=(
  "oracle   /dev/sda   32   2026-09-07   351"
  "smaug    pci-0000:00:17.0-ata-6    4   2026-09-16   483"
)

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

PRINT_ONLY=0
case "${1:-}" in
  "") ;;
  --print) PRINT_ONLY=1 ;;
  -h|--help) sed -n '/^# Usage:/,$p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;/^set -/q'; exit 0 ;;
  *) die "unknown argument $1" ;;
esac

row_host()    { awk '{print $1}' <<<"$1"; }
row_slot()    { awk '{print $2}' <<<"$1"; }
row_sectors() { awk '{print $3}' <<<"$1"; }
row_readon()  { awk '{print $4}' <<<"$1"; }
row_issue()   { awk '{print $5}' <<<"$1"; }

emit() {
  printf '# HELP homelab_smart_reallocated_sectors_baseline Reallocated sectors already read and recorded for this drive; SmartDriveBadSectors fires above it. See scripts/render-smart-baselines.sh.\n'
  printf '# TYPE homelab_smart_reallocated_sectors_baseline gauge\n'
  local row host slot sectors
  for row in "${BASELINES[@]}"; do
    host="$(row_host "${row}")"
    slot="$(row_slot "${row}")"
    sectors="$(row_sectors "${row}")"
    [[ "${sectors}" =~ ^[0-9]+$ ]] \
      || die "baseline for ${host} ${slot} is not a whole number: ${sectors@Q}"
    [[ "$(row_readon "${row}")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
      || die "baseline for ${host} ${slot} has no read-on date; a count with no date is not a record"
    [[ "$(row_issue "${row}")" =~ ^[0-9]+$ ]] \
      || die "baseline for ${host} ${slot} names no issue; a count nobody looked at is not a baseline"
    printf 'homelab_smart_reallocated_sectors_baseline{host="%s",slot="%s"} %s\n' \
      "${host}" "${slot}" "${sectors}"
  done
}

if ((PRINT_ONLY)); then
  emit
  exit 0
fi

[[ -d "${TEXTFILE_DIR}" ]] \
  || die "no ${TEXTFILE_DIR} — run 'sudo ./scripts/install-timers.sh --install' first"

# Not named after any job in install-timers.sh's JOBS table: run-scheduled.sh
# writes "${JOB}.prom" and would clobber it, which is what happened to the
# patch-state collector (#360).
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"

printf 'smart-baselines drives=%s -> %s\n' "${#BASELINES[@]}" "${PROM##*/}"
