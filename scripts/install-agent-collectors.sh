#!/usr/bin/env bash
#
# Put the textfile collectors on an agent host.
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
# IT NEEDS ROOT ON THE TARGET, WHICH IS NOT THE SAME AS NEEDING sudo. The estate
# has both shapes and the script picks per host: an unprivileged login uses sudo
# and prompts; a root login runs the block directly. Saruman is the second kind
# and has no sudo installed at all, so assuming it failed with "command not
# found: sudo" while already holding the only privilege it needed.
#
# WHERE sudo IS USED, it cannot be avoided:
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
# WHAT IT INSTALLS. One row per collector in COLLECTORS below — today
# patch-state (#360) and smart-state (#351). Adding a third is a row plus a unit
# under systemd/agent/, not a new script: the first version of this was
# install-agent-collectors.sh and hardcoded one job, which lasted exactly as
# long as it took for the second collector to need shipping.
#
# NOT EVERY COLLECTOR SUITS EVERY HOST, and the check is per collector rather
# than per host. patch-state needs apt; smart-state needs smartmontools. A host
# missing one still gets the other, and the one it cannot have is reported rather
# than skipped silently.
#
# patch-state requires apt-get and NOT apt-check. It preferred apt-check until
# Saruman: Proxmox VE 9 is Debian 13, where update-notifier-common no longer
# exists and apt-check with it. Requiring apt-check excluded every modern Debian
# host from a collector that can serve them perfectly well from `apt-get -s
# upgrade`. The collector picks the better method itself and publishes which one
# it used.
#
# Usage: scripts/install-agent-collectors.sh [user@]host [...]
#        scripts/install-agent-collectors.sh --check [user@]host [...]
#        scripts/install-agent-collectors.sh --only NAME [user@]host [...]
#
#   --check verifies an existing install and changes nothing.
#   --only  installs or checks one collector by name.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="${REPO}/systemd/agent"

REMOTE_UNITS=/etc/systemd/system
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector

# name         local script                     .prom it writes        requirement
COLLECTORS=(
  "patch-state scripts/collect-patch-state.sh   apt-patch-state.prom   /usr/bin/apt-get"
  "smart-state scripts/collect-smart-state.sh   smart-state-HOST.prom  /usr/sbin/smartctl"
  "pve-version scripts/collect-pve-version.sh   pve-version.prom       /usr/bin/pveversion"
  "guest-state scripts/collect-guest-state.sh   guest-state.prom       /usr/sbin/qm"
)

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; RESET=$'\033[0m'

pass() { printf '%s  PASS%s %s\n' "$GREEN" "$RESET" "$*"; }
fail() { printf '%s  FAIL%s %s\n' "$RED" "$RESET" "$*"; FAILED=1; }
warn() { printf '%s  WARN%s %s\n' "$YELLOW" "$RESET" "$*"; }
step() { printf '\n%s--%s %s\n' "$BLUE" "$RESET" "$*"; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

CHECK_ONLY=0
ONLY=""
TARGETS=()
while (($#)); do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --only)  ONLY="${2:-}"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^#   --only/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done
((${#TARGETS[@]})) || die "no target host given.

Usage: scripts/install-agent-collectors.sh [user@]host [...]
This needs sudo ON THE TARGET and will prompt for a password."

# Everything the table names must exist before a single host is touched. A
# half-installed agent is worse than an uninstalled one.
selected=0
for row in "${COLLECTORS[@]}"; do
  read -r name script _prom _need <<<"$row"
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && continue
  selected=1
  [[ -f "${REPO}/${script}" ]] || die "no collector at ${REPO}/${script}"
  for unit in "homelab-${name}.service" "homelab-${name}.timer"; do
    [[ -f "${UNIT_DIR}/${unit}" ]] || die "no ${unit} under ${UNIT_DIR}"
  done
done
((selected)) || die "--only ${ONLY@Q} matches no collector. Known: $(
  for row in "${COLLECTORS[@]}"; do read -r n _ _ _ <<<"$row"; printf '%s ' "$n"; done)"

FAILED=0

# -t for the sudo prompt. Two of them, because the outer ssh needs a TTY to
# forward the password prompt and ssh only allocates one for a command when
# asked twice.
ssh_tty() { ssh -tt -o ConnectTimeout=10 "$1" "${@:2}"; }

# ssh_q closes stdin so a call inside a loop cannot swallow the loop's input,
# which is the standard hazard with ssh in shell loops.
ssh_q()   { ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" "${@:2}" </dev/null; }

# ssh_in is the same WITHOUT that redirect, for the calls that pipe a file in.
# Using ssh_q to stage is how every unit arrived on oracle as ZERO BYTES: the
# function's own `</dev/null` overrides the caller's `< file`, so `cat >` on the
# far end read nothing. systemd reports a zero-length unit as `masked`, so the
# install failed with "Unit file ... is masked" and pointed nowhere near stdin.
#
# Worth knowing if this is ever tested by hand: under bash the last redirect
# wins, which is the bug. Under zsh, MULTIOS concatenates them instead and the
# content arrives — so the same command tested interactively in zsh works and in
# the script does not.
ssh_in()  { ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" "${@:2}"; }

# The .prom a collector writes. smart-state names its file after the host, so the
# SSH mode on the monitoring host cannot overwrite the local mode's output; the
# table carries the placeholder and it is resolved per target.
prom_for() {
  local pattern="$1" hostname="$2"
  printf '%s' "${pattern/HOST/$hostname}"
}

verify_one() {
  local target="$1" name="$2" prom_pattern="$3" need="$4" remote_hostname="$5"

  # Per collector, not per host: a host without apt still gets SMART, and a host
  # without smartmontools still gets patch state. Reporting the one it cannot
  # have beats installing a unit that can only fail.
  if ! ssh_q "$target" "test -x ${need}"; then
    fail "${target}/${name}: ${need} is missing — this host cannot run this collector.
       patch-state needs apt; smart-state needs smartmontools."
    return
  fi
  pass "${target}/${name}: ${need} present"

  local state
  state="$(ssh_q "$target" "systemctl is-enabled homelab-${name}.timer 2>&1" | tr -d '\r')"
  case "$state" in
    enabled*) pass "${target}/${name}: timer enabled" ;;
    masked*)
      # Almost always a zero-length unit file rather than a deliberate mask:
      # systemd reports both the same way, and an empty file is what a broken
      # transfer leaves behind. Say which to check, since the words differ.
      fail "${target}/${name}: homelab-${name}.timer is MASKED. If it was not masked
       deliberately, the unit file is empty — check
       'wc -c /etc/systemd/system/homelab-${name}.timer' on the host. Re-running
       this installer overwrites it and daemon-reload picks it up." ;;
    *) fail "${target}/${name}: homelab-${name}.timer is ${state:-unknown}, not enabled" ;;
  esac

  # The file, and its mode. A 0600 .prom is invisible to the collector and the
  # metric silently never appears — the failure run-scheduled.sh records having
  # measured, and worth asserting rather than trusting.
  local prom mode
  prom="${TEXTFILE_DIR}/$(prom_for "$prom_pattern" "$remote_hostname")"
  mode="$(ssh_q "$target" "stat -c %a ${prom} 2>/dev/null" | tr -d '\r')"
  if [[ -z "$mode" ]]; then
    fail "${target}/${name}: ${prom} does not exist — the timer has not run yet"
  elif [[ "$mode" != 644 ]]; then
    fail "${target}/${name}: ${prom} is mode ${mode}, not 644 — Alloy cannot read it"
  else
    local samples
    samples="$(ssh_q "$target" "grep -c '^homelab_' ${prom}" | tr -d '\r')"
    pass "${target}/${name}: ${prom##*/} written, mode 644, ${samples} sample(s)"
  fi
}

install_one() {
  local target="$1" name="$2" script="$3" need="$4" stage="$5"

  if ! ssh_q "$target" "test -x ${need}"; then
    fail "${target}/${name}: ${need} is missing — not installing a unit that can only fail"
    return 1
  fi

  # Staged into the invoking user's home first and moved into place by a single
  # privileged block, so the sudo password is asked for once per host rather than
  # once per file.
  local src dst
  for pair in \
      "${REPO}/${script}:${stage}/.homelab-${name}.sh" \
      "${UNIT_DIR}/homelab-${name}.service:${stage}/.homelab-${name}.service" \
      "${UNIT_DIR}/homelab-${name}.timer:${stage}/.homelab-${name}.timer"; do
    src="${pair%%:*}"; dst="${pair#*:}"
    if ! ssh_in "$target" "cat > ${dst}" < "$src"; then
      fail "${target}/${name}: could not copy ${src##*/}"
      return 1
    fi
    # ASSERT THE BYTES ARRIVED. A transfer that silently moved nothing is what
    # put four zero-length unit files on oracle and had systemd call them
    # masked; "staged" must mean the file is there AND has the size it should.
    local want got
    want="$(wc -c < "$src" | tr -d ' ')"
    got="$(ssh_q "$target" "wc -c < ${dst} 2>/dev/null" | tr -d ' \r')"
    if [[ "$got" != "$want" ]]; then
      fail "${target}/${name}: ${dst##*/} arrived as ${got:-0} bytes, expected ${want}"
      return 1
    fi
  done
  pass "${target}/${name}: staged, byte counts match"
  return 0
}

for target in "${TARGETS[@]}"; do
  printf '\n%s=== %s ===%s\n' "$BLUE" "$target" "$RESET"
  if ! ssh_q "$target" true; then
    fail "${target}: unreachable over SSH from this host"
    continue
  fi

  # The remote hostname, for the collectors whose filename carries it. Read once
  # rather than assumed from the SSH target, which is often an address.
  remote_hostname="$(ssh_q "$target" hostname | tr -d '\r')"
  [[ -n "$remote_hostname" ]] || { fail "${target}: could not read its hostname"; continue; }

  # The staging directory, ABSOLUTE, and this is not a detail. Files are staged
  # as the login user and installed by `sudo sh -c`, and sudo sets HOME=/root —
  # so a `~` inside that command expands to /root while the files are in
  # /home/atropos. The first real run failed with
  #     install: cannot stat '/root/.homelab-patch-state.sh'
  # having staged both collectors correctly. Resolved once, here, and passed in.
  #
  # NOT /tmp, deliberately: these files are installed as root-owned executables,
  # and staging them anywhere world-writable would let another local user swap
  # one between the copy and the install.
  # shellcheck disable=SC2016  # $HOME must expand on the REMOTE host, not here
  remote_home="$(ssh_q "$target" 'printf %s "$HOME"' | tr -d '\r')"
  [[ -n "$remote_home" && "$remote_home" == /* ]] \
    || { fail "${target}: could not resolve the login user's home directory"; continue; }

  # WHETHER sudo IS NEEDED AT ALL, which is not the same question as whether it
  # is available. The estate has both shapes:
  #
  #   oracle    login atropos, uid 1000, sudo present   -> sudo, with a prompt
  #   Saruman   login root,    uid 0,    sudo ABSENT    -> no sudo, run directly
  #   morpheus  login root,    uid 0,    sudo absent    -> same
  #
  # Assuming sudo failed on Saruman with "zsh:1: command not found: sudo" while
  # already running as root — the one privilege it needed, it already had.
  # Proxmox and pfSense are both minimal installs where sudo is simply not there.
  remote_uid="$(ssh_q "$target" 'id -u' | tr -d '\r')"
  [[ "$remote_uid" =~ ^[0-9]+$ ]] \
    || { fail "${target}: could not read the login user's uid"; continue; }
  if [[ "$remote_uid" == 0 ]]; then
    privileged=(sh -c)
    priv_note="already root"
  elif ssh_q "$target" "command -v sudo >/dev/null 2>&1"; then
    privileged=(sudo sh -c)
    priv_note="via sudo — expect a password prompt"
  else
    fail "${target}: login user is uid ${remote_uid} and there is no sudo on this host.
       Installing units and writing /usr/local/bin needs root. Either log in as
       root (AGENT=root@host) or install sudo there."
    continue
  fi

  if ! ssh_q "$target" "test -d ${TEXTFILE_DIR}"; then
    fail "${target}: no ${TEXTFILE_DIR} — deploy Alloy to this host first
       (scripts/deploy-agent.sh), which is what creates it"
    continue
  fi
  pass "${target}: textfile directory present, hostname ${remote_hostname}"

  staged=()
  if ((! CHECK_ONLY)); then
    step "${target}: shipping collectors"
    for row in "${COLLECTORS[@]}"; do
      read -r name script _prom need <<<"$row"
      [[ -n "$ONLY" && "$ONLY" != "$name" ]] && continue
      install_one "$target" "$name" "$script" "$need" "$remote_home" && staged+=("$name")
    done

    if ((${#staged[@]})); then
      step "${target}: installing (${priv_note})"
      # `install` rather than mv, so the mode is set in the same operation that
      # puts the file there and is never briefly wrong. Each service is started
      # once immediately: a timer enabled but never run leaves the host with no
      # series until tomorrow, which is indistinguishable from a broken install
      # for a day.
      cmds=""
      for name in "${staged[@]}"; do
        cmds+="install -m 0755 -o root -g root ${remote_home}/.homelab-${name}.sh /usr/local/bin/homelab-collect-${name} && "
        cmds+="install -m 0644 -o root -g root ${remote_home}/.homelab-${name}.service ${REMOTE_UNITS}/homelab-${name}.service && "
        cmds+="install -m 0644 -o root -g root ${remote_home}/.homelab-${name}.timer ${REMOTE_UNITS}/homelab-${name}.timer && "
      done
      cmds+="systemctl daemon-reload"
      for name in "${staged[@]}"; do
        cmds+=" && systemctl enable --now homelab-${name}.timer && systemctl start homelab-${name}.service"
      done
      # A TTY is allocated ONLY when sudo may prompt. Asking for one when running
      # as root adds carriage returns to everything the remote prints for no
      # reason, and `ssh -tt` to a host with no controlling terminal is a
      # needless failure mode.
      if [[ "$priv_note" == "already root" ]]; then
        ok=0; ssh_q "$target" "${privileged[*]} '${cmds}'" || ok=$?
      else
        ok=0; ssh_tty "$target" "${privileged[*]} '${cmds}'" || ok=$?
      fi
      if ((ok == 0)); then
        pass "${target}: installed and started ${staged[*]}"
      else
        fail "${target}: install failed"
      fi
      ssh_q "$target" "rm -f ${remote_home}/.homelab-*.sh ${remote_home}/.homelab-*.service ${remote_home}/.homelab-*.timer"
    fi
  fi

  step "${target}: verifying"
  for row in "${COLLECTORS[@]}"; do
    read -r name _script prom need <<<"$row"
    [[ -n "$ONLY" && "$ONLY" != "$name" ]] && continue
    verify_one "$target" "$name" "$prom" "$need" "$remote_hostname"
  done
done

printf '\n'
if ((FAILED)); then
  printf '%sone or more collectors are not running on one or more hosts%s\n' "$RED" "$RESET" >&2
  exit 1
fi
printf 'collectors running on %d host(s). The series appear as\n' "${#TARGETS[@]}"
printf 'homelab_apt_upgrades_pending{host="..."} and homelab_smart_healthy{host="..."}\n'
printf 'within one Alloy scrape.\n'
