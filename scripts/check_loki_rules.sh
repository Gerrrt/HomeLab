#!/usr/bin/env bash
#
# Validate the Loki alerting rules, and the LogQL in the Grafana dashboards.
#
# There is no `promtool check rules` equivalent for LogQL: promtool parses
# PromQL and rejects every stream selector in these files. The only tool that
# genuinely understands LogQL is Loki itself, so this boots the pinned Loki
# image against a throwaway config with the rules mounted, and fails if the
# ruler reports a parse error.
#
# `-verify-config` alone is NOT sufficient — it validates the config file and
# never looks at the rule files. Verified: a rule file containing
# `count_over_time({{{BROKEN` passes -verify-config and is only caught here.
#
# The dashboards ride along because a panel query is as easy to typo as a rule
# and fails more quietly: a broken one renders an empty panel, and "no data" is
# indistinguishable from "this is broken". CI already hands the Prometheus half
# of the panels to promtool for exactly that reason; LogQL had no equivalent,
# so a typo in a Loki panel reached production unchallenged.
#
# Usage: scripts/check_loki_rules.sh [--stack NAME] [--skips-file PATH]

# -e is on: a failed cp or config rewrite must not produce a cheerful PASS.
# The one command allowed to fail is the timeout below, which is guarded.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_NAME="observability"
# Resolved from compose.yaml — see scripts/image-for.sh.
LOKI_IMAGE="$("${REPO_ROOT}/scripts/image-for.sh" loki)"
BOOT_SECONDS="${BOOT_SECONDS:-45}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

# --skips-file <path>: append a line if this check skips. scripts/validate.sh
# passes an mktemp it removes on exit and adds the line count to its SKIPPED
# total, so a skip here cannot be mistaken for a pass. The caller owns the path.
SKIPS_FILE=""
while (($#)); do
  case "$1" in
    --skips-file) SKIPS_FILE="${2:?--skips-file needs a path}"; shift ;;
    --stack) STACK_NAME="${2:?--stack needs a name}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

STACK="${REPO_ROOT}/stacks/${STACK_NAME}"
[[ -f "${STACK}/compose.yaml" ]] || die "no such stack: ${STACK}"
RULES_DIR="${STACK}/loki/rules"

# A stack may legitimately have neither Loki rules nor dashboards. `stacks/lab`
# has both absences on purpose: its Loki carries no ruler, because a ruler needs
# an Alertmanager to deliver to and that stack has none (ADR-0020), and it ships
# no dashboards yet. With nothing to parse there is nothing this check can say,
# and it exits 0 saying so.
#
# NOT a skip. A skip means "this could not run and therefore proved nothing",
# and validate.sh counts skips precisely so a run cannot claim to have checked
# what it did not (#68). This ran, and there was nothing to check — a different
# statement, and mislabelling it would inflate the skip count on every run
# forever until it stopped being read.
n_committed=0
if [[ -d "${RULES_DIR}" ]]; then
  shopt -s nullglob
  rule_files=("${RULES_DIR}"/*.yaml)
  shopt -u nullglob
  n_committed=${#rule_files[@]}
fi
shopt -s nullglob
dash_files=("${STACK}/grafana/dashboards"/*.json)
shopt -u nullglob
if ((n_committed == 0 && ${#dash_files[@]} == 0)); then
  printf '\033[0;32m  PASS\033[0m %s\n' \
    "${STACK_NAME}: no Loki rules and no dashboards — nothing to parse"
  exit 0
fi

# Whether this run can happen at all is decided FIRST, before anything with a
# side effect or a failure mode of its own.
#
# Everything below needs a scratch directory, may pip install PyYAML, and
# shells out to check_dashboards.py to emit the panel queries. Doing any of
# that before knowing there is a Loki to run it against turned an intended SKIP
# into a hard failure on a host with no python3 — and recorded no skip while
# failing, which is the precise confusion #68 was about: a check that did not
# run must say so. It must not fail, and it must not pass.
#
# Only availability is settled here. The docker command line needs ${WORK},
# which does not exist yet, so the runner is named now and built below.
if command -v loki >/dev/null 2>&1; then
  RUNNER=loki
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  RUNNER=docker
else
  # Recorded, not just printed. scripts/validate.sh counts the lines of this
  # file into its SKIPPED total; without it this exit 0 read as a pass and the
  # run could sign off with an unqualified "all checks passed" over rules that
  # were never validated (#68). Same contract as scripts/lint.sh and
  # scripts/seed-validation-env.sh: the caller owns the path and its lifetime.
  msg="no loki binary and no docker daemon"
  printf '\033[0;33m  SKIP\033[0m %s\n' "${msg}"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "${msg}" >> "${SKIPS_FILE}"
  exit 0
fi

WORK="$(mktemp -d)"
# Loki writes as its own uid; never let cleanup failure mask the result.
trap 'rm -rf "${WORK}" 2>/dev/null || true' EXIT
# auth_enabled is false, so Loki's local ruler looks under <dir>/fake/.
mkdir -p "${WORK}/rules/fake" "${WORK}/data"
# An `if` and not `((n_committed)) && cp ...`: under `set -e` that one-liner
# exits the script when the count is zero, because the && chain's status
# becomes the failed arithmetic. A stack with dashboards but no rules would
# have died here reporting nothing.
if ((n_committed)); then
  cp "${RULES_DIR}"/*.yaml "${WORK}/rules/fake/"
fi

# Dashboard LogQL, as an extra rule file so it takes precisely the same path
# through the ruler as the committed rules — same parser, same failure output,
# no second code path to keep honest.
#
# Asked for only when the stack HAS dashboards. check_dashboards.py --emit-logql
# still fails on an empty directory, deliberately: its output is the file that
# proves the panel queries parse, so emitting nothing over a vanished dashboard
# directory would pass this check over nothing (#68). The guard belongs here,
# where "this stack ships no dashboards" is known, rather than in the emitter,
# where it cannot be told apart from "the dashboards are gone".
DASH_RULES="${WORK}/rules/fake/dashboard-expressions.rules.yaml"
n_dash=0
if ((${#dash_files[@]})); then
  if ! python3 "${REPO_ROOT}/scripts/check_dashboards.py" --stack "${STACK_NAME}" --emit-logql \
       > "${DASH_RULES}" 2> "${WORK}/emit.err"; then
    cat "${WORK}/emit.err" >&2
    die "could not emit dashboard LogQL"
  fi
  n_dash="$(grep -c '^ *- alert:' "${DASH_RULES}" || true)"
fi

# The Loki image runs as uid 10001, while mktemp -d creates a 0700 directory
# owned by the invoking user. Without this the container cannot read its own
# config, exits within seconds, and the run looks like "the ruler evaluated
# nothing" rather than a permissions problem. Throwaway directory, so the broad
# mode is fine.
chmod -R a+rwX "${WORK}"

# PyYAML is not guaranteed on a clean runner, and the failure mode without this
# guard is an opaque ModuleNotFoundError inside a heredoc.
if ! python3 -c 'import yaml' 2>/dev/null; then
  info "installing PyYAML"
  python3 -m pip install --quiet --disable-pip-version-check pyyaml >/dev/null 2>&1 \
    || die "PyYAML is required and could not be installed"
fi

# Rewrite every path in the real config to point inside the scratch dir, so the
# rules are checked against the same settings production uses.
python3 - "$STACK/loki/loki-config.yaml" "${WORK}" > "${WORK}/loki.yaml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
work = sys.argv[2]
cfg["common"]["path_prefix"] = f"{work}/data"
cfg["common"]["storage"]["filesystem"] = {
    "chunks_directory": f"{work}/data/chunks", "rules_directory": f"{work}/data/rules"}
cfg["storage_config"]["tsdb_shipper"] = {
    "active_index_directory": f"{work}/data/index", "cache_location": f"{work}/data/cache"}
cfg["storage_config"]["filesystem"] = {"directory": f"{work}/data/chunks"}
cfg["compactor"]["working_directory"] = f"{work}/data/compactor"
cfg["ruler"]["storage"]["local"]["directory"] = f"{work}/rules"
cfg["ruler"]["rule_path"] = f"{work}/data/rules-temp"
yaml.safe_dump(cfg, sys.stdout)
PY

# Rule groups use interval: 1m in production, and Loki jitters a group's first
# evaluation across that interval — so a short boot window can legitimately see
# no evaluations, which looks identical to a misconfigured tenant path. Shorten
# the interval in the throwaway copies only; the committed rules and their LogQL
# are untouched.
python3 - "${WORK}/rules/fake" <<'SPEEDUP'
import pathlib, sys, yaml
for f in pathlib.Path(sys.argv[1]).glob("*.yaml"):
    doc = yaml.safe_load(f.read_text())
    for group in doc.get("groups", []):
        group["interval"] = "5s"
    f.write_text(yaml.safe_dump(doc))
SPEEDUP

n_rules="$(grep -ch '^ *- alert:' "${RULES_DIR}"/*.yaml | paste -sd+ | bc || true)"
info "checking ${n_rules} Loki rule(s) and ${n_dash} dashboard expression(s)"

if [[ "${RUNNER}" == "loki" ]]; then
  RUN=(loki)
else
  # --user: without it Loki writes as uid 10001 and the runner cannot delete
  # the scratch directory afterwards, filling the log with rm errors.
  RUN=(docker run --rm --user "$(id -u):$(id -g)" \
       -v "${WORK}:${WORK}" -w "${WORK}" --entrypoint loki "${LOKI_IMAGE}")
fi

OUT="${WORK}/loki.log"
# Re-apply after loki.yaml was generated above, so the container user can read
# it too.
chmod -R a+rwX "${WORK}" 2>/dev/null || true
# Loki runs until killed, so a 124 from timeout is the expected outcome.
rc=0
timeout "${BOOT_SECONDS}" "${RUN[@]}" \
  -config.file="${WORK}/loki.yaml" -target=all \
  -server.http-listen-port=3197 > "${OUT}" 2>&1 || rc=$?

if grep -qiE 'parse error|failed to parse|syntax error' "${OUT}"; then
  printf '\033[0;31m  FAIL\033[0m LogQL parse error in the rules or a dashboard panel\n'
  printf '        A DashboardExpr<n> name is a panel query; run\n'
  printf '        scripts/check_dashboards.py --emit-logql to see which.\n'
  grep -iE 'parse error|failed to parse|syntax error' "${OUT}" | head -5
  exit 1
fi

# Confirm the ruler actually loaded them. A silent "no errors" is not evidence
# if the ruler never read the files at all.
evaluated="$(grep -oE 'rule_name="?[A-Za-z_][A-Za-z0-9_]*' "${OUT}" \
             | sed 's/^rule_name="\?//' | sort -u | wc -l || true)"
if ((evaluated == 0)); then
  printf '\033[0;31m  FAIL\033[0m the ruler evaluated no rules\n'
  # rc 124 is the timeout we expect (Loki runs until killed). Anything else
  # means Loki died early — usually it could not read the mounted files.
  if ((rc != 124)); then
    printf '        loki exited early with status %s; last output:\n' "${rc}"
  else
    printf '        loki ran the full %ss but never evaluated a rule.\n' "${BOOT_SECONDS}"
    printf '        Check the ruler tenant path (<directory>/fake/).\n'
  fi
  tail -n 15 "${OUT}" | sed 's/^/        /'
  exit 1
fi

printf '\033[0;32m  PASS\033[0m %s Loki rule(s) and %s dashboard expression(s) parsed, %s evaluated by the ruler\n' \
  "${n_rules}" "${n_dash}" "${evaluated}"
