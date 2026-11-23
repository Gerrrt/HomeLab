#!/usr/bin/env bash
#
# Whether the NUT server on the firewall can read the UPS, as a metric.
#
# WHAT NOTHING WAS WATCHING. morpheus runs NUT's primary for `mjolnir`: its
# snmp-ups driver polls the card, and every secondary (Saruman, smaug, trinity)
# learns of a power cut only from it. From 2026-11-05 to 2026-11-07 the driver
# was not connected, upsmon logged it 23,048 times, and nothing raised a word
# (changelog, 2026-11-23). The card-silence alerts are about the card answering
# SNMP; they say nothing about NUT, and a driver that stays down while the card
# answers raises nothing at all. Loki does not fill the gap either: syslogd
# folds a repeated line into "last message repeated", so a driver down for
# days leaves one line, and a log rule's window has moved past it within
# minutes. The two Loki rules in loki/rules/ups.rules.yaml cover the short
# gaps; this covers the long one.
#
# So this asks NUT itself, the way a secondary does: `upsc mjolnir@127.0.0.1
# ups.status` on the firewall, over the ssh `make gateway-state` already makes.
# A status (OL, OB, LB, ...) is readable; anything else ("Error: Data stale",
# "Error: Driver not connected", no answer) is not. The reason goes to the job's
# output, not to a label, so the series keeps one identity and `for` works.
#
# "Could not ask" is kept apart from "NUT cannot read it": if ssh fails the run
# fails and writes nothing, and the job alerts (ScheduledJobFailed) instead of
# this one.
#
# Usage: scripts/collect-nut-state.sh --ssh USER@HOST --host NAME [--ups NAME] [--print]
#        scripts/collect-nut-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PRINT_ONLY=0
SSH_TARGET=""
HOST_LABEL=""
UPS="mjolnir"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# upsc's answer -> "1 <status>" or "0 <reason>". The answer is the remote
# output: the status line, or upsc's error, then "rc=N".
classify() {
  local answer="$1" first rc
  first="$(printf '%s\n' "$answer" | grep -v '^rc=' | head -1 | tr -d '\r')"
  rc="$(printf '%s\n' "$answer" | sed -n 's/^rc=//p' | tail -1)"
  if [[ "$rc" == 0 && "$first" =~ ^[A-Z]+( [A-Z]+)*$ ]]; then
    printf '1 %s\n' "$first"
  else
    first="${first#Error: }"
    printf '0 %s\n' "${first:-no answer}"
  fi
}

render() {
  local readable="$1"
  printf '# HELP homelab_nut_ups_readable 1 when the NUT server on this host can read the UPS (upsc returns a status).\n'
  printf '# TYPE homelab_nut_ups_readable gauge\n'
  printf 'homelab_nut_ups_readable{host="%s",ups="%s"} %s\n' "$HOST_LABEL" "$UPS" "$readable"
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  ok()  { printf '\033[0;32m  PASS\033[0m %s\n' "$1"; }
  bad() { printf '\033[0;31m  FAIL\033[0m %s\n' "$1"; fail=1; }
  same() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1"; printf '       got      %s\n       expected %s\n' "$2" "$3"; fi; }

  same "on line is readable"           "$(classify $'OL\nrc=0')"                          "1 OL"
  same "on battery, charging is readable" "$(classify $'OB DISCHRG\nrc=0')"              "1 OB DISCHRG"
  same "stale data is not"             "$(classify $'Error: Data stale\nrc=1')"           "0 Data stale"
  same "a driver not connected is not" "$(classify $'Error: Driver not connected\nrc=1')" "0 Driver not connected"
  same "no answer at all is not"       "$(classify 'rc=255')"                             "0 no answer"
  same "a status with a failing rc is not" "$(classify $'OL\nrc=1')"                      "0 OL"
  HOST_LABEL=morpheus
  same "the series" "$(render 0 | tail -1)" 'homelab_nut_ups_readable{host="morpheus",ups="mjolnir"} 0'
  exit $fail
fi

need_value() { [[ $2 -ge 2 && -n "$1" ]] || die "$3 needs a value"; }
while (($#)); do
  case "$1" in
    --print) PRINT_ONLY=1; shift ;;
    --ssh)   need_value "${2:-}" $# "$1"; SSH_TARGET="$2"; shift 2 ;;
    --host)  need_value "${2:-}" $# "$1"; HOST_LABEL="$2"; shift 2 ;;
    --ups)   need_value "${2:-}" $# "$1"; UPS="$2"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ -n "$SSH_TARGET" ]] || die "--ssh USER@HOST is required"
[[ "$HOST_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--host NAME is required"
# Interpolated into the command the firewall runs, so checked for shape.
[[ "$UPS" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--ups ${UPS@Q} is not a UPS name"

answer="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
  "upsc ${UPS}@127.0.0.1 ups.status 2>&1; echo rc=\$?" 2>/dev/null)"
[[ "$answer" == *rc=* ]] || die "could not ask NUT on ${SSH_TARGET}"

read -r readable detail <<<"$(classify "$answer")"
if ((PRINT_ONLY)); then render "$readable"; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
PROM="${TEXTFILE_DIR}/nut-state-${HOST_LABEL}.prom"
tmp="${PROM}.$$"
render "$readable" > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
{ chmod 0644 "${tmp}" && mv -f "${tmp}" "${PROM}"; } \
  || { rm -f "${tmp}"; die "could not install ${PROM}"; }
printf 'nut-state host=%s ups=%s readable=%s (%s)\n' "$HOST_LABEL" "$UPS" "$readable" "$detail"
