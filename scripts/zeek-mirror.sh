#!/usr/bin/env bash
#
# Mirror every port of the hypervisor's lab bridge to the Zeek sensor, and keep
# it mirrored (#437, ADR-0064).
#
# WHY tc AND NOT OPEN VSWITCH. #437 was filed saying port mirroring needs OVS.
# It does not: a Linux bridge port is a netdev, and a `clsact` qdisc with a
# `matchall` filter and a `mirred` action copies whatever enters it to another
# netdev. Converting `vmbr0` would have meant moving 10.0.30.110 — the
# management plane ADR-0014's host firewall guards — onto an OVSIntPort, and
# putting a bridge that speaks VLAN tags under the one segment built to hold an
# attacker. ADR-0064 records the comparison.
#
# WHAT IS MIRRORED. The INGRESS of every bridge port except the sensor's own,
# which is every frame exactly once — each one enters the bridge through one
# port, whether a guest tap or eno1 — plus the EGRESS of the bridge device
# itself, which is what the hypervisor originates and which enters through no
# port. The copies go to the sensor's second NIC, `tap190i1`, which sits alone
# on the port-less `vmbr1` and so receives nothing else and reaches nothing.
#
# WHY A TIMER AND NOT A ONE-SHOT AT BOOT. Boot is the least of it. A guest
# restart recreates its tap without the filter. A SENSOR restart is worse: the
# tap is recreated with a new ifindex, every filter keeps the old one, and tc
# shows `Egress Mirror to device *` and mirrors nothing, with no error anywhere.
# So this runs every minute, checks each port for a mirror to the capture tap
# BY NAME, and replaces anything else. A port that is already right is left
# alone; `tc filter replace` on a matchall filter is not idempotent (it answers
# "File exists"), so the replace is a delete and an add.
#
# WHEN THE SENSOR IS DOWN it removes the filters rather than leave them pointing
# at nothing. The next run after the sensor starts puts them back.
#
# IT DOES NOT REPORT ON ITSELF. scripts/collect-zeek-mirror-state.sh reads the
# same kernel state independently and publishes homelab_zeek_mirror_active.
# That separation is #437's reboot proof: disable this timer, reboot, and the
# gauge has to go to zero on its own.
#
# Usage: scripts/zeek-mirror.sh [--dry-run]
#        scripts/zeek-mirror.sh --self-test
set -uo pipefail

SENSOR_VMID="${SENSOR_VMID:-190}"
BRIDGE="${BRIDGE:-vmbr0}"
CAPTURE="${CAPTURE:-tap${SENSOR_VMID}i1}"
PREF="${PREF:-437}"
SYSNET="${SYSNET:-/sys/class/net}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The same two parsers as the collector; see its header for why there are two
# copies.
select_ports() {
  awk -v vmid="$SENSOR_VMID" '$0 != "" && $0 !~ ("^tap" vmid "i[0-9]+$")'
}
mirrors_to() {
  awk -v dev="$1" '
    /matchall/ { m = 1 }
    index($0, "(Egress Mirror to device " dev ")") && m { ok = 1 }
    END { print ok ? 1 : 0 }
  '
}
# 1 when there is any filter at this pref, whatever it points at.
has_filter() {
  awk '/filter/ { f = 1 } END { print f ? 1 : 0 }'
}

# The commands that make one port right, one per line, for a state read from
# `tc filter show`. Nothing when it is already right. `del` only when something
# is there to delete, so a clean port produces no error to read past.
plan_port() {
  local dev="$1" dir="$2" shown="$3"
  if [[ "$(printf '%s\n' "$shown" | mirrors_to "$CAPTURE")" == 1 ]]; then
    return
  fi
  printf 'tc qdisc replace dev %s clsact\n' "$dev"
  [[ "$(printf '%s\n' "$shown" | has_filter)" == 1 ]] \
    && printf 'tc filter del dev %s %s pref %s\n' "$dev" "$dir" "$PREF"
  printf 'tc filter add dev %s %s pref %s matchall action mirred egress mirror dev %s\n' \
    "$dev" "$dir" "$PREF" "$CAPTURE"
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" expect="$2" got="$3"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  good="filter protocol all matchall chain 0
filter protocol all matchall chain 0 handle 0x1
  not_in_hw
	action order 1: mirred (Egress Mirror to device tap190i1) pipe
	index 1 ref 1 bind 1"
  dangling="${good/tap190i1/*}"

  check "a port already mirrored is left alone" "" "$(plan_port tap150i0 ingress "$good")"
  check "a clean port gets the qdisc and the filter" \
"tc qdisc replace dev tap150i0 clsact
tc filter add dev tap150i0 ingress pref 437 matchall action mirred egress mirror dev tap190i1" \
    "$(plan_port tap150i0 ingress "")"
  check "a dangling mirror (sensor restarted) is replaced" \
"tc qdisc replace dev eno1 clsact
tc filter del dev eno1 ingress pref 437
tc filter add dev eno1 ingress pref 437 matchall action mirred egress mirror dev tap190i1" \
    "$(plan_port eno1 ingress "$dangling")"
  check "the bridge's own egress is planned the same way" \
"tc qdisc replace dev vmbr0 clsact
tc filter add dev vmbr0 egress pref 437 matchall action mirred egress mirror dev tap190i1" \
    "$(plan_port vmbr0 egress "")"
  check "the sensor's own taps are never mirrored" "eno1 tap140i0" \
    "$(printf 'eno1\ntap140i0\ntap190i0\ntap190i1\n' | select_ports | paste -sd' ' -)"
  exit $fail
fi

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

command -v tc >/dev/null 2>&1 || die "no tc on this host."
[[ -d "${SYSNET}/${BRIDGE}/brif" ]] || die "no bridge ${BRIDGE}."

targets() {
  find "${SYSNET}/${BRIDGE}/brif/" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | select_ports | sed 's/$/ ingress/'
  printf '%s egress\n' "$BRIDGE"
}

# One planned line, split into words and run. Nothing in it is quoted or can
# contain a space: device names, a direction, numbers and tc's keywords.
run() {
  if ((DRY_RUN)); then printf '%s\n' "$1"; return 0; fi
  local -a argv
  read -ra argv <<<"$1"
  "${argv[@]}"
}

# No capture tap: the sensor is stopped or not built. Take the mirrors down
# rather than leave them aimed at nothing, and exit clean — a stopped sensor is
# a state for the collector to report, not a failure of this unit.
if [[ ! -e "${SYSNET}/${CAPTURE}" ]]; then
  removed=0
  while read -r dev dir; do
    if [[ "$(tc filter show dev "$dev" "$dir" pref "$PREF" 2>/dev/null | has_filter)" == 1 ]]; then
      run "tc filter del dev ${dev} ${dir} pref ${PREF}" && removed=$((removed + 1))
    fi
  done < <(targets)
  printf 'zeek-mirror bridge=%s capture=%s sensor=absent removed=%s\n' "$BRIDGE" "$CAPTURE" "$removed"
  exit 0
fi

total=0; already=0; applied=0; failed=0; bad=()
while read -r dev dir; do
  total=$((total + 1))
  plan="$(plan_port "$dev" "$dir" "$(tc filter show dev "$dev" "$dir" pref "$PREF" 2>/dev/null)")"
  if [[ -z "$plan" ]]; then already=$((already + 1)); continue; fi
  ok=1
  while read -r cmd; do
    run "$cmd" || ok=0
  done <<<"$plan"
  if ((ok)); then applied=$((applied + 1)); else failed=$((failed + 1)); bad+=("${dev}:${dir}"); fi
done < <(targets)

printf 'zeek-mirror bridge=%s capture=%s targets=%s already=%s applied=%s failed=%s%s\n' \
  "$BRIDGE" "$CAPTURE" "$total" "$already" "$applied" "$failed" "${bad[*]:+ bad=${bad[*]}}"
((failed == 0))
