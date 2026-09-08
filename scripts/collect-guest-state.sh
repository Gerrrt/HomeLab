#!/usr/bin/env bash
#
# Whether the hypervisor's guests are running (#257).
#
# THE GAP. `Saruman`'s own agent has reported into the estate's stack since
# 2026-09-02 (#88, #240), so the hypervisor is visible on VLAN 99. Its guests are
# not, and by ADR-0007 their telemetry never will be. `alexander` — which has run
# `stacks/lab/` since 2026-09-05 — produces no series here at all; verified
# 2026-09-07, `{instance=~".*alexander.*"}` is empty.
#
# So if the guest dies, the estate sees a healthy DL360 and nothing else.
# RemoteWriteJobStale is the net for a host that goes quiet, and it keys on jobs
# that ARRIVE here, which is exactly why it can never cover something that stays
# in the lab. #257 puts it plainly: "the lab is being built to go quiet."
#
# WHY THIS IS NOT THE TELEMETRY ADR-0007 KEEPS IN THE LAB, which is the whole
# question and is answered in ADR-0028 rather than assumed here. What this emits
# is a property of the HYPERVISOR — how many guests it is running and which —
# read from `qm`/`pct` on the host that already reports to VLAN 99. It carries
# nothing about what a guest is doing: no metric it produces, no log it writes,
# no service it runs. "VM 100 exists and is running" is the same class of fact as
# "this host has 4 CPUs", which the estate already collects from this host.
#
# WHAT IT THEREFORE DOES NOT ANSWER, and this matters more than what it does.
# A guest that is powered on with a dead lab stack inside it looks identical to
# a healthy one. This closes "the guest died" and leaves "the lab stack died"
# open — ADR-0028 records that, and names the firewall pass a real heartbeat
# would need.
#
# NO ROOT NEEDED for the reading; the unit runs as root because the textfile
# directory on an agent host is root-owned, the same incidental reason as the
# other agent collectors.
#
# Usage: scripts/collect-guest-state.sh [--print]
#        scripts/collect-guest-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/guest-state.prom"
HOSTNAME_LABEL="$(hostname)"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# `qm list` and `pct list` print a header and then fixed columns:
#
#       VMID NAME          STATUS     MEM(MB)  BOOTDISK(GB) PID
#        100 alexander     running    4096            32.00 1234
#
# Parsed by shape rather than by column position, for the reason the gateway
# collector learned: a row without a PID, or a name containing a space, shifts
# every position-based field. VMID is the leading integer, STATUS is the field
# that IS a status, and NAME is what sits between them.
parse_guest_list() {
  local kind="$1"
  awk -v kind="$kind" '
    $1 == "VMID" { next }
    $1 !~ /^[0-9]+$/ { next }
    {
      vmid = $1; status = ""; status_at = 0
      for (i = 2; i <= NF; i++) {
        if ($i == "running" || $i == "stopped" || $i == "paused" || $i == "suspended") {
          status = $i; status_at = i; break
        }
      }
      if (status == "") next
      name = ""
      for (i = 2; i < status_at; i++) name = name (name == "" ? "" : " ") $i
      if (name == "") name = "vmid-" vmid
      printf "%s %s %s %s\n", kind, vmid, name, status
    }
  '
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" kind="$2" expect="$3" got
    got="$(printf '%s\n' "$4" | parse_guest_list "$kind" | tr '\n' ';')"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  check "the documented qm list shape" qemu "qemu 100 alexander running;" \
"      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
       100 alexander            running    4096              32.00 1234"
  # A stopped guest has no PID, so the row is one column shorter. Position-based
  # parsing reads BOOTDISK as the PID and, worse, still finds a plausible status.
  check "stopped guest has no PID column" qemu "qemu 101 winsrv stopped;" \
"      VMID NAME       STATUS     MEM(MB)    BOOTDISK(GB) PID
       101 winsrv     stopped    8192              64.00"
  check "a name containing a space" qemu "qemu 102 dc one running;" \
"       102 dc one    running    8192              64.00 999"
  check "mixed states" qemu "qemu 100 alexander running;qemu 101 winsrv stopped;" \
"      VMID NAME       STATUS     MEM(MB)    BOOTDISK(GB) PID
       100 alexander  running    4096              32.00 1234
       101 winsrv     stopped    8192              64.00"
  check "containers are labelled lxc" lxc "lxc 200 wazuh running;" \
"      VMID  STATUS     LOCK         NAME
       200 wazuh      running"
  check "header alone yields nothing" qemu "" \
"      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  check "empty input yields nothing" qemu "" ""
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v qm >/dev/null 2>&1 \
  || die "no qm on this host — it is not a Proxmox VE node.
This collector covers PVE hypervisors only; see the header."

rows="$(qm list 2>/dev/null | parse_guest_list qemu)"
if command -v pct >/dev/null 2>&1; then
  rows="${rows}
$(pct list 2>/dev/null | parse_guest_list lxc)"
fi
rows="$(printf '%s\n' "$rows" | grep -v '^$' || true)"

# No guests is a legitimate answer and must not look like a broken collector, so
# the marker below is emitted either way and the count can be zero.
emit() {
  printf '# HELP homelab_guest_running 1 when this hypervisor guest is running.\n'
  printf '# TYPE homelab_guest_running gauge\n'
  if [[ -n "$rows" ]]; then
    while read -r kind vmid name status; do
      [[ -n "$kind" ]] || continue
      printf 'homelab_guest_running{host="%s",guest="%s",vmid="%s",type="%s"} %s\n' \
        "$HOSTNAME_LABEL" "$name" "$vmid" "$kind" \
        "$([[ "$status" == running ]] && echo 1 || echo 0)"
    done <<<"$rows"
  fi
  printf '# HELP homelab_guests_total Guests this hypervisor knows about, running or not.\n'
  printf '# TYPE homelab_guests_total gauge\n'
  printf 'homelab_guests_total{host="%s"} %s\n' \
    "$HOSTNAME_LABEL" "$(printf '%s\n' "$rows" | grep -c . || true)"
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'guest-state host=%s guests=%s running=%s\n' "$HOSTNAME_LABEL" \
  "$(printf '%s\n' "$rows" | grep -c . || true)" \
  "$(printf '%s\n' "$rows" | grep -c ' running$' || true)"
