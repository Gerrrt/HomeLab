#!/usr/bin/env bash
#
# Compare the ruleset on main with .github/rulesets/main.json, or apply the file.
#
# WHY THE RULESET IS A FILE (#833)
#
# Until #833 the gate between a pull request and the hosts was a GitHub setting
# nobody could see in a diff, and it was missing its most important rule: a PR
# with a failing Lint could be merged, and converge.sh would deploy the signed
# merge within the hour. Clicking the rule in is a fix for one day. Writing it
# down, and checking weekly that GitHub still says what the file says, is the fix
# for the next edit in the settings page too, which nothing else would notice.
#
# HOW IT COMPARES
#
# The file is the claim; the live ruleset is the measurement. The rule TYPES must
# match exactly, so a rule added or removed in the UI is drift. Within a rule,
# only the parameters the file names are compared, because GitHub fills in
# defaults the file has no reason to repeat, and a new default appearing in the
# API is not a change anyone made.
#
# It also asserts that converge.sh's REQUIRED_CHECKS are all required by the
# ruleset. The host's list is shorter on purpose (it omits the pull-request-only
# check), but a host waiting on a check the ruleset does not require would be
# gating on something a merge never has to pass.
#
# Reading needs no credential: rulesets on a public repository are readable
# anonymously, so this runs in CI with the default token. Applying needs `gh`
# signed in as an admin, and is a human's to run.
#
# Usage:
#   scripts/check-ruleset.sh            report drift, change nothing (exit 1 on drift)
#   scripts/check-ruleset.sh --apply    make the live ruleset match the file

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="Gerrrt/HomeLab"
FILE="${REPO_ROOT}/.github/rulesets/main.json"
CONVERGE="${REPO_ROOT}/scripts/converge.sh"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

APPLY=0
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  -h|--help) sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown argument: $1" ;;
esac

[[ -f "${FILE}" ]] || die "no ruleset file at ${FILE}"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "${FILE}")"

api() {
  # GITHUB_TOKEN in CI lifts the anonymous rate limit; it is sent as a header
  # read from stdin, never on the command line.
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "${GITHUB_TOKEN}" \
      | curl -fsS --max-time 20 -K - -H 'Accept: application/vnd.github+json' "https://api.github.com$1"
  else
    curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' "https://api.github.com$1"
  fi
}

id="$(api "/repos/${REPO}/rulesets" \
  | python3 -c 'import json,sys; m=[r["id"] for r in json.load(sys.stdin) if r["name"]==sys.argv[1]]; print(m[0] if m else "")' "${NAME}")" \
  || die "could not list the rulesets on ${REPO}"

if ((APPLY)); then
  command -v gh >/dev/null 2>&1 || die "--apply needs gh, signed in as a repository admin"
  if [[ -n "${id}" ]]; then
    info "updating ruleset '${NAME}' (${id}) from ${FILE#"${REPO_ROOT}/"}"
    gh api -X PUT "repos/${REPO}/rulesets/${id}" --input "${FILE}" >/dev/null
  else
    info "creating ruleset '${NAME}' from ${FILE#"${REPO_ROOT}/"}"
    gh api -X POST "repos/${REPO}/rulesets" --input "${FILE}" >/dev/null
  fi
  info "applied; checking it took"
  exec "${BASH_SOURCE[0]}"
fi

[[ -n "${id}" ]] || die "no ruleset named '${NAME}' on ${REPO} — main is unprotected. Apply it: $0 --apply"

live="$(api "/repos/${REPO}/rulesets/${id}")" || die "could not read ruleset ${id}"

# converge.sh's list, read the way it is written: one bash array on one line.
converge_checks="$(sed -n 's/^REQUIRED_CHECKS=(\(.*\))$/\1/p' "${CONVERGE}")"
[[ -n "${converge_checks}" ]] || die "could not find REQUIRED_CHECKS=(...) in ${CONVERGE}"

LIVE="${live}" python3 - "${FILE}" "${converge_checks}" <<'PY'
import json, os, shlex, sys

want = json.load(open(sys.argv[1]))
live = json.loads(os.environ["LIVE"])
converge = shlex.split(sys.argv[2])
problems = []

for key in ("target", "enforcement", "conditions", "bypass_actors"):
    # GitHub returns bypass_actors as null to anyone who is not an admin, which
    # is every reader this check has in CI. Null is "not shown", not "none".
    if key == "bypass_actors" and live.get(key) is None:
        continue
    if live.get(key) != want.get(key):
        problems.append(f"{key}: live {json.dumps(live.get(key))}, file {json.dumps(want.get(key))}")

live_rules = {r["type"]: r.get("parameters", {}) for r in live.get("rules", [])}
want_rules = {r["type"]: r.get("parameters", {}) for r in want["rules"]}

for t in sorted(set(want_rules) - set(live_rules)):
    problems.append(f"rule '{t}' is in the file and not on GitHub")
for t in sorted(set(live_rules) - set(want_rules)):
    problems.append(f"rule '{t}' is on GitHub and not in the file")

def norm(v):
    # Lists of objects (the required checks) compare as sets: order in the UI is
    # not a decision.
    if isinstance(v, list):
        return sorted(json.dumps(x, sort_keys=True) for x in v)
    return v

for t in sorted(set(want_rules) & set(live_rules)):
    for k, v in want_rules[t].items():
        if norm(live_rules[t].get(k)) != norm(v):
            problems.append(f"rule '{t}' parameter '{k}': live {json.dumps(live_rules[t].get(k))}, file {json.dumps(v)}")

required = {c["context"] for c in want_rules.get("required_status_checks", {}).get("required_status_checks", [])}
for c in converge:
    if c not in required:
        problems.append(f"converge.sh waits on '{c}', which the ruleset does not require")

if problems:
    print("the ruleset on main is not what .github/rulesets/main.json says:")
    for p in problems:
        print(f"  - {p}")
    print("If GitHub is right, update the file. If the file is right: scripts/check-ruleset.sh --apply")
    sys.exit(1)
print(f"ruleset '{want['name']}' matches the file ({len(want_rules)} rules, {len(required)} required checks)")
PY
