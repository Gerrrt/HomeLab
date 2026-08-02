#!/usr/bin/env bash
#
# Validate the Loki alerting rules.
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
# Usage: scripts/check_loki_rules.sh

# -e is on: a failed cp or config rewrite must not produce a cheerful PASS.
# The one command allowed to fail is the timeout below, which is guarded.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${REPO_ROOT}/stacks/observability"
LOKI_IMAGE="grafana/loki:3.3.2"
BOOT_SECONDS="${BOOT_SECONDS:-45}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

RULES_DIR="${STACK}/loki/rules"
[[ -d "${RULES_DIR}" ]] || die "no rules directory at ${RULES_DIR}"

WORK="$(mktemp -d)"
# Loki writes as its own uid; never let cleanup failure mask the result.
trap 'rm -rf "${WORK}" 2>/dev/null || true' EXIT
# auth_enabled is false, so Loki's local ruler looks under <dir>/fake/.
mkdir -p "${WORK}/rules/fake" "${WORK}/data"
cp "${RULES_DIR}"/*.yaml "${WORK}/rules/fake/"

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
info "checking ${n_rules} Loki rule(s)"

if command -v loki >/dev/null 2>&1; then
  RUN=(loki)
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # --user: without it Loki writes as uid 10001 and the runner cannot delete
  # the scratch directory afterwards, filling the log with rm errors.
  RUN=(docker run --rm --user "$(id -u):$(id -g)" \
       -v "${WORK}:${WORK}" -w "${WORK}" --entrypoint loki "${LOKI_IMAGE}")
else
  printf '\033[0;33m  SKIP\033[0m no loki binary and no docker daemon\n'
  exit 0
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
  printf '\033[0;31m  FAIL\033[0m LogQL parse error in the Loki rules\n'
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

printf '\033[0;32m  PASS\033[0m %s Loki rule(s) parsed, %s evaluated by the ruler\n' \
  "${n_rules}" "${evaluated}"
