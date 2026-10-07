#!/usr/bin/env bash
#
# Prove that the network syslog listener stores only what its senders send (#844).
#
# syslog.alloy publishes a UDP listener that morpheus writes filterlog and
# Suricata lines to, and the Loki security rules read those lines by
# {host="morpheus"}. Before #844 any host that could reach the port could
# write such lines, and a message's own hostname field overrode the label.
# This boots the pinned Loki and the pinned Alloy, loading syslog.alloy and
# nothing else, on a scratch Docker network where every sender has a fixed
# address. It then sends three lines:
#
#   1. from the allowed address, shaped as pfSense sends (no hostname)
#      -> stored, host="morpheus"
#   2. from another address, claiming hostname `morpheus`
#      -> absent, and the drop counter has counted it
#   3. from the allowed address, claiming hostname `evil`
#      -> stored, host="morpheus": the message hostname is not trusted
#
# Case 2 is checked for absence only after cases 1 and 3, which were sent
# after it, have arrived. "Absent" therefore means refused, not slow. The
# counter shows that it reached Alloy at all.
#
# The one change made to syslog.alloy: the scratch network cannot be
# 10.0.99.0/24 without taking the monitoring host's real route to VLAN 99, so
# the allowed address literal is rewritten to the scratch "morpheus". The
# rewrite has to match at least once, or this fails rather than testing a file
# with no allowlist in it.
#
# Usage: scripts/check_syslog_senders.sh [--skips-file PATH] [--alloy-file PATH]
#   --alloy-file  test a different syslog config (used to measure alternatives
#                 and to check that this check fails when the fix is reverted)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOY_FILE="${REPO_ROOT}/stacks/observability/alloy/syslog.alloy"
SKIPS_FILE=""

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }

while (($#)); do
  case "$1" in
    --skips-file) SKIPS_FILE="${2:?--skips-file needs a path}"; shift ;;
    --alloy-file) ALLOY_FILE="${2:?--alloy-file needs a path}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
[[ -f "${ALLOY_FILE}" ]] || die "no such file: ${ALLOY_FILE}"

# Fixed addresses need a user-defined Docker network, so there is no
# native-binary fallback the way check_loki_rules.sh has one. Recorded as a
# skip and not passed, on the same contract (#68).
if ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
  msg="no docker daemon — syslog sender allowlist not exercised"
  printf '\033[0;33m  SKIP\033[0m %s\n' "${msg}"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "${msg}" >> "${SKIPS_FILE}"
  exit 0
fi

LOKI_IMAGE="$("${REPO_ROOT}/scripts/image-for.sh" loki)"
ALLOY_IMAGE="$("${REPO_ROOT}/scripts/image-for.sh" alloy)"

# A /24 nothing in the lab uses. Docker adds a host route for it while the
# network exists, so it must not overlap anything real.
NET_PREFIX="172.31.244"
LOKI_IP="${NET_PREFIX}.2"
ALLOY_IP="${NET_PREFIX}.3"
ALLOWED_IP="${NET_PREFIX}.10"
STRANGER_IP="${NET_PREFIX}.11"

TAG="syslogcheck-$$"
NET="${TAG}"
WORK="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329  # reached through the EXIT trap
cleanup() {
  docker rm -f "${TAG}-loki" "${TAG}-alloy" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

# The one PyYAML bootstrap (#848), as in check_loki_rules.sh: the host's
# python3-yaml, or on a runner the hash-pinned scripts/requirements.txt.
pydeps="$(python3 "${REPO_ROOT}/scripts/_deps.py" --pythonpath)" \
  || die "PyYAML is required: sudo apt install python3-yaml"
[[ -n "${pydeps}" ]] && export PYTHONPATH="${pydeps}${PYTHONPATH:+:${PYTHONPATH}}"

mkdir -p "${WORK}/data" "${WORK}/rules/fake" "${WORK}/alloy"
python3 "${REPO_ROOT}/scripts/loki_scratch_config.py" \
  "${REPO_ROOT}/stacks/observability/loki/loki-config.yaml" "${WORK}" --for-tests \
  > "${WORK}/loki.yaml"

# The address rewrite, asserted to happen at all.
python3 - "${ALLOY_FILE}" "${WORK}/alloy/syslog.alloy" "${ALLOWED_IP}" <<'REWRITE'
import sys
src, dst, ip = sys.argv[1:]
text = open(src, encoding="utf-8").read()
old = '"10\\\\.0\\\\.99\\\\.1"'
new = '"' + ip.replace(".", "\\\\.") + '"'
n = text.count(old)
if n == 0:
    sys.exit(f"the allowed-sender literal {old} is not in {src}: nothing to test")
open(dst, "w", encoding="utf-8").write(text.replace(old, new))
REWRITE
chmod -R a+rwX "${WORK}"

docker network create --subnet "${NET_PREFIX}.0/24" --gateway "${NET_PREFIX}.1" "${NET}" >/dev/null

# homelab.logs=off keeps production Alloy, if it is running on this daemon,
# from ingesting these containers' own output.
docker run -d --name "${TAG}-loki" --label homelab.logs=off \
  --network "${NET}" --ip "${LOKI_IP}" --user "$(id -u):$(id -g)" \
  -v "${WORK}:${WORK}" -w "${WORK}" "${LOKI_IMAGE}" \
  -config.file="${WORK}/loki.yaml" -target=all >/dev/null

docker run -d --name "${TAG}-alloy" --label homelab.logs=off \
  --network "${NET}" --ip "${ALLOY_IP}" \
  -e LOKI_URL="http://${LOKI_IP}:3100/loki/api/v1/push" \
  -v "${WORK}/alloy:/etc/alloy:ro" "${ALLOY_IMAGE}" \
  run --server.http.listen-addr=0.0.0.0:12345 --storage.path=/tmp/alloy /etc/alloy >/dev/null

wait_for() { # url seconds
  local i
  for ((i = 0; i < $2; i++)); do
    curl -fsS -m 2 "$1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

wait_for "http://${LOKI_IP}:3100/ready" 90 || {
  docker logs --tail 20 "${TAG}-loki" 2>&1 | sed 's/^/        /'
  die "scratch Loki never became ready"
}
# What has to be up is the UDP listener, so wait for its own metric rather
# than /-/ready: on a busy daemon /-/ready once took past 60s while the log
# already said "syslog listening". A UDP line sent before the listener exists
# is lost without an error, so this is a hard wait, not a sleep.
alloy_up=0
for ((i = 0; i < 120; i++)); do
  if curl -fsS -m 2 "http://${ALLOY_IP}:12345/metrics" 2>/dev/null \
       | grep -q '^loki_source_syslog'; then
    alloy_up=1
    break
  fi
  sleep 1
done
if ((!alloy_up)); then
  docker logs --tail 20 "${TAG}-alloy" 2>&1 | sed 's/^/        /'
  curl -sS -m 2 "http://${ALLOY_IP}:12345/-/ready" 2>&1 | sed 's/^/        ready: /' || true
  die "scratch Alloy's syslog listener never came up"
fi

dropped() {
  curl -fsS -m 5 "http://${ALLOY_IP}:12345/metrics" \
    | awk '/^loki_process_dropped_lines_total\{/ && /reason="syslog_sender_not_allowed"/ {s += $NF} END {print s + 0}'
}

send() { # from-ip line
  docker run --rm --label homelab.logs=off --network "${NET}" --ip "$1" \
    --entrypoint bash "${ALLOY_IMAGE}" \
    -c 'printf "%s\n" "$1" > "/dev/udp/$2/1514"' _ "$2" "${ALLOY_IP}"
}

RUN_ID="$(date +%s)-$$"
TOK_ALLOWED="allowed-${RUN_ID}"
TOK_SPOOF="spoofed-${RUN_ID}"
TOK_EVIL="evilname-${RUN_ID}"
STAMP="$(LC_ALL=C date -u '+%b %e %H:%M:%S')"

dropped_before="$(dropped)"
# The spoof goes first. See the header for why the order matters.
send "${STRANGER_IP}" "<134>${STAMP} morpheus filterlog[4242]: ${TOK_SPOOF},,,1000000103,igc0.20,match,block,in,4"
send "${ALLOWED_IP}"  "<134>${STAMP} filterlog[4242]: ${TOK_ALLOWED},,,1000000103,igc0.20,match,block,in,4"
send "${ALLOWED_IP}"  "<134>${STAMP} evil filterlog[4242]: ${TOK_EVIL},,,1000000103,igc0.20,match,block,in,4"

# Prints the label set of every stream holding the token, one JSON per line.
streams_with() {
  python3 - "http://${LOKI_IP}:3100" "$1" <<'QUERY'
import json, sys, time, urllib.parse, urllib.request
base, token = sys.argv[1:]
now = time.time_ns()
q = urllib.parse.urlencode({
    "query": '{source="network"} |= "%s"' % token,
    "start": now - 600 * 10**9, "end": now + 60 * 10**9, "limit": 100,
})
with urllib.request.urlopen(f"{base}/loki/api/v1/query_range?{q}", timeout=10) as r:
    for s in json.load(r)["data"]["result"]:
        print(json.dumps(s["stream"], sort_keys=True))
QUERY
}

wait_streams() { # token seconds -> prints streams once present
  local out i
  for ((i = 0; i < $2; i++)); do
    out="$(streams_with "$1" || true)"
    [[ -n "${out}" ]] && { printf '%s\n' "${out}"; return 0; }
    sleep 1
  done
  return 1
}

FAILED=0
info "sent three lines through ${ALLOY_FILE#"${REPO_ROOT}"/}"

# host_is <streams> — every stream carries host="morpheus" and nothing else
# says `evil`.
host_is_morpheus() {
  python3 -c '
import json, sys
streams = [json.loads(l) for l in sys.stdin if l.strip()]
ok = streams and all(s.get("host") == "morpheus" and "evil" not in s.values() for s in streams)
sys.exit(0 if ok else 1)'
}

if s1="$(wait_streams "${TOK_ALLOWED}" 45)"; then
  if printf '%s\n' "${s1}" | host_is_morpheus; then
    pass "allowed sender stored as host=\"morpheus\""
  else
    fail "allowed sender stored with the wrong labels: ${s1}"
  fi
else
  fail "allowed sender's line never reached Loki"
fi

if s3="$(wait_streams "${TOK_EVIL}" 15)"; then
  if printf '%s\n' "${s3}" | host_is_morpheus; then
    pass "a message hostname of \"evil\" does not override host=\"morpheus\""
  else
    fail "the message hostname set the labels: ${s3}"
  fi
else
  fail "allowed sender's line with a hostname never reached Loki"
fi

# Absence is only evidence when the query itself succeeded. A timeout or an
# HTTP error prints nothing too, and must not read as "not stored".
if ! s2="$(streams_with "${TOK_SPOOF}")"; then
  fail "the Loki query for the spoofed line failed, so its absence is unproven"
elif [[ -z "${s2}" ]]; then
  pass "a line from ${STRANGER_IP} claiming hostname \"morpheus\" is not in Loki"
else
  fail "a line from an unlisted sender was stored: ${s2}"
fi

dropped_after="$(dropped)"
if ((dropped_after - dropped_before == 1)); then
  pass "the refused line is counted (reason=\"syslog_sender_not_allowed\")"
else
  fail "drop counter moved by $((dropped_after - dropped_before)), expected 1"
fi

exit "${FAILED}"
