#!/usr/bin/env bash
#
# Walk one OID subtree on one SNMP device, the way snmp-exporter would, without
# the community ever appearing in an argument vector.
#
# This exists for the MokerLink switch. It has locked up under exporter polling
# before, and it returns at least one malformed varbind (ifTable column 22) that
# makes snmp-exporter discard a whole GETBULK response — so a new column is not
# something to add to generator.yaml and hope. It is something to fetch first,
# with the request shape the exporter will use, and read.
#
# What "the request shape the exporter will use" means here:
#
#   * GETBULK, never GET or GETNEXT. The switch drops both silently, and
#     net-snmp's snmpbulkwalk falls back to a plain GET when a subtree comes
#     back empty — so an OID the switch does not implement would present as a
#     21-second timeout, indistinguishable from the switch having wedged. This
#     script loops snmpbulkget by hand instead and never sends a GET.
#   * max-repetitions, timeout and retries default to the mokerlink module's
#     values (5, 7s, 2). A gentler probe would prove nothing about the load the
#     exporter is about to apply.
#   * Varbinds past the end of the subtree are printed rather than hidden.
#     GETBULK does not stop at a subtree boundary, so the last request of a
#     walk overshoots into whatever comes next, and the exporter has to decode
#     those varbinds too. They are the ones that bite; you want to see them.
#
# The community reaches net-snmp through a defCommunity line in an snmp.conf
# under SNMPCONFPATH, exactly as scripts/snmp-verify.sh does, so it is never in
# argv, shell history or /proc/<pid>/cmdline. stderr is captured to a file and
# classified, never printed: on a config parse error net-snmp echoes the
# offending line, and that line is the community.
#
# Do not add a --debug flag that passes -d to snmpbulkget: it prints the
# community in hex. `bash -x` on this script leaks it too.
#
# Usage:
#   scripts/snmp-walk.sh --device neo 1.3.6.1.2.1.31.1.1.1.6
#   scripts/snmp-walk.sh --device neo --max-repetitions 1 <oid>   one packet
#   scripts/snmp-walk.sh --device neo --dry-run <oid>             no decrypt, no packets

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="observability"

# shellcheck source=secrets-env.sh
source "${REPO_ROOT}/scripts/secrets-env.sh"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*" >&2; }

# Defaults mirror the mokerlink module in snmp-exporter/generator.yaml.
MAX_REPETITIONS=5
TIMEOUT=7
RETRIES=2
# A hard ceiling on requests, so a device that answers with the same OID
# forever cannot turn this into a loop. 200 requests at max-repetitions 5 is a
# thousand varbinds, several times any column this was written for.
MAX_REQUESTS=200

DRY_RUN=0
ONLY_DEVICE=""
ROOT=""

while (($#)); do
  case "$1" in
    --device)          ONLY_DEVICE="${2:?--device needs a name or IP}"; shift 2 ;;
    --max-repetitions) MAX_REPETITIONS="${2:?--max-repetitions needs a number}"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                die "unknown argument: $1" ;;
    *)
      [[ -z "${ROOT}" ]] || die "only one OID may be given (got '${ROOT}' and '$1')"
      ROOT="$1"; shift ;;
  esac
done

[[ -n "${ONLY_DEVICE}" ]] || die "--device is required (a name or IP from prometheus/targets/snmp.yaml)"
[[ -n "${ROOT}" ]] || die "an OID to walk is required, e.g. 1.3.6.1.2.1.31.1.1.1.6"
[[ "${ROOT}" =~ ^\.?[0-9]+(\.[0-9]+)+$ ]] || die "'${ROOT}' is not a numeric OID"
[[ "${MAX_REPETITIONS}" =~ ^[1-9][0-9]*$ ]] || die "--max-repetitions must be a positive integer"
ROOT="${ROOT#.}"

# ---------------------------------------------------------------------------
# Inventory — one device, resolved through the same list snmp-verify.sh uses,
# so the secret's variable name is derived from the inventory rather than typed.
# ---------------------------------------------------------------------------
INVENTORY="$("${REPO_ROOT}/scripts/snmp-targets.sh")"
INVENTORY="$(awk -F'\t' -v d="${ONLY_DEVICE}" '$1 == d || $3 == d' <<< "${INVENTORY}")"
[[ -n "${INVENTORY}" ]] || die "no SNMP device matches '${ONLY_DEVICE}' (try a device name or IP from prometheus/targets/snmp.yaml)"
[[ "$(wc -l <<< "${INVENTORY}")" -eq 1 ]] || die "'${ONLY_DEVICE}' matches more than one device"

IFS=$'\t' read -r IP AUTH DEVICE VAR <<< "${INVENTORY}"

if ((DRY_RUN)); then
  printf '\n\033[1m%s\033[0m\n' "SNMP walk (dry run — nothing decrypted, no packets sent)"
  printf '  %-12s %-16s %-16s %s\n' "${DEVICE}" "${IP}" "${AUTH}" "${VAR}"
  printf '  oid %s  max-repetitions %s  timeout %ss  retries %s\n\n' \
    "${ROOT}" "${MAX_REPETITIONS}" "${TIMEOUT}" "${RETRIES}"
  exit 0
fi

command -v snmpbulkget >/dev/null 2>&1 || die "snmpbulkget not found. Install the net-snmp client tools:
  Debian/Ubuntu:  sudo apt install snmp
  RHEL/Fedora:    sudo dnf install net-snmp-utils"

# ---------------------------------------------------------------------------
# Scratch space, as in snmp-verify.sh: tmpfs preferred so the plaintext never
# reaches a block device; 0700 directory, 0600 files, removed on every exit.
# ---------------------------------------------------------------------------
WORK=""
for base in /dev/shm "${TMPDIR:-/tmp}"; do
  [[ -d "${base}" && -w "${base}" ]] || continue
  WORK="$(mktemp -d "${base}/snmp-walk.XXXXXX")" && break
done
[[ -n "${WORK}" ]] || die "could not create a scratch directory in /dev/shm or ${TMPDIR:-/tmp}"
chmod 700 "${WORK}"
trap 'rm -rf "${WORK}"' EXIT INT TERM
umask 077

load_secrets "${STACK}"

COMMUNITY="${!VAR:-}"
[[ -n "${COMMUNITY}" ]] || die "${VAR} is empty in secrets/${STACK}.sops.yaml"
[[ "${COMMUNITY}" != *[[:space:]]* && "${COMMUNITY}" != *'#'* ]] || die \
  "${VAR} contains whitespace or '#', which net-snmp's snmp.conf parser cannot represent."
printf 'defCommunity %s\n' "${COMMUNITY}" > "${WORK}/snmp.conf"
chmod 600 "${WORK}/snmp.conf"
unset COMMUNITY

# ---------------------------------------------------------------------------
# The walk. Each request asks for the varbinds after `next`; the reply is
# printed verbatim (numeric OIDs, -Oqn), and `next` becomes the last OID
# returned. The walk is over when that OID is outside the root, when the device
# has nothing more, or when it stops answering.
#
# stderr goes to a file and is classified by substring, never printed and never
# passed to sed — either would put the defCommunity line into an argument
# vector or the terminal on a parse error.
# ---------------------------------------------------------------------------
info "${DEVICE} (${IP}) GETBULK ${ROOT} max-repetitions ${MAX_REPETITIONS} timeout ${TIMEOUT}s retries ${RETRIES}"

next="${ROOT}"
requests=0
rows=0
overshoot=0
ended=""
start="$(date +%s.%N)"

while ((requests < MAX_REQUESTS)); do
  requests=$((requests + 1))
  rc=0
  out="$(timeout $(( (RETRIES + 1) * TIMEOUT + 5 )) env MIBS= SNMPCONFPATH="${WORK}" \
          snmpbulkget -v2c -t "${TIMEOUT}" -r "${RETRIES}" -Cn0 -Cr"${MAX_REPETITIONS}" -Oqn \
          "${IP}" "${next}" 2>"${WORK}/err")" || rc=$?

  if ((rc != 0)); then
    if grep -q 'Timeout' "${WORK}/err"; then
      ended="timeout"
    elif ((rc == 124)); then
      ended="timeout (outer)"
    else
      ended="error rc=${rc}"
    fi
    break
  fi

  [[ -n "${out}" ]] || { ended="empty reply"; break; }

  last=""
  while IFS= read -r line; do
    printf '%s\n' "${line}"
    oid="${line%% *}"; oid="${oid#.}"
    if [[ "${line}" == *"No more variables left in this MIB View"* ]]; then
      ended="end of MIB"
    elif [[ "${oid}" == "${ROOT}."* ]]; then
      rows=$((rows + 1))
    else
      overshoot=$((overshoot + 1))
    fi
    last="${oid}"
  done <<< "${out}"

  [[ -n "${ended}" ]] && break
  [[ "${last}" == "${ROOT}."* ]] || { ended="left the subtree"; break; }
  [[ "${last}" != "${next}" ]] || { ended="no progress (device returned the request OID)"; break; }
  next="${last}"
done
[[ -n "${ended}" ]] || ended="request ceiling (${MAX_REQUESTS}) reached"

elapsed="$(awk -v s="${start}" -v e="$(date +%s.%N)" 'BEGIN { printf "%.2f", e - s }')"
info "rows in subtree: ${rows}  overshoot varbinds: ${overshoot}  requests: ${requests}  elapsed: ${elapsed}s  ended: ${ended}"

# 0: walked it. 2: answered, but nothing lives under that OID — the device does
# not implement it, which is a finding, not a fault. 1: did not answer cleanly.
case "${ended}" in
  "left the subtree"|"end of MIB") ((rows > 0)) && exit 0 || exit 2 ;;
  *) exit 1 ;;
esac
