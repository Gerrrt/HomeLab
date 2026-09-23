#!/usr/bin/env bash
#
# Boot one service under its real hardening, wait for it to be healthy, and
# throw it away (#534).
#
# WHAT WAS TRUE BEFORE THIS. Home Assistant's hardened configuration — read-only
# root, every capability dropped, no-new-privileges, two tmpfs mounts — was
# proved once, on the monitoring host on 2026-09-09, against one digest. The
# sensitive README said so: "That was one boot of one digest. Dependabot moves
# the digest monthly; nothing here re-runs the boot." CI checks the compose
# file's shape and execs the healthcheck binary (--probe); neither starts the
# application. So every merged bump reopened the question, and the first place
# a "no" would surface was `trinity`, after the deploy.
#
# WHAT THIS DOES. `docker compose up --wait` on the one service, from the real
# compose.yaml, with --no-deps, under a throwaway project name, then:
#
#   1. healthy     the service's own healthcheck passed inside --wait-timeout.
#   2. hardened    `docker inspect` agrees the container actually ran read-only,
#                  with ALL capabilities dropped and no-new-privileges. Without
#                  this a boot proves nothing about the hardening: a softened
#                  compose.yaml would boot, pass, and cache a proof for it.
#   3. gone        `down -v`, always, from a trap.
#
# The network is made INTERNAL for the boot by an override file, which is how
# the 2026-09-09 proof was taken: no route out. A service that only boots when
# it can reach the internet is a finding, not something to paper over here.
#
# THE PROOF IS CACHED, the way check_compose_health.py caches --probe's (#602).
# What a boot establishes is a claim about its inputs: the service as `docker
# compose config` resolves it (image digest included), every file under the
# service's config directory, and this script. The key is a hash of all three,
# so a Dependabot bump — or any edit to the service, its config or this check —
# misses and boots, and a docs-only diff pulls nothing. Nothing is skipped: a
# missing proof is always a boot.
#
# Usage: scripts/check_hardened_boot.sh [--stack S] [--service NAME]
#                                       [--config-dir DIR] [--proof-cache FILE]
#
#   Defaults: --stack sensitive --service home-assistant
#             --config-dir stacks/<stack>/<service>
#
# Needs docker with compose v2. Exits 1 on any failure, and fails rather than
# skips when there is no daemon, for --probe's reason: a CI step that can
# quietly degrade is one nobody will notice degrading.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

STACK=sensitive
SERVICE=home-assistant
CONFIG_DIR=""
PROOF_CACHE=""
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

while (($#)); do
  case "$1" in
    --stack)       STACK="${2:?--stack needs a value}"; shift 2 ;;
    --service)     SERVICE="${2:?--service needs a value}"; shift 2 ;;
    --config-dir)  CONFIG_DIR="${2:?--config-dir needs a value}"; shift 2 ;;
    --proof-cache) PROOF_CACHE="${2:?--proof-cache needs a path}"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^#             --config-dir/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
CONFIG_DIR="${CONFIG_DIR:-stacks/${STACK}/${SERVICE}}"
COMPOSE="stacks/${STACK}/compose.yaml"

pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${COMPOSE}" ]] || die "no ${COMPOSE}"
command -v docker >/dev/null 2>&1 || die "no docker — this check boots a container and cannot run without one"
docker info >/dev/null 2>&1 || die "docker is installed but the daemon is not answering"

WORK="$(mktemp -d)"
PROJECT="hardened-boot-${SERVICE}-$$"
ENV_FILE="${WORK}/.env"
OVERRIDE="${WORK}/internal.yaml"

"${REPO_ROOT}/scripts/seed-validation-env.sh" "${ENV_FILE}" "${STACK}" \
  || die "could not seed a validation .env for ${STACK}"

compose() {
  docker compose --project-name "${PROJECT}" --env-file "${ENV_FILE}" \
    -f "${COMPOSE}" -f "${OVERRIDE}" "$@"
}

# Every network the service joins becomes internal: no route off the host.
networks="$(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE}" config --format json \
  | python3 -c '
import json, sys
svc = json.load(sys.stdin)["services"].get(sys.argv[1])
if svc is None:
    sys.exit("no service " + sys.argv[1])
print("\n".join(svc.get("networks") or {}))
' "${SERVICE}")" || die "${SERVICE} is not a service in ${COMPOSE}"
{
  printf 'networks:\n'
  while read -r n; do
    [[ -n "$n" ]] && printf '  %s:\n    internal: true\n' "$n"
  done <<<"${networks}"
} > "${OVERRIDE}"

# The proof key. `--no-path-resolution` keeps the checkout's absolute path out
# of it, so a runner and a laptop agree on the same inputs. `--no-interpolate`
# is deliberately NOT used: the digest arrives through the image line either
# way, and the seeded values are fixed.
key="$( {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE}" config \
    --no-path-resolution --format json \
    | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["services"][sys.argv[1]], sort_keys=True))' "${SERVICE}"
  if [[ -d "${CONFIG_DIR}" ]]; then
    find "${CONFIG_DIR}" -type f -print0 | sort -z | xargs -0 sha256sum
  fi
  sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1
} | sha256sum | cut -d' ' -f1)"
proof="${STACK}/${SERVICE} ${key}"

if [[ -n "${PROOF_CACHE}" && -f "${PROOF_CACHE}" ]] && grep -qxF "${proof}" "${PROOF_CACHE}"; then
  pass "${STACK}/${SERVICE}: booted hardened and healthy with exactly these inputs before (proof ${key:0:12})"
  rm -rf "${WORK}"
  exit 0
fi

# shellcheck disable=SC2317  # reached through the EXIT trap
cleanup() {
  local rc=$?
  if ((rc != 0)); then
    printf '\n-- last 60 lines from %s --\n' "${SERVICE}"
    compose logs --no-color --tail 60 "${SERVICE}" 2>&1 | sed 's/^/   /'
  fi
  compose down -v --remove-orphans >/dev/null 2>&1
  rm -rf "${WORK}"
  exit "$rc"
}
trap cleanup EXIT

printf '== %s/%s: booting under its compose hardening, network internal\n' "${STACK}" "${SERVICE}"
start=${SECONDS}
if ! compose up --detach --no-deps --wait --wait-timeout "${WAIT_TIMEOUT}" "${SERVICE}"; then
  fail "${STACK}/${SERVICE}: not healthy within ${WAIT_TIMEOUT}s"
  exit 1
fi
pass "${STACK}/${SERVICE}: healthy after $((SECONDS - start))s"

cid="$(compose ps -q "${SERVICE}")"
[[ -n "${cid}" ]] || { fail "${STACK}/${SERVICE}: no container id after a healthy boot"; exit 1; }

# The hardening the proof is about, read from the running container rather than
# from the file that asked for it.
bad=0
ro="$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "${cid}")"
caps="$(docker inspect -f '{{join .HostConfig.CapDrop ","}}' "${cid}")"
secopt="$(docker inspect -f '{{join .HostConfig.SecurityOpt ","}}' "${cid}")"
[[ "${ro}" == true ]] || { fail "root filesystem is not read-only (ReadonlyRootfs=${ro})"; bad=1; }
[[ ",${caps}," == *,ALL,* ]] || { fail "capabilities are not all dropped (CapDrop=${caps:-none})"; bad=1; }
[[ "${secopt}" == *no-new-privileges* ]] || { fail "no-new-privileges is not set (SecurityOpt=${secopt:-none})"; bad=1; }
((bad)) && exit 1
pass "${STACK}/${SERVICE}: ran read-only, CapDrop=ALL, no-new-privileges"

if [[ -n "${PROOF_CACHE}" ]]; then
  mkdir -p "$(dirname "${PROOF_CACHE}")"
  printf '%s\n' "${proof}" >> "${PROOF_CACHE}"
fi
exit 0
