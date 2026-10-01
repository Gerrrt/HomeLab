#!/usr/bin/env bash
#
# Who can open the household's copy, read out of the one file that says so.
#
# WHY A FILE OF ITS OWN AND NOT A SOPS RULE
#
# ADR-0073. The household's archive has to open with a key that is not only
# the operator's (ADR-0023), and the obvious place to add one — the sensitive
# rule in .sops.yaml — would also hand that key secrets/sensitive.sops.yaml:
# the tier's passwords, Vaultwarden's admin token among them. The person who
# holds the household's photographs has no use for those, and ADR-0048 already
# made the estate's rule that one key doing two jobs means one leak takes both.
# So the household's recipients live in stacks/sensitive/household.recipients,
# which encrypts the library and document sets and opens nothing in secrets/.
# scripts/check_sops_rules.py holds the line: a `household` key in any sops
# rule fails it.
#
# THE FORMAT
#
# The file is valid input to `age -R` as it stands — comments and keys, one per
# line — so the holder's own copy of it is usable without this script. What
# this adds is a role per key, as the comment line directly above it:
#
#   # role: household          (who, generated on their own device, when)
#   age1...
#   # role: technical-second   (ADR-0024's; the catch-all rule's second key)
#   age1...
#
# Two roles, and only two. `household` is the person ADR-0023 is about: the
# one who opens the copy from their own device without the operator there.
# `technical-second` is ADR-0024's recipient, carried here as the fallback the
# 2026-09-27 comment on #455 recommends — not instead of the household key.
# A key with no role, a role with no key, an unknown role, a duplicate and a
# line that is not a key are each refused by name: a recipients file read
# leniently is how a recovery path gets advertised that opens nothing.
#
# Usage:
#   scripts/household-recipients.sh --list [--role <role>]  keys, one per line
#   scripts/household-recipients.sh --roles                 "<role> <key>", one per line
#   scripts/household-recipients.sh --check                 parse, and say what the file holds
#   scripts/household-recipients.sh --has-holder            exit 0 iff a household key exists
#   scripts/household-recipients.sh --self-test
#
#   --file <path>  read another file (default stacks/sensitive/household.recipients)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${REPO_ROOT}/stacks/sensitive/household.recipients"
MODE=""
ROLE=""

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# --self-test
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  fail=0
  # Two well-formed keys: age1 and 58 characters of bech32.
  K1="age1$(printf 'q%.0s' {1..58})"
  K2="age1$(printf 'p%.0s' {1..58})"
  run() {  # <fixture body> <args...> → OUT, RC
    local body="$1"; shift
    printf '%s' "${body}" > "${T}/r"
    set +e
    OUT="$("${BASH_SOURCE[0]}" --file "${T}/r" "$@" 2>&1)"
    RC=$?
    set -e
  }
  check() {  # <name> <expected rc> <expected substring>
    if [[ ${RC} == "$2" && ${OUT} == *"$3"* ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$1"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       exit %s, wanted %s; wanted output containing: %s\n' "$1" "${RC}" "$2" "$3"
      printf '%s\n' "${OUT}" | sed 's/^/       | /'
      fail=1
    fi
  }

  both="# a comment
# role: household  (someone, 2026-10-01)
${K1}

# role: technical-second
${K2}
"
  run "${both}" --list
  check "both keys are listed, in file order" 0 "${K1}
${K2}"
  run "${both}" --list --role household
  check "--role picks one role's keys" 0 "${K1}"
  [[ ${OUT} != *"${K2}"* ]] || { printf '\033[0;31m  FAIL\033[0m --role leaked the other role\n'; fail=1; }
  run "${both}" --roles
  check "--roles pairs each key with its role" 0 "technical-second ${K2}"
  run "${both}" --has-holder
  check "a household key is a holder" 0 ""

  second="# role: technical-second
${K2}
"
  run "${second}" --has-holder
  check "the technical second alone is not a holder" 1 ""
  run "${second}" --check
  check "--check says so in words" 0 "no household holder"

  run "${K1}
" --list
  check "a key with no role is refused" 1 "has no '# role:' line above it"
  run "# role: household
# role: technical-second
${K1}
" --list
  check "a role with no key is refused" 1 "names no key"
  run "# role: household
" --list
  check "a role at the end of the file is refused" 1 "names no key"
  run "# role: neighbour
${K1}
" --list
  check "an unknown role is refused" 1 "unknown role 'neighbour'"
  run "# role: household
${K1}
# role: technical-second
${K1}
" --list
  check "a key listed twice is refused" 1 "listed twice"
  run "# role: household
age1notakey
" --list
  check "a line that is not a key is refused" 1 "is not an age recipient"
  run $'# role: household\n'"${K1}"$' \n' --list
  check "trailing whitespace is refused, not trimmed" 1 "is not an age recipient"
  run "" --check
  check "an empty file is refused" 1 "holds no recipients"
  set +e
  OUT="$("${BASH_SOURCE[0]}" --file "${T}/absent" --list 2>&1)"; RC=$?
  set -e
  check "a missing file is refused" 1 "no recipients file"

  exit "${fail}"
fi

while (($#)); do
  case "$1" in
    --list)       MODE="list"; shift ;;
    --roles)      MODE="roles"; shift ;;
    --check)      MODE="check"; shift ;;
    --has-holder) MODE="has-holder"; shift ;;
    --role)       ROLE="${2:-}"; shift 2 ;;
    --file)       FILE="${2:-}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n ${MODE} ]] || { usage >&2; die "say what to do"; }
[[ -z ${ROLE} || ${ROLE} == household || ${ROLE} == technical-second ]] \
  || die "--role is household or technical-second, got '${ROLE}'"
[[ -r ${FILE} ]] || die "no recipients file at ${FILE}"

# ---------------------------------------------------------------------------
# Parse. Every refusal names the line, because the file is edited by hand.
# ---------------------------------------------------------------------------
KEY_RE='^age1[02-9ac-hj-np-z]{58}$'
ROLE_RE='^#[[:space:]]*role:[[:space:]]*([A-Za-z0-9_-]+)([[:space:]].*)?$'
pending="" pending_at=0 n=0
roles=() keys=()
declare -A seen=()
while IFS= read -r line || [[ -n ${line} ]]; do
  n=$((n + 1))
  if [[ ${line} =~ ${ROLE_RE} ]]; then
    [[ -z ${pending} ]] || die "${FILE}:${pending_at}: '# role: ${pending}' names no key — the next line that is not a comment must be its key"
    case "${BASH_REMATCH[1]}" in
      household|technical-second) ;;
      *) die "${FILE}:${n}: unknown role '${BASH_REMATCH[1]}' — the roles are household and technical-second (ADR-0073)" ;;
    esac
    pending="${BASH_REMATCH[1]}" pending_at="${n}"
    continue
  fi
  [[ -z ${line} || ${line} == \#* ]] && continue
  [[ ${line} =~ ${KEY_RE} ]] || die "${FILE}:${n}: '${line}' is not an age recipient (age1 and 58 characters, nothing else on the line)"
  [[ -n ${pending} ]] || die "${FILE}:${n}: ${line} has no '# role:' line above it — say whose key it is"
  [[ -z ${seen[${line}]:-} ]] || die "${FILE}:${n}: ${line} is listed twice (first at line ${seen[${line}]})"
  seen[${line}]="${n}"
  roles+=("${pending}")
  keys+=("${line}")
  pending=""
done < "${FILE}"
[[ -z ${pending} ]] || die "${FILE}:${pending_at}: '# role: ${pending}' names no key — the next line that is not a comment must be its key"
((${#keys[@]})) || die "${FILE} holds no recipients"

holders=0
for r in "${roles[@]}"; do [[ ${r} == household ]] && holders=$((holders + 1)); done

case "${MODE}" in
  list)
    for i in "${!keys[@]}"; do
      if [[ -z ${ROLE} || ${roles[i]} == "${ROLE}" ]]; then printf '%s\n' "${keys[i]}"; fi
    done
    ;;
  roles)
    for i in "${!keys[@]}"; do printf '%s %s\n' "${roles[i]}" "${keys[i]}"; done
    ;;
  check)
    printf '%s: %d recipient(s), %d household\n' "${FILE#"${REPO_ROOT}"/}" "${#keys[@]}" "${holders}"
    ((holders)) || printf 'no household holder yet — the copy does not meet ADR-0023 until one is added (ADR-0073)\n'
    ;;
  has-holder)
    ((holders))
    ;;
esac
