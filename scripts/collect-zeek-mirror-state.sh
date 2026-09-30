#!/usr/bin/env bash
#
# Whether the Zeek mirror on the hypervisor's lab bridge is actually carrying
# packets to the sensor (#437, ADR-0064).
#
# THE GAP. Zeek on `fenrir` sees the domain's east-west traffic only because
# scripts/zeek-mirror.sh puts a `tc` mirror on every port of `vmbr0`. That mirror
# is kernel state: it does not survive a reboot, a guest restart recreates the
# tap it sat on without it, and a sensor restart leaves every filter pointing at
# an interface that no longer exists — `tc` shows that as
# `Egress Mirror to device *` and carries on, mirroring nothing, silently. The
# lab's Loki has no ruler (ADR-0020), so "Zeek went quiet" cannot be an alert
# where Zeek's logs land (#441). This is where it is answered instead.
#
# WHY IT IS NOT THE SCRIPT THAT BUILDS THE MIRROR. A unit that reports on its own
# work reports that it ran. This one reads the kernel independently, so
# disabling homelab-zeek-mirror.timer and rebooting — #437's proof — drives this
# gauge to 0 rather than taking it down with the thing it watches.
#
# WHAT "ACTIVE" MEANS. All four, because each one alone is a healthy-looking
# number with nothing underneath it:
#   - the sensor guest is running (`qm status`);
#   - its capture tap exists and is up;
#   - every port of the bridge carries the pref-437 mirror to THAT tap, by name
#     — a filter pointing at `*` counts as absent;
#   - the tap's tx_packets moved since the last run. The domain is never silent
#     for five minutes (DNS, Kerberos renewals, the scrape), so a flat counter
#     is a mirror that is configured and not delivering.
#
# A SENSOR NEVER BUILT IS NOT A SENSOR THAT IS DOWN. With no VM 190 at all —
# before build-the-sensor-guest.md, or after its §9 took it out — this writes
# nothing and removes any file it wrote before, so the series vanish rather
# than read 0. Otherwise a full install-agent-collectors run on the hypervisor
# would page ZeekMirrorInactive for a guest nobody has made. A STOPPED sensor
# is a different thing, and reads 0.
#
# NO GUEST DATA (ADR-0028). Run state, host interfaces and host tc state: all of
# it hypervisor state. Nothing here reads what Zeek logged, or whether Zeek is
# running inside the guest — that is the one thing this cannot see, and
# ADR-0064 says so.
#
# Usage: scripts/collect-zeek-mirror-state.sh [--print]
#        scripts/collect-zeek-mirror-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/zeek-mirror-state.prom"
HOSTNAME_LABEL="$(hostname)"

# The same defaults as scripts/zeek-mirror.sh. Kept as two copies rather than a
# shared file because each script is installed alone to /usr/local/bin.
SENSOR_VMID="${SENSOR_VMID:-190}"
BRIDGE="${BRIDGE:-vmbr0}"
CAPTURE="${CAPTURE:-tap${SENSOR_VMID}i1}"
PREF="${PREF:-437}"
SYSNET="${SYSNET:-/sys/class/net}"
STATE_DIR="${STATE_DIR:-/run/homelab-zeek-mirror-state}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The bridge's ports that should carry the mirror: all of them except the
# sensor's own taps. Its management NIC is on this bridge; mirroring it would
# feed Zeek its own log shipping. One name per line in, one per line out.
select_ports() {
  awk -v vmid="$SENSOR_VMID" '$0 != "" && $0 !~ ("^tap" vmid "i[0-9]+$")'
}

# `tc filter show dev X <dir> pref N` on stdin. 1 when a matchall filter there
# mirrors to the capture tap BY NAME, else 0. With `pref` given, tc omits the
# pref from its output, so the pref is the query's job and not the parser's.
mirrors_to() {
  awk -v dev="$1" '
    /matchall/ { m = 1 }
    index($0, "(Egress Mirror to device " dev ")") && m { ok = 1 }
    END { print ok ? 1 : 0 }
  '
}

# `qm status VMID` on stdin: running, stopped, absent, or nothing for output it
# does not recognise.
parse_qm_status() {
  awk '
    /^status:/ { print $2; found = 1; exit }
    /does not exist/ { print "absent"; found = 1; exit }
  '
}

# Whether the tap delivered packets since the last run. A counter BELOW the last
# one means the tap was recreated (the sensor restarted) and counts from zero
# again; that and a first run after boot, with no previous reading, both ask
# only that it has delivered something.
# Args: previous (may be empty), current.
advanced() {
  local prev="$1" now="$2"
  if [[ -z "$prev" ]] || ((now < prev)); then
    ((now > 0)) && echo 1 || echo 0
  else
    ((now > prev)) && echo 1 || echo 0
  fi
}

# Args: running(0/1) capture_up(0/1) expected mirrored advanced(0/1)
verdict() {
  local running="$1" up="$2" expected="$3" mirrored="$4" moved="$5"
  if ((running && up && expected > 0 && mirrored == expected && moved)); then echo 1; else echo 0; fi
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

  # tc's own output, captured from iproute2 6.15 on Saruman's kernel.
  good="filter protocol all matchall chain 0
filter protocol all matchall chain 0 handle 0x1
  not_in_hw
	action order 1: mirred (Egress Mirror to device tap190i1) pipe
	index 1 ref 1 bind 1"
  # The sensor restarted: its tap was destroyed and recreated with a new
  # ifindex, and the filter kept the old one. tc prints `*` and mirrors nothing.
  dangling="${good/tap190i1/*}"
  check "a mirror to the capture tap counts" 1 "$(printf '%s\n' "$good" | mirrors_to tap190i1)"
  check "a mirror to a vanished tap (*) does not" 0 "$(printf '%s\n' "$dangling" | mirrors_to tap190i1)"
  check "a mirror to another tap does not" 0 "$(printf '%s\n' "${good/tap190i1/tap190i10}" | mirrors_to tap190i1)"
  check "no filter at all does not" 0 "$(printf '' | mirrors_to tap190i1)"

  ports="eno1
tap140i0
tap150i0
tap190i0
tap190i1
tap1900i0"
  check "the sensor's own taps are excluded, a longer VMID is not" \
    "eno1 tap140i0 tap150i0 tap1900i0" "$(printf '%s\n' "$ports" | select_ports | paste -sd' ' -)"

  check "qm running" running "$(printf 'status: running\n' | parse_qm_status)"
  check "qm stopped" stopped "$(printf 'status: stopped\n' | parse_qm_status)"
  check "qm on a VMID that was never built" absent \
    "$(printf "Configuration file 'nodes/Saruman/qemu-server/190.conf' does not exist\n" | parse_qm_status)"
  check "qm output it does not recognise is no verdict" "" "$(printf 'ipcc_send_rec failed\n' | parse_qm_status)"

  check "packets moved" 1 "$(advanced 100 250)"
  check "packets flat — configured, not delivering" 0 "$(advanced 250 250)"
  check "first run after boot, packets present" 1 "$(advanced "" 42)"
  check "first run after boot, nothing delivered" 0 "$(advanced "" 0)"
  check "tap recreated, counting again" 1 "$(advanced 90000 12)"

  check "all four hold: active" 1 "$(verdict 1 1 11 11 1)"
  check "one port missing its mirror: inactive" 0 "$(verdict 1 1 11 10 1)"
  check "sensor stopped: inactive" 0 "$(verdict 0 0 11 0 0)"
  check "tap down: inactive" 0 "$(verdict 1 0 11 11 1)"
  check "packets flat: inactive" 0 "$(verdict 1 1 11 11 0)"
  check "an empty bridge is not a mirrored one" 0 "$(verdict 1 1 0 0 1)"
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v qm >/dev/null 2>&1 || die "no qm on this host — it is not a Proxmox VE node."
command -v tc >/dev/null 2>&1 || die "no tc on this host."
[[ -d "${SYSNET}/${BRIDGE}/brif" ]] \
  || die "no bridge ${BRIDGE} — nothing to have mirrored, and nothing to report."

# A STATUS THAT CANNOT BE READ IS NOT A SENSOR THAT IS DOWN. An unrecognised
# `qm` answer writes nothing, and ZeekMirrorStateStale says the reading stopped.
qm_out="$(qm status "${SENSOR_VMID}" 2>&1)"
qm_state="$(printf '%s\n' "$qm_out" | parse_qm_status)"
[[ -n "$qm_state" ]] || die "qm status ${SENSOR_VMID} gave nothing recognisable: ${qm_out:-<empty>}"
if [[ "$qm_state" == absent ]]; then
  if ((PRINT_ONLY)); then
    printf '# VM %s does not exist: the sensor is not built, and nothing is published\n' "$SENSOR_VMID"
    exit 0
  fi
  rm -f "${PROM}"
  printf 'zeek-mirror-state host=%s sensor=absent published=nothing\n' "$HOSTNAME_LABEL"
  exit 0
fi
running=0; [[ "$qm_state" == running ]] && running=1

up=0
if [[ -r "${SYSNET}/${CAPTURE}/operstate" ]] && [[ "$(<"${SYSNET}/${CAPTURE}/operstate")" != down ]]; then
  # A tap reads `unknown`, not `up`, when it is working; only `down` is down.
  up=1
fi
tx=0
[[ -r "${SYSNET}/${CAPTURE}/statistics/tx_packets" ]] && tx="$(<"${SYSNET}/${CAPTURE}/statistics/tx_packets")"

# Every port's ingress, and the bridge's own egress — the traffic the
# hypervisor originates, which enters through no port.
expected=0; mirrored=0; missing=()
while read -r dev dir; do
  expected=$((expected + 1))
  if [[ "$(tc filter show dev "$dev" "$dir" pref "$PREF" 2>/dev/null | mirrors_to "$CAPTURE")" == 1 ]]; then
    mirrored=$((mirrored + 1))
  else
    missing+=("${dev}:${dir}")
  fi
done < <(
  find "${SYSNET}/${BRIDGE}/brif/" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | select_ports | sed 's/$/ ingress/'
  printf '%s egress\n' "$BRIDGE"
)

prev=""
[[ -r "${STATE_DIR}/tx_packets" ]] && prev="$(<"${STATE_DIR}/tx_packets")"
[[ "$prev" =~ ^[0-9]+$ ]] || prev=""
moved="$(advanced "$prev" "$tx")"
active="$(verdict "$running" "$up" "$expected" "$mirrored" "$moved")"

emit() {
  printf '# HELP homelab_zeek_mirror_active 1 when the sensor runs and every bridge port mirrors to its tap, and packets arrived.\n'
  printf '# TYPE homelab_zeek_mirror_active gauge\n'
  printf 'homelab_zeek_mirror_active{host="%s"} %s\n' "$HOSTNAME_LABEL" "$active"
  printf '# HELP homelab_zeek_mirror_sensor_running 1 when the sensor guest is running.\n'
  printf '# TYPE homelab_zeek_mirror_sensor_running gauge\n'
  printf 'homelab_zeek_mirror_sensor_running{host="%s"} %s\n' "$HOSTNAME_LABEL" "$running"
  printf '# HELP homelab_zeek_mirror_ports_expected Bridge ports (and the bridge egress) that should mirror to the sensor.\n'
  printf '# TYPE homelab_zeek_mirror_ports_expected gauge\n'
  printf 'homelab_zeek_mirror_ports_expected{host="%s"} %s\n' "$HOSTNAME_LABEL" "$expected"
  printf '# HELP homelab_zeek_mirror_ports_mirrored Of those, how many carry a mirror to the sensor tap by name.\n'
  printf '# TYPE homelab_zeek_mirror_ports_mirrored gauge\n'
  printf 'homelab_zeek_mirror_ports_mirrored{host="%s"} %s\n' "$HOSTNAME_LABEL" "$mirrored"
  printf '# HELP homelab_zeek_mirror_sensor_tx_packets_total Packets the hypervisor delivered to the sensor capture tap.\n'
  printf '# TYPE homelab_zeek_mirror_sensor_tx_packets_total counter\n'
  printf 'homelab_zeek_mirror_sensor_tx_packets_total{host="%s"} %s\n' "$HOSTNAME_LABEL" "$tx"
}

if ((PRINT_ONLY)); then
  emit
  ((${#missing[@]})) && printf '# not mirrored: %s\n' "${missing[*]}"
  exit 0
fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"

# The last count, for the next run. /run is tmpfs, so a reboot starts clean —
# which is the case advanced() treats as a first run.
mkdir -p "${STATE_DIR}" && printf '%s\n' "$tx" > "${STATE_DIR}/tx_packets"

printf 'zeek-mirror-state host=%s active=%s sensor=%s capture_up=%s mirrored=%s/%s tx_packets=%s%s\n' \
  "$HOSTNAME_LABEL" "$active" "$qm_state" "$up" "$mirrored" "$expected" "$tx" \
  "${missing[*]:+ missing=$(IFS=,; printf '%s' "${missing[*]}")}"
