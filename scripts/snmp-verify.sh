#!/usr/bin/env bash
#
# Check that every SNMP device answers to the community currently in SOPS —
# and, with --old, that it no longer answers to the previous one.
#
# This replaces the hand-typed snmpwalk block that used to be step 3 of
# docs/runbooks/rotate-snmp-community.md:
#
#   snmpwalk -v2c -c '<new-community>' 10.0.99.1 1.3.6.1.2.1.1.1.0
#
# repeated once per device. That put a live credential into the operator's
# shell history and, for the lifetime of the process, into /proc/<pid>/cmdline,
# which is world-readable — any local user running `ps` gets it. Here the
# community reaches net-snmp through a defCommunity line in an snmp.conf under
# SNMPCONFPATH instead, so it never appears in an argument vector.
#
# What this does NOT fix: SNMPv2c still sends the community in cleartext in
# every packet. Distinct per-device communities limit the blast radius of a
# captured poll; they do not make the protocol secure. SNMPv3 authPriv is
# tracked in docs/roadmap.md, blocked on the MokerLink switch not supporting it.
#
# Do not add a --debug flag that passes -d to snmpget: it prints the community
# in hex. `bash -x` on this script leaks it too, which no amount of care here
# can prevent.
#
# Usage:
#   scripts/snmp-verify.sh                  every device, current community
#   scripts/snmp-verify.sh --device neo     one device (name or IP)
#   scripts/snmp-verify.sh --old            also check the old one is refused
#   scripts/snmp-verify.sh --dry-run        show the mapping; no decrypt, no packets

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="observability"

# shellcheck source=secrets-env.sh
source "${REPO_ROOT}/scripts/secrets-env.sh"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() { printf '\033[0;33m  SKIP\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# sysDescr, as a node and as the instance GETBULK returns for it.
SYSDESCR_NODE='1.3.6.1.2.1.1.1'
SYSDESCR_OID='.1.3.6.1.2.1.1.1.0'

FAILED=0
CHECK_OLD=0
DRY_RUN=0
ONLY_DEVICE=""

while (($#)); do
  case "$1" in
    --old)     CHECK_OLD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --device)  ONLY_DEVICE="${2:?--device needs a name or IP}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------
INVENTORY="$("${REPO_ROOT}/scripts/snmp-targets.sh")"

if [[ -n "${ONLY_DEVICE}" ]]; then
  INVENTORY="$(awk -F'\t' -v d="${ONLY_DEVICE}" '$1 == d || $3 == d' <<< "${INVENTORY}")"
  [[ -n "${INVENTORY}" ]] || die "no SNMP device matches '${ONLY_DEVICE}' (try a device name or IP from prometheus/targets/snmp.yaml)"
fi

if ((DRY_RUN)); then
  head_ "SNMP inventory (dry run — nothing decrypted, no packets sent)"
  while IFS=$'\t' read -r ip auth device var; do
    [[ -n "${ip}" ]] || continue
    printf '  %-12s %-16s %-12s %s\n' "${device}" "${ip}" "${auth}" "${var}"
  done <<< "${INVENTORY}"
  printf '\n'
  exit 0
fi

command -v snmpget >/dev/null 2>&1 || die "snmpget not found. Install the net-snmp client tools:
  Debian/Ubuntu:  sudo apt install snmp
  RHEL/Fedora:    sudo dnf install net-snmp-utils"

# ---------------------------------------------------------------------------
# Scratch space for the per-device snmp.conf files.
#
# net-snmp takes the community from -c (argv, world-readable for the whole run)
# or from a defCommunity line in an snmp.conf. SNMPCONFPATH replaces net-snmp's
# entire config search path, so one directory per device means each snmpget
# sees exactly one community and cannot inherit a stray defCommunity from
# /etc/snmp/snmp.conf or ~/.snmp/snmp.conf.
#
# /dev/shm is preferred because it is tmpfs: the plaintext never reaches a
# block device, so it cannot be recovered from unallocated space afterwards.
# TMPDIR is the fallback and is usually disk-backed — worth knowing, not worth
# refusing to run over, and no worse than .rendered/snmp.yaml, which holds all
# four of these at 0600 permanently.
#
# Residual risk, stated plainly: for the duration of this run the communities
# exist as 0600 files in a 0700 directory. root can read them, as can anything
# that can ptrace this process.
# ---------------------------------------------------------------------------
WORK=""
for base in /dev/shm "${TMPDIR:-/tmp}"; do
  [[ -d "${base}" && -w "${base}" ]] || continue
  WORK="$(mktemp -d "${base}/snmp-verify.XXXXXX")" && break
done
[[ -n "${WORK}" ]] || die "could not create a scratch directory in /dev/shm or ${TMPDIR:-/tmp}"
chmod 700 "${WORK}"
# Covers every exit path, not just the checked failures: a set -e abort, a
# Ctrl-C mid-run, a SIGTERM. Same reasoning as bootstrap.sh.
trap 'rm -rf "${WORK}"' EXIT INT TERM
umask 077

load_secrets "${STACK}"

# ---------------------------------------------------------------------------
# write_conf <dir> <community>
#
# defCommunity takes the rest of the line, so a community containing whitespace
# or a '#' is silently truncated or commented out — which presents as the
# device rejecting a string you know is correct. Refuse instead. The value is
# never echoed; only the key name that holds it.
# ---------------------------------------------------------------------------
write_conf() {
  local dir="$1" community="$2" label="$3"
  [[ -n "${community}" ]] || die "${label} is empty in secrets/${STACK}.sops.yaml"
  [[ "${community}" != *[[:space:]]* && "${community}" != *'#'* ]] || die \
    "${label} contains whitespace or '#', which net-snmp's snmp.conf parser cannot represent.
Regenerate it with scripts/gen-secret.sh and set it on the device."
  mkdir -p "${dir}"
  printf 'defCommunity %s\n' "${community}" > "${dir}/snmp.conf"
  chmod 600 "${dir}/snmp.conf"
}

# ---------------------------------------------------------------------------
# probe <ip> <conf_dir> <retries>
#
# Sets PROBE_STATUS to ok | noresponse | nosuchobject | error, and PROBE_DETAIL
# to something safe to print.
#
# GETBULK, not GET. The MokerLink switch answers GETBULK and silently drops both
# GET and GETNEXT, so a GET-based probe times out against it no matter which
# community is used. That is not merely a cosmetic FAIL: --old infers "rejected"
# from a timeout, so a probe the device never answers would report every
# community as refused, including one that still works. The check would agree
# with the operator instead of testing them, which is the one thing this script
# exists not to do.
#
# One GETBULK with non-repeaters 0 and max-repetitions 1 is a single round trip
# returning a single varbind — the same cost as the GET it replaces. All four
# devices are SNMPv2c and all four answer it.
#
# It is aimed at the sysDescr *node*, not sysDescr.0, because GETBULK is
# GETNEXT-shaped: asking for 1.3.6.1.2.1.1.1 returns 1.3.6.1.2.1.1.1.0. The
# returned OID is then asserted, because unlike GET, a GETBULK against a device
# with no sysDescr does not raise an error — it just returns whatever comes
# next, which would otherwise be reported as a pass carrying the wrong value.
#
# MIBS= disables MIB loading: the OID is numeric, and a partial MIB directory
# on the operator's host otherwise prints twenty lines of parse warnings that
# make a pass look like a failure.
#
# -t 2: two-second timeout. SNMP is UDP, so a single dropped packet is not a
# rotation failure — hence one retry for the current check. The outer `timeout`
# is belt and braces for snmpget wedging on something other than the exchange.
# ---------------------------------------------------------------------------
probe() {
  local ip="$1" conf_dir="$2" retries="$3" out rc=0
  PROBE_STATUS=""; PROBE_DETAIL=""

  out="$(timeout 15 env MIBS= SNMPCONFPATH="${conf_dir}" \
          snmpbulkget -v2c -t 2 -r "${retries}" -Cn0 -Cr1 -Oqn \
          "${ip}${SNMP_VERIFY_PORT:+:${SNMP_VERIFY_PORT}}" \
          "${SYSDESCR_NODE}" 2>&1)" || rc=$?

  # net-snmp can echo an offending config line on a parse error, and that line
  # is the defCommunity line. So `out` is classified and then discarded — it is
  # never printed, and never passed to sed for redaction either, because that
  # would put the community into sed's own argument vector.
  if ((rc == 0)) && [[ "${out}" == "${SYSDESCR_OID} "* ]]; then
    PROBE_STATUS="ok"
    PROBE_DETAIL="$(printf '%s' "${out#"${SYSDESCR_OID} "}" | tr -cd '[:print:]' | cut -c1-60)"
  elif ((rc == 0)) && [[ -n "${out}" ]]; then
    # Answered, but the varbind after the sysDescr node is something else.
    PROBE_STATUS="nosuchobject"
  elif [[ "${out}" == *"Timeout"* ]]; then
    PROBE_STATUS="noresponse"
  else
    PROBE_STATUS="error"
    PROBE_DETAIL="rc=${rc}"
  fi
}

# ---------------------------------------------------------------------------
# Current communities
# ---------------------------------------------------------------------------
head_ "Current community"

PASSED_DEVICES=""
while IFS=$'\t' read -r ip auth device var; do
  [[ -n "${ip}" ]] || continue
  conf_dir="${WORK}/cur-${device}"
  write_conf "${conf_dir}" "${!var:-}" "${var}"
  probe "${ip}" "${conf_dir}" 1

  case "${PROBE_STATUS}" in
    ok)
      pass "$(printf '%-10s %-12s %s' "${device}" "${ip}" "${PROBE_DETAIL}")"
      PASSED_DEVICES+="${device}"$'\n'
      ;;
    nosuchobject)
      fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "answered, but does not implement sysDescr.0")"
      ;;
    noresponse)
      fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "no response (wrong community, filtered, or down)")"
      ;;
    *)
      fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "unexpected snmpget failure (${PROBE_DETAIL})")"
      ;;
  esac
done <<< "${INVENTORY}"

# ---------------------------------------------------------------------------
# Old community
# ---------------------------------------------------------------------------
if ((CHECK_OLD)); then
  # A terminal is required. Accepting the old community on stdin would let
  # someone write `echo "$old" | scripts/snmp-verify.sh --old`, putting it into
  # their shell history — the exact leak this script exists to close.
  [[ -t 0 ]] || die "--old needs a terminal: it reads the old community without echoing it"
  printf 'Old community (not echoed; written only to a 0600 file that is deleted on exit): ' >&2
  IFS= read -rs OLD_COMMUNITY
  printf '\n' >&2
  [[ -n "${OLD_COMMUNITY}" ]] || die "no old community entered"

  head_ "Old community (must be refused)"
  write_conf "${WORK}/old" "${OLD_COMMUNITY}" "the old community"

  while IFS=$'\t' read -r ip auth device var; do
    [[ -n "${ip}" ]] || continue

    # Only devices that just answered to their current community are checked.
    #
    # SNMPv2c has no "wrong community" reply — a device that rejects you simply
    # drops the packet. So a timeout is indistinguishable from "the device is
    # down", "a firewall dropped it", or "the IP is wrong". Against a device
    # that just answered, a timeout is genuinely a rejection; against anything
    # else it proves nothing, and reporting it as success would be this tool
    # agreeing with the operator rather than checking them.
    if ! grep -qxF "${device}" <<< "${PASSED_DEVICES}"; then
      skip "$(printf '%-10s %-12s %s' "${device}" "${ip}" "current-community check failed; a timeout here would prove nothing")"
      continue
    fi

    # -r 0: a timeout is the expected outcome, so retrying only doubles the wait.
    probe "${ip}" "${WORK}/old" 0

    case "${PROBE_STATUS}" in
      ok|nosuchobject)
        fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "STILL ACCEPTED — the device added the new community alongside the old one; delete the old entry")"
        ;;
      noresponse)
        pass "$(printf '%-10s %-12s %s' "${device}" "${ip}" "rejected")"
        ;;
      *)
        fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "unexpected snmpget failure (${PROBE_DETAIL})")"
        ;;
    esac
  done <<< "${INVENTORY}"
fi

printf '\n'
if ((FAILED)); then
  printf '\033[0;31msnmp verification failed\033[0m\n'
  exit 1
fi
printf '\033[0;32mall SNMP targets verified\033[0m\n'
