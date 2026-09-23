#!/usr/bin/env bash
#
# How full this hypervisor's LVM-thin pools are (#538).
#
# THE GAP. `Saruman` has two thin pools: `pve/data` on the HDD mirror and
# `large_data/large_data` on the SSD logical drive made on 2026-09-19 (#527),
# which holds `alexander`. A thin pool is not a filesystem, so node_exporter's
# node_filesystem_* never sees one — the host reports `/`, `/boot/efi` and
# `/etc/pve` and nothing else. HostDiskCritical and HostDiskWillFillIn24h are
# structurally blind to both pools, and a pool that fills makes every guest on
# it read-only at once. fit-the-saruman-ssds.md §7 recorded the gap; this is
# what closes it.
#
# SO DISK ALERTS ON A HYPERVISOR COME IN TWO KINDS: filesystems, from
# node_exporter, and pools, from this file. Neither covers the other.
#
# DATA AND METADATA ARE SEPARATE, and metadata is the worse one to fill. Data
# full stops writes into unallocated space; metadata full can leave the pool
# needing `lvconvert --repair` before any guest on it starts again. The rules
# hold metadata to a lower threshold for that reason.
#
# AN INACTIVE POOL HAS NO PERCENTAGES, and lvs prints empty fields for it. That
# is not zero, so no percentage is emitted for it, and homelab_thin_pool_active
# says why. A pool that is inactive has no running guests either, and
# HypervisorGuestStopped is the alert for that.
#
# ROOT, and here it is needed rather than incidental: lvs reads the device
# mapper, which needs CAP_SYS_ADMIN.
#
# Usage: scripts/collect-thin-pool-state.sh [--print]
#        scripts/collect-thin-pool-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/thin-pool-state.prom"
HOSTNAME_LABEL="$(hostname)"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

STDERR_FILE="$(mktemp)"
trap 'rm -f "${STDERR_FILE}"' EXIT

# lvs, asked for exactly this, with `|` between fields and sizes in bytes:
#
#     pve|data|22.76|1.20|1234567890
#     large_data|large_data|11.40|0.98|940573065216
#     pve|olddata|||107374182400          <- an inactive pool
#
# Parsed by separator, never by column: an empty field is the case that matters,
# and whitespace splitting collapses it into the next one.
parse_lvs() {
  awk -F'|' '
    NF < 5 { next }
    {
      for (i = 1; i <= NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
      if ($1 == "" || $2 == "") next
      if ($5 !~ /^[0-9]+$/) next
      active = ($3 ~ /^[0-9]+(\.[0-9]+)?$/ && $4 ~ /^[0-9]+(\.[0-9]+)?$/) ? 1 : 0
      printf "%s %s %s %s %s %s\n", $1, $2, active, (active ? $3 : "-"), (active ? $4 : "-"), $5
    }
  '
}

emit() {  # <parsed rows>
  local rows="$1" vg pool active data meta size
  printf '# HELP homelab_thin_pool_active 1 when this LVM-thin pool is active and reports its usage.\n'
  printf '# TYPE homelab_thin_pool_active gauge\n'
  printf '# HELP homelab_thin_pool_data_percent Share of the thin pool data space allocated, 0-100.\n'
  printf '# TYPE homelab_thin_pool_data_percent gauge\n'
  printf '# HELP homelab_thin_pool_metadata_percent Share of the thin pool metadata space used, 0-100.\n'
  printf '# TYPE homelab_thin_pool_metadata_percent gauge\n'
  printf '# HELP homelab_thin_pool_size_bytes Size of the thin pool data volume.\n'
  printf '# TYPE homelab_thin_pool_size_bytes gauge\n'
  while read -r vg pool active data meta size; do
    [[ -n ${vg} ]] || continue
    local l="host=\"${HOSTNAME_LABEL}\",vg=\"${vg}\",pool=\"${pool}\""
    printf 'homelab_thin_pool_active{%s} %s\n' "${l}" "${active}"
    if ((active)); then
      printf 'homelab_thin_pool_data_percent{%s} %s\n' "${l}" "${data}"
      printf 'homelab_thin_pool_metadata_percent{%s} %s\n' "${l}" "${meta}"
    fi
    printf 'homelab_thin_pool_size_bytes{%s} %s\n' "${l}" "${size}"
  done <<<"${rows}"
  printf '# HELP homelab_thin_pools_total Thin pools this host has, active or not.\n'
  printf '# TYPE homelab_thin_pools_total gauge\n'
  printf 'homelab_thin_pools_total{host="%s"} %s\n' "${HOSTNAME_LABEL}" "$(printf '%s\n' "${rows}" | grep -c . || true)"
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {  # <name> <expected parse, rows joined by ;> <lvs output>
    local got
    got="$(printf '%s\n' "$3" | parse_lvs | tr '\n' ';')"
    if [[ "$got" == "$2" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$1"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$1" "$got" "$2"
      fail=1
    fi
  }
  check "Saruman's two pools" \
    "pve data 1 22.76 1.20 1234567890;large_data large_data 1 11.40 0.98 940573065216;" \
"  pve|data|22.76|1.20|1234567890
  large_data|large_data|11.40|0.98|940573065216"
  # The case whitespace splitting gets wrong: two empty fields, and the size
  # read as the data percentage.
  check "an inactive pool reports no percentages rather than zero" \
    "pve olddata 0 - - 107374182400;" "  pve|olddata|||107374182400"
  check "a pool at exactly 100 percent" \
    "vg p 1 100.00 4.10 1073741824;" "  vg|p|100.00|4.10|1073741824"
  check "no thin pools yields nothing" "" ""
  check "a line that is not a row is ignored" "" "  WARNING: something lvs said"
  # emit() on an inactive pool: the active gauge and the size, no percentages.
  got="$(HOSTNAME_LABEL=h emit "pve olddata 0 - - 1" | grep -v '^#' | tr '\n' ';')"
  want='homelab_thin_pool_active{host="h",vg="pve",pool="olddata"} 0;homelab_thin_pool_size_bytes{host="h",vg="pve",pool="olddata"} 1;homelab_thin_pools_total{host="h"} 1;'
  if [[ "$got" == "$want" ]]; then printf '\033[0;32m  PASS\033[0m emit() writes no percentage for an inactive pool\n'
  else printf '\033[0;31m  FAIL\033[0m emit() on an inactive pool\n       got      %s\n       expected %s\n' "$got" "$want"; fail=1; fi
  got="$(HOSTNAME_LABEL=h emit "" | grep -v '^#' | tr '\n' ';')"
  if [[ "$got" == 'homelab_thin_pools_total{host="h"} 0;' ]]; then printf '\033[0;32m  PASS\033[0m emit() with no pools still writes the total\n'
  else printf '\033[0;31m  FAIL\033[0m emit() with no pools\n       got      %s\n' "$got"; fail=1; fi
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v lvs >/dev/null 2>&1 || die "no lvs on this host — it has no LVM, so it has no thin pools to report."

# A FAILED lvs AND A HOST WITH NO THIN POOLS MUST NOT LOOK THE SAME. It is
# collect-guest-state.sh's lesson, where a qm that produced nothing was
# reported as a hypervisor with no guests. The exit status is checked, and a
# failure writes nothing, so the file's mtime stops moving and ThinPoolStateStale
# fires rather than the last numbers being served as current.
raw="$(LC_ALL=C lvs --noheadings --nosuffix --units b --separator '|' \
  -o vg_name,lv_name,data_percent,metadata_percent,lv_size \
  --select 'lv_attr=~^t' 2>"${STDERR_FILE}")"
rc=$?
if ((rc != 0)); then
  detail="$(grep -v '^$' "${STDERR_FILE}" | tail -2 | paste -sd'; ' -)"
  die "lvs failed (exit ${rc})${detail:+ — ${detail}}
Pool usage cannot be read, which is NOT the same as this host having no thin
pools. Nothing was written."
fi

rows="$(printf '%s\n' "${raw}" | parse_lvs)"

if ((PRINT_ONLY)); then emit "${rows}"; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit "${rows}" > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'thin-pool-state host=%s pools=%s\n' "${HOSTNAME_LABEL}" "$(printf '%s\n' "${rows}" | grep -c . || true)"
