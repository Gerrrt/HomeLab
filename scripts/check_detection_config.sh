#!/usr/bin/env bash
#
# Check the detection and sensor configuration the SOC and the sensor run.
#
# Nothing validated these (#1426). A malformed Wazuh rule, an ossec.conf the
# manager refuses or a Zeek script that does not parse merged green and broke
# only on odin or fenrir, which are exactly the configs a detection exercise
# depends on.
#
# Static, everywhere (python3, no network):
#   - stacks/soc/wazuh/manager/rules/local_rules.xml, ossec.conf and
#     shared/default/agent.conf parse as XML (Wazuh's files may hold several
#     top-level elements, so each is read inside a wrapper);
#   - every rule id in local_rules.xml is unique and inside the range the
#     file's header gives itself, 100100-100199;
#   - the indexer's two JSON files parse.
#
# In the pinned images, when docker is reachable (SKIP otherwise):
#   - `wazuh-analysisd -t` in compose.yaml's wazuh-manager, with the three
#     files mounted where the manager reads them;
#   - `zeek --parse-only` in compose.yaml's zeek, with local.zeek and the
#     vendored ja4 mounted as stacks/sensor/compose.yaml mounts them.
#
# Not covered: Velociraptor's init.vql (no offline parser) and the analyst's
# scan0-egress.nft (nft -c needs CAP_NET_ADMIN).
#
# Usage: scripts/check_detection_config.sh [--skips-file PATH]
#   --skips-file  append each SKIP's reason, as the other docker-backed checks
#                 do, so validate.sh counts it and require-no-skip.sh fails it
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

SKIPS_FILE=""
while (($#)); do
  case "$1" in
    --skips-file) SKIPS_FILE="${2:?--skips-file needs a path}"; shift 2 ;;
    *) printf 'usage: %s [--skips-file PATH]\n' "$0" >&2; exit 2 ;;
  esac
done

FAILED=0
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() {
  printf '\033[0;33m  SKIP\033[0m %s\n' "$*"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "$*" >> "${SKIPS_FILE}"
  return 0
}

WAZUH=stacks/soc/wazuh
RULES="${WAZUH}/manager/rules/local_rules.xml"
OSSEC="${WAZUH}/manager/ossec.conf"
AGENT="${WAZUH}/manager/shared/default/agent.conf"
ZEEK_LOCAL=stacks/sensor/zeek/local.zeek
ZEEK_JA4=stacks/sensor/zeek/ja4

# --- static -----------------------------------------------------------------
if out="$(python3 -I - "${RULES}" "${OSSEC}" "${AGENT}" "${WAZUH}"/indexer/*.json 2>&1 <<'PY'
import json, re, sys, xml.etree.ElementTree as ET
problems = []
rules, ossec, agent, *jsons = sys.argv[1:]
trees = {}
for f in (rules, ossec, agent):
    text = open(f, encoding="utf-8").read()
    # Wazuh files may have several top-level elements and a leading comment.
    try:
        trees[f] = ET.fromstring("<wrap>" + re.sub(r"^\s*<\?xml[^>]*\?>", "", text) + "</wrap>")
        print(f"ok   {f} parses as XML")
    except ET.ParseError as e:
        problems.append(f"{f}: not well-formed XML: {e}")
if rules in trees:
    ids = [r.get("id") for r in trees[rules].iter("rule")]
    seen, dupes = set(), set()
    for i in ids:
        (dupes if i in seen else seen).add(i)
    if dupes:
        problems.append(f"{rules}: duplicate rule id(s) {sorted(dupes)}")
    bad = [i for i in ids if not (i and i.isdigit() and 100100 <= int(i) <= 100199)]
    if bad:
        problems.append(f"{rules}: rule id(s) outside 100100-100199 or not numeric: {bad}")
    if not ids:
        problems.append(f"{rules}: no <rule> at all")
    if not dupes and not bad and ids:
        print(f"ok   {rules}: {len(ids)} rule ids, unique, all in 100100-100199")
for f in jsons:
    try:
        json.load(open(f, encoding="utf-8"))
        print(f"ok   {f} parses as JSON")
    except ValueError as e:
        problems.append(f"{f}: not valid JSON: {e}")
for p in problems:
    print("FAIL " + p)
sys.exit(1 if problems else 0)
PY
)"; then
  pass "Wazuh XML and indexer JSON: $(grep -c '^ok' <<<"${out}") checks"
else
  printf '%s\n' "${out}" | grep -v '^ok' | sed 's/^/        /'
  fail "Wazuh XML or indexer JSON"
fi

# --- in the pinned images -------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  skip "no docker daemon — wazuh-analysisd -t and zeek --parse-only not run"
  exit "${FAILED}"
fi

manager="$(COMPOSE_FILE=stacks/soc/compose.yaml ./scripts/image-for.sh wazuh-manager)"
if out="$(docker run --rm --network none --entrypoint /var/ossec/bin/wazuh-analysisd \
      -v "${REPO_ROOT}/${OSSEC}:/var/ossec/etc/ossec.conf:ro" \
      -v "${REPO_ROOT}/${RULES}:/var/ossec/etc/rules/local_rules.xml:ro" \
      -v "${REPO_ROOT}/${AGENT}:/var/ossec/etc/shared/default/agent.conf:ro" \
      "${manager}" -t 2>&1)"; then
  pass "wazuh-analysisd -t accepts ossec.conf and the rules (${manager%%@*})"
else
  printf '%s\n' "${out}" | tail -20 | sed 's/^/        /'
  fail "wazuh-analysisd -t rejects the configuration (${manager%%@*})"
fi

zeek="$(COMPOSE_FILE=stacks/sensor/compose.yaml ./scripts/image-for.sh zeek)"
if out="$(docker run --rm --network none --entrypoint zeek -w /tmp \
      -v "${REPO_ROOT}/${ZEEK_LOCAL}:/zeek/site/local.zeek:ro" \
      -v "${REPO_ROOT}/${ZEEK_JA4}:/zeek/site/ja4:ro" \
      "${zeek}" --parse-only local /zeek/site/local.zeek 2>&1)"; then
  pass "zeek --parse-only accepts local.zeek and ja4 (${zeek%%@*})"
else
  printf '%s\n' "${out}" | tail -20 | sed 's/^/        /'
  fail "zeek --parse-only rejects local.zeek or ja4 (${zeek%%@*})"
fi

exit "${FAILED}"
