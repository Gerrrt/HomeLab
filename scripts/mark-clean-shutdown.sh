#!/usr/bin/env bash
#
# Count a host's clean stops, as a metric, so a drive that counts every
# power-off can still tell a planned one from a cut (#746).
#
# WHY THIS EXISTS. SmartDriveUnsafeShutdownsGrowing was written on the premise
# that a clean shutdown does not move a drive's unsafe-shutdown counter (#574,
# ADR-0049). smaug's boot SSD, an Intel DC S3520, disproved it on 2026-09-29:
# 522 before a clean TrueNAS *System → Shut Down*, 523 after. One clean stop,
# plus one. The rule could not tell maintenance from a power cut, which is the
# one distinction it exists to make.
#
# WHAT IT DOES. Runs as a TrueNAS SHUTDOWN init script, so it runs on every
# stop that goes through the init system: the UI's Shut Down and Restart, and
# the UPS service's halt on LB (ADR-0049), which is a `shutdown` like any other.
# A pulled plug, a crash, or a mains cut that outlasts the pack never runs it.
# It adds one to homelab_clean_shutdowns_total and stamps the time, and the
# rule subtracts the day's clean stops from the day's unsafe ones. What is left
# is a stop nobody planned.
#
# A FACT IN A FILE, NOT A SILENCE. #572 / ADR-0046 argued that a silence is the
# wrong place to record a fact: it matches labels, not values, it expires, and
# it lives outside git. Telling Alertmanager "this reboot was planned" would be
# that again, and would depend on somebody remembering. The host records it
# itself, on the way down, every time.
#
# THE COUNT LIVES IN THE FILE IT IS SERVED FROM. There is no other state: the
# previous value is read back out of the .prom, so the file on the pool is the
# whole of it. A missing or unreadable file starts again at one, which reads to
# the rule as at most one forgiven unsafe shutdown — the failure leans quiet by
# one, never loud.
#
# FAST, BECAUSE IT IS ON THE WAY DOWN. TrueNAS gives a SHUTDOWN script a timeout
# (10s is what build-the-nas.md §6.4 sets) and the pool is still imported when
# it runs. Temp file, mv, sync: the same atomic write collect-smart-state.sh
# uses, plus the sync, because the next thing that happens is the power going.
#
# The command line TrueNAS runs is
#
#   TEXTFILE_DIR=/mnt/erebor/apps/textfile \
#   /bin/bash /mnt/erebor/apps/stack/mark-clean-shutdown.sh --host smaug
#
# `--host` because the label has to match the `host` collect-smart-state.sh
# writes; the rule joins on it.
#
# Usage: scripts/mark-clean-shutdown.sh --host NAME
#        scripts/mark-clean-shutdown.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
HOST_LABEL=""
SELF_TEST=0

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --host) HOST_LABEL="${2:-}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# The previous count, read back out of the file. Anything that is not a plain
# non-negative integer on the expected line is treated as no count at all.
previous() {
  local file="$1" host="$2" v
  [[ -r "$file" ]] || { echo 0; return; }
  v="$(awk -v want="homelab_clean_shutdowns_total{host=\"${host}\"}" \
    '$1 == want { print $2; exit }' "$file" 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

render() {
  local host="$1" count="$2" now="$3"
  cat <<EOF
# HELP homelab_clean_shutdowns_total Stops of this host that ran its SHUTDOWN init script (#746).
# TYPE homelab_clean_shutdowns_total counter
homelab_clean_shutdowns_total{host="${host}"} ${count}
# HELP homelab_clean_shutdown_timestamp_seconds When the last clean stop began.
# TYPE homelab_clean_shutdown_timestamp_seconds gauge
homelab_clean_shutdown_timestamp_seconds{host="${host}"} ${now}
EOF
}

mark() {
  local dir="$1" host="$2" now="$3" prom tmp count
  prom="${dir}/clean-shutdowns-${host}.prom"
  count=$(( $(previous "$prom" "$host") + 1 ))
  tmp="${prom}.$$"
  render "$host" "$count" "$now" > "$tmp" || { rm -f "$tmp"; die "could not write ${tmp}"; }
  chmod 0644 "$tmp"
  mv -f "$tmp" "$prom"
  sync "$prom" 2>/dev/null || sync
}

if ((SELF_TEST)); then
  fail=0
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  file="${dir}/clean-shutdowns-fixture.prom"

  check() {
    local name="$1" expect="$2" pattern="$3" got
    got="$(grep -cE -- "$pattern" "$file" 2>/dev/null)"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s -> %s line(s) matching %s, expected %s\n' \
        "$name" "$got" "$pattern" "$expect"
      fail=1
    fi
  }

  # 1. The first clean stop after install: no file yet, so the count is one.
  mark "$dir" fixture 1790000000
  check "first stop on a missing file counts one" \
    1 '^homelab_clean_shutdowns_total\{host="fixture"\} 1$'
  check "first stop is stamped" \
    1 '^homelab_clean_shutdown_timestamp_seconds\{host="fixture"\} 1790000000$'

  # 2. The second reads the first back and adds one, and the stamp moves.
  mark "$dir" fixture 1790003600
  check "second stop increments" \
    1 '^homelab_clean_shutdowns_total\{host="fixture"\} 2$'
  check "the stamp is the latest stop, not the first" \
    1 '^homelab_clean_shutdown_timestamp_seconds\{host="fixture"\} 1790003600$'
  check "exactly one series per metric, never appended" \
    2 '^homelab_clean_shutdown'

  # 3. A corrupt file starts again at one rather than failing the shutdown.
  printf 'homelab_clean_shutdowns_total{host="fixture"} banana\n' > "$file"
  mark "$dir" fixture 1790007200
  check "a garbled count restarts at one" \
    1 '^homelab_clean_shutdowns_total\{host="fixture"\} 1$'

  # 4. A count written for a different host is not this host's count.
  printf 'homelab_clean_shutdowns_total{host="other"} 40\n' > "$file"
  mark "$dir" fixture 1790010800
  check "another host's count is not read" \
    1 '^homelab_clean_shutdowns_total\{host="fixture"\} 1$'

  # 5. No temp file left behind for the textfile collector to choke on.
  if compgen -G "${file}.*" >/dev/null; then
    printf '\033[0;31m  FAIL\033[0m a temp file was left in the textfile directory\n'
    fail=1
  else
    printf '\033[0;32m  PASS\033[0m no temp file left behind\n'
  fi

  exit "$fail"
fi

[[ -n "$HOST_LABEL" ]] || die "--host NAME is required: the rule joins on it"
[[ -d "$TEXTFILE_DIR" ]] || die "no ${TEXTFILE_DIR}"

mark "$TEXTFILE_DIR" "$HOST_LABEL" "$(date +%s)"
printf 'clean-shutdown host=%s count=%s\n' "$HOST_LABEL" \
  "$(previous "${TEXTFILE_DIR}/clean-shutdowns-${HOST_LABEL}.prom" "$HOST_LABEL")"
