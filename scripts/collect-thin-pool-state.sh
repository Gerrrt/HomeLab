#!/usr/bin/env bash
#
# How full the hypervisor's LVM-thin pools are (#538).
#
# THE GAP. `Saruman` has two thin pools: `pve/data` on the HDD mirror and
# `large_data/large_data` on the SSD logical drive made on 2026-09-19 (#527),
# which holds `alexander`. A thin pool is not a filesystem, so node_exporter's
# `node_filesystem_*` never sees one — the host reports only `/`, `/boot/efi` and
# `/etc/pve`. HostDiskCritical and HostDiskWillFillIn24h are therefore
# structurally blind to the pools, and a thin pool that fills makes every guest
# on it read-only at once. `fit-the-saruman-ssds.md` §7 recorded the gap; this
# is the collector it pointed at.
#
# WHY METADATA IS ITS OWN SERIES. A pool has two things that can run out, and
# the smaller one is worse: a full metadata volume can leave the pool needing
# `lvconvert --repair` rather than just more space. So data and metadata are
# separate gauges, and ThinPoolNearlyFull holds metadata to a lower threshold.
#
# WHY THIS IS NOT GUEST TELEMETRY (ADR-0007, ADR-0028). How full the hypervisor's
# own storage is, is a property of the hypervisor, read from `lvs` on the host
# that already reports to VLAN 99 — the same class of fact as
# `node_filesystem_avail_bytes` for its root. Pool names are the hypervisor's;
# nothing here names or measures what a guest is doing.
#
# ROOT IS NEEDED for the reading this time, not just for the textfile directory:
# `lvs` opens the block devices.
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

# One line per thin pool, from
#
#   lvs --noheadings --nosuffix --units b --separator '|' \
#       -o vg_name,lv_name,data_percent,metadata_percent,lv_size --select 'lv_attr=~^t'
#
#     pve|data|12.34|1.56|1073741824
#
# The separator is explicit because the default is whitespace padding, and an
# INACTIVE pool leaves both percentages empty — which whitespace splitting reads
# as the size shifting two columns left. An empty percentage is dropped rather
# than reported as 0: "not measured" is not "empty", and a pool reported empty
# is the one reading that must never be invented.
#
# Output: vg pool data_percent metadata_percent size_bytes, with "-" for a
# percentage that was not reported.
parse_lvs() {
  awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function pct(s)  { s = trim(s); return (s ~ /^[0-9]+(\.[0-9]+)?$/) ? s : "-" }
    NF == 5 {
      vg = trim($1); lv = trim($2); size = trim($5)
      if (vg == "" || lv == "" || size !~ /^[0-9]+$/) next
      printf "%s %s %s %s %s\n", vg, lv, pct($3), pct($4), size
    }
  '
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" expect="$2" got
    got="$(printf '%s\n' "$3" | parse_lvs | tr '\n' ';')"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  # Read off Saruman on 2026-09-22, verbatim.
  check "Saruman's two pools, as lvs pads them" \
    "large_data large_data 7.87 0.42 940828524544;pve data 1.55 0.29 852844609536;" \
"  large_data|large_data|7.87|0.42|940828524544
  pve|data|1.55|0.29|852844609536"
  # The reason for the explicit separator: an inactive pool has no percentages,
  # and with whitespace splitting the size would be read as the data percentage.
  check "an inactive pool reports no percentages rather than zero" \
    "pve data - - 1098437885952;" \
"  pve|data|||1098437885952"
  check "a full pool is 100.00, not rounded away" \
    "pve data 100.00 4.10 1098437885952;" \
"  pve|data|100.00|4.10|1098437885952"
  check "a line that is not a pool row is ignored" "" \
"  WARNING: some physical volume warning on stderr leaked to stdout"
  check "no thin pools yields nothing" "" ""
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v lvs >/dev/null 2>&1 \
  || die "no lvs on this host — it has no LVM tools, so it has no thin pools to report."

# A FAILED lvs AND A HOST WITH NO THIN POOLS MUST NOT LOOK THE SAME — the lesson
# collect-guest-state.sh learned by reporting zero guests on a hypervisor that
# ran one. Zero pools is an empty stdout with exit 0; anything else non-zero is
# a failure, and nothing is written, so ThinPoolStateStale says so.
#
# LC_ALL=C because lvs prints percentages in the locale's decimal separator.
raw="$(LC_ALL=C lvs --noheadings --nosuffix --units b --separator '|' \
  -o vg_name,lv_name,data_percent,metadata_percent,lv_size \
  --select 'lv_attr=~^t' 2>"${STDERR_FILE}")"
rc=$?
if ((rc != 0)); then
  detail="$(tr -d '\r' < "${STDERR_FILE}" | grep -v '^$' | tail -2 | paste -sd'; ' -)"
  die "lvs failed (exit ${rc})${detail:+ — ${detail}}
Pool usage cannot be read, which is NOT the same as this host having no thin
pools — reporting none here would hide a filling pool behind a quiet metric."
fi

rows="$(printf '%s\n' "$raw" | parse_lvs)"

# One family at a time: the exposition format wants each metric's samples
# together under its own HELP and TYPE, not interleaved pool by pool.
family() {
  local metric="$1" field="$2" help="$3"
  printf '# HELP %s %s\n# TYPE %s gauge\n' "$metric" "$help" "$metric"
  [[ -n "$rows" ]] || return 0
  while read -r vg pool data meta size; do
    [[ -n "$vg" ]] || continue
    local v
    case "$field" in data) v="$data" ;; meta) v="$meta" ;; size) v="$size" ;; esac
    [[ "$v" == "-" ]] && continue
    printf '%s{host="%s",vg="%s",pool="%s"} %s\n' "$metric" "$HOSTNAME_LABEL" "$vg" "$pool" "$v"
  done <<<"$rows"
}

emit() {
  family homelab_thin_pool_data_percent data "Percentage of an LVM-thin pool's data space in use."
  family homelab_thin_pool_metadata_percent meta "Percentage of an LVM-thin pool's metadata space in use."
  family homelab_thin_pool_size_bytes size "Size of an LVM-thin pool's data space."
  printf '# HELP homelab_thin_pools LVM-thin pools this host has, active or not.\n'
  printf '# TYPE homelab_thin_pools gauge\n'
  printf 'homelab_thin_pools{host="%s"} %s\n' \
    "$HOSTNAME_LABEL" "$(printf '%s\n' "$rows" | grep -c . || true)"
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'thin-pool-state host=%s pools=%s\n' "$HOSTNAME_LABEL" \
  "$(printf '%s\n' "$rows" | grep -c . || true)"
