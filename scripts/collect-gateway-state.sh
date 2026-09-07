#!/usr/bin/env bash
#
# The firewall's own view of its uplinks, as metrics (#353).
#
# WHAT NOTHING WAS WATCHING. #166 added latency probes, but those measure
# "monitoring host -> target". A gateway's own view of its uplink is a different
# measurement on a different interface, and it was not collected at all. dpinger
# logs to syslog only on a STATE CHANGE, so a gateway that has been down since
# before log retention began writes nothing — which is why searching Loki for
# `dpinger|gateway alarm|packet loss` over 24h returned zero matches while a
# gateway sat at 100% loss.
#
# WHY IT MEASURES FORWARDING AS WELL AS STATUS, which is the whole design.
# On 2026-09-07 `WAN_DHCP6` reported down at 100% loss. It was not down:
#
#     ping6 fe80::21c:73ff:fe00:99%em0   3 sent, 0 received, 100% loss
#     ping6 2606:4700:4700::1111         3 sent, 3 received, ~11ms
#     traceroute6 hop 2                  po-316-...seattle.comcast.net
#
# The v6 default route IS that gateway, traffic traverses it, and its NDP entry
# is live. It simply does not answer ICMPv6 echo to its link-local address,
# which is what dpinger was pointed at — common on ISP CPE. So "100% loss" was a
# property of the MONITOR TARGET, not of the link.
#
# A collector that reported only pfSense's status would have turned a
# measurement artifact into a permanently-firing alert, and this repository has
# written down what happens to those: a check that is permanently red for a
# known reason stops being read. So each gateway's reported status is paired
# with an independent question — can this box actually reach the internet over
# that address family — and the two together separate a real outage from a
# monitor pointed at something that never answers.
#
# NO ADDRESSES ARE EMITTED. Labels are the gateway NAME and the address family.
# The monitor and source columns carry the WAN address and the ISP's gateway,
# and docs/security.md says the WAN address is not published.
#
# Usage: scripts/collect-gateway-state.sh --ssh USER@HOST --host NAME [--print]
#        scripts/collect-gateway-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PRINT_ONLY=0
SSH_TARGET=""
HOST_LABEL=""

# Anycast addresses used only to ask "does this family leave the building".
# Overridable because an estate that blocks them outbound would otherwise
# measure its own egress policy and call it an uplink failure.
PROBE4="${GATEWAY_PROBE4:-1.1.1.1}"
PROBE6="${GATEWAY_PROBE6:-2606:4700:4700::1111}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# pfSense's gatewaystatus table is RAGGED: a gateway with no monitor prints four
# fields where a monitored one prints eight.
#
#   WAN_DHCP6  fe80::...%em0  fe80::...%em0   0ms   0ms  100%  down    highloss
#   LAN_DHCP   none                                       online  none
#
# So fields are found BY SHAPE rather than by position — status is the word that
# is a status, loss is the field ending in %, delay is the field ending in ms.
# Position-based parsing of this table silently attributes the wrong column the
# first time a gateway without a monitor appears.
parse_gatewaystatus() {
  awk '
    NR == 1 && $1 == "Name" { next }                 # header
    NF < 2 { next }
    {
      name = $1; status = ""; loss = ""; delay = ""; family = "inet"
      if ($2 ~ /:/) family = "inet6"                 # monitor address shape
      for (i = 2; i <= NF; i++) {
        if ($i == "online" || $i == "down" || $i == "pending") status = $i
        else if ($i ~ /^[0-9.]+%$/) { loss = $i; sub(/%$/, "", loss) }
        else if ($i ~ /^[0-9.]+ms$/ && delay == "") { delay = $i; sub(/ms$/, "", delay) }
      }
      if (status == "") next
      printf "%s %s %s %s %s\n", name, family, status, (loss == "" ? "NaN" : loss), (delay == "" ? "NaN" : delay)
    }
  '
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" expect="$2" got
    got="$(printf '%s\n' "$3" | parse_gatewaystatus | tr '\n' ';')"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  # The live table on 2026-09-07, addresses replaced. This is the case that
  # matters: a v6 gateway reporting 100% loss beside a healthy v4 one, and a
  # third gateway with no monitor at all.
  check "the live table" \
    "WAN_DHCP6 inet6 down 100 0;WAN_DHCP inet online 0.0 13.707;LAN_DHCP inet online NaN NaN;" \
"Name       Monitor        Source          Delay     StdDev  Loss  Status  Substatus
WAN_DHCP6  fe80::1%em0    fe80::2%em0       0ms        0ms  100%    down   highloss
WAN_DHCP   1.1.1.1        174.16.0.1   13.707ms     4.021ms  0.0%  online       none
LAN_DHCP   none                                                    online       none"
  # A gateway with no monitor must not inherit the previous row's numbers, which
  # is what position-based parsing does.
  check "unmonitored gateway carries no numbers" "LAN_DHCP inet online NaN NaN;" \
"LAN_DHCP   none                                                    online       none"
  check "pending is kept, not dropped" "WAN_DHCP inet pending 0.0 5.0;" \
"WAN_DHCP   1.1.1.1   174.16.0.1   5.0ms   1.0ms  0.0%  pending  none"
  check "v6 detected from the monitor address" "W6 inet6 online 0.0 9.0;" \
"W6   2606:4700:4700::1111   2001:db8::1   9.0ms   1.0ms  0.0%  online  none"
  check "header alone yields nothing" "" \
"Name       Monitor    Source    Delay   StdDev  Loss  Status  Substatus"
  exit $fail
fi

while (($#)); do
  case "$1" in
    --print) PRINT_ONLY=1; shift ;;
    --ssh)   SSH_TARGET="${2:-}"; shift 2 ;;
    --host)  HOST_LABEL="${2:-}"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ -n "$SSH_TARGET" ]] || die "--ssh USER@HOST is required"
[[ -n "$HOST_LABEL" ]] || die "--host NAME is required"

STDERR_FILE="$(mktemp)"; trap 'rm -f "${STDERR_FILE}"' EXIT

raw="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
  'pfSsh.php playback gatewaystatus' 2>"${STDERR_FILE}")"
if [[ -z "$raw" ]]; then
  detail="$(tr -d '\r' < "${STDERR_FILE}" | grep -v '^$' | tail -2 | paste -sd'; ' -)"
  die "could not read gateway status from ${SSH_TARGET}${detail:+ — ${detail}}"
fi

rows="$(printf '%s\n' "$raw" | parse_gatewaystatus)"
[[ -n "$rows" ]] || die "gatewaystatus returned no gateways — the output format may have changed"

# The independent question, asked once per family that has a gateway. `-c 2` and
# a short deadline: this runs daily and is a liveness question, not a latency
# one — #166's blackbox probes own latency.
probe_family() {
  local fam="$1" cmd target
  if [[ "$fam" == inet6 ]]; then cmd=ping6; target="$PROBE6"; else cmd=ping; target="$PROBE4"; fi
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
       "$cmd -c 2 -t 5 $target >/dev/null 2>&1"; then echo 1; else echo 0; fi
}

emit() {
  printf '# HELP homelab_gateway_status 1 when the firewall reports this gateway online.\n'
  printf '# TYPE homelab_gateway_status gauge\n'
  while read -r name family status loss delay; do
    [[ -n "$name" ]] || continue
    printf 'homelab_gateway_status{host="%s",gateway="%s",family="%s"} %s\n' \
      "$HOST_LABEL" "$name" "$family" "$([[ "$status" == online ]] && echo 1 || echo 0)"
  done <<<"$rows"

  printf '# HELP homelab_gateway_loss_ratio Packet loss the firewall measures to its monitor address.\n'
  printf '# TYPE homelab_gateway_loss_ratio gauge\n'
  while read -r name family status loss delay; do
    [[ -n "$name" && "$loss" != NaN ]] || continue
    printf 'homelab_gateway_loss_ratio{host="%s",gateway="%s",family="%s"} %s\n' \
      "$HOST_LABEL" "$name" "$family" "$(awk -v l="$loss" 'BEGIN{printf "%.4f", l/100}')"
  done <<<"$rows"

  printf '# HELP homelab_gateway_delay_seconds Round-trip delay the firewall measures to its monitor address.\n'
  printf '# TYPE homelab_gateway_delay_seconds gauge\n'
  while read -r name family status loss delay; do
    [[ -n "$name" && "$delay" != NaN ]] || continue
    printf 'homelab_gateway_delay_seconds{host="%s",gateway="%s",family="%s"} %s\n' \
      "$HOST_LABEL" "$name" "$family" "$(awk -v d="$delay" 'BEGIN{printf "%.6f", d/1000}')"
  done <<<"$rows"

  printf '# HELP homelab_gateway_forwarding 1 when the firewall can reach the internet over this address family.\n'
  printf '# TYPE homelab_gateway_forwarding gauge\n'
  for fam in $(printf '%s\n' "$rows" | awk '{print $2}' | sort -u); do
    printf 'homelab_gateway_forwarding{host="%s",family="%s"} %s\n' \
      "$HOST_LABEL" "$fam" "$(probe_family "$fam")"
  done
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
PROM="${TEXTFILE_DIR}/gateway-state-${HOST_LABEL}.prom"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
[[ -s "${tmp}" ]] || { rm -f "${tmp}"; die "rendered no metrics"; }
chmod 0644 "${tmp}"; mv -f "${tmp}" "${PROM}"
printf 'gateway-state host=%s gateways=%s\n' "$HOST_LABEL" "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
