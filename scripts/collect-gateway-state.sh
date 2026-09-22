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
# THE DYNAMIC DNS RECORD, AS A COMPARISON (#604). ADR-0044 put the remote
# path's endpoint behind a record `morpheus` keeps current, and the WAN address
# is sticky — so a broken updater changes nothing visible until the one day the
# address moves, and on that day the operator is outside trying to get in. The
# question asked here is whether the name, as a PUBLIC resolver answers it,
# equals the address the WAN interface holds. The estate's own resolver would
# prove nothing: Unbound answers from its cache.
#
# The comparison runs ON THE FIREWALL. The hostname is on the withheld list and
# lives only in config.xml; the WAN address is withheld too. A script goes over
# ssh on stdin, reads both there, asks the resolver there, and prints one word.
# Neither value is in an argv, a variable or a log on this host, and the metric
# is that word as a boolean.
#
# "Could not compare" is kept apart from "does not match". A resolver that did
# not answer is a fact about the measurement, not about the record, and folding
# it into 0 would page for a stale record every time 1.1.1.1 blinked.
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
# The public resolver the record is asked of. An address, never a name: it is
# interpolated into the script the firewall runs, so it is checked for shape.
DDNS_RESOLVER="${GATEWAY_DDNS_RESOLVER:-1.1.1.1}"

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

# The verdict on one `drill NAME A` answer, given the WAN address as `wan`.
# Prints exactly one of match, stale or unchecked. It runs on the firewall and
# is kept here so --self-test exercises the same text. No single quotes in it:
# it travels inside a single-quoted shell assignment.
#
#   NOERROR, every A equals wan (after any CNAME)  match
#   NOERROR, any A differs, or no A at all         stale — deleted counts
#   NXDOMAIN                                       stale
#   SERVFAIL, REFUSED, no header (timeout)         unchecked
#
# An answer with one right A and one wrong one is stale: a peer picks either.
# shellcheck disable=SC2016  # awk's fields, not the shell's
DDNS_VERDICT_AWK='
  /^;; ->>HEADER<<-/ {
    for (i = 1; i <= NF; i++) if ($i == "rcode:") { rcode = $(i + 1); sub(/,$/, "", rcode) }
  }
  /^;; ANSWER SECTION:/ { inans = 1; next }
  inans && /^[[:space:]]*$/ { inans = 0 }
  inans && $4 == "A" { n++; if ($5 != wan) bad++ }
  END {
    if (rcode == "NXDOMAIN") print "stale"
    else if (rcode != "NOERROR") print "unchecked"
    else if (n == 0 || bad > 0) print "stale"
    else print "match"
  }
'

# The script the firewall runs for the comparison, on stdin to `sh -s`. It
# prints one word and nothing else. The PHP reads config.xml with pfSense's own
# config API and hands each enabled entry's name and interface address to the
# shell below it; both stay in that process on the firewall.
#
# The name is `host`, or `host.domainname` for the providers pfSense splits
# that way — the rule the Dynamic DNS status widget applies, reproduced because
# it is not in a shared include. `-v6` client types update AAAA records, which
# ADR-0044 decision 3 does not use, and are skipped.
remote_ddns_script() {
  printf "resolver='%s'\n" "$DDNS_RESOLVER"
  printf "verdict_awk='%s'\n" "$DDNS_VERDICT_AWK"
  cat <<'SH'
entries="$(/usr/local/bin/php 2>/dev/null <<'PHP'
<?php
require_once("config.inc");
require_once("interfaces.inc");
foreach (config_get_path('dyndnses/dyndns', []) as $e) {
  if (!isset($e['enable']) || empty($e['host']) || empty($e['interface'])) continue;
  if (substr($e['type'] ?? '', -3) === '-v6') continue;
  $name = empty($e['domainname']) ? $e['host'] : $e['host'] . '.' . $e['domainname'];
  echo $name, ' ', get_interface_ip($e['interface']), "\n";
}
PHP
)"
[ -n "$entries" ] || { echo unchecked; exit 0; }
result=match
while read -r name wan; do
  [ -n "$name" ] || continue
  if [ -z "$wan" ]; then
    v=unchecked
  else
    v="$(drill @"$resolver" "$name" A 2>/dev/null | awk -v wan="$wan" "$verdict_awk")"
  fi
  case "$v" in
    stale) result=stale ;;
    match) ;;
    *) [ "$result" = stale ] || result=unchecked ;;
  esac
done <<EOF
$entries
EOF
echo "$result"
SH
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

  # The record verdict, fed drill's output as FreeBSD prints it. Addresses and
  # names are documentation ones; the WAN address is 192.0.2.10 throughout.
  verdict() {
    local name="$1" expect="$2" got
    got="$(printf '%s\n' "$3" | awk -v wan=192.0.2.10 "$DDNS_VERDICT_AWK")"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  hdr() { printf ';; ->>HEADER<<- opcode: QUERY, rcode: %s, id: 4242\n;; flags: qr rd ra ; QUERY: 1, ANSWER: %s, AUTHORITY: 0, ADDITIONAL: 0\n;; QUESTION SECTION:\n;; home.example.net.\tIN\tA\n\n;; ANSWER SECTION:\n' "$1" "$2"; }
  tail_=$'\n;; AUTHORITY SECTION:\n\n;; ADDITIONAL SECTION:\n\n;; Query time: 13 msec\n;; SERVER: 198.51.100.53'
  verdict "record equals the WAN address" match \
    "$(hdr NOERROR 1)
home.example.net.	60	IN	A	192.0.2.10
${tail_}"
  verdict "record holds another address" stale \
    "$(hdr NOERROR 1)
home.example.net.	60	IN	A	198.51.100.7
${tail_}"
  verdict "a prefix of the WAN address is not a match" stale \
    "$(hdr NOERROR 1)
home.example.net.	60	IN	A	192.0.2.1
${tail_}"
  verdict "NXDOMAIN is a stale record, not a failed check" stale \
    "$(hdr NXDOMAIN 0)
${tail_}"
  verdict "NOERROR with no answer is a deleted record" stale \
    "$(hdr NOERROR 0)
${tail_}"
  verdict "SERVFAIL is a failed check" unchecked \
    "$(hdr SERVFAIL 0)
${tail_}"
  verdict "no reply at all is a failed check" unchecked ""
  verdict "a CNAME chain ending at the WAN address matches" match \
    "$(hdr NOERROR 2)
www.example.net.	300	IN	CNAME	home.example.net.
home.example.net.	60	IN	A	192.0.2.10
${tail_}"
  verdict "one right A and one wrong is stale" stale \
    "$(hdr NOERROR 2)
home.example.net.	60	IN	A	192.0.2.10
home.example.net.	60	IN	A	198.51.100.7
${tail_}"
  # An A record in the authority or additional section is not the answer.
  verdict "an A outside the answer section is ignored" stale \
    "$(hdr NOERROR 0)
;; AUTHORITY SECTION:

;; ADDITIONAL SECTION:
ns.example.net.	60	IN	A	192.0.2.10"

  # The firewall's script must at least parse as sh; it is never run here.
  if remote_ddns_script | sh -n 2>/dev/null; then
    printf '\033[0;32m  PASS\033[0m %s\n' "the firewall's script parses"
  else
    printf '\033[0;31m  FAIL\033[0m %s\n' "the firewall's script does not parse"; fail=1
  fi
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
[[ "$DDNS_RESOLVER" =~ ^[0-9A-Fa-f:.]+$ ]] || die "GATEWAY_DDNS_RESOLVER must be an address"

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

# The record comparison, on the firewall. Anything but the two words that are a
# verdict — ssh refused, a timeout, a script error — is `unchecked`, and none of
# it fails the gateway metrics above.
probe_ddns() {
  local v
  v="$(remote_ddns_script | timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 \
    "$SSH_TARGET" 'sh -s' 2>/dev/null | tail -1)"
  case "$v" in match|stale) echo "$v" ;; *) echo unchecked ;; esac
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

  local ddns; ddns="$(probe_ddns)"
  printf '# HELP homelab_ddns_record_checked 1 when the firewall could compare its dynamic DNS record with its WAN address. Carries no name and no address.\n'
  printf '# TYPE homelab_ddns_record_checked gauge\n'
  printf 'homelab_ddns_record_checked{host="%s"} %s\n' \
    "$HOST_LABEL" "$([[ "$ddns" == unchecked ]] && echo 0 || echo 1)"
  # Absent rather than 0 when the comparison did not run: a check that could
  # not ask must not read as a record that answered wrong.
  if [[ "$ddns" != unchecked ]]; then
    printf '# HELP homelab_ddns_record_matches_wan 1 when a public resolver answers the dynamic DNS name with the WAN address. Carries no name and no address.\n'
    printf '# TYPE homelab_ddns_record_matches_wan gauge\n'
    printf 'homelab_ddns_record_matches_wan{host="%s"} %s\n' \
      "$HOST_LABEL" "$([[ "$ddns" == match ]] && echo 1 || echo 0)"
  fi
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
PROM="${TEXTFILE_DIR}/gateway-state-${HOST_LABEL}.prom"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
[[ -s "${tmp}" ]] || { rm -f "${tmp}"; die "rendered no metrics"; }
chmod 0644 "${tmp}"; mv -f "${tmp}" "${PROM}"
printf 'gateway-state host=%s gateways=%s ddns=%s\n' "$HOST_LABEL" \
  "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" \
  "$(awk '/^homelab_ddns_record_matches_wan/ { print ($2 == 1 ? "match" : "stale"); f = 1 } END { if (!f) print "unchecked" }' "${PROM}")"
