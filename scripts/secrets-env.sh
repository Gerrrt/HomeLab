#!/usr/bin/env bash
#
# Decrypt a stack's SOPS file into shell variables. Sourced, not executed.
#
# This exists because two copies of a hand-rolled YAML parser will eventually
# disagree, and the way that failure presents is the worst one available:
# snmp-verify.sh reporting PASS for a string that render-config.sh then writes
# differently, so the target goes DOWN while the verification stands there
# saying it cannot be the community. One parser, one set of edge cases.
#
# Usage:
#   source "${REPO_ROOT}/scripts/secrets-env.sh"
#   load_secrets observability
#   printf '%s' "${SNMP_COMMUNITY_APC}"      # or "${!var}" indirectly
#
# Variables are set with `printf -v`, NOT exported. See load_secrets.

# Sourced-not-run guard. Executing this file defines a function into a shell
# that immediately exits, which looks like it worked and does nothing.
if ! (return 0 2>/dev/null); then
  printf '\033[0;31merror:\033[0m %s is meant to be sourced, not run\n' \
    "${BASH_SOURCE[0]}" >&2
  exit 1
fi

# Matches render-config.sh's die(). Named with a prefix because this file is
# sourced into scripts that define their own die() with different output
# conventions — validate.sh-style callers accumulate failures rather than
# exiting, and silently overriding their helper would be a nasty surprise.
_secrets_die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# load_secrets <stack>
#
# Decrypts secrets/<stack>.sops.yaml and sets one shell variable per key.
load_secrets() {
  local stack="${1:?usage: load_secrets <stack>}"
  local repo_root secrets_file plaintext line key value

  # BASH_SOURCE[0] inside a function is the file the function was defined in,
  # so this resolves against scripts/ regardless of who sourced it or from
  # which working directory.
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  secrets_file="${repo_root}/secrets/${stack}.sops.yaml"

  command -v sops >/dev/null 2>&1 \
    || _secrets_die "sops not found. Install it: https://github.com/getsops/sops/releases"

  [[ -f "${secrets_file}" ]] \
    || _secrets_die "${secrets_file} does not exist. Run 'make secrets-init' first."

  # Keep the plaintext in a variable, never in a file.
  plaintext="$(sops --decrypt "${secrets_file}")" \
    || _secrets_die "decryption failed. Is ~/.config/sops/age/keys.txt present?"

  while IFS= read -r line; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
    [[ "${line}" =~ ^---$ ]] && continue

    key="${line%%:*}"
    # No colon at all: not a key/value line.
    [[ "${key}" == "${line}" ]] && continue

    # Require the space after the colon rather than guessing, because both
    # ways of omitting it fail silently and produce a *plausible* value:
    #
    #   SNMP_COMMUNITY_APC:abc123   ->  ${line#*: } finds no ": " and returns
    #                                   the whole line, so the community
    #                                   becomes "SNMP_COMMUNITY_APC:abc123" —
    #                                   renders cleanly, and only the device
    #                                   ever disagrees.
    #   SNMP_COMMUNITY_APC:         ->  value becomes "SNMP_COMMUNITY_APC:",
    #                                   which is non-empty, so it sails through
    #                                   render-config.sh's REQUIRED check.
    #
    # Both are one slip in `make secrets-edit` away, and neither is visible in
    # a diff. Refusing to parse is the only honest option. The key is named;
    # the value never is.
    [[ "${line}" == *": "* ]] || _secrets_die \
      "malformed line in $(basename "${secrets_file}") for key '${key}': expected 'KEY: value' with a space after the colon"

    # A key that is not a valid shell identifier means the file has nesting or
    # indentation this parser cannot represent. Failing beats setting nothing
    # and letting the REQUIRED check report it as simply missing.
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || _secrets_die \
      "unsupported key '${key}' in $(basename "${secrets_file}") — this parser handles flat 'KEY: value' lines only"

    value="${line#*: }"
    # Strip surrounding quotes if the YAML had them.
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"

    # printf -v, deliberately not `export`. An exported secret is inherited by
    # every child process — and render-config.sh spawns mkdir, cat, grep, chmod
    # and id after this point, each of which would carry four SNMP communities
    # and the Grafana password in its environment for no reason. Nothing needs
    # it: callers read these in-process via ${!var}. It also keeps them out of
    # snmpget's /proc/<pid>/environ in snmp-verify.sh.
    printf -v "${key}" '%s' "${value}"
  done <<< "${plaintext}"

  unset plaintext
}
