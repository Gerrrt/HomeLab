#!/usr/bin/env bash
#
# How far behind morpheus's packages are, as metrics (#378).
#
# THE GAP THIS CLOSES. patch-state covers every apt host in the estate —
# `prometheus` and `oracle` through apt-check, `Saruman` through the apt-get
# fallback (#377). `morpheus` is FreeBSD and has neither, so the one host where
# this matters most had nothing: docs/security.md names "a vulnerability in
# pfSense itself" as an accepted, undefended threat, and that is a reasonable
# position to hold deliberately and a much weaker one when nobody knows how far
# behind the firewall is.
#
# ONE COMMAND, TWO ANSWERS. #378 asked which signal this should be about and
# listed `pkg version -vRL=` and `pfSense-upgrade -c` as alternatives answering
# different questions. They do — but they do not need different commands,
# because pfSense ships the system itself as pkg meta-packages:
#
#     pfSense-2.9.0                  Main pfSense package
#     pfSense-base-2.9.0             pfSense core files
#     pfSense-kernel-pfSense-2.9.0   pfSense kernel
#
# So `pkg version -vRL=` reports both: the total number of packages behind the
# repository, and — if one of those three is among them — that a SYSTEM upgrade
# is available, which is the thing an operator actually acts on. Verified
# 2026-09-07: two packages behind, none of them a system package, and
# `pfSense-upgrade -c` independently said "Your system is up to date".
#
# Parsing `pfSense-upgrade -c`'s prose was the alternative and is worse: it is a
# shell wrapper whose human-readable output has no format contract, and reading
# "up to date" out of it would silently report "no update" the day that sentence
# is reworded.
#
# NO SECURITY COUNT, and this is a real difference from the apt hosts rather than
# an omission. FreeBSD's pkg has no security pocket, so there is no equivalent of
# homelab_apt_security_upgrades_pending. Emitting a zero would be worse than
# emitting nothing: it would read as "no security updates pending" when it
# actually means "this host cannot tell you".
#
# RUNS FROM THE MONITORING HOST over SSH, like smart-state-remote and for the
# same reason: morpheus has no node_exporter, no Alloy and no textfile directory
# of its own. The result is written into THIS host's textfile directory under
# host="morpheus", so those series carry instance="prometheus" — the accepted
# price of the host having no agent.
#
# IT UPDATES THE REPOSITORY CATALOGUE as a side effect: `pkg version -R` fetches
# metadata before comparing. That is a network fetch and a disk write on the
# firewall, which is why this is daily rather than hourly and why the unit's
# timeout is generous.
#
# Usage: scripts/collect-pkg-state.sh --ssh USER@HOST --host NAME [--print]
#        scripts/collect-pkg-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

PRINT_ONLY=0
SSH_TARGET=""
HOST_LABEL=""

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The lines that are actually package status, out of output that also carries
# catalogue-update chatter — and that chatter goes to STDOUT, not stderr, so it
# cannot be dropped with a redirect:
#
#     Updating pfSense repository catalogue...
#     Fetching meta.conf: . done
#     All repositories are up to date.
#     if_pppoe-kmod-2.9.0.1600018    <   needs updating (remote has 2.9.0.1600018_1)
#
# A status line is a package name, whitespace, then < or > . Nothing in the
# chatter has that shape.
#
# Separated out so --self-test can drive it: morpheus cannot be made to have a
# system upgrade pending on demand, and the one branch that matters most is the
# one that has never been observed live.
parse_pkg_version() {
  awk '
    $0 ~ /^[^ \t]+[ \t]+[<>][ \t]+/ {
      behind++
      # The system itself, as opposed to an add-on package. pfSense delivers it
      # as these three; any of them being behind means a system upgrade.
      if ($1 ~ /^pfSense-[0-9]/ || $1 ~ /^pfSense-base-[0-9]/ || $1 ~ /^pfSense-kernel-/) system_update = 1
    }
    END { printf "%d %d\n", behind+0, system_update+0 }
  '
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" expect="$2" got
    got="$(printf '%s\n' "$3" | parse_pkg_version)"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s -> %s\n' "$name" "$got"
    else
      printf '\033[0;31m  FAIL\033[0m %s -> %s, expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  NOISE="Updating pfSense-core repository catalogue...
Fetching meta.conf: . done
Processing entries: . done
pfSense repository update completed. 574 packages processed.
All repositories are up to date."

  check "catalogue chatter alone counts nothing" "0 0" "$NOISE"
  # The live state on 2026-09-07, which is the only case observable today.
  check "two add-on packages behind, no system update" "2 0" "${NOISE}
if_pppoe-kmod-2.9.0.1600018        <   needs updating (remote has 2.9.0.1600018_1)
pfSense-repoc-20260807.184806      <   needs updating (remote has 20260827.172430)"
  # The branch that matters and cannot be produced on demand.
  check "system upgrade available" "1 1" "${NOISE}
pfSense-2.9.0                      <   needs updating (remote has 2.9.1)"
  check "system base behind counts as a system update" "1 1" \
"pfSense-base-2.9.0                 <   needs updating (remote has 2.9.1)"
  check "system kernel behind counts as a system update" "1 1" \
"pfSense-kernel-pfSense-2.9.0       <   needs updating (remote has 2.9.1)"
  check "mixed: system update among add-ons" "3 1" \
"if_pppoe-kmod-2.9.0.1600018        <   needs updating (remote has 2.9.0.1600018_1)
pfSense-2.9.0                      <   needs updating (remote has 2.9.1)
pfSense-repoc-20260807.184806      <   needs updating (remote has 20260827.172430)"
  # pfSense-repoc starts with "pfSense-" and is NOT the system. Without the
  # digit anchor it would report a system upgrade on a host that has none, which
  # is the false positive that would make this alert untrustworthy.
  check "pfSense-repoc is not a system update" "1 0" \
"pfSense-repoc-20260807.184806      <   needs updating (remote has 20260827.172430)"
  # A package NEWER than the repo, which pkg marks with '>'. Counted as behind
  # is wrong, but it is still drift worth seeing, so it counts and does not
  # trigger the system flag unless it is a system package.
  check "locally newer package still counts as drift" "1 0" \
"some-pkg-9.9                       >   succeeds index (index has 1.0)"
  exit $fail
fi

while (($#)); do
  case "$1" in
    --print) PRINT_ONLY=1; shift ;;
    --ssh)   SSH_TARGET="${2:-}"; shift 2 ;;
    --host)  HOST_LABEL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^set -/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;/^set -/d'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

[[ -n "$SSH_TARGET" ]] || die "--ssh USER@HOST is required.

This collector reads a FreeBSD host from the monitoring host; there is no local
mode, because the only FreeBSD host here has no agent of its own. For apt hosts
use scripts/collect-patch-state.sh."
[[ -n "$HOST_LABEL" ]] || die "--ssh needs --host NAME for the label"

STDERR_FILE="$(mktemp)"
trap 'rm -f "${STDERR_FILE}"' EXIT

# Not ssh_q-style stdin closing: nothing is piped in, and stderr is captured so
# a failure reports why rather than looking like a host with no packages. That
# lesson cost three rounds on the SMART collector (#370).
raw="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
  'pkg version -vRL=' 2>"${STDERR_FILE}")"
rc=$?

if ((rc != 0)) || [[ -z "$raw" ]]; then
  detail="$(tr -d '\r' < "${STDERR_FILE}" | grep -v '^$' | tail -2 | paste -sd'; ' -)"
  die "could not read pkg status from ${SSH_TARGET}${detail:+ — ${detail}}
A catalogue fetch needs the firewall to reach its update servers; a WAN outage
looks exactly like this and is not a fault in the collector."
fi

read -r behind system_update <<<"$(printf '%s\n' "$raw" | parse_pkg_version)"
[[ "$behind" =~ ^[0-9]+$ && "$system_update" =~ ^[0-9]+$ ]] \
  || die "could not parse pkg output into counts"

# Installed total, for context rather than for an alert. Cheap, and it makes
# "behind" readable as a proportion rather than a bare number.
installed="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
  'pkg info | wc -l' 2>/dev/null | tr -d ' \r')"
[[ "$installed" =~ ^[0-9]+$ ]] || installed=0

emit() {
  cat <<EOF
# HELP homelab_pkg_upgrades_pending Packages whose installed version is behind the repository.
# TYPE homelab_pkg_upgrades_pending gauge
homelab_pkg_upgrades_pending{host="${HOST_LABEL}"} ${behind}
# HELP homelab_pkg_system_update_available 1 when a pfSense system package is behind the repository.
# TYPE homelab_pkg_system_update_available gauge
homelab_pkg_system_update_available{host="${HOST_LABEL}"} ${system_update}
# HELP homelab_pkg_installed_total Packages installed on this host.
# TYPE homelab_pkg_installed_total gauge
homelab_pkg_installed_total{host="${HOST_LABEL}"} ${installed}
EOF
}

if ((PRINT_ONLY)); then
  emit
  exit 0
fi

[[ -d "${TEXTFILE_DIR}" ]] \
  || die "no ${TEXTFILE_DIR} — run 'sudo ./scripts/install-timers.sh --install' first"

# Named after the host, and NOT after any job in install-timers.sh's JOBS table:
# run-scheduled.sh writes "${JOB}.prom" and would overwrite this, which is
# exactly what happened to the apt collector (#360).
PROM="${TEXTFILE_DIR}/pkg-state-${HOST_LABEL}.prom"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
[[ -s "${tmp}" ]] || { rm -f "${tmp}"; die "rendered no metrics for ${HOST_LABEL}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"

printf 'pkg-state host=%s behind=%s system_update=%s installed=%s\n' \
  "${HOST_LABEL}" "${behind}" "${system_update}" "${installed}"
