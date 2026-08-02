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

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${REPO_ROOT}/stacks/observability"
LOKI_IMAGE="grafana/loki:3.3.2"
BOOT_SECONDS="${BOOT_SECONDS:-45}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

RULES_DIR="${STACK}/loki/rules"
[[ -d "${RULES_DIR}" ]] || die "no rules directory at ${RULES_DIR}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
# auth_enabled is false, so Loki's local ruler looks under <dir>/fake/.
mkdir -p "${WORK}/rules/fake" "${WORK}/data"
cp "${RULES_DIR}"/*.yaml "${WORK}/rules/fake/"

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

n_rules="$(grep -ch '^ *- alert:' "${RULES_DIR}"/*.yaml | paste -sd+ | bc)"
info "checking ${n_rules} Loki rule(s)"

if command -v loki >/dev/null 2>&1; then
  RUN=(loki)
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  RUN=(docker run --rm -v "${WORK}:${WORK}" -w "${WORK}" --entrypoint loki "${LOKI_IMAGE}")
else
  printf '\033[0;33m  SKIP\033[0m no loki binary and no docker daemon\n'
  exit 0
fi

OUT="${WORK}/loki.log"
timeout "${BOOT_SECONDS}" "${RUN[@]}" \
  -config.file="${WORK}/loki.yaml" -target=all \
  -server.http-listen-port=3197 > "${OUT}" 2>&1

if grep -qiE 'parse error|failed to parse|syntax error' "${OUT}"; then
  printf '\033[0;31m  FAIL\033[0m LogQL parse error in the Loki rules\n'
  grep -iE 'parse error|failed to parse|syntax error' "${OUT}" | head -5
  exit 1
fi

# Confirm the ruler actually loaded them. A silent "no errors" is not evidence
# if the ruler never read the files at all.
evaluated="$(grep -o 'rule_name=[A-Za-z]*' "${OUT}" | sort -u | wc -l)"
if ((evaluated == 0)); then
  printf '\033[0;31m  FAIL\033[0m the ruler evaluated no rules — check the tenant path\n'
  exit 1
fi

printf '\033[0;32m  PASS\033[0m %s Loki rule(s) parsed, %s evaluated by the ruler\n' \
  "${n_rules}" "${evaluated}"
