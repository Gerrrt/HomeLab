#!/usr/bin/env bash
# Stop the attack VM, ragnarok, at a deadline, so it is never left running
# on VLAN 30 (ADR-0125, which supersedes ADR-0124; #1647). gandalf itself
# stays on.
#
# Usage:
#   homelab-ragnarok-stop check     what the timer runs: warn, or stop ragnarok
#   homelab-ragnarok-stop status    print the deadline and the time left
#   homelab-ragnarok-stop extend H  set the deadline H hours from now (1-12)
#   range-extend H                  the same as `extend H` (a symlink to this)
#   scripts/ragnarok-stop.sh --self-test
#
# THE DEADLINE is six hours after ragnarok started, or the time the last
# `extend` set. An extension belongs to one run of the VM: it is stored with
# the QEMU process's PID, and a deadline stored for another PID is ignored.
# So a stop and a start always begin again from six hours, even when both
# fall between two runs of the timer. While ragnarok is stopped, `check`
# clears the state and does nothing else. One extension is capped at twelve
# hours, so a typo or a "just leave it" cannot quietly switch the backstop
# off.
#
# THE WARNINGS go through `wall` to every shell on gandalf and, through the
# guest agent, to every shell inside ragnarok, where the session is: once
# at 30 minutes or less, once at 5 or less. The timer runs this every
# minute, well inside the five-minute window, so a late run cannot skip the
# last warning. A warning is recorded against the deadline it was for, so
# an extension re-arms both without clearing anything.
#
# ONE LOCK. `check` and `extend` each hold an flock on the state
# directory's lock file for the whole operation, the stop included. Without
# it, a check that had read the old deadline could stop the VM after
# `range-extend` reported success (review on #1649).
#
# IT NEVER STOPS RAGNAROK IN THE MIDDLE OF A PACKAGE INSTALL. Past the
# deadline, it asks the guest agent whether anything holds dpkg's lock
# inside the VM. If something does, it logs that it is waiting and exits,
# and the next run asks again. An agent that does not answer counts as not
# busy, so a hung agent cannot keep the VM up.
#
# THE STOP is `qm shutdown` with a three-minute timeout and --forceStop, so
# an ACPI shutdown gets its chance and a guest that ignores it is stopped
# anyway. Just before it, the run reads the PID again. The guest-agent calls
# before it can take seconds, and a VM stopped and started in that time is a
# new run that this run's deadline does not cover, so it is left alone
# (review on #1652). `qm` takes no PID, so a restart in the instant between
# that read and the shutdown is the window left, and it is milliseconds.
#
# THE START TIME is the QEMU process's own, from /proc/<pid>/stat: boot time
# plus the process's start in clock ticks. It is the same on every run, so
# the default deadline is too, and a warning is never sent twice for it.
# `now` minus `ps -o etimes` would sample two clocks and could move by a
# second between runs (review on #1652).
set -euo pipefail

VMID="${RAGNAROK_VMID:-130}"
HOURS=6
MAX_EXTEND=12
STATE_DIR="${RANGE_STATE_DIR:-/run/homelab-ragnarok-stop}"

# Each of these is replaced by the self-test, which is the only reason they
# are functions.
now() { date +%s; }
vm_pid() {
  # The running QEMU process's PID, or nothing when the VM is stopped.
  local p=""
  p="$(head -c 16 "/var/run/qemu-server/${VMID}.pid" 2>/dev/null | tr -d '[:space:]')" || true
  if is_uint "${p}" && [[ -d "/proc/${p}" ]]; then printf '%s' "${p}"; fi
  return 0
}
vm_start() {
  # Seconds since the epoch at which process $1 started. Field 22 of
  # /proc/<pid>/stat, counted after the ") " that ends the command name,
  # which may itself hold spaces.
  local ticks btime hz
  ticks="$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}')"
  btime="$(awk '/^btime /{print $2}' /proc/stat)"
  hz="$(getconf CLK_TCK)"
  is_uint "${ticks}" && is_uint "${btime}" && is_uint "${hz}" && printf '%s' "$(( btime + ticks / hz ))"
  return 0
}
guest_dpkg_busy() {
  # True only if the agent answers and fuser finds a holder (exit 0).
  qm guest exec "${VMID}" --timeout 15 -- fuser -s /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null \
    | grep -qE '"exitcode"[[:space:]]*:[[:space:]]*0[^0-9]'
}
take_lock() { flock -w 30 9; }
say() {
  # Under systemd, stdout already goes to the journal under this unit's
  # SyslogIdentifier, so logger as well would record every line twice.
  # From a shell (range-extend), logger is what puts it in the journal.
  [[ -n "${INVOCATION_ID:-}" ]] || logger -t homelab-ragnarok-stop -- "$*" 2>/dev/null || true
  printf '%s\n' "$*"
}
warn_all() {
  wall -- "$*" 2>/dev/null || true
  qm guest exec "${VMID}" --timeout 15 -- wall -- "$*" >/dev/null 2>&1 || true
}
stop_vm() { qm shutdown "${VMID}" --timeout 180 --forceStop 1; }

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
  # The temporary name is unique, so two writers never share one.
  local tmp
  mkdir -p "${STATE_DIR}"
  tmp="$(mktemp "${STATE_DIR}/.$1.XXXXXX")"
  printf '%s\n' "$2" > "${tmp}"
  mv -f "${tmp}" "${STATE_DIR}/$1"
}

clear_state() { rm -f "${STATE_DIR}/deadline" "${STATE_DIR}/run" "${STATE_DIR}/warned-30" "${STATE_DIR}/warned-5"; }

with_lock() {
  # Run "$@" holding the lock. fd 9 closes when the group ends, which
  # releases it, so nothing outlives the operation.
  mkdir -p "${STATE_DIR}"
  {
    take_lock || { say "could not take ${STATE_DIR}/lock in 30 s"; return 1; }
    "$@"
  } 9>"${STATE_DIR}/lock"
}

extended() {
  # The stored deadline, if it was set for this run of the VM ($1 is the PID).
  local d
  d="$(read_state deadline)"
  if [[ -n "${d}" && "$(read_state run)" == "$1" ]]; then printf '%s' "${d}"; fi
  return 0
}

deadline() {
  # $1 is the PID of the running VM.
  local d st
  d="$(extended "$1")"
  if [[ -n "${d}" ]]; then printf '%s' "${d}"; return; fi
  st="$(vm_start "$1")"
  is_uint "${st}" || st="$(now)"
  printf '%s' "$(( st + HOURS * 3600 ))"
}

minutes_left() { printf '%s' "$(( ($1 + 59) / 60 ))"; }

fmt_time() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M'; }

cmd_check() { with_lock check_locked; }

check_locked() {
  local pid t d left mins
  pid="$(vm_pid)"
  if [[ -z "${pid}" ]]; then
    clear_state
    return 0
  fi
  t="$(now)"
  d="$(deadline "${pid}")"
  left=$(( d - t ))
  if (( left <= 0 )); then
    if guest_dpkg_busy; then
      say "deadline $(fmt_time "${d}") has passed, but dpkg's lock is held inside ragnarok; waiting for the next run"
      return 0
    fi
    say "deadline $(fmt_time "${d}") has passed; stopping ragnarok"
    warn_all "ragnarok: the deadline has passed (ADR-0125). Shutting down now."
    if [[ "$(vm_pid)" != "${pid}" ]]; then
      say "ragnarok stopped or restarted during this check; leaving the new run to its own deadline"
      return 0
    fi
    stop_vm
    clear_state
    return 0
  fi
  mins="$(minutes_left "${left}")"
  if (( left <= 300 )); then
    if [[ "$(read_state warned-5)" != "${d}" ]]; then
      warn_all "ragnarok shuts down in ${mins} min (ADR-0125). To keep it running, on gandalf: range-extend <hours>"
      write_state warned-5 "${d}"
      write_state warned-30 "${d}"
      say "warned: ${mins} min to the deadline"
    fi
  elif (( left <= 1800 )); then
    if [[ "$(read_state warned-30)" != "${d}" ]]; then
      warn_all "ragnarok shuts down in ${mins} min (ADR-0125). To keep it running, on gandalf: range-extend <hours>"
      write_state warned-30 "${d}"
      say "warned: ${mins} min to the deadline"
    fi
  fi
  return 0
}

cmd_extend() {
  local h="${1:-}"
  if ! is_uint "${h}" || (( 10#${h} < 1 || 10#${h} > MAX_EXTEND )); then
    printf 'usage: range-extend <hours>, a whole number from 1 to %d\n' "${MAX_EXTEND}" >&2
    return 2
  fi
  with_lock extend_locked "$(( 10#${h} ))"
}

extend_locked() {
  local h="$1" pid t d
  pid="$(vm_pid)"
  if [[ -z "${pid}" ]]; then
    printf 'ragnarok (VM %s) is not running, so there is no deadline to extend\n' "${VMID}" >&2
    return 1
  fi
  t="$(now)"
  d=$(( t + h * 3600 ))
  write_state run "${pid}"
  write_state deadline "${d}"
  say "deadline set to $(fmt_time "${d}"), ${h} h from now, by ${SUDO_USER:-${USER:-root}}"
  return 0
}

cmd_status() {
  local pid t d left
  pid="$(vm_pid)"
  if [[ -z "${pid}" ]]; then
    printf 'ragnarok (VM %s) is not running; nothing to stop\n' "${VMID}"
    return 0
  fi
  t="$(now)"
  d="$(deadline "${pid}")"
  left=$(( d - t ))
  if [[ -n "$(extended "${pid}")" ]]; then
    printf 'deadline %s (set by range-extend)\n' "$(fmt_time "${d}")"
  else
    printf 'deadline %s (%d h after ragnarok started)\n' "$(fmt_time "${d}")" "${HOURS}"
  fi
  if (( left > 0 )); then
    printf '%d min left\n' "$(minutes_left "${left}")"
  else
    printf 'passed %d min ago; the next run stops ragnarok unless dpkg is busy inside it\n' "$(( -left / 60 ))"
  fi
  return 0
}

# Machine-readable state for collect-range-state.sh (#1651, ADR-0126), so the
# effective deadline a monitor alerts on comes from one place — here — rather
# than a second copy of this script's run-identity and six-hour-default logic.
# One key=value per line. A stopped VM prints `running=0` and no deadline.
cmd_deadline_epoch() {
  local pid
  pid="$(vm_pid)"
  if [[ -z "${pid}" ]]; then
    printf 'running=0\n'
    return 0
  fi
  printf 'running=1\n'
  printf 'deadline_epoch=%s\n' "$(deadline "${pid}")"
  if [[ -n "$(extended "${pid}")" ]]; then
    printf 'source=extended\n'
  else
    printf 'source=default\n'
  fi
  return 0
}

self_test() {
  local passed=0 failed=0 tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  STATE_DIR="${tmp}/state"

  # Fakes. START is when the VM started; NOW, PID, BUSY and the logs are
  # set per fixture. An empty PID is a stopped VM.
  local START=1800000000 NOW=0 PID=4242 BUSY=1 WALL_LOG="${tmp}/wall" STOP_LOG="${tmp}/stop"
  now() { printf '%s' "${NOW}"; }
  vm_pid() { printf '%s' "${PID}"; }
  vm_start() { printf '%s' "${START}"; }
  # RESTART, when set, is the PID the VM comes back with while the check is
  # asking the guest agent about dpkg: a stop and a start mid-check.
  local RESTART=""
  guest_dpkg_busy() { if [[ -n "${RESTART}" ]]; then PID="${RESTART}"; fi; return "${BUSY}"; }
  say() { :; }
  warn_all() { printf '%s\n' "$*" >> "${WALL_LOG}"; }
  stop_vm() { printf 'stop\n' >> "${STOP_LOG}"; }
  local HAVE_FLOCK=1
  if ! command -v flock >/dev/null 2>&1; then
    HAVE_FLOCK=0
    take_lock() { :; }
  fi

  reset() { rm -rf "${STATE_DIR}" "${WALL_LOG}" "${STOP_LOG}"; BUSY=1; PID=4242; START=1800000000; RESTART=""; }
  walls() { [[ -f "${WALL_LOG}" ]] && wc -l < "${WALL_LOG}" | tr -d ' ' || printf 0; }
  stops() { [[ -f "${STOP_LOG}" ]] && wc -l < "${STOP_LOG}" | tr -d ' ' || printf 0; }
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
  reset; NOW=$((START + 60)); cmd_check
  check "a fresh start neither warns nor stops" "$(walls)/$(stops)" "0/0"

  reset; NOW=$((START + 6 * H - 1700)); cmd_check; cmd_check
  check "under 30 min warns once, not on every run" "$(walls)/$(stops)" "1/0"

  reset; NOW=$((START + 6 * H - 1700)); cmd_check; NOW=$((START + 6 * H - 200)); cmd_check; cmd_check
  check "under 5 min warns a second time, once" "$(walls)/$(stops)" "2/0"

  reset; NOW=$((START + 6 * H - 200)); cmd_check; NOW=$((START + 6 * H - 100)); cmd_check
  check "a first run inside 5 min sends one warning, not two" "$(walls)/$(stops)" "1/0"

  reset; NOW=$((START + 6 * H)); cmd_check
  check "at the deadline it stops ragnarok" "$(stops)" "1"

  reset; NOW=$((START + 6 * H + 10)); BUSY=0; cmd_check
  check "past the deadline with dpkg busy inside the VM it waits" "$(stops)" "0"
  BUSY=1; cmd_check
  check "and stops it on the next run once dpkg is done" "$(stops)" "1"

  reset; NOW=$((START + 5 * H)); cmd_extend 3 >/dev/null; NOW=$((START + 6 * H + 60)); cmd_check
  check "an extension moves the deadline past six hours" "$(stops)" "0"
  NOW=$((START + 8 * H)); cmd_check
  check "and the extended deadline is enforced" "$(stops)" "1"

  reset; NOW=$((START + 6 * H - 1700)); cmd_check; cmd_extend 1 >/dev/null; NOW=$((NOW + H - 1700)); cmd_check
  check "an extension re-arms the 30-minute warning" "$(walls)" "2"

  reset; NOW=$((START + H))
  check "extend refuses 0" "$(cmd_extend 0 2>/dev/null; printf '%s' "$?")" "2"
  check "extend refuses 13 (the cap is 12)" "$(cmd_extend 13 2>/dev/null; printf '%s' "$?")" "2"
  check "extend refuses a non-number" "$(cmd_extend 2h 2>/dev/null; printf '%s' "$?")" "2"
  check "extend refuses nothing at all" "$(cmd_extend 2>/dev/null; printf '%s' "$?")" "2"
  check "a refused extend leaves no deadline behind" "$(read_state deadline)" ""
  check "extend accepts 12" "$(cmd_extend 12 >/dev/null; read_state deadline)" "$((NOW + 12 * H))"
  check "extend reads 08 as eight, not as octal" "$(cmd_extend 08 >/dev/null; read_state deadline)" "$((NOW + 8 * H))"

  reset; mkdir -p "${STATE_DIR}"; printf 'garbage\n' > "${STATE_DIR}/deadline"; printf '4242\n' > "${STATE_DIR}/run"; NOW=$((START + H))
  check "an unreadable deadline falls back to six hours after the start" "$(deadline 4242)" "$((START + 6 * H))"

  # A stopped VM: nothing to do, and nothing left over for the next start.
  reset; NOW=$((START + 5 * H)); cmd_extend 3 >/dev/null; PID=""; cmd_check
  check "a stopped VM is not stopped again" "$(walls)/$(stops)" "0/0"
  check "and its extension is cleared" "$(read_state deadline)" ""
  check "extend refuses while the VM is stopped" "$(cmd_extend 2 2>/dev/null; printf '%s' "$?")" "1"

  # A new run of the VM never inherits the last run's extension, even when
  # no check ran in between to clear it.
  reset; NOW=$((START + H)); cmd_extend 12 >/dev/null
  PID=5151; START=$((NOW + 60)); NOW=$((START + 6 * H)); cmd_check
  check "a new run ignores the old run's extension" "$(stops)" "1"

  # deadline-epoch: the machine-readable state the monitor reads (#1651).
  reset; NOW=$((START + H)); PID=""
  check "deadline-epoch on a stopped VM prints running=0" "$(cmd_deadline_epoch)" "running=0"
  reset; NOW=$((START + H))
  check "deadline-epoch on a fresh run gives start + six hours" \
    "$(cmd_deadline_epoch | sed -n 's/^deadline_epoch=//p')" "$((START + 6 * H))"
  check "and marks it the default" "$(cmd_deadline_epoch | sed -n 's/^source=//p')" "default"
  reset; NOW=$((START + H)); cmd_extend 3 >/dev/null
  check "deadline-epoch after an extension gives the extended deadline" \
    "$(cmd_deadline_epoch | sed -n 's/^deadline_epoch=//p')" "$((NOW + 3 * H))"
  check "and marks it extended" "$(cmd_deadline_epoch | sed -n 's/^source=//p')" "extended"

  # A restart between reading the PID and stopping: the new run is not the
  # one whose deadline passed (review on #1652).
  reset; NOW=$((START + 6 * H + 10)); RESTART=5151; cmd_check
  check "a VM restarted during the check is not stopped by the old run's deadline" "$(stops)" "0"
  RESTART=""; START=$((NOW - 60)); cmd_check
  check "and the new run gets its own six hours" "$(stops)" "0"

  # The two interleavings the lock exists for. The test holds the lock on
  # fd 8, starts the other operation in the background, does what the
  # lock's holder would do, and lets go.
  if ((HAVE_FLOCK)); then
    local pid
    reset; mkdir -p "${STATE_DIR}"; NOW=$((START + 6 * H + 10))
    exec 8>"${STATE_DIR}/lock"; flock 8
    # 8>&-: the child must not inherit the test's hold on the lock, or it
    # waits on itself until the timeout.
    cmd_check 8>&- & pid=$!
    sleep 0.3
    write_state run "${PID}"
    write_state deadline "$((NOW + H))"
    exec 8>&-
    wait "${pid}"
    check "a check waiting on the lock reads the deadline the extension wrote" "$(stops)" "0"

    reset; mkdir -p "${STATE_DIR}"; NOW=$((START + H))
    exec 8>"${STATE_DIR}/lock"; flock 8
    cmd_extend 2 >/dev/null 8>&- & pid=$!
    sleep 0.3
    check "an extension waits while a check holds the lock" "$(read_state deadline)" ""
    exec 8>&-
    wait "${pid}"
    check "and writes its deadline once the check lets go" "$(read_state deadline)" "$((NOW + 2 * H))"
  else
    printf '\033[0;33m  SKIP\033[0m the two lock interleavings: no flock on this host\n'
  fi

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
  deadline-epoch) cmd_deadline_epoch ;;
  *) printf 'usage: %s check|status|extend <hours>|deadline-epoch|--self-test\n' "$0" >&2; exit 2 ;;
esac
