#!/usr/bin/env bash
#
# The TrueNAS version this NAS runs, as a metric (#616).
#
# THE SAME HOLE AS PROXMOX, ONE HOST OVER. check_versions.py compares what the
# documents say each host runs against what the host reports. The documents say
# `smaug` runs "TrueNAS 25.10", and nothing on the wire carried that number:
#
#     node_os_info      Debian GNU/Linux 12 (bookworm)   the base SCALE is built on
#     node_uname_info   6.12.105-production+truenas      the KERNEL, not the product
#
# So every weekly run compared "TrueNAS 25.10" against "Debian 12" and failed,
# on a host where both statements are true. scripts/collect-pve-version.sh is
# the answer #311 gave Saruman; this is the same answer for this host, and
# check_versions.py prefers its series over node_os_info for the same reason.
#
# WHERE IT RUNS, which #616 asked to be decided rather than assumed. Not as an
# agent unit: `smaug` has no Alloy, and a TrueNAS update replaces the root, so
# a systemd unit dropped into it would not survive the first upgrade. Not
# pulled from the monitoring host either: the one path in, `10.0.99.20 →
# 10.0.40.30:22` as `frodo`, was written for the backup pull and nothing else
# (ADR-0045), and widening a key's job one read at a time is how it stops
# meaning anything. So it runs where SMART does (ADR-0047) — a root cron job in
# TrueNAS's own UI, the script on the pool beside compose.yaml — and writes into
# the directory node_exporter already bind-mounts at /textfile. The job lives in
# TrueNAS's config database and the script on `erebor`, so an upgrade touches
# neither; the series rides the scrape that already exists; nothing on
# CasaBonita initiates anything. build-the-nas.md §6.7 is the procedure.
#
# THE SOURCE. /etc/version carries the product version on TrueNAS SCALE and
# nothing else — read off `smaug` on 2026-09-22 as `25.10.7`, seven bytes, no
# trailing newline, world-readable. /etc/os-release describes the Debian base
# and is exactly what this exists to stop being compared.
#
# NO ROOT. The read needs none. The cron job runs as root only because the
# textfile directory is root-owned 0755 — the incidental reason
# collect-pve-version.sh gives for the same thing.
#
# Usage: scripts/collect-truenas-version.sh [--print] [--host NAME]
#        scripts/collect-truenas-version.sh --self-test
#
#   --host NAME   the `host` label; defaults to `hostname`. On smaug pass
#                 `--host smaug`, as the SMART job does, so the label matches
#                 the scrape's instance rather than whatever TrueNAS calls itself.
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/truenas-version.prom"
VERSION_FILE="${VERSION_FILE:-/etc/version}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# A TrueNAS SCALE version: two to four dotted numbers, optionally a pre-release
# suffix — `25.10.7`, `25.04.2.4`, `25.10-RC.1`, `26.04-BETA.1`. Anything else
# FAILS carrying the raw string rather than emitting a number this guessed:
# a wrong version in Prometheus is a check that passes for the wrong reason.
#
# Prints "<version> <release>", release being the first two components — the
# line the documents record ("TrueNAS 25.10") and check_versions.py compares
# on. Both go on the metric: the version because it is the fact, the release
# because it is the claim.
parse_version() {
  local raw
  raw="$(tr -d '[:space:]' <<<"$1")"
  [[ ${raw} =~ ^([0-9]+\.[0-9]+)(\.[0-9]+){0,2}(-[A-Za-z]+(\.[0-9]+)?)?$ ]] || return 1
  printf '%s %s\n' "${raw}" "${BASH_REMATCH[1]}"
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" expect="$2" raw="$3" got
    got="$(parse_version "$raw" || printf '<refused>')"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s -> %s\n' "$name" "$got"
    else
      printf '\033[0;31m  FAIL\033[0m %s -> %s, expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  # The file as read off smaug: no trailing newline.
  check "smaug on 2026-09-22"          "25.10.7 25.10"        "25.10.7"
  check "with a trailing newline"      "25.10.7 25.10"        $'25.10.7\n'
  check "a four-part point release"    "25.04.2.4 25.04"      "25.04.2.4"
  check "a bare release"               "25.10 25.10"          "25.10"
  check "a release candidate"          "25.10-RC.1 25.10"     "25.10-RC.1"
  # Refusals. CORE's old form names a different product line, and an empty or
  # prose file is a TrueNAS this parse has not met — say so, do not guess.
  check "TrueNAS CORE's form"          "<refused>"            "TrueNAS-13.0-U6.1"
  check "empty"                        "<refused>"            ""
  check "one number"                   "<refused>"            "25"
  check "prose"                        "<refused>"            "TrueNAS SCALE 25.10.7"
  exit $fail
fi

PRINT_ONLY=0
HOST_LABEL=""
while (($#)); do
  case "$1" in
    --print) PRINT_ONLY=1; shift ;;
    --host)  HOST_LABEL="${2:-}"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
: "${HOST_LABEL:=$(hostname)}"
[[ ${HOST_LABEL} =~ ^[A-Za-z0-9._-]+$ ]] || die "--host must be a plain name, got '${HOST_LABEL}'"

[[ -r ${VERSION_FILE} ]] \
  || die "no readable ${VERSION_FILE} — this is not TrueNAS SCALE.
This collector covers TrueNAS only; see the header."

raw="$(<"${VERSION_FILE}")"
parsed="$(parse_version "${raw}")" || die "could not read a TrueNAS version from ${VERSION_FILE}, which holds:
  ${raw}
Fix the parse in scripts/collect-truenas-version.sh rather than letting this
emit a number it guessed."
version="${parsed% *}"
release="${parsed#* }"

emit() {
  cat <<EOF
# HELP truenas_version_info The TrueNAS version this NAS runs, from /etc/version.
# TYPE truenas_version_info gauge
truenas_version_info{host="${HOST_LABEL}",version="${version}",release="${release}"} 1
EOF
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'truenas-version host=%s version=%s release=%s\n' "${HOST_LABEL}" "${version}" "${release}"
