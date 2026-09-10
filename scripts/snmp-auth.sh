#!/usr/bin/env bash
#
# One reader for the `auths:` blocks in snmp-exporter/generator.yaml, and one
# writer for the net-snmp snmp.conf that carries a device's credential.
# Sourced, not executed.
#
# This exists because the estate is mixed on purpose (ADR-0036): two devices
# are polled over SNMPv3 authPriv and two over SNMPv2c, and a device's shape —
# one community, or a user with two passphrases — is declared in exactly one
# place, the auth block the exporter itself reads. Every tool that needs to
# know derives it from there: snmp-targets.sh to name the secret keys,
# snmp-verify.sh and snmp-walk.sh to write a config net-snmp can use, and
# `make snmp-generate` to pass the placeholders through the generator. Before
# this file, "one community per device" was an assumption held in five scripts
# at once, and a v3 device would have had to be special-cased in each.
#
# Nothing here decrypts anything. The writer reads values out of variables the
# caller has already set with load_secrets (scripts/secrets-env.sh), by name,
# through ${!var}; the names are derived, the values are never echoed.
#
# Key names, derived from the auth label:
#
#   auth_ilo, version 2   ->  SNMP_COMMUNITY_ILO
#   auth_ilo, version 3   ->  SNMP_AUTHPASS_ILO  SNMP_PRIVPASS_ILO
#
# The SNMPv3 user name is not a secret and is not a key: USM sends it in the
# clear header of every message, so it stays in the tracked generator.yaml as
# a literal `username:`.
#
# Usage:
#   source "${REPO_ROOT}/scripts/snmp-auth.sh"
#   snmp_auth_read auth_ilo            # sets SNMP_AUTH_* from generator.yaml
#   snmp_auth_keys auth_ilo            # prints the secret key names, comma-joined
#   snmp_write_conf "$dir" auth_ilo    # writes $dir/snmp.conf from ${!key}
#   snmp_write_community_conf "$dir" "$community" "<label>"   # v2c, any string

if ! (return 0 2>/dev/null); then
  printf '\033[0;31merror:\033[0m %s is meant to be sourced, not run\n' \
    "${BASH_SOURCE[0]}" >&2
  exit 1
fi

# Prefixed for the same reason secrets-env.sh's is: this is sourced into
# scripts that own die() with their own output conventions.
_snmp_auth_die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The generator file is overridable for the same reason snmp-targets.sh's
# targets file is: a test can point both at scratch copies without touching
# the checkout.
_snmp_auth_generator() {
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '%s' "${SNMP_GENERATOR_FILE:-${repo_root}/stacks/observability/snmp-exporter/generator.yaml}"
}

# ---------------------------------------------------------------------------
# snmp_auth_read <auth>
#
# Reads one `auth_<x>:` block and sets:
#
#   SNMP_AUTH_VERSION     1 | 2 | 3
#   SNMP_AUTH_LEVEL       security_level, as written
#   SNMP_AUTH_USERNAME    username, as written (v3)
#   SNMP_AUTH_AUTHPROTO   auth_protocol, as written (v3)
#   SNMP_AUTH_PRIVPROTO   priv_protocol, as written (v3)
#   SNMP_AUTH_COMMUNITY   the `community:` field, as written — i.e. the
#                         ${PLACEHOLDER}, never a value
#   SNMP_AUTH_PASSWORD    the `password:` field, as written (a placeholder)
#   SNMP_AUTH_PRIVPASS    the `priv_password:` field, as written (a placeholder)
#
# The block is found by its two-space-indented label and read until the next
# label at that indent or the next top-level key. yamllint holds the file to
# that shape, and snmp-targets.sh --check holds every block to the fields
# below, so awk is enough here for the same reason it is in snmp-targets.sh:
# this has to work before python is guaranteed present.
# ---------------------------------------------------------------------------
snmp_auth_read() {
  local auth="${1:?snmp_auth_read needs an auth label}" generator line key value
  generator="$(_snmp_auth_generator)"
  [[ -f "${generator}" ]] || _snmp_auth_die "no such generator file: ${generator}"

  SNMP_AUTH_VERSION=""; SNMP_AUTH_LEVEL=""; SNMP_AUTH_USERNAME=""
  SNMP_AUTH_AUTHPROTO=""; SNMP_AUTH_PRIVPROTO=""; SNMP_AUTH_COMMUNITY=""
  SNMP_AUTH_PASSWORD=""; SNMP_AUTH_PRIVPASS=""

  local found=0
  # The three fields below are read by snmp-targets.sh --check, not here.
  # shellcheck disable=SC2034
  while IFS= read -r line; do
    found=1
    key="${line%%:*}"
    value="${line#*:}"
    value="${value#"${value%%[![:space:]]*}"}"   # ltrim
    value="${value%"${value##*[![:space:]]}"}"   # rtrim
    case "${key}" in
      version)        SNMP_AUTH_VERSION="${value}" ;;
      security_level) SNMP_AUTH_LEVEL="${value}" ;;
      username)       SNMP_AUTH_USERNAME="${value}" ;;
      auth_protocol)  SNMP_AUTH_AUTHPROTO="${value}" ;;
      priv_protocol)  SNMP_AUTH_PRIVPROTO="${value}" ;;
      community)      SNMP_AUTH_COMMUNITY="${value}" ;;
      password)       SNMP_AUTH_PASSWORD="${value}" ;;
      priv_password)  SNMP_AUTH_PRIVPASS="${value}" ;;
    esac
  done < <(awk -v want="  ${auth}:" '
    $0 == want                 { inblock = 1; next }
    inblock && /^  [^ ]/       { exit }
    inblock && /^[^ ]/         { exit }
    inblock && /^    [a-z_]+:/ { sub(/^    /, ""); sub(/[[:space:]]*#.*$/, ""); print }
  ' "${generator}")

  ((found)) || _snmp_auth_die "generator.yaml has no '${auth}:' block under auths:"
  [[ -n "${SNMP_AUTH_VERSION}" ]] || _snmp_auth_die "the '${auth}:' block in generator.yaml has no 'version:'"
  case "${SNMP_AUTH_VERSION}" in
    1|2|3) ;;
    *) _snmp_auth_die "the '${auth}:' block in generator.yaml has version '${SNMP_AUTH_VERSION}'; snmp-exporter accepts 1, 2 or 3" ;;
  esac
}

# ---------------------------------------------------------------------------
# snmp_auth_keys <auth>
#
# Prints the secret key names for a device, comma-joined, in the order the
# rest of the tooling expects them. This is the only place the names are
# derived; the same output is used for the sops key, the ${PLACEHOLDER} in
# generator.yaml, the REQUIRED array in render-config.sh and the -e flags of
# `make snmp-generate`.
# ---------------------------------------------------------------------------
snmp_auth_keys() {
  local auth="${1:?snmp_auth_keys needs an auth label}" suffix
  [[ "${auth}" == auth_* ]] \
    || _snmp_auth_die "auth label '${auth}' does not start with 'auth_', so no secret key name can be derived from it"
  suffix="${auth#auth_}"
  # The suffix becomes part of a shell variable name read through ${!var}. A
  # label like auth_a.pc or auth_a-pc passes the prefix check but yields a
  # name bash rejects with "bad substitution", several files away from the
  # label that caused it. Reject it here instead.
  [[ "${suffix}" =~ ^[A-Za-z0-9_]+$ ]] \
    || _snmp_auth_die "auth label '${auth}' yields an invalid variable name (SNMP_*_${suffix^^}) — the part after 'auth_' must be letters, digits or underscores"
  # Callers run this in a command substitution, so anything set here is lost
  # to them; a caller that wants SNMP_AUTH_* calls snmp_auth_read itself.
  snmp_auth_read "${auth}"
  case "${SNMP_AUTH_VERSION}" in
    3) printf 'SNMP_AUTHPASS_%s,SNMP_PRIVPASS_%s\n' "${suffix^^}" "${suffix^^}" ;;
    *) printf 'SNMP_COMMUNITY_%s\n' "${suffix^^}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Protocol names: snmp-exporter's spelling to net-snmp's.
#
# The exporter writes SHA256 and AES256; net-snmp's snmp.conf wants SHA-256 and
# AES-256. The two Cisco-style key-extension variants (AES192C, AES256C) have
# no snmp.conf spelling on the net-snmp shipped here and are refused rather
# than guessed — a wrong guess presents as the device rejecting a passphrase
# you know is correct.
# ---------------------------------------------------------------------------
_snmp_netsnmp_proto() {
  case "$1" in
    MD5|SHA|DES|AES)        printf '%s' "$1" ;;
    SHA224|SHA256|SHA384|SHA512) printf 'SHA-%s' "${1#SHA}" ;;
    AES192|AES256)          printf 'AES-%s' "${1#AES}" ;;
    *) _snmp_auth_die "protocol '$1' has no net-snmp spelling this tooling knows (MD5, SHA, SHA224-512, DES, AES, AES192, AES256)" ;;
  esac
}

# A value that snmp.conf cannot carry. Every directive here takes whitespace-
# separated tokens, so a value with whitespace is silently truncated, and '#'
# starts a comment — both present as the device rejecting a string you know is
# correct. Refuse instead. The label is named; the value never is.
_snmp_conf_value_ok() {
  local value="$1" label="$2"
  [[ -n "${value}" ]] || _snmp_auth_die "${label} is empty in the secrets file"
  [[ "${value}" != *[[:space:]]* && "${value}" != *'#'* ]] || _snmp_auth_die \
    "${label} contains whitespace or '#', which net-snmp's snmp.conf parser cannot represent.
Regenerate it with scripts/gen-secret.sh and set it on the device."
}

# ---------------------------------------------------------------------------
# snmp_write_community_conf <dir> <community> <label>
#
# A v2c config for an arbitrary string. Used for every v2c device and for the
# old-community probe on every device, v3 ones included: against a device that
# has moved to v3 and switched v1/v2c off, "the old community over v2c is
# refused" is exactly the check that the move is complete.
# ---------------------------------------------------------------------------
snmp_write_community_conf() {
  local dir="$1" community="$2" label="$3"
  _snmp_conf_value_ok "${community}" "${label}"
  mkdir -p "${dir}"
  printf 'defVersion 2c\ndefCommunity %s\n' "${community}" > "${dir}/snmp.conf"
  chmod 600 "${dir}/snmp.conf"
}

# ---------------------------------------------------------------------------
# snmp_write_conf <dir> <auth>
#
# The current credential for a device, in whatever shape its auth block
# declares. Values come from the caller's shell variables, named by
# snmp_auth_keys and set by load_secrets; they are read through ${!var} and
# written to a 0600 file, never printed.
# ---------------------------------------------------------------------------
snmp_write_conf() {
  local dir="$1" auth="$2" keys authkey privkey authproto privproto
  snmp_auth_read "${auth}"
  keys="$(snmp_auth_keys "${auth}")"
  case "${SNMP_AUTH_VERSION}" in
    3)
      [[ "${SNMP_AUTH_LEVEL}" == "authPriv" ]] || _snmp_auth_die \
        "'${auth}' is version 3 with security_level '${SNMP_AUTH_LEVEL}'; ADR-0036 allows authPriv only"
      [[ "${SNMP_AUTH_USERNAME}" =~ ^[A-Za-z0-9_.-]+$ ]] || _snmp_auth_die \
        "'${auth}' has a username snmp.conf cannot carry ('${SNMP_AUTH_USERNAME}'): letters, digits, '_', '.' and '-' only"
      authproto="$(_snmp_netsnmp_proto "${SNMP_AUTH_AUTHPROTO}")"
      privproto="$(_snmp_netsnmp_proto "${SNMP_AUTH_PRIVPROTO}")"
      authkey="${keys%%,*}"; privkey="${keys#*,}"
      _snmp_conf_value_ok "${!authkey:-}" "${authkey}"
      _snmp_conf_value_ok "${!privkey:-}" "${privkey}"
      mkdir -p "${dir}"
      printf 'defVersion 3\ndefSecurityName %s\ndefSecurityLevel authPriv\ndefAuthType %s\ndefAuthPassphrase %s\ndefPrivType %s\ndefPrivPassphrase %s\n' \
        "${SNMP_AUTH_USERNAME}" "${authproto}" "${!authkey}" "${privproto}" "${!privkey}" \
        > "${dir}/snmp.conf"
      chmod 600 "${dir}/snmp.conf"
      ;;
    *)
      snmp_write_community_conf "${dir}" "${!keys:-}" "${keys}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# snmp_classify_rejection <text>
#
# SNMPv2c has no "wrong community" reply — a device that rejects you drops the
# packet — but USM does: a wrong user, passphrase or protocol comes back as a
# Report PDU, which net-snmp turns into one of a handful of fixed phrases.
# Prints the phrase if the text holds one, else nothing. Only the fixed phrase
# is ever printed, never the surrounding output: on a config parse error
# net-snmp echoes the offending line, and that line holds a credential.
# ---------------------------------------------------------------------------
snmp_classify_rejection() {
  local text="$1" phrase
  for phrase in "Unknown user name" "Authentication failure" "Decryption error" \
                "Unsupported security level" "Unknown security engine ID" \
                "Not in time window"; do
    if [[ "${text}" == *"${phrase}"* ]]; then
      printf '%s' "${phrase}"
      return 0
    fi
  done
  return 1
}
