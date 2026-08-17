#!/usr/bin/env bash
#
# Generate random secrets.
#
# Replaces the inline one-liner that used to live in the rotation runbook:
#
#   openssl rand -base64 24 | tr -d '/+=' | head -c 24
#
# which had two faults. `tr -d` removes an unbounded number of characters
# before `head -c 24` truncates, so the output length was a random variable —
# usually 24, occasionally less, never announced. And `head -c` closes the pipe,
# so openssl takes SIGPIPE and the whole thing exits 141 under `pipefail`, which
# is why it could not simply be pasted into a script.
#
# Usage:
#   scripts/gen-secret.sh                  one 24-character secret
#   scripts/gen-secret.sh --length 15      shorter (some devices cap the field)
#   scripts/gen-secret.sh --count 4        several
#   scripts/gen-secret.sh --snmp           one per SNMP device, ready to paste
#                                          into `make secrets-edit`

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

LENGTH=24
COUNT=1
SNMP=0

while (($#)); do
  case "$1" in
    --length) LENGTH="${2:?--length needs a value}"; shift 2 ;;
    --count)  COUNT="${2:?--count needs a value}";   shift 2 ;;
    --snmp)   SNMP=1; shift ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if ! [[ "${LENGTH}" =~ ^[0-9]+$ ]] || ((LENGTH < 8)); then
  die "--length must be an integer of at least 8"
fi
if ! [[ "${COUNT}" =~ ^[0-9]+$ ]] || ((COUNT < 1)); then
  die "--count must be a positive integer"
fi

# ---------------------------------------------------------------------------
# The alphabet is [A-Za-z0-9], and every exclusion is load-bearing for a
# consumer in this repository:
#
#   $ ` \ " '   the value passes through bash parameter expansion in
#               render-config.sh before being written to the rendered snmp.yaml
#   &           render-config.sh already disables patsub_replacement because an
#               unescaped & in a ${x//a/b} replacement expands to the matched
#               text — silently rendering the placeholder it was meant to
#               replace. Excluding it makes that guard belt AND braces
#   space, #    snmp-verify.sh writes the community to a net-snmp snmp.conf,
#               where defCommunity takes the rest of the line; # also starts a
#               YAML comment
#   :           secrets-env.sh splits on the first ": "
#
# 24 alphanumerics is ~143 bits. Nothing here is improved by a wider alphabet,
# and every character outside it has a specific way of going wrong quietly.
# ---------------------------------------------------------------------------
gen_secret() {
  local length="$1" value
  # tr -dc from /dev/urandom is uniform by construction: bytes outside the
  # class are discarded rather than folded into it, so there is no modulo bias.
  # dd guarantees exactly `length` characters.
  #
  # dd closes the pipe once it has its bytes, so tr dies of SIGPIPE. That is
  # the design rather than a failure, so pipefail is relaxed — inside a
  # subshell, so the rest of the script keeps it.
  value="$(
    set +o pipefail
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | dd bs=1 count="${length}" 2>/dev/null
  )"
  ((${#value} == length)) || die "short read from /dev/urandom (got ${#value}, wanted ${length})"
  printf '%s\n' "${value}"
}

if ((SNMP)); then
  # Key names come from the device inventory, so a fifth device produces a
  # fifth line here without this script being touched.
  while IFS=$'\t' read -r _ip _auth _device var; do
    [[ -n "${var}" ]] || continue
    printf '%s: %s\n' "${var}" "$(gen_secret "${LENGTH}")"
  done < <("${REPO_ROOT}/scripts/snmp-targets.sh")

  printf '\n\033[0;33mThese are now in your terminal scrollback.\033[0m They are not in your
shell history — they are output, not a command — but close this window when you
are done. Set each one on its device first, then paste them into
"make secrets-edit". See docs/runbooks/rotate-snmp-community.md.\n' >&2
else
  for ((i = 0; i < COUNT; i++)); do
    gen_secret "${LENGTH}"
  done
fi
