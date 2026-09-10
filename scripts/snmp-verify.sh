#!/usr/bin/env bash
#
# Check that every SNMP device answers to the community currently in SOPS,
# that it refuses the stock communities `public` and `private` — and, with
# --old, that it no longer answers to the previous one.
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
# captured poll; they do not make the protocol secure. The estate is mixed on
# purpose (ADR-0036): a device whose auth block in generator.yaml is version 3
# is probed over SNMPv3 authPriv with the user and passphrases that block
# names, through the same snmp.conf route — and its --old check is still v2c,
# because "the old community is refused" is exactly the proof that v1/v2c
# access is off on a device that has moved.
#
# Do not add a --debug flag that passes -d to snmpget: it prints the community
# in hex. `bash -x` on this script leaks it too, which no amount of care here
# can prevent.
#
# Usage:
#   scripts/snmp-verify.sh                  every device: current community
#                                           answers, stock ones are refused
#   scripts/snmp-verify.sh --device neo     one device (name or IP)
#   scripts/snmp-verify.sh --old            also check the old ones are refused;
#                                           a stock community answering is FAIL
#                                           here, WARN in plain mode
#   scripts/snmp-verify.sh --dry-run        show the mapping; no decrypt, no packets

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="observability"

# shellcheck source=secrets-env.sh
source "${REPO_ROOT}/scripts/secrets-env.sh"
# shellcheck source=snmp-auth.sh
source "${REPO_ROOT}/scripts/snmp-auth.sh"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() { printf '\033[0;33m  SKIP\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m  WARN\033[0m %s\n' "$*"; WARNED=$((WARNED + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# sysDescr, as a node and as the instance GETBULK returns for it.
SYSDESCR_NODE='1.3.6.1.2.1.1.1'
SYSDESCR_OID='.1.3.6.1.2.1.1.1.0'

FAILED=0
WARNED=0
CHECK_OLD=0
DRY_RUN=0
ONLY_DEVICE=""

while (($#)); do
  case "$1" in
    --old)     CHECK_OLD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --device)  ONLY_DEVICE="${2:?--device needs a name or IP}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -/{/^set -/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# A terminal is required for --old. Accepting old communities on stdin would
# let someone write `echo "$old" | scripts/snmp-verify.sh --old`, putting them
# into their shell history — the exact leak this script exists to close.
# Checked here, before anything is decrypted or sent, so a pipe is refused
# outright rather than after two sections of output.
if ((CHECK_OLD)) && [[ ! -t 0 ]]; then
  die "--old needs a terminal: it reads the old communities without echoing them"
fi

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
  while IFS=$'\t' read -r ip auth device version keys; do
    [[ -n "${ip}" ]] || continue
    printf '  %-12s %-16s %-16s v%-3s %s\n' "${device}" "${ip}" "${auth}" "${version}" "${keys//,/ }"
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

# The snmp.conf itself is written by scripts/snmp-auth.sh: defCommunity for a
# v2c device, defSecurityName and the two passphrases for a v3 one, from the
# auth block in generator.yaml. Same refusal of whitespace and '#' in a value,
# same rule that the key is named and the value never is.

# ---------------------------------------------------------------------------
# probe <ip> <conf_dir> <retries>
#
# Sets PROBE_STATUS to ok | noresponse | nosuchobject | rejected | error, and
# PROBE_DETAIL to something safe to print.
#
# The version is not on the command line: the snmp.conf under SNMPCONFPATH
# carries defVersion, so the same invocation speaks v2c to one device and v3
# to the next. A -v here would override the file and silently probe a v3
# device as v2c.
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
# devices answer it, and GETBULK exists in v3 as it does in v2c.
#
# `rejected` is new with SNMPv3 and cannot happen over v2c: USM answers a
# wrong user, passphrase or protocol with a Report PDU, which net-snmp turns
# into a fixed phrase. Only that phrase is printed — see the note on `out`
# below. Over v2c a rejection is still a silent drop, i.e. `noresponse`.
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
          snmpbulkget -t 2 -r "${retries}" -Cn0 -Cr1 -Oqn \
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
  elif PROBE_DETAIL="$(snmp_classify_rejection "${out}")"; then
    PROBE_STATUS="rejected"
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
while IFS=$'\t' read -r ip auth device version keys; do
  [[ -n "${ip}" ]] || continue
  conf_dir="${WORK}/cur-${device}"
  snmp_write_conf "${conf_dir}" "${auth}"
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
      if [[ "${version}" == "3" ]]; then
        fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "no response (filtered, down, or SNMPv3 not enabled on the device)")"
      else
        fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "no response (wrong community, filtered, or down)")"
      fi
      ;;
    rejected)
      fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "rejected over SNMPv3: ${PROBE_DETAIL} — the user, a passphrase or a protocol differs from the device")"
      ;;
    *)
      fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "unexpected snmpget failure (${PROBE_DETAIL})")"
      ;;
  esac
done <<< "${INVENTORY}"

# ---------------------------------------------------------------------------
# Stock communities
#
# `public` and `private` are what every scanner tries first, and what a switch
# ships with. Found on `neo` on 2026-09-06 (#84): a test config rendered with
# an empty community — which gosnmp turns into `public` — returned a full
# scrape of the switch while the same config timed out against pfSense. Both
# strings answer there; the other three devices refuse both. Neither string is
# a secret, so unlike --old this needs no terminal and the weekly timer covers
# it.
#
# WARN in plain mode, FAIL under --old. The weekly run exits non-zero into
# ScheduledJobFailed, which stays firing until the job next succeeds — and
# retiring a row on `neo` needs a reboot window (#84), so a fatal result would
# keep that alert lit for weeks and hide any other verification failure behind
# it. --old is the operator proving a retirement, and there a stock row that
# still answers is exactly the thing being proved gone.
#
# Same precondition as --old: only devices that just answered their current
# community are checked. A device that never answered turns a refusal into a
# timeout that means nothing.
# ---------------------------------------------------------------------------
head_ "Stock communities (must be refused)"

STOCK_COMMUNITIES=(public private)
for stock in "${STOCK_COMMUNITIES[@]}"; do
  # Always v2c, like --old: on a device moved to SNMPv3 with v1 switched off,
  # "refuses public" over v2c is part of the proof that the move is complete.
  snmp_write_community_conf "${WORK}/stock-${stock}" "${stock}" "the stock community ${stock}"
done

while IFS=$'\t' read -r ip auth device version keys; do
  [[ -n "${ip}" ]] || continue

  if ! grep -qxF "${device}" <<< "${PASSED_DEVICES}"; then
    skip "$(printf '%-10s %-12s %s' "${device}" "${ip}" "current-community check failed; a timeout here would prove nothing")"
    continue
  fi

  accepted=""
  for stock in "${STOCK_COMMUNITIES[@]}"; do
    # -r 0: a timeout is the expected outcome, so retrying only doubles the wait.
    probe "${ip}" "${WORK}/stock-${stock}" 0
    case "${PROBE_STATUS}" in
      ok|nosuchobject) accepted+="${stock} " ;;
      noresponse) ;;
      *) fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "unexpected snmpget failure probing '${stock}' (${PROBE_DETAIL})")" ;;
    esac
  done

  if [[ -z "${accepted}" ]]; then
    pass "$(printf '%-10s %-12s %s' "${device}" "${ip}" "refuses ${STOCK_COMMUNITIES[*]}")"
  elif ((CHECK_OLD)); then
    fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "STOCK COMMUNITY ACCEPTED: ${accepted% } — overwrite the row (rotate-snmp-community.md §2.5)")"
  else
    warn "$(printf '%-10s %-12s %s' "${device}" "${ip}" "STOCK COMMUNITY ACCEPTED: ${accepted% } — not fatal in plain mode, see the comment above this check")"
  fi
done <<< "${INVENTORY}"

# ---------------------------------------------------------------------------
# Old community
# ---------------------------------------------------------------------------
if ((CHECK_OLD)); then
  head_ "Old community (must be refused)"

  # Asked for per device, not once. A single prompt was right when one community
  # was shared across all four; after a rotation each device has its own
  # predecessor, and testing one string against every device proves nothing
  # about the three it never belonged to. Enter is a skip, because the usual
  # case is checking one device you just rotated.
  printf '  Each device is asked separately. Press Enter to skip one.\n\n' >&2

  asked=0
  while IFS=$'\t' read -r ip auth device version keys; do
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

    # Read from the terminal explicitly: this loop's stdin is the inventory.
    printf '  old community for %-10s (not echoed, Enter to skip): ' "${device}" >&2
    IFS= read -rs old_one < /dev/tty
    printf '\n' >&2

    if [[ -z "${old_one}" ]]; then
      skip "$(printf '%-10s %-12s %s' "${device}" "${ip}" "not checked — no old community given")"
      continue
    fi
    asked=$((asked + 1))

    # Always v2c, whatever the device speaks now. On a device moved to v3
    # this is the check that matters: SNMPv1 switched off on the device means
    # the old community is refused here, and STILL ACCEPTED means it was not.
    snmp_write_community_conf "${WORK}/old-${device}" "${old_one}" "the old community for ${device}"
    old_one=""

    # -r 0: a timeout is the expected outcome, so retrying only doubles the wait.
    probe "${ip}" "${WORK}/old-${device}" 0

    case "${PROBE_STATUS}" in
      ok|nosuchobject)
        if [[ "${version}" == "3" ]]; then
          fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "STILL ACCEPTED over v2c — SNMPv1/v2c access is still enabled on the device; the move to v3 is not complete")"
        else
          fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "STILL ACCEPTED — the device added the new community alongside the old one; delete the old entry")"
        fi
        ;;
      noresponse)
        pass "$(printf '%-10s %-12s %s' "${device}" "${ip}" "rejected")"
        ;;
      *)
        fail "$(printf '%-10s %-12s %s' "${device}" "${ip}" "unexpected snmpget failure (${PROBE_DETAIL})")"
        ;;
    esac
  done <<< "${INVENTORY}"

  ((asked > 0)) || die "no old community entered for any device — nothing was checked"
fi

printf '\n'
if ((FAILED)); then
  printf '\033[0;31msnmp verification failed\033[0m\n'
  exit 1
fi
if ((WARNED)); then
  # Not a clean pass and not reported as one: the exit code is 0 for the reason
  # the stock-community comment gives, but the last line says what was found.
  printf '\033[0;33mall SNMP targets answer their community; %d stock-community warning(s) above\033[0m\n' "${WARNED}"
  exit 0
fi
printf '\033[0;32mall SNMP targets verified\033[0m\n'
