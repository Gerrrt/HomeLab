#!/usr/bin/env bash
#
# Print the SNMP device inventory as tab-separated records:
#
#   <ip>  <auth>  <device>  <version>  <secret-key-names>
#
# `version` is the SNMP version the device's auth block declares (2 or 3), and
# the last field is the comma-joined list of sops keys that credential needs:
# one community for v2c, an authentication and a privacy passphrase for v3.
#
# The device list must live in exactly one place. It is currently spread across
# five: prometheus/targets/snmp.yaml (the real one), generator.yaml's auths:
# block, render-config.sh's REQUIRED array, secrets/observability.example.yaml,
# and the -e flags in the Makefile's snmp-generate target. Every new tool reads
# it from here instead of adding a sixth, and --check asserts the other copies
# still agree.
#
# The secret key names are derived, not stored: auth_pfsense -> SNMP_COMMUNITY_PFSENSE,
# and for a v3 device auth_ilo -> SNMP_AUTHPASS_ILO,SNMP_PRIVPASS_ILO. Which of
# the two shapes applies is read out of the auth block in generator.yaml, the
# file the exporter itself reads (scripts/snmp-auth.sh, ADR-0036). That is
# what lets a fifth device be added, or a device moved to v3, without editing
# snmp-verify.sh or gen-secret.sh at all.
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
GENERATOR="${SNMP_GENERATOR_FILE:-${REPO_ROOT}/stacks/observability/snmp-exporter/generator.yaml}"
GENERATED="${REPO_ROOT}/stacks/observability/snmp-exporter/snmp.yaml"
RENDER="${REPO_ROOT}/scripts/render-config.sh"
EXAMPLE="${REPO_ROOT}/secrets/observability.example.yaml"

# shellcheck source=snmp-auth.sh
source "${REPO_ROOT}/scripts/snmp-auth.sh"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

[[ -f "${TARGETS}" ]] || die "no such targets file: ${TARGETS}"
[[ -f "${GENERATOR}" ]] || die "no such generator file: ${GENERATOR}"

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

  # snmp_auth_read dies on a block that is missing or has no usable version,
  # and snmp_auth_keys on a label no variable name can be made from — so the
  # inventory cannot be printed for a device the exporter could not poll.
  snmp_auth_read "${auth}"
  keys="$(snmp_auth_keys "${auth}")"
  inventory+="${ip}"$'\t'"${auth}"$'\t'"${dev}"$'\t'"${SNMP_AUTH_VERSION}"$'\t'"${keys}"$'\n'
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

# The field an auth block must hold for a given key, and the placeholder it
# must hold there. An unset variable renders the field with nothing after it,
# which render-config.sh's placeholder grep cannot catch because there is no
# placeholder left to find. That path fails open, so it is checked here — in
# generator.yaml, and again in the generated snmp.yaml, because the generator
# copies the auths block verbatim and a hand edit to one without the other is
# a config the exporter will poll with.
field_for() {
  case "$1" in
    SNMP_COMMUNITY_*) printf 'community' ;;
    SNMP_AUTHPASS_*)  printf 'password' ;;
    SNMP_PRIVPASS_*)  printf 'priv_password' ;;
    *) die "no auth field is known for key '$1'" ;;
  esac
}

block_has() {
  # block_has <file> <auth> <field> <value>: the auth block holds exactly
  # `<field>: <value>`, and not a literal, and not another device's value.
  awk -v want="${2}:" -v field="${3}:" -v value="$4" '
    $1 == want                { inblock = 1; next }
    inblock && $1 == field    { found = ($2 == value); exit }
    inblock && /^  [^ ]/      { exit }
    inblock && /^[^[:space:]]/ { exit }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

while IFS=$'\t' read -r ip auth dev version keys; do
  [[ -n "${ip}" ]] || continue

  snmp_auth_read "${auth}"
  if [[ "${version}" == "3" ]]; then
    # authPriv or nothing (ADR-0036). A v3 block that authenticates and then
    # sends the tables in clear has kept the cost of the move and given up
    # the benefit; a v3 block with no auth at all is v2c with more packets.
    [[ "${SNMP_AUTH_LEVEL}" == "authPriv" ]] \
      || note "${dev} (${ip}): ${auth} is version 3 with security_level '${SNMP_AUTH_LEVEL}'; ADR-0036 allows authPriv only"
    [[ -n "${SNMP_AUTH_USERNAME}" && "${SNMP_AUTH_USERNAME}" != "\${"* ]] \
      || note "${dev} (${ip}): ${auth} has no literal 'username:' — the USM user name is not a secret and belongs in generator.yaml"
    [[ "${SNMP_AUTH_AUTHPROTO}" =~ ^(MD5|SHA|SHA224|SHA256|SHA384|SHA512)$ ]] \
      || note "${dev} (${ip}): ${auth} has auth_protocol '${SNMP_AUTH_AUTHPROTO}'; snmp-exporter accepts MD5, SHA, SHA224, SHA256, SHA384 or SHA512"
    [[ "${SNMP_AUTH_PRIVPROTO}" =~ ^(DES|AES|AES192|AES256|AES192C|AES256C)$ ]] \
      || note "${dev} (${ip}): ${auth} has priv_protocol '${SNMP_AUTH_PRIVPROTO}'; snmp-exporter accepts DES, AES, AES192, AES192C, AES256 or AES256C"
    [[ -z "${SNMP_AUTH_COMMUNITY}" ]] \
      || note "${dev} (${ip}): ${auth} is version 3 and still carries a 'community:' line — a leftover from the v2c block, and a leftover placeholder render-config.sh will demand a value for"
  else
    [[ -z "${SNMP_AUTH_PASSWORD}${SNMP_AUTH_PRIVPASS}" ]] \
      || note "${dev} (${ip}): ${auth} is version ${version} and carries v3 passphrase fields; either the version is wrong or the fields are leftovers"
  fi

  IFS=, read -ra key_list <<< "${keys}"
  for var in "${key_list[@]}"; do
    grep -q "^[[:space:]]*${var}$" "${RENDER}" \
      || note "${dev} (${ip}): ${var} is missing from the REQUIRED array in scripts/render-config.sh"
    grep -q "^${var}:" "${EXAMPLE}" \
      || note "${dev} (${ip}): ${var} is missing from secrets/observability.example.yaml"
    field="$(field_for "${var}")"
    block_has "${GENERATOR}" "${auth}" "${field}" "\${${var}}" \
      || note "${dev} (${ip}): generator.yaml has no '${auth}:' block with '${field}: \${${var}}'"
    if [[ -f "${GENERATED}" ]]; then
      block_has "${GENERATED}" "${auth}" "${field}" "\${${var}}" \
        || note "${dev} (${ip}): snmp.yaml has no '${auth}:' block with '${field}: \${${var}}' — generator.yaml was edited without 'make snmp-generate'"
    fi
  done
done <<< "${inventory}"

((failed == 0)) || exit 1
printf 'snmp inventory consistent (%s devices)\n' "$(printf '%s' "${inventory}" | grep -c .)"
