#!/usr/bin/env bash
#
# The list of stacks, defined once.
#
#   scripts/stacks.sh            names, one per line      -> observability
#   scripts/stacks.sh --paths    repo-relative paths      -> stacks/observability
#
# Why this exists
# ---------------
# `STACK ?= observability` in the Makefile parameterised the lifecycle and
# secrets targets and stopped there. Every validator carried its own
# `stacks/observability` — validate.sh, four Python checkers, check_loki_rules.sh,
# seed-validation-env.sh and ci.yml — so `stacks/lab` landed as a stack CI had
# never seen: compose not `config`-checked, rules not `promtool`-tested, images
# pinned by nothing (#263, #264).
#
# The fix is one list, not eight. Anything that iterates stacks reads it from
# here, including the Python checkers — a second implementation in Python would
# be a second definition, and two definitions of "what a stack is" drift the
# same way two copies of a device list do. That is the argument snmp-targets.sh
# makes about the SNMP inventory, applied one level up.
#
# What counts as a stack
# ----------------------
# A directory under stacks/ holding a compose.yaml. Nothing else is consulted —
# not a manifest, not a list in this file — because a stack IS its compose file
# (ADR-0004), and any register kept beside the directory tree is a register that
# can disagree with it.
#
# A directory WITHOUT a compose.yaml is an error, not a skip. That is the whole
# point rather than strictness for its own sake: the failure this guards against
# is a stack nothing checks, and silently skipping a malformed directory is
# indistinguishable from it. `mkdir stacks/foo` now fails `make validate` with a
# sentence saying why, instead of passing and quietly covering nothing.
#
# Hidden directories are skipped — `.rendered/` and friends live under a stack,
# never beside one.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACKS_DIR="${REPO_ROOT}/stacks"

MODE="names"
case "${1:-}" in
  "") ;;
  --paths) MODE="paths" ;;
  -h | --help)
    sed -n '3,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf '\033[0;31merror:\033[0m unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

[[ -d "${STACKS_DIR}" ]] || {
  printf '\033[0;31merror:\033[0m no stacks/ directory at %s\n' "${STACKS_DIR}" >&2
  exit 1
}

found=0
malformed=()
for dir in "${STACKS_DIR}"/*/; do
  name="$(basename "${dir}")"
  [[ "${name}" == .* ]] && continue
  # A glob that matches nothing expands to itself; without this an empty
  # stacks/ would report a stack literally called `*`.
  [[ -d "${dir}" ]] || continue
  if [[ ! -f "${dir}compose.yaml" ]]; then
    malformed+=("${name}")
    continue
  fi
  found=1
  if [[ "${MODE}" == "paths" ]]; then
    printf 'stacks/%s\n' "${name}"
  else
    printf '%s\n' "${name}"
  fi
done

if ((${#malformed[@]})); then
  printf '\033[0;31merror:\033[0m no compose.yaml in: %s\n' "${malformed[*]}" >&2
  printf 'A directory under stacks/ is a stack, and a stack is its compose file
(ADR-0004). Nothing validates, deploys or pins images for a directory without
one, so this fails rather than skipping it — a stack nothing checks is the
defect this list exists to prevent (#263).

Add a compose.yaml, or remove the directory.\n' >&2
  exit 1
fi

((found)) || {
  printf '\033[0;31merror:\033[0m stacks/ holds no stack with a compose.yaml\n' >&2
  exit 1
}
