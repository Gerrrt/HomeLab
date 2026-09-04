#!/usr/bin/env bash
#
# Pull every provisioned dashboard out of the running Grafana and write it back
# over grafana/dashboards/, so the loop is: edit in the UI, run this, git diff.
#
# WHY THIS EXISTS
#
# The export step used to be: Dashboard settings -> JSON Model, select all,
# copy, paste over the file. docs/roadmap.md was blunt about the consequence —
# manual, and therefore skipped under pressure (#100).
#
# WHY THE PROVISIONING HAD TO CHANGE FOR IT TO WORK
#
# This command is useless while `allowUiUpdates` is false, and not in a way
# that announces itself. Grafana refuses to persist an edit to a provisioned
# dashboard at all — `POST /api/dashboards/db` answers
# `400 Cannot save provisioned dashboard` — so the API can only ever hand back
# the file it was provisioned from. Every export would have been a clean no-op
# over the very edit it was supposed to capture, and `git diff` would have said
# "nothing changed" about a change that was really there on the screen.
#
# So dashboards.yaml now sets `allowUiUpdates: true`. The file is still the
# source of truth — Grafana re-provisions over its own copy whenever the JSON
# changes — but an edit now survives long enough to be exported. What that
# costs is the guarantee that the running dashboard and the committed one are
# the same thing, and --check below is what buys it back: the scheduled
# `dashboards-drift` job runs it, so an edit nobody exported becomes a stale
# job rather than a surprise six months later.
#
# The Grafana password is read in-process via scripts/secrets-env.sh and passed
# to curl on stdin through --config, never in argv: everything in argv is
# visible in `ps` to every user on the host for the life of the request. Same
# handling as scripts/capture-screenshots.sh, for the same reason.
#
# Usage:
#   scripts/export-dashboards.sh [--check] [stack]     (default: observability)
#
#   --check   report what differs and write nothing; exits non-zero on drift.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CHECK=0
STACK=""
while (($#)); do
  case "$1" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    *) STACK="$1" ;;
  esac
  shift
done
STACK="${STACK:-observability}"
STACK_DIR="${REPO_ROOT}/stacks/${STACK}"
DASHBOARD_DIR="${STACK_DIR}/grafana/dashboards"
COMPOSE=(docker compose -f "${STACK_DIR}/compose.yaml")

# shellcheck source=secrets-env.sh
source "${REPO_ROOT}/scripts/secrets-env.sh"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

[[ -d "${DASHBOARD_DIR}" ]] || die "no dashboards at ${DASHBOARD_DIR}"

# Nothing here can work against a Grafana that is not serving, and the failure
# would otherwise be a connection error per dashboard rather than one sentence.
"${COMPOSE[@]}" ps --status running --services 2>/dev/null | grep -qx grafana \
  || die "grafana is not running — run 'make up' first"

# The uid list is derived from the committed files rather than written down
# again. A hardcoded list is a second copy of the dashboard inventory, and the
# way it fails is by silently not exporting the dashboard somebody just added.
mapfile -t UIDS < <(python3 - "${DASHBOARD_DIR}" <<'UIDS_PY'
import json, pathlib, sys
for path in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    uid = json.loads(path.read_text(encoding="utf-8")).get("uid")
    if not uid:
        sys.exit(f"{path.name}: no top-level 'uid'")
    print(uid)
UIDS_PY
)
((${#UIDS[@]})) || die "no dashboards with a uid in ${DASHBOARD_DIR}"

# The uid reader above runs in a process substitution, whose exit status
# mapfile does not see and `set -e` therefore cannot act on. A file it refused
# to read would simply be absent from the list, and the export would quietly
# cover one dashboard fewer than the folder holds. Count them instead.
n_files="$(find "${DASHBOARD_DIR}" -maxdepth 1 -name '*.json' -type f | wc -l)"
((${#UIDS[@]} == n_files)) \
  || die "read ${#UIDS[@]} uid(s) from ${n_files} dashboard file(s) — one of them could not be parsed"

info "decrypting ${STACK}.sops.yaml"
load_secrets "${STACK}"
[[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] \
  || die "GRAFANA_ADMIN_PASSWORD missing from secrets/${STACK}.sops.yaml"

# Read the published port back out of the rendered .env rather than assuming
# 3000, for the same reason `make up` and capture-screenshots.sh do: a wrong URL
# here looks exactly like a Grafana that is down.
PORT="$(grep -E '^GRAFANA_PORT=' "${STACK_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
BASE="https://localhost:${PORT:-3000}"

CURL_CONFIG="$(mktemp)"
FETCHED="$(mktemp -d)"
trap 'rm -f "${CURL_CONFIG}"; rm -rf "${FETCHED}"' EXIT

# --config keeps the credential out of argv. mktemp creates the file at 0600
# and the trap above removes it on every exit path.
{
  printf 'user = "%s:%s"\n' "${GRAFANA_ADMIN_USER:-admin}" "${GRAFANA_ADMIN_PASSWORD}"
  # The lab CA signs grafana.matrix.elysium and this request is to localhost, so
  # the name cannot match. Verification is not what this script is testing.
  printf 'insecure\n'
  printf 'silent\n'
  printf 'show-error\n'
  printf 'fail\n'
} > "${CURL_CONFIG}"

info "fetching ${#UIDS[@]} dashboard(s) from ${BASE}"
for uid in "${UIDS[@]}"; do
  curl --config "${CURL_CONFIG}" --max-time 30 \
       -o "${FETCHED}/${uid}.json" "${BASE}/api/dashboards/uid/${uid}" \
    || die "could not fetch uid '${uid}' — is it provisioned into this Grafana?"
done

# Anything created in the UI is fetched too, so export_dashboards.py can say so.
# A dashboard that exists only in Grafana's database is one restart of a rebuilt
# stack away from being gone, and this is the one command positioned to notice.
SEARCH="$(mktemp)"
trap 'rm -f "${CURL_CONFIG}" "${SEARCH}"; rm -rf "${FETCHED}"' EXIT
if curl --config "${CURL_CONFIG}" --max-time 30 -o "${SEARCH}" \
     "${BASE}/api/search?type=dash-db&limit=500"; then
  while read -r uid; do
    [[ -n "${uid}" ]] || continue
    # Spelled as an `if` and not `[[ ... ]] && continue`, because that idiom
    # ends an && list on a false test and `set -e` treats the list's status as
    # the loop body's — an orphan uid, the one case this exists for, would end
    # the script rather than be fetched.
    if [[ ! -f "${FETCHED}/${uid}.json" ]]; then
      # Fetched for real rather than stubbed, so what export_dashboards.py
      # reports is a dashboard Grafana actually served, not a name off a list.
      curl --config "${CURL_CONFIG}" --max-time 30 \
           -o "${FETCHED}/${uid}.json" "${BASE}/api/dashboards/uid/${uid}" \
        || rm -f "${FETCHED}/${uid}.json"
    fi
  done < <(python3 -c '
import json, sys
for row in json.load(open(sys.argv[1])):
    print(row.get("uid", ""))
' "${SEARCH}")
else
  # Not fatal. Failing the whole export because the orphan sweep could not run
  # would trade the thing this command is for against a warning it is not.
  printf '\033[0;33mwarning:\033[0m /api/search failed — cannot tell whether Grafana holds an unprovisioned dashboard\n' >&2
fi

ARGS=(--fetched "${FETCHED}" --dashboards "${DASHBOARD_DIR}")
if ((CHECK)); then ARGS+=(--check); fi

python3 "${REPO_ROOT}/scripts/export_dashboards.py" "${ARGS[@]}"
