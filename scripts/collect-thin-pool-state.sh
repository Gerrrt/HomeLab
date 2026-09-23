#!/usr/bin/env bash
#
# How full the hypervisor's LVM-thin pools are (#538).
#
# THE GAP. `Saruman` has two thin pools: `pve/data` on the HDD mirror and
# `large_data/large_data` on the SSD logical drive made on 2026-09-19 (#527). A
# thin pool is not a filesystem, so node_exporter's `node_filesystem_*` never
# sees one — the host reports `/`, `/boot/efi` and `/etc/pve` and nothing else.
# HostDiskCritical and HostDiskWillFillIn24h are therefore structurally blind to
# both pools, and a thin pool that fills makes every guest on it read-only at
# once. fit-the-saruman-ssds.md §7 recorded the blind spot; this closes it. It is
# #351's shape: a reading the host has and the stack never asked for.
#
# METADATA IS REPORTED BESIDE DATA, NOT INSTEAD OF IT. A pool whose metadata
# fills is worse off than one whose data fills — the pool can go read-only or
# need `thin_repair` — and it can happen with the data half nearly empty, on a
# pool that holds many snapshots. host.rules.yaml holds it to a lower threshold.
#
# ROOT IS NEEDED for the reading, unlike guest-state: `lvs` opens the block
# devices. The unit runs as root for that and for the textfile directory.
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

# The lvs call, and the only shape the parser accepts. `|` as the separator
# because a field is never allowed to contain one, bytes with no suffix so the
# size is an integer, and LC_ALL=C so a German locale cannot turn 22.76 into
# 22,76. `lv_attr=~^t` is "this LV is a thin pool" — the first attribute
# character is the volume type, and `t` is thin pool.
LVS_ARGS=(--noheadings --units b --nosuffix --separator '|'
  -o 'vg_name,lv_name,data_percent,metadata_percent,lv_size'
  --select 'lv_attr=~^t')

# One pool per line in, `vg pool data meta size` out. A row whose percentages
# are blank is an INACTIVE pool — lvs cannot read usage from a pool that is not
# active — and is dropped rather than reported as zero: an empty pool and a pool
# nobody can read must not look the same, which is guest-state's lesson.
parse_lvs() {
  awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    NF < 5 { next }
    {
      vg = trim($1); lv = trim($2); data = trim($3); meta = trim($4); size = trim($5)
      if (vg == "" || lv == "") next
      if (data !~ /^[0-9]+(\.[0-9]+)?$/ || meta !~ /^[0-9]+(\.[0-9]+)?$/) next
      if (size !~ /^[0-9]+$/) next
      printf "%s %s %s %s %s\n", vg, lv, data, meta, size
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
  # Saruman's two pools. lvs indents every row by two spaces and pads nothing
  # between separators; the trim is what keeps the vg name from being "  pve".
  check "both of Saruman's pools" \
    "pve data 22.76 1.50 141733920768;large_data large_data 11.42 0.87 940573786112;" \
"  pve|data|22.76|1.50|141733920768
  large_data|large_data|11.42|0.87|940573786112"
  check "a full pool reads 100.00" "pve data 100.00 4.10 141733920768;" \
"  pve|data|100.00|4.10|141733920768"
  # An inactive pool prints its row with the two percentages empty. Reporting
  # it as 0 % would be a pool nobody can read looking like an empty one.
  check "an inactive pool is dropped, not zeroed" \
    "large_data large_data 11.42 0.87 940573786112;" \
"  pve|data|||141733920768
  large_data|large_data|11.42|0.87|940573786112"
  check "a comma decimal is refused, not misread" "" \
"  pve|data|22,76|1,50|141733920768"
  check "no thin pools yields nothing" "" ""
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v lvs >/dev/null 2>&1 \
  || die "no lvs on this host — it has no LVM to report on."

# A FAILED lvs AND A HOST WITH NO THIN POOLS MUST NOT LOOK THE SAME. The first is
# a collector that cannot see; the second is a legitimate answer. So a non-zero
# exit is fatal and writes nothing — the old .prom ages out and
# ThinPoolStateStopped says so — and only a clean run may report zero pools.
lvs_raw="$(LC_ALL=C lvs "${LVS_ARGS[@]}" 2>"${STDERR_FILE}")"
lvs_rc=$?
if ((lvs_rc != 0)); then
  detail="$(tr -d '\r' < "${STDERR_FILE}" | grep -v '^$' | tail -2 | paste -sd'; ' -)"
  die "lvs failed (exit ${lvs_rc})${detail:+ — ${detail}}
Pool usage cannot be read, which is NOT the same as this host having no pools."
fi

rows="$(printf '%s\n' "$lvs_raw" | parse_lvs)"

emit() {
  printf '# HELP homelab_thin_pool_data_percent Data space used in this LVM-thin pool, 0-100.\n'
  printf '# TYPE homelab_thin_pool_data_percent gauge\n'
  printf '# HELP homelab_thin_pool_metadata_percent Metadata space used in this LVM-thin pool, 0-100.\n'
  printf '# TYPE homelab_thin_pool_metadata_percent gauge\n'
  printf '# HELP homelab_thin_pool_size_bytes Size of this LVM-thin pool.\n'
  printf '# TYPE homelab_thin_pool_size_bytes gauge\n'
  if [[ -n "$rows" ]]; then
    while read -r vg pool data meta size; do
      [[ -n "$vg" ]] || continue
      labels="host=\"${HOSTNAME_LABEL}\",vg=\"${vg}\",pool=\"${pool}\""
      printf 'homelab_thin_pool_data_percent{%s} %s\n' "$labels" "$data"
      printf 'homelab_thin_pool_metadata_percent{%s} %s\n' "$labels" "$meta"
      printf 'homelab_thin_pool_size_bytes{%s} %s\n' "$labels" "$size"
    done <<<"$rows"
  fi
  # Emitted either way, so absence means the collector stopped rather than that
  # the host has no pools — the series ThinPoolStateStopped watches.
  printf '# HELP homelab_thin_pools_total LVM-thin pools this host reports with readable usage.\n'
  printf '# TYPE homelab_thin_pools_total gauge\n'
  printf 'homelab_thin_pools_total{host="%s"} %s\n' \
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
