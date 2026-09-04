#!/usr/bin/env bash
#
# Prove that `make dashboards-export` still works, without a live stack.
#
# It boots the pinned Grafana image against a throwaway copy of the committed
# provisioning, and asserts three things. Each of them is a way the export can
# stop working while every other check in this repository still passes.
#
#   1. ROUND TRIP. Provisioning a dashboard and reading it straight back
#      produces the same file. Grafana does not hand back what it was given —
#      it sorts keys alphabetically, HTML-escapes `&` to `\u0026`, and
#      migrates old schema versions — so the committed JSON has to already be
#      in the form the export writes. Without this, the first real export
#      after any drift rewrites all seven files and the diff that matters is
#      buried in one that does not.
#
#   2. UI SAVES ARE ACCEPTED. This is the load-bearing one. While
#      `allowUiUpdates` is false, Grafana answers every save to a provisioned
#      dashboard with `400 Cannot save provisioned dashboard`, so no UI edit
#      ever reaches the database and the export can only ever hand back the
#      file it started from. `make dashboards-export` would then be a silent
#      no-op over the very edit it exists to capture, and `git diff` would say
#      "nothing changed" about a change that was really there on the screen.
#      That is what #100 turned out to be blocked on, and it is invisible: the
#      command succeeds, exits zero, and writes nothing. So the setting is
#      asserted here rather than trusted.
#
#   3. END TO END. The edit from (2) is fetched back and folded in by
#      scripts/export_dashboards.py, against a scratch copy of the dashboard
#      directory. Assertions 1 and 2 can both pass while the canonicaliser
#      drops the change on the floor — this is the one that watches a real
#      edit travel from the API into a file.
#
# Nothing here needs a secret. The throwaway Grafana serves plain HTTP on its
# own loopback with anonymous admin, is never published to a port, and is
# removed on every exit path. The committed dashboards are copied, never
# mounted read-write, so a failing run cannot leave a modified dashboard behind.
#
# Modelled on scripts/check_loki_rules.sh, which boots the pinned Loki image for
# the same reason: the only thing that genuinely understands the format is the
# thing that will serve it.
#
# Usage: scripts/check_dashboard_roundtrip.sh [--skips-file <path>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${REPO_ROOT}/stacks/observability"
DASHBOARD_DIR="${STACK}/grafana/dashboards"
BOOT_SECONDS="${BOOT_SECONDS:-90}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

# --skips-file <path>: append a line if this check skips. Same contract as
# scripts/check_loki_rules.sh and scripts/lint.sh — scripts/validate.sh passes
# an mktemp it removes on exit and adds the line count to its SKIPPED total, so
# a skip here cannot be mistaken for a pass (#68).
SKIPS_FILE=""
while (($#)); do
  case "$1" in
    --skips-file) SKIPS_FILE="${2:?--skips-file needs a path}"; shift ;;
    -h|--help) sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -d "${DASHBOARD_DIR}" ]] || die "no dashboards at ${DASHBOARD_DIR}"

# Settled before anything with a side effect, for the same reason
# check_loki_rules.sh settles it first: a check that cannot run must say so, and
# must neither fail nor pass.
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  msg="no docker daemon — dashboard round trip not verified"
  printf '\033[0;33m  SKIP\033[0m %s\n' "${msg}"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "${msg}" >> "${SKIPS_FILE}"
  exit 0
fi
command -v python3 >/dev/null 2>&1 || {
  msg="python3 not installed — dashboard round trip not verified"
  printf '\033[0;33m  SKIP\033[0m %s\n' "${msg}"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "${msg}" >> "${SKIPS_FILE}"
  exit 0
}

# Resolved from compose.yaml — see scripts/image-for.sh. Hardcoding it would
# mean CI checking the round trip against a Grafana the stack does not run,
# which is precisely how a normalisation change would slip past (#68).
GRAFANA_IMAGE="$("${REPO_ROOT}/scripts/image-for.sh" grafana)"

WORK="$(mktemp -d)"
CONTAINER="homelab-roundtrip-$$"
cleanup() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${WORK}/dashboards" "${WORK}/provisioning/dashboards" \
         "${WORK}/provisioning/datasources" "${WORK}/fetched" "${WORK}/scratch"
cp "${DASHBOARD_DIR}"/*.json "${WORK}/dashboards/"
cp "${DASHBOARD_DIR}"/*.json "${WORK}/scratch/"
cp "${STACK}/grafana/provisioning/dashboards/dashboards.yaml" \
   "${WORK}/provisioning/dashboards/"
cp "${STACK}/grafana/provisioning/datasources/datasources.yaml" \
   "${WORK}/provisioning/datasources/"

# Grafana runs as uid 472 and mktemp -d creates a 0700 directory owned by the
# invoking user. Without this it cannot read its own provisioning, exits, and
# the run looks like "the dashboards did not round-trip" rather than a
# permissions problem — the same trap check_loki_rules.sh documents for uid
# 10001. Throwaway directory, so the broad mode is fine.
chmod -R a+rX "${WORK}"

n_dash="$(find "${DASHBOARD_DIR}" -maxdepth 1 -name '*.json' -type f | wc -l)"
info "booting ${GRAFANA_IMAGE%%@*} with ${n_dash} provisioned dashboard(s)"

# No published port: everything below goes through `docker exec`, so this cannot
# collide with the Grafana already serving on this host, and CI needs no free
# port. Anonymous admin rather than a password, because a throwaway needs no
# credential and a literal one in a script is a thing gitleaks would have to be
# taught to ignore.
#
# The datasource URLs are never contacted — no panel is queried here — but
# provisioning fails to parse without the variables, and a datasource that fails
# to provision takes the dashboard provisioner down with it.
docker run -d --name "${CONTAINER}" \
  -e GF_AUTH_ANONYMOUS_ENABLED=true \
  -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
  -e GF_AUTH_BASIC_ENABLED=false \
  -e GF_ANALYTICS_REPORTING_ENABLED=false \
  -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
  -e PROMETHEUS_URL=http://127.0.0.1:9090 \
  -e LOKI_URL=http://127.0.0.1:3100 \
  -v "${WORK}/provisioning:/etc/grafana/provisioning:ro" \
  -v "${WORK}/dashboards:/var/lib/grafana/dashboards:ro" \
  "${GRAFANA_IMAGE}" >/dev/null \
  || die "could not start ${GRAFANA_IMAGE}"

# api/health answers before provisioning has finished, so readiness is measured
# by the dashboards actually being there rather than by the process being up.
# Polling for the first uid is what distinguishes "still provisioning" from
# "provisioned nothing", and a fixed sleep gets that wrong in both directions.
first_uid="$(python3 -c '
import json, pathlib, sys
print(json.loads(sorted(pathlib.Path(sys.argv[1]).glob("*.json"))[0].read_text())["uid"])
' "${DASHBOARD_DIR}")"

api() {
  # busybox wget, which is what the image ships and what the compose healthcheck
  # already relies on. -O- to stdout; the caller decides what to do with it.
  docker exec "${CONTAINER}" wget -q -O- "http://localhost:3000$1"
}

ready=0
for _ in $(seq 1 "$((BOOT_SECONDS / 2))"); do
  if api "/api/dashboards/uid/${first_uid}" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if ((!ready)); then
  printf '\033[0;31m  FAIL\033[0m grafana did not provision %s within %ss\n' \
    "${first_uid}" "${BOOT_SECONDS}"
  docker logs "${CONTAINER}" 2>&1 | tail -n 20 | sed 's/^/        /'
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Round trip
# ---------------------------------------------------------------------------
while read -r uid; do
  api "/api/dashboards/uid/${uid}" > "${WORK}/fetched/${uid}.json" \
    || die "grafana provisioned no dashboard with uid '${uid}'"
done < <(python3 -c '
import json, pathlib, sys
for path in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    print(json.loads(path.read_text(encoding="utf-8"))["uid"])
' "${DASHBOARD_DIR}")

# Held rather than streamed, so a passing run says one line and a failing one
# still shows the whole diff — which is the only output that says *what* drifted.
if python3 "${REPO_ROOT}/scripts/export_dashboards.py" \
     --fetched "${WORK}/fetched" --dashboards "${DASHBOARD_DIR}" --check \
     > "${WORK}/roundtrip.out" 2>&1; then
  printf '\033[0;32m  PASS\033[0m %s dashboard(s) round-trip through grafana unchanged\n' "${n_dash}"
else
  printf '\033[0;31m  FAIL\033[0m the committed JSON is not what grafana produces from it\n'
  sed 's/^/        /' "${WORK}/roundtrip.out"
  printf '        Run '\''make dashboards-export'\'' against a live stack to normalise it.\n'
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. UI saves are accepted — i.e. allowUiUpdates is still true
# ---------------------------------------------------------------------------
MARKER="round-trip probe $$"
python3 - "${WORK}/fetched/${first_uid}.json" "${WORK}/save.json" "${MARKER}" <<'SAVE_PY'
import json, sys
dashboard = json.load(open(sys.argv[1]))["dashboard"]
# A description is edited rather than a panel added, so what travels is a plain
# string that cannot be confused with something Grafana normalised on the way.
dashboard["description"] = sys.argv[3]
json.dump({"dashboard": dashboard, "overwrite": True, "message": "round-trip probe"},
          open(sys.argv[2], "w"))
SAVE_PY

docker cp "${WORK}/save.json" "${CONTAINER}:/tmp/save.json" >/dev/null
save_out="$(docker exec "${CONTAINER}" wget -q -O- \
  --header='Content-Type: application/json' \
  --post-file=/tmp/save.json \
  http://localhost:3000/api/dashboards/db 2>&1)" || save_out="${save_out:-<no response>}"

if [[ "${save_out}" != *'"status":"success"'* ]]; then
  printf '\033[0;31m  FAIL\033[0m grafana refused a UI-shaped save to a provisioned dashboard\n'
  printf '        %s\n' "${save_out}"
  printf '        make dashboards-export cannot capture an edit that grafana will\n'
  printf '        not store. Check allowUiUpdates in\n'
  printf '        grafana/provisioning/dashboards/dashboards.yaml — while it is false\n'
  printf '        the export is a silent no-op (#100).\n'
  exit 1
fi
printf '\033[0;32m  PASS\033[0m grafana stores a save to a provisioned dashboard (allowUiUpdates)\n'

# ---------------------------------------------------------------------------
# 3. End to end: the stored edit reaches the file
# ---------------------------------------------------------------------------
api "/api/dashboards/uid/${first_uid}" > "${WORK}/fetched/${first_uid}.json" \
  || die "could not re-fetch ${first_uid} after saving it"

# Written into the scratch copy taken before the container started, never into
# the committed directory: a check that edits the tree it is checking is one
# failed run away from a dirty repository.
if ! python3 "${REPO_ROOT}/scripts/export_dashboards.py" \
       --fetched "${WORK}/fetched" --dashboards "${WORK}/scratch" >/dev/null; then
  printf '\033[0;31m  FAIL\033[0m the export could not fold the saved edit back in\n'
  exit 1
fi

if grep -qF "${MARKER}" "${WORK}/scratch/"*.json; then
  printf '\033[0;32m  PASS\033[0m a UI edit travels from the API into the dashboard file\n'
else
  printf '\033[0;31m  FAIL\033[0m the export ran but the saved edit did not reach the file\n'
  printf '        scripts/export_dashboards.py dropped a change grafana had stored.\n'
  exit 1
fi
