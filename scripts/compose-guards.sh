#!/usr/bin/env bash
#
# Print the variables a stack's compose.yaml requires, one per line.
#
# `${VAR:?message}` in compose.yaml IS the declaration that a service cannot
# start without VAR, so anything that needs to know what a stack requires reads
# it from there rather than keeping a second list that can only drift from it.
# Two callers do: scripts/seed-validation-env.sh, which must satisfy every guard
# to get `docker compose config` past them, and scripts/render-config.sh, which
# must ask SOPS for every guarded secret. They used to hold a copy each of the
# same grep, which is one copy too many for a derivation both of them describe
# as "the same one the other uses".
#
# That grep read the raw file, so it read comments as well as YAML: a comment in
# compose.yaml that *mentioned* the guard syntax — explaining what one does, for
# instance — was picked up as a real guard, and validation then demanded a value
# for a variable that does not exist. Documentation should not have to avoid
# describing the thing it documents (#107).
#
# So the guards are read from the parsed document instead, where a comment
# cannot appear. `docker compose config` would be the authority, but it resolves
# the guards rather than reporting them — it is the thing being satisfied, so it
# cannot be the thing asked. PyYAML gives the values without the comments, and
# check_compose_health.py already parses compose.yaml with it.
#
# Usage: scripts/compose-guards.sh <compose.yaml>
#
# Exit status is what callers must check: a stack whose compose.yaml genuinely
# guards nothing prints nothing and exits 0, which is indistinguishable in the
# output alone from this script having failed. Both callers read it through
# command substitution for that reason.

set -euo pipefail

FILE="${1:?usage: compose-guards.sh <compose.yaml>}"
[[ -f "${FILE}" ]] || {
  printf 'no such compose file: %s\n' "${FILE}" >&2
  exit 1
}

# PyYAML is not installed for this — it is asked for and worked around if
# absent. render-config.sh runs on a deploy host, and making a render depend on
# a Python library (or on pip reaching the network to install one) to read a
# list of variable names would be a worse trade than the approximation below.
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "${FILE}" <<'GUARDS_PY'
import re
import sys

import yaml

GUARD = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*):\?")

# Every scalar, not just the handful of keys guards happen to appear under
# today: they are in `user:`, in `environment:` and in `group_add:` already, and
# a guard is equally valid in a command, a label or a mapping key.
found = set()


def walk(node):
    if isinstance(node, dict):
        for key, value in node.items():
            walk(key)
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)
    elif isinstance(node, str):
        found.update(GUARD.findall(node))


walk(yaml.safe_load(open(sys.argv[1], encoding="utf-8")))
for name in sorted(found):
    print(name)
GUARDS_PY
else
  # The fallback, and it is an approximation: strip what YAML would treat as a
  # comment — a # at the start of a line or after whitespace — and grep what is
  # left. That is right about the case this exists for (a comment describing a
  # guard) and wrong about a # inside a quoted string, where it truncates the
  # line and can miss a guard that follows. Missing one is the old failure mode,
  # an opaque compose interpolation error later, rather than a false demand.
  #
  # `|| true` because grep exits 1 on no matches, and a stack that guards
  # nothing is legitimate — the loops on the other end handle an empty list.
  sed -E 's/(^|[[:space:]])#.*$//' "${FILE}" \
    | { grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:\?' || true; } \
    | sed 's/^\${//; s/:?$//' | sort -u
fi
