#!/usr/bin/env bash
#
# The monitoring host's boot ordering: units that are not on a timer (ADR-0105).
#
#   scripts/install-host-units.sh --check     assert the units are coherent (offline, no privilege)
#   scripts/install-host-units.sh --install   install them and reload systemd (needs root)
#   scripts/install-host-units.sh --status    show what systemd has loaded, and prove the ordering
#
# WHY A SEPARATE INSTALLER
#
# install-timers.sh is the schedule: every unit it owns is a .service and
# .timer pair with a row in its JOBS table, run through run-scheduled.sh, and
# its --check fails a unit that has none of those. What lives in
# systemd/host/ is the opposite shape — a oneshot in the boot and a drop-in on
# a unit this repository does not own — so it gets its own short installer
# rather than an exception in that one.
#
# WHAT --check ASSERTS
#
#   1. The waiter's address is INGEST_BIND_ADDR's default in the observability
#      stack's compose.yaml. They are two copies of one fact, and the waiter
#      waiting for an address the stack does not bind is the same silent
#      outage this exists to prevent.
#   2. The drop-in orders docker.service After= the waiter and Wants= it.
#   3. `systemd-analyze verify` accepts the waiter, where systemd-analyze exists.
#   4. On the host that runs the stack: the installed copies match these, and
#      docker.service as systemd has loaded it carries the ordering. A unit
#      edited here and never installed is the drift #339 found in the timers.
#
# --install does not restart docker. The drop-in takes effect at the next
# start of docker.service, which is the next boot; restarting docker to prove
# it would stop the stack for nothing. --status proves the ordering from what
# systemd has loaded instead.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/systemd/host"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
COMPOSE="${REPO_ROOT}/stacks/observability/compose.yaml"
UNIT=homelab-wait-address.service
DROPIN_DIR=docker.service.d
DROPIN=10-homelab-wait-address.conf

FAILED=0
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() { printf '\033[0;33m  SKIP\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

unit_address() {
  sed -n 's/^Environment=HOMELAB_WAIT_ADDRESS=\([0-9.]*\)$/\1/p' "${SRC}/${UNIT}"
}

compose_address() {
  sed -n 's/.*\${INGEST_BIND_ADDR:-\([0-9.]*\)}.*/\1/p' "${COMPOSE}" | sort -u
}

# The stack runs here: the one place the installed copies can be compared.
stack_here() {
  command -v docker >/dev/null 2>&1 \
    && docker ps --filter name='^ingest-proxy$' --format '{{.Names}}' 2>/dev/null | grep -q .
}

check() {
  local ua ca
  ua="$(unit_address)"
  ca="$(compose_address)"
  if [[ -z "${ua}" ]]; then
    fail "${UNIT} sets no HOMELAB_WAIT_ADDRESS"
  elif [[ "$(wc -l <<<"${ca}")" -ne 1 || -z "${ca}" ]]; then
    fail "${COMPOSE#"${REPO_ROOT}/"} should give INGEST_BIND_ADDR exactly one default (found: ${ca:-none})"
  elif [[ "${ua}" == "${ca}" ]]; then
    pass "${UNIT} waits for ${ua}, the address the stack publishes on"
  else
    fail "${UNIT} waits for ${ua} but the stack publishes on ${ca}"
  fi

  if grep -qx "After=${UNIT}" "${SRC}/${DROPIN_DIR}/${DROPIN}" \
     && grep -qx "Wants=${UNIT}" "${SRC}/${DROPIN_DIR}/${DROPIN}"; then
    pass "${DROPIN_DIR}/${DROPIN} orders docker after ${UNIT} and pulls it in"
  else
    fail "${DROPIN_DIR}/${DROPIN} must carry both After=${UNIT} and Wants=${UNIT}"
  fi

  if command -v systemd-analyze >/dev/null 2>&1; then
    local out
    # Only lines about this unit: verify also reports unrelated units it
    # loads on the way, which are the host's business, not this check's.
    out="$(systemd-analyze verify "${SRC}/${UNIT}" 2>&1 | grep -F "${UNIT}" || true)"
    if [[ -z "${out}" ]]; then
      pass "systemd-analyze verify accepts ${UNIT}"
    else
      fail "systemd-analyze verify rejects ${UNIT}: ${out}"
    fi
  else
    skip "systemd-analyze not installed; ${UNIT} not verified"
  fi

  if stack_here; then
    if cmp -s "${SRC}/${UNIT}" "${SYSTEMD_DIR}/${UNIT}" \
       && cmp -s "${SRC}/${DROPIN_DIR}/${DROPIN}" "${SYSTEMD_DIR}/${DROPIN_DIR}/${DROPIN}"; then
      pass "the installed copies match systemd/host/"
    else
      fail "the stack runs here and systemd/host/ is not installed as committed — run 'make install-host-units'"
    fi
    if systemctl show docker.service -p After --value 2>/dev/null | tr ' ' '\n' | grep -qx "${UNIT}"; then
      pass "docker.service as loaded is ordered after ${UNIT}"
    else
      fail "docker.service as loaded is not ordered after ${UNIT} — 'sudo systemctl daemon-reload'?"
    fi
  else
    skip "the observability stack does not run here; installed copies not compared"
  fi
}

install_units() {
  ((EUID == 0)) || die "--install needs root: sudo $0 --install"
  install -D -m 0644 "${SRC}/${UNIT}" "${SYSTEMD_DIR}/${UNIT}"
  install -D -m 0644 "${SRC}/${DROPIN_DIR}/${DROPIN}" "${SYSTEMD_DIR}/${DROPIN_DIR}/${DROPIN}"
  systemctl daemon-reload
  systemctl enable "${UNIT}"
  # Start it now so its state is `active` before the next boot needs it. With
  # the address already held this returns at once; without it, it would wait,
  # so --no-block keeps an install on a host with no link from hanging.
  systemctl start --no-block "${UNIT}"
  printf 'installed %s and %s/%s; docker picks the ordering up at its next start\n' \
    "${UNIT}" "${DROPIN_DIR}" "${DROPIN}"
}

status() {
  systemctl --no-pager status "${UNIT}" | head -5
  printf '\ndocker.service, as loaded:\n'
  systemctl show docker.service -p DropInPaths -p After -p Wants \
    | sed 's/ /\n    /g' | grep -E "^(DropInPaths|After|Wants)=|${UNIT}|${DROPIN}"
  printf '\nthe chain docker waits on at boot:\n'
  systemd-analyze critical-chain docker.service --no-pager 2>/dev/null | sed -n '1,12p'
}

# Prove the ordering with systemd itself, without root and without touching
# the real docker. The committed waiter and drop-in are loaded into the
# caller's user manager under test names, in front of a stand-in docker unit,
# and started twice: once waiting for an address this host does not hold, when
# the stand-in's start job must sit `waiting` behind the waiter's `running`
# one, and once for the address it does hold, when both must finish.
# Everything is removed afterwards. Not a --self-test, because a CI runner has
# no user manager to ask.
prove_ordering() {
  local udir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user" held absent rc=0
  held="$(unit_address)"
  absent="192.0.2.1"   # TEST-NET-1: never assigned to a real interface
  [[ "$(systemctl --user is-system-running 2>/dev/null)" =~ ^(running|degraded)$ ]] \
    || die "no user systemd manager to prove the ordering in"
  [[ -e "${udir}/hl-proof-docker.service" ]] && die "${udir}/hl-proof-docker.service exists; remove the last proof first"
  mkdir -p "${udir}/hl-proof-docker.service.d"
  cleanup_proof() {
    systemctl --user stop hl-proof-docker.service hl-proof-wait.service >/dev/null 2>&1
    command rm -f "${udir}/hl-proof-wait.service" "${udir}/hl-proof-docker.service" \
      "${udir}/hl-proof-docker.service.d/${DROPIN}"
    rmdir "${udir}/hl-proof-docker.service.d" 2>/dev/null
    systemctl --user daemon-reload
  }
  trap cleanup_proof RETURN
  # The stand-in docker: records when it ran.
  printf '[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/true\n' \
    > "${udir}/hl-proof-docker.service"
  sed "s/${UNIT}/hl-proof-wait.service/g" "${SRC}/${DROPIN_DIR}/${DROPIN}" \
    > "${udir}/hl-proof-docker.service.d/${DROPIN}"

  local addr
  for addr in "${absent}" "${held}"; do
    systemctl --user stop hl-proof-docker.service hl-proof-wait.service >/dev/null 2>&1
    # The system-manager orderings (networkd, the real docker) mean nothing in
    # a user manager, so they are dropped; the ExecStart and the drop-in, which
    # are what is being proved, are the committed ones.
    sed -e "s/^Environment=HOMELAB_WAIT_ADDRESS=.*/Environment=HOMELAB_WAIT_ADDRESS=${addr}/" \
        -e '/^\(DefaultDependencies\|After\|Before\|Wants\)=/d' \
        "${SRC}/${UNIT}" > "${udir}/hl-proof-wait.service"
    systemctl --user daemon-reload
    systemctl --user start --no-block hl-proof-docker.service
    sleep 4
    printf '\n-- waiting for %s:\n' "${addr}"
    systemctl --user list-jobs --no-legend 2>/dev/null | grep hl-proof | sed 's/^/   job: /'
    local d w
    d="$(systemctl --user show hl-proof-docker.service -p ActiveState --value)"
    w="$(systemctl --user show hl-proof-wait.service -p ActiveState --value)"
    printf '   stand-in docker: %s, waiter: %s\n' "${d}" "${w}"
    if [[ "${addr}" == "${absent}" ]]; then
      if [[ "${d}" == inactive && "${w}" == activating ]]; then
        pass "with ${addr} absent, docker's start job is held behind the waiter"
      else
        fail "with ${addr} absent, docker is ${d} and the waiter ${w}"; rc=1
      fi
    else
      if [[ "${d}" == active && "${w}" == active ]]; then
        pass "with ${addr} held, the waiter finishes and docker starts"
      else
        fail "with ${addr} held, docker is ${d} and the waiter ${w}"; rc=1
      fi
    fi
  done
  printf '\n-- the stand-in docker as systemd loaded it:\n'
  systemctl --user show hl-proof-docker.service -p After -p Wants -p DropInPaths \
    | sed "s|${HOME}|~|g; s/^/   /"
  return "${rc}"
}

case "${1:-}" in
  --check)   check; exit "${FAILED}" ;;
  --prove-ordering) prove_ordering; exit $? ;;
  --install) install_units ;;
  --status)  status ;;
  *) sed -n '/^#   scripts/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,3\}//'; exit 2 ;;
esac
