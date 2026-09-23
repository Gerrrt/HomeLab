#!/usr/bin/env bash
#
# How full the hypervisor's LVM-thin pools are (#538).
#
# THE GAP. `Saruman` has two thin pools: `pve/data` on the HDD mirror and
# `large_data/large_data` on the SSD logical drive made on 2026-09-19 (#527),
# which carries `alexander`. A thin pool is not a filesystem, so node_exporter's
# `node_filesystem_*` never sees one — the host reports `/`, `/boot/efi` and
# `/etc/pve` and nothing else. HostDiskCritical and HostDiskWillFillIn24h are
# therefore structurally blind to the pools, and a thin pool that fills makes
# every guest on it read-only at once. `fit-the-saruman-ssds.md` §7 recorded the
# gap on the day the second pool was made; this is what closes it.
#
# METADATA AS WELL AS DATA, and metadata is the worse of the two. A pool whose
# data fills stops writes; a pool whose metadata fills can leave the pool itself
# needing `lvconvert --repair`. It is also the one nobody watches, because `pvesm
# status` and the Proxmox UI both show data usage only.
#
# ROOT IS NEEDED FOR THE READING, unlike the guest-state collector beside it:
# `lvs` opens the block devices. The agent collectors already run as root for
# the textfile directory, so nothing new is granted.
#
# Usage: scripts/collect-thin-pools.sh [--print]
#        scripts/collect-thin-pools.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/thin-pools.prom"
HOSTNAME_LABEL="$(hostname)"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

STDERR_FILE="$(mktemp)"
trap 'rm -f "${STDERR_FILE}"' EXIT

# The columns asked for, in order. `--separator '|'` rather than whitespace, so
# an empty field — the percentages of an inactive pool — stays an empty field
# instead of shifting every column after it. `--units b --nosuffix` so sizes are
# plain bytes rather than "876.00g".
LVS_FIELDS=vg_name,lv_name,lv_attr,data_percent,metadata_percent,lv_size,lv_metadata_size

# Rows out: `vg pool active data_percent metadata_percent size_bytes
# metadata_size_bytes`, one per thin pool, with `-` for a percentage the pool
# did not report.
#
# THE POOL IS CHOSEN HERE, NOT BY `lvs --select`. A thin pool's lv_attr starts
# with `t`; a thin volume's starts with `V`, and a thin pool's hidden `_tdata`
# and `_tmeta` sub-volumes are not listed without `-a`. Filtering in the parser
# rather than in the command is what lets a fixture below prove that a guest's
# disk is never mistaken for a pool.
#
# An INACTIVE pool reports empty percentages. It is still a pool, so it is kept
# and reported as inactive rather than dropped — a pool that vanished from the
# output would look exactly like a pool that is fine.
parse_lvs() {
  awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      vg = trim($1); lv = trim($2); attr = trim($3)
      if (vg == "" || lv == "" || attr !~ /^t/) next
      d = trim($4); m = trim($5); size = trim($6); msize = trim($7)
      num = "^[0-9]+([.][0-9]+)?$"
      active = (d ~ num && m ~ num) ? 1 : 0
      if (d !~ num) d = "-"
      if (m !~ num) m = "-"
      if (size !~ /^[0-9]+$/) size = "-"
      if (msize !~ /^[0-9]+$/) msize = "-"
      printf "%s %s %s %s %s %s %s\n", vg, lv, active, d, m, size, msize
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
  # Both of Saruman's pools, in the shape `lvs --noheadings --separator '|'`
  # prints: leading spaces, no header, one row per LV. The thin volume and the
  # plain root LV beside them must not be read as pools.
  check "both pools, and only the pools" \
"pve data 1 22.76 1.52 1846425190400 1073741824;large_data large_data 1 11.42 0.88 940597231616 104857600;" \
"  pve|data|twi-aotz--|22.76|1.52|1846425190400|1073741824
  pve|root|-wi-ao----|||107374182400|
  pve|swap|-wi-ao----|||8589934592|
  large_data|large_data|twi-aotz--|11.42|0.88|940597231616|104857600
  large_data|vm-140-disk-0|Vwi-aotz--|48.10||107374182400|"
  # A guest disk carries a data_percent of its own. Reading it as a pool would
  # report a 100 GiB volume's fill as though it were the pool's.
  check "a thin volume is not a pool" "" \
"  large_data|vm-140-disk-0|Vwi-aotz--|48.10||107374182400|"
  # An inactive pool has no percentages. Kept, and marked inactive.
  check "an inactive pool is kept, not dropped" \
"pve data 0 - - 1846425190400 1073741824;" \
"  pve|data|twi---tz--|||1846425190400|1073741824"
  check "a full pool reads 100.00" \
"pve data 1 100.00 12.50 1846425190400 1073741824;" \
"  pve|data|twi-aotzF-|100.00|12.50|1846425190400|1073741824"
  check "no LVM at all yields nothing" "" ""
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v lvs >/dev/null 2>&1 \
  || die "no lvs on this host — LVM is not installed, so there are no thin pools to read."

# NO POOLS AND A BROKEN `lvs` MUST NOT LOOK THE SAME, for the reason
# collect-guest-state.sh learned on its first run: a collector that reports zero
# after a failure is the silence it exists to break. `lvs` exits non-zero when it
# cannot read, and then nothing is written — the old file stays, its timestamp
# stops moving, and ThinPoolStateStopped says so.
#
# LC_ALL=C so a percentage is never printed with a decimal comma.
raw="$(LC_ALL=C lvs --noheadings --separator '|' --units b --nosuffix \
        -o "${LVS_FIELDS}" 2>"${STDERR_FILE}")"
rc=$?
if ((rc != 0)); then
  detail="$(grep -v '^$' "${STDERR_FILE}" | tail -2 | paste -sd'; ' -)"
  die "lvs failed (exit ${rc})${detail:+ — ${detail}}
Pool usage cannot be read, which is NOT the same as this host having no pools."
fi

rows="$(printf '%s\n' "$raw" | parse_lvs)"

emit() {
  printf '# HELP homelab_thin_pool_active 1 when the LVM-thin pool is active and reporting usage.\n'
  printf '# TYPE homelab_thin_pool_active gauge\n'
  printf '# HELP homelab_thin_pool_data_percent Percent of the thin pool data volume allocated.\n'
  printf '# TYPE homelab_thin_pool_data_percent gauge\n'
  printf '# HELP homelab_thin_pool_metadata_percent Percent of the thin pool metadata volume allocated.\n'
  printf '# TYPE homelab_thin_pool_metadata_percent gauge\n'
  printf '# HELP homelab_thin_pool_size_bytes Size of the thin pool data volume.\n'
  printf '# TYPE homelab_thin_pool_size_bytes gauge\n'
  printf '# HELP homelab_thin_pool_metadata_size_bytes Size of the thin pool metadata volume.\n'
  printf '# TYPE homelab_thin_pool_metadata_size_bytes gauge\n'
  if [[ -n "$rows" ]]; then
    local vg pool active d m size msize l
    while read -r vg pool active d m size msize; do
      [[ -n "$vg" ]] || continue
      l="host=\"${HOSTNAME_LABEL}\",vg=\"${vg}\",pool=\"${pool}\""
      printf 'homelab_thin_pool_active{%s} %s\n' "$l" "$active"
      [[ "$d" != - ]] && printf 'homelab_thin_pool_data_percent{%s} %s\n' "$l" "$d"
      [[ "$m" != - ]] && printf 'homelab_thin_pool_metadata_percent{%s} %s\n' "$l" "$m"
      [[ "$size" != - ]] && printf 'homelab_thin_pool_size_bytes{%s} %s\n' "$l" "$size"
      [[ "$msize" != - ]] && printf 'homelab_thin_pool_metadata_size_bytes{%s} %s\n' "$l" "$msize"
    done <<<"$rows"
  fi
  printf '# HELP homelab_thin_pools_total LVM-thin pools on this host, active or not.\n'
  printf '# TYPE homelab_thin_pools_total gauge\n'
  printf 'homelab_thin_pools_total{host="%s"} %s\n' \
    "$HOSTNAME_LABEL" "$(printf '%s\n' "$rows" | grep -c . || true)"
  # A TIMESTAMP, not presence, is what the staleness rule reads. The .prom file
  # persists and node_exporter re-serves it on every scrape, so a timer that
  # stops leaves every series above present and frozen — DriftCheckStopped's
  # lesson. Only this moving says the reading is current.
  printf '# HELP homelab_thin_pools_last_run_timestamp_seconds When this collector last read the pools.\n'
  printf '# TYPE homelab_thin_pools_last_run_timestamp_seconds gauge\n'
  printf 'homelab_thin_pools_last_run_timestamp_seconds{host="%s"} %s\n' \
    "$HOSTNAME_LABEL" "$(date +%s)"
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'thin-pools host=%s pools=%s%s\n' "$HOSTNAME_LABEL" \
  "$(printf '%s\n' "$rows" | grep -c . || true)" \
  "$(printf '%s\n' "$rows" | awk 'NF { printf " %s/%s=%s%%,meta=%s%%", $1, $2, $4, $5 }')"
