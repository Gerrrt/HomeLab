#!/usr/bin/env bash
#
# Print the SNMP device inventory as tab-separated records:
#
#   <ip>  <auth>  <device>  <secret-key-name>
#
# The device list must live in exactly one place. It is currently spread across
# five: prometheus/targets/snmp.yaml (the real one), generator.yaml's auths:
# block, render-config.sh's REQUIRED array, secrets/observability.example.yaml,
# and the -e flags in the Makefile's snmp-generate target. Every new tool reads
# it from here instead of adding a sixth, and --check asserts the other copies
# still agree.
#
# The secret key name is derived, not stored: auth_pfsense -> SNMP_COMMUNITY_PFSENSE.
# That is what lets a fifth device be added without editing snmp-verify.sh or
# gen-secret.sh at all.
#
# Parsed with awk rather than PyYAML for the same reason image-for.sh is: this
# has to work before python or docker are guaranteed present, and the file's
# shape is already constrained by yamllint.
#
# Usage:
#   scripts/snmp-targets.sh            print the inventory
#   scripts/snmp-targets.sh --check    assert the other copies of the list agree

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGETS="${SNMP_TARGETS_FILE:-${REPO_ROOT}/stacks/observability/prometheus/targets/snmp.yaml}"
GENERATOR="${REPO_ROOT}/stacks/observability/snmp-exporter/generator.yaml"
RENDER="${REPO_ROOT}/scripts/render-config.sh"
EXAMPLE="${REPO_ROOT}/secrets/observability.example.yaml"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

[[ -f "${TARGETS}" ]] || die "no such targets file: ${TARGETS}"

# ---------------------------------------------------------------------------
# Parse
# ---------------------------------------------------------------------------
records="$(awk '
  /^- targets:/ {
    if (ip != "") print ip "\t" auth "\t" dev
    ip = ""; auth = ""; dev = ""
    if (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) ip = substr($0, RSTART, RLENGTH)
    next
  }
  /^[[:space:]]+auth:[[:space:]]/   { auth = $2 }
  /^[[:space:]]+device:[[:space:]]/ { dev  = $2 }
  END { if (ip != "") print ip "\t" auth "\t" dev }
' "${TARGETS}")"

[[ -n "${records}" ]] || die "no SNMP targets parsed out of ${TARGETS}"

inventory=""
while IFS=$'\t' read -r ip auth dev; do
  # A record missing a field means the file's shape changed under this parser.
  # Failing here is the whole point: silently dropping a device would mean a
  # rotation that verifies green with one device never contacted.
  [[ -n "${ip}" && -n "${auth}" && -n "${dev}" ]] \
    || die "incomplete target record in ${TARGETS} (ip='${ip}' auth='${auth}' device='${dev}')"
  [[ "${auth}" == auth_* ]] \
    || die "auth label '${auth}' in ${TARGETS} does not start with 'auth_', so no secret key name can be derived from it"

  suffix="${auth#auth_}"
  inventory+="${ip}"$'\t'"${auth}"$'\t'"${dev}"$'\t'"SNMP_COMMUNITY_${suffix^^}"$'\n'
done <<< "${records}"

if ((! CHECK)); then
  printf '%s' "${inventory}"
  exit 0
fi

# ---------------------------------------------------------------------------
# --check: the other copies of the list must agree
#
# Offline: no decryption, no network, no docker. Safe for CI and for
# `make validate`.
# ---------------------------------------------------------------------------
failed=0
note() { printf '\033[0;31m  mismatch\033[0m %s\n' "$*" >&2; failed=1; }

while IFS=$'\t' read -r ip auth dev var; do
  [[ -n "${ip}" ]] || continue

  grep -q "^[[:space:]]*${var}$" "${RENDER}" \
    || note "${dev} (${ip}): ${var} is missing from the REQUIRED array in scripts/render-config.sh"

  grep -q "^${var}:" "${EXAMPLE}" \
    || note "${dev} (${ip}): ${var} is missing from secrets/observability.example.yaml"

  # The generator must have a matching auth block whose community is the
  # placeholder — not a literal, and not a different device's placeholder.
  # An unset variable here renders `community:` with nothing after it, which
  # render-config.sh's placeholder grep cannot catch because there is no
  # placeholder left to find. That path fails open, so it is checked here.
  awk -v want="${auth}:" -v ph="\${${var}}" '
    $1 == want            { inblock = 1; next }
    inblock && $1 == "community:" { found = ($2 == ph); exit }
    inblock && /^[^[:space:]]/    { exit }
    END { exit(found ? 0 : 1) }
  ' "${GENERATOR}" \
    || note "${dev} (${ip}): generator.yaml has no '${auth}:' block with 'community: \${${var}}'"
done <<< "${inventory}"

((failed == 0)) || exit 1
printf 'snmp inventory consistent (%s devices)\n' "$(printf '%s' "${inventory}" | grep -c .)"
