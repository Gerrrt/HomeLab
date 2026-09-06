#!/usr/bin/env bash
#
# Put the patch-state collector on an agent host.
#
# WHAT #360 IS. #152 closed the patch-visibility gap on the monitoring host and
# only there. `oracle` is Ubuntu 24.04 with `apt-check` present and a textfile
# collector Alloy is already reading, and nothing was collecting from it: on
# 2026-09-06 it had been running kernel 6.8.0-138 for two days with 6.8.0-139
# installed and a reboot flag set since 2026-09-04. The estate could not see it.
#
# WHY A SEPARATE SCRIPT FROM deploy-agent.sh. That script goes out of its way to
# need no privilege on the target — its header says so, and it runs Alloy under
# Docker specifically because "the docker group needs no sudo". Folding a
# systemd unit install into it would give the whole agent deployment a sudo
# requirement it does not otherwise have, on every run, to install something
# that changes about once. So this is its own step, run once per host, and
# deploy-agent.sh keeps its property.
#
# THIS ONE DOES NEED sudo ON THE TARGET, and cannot avoid it:
# /var/lib/node_exporter/textfile_collector on an agent host is created by the
# Alloy deployment and owned by root, /usr/local/bin and /etc/systemd/system are
# root-owned everywhere, and enabling a timer is a privileged operation. It is
# the same one-off `sudo` that install-timers.sh asks for on the monitoring
# host. A TTY is allocated so the sudo password prompt works; unlike every other
# remote script here it therefore does NOT use BatchMode, and it is the one
# script in this repository that is meant to be run by hand rather than by a
# timer.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not install run-scheduled.sh or a
# job entry. An agent host has no checkout of this repository and no Makefile,
# so there are no homelab_job_* outcome metrics for these runs — the unit header
# says so at length. `PatchStateStopped` covers the gap from the data side
# instead, alerting when a host that WAS reporting stops.
#
# Usage: scripts/install-agent-patch-state.sh [user@]host [...]
#        scripts/install-agent-patch-state.sh --check [user@]host [...]
#
#   --check verifies an existing install and changes nothing.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTOR="${REPO}/scripts/collect-patch-state.sh"
UNIT_DIR="${REPO}/systemd/agent"

REMOTE_BIN=/usr/local/bin/homelab-collect-patch-state
REMOTE_UNITS=/etc/systemd/system
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
PROM="${TEXTFILE_DIR}/apt-patch-state.prom"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; RESET=$'\033[0m'

pass() { printf '%s  PASS%s %s\n' "$GREEN" "$RESET" "$*"; }
fail() { printf '%s  FAIL%s %s\n' "$RED" "$RESET" "$*"; FAILED=1; }
warn() { printf '%s  WARN%s %s\n' "$YELLOW" "$RESET" "$*"; }
step() { printf '\n%s--%s %s\n' "$BLUE" "$RESET" "$*"; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

CHECK_ONLY=0
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option ${arg}" ;;
    *) TARGETS+=("$arg") ;;
  esac
done
((${#TARGETS[@]})) || die "no target host given.

Usage: scripts/install-agent-patch-state.sh [user@]host [...]
This needs sudo ON THE TARGET and will prompt for a password."

[[ -f "$COLLECTOR" ]] || die "no collector at ${COLLECTOR}"
for unit in homelab-patch-state.service homelab-patch-state.timer; do
  [[ -f "${UNIT_DIR}/${unit}" ]] || die "no ${unit} under ${UNIT_DIR}"
done

FAILED=0

# -t for the sudo prompt. Two of them, because the outer ssh needs a TTY to
# forward the password prompt and ssh only allocates one for a command when
# asked twice.
ssh_tty() { ssh -tt -o ConnectTimeout=10 "$1" "${@:2}"; }
ssh_q()   { ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" "${@:2}" </dev/null; }

verify() {
  local target="$1"

  # The collector reads apt-check and a flag file; if apt-check is missing this
  # host is not an apt system and nothing here applies. Proxmox is the case #360
  # flags — it ships update-notifier-common inconsistently, so this is checked
  # rather than assumed.
  if ! ssh_q "$target" "test -x /usr/lib/update-notifier/apt-check"; then
    fail "${target}: no /usr/lib/update-notifier/apt-check — not an apt host, or
       update-notifier-common is not installed. On Debian/Proxmox:
       apt install update-notifier-common"
    return
  fi
  pass "${target}: apt-check present"

  if ! ssh_q "$target" "test -d ${TEXTFILE_DIR}"; then
    fail "${target}: no ${TEXTFILE_DIR} — deploy Alloy to this host first
       (scripts/deploy-agent.sh), which is what creates it"
    return
  fi
  pass "${target}: textfile directory present"

  if ssh_q "$target" "systemctl is-enabled --quiet homelab-patch-state.timer"; then
    pass "${target}: homelab-patch-state.timer enabled"
  else
    fail "${target}: homelab-patch-state.timer is not enabled"
  fi

  # The file, and its mode. A 0600 .prom is invisible to the collector and the
  # metric silently never appears — the same failure run-scheduled.sh records
  # having measured, and worth asserting rather than trusting.
  local mode
  mode="$(ssh_q "$target" "stat -c %a ${PROM} 2>/dev/null" | tr -d '\r')"
  if [[ -z "$mode" ]]; then
    fail "${target}: ${PROM} does not exist — the timer has not run yet"
  elif [[ "$mode" != 644 ]]; then
    fail "${target}: ${PROM} is mode ${mode}, not 644 — Alloy cannot read it"
  else
    pass "${target}: ${PROM} written, mode 644"
    ssh_q "$target" "grep -c '^homelab_' ${PROM}" >/dev/null \
      && pass "${target}: $(ssh_q "$target" "grep -c '^homelab_' ${PROM}" | tr -d '\r') sample(s) in it"
  fi
}

install_to() {
  local target="$1"
  step "${target}: shipping the collector and units"

  # Everything is staged into the invoking user's home first and moved into
  # place by a single privileged block, so the sudo password is asked for once
  # rather than once per file.
  if ! ssh_q "$target" "cat > ~/.homelab-patch-state.sh" < "$COLLECTOR"; then
    fail "${target}: could not copy the collector"; return
  fi
  ssh_q "$target" "cat > ~/.homelab-patch-state.service" < "${UNIT_DIR}/homelab-patch-state.service"
  ssh_q "$target" "cat > ~/.homelab-patch-state.timer" < "${UNIT_DIR}/homelab-patch-state.timer"
  pass "${target}: staged"

  step "${target}: installing (sudo — expect a password prompt)"
  # `install` rather than mv, so the mode is set in the same operation that puts
  # the file there and never briefly wrong. The service is started once
  # immediately: a timer that is enabled but has never run leaves the host with
  # no series until 08:00 tomorrow, which is indistinguishable from a broken
  # install for a day.
  ssh_tty "$target" "sudo sh -c '
    install -m 0755 -o root -g root ~/.homelab-patch-state.sh ${REMOTE_BIN} &&
    install -m 0644 -o root -g root ~/.homelab-patch-state.service ${REMOTE_UNITS}/homelab-patch-state.service &&
    install -m 0644 -o root -g root ~/.homelab-patch-state.timer ${REMOTE_UNITS}/homelab-patch-state.timer &&
    systemctl daemon-reload &&
    systemctl enable --now homelab-patch-state.timer &&
    systemctl start homelab-patch-state.service
  ' && rm -f ~/.homelab-patch-state.sh ~/.homelab-patch-state.service ~/.homelab-patch-state.timer"

  local rc=$?
  ((rc == 0)) || { fail "${target}: install failed (rc=${rc})"; return; }
  pass "${target}: installed and started"
}

for target in "${TARGETS[@]}"; do
  printf '\n%s=== %s ===%s\n' "$BLUE" "$target" "$RESET"
  if ! ssh_q "$target" true; then
    fail "${target}: unreachable over SSH from this host"
    continue
  fi
  ((CHECK_ONLY)) || install_to "$target"
  step "${target}: verifying"
  verify "$target"
done

printf '\n'
if ((FAILED)); then
  printf '%sone or more hosts are not collecting patch state%s\n' "$RED" "$RESET" >&2
  exit 1
fi
printf 'patch state collecting on %d host(s). The series appear as\n' "${#TARGETS[@]}"
printf 'homelab_apt_upgrades_pending{host="..."} within one Alloy scrape.\n'
