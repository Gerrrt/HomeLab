#!/usr/bin/env bash
# Power gandalf off at a deadline, so the range is never left running
# (ADR-0124, #1647).
#
# Usage:
#   homelab-range-poweroff check     what the timer runs: warn, or power off
#   homelab-range-poweroff status    print the deadline and the time left
#   homelab-range-poweroff extend H  set the deadline H hours from now (1-12)
#   range-extend H                   the same as `extend H` (a symlink to this)
#   scripts/range-poweroff.sh --self-test
#
# THE DEADLINE is six hours after boot, or the time the last `extend` set.
# It lives under /run, which a boot clears, so every boot starts the six
# hours again and an extension never outlives the session that asked for
# it. One extension is capped at twelve hours, so a typo or a "just leave
# it" cannot quietly switch the backstop off.
#
# THE WARNINGS go to every shell through `wall`: once at 30 minutes or
# less, once at 5 or less. The timer runs this every five minutes, so
# exactly one run falls inside the last five. A warning is recorded
# against the deadline it was for, so an extension re-arms both without
# clearing anything.
#
# IT NEVER POWERS OFF IN THE MIDDLE OF A PACKAGE INSTALL. While something
# holds dpkg's lock, a run past the deadline logs that it is waiting and
# exits. The next run checks again. Cutting dpkg off half way leaves a
# hypervisor that may not boot, which is worse than a range left on for
# five more minutes.
#
# THE POWER-OFF is the ordinary `systemctl poweroff`. pve-guests.service's
# ExecStop runs Proxmox's stopall, which shuts every guest down and forces
# any that ignore ACPI, as Mr-Robot does. Reverting the targets to `clean`
# is build-the-playground.md §7's first step at the next power-on.
set -euo pipefail

HOURS=6
MAX_EXTEND=12
STATE_DIR="${RANGE_STATE_DIR:-/run/homelab-range-poweroff}"

# Each of these is replaced by the self-test, which is the only reason they
# are functions.
now() { date +%s; }
boot_time() { awk '/^btime /{print $2}' /proc/stat; }
dpkg_busy() { fuser -s /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null; }
say() { logger -t homelab-range-poweroff -- "$*" 2>/dev/null || true; printf '%s\n' "$*"; }
warn_all() { wall -- "$*" 2>/dev/null || true; }
power_off() { systemctl poweroff; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

read_state() {
  # One integer per file. Anything else reads as absent.
  local f="${STATE_DIR}/$1" v=""
  [[ -f "${f}" ]] && v="$(head -c 32 "${f}" 2>/dev/null | tr -d '[:space:]')"
  is_uint "${v}" && printf '%s' "${v}"
  return 0
}

write_state() {
  # Write then rename, so a reader never sees half a number.
  mkdir -p "${STATE_DIR}"
  printf '%s\n' "$2" > "${STATE_DIR}/$1.tmp"
  mv -f "${STATE_DIR}/$1.tmp" "${STATE_DIR}/$1"
}

deadline() {
  local d
  d="$(read_state deadline)"
  if [[ -n "${d}" ]]; then printf '%s' "${d}"; return; fi
  printf '%s' "$(( $(boot_time) + HOURS * 3600 ))"
}

minutes_left() { printf '%s' "$(( ($1 + 59) / 60 ))"; }

fmt_time() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M'; }

cmd_check() {
  local t d left mins
  t="$(now)"
  d="$(deadline)"
  left=$(( d - t ))
  if (( left <= 0 )); then
    if dpkg_busy; then
      say "deadline $(fmt_time "${d}") has passed, but dpkg's lock is held; waiting for the next run"
      return 0
    fi
    say "deadline $(fmt_time "${d}") has passed; powering gandalf off"
    warn_all "gandalf: the range deadline has passed (ADR-0124). Powering off now."
    power_off
    return 0
  fi
  mins="$(minutes_left "${left}")"
  if (( left <= 300 )); then
    if [[ "$(read_state warned-5)" != "${d}" ]]; then
      warn_all "gandalf powers off in ${mins} min (ADR-0124). To keep it on: range-extend <hours>"
      write_state warned-5 "${d}"
      write_state warned-30 "${d}"
      say "warned: ${mins} min to the deadline"
    fi
  elif (( left <= 1800 )); then
    if [[ "$(read_state warned-30)" != "${d}" ]]; then
      warn_all "gandalf powers off in ${mins} min (ADR-0124). To keep it on: range-extend <hours>"
      write_state warned-30 "${d}"
      say "warned: ${mins} min to the deadline"
    fi
  fi
  return 0
}

cmd_extend() {
  local h="${1:-}" t d
  if ! is_uint "${h}" || (( 10#${h} < 1 || 10#${h} > MAX_EXTEND )); then
    printf 'usage: range-extend <hours>, a whole number from 1 to %d\n' "${MAX_EXTEND}" >&2
    return 2
  fi
  h=$(( 10#${h} ))
  t="$(now)"
  d=$(( t + h * 3600 ))
  write_state deadline "${d}"
  say "deadline set to $(fmt_time "${d}"), ${h} h from now, by ${SUDO_USER:-${USER:-root}}"
  return 0
}

cmd_status() {
  local t d left
  t="$(now)"
  d="$(deadline)"
  left=$(( d - t ))
  if [[ -n "$(read_state deadline)" ]]; then
    printf 'deadline %s (set by range-extend)\n' "$(fmt_time "${d}")"
  else
    printf 'deadline %s (%d h after boot)\n' "$(fmt_time "${d}")" "${HOURS}"
  fi
  if (( left > 0 )); then
    printf '%d min left\n' "$(minutes_left "${left}")"
  else
    printf 'passed %d min ago; the next run powers off unless dpkg is busy\n' "$(( -left / 60 ))"
  fi
  return 0
}

self_test() {
  local passed=0 failed=0 tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  STATE_DIR="${tmp}/state"

  # Fakes. BOOT is fixed; NOW, BUSY and the logs are set per fixture.
  local BOOT=1800000000 NOW=0 BUSY=1 WALL_LOG="${tmp}/wall" OFF_LOG="${tmp}/off"
  now() { printf '%s' "${NOW}"; }
  boot_time() { printf '%s' "${BOOT}"; }
  dpkg_busy() { return "${BUSY}"; }
  say() { :; }
  warn_all() { printf '%s\n' "$*" >> "${WALL_LOG}"; }
  power_off() { printf 'off\n' >> "${OFF_LOG}"; }

  reset() { rm -rf "${STATE_DIR}" "${WALL_LOG}" "${OFF_LOG}"; BUSY=1; }
  walls() { [[ -f "${WALL_LOG}" ]] && wc -l < "${WALL_LOG}" | tr -d ' ' || printf 0; }
  offs() { [[ -f "${OFF_LOG}" ]] && wc -l < "${OFF_LOG}" | tr -d ' ' || printf 0; }
  check() {
    local name="$1" got="$2" expect="$3"
    if [[ "${got}" == "${expect}" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "${name}"; passed=$((passed + 1))
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "${name}" "${got}" "${expect}"
      failed=$((failed + 1))
    fi
  }

  local H=3600
  reset; NOW=$((BOOT + 60)); cmd_check
  check "a fresh boot neither warns nor powers off" "$(walls)/$(offs)" "0/0"

  reset; NOW=$((BOOT + 6 * H - 1700)); cmd_check; cmd_check
  check "under 30 min warns once, not on every run" "$(walls)/$(offs)" "1/0"

  reset; NOW=$((BOOT + 6 * H - 1700)); cmd_check; NOW=$((BOOT + 6 * H - 200)); cmd_check; cmd_check
  check "under 5 min warns a second time, once" "$(walls)/$(offs)" "2/0"

  reset; NOW=$((BOOT + 6 * H - 200)); cmd_check; NOW=$((BOOT + 6 * H - 100)); cmd_check
  check "a first run inside 5 min sends one warning, not two" "$(walls)/$(offs)" "1/0"

  reset; NOW=$((BOOT + 6 * H)); cmd_check
  check "at the deadline it powers off" "$(offs)" "1"

  reset; NOW=$((BOOT + 6 * H + 10)); BUSY=0; cmd_check
  check "past the deadline with dpkg busy it waits" "$(offs)" "0"
  BUSY=1; cmd_check
  check "and powers off on the next run once dpkg is done" "$(offs)" "1"

  reset; NOW=$((BOOT + 5 * H)); cmd_extend 3 >/dev/null; NOW=$((BOOT + 6 * H + 60)); cmd_check
  check "an extension moves the deadline past six hours" "$(offs)" "0"
  NOW=$((BOOT + 8 * H)); cmd_check
  check "and the extended deadline is enforced" "$(offs)" "1"

  reset; NOW=$((BOOT + 6 * H - 1700)); cmd_check; cmd_extend 1 >/dev/null; NOW=$((NOW + H - 1700)); cmd_check
  check "an extension re-arms the 30-minute warning" "$(walls)" "2"

  reset; NOW=$((BOOT + H))
  check "extend refuses 0" "$(cmd_extend 0 2>/dev/null; printf '%s' "$?")" "2"
  check "extend refuses 13 (the cap is 12)" "$(cmd_extend 13 2>/dev/null; printf '%s' "$?")" "2"
  check "extend refuses a non-number" "$(cmd_extend 2h 2>/dev/null; printf '%s' "$?")" "2"
  check "extend refuses nothing at all" "$(cmd_extend 2>/dev/null; printf '%s' "$?")" "2"
  check "a refused extend leaves no deadline behind" "$(read_state deadline)" ""
  check "extend accepts 12" "$(cmd_extend 12 >/dev/null; read_state deadline)" "$((NOW + 12 * H))"
  check "extend reads 08 as eight, not as octal" "$(cmd_extend 08 >/dev/null; read_state deadline)" "$((NOW + 8 * H))"

  reset; mkdir -p "${STATE_DIR}"; printf 'garbage\n' > "${STATE_DIR}/deadline"
  check "an unreadable deadline file falls back to six hours after boot" "$(deadline)" "$((BOOT + 6 * H))"

  ((failed == 0))
}

case "$(basename "$0")" in
  range-extend) cmd_extend "$@"; exit $? ;;
esac

case "${1:-}" in
  --self-test) self_test ;;
  check) cmd_check ;;
  status) cmd_status ;;
  extend) shift; cmd_extend "$@" ;;
  *) printf 'usage: %s check|status|extend <hours>|--self-test\n' "$0" >&2; exit 2 ;;
esac
