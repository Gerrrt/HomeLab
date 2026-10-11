#!/usr/bin/env bash
#
# Prove the first half of scripts/gosu-skip.txt's rule on every pinned image it
# covers: started as 999:999, the entrypoint never runs gosu (#995, #980).
#
# scan-images.sh skips /usr/local/bin/gosu in the repositories gosu-skip.txt
# lists, so their gosu CVEs never reach an issue. That is honest only while
# gosu cannot run. check_compose_health.py holds every such service to
# `user: "999:999"`. This checks the other half, which is the image's to keep:
# that its entrypoint calls gosu only when started as root. A bump that changes
# that fails here, rather than hiding findings in a file that now runs.
#
# For each pinned image of a listed repository, under every stacks/*/compose.yaml
# (resolved per service through image-for.sh), it boots the image twice. A
# stand-in gosu is mounted over /usr/local/bin/gosu. It records that it ran and
# exits 1, so the entrypoint cannot carry on as if it had dropped privilege.
#
#   999:999  the service's own user, on a scratch tmpfs data directory. It must
#            initialise, reach "ready to accept connections", and leave no
#            marker. That is the claim gosu-skip.txt makes.
#   root     the image's default user. It must leave the marker. That proves
#            the stand-in is really on the entrypoint's path, so a clean
#            999:999 run means gosu was not called, not that it was not found.
#
# The data directory is a tmpfs at the image's own PGDATA, and the password is
# a throwaway, so nothing persists and nothing real is touched. The containers
# carry homelab.logs=off, so production Alloy does not ingest them.
#
# Usage: scripts/check_gosu_skip.sh [--skips-file PATH]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIPS_FILE=""
FAILED=0
READY_TIMEOUT=120

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }

while (($#)); do
  case "$1" in
    --skips-file) SKIPS_FILE="${2:?--skips-file needs a path}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# Same contract as the other boot checks: no docker is a recorded skip, never
# a pass (#68).
if ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
  msg="no docker daemon — gosu-skip.txt's root-only claim not exercised"
  printf '\033[0;33m  SKIP\033[0m %s\n' "${msg}"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "${msg}" >> "${SKIPS_FILE}"
  exit 0
fi

GOSU_SKIP="$(grep -vE '^[[:space:]]*(#|$)' "${REPO_ROOT}/scripts/gosu-skip.txt")" \
  || die "scripts/gosu-skip.txt lists no repository"

# Every service in every stack whose image is from a listed repository, as
# `<compose file> <service>` pairs, read the way image-for.sh reads a service.
# Each image is then resolved through image-for.sh itself, the one way a script
# here may name an image, so this boots exactly what compose.yaml pins.
stack_paths="$("${REPO_ROOT}/scripts/stacks.sh" --paths)" || die "scripts/stacks.sh failed"
pairs=()
while read -r sd; do
  compose="${REPO_ROOT}/${sd}/compose.yaml"
  while read -r svc ref; do
    name="${ref%%@*}"
    grep -qxF "${name%:*}" <<<"${GOSU_SKIP}" && pairs+=("${compose} ${svc}")
  done < <(awk '
    /^services:/            { in_services = 1; next }
    /^[^[:space:]#]/        { in_services = 0 }
    !in_services            { next }
    /^  [A-Za-z0-9_.-]+:/   { line = $0; sub(/^  /, "", line); sub(/:.*/, "", line); current = line }
    $1 == "image:" && current != "" {
      v = $2
      sub(/^"/, "", v); sub(/"$/, "", v)
      sub(/^\047/, "", v); sub(/\047$/, "", v)
      if (v != "") print current, v
    }
  ' "${compose}")
done <<<"${stack_paths}"

declare -A seen=()
images=()
for pair in "${pairs[@]}"; do
  read -r compose svc <<<"${pair}"
  img="$(COMPOSE_FILE="${compose}" "${REPO_ROOT}/scripts/image-for.sh" "${svc}")" \
    || die "image-for.sh could not resolve ${svc} in ${compose#"${REPO_ROOT}"/}"
  [[ "${img}" == *@sha256:* ]] || die "${compose#"${REPO_ROOT}"/}: ${svc} runs ${img}, not pinned by digest"
  [[ -n "${seen[${img}]+x}" ]] && continue
  seen[${img}]=1
  images+=("${img}")
done

# A listed repository that no stack pins any more is a stale entry: the skip
# would apply to nothing, but the list would still claim it was checked.
while read -r repo; do
  covered=0
  for img in "${images[@]}"; do
    name="${img%%@*}"
    [[ "${name%:*}" == "${repo}" ]] && covered=1
  done
  ((covered)) || fail "gosu-skip.txt lists ${repo}, which no stack pins; remove the entry"
done <<<"${GOSU_SKIP}"
((${#images[@]} > 0)) || die "no stack pins a repository gosu-skip.txt lists"

TAG="gosucheck-$$"
n=0
WORK="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329  # reached through the EXIT trap
cleanup() {
  docker ps -aq --filter "label=homelab.gosucheck=${TAG}" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${WORK}/bin"
printf '#!/bin/sh\necho "gosu $*" > /gosu-mark/ran\nexit 1\n' > "${WORK}/bin/gosu"
chmod 0755 "${WORK}/bin/gosu"

# One boot. Prints `ready` or `exited` or `timeout`; the marker is read after.
boot() { # image user markdir name
  local img="$1" user="$2" mark="$3" name="$4" pgdata state i
  pgdata="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${img}" | sed -n 's/^PGDATA=//p')"
  [[ -n "${pgdata}" ]] || { echo "no-pgdata"; return; }
  local as=()
  [[ "${user}" == root ]] || as=(--user "${user}")
  docker run -d --name "${name}" --label homelab.logs=off --label "homelab.gosucheck=${TAG}" \
    "${as[@]}" -e POSTGRES_PASSWORD=gosucheck \
    --tmpfs "${pgdata}:uid=999,gid=999,mode=0700" \
    -v "${WORK}/bin/gosu:/usr/local/bin/gosu:ro" -v "${mark}:/gosu-mark" \
    "${img}" >/dev/null
  state="timeout"
  for ((i = 0; i < READY_TIMEOUT; i++)); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" != true ]]; then
      state="exited"
      break
    fi
    # The last "ready" line is the real server's: the init run's temporary
    # server logs one too, before "init process complete".
    if docker logs "${name}" 2>&1 | grep -q 'PostgreSQL init process complete' \
       && docker logs "${name}" 2>&1 | tail -n 3 | grep -q 'ready to accept connections'; then
      state="ready"
      break
    fi
    sleep 1
  done
  echo "${state}"
}

for img in "${images[@]}"; do
  shown="${img%%@*}"
  info "${shown}"
  docker pull -q "${img}" >/dev/null || { fail "${shown}: could not pull ${img}"; continue; }

  # 999:999, the service's own user: ready, and gosu never ran.
  mark="${WORK}/mark-$((++n))"
  mkdir -p "${mark}"
  chmod 0777 "${mark}"
  state="$(boot "${img}" 999:999 "${mark}" "${TAG}-${n}")"
  # The marker first: a gosu call also kills the container (the stand-in exits
  # 1), and "it ran gosu" is the finding, not "it did not come up".
  if [[ -e "${mark}/ran" ]]; then
    fail "${shown}: as 999:999 the entrypoint ran gosu ($(cat "${mark}/ran")); the skip is no longer honest"
  elif [[ "${state}" != ready ]]; then
    fail "${shown}: as 999:999 the server did not come up (${state})"
    docker logs --tail 8 "${TAG}-${n}" 2>&1 | sed 's/^/        /'
  else
    pass "${shown}: as 999:999 it initialised and is ready, and gosu never ran"
  fi
  docker rm -f "${TAG}-${n}" >/dev/null 2>&1 || true

  # root, the control: the stand-in must be on the path and get called.
  mark="${WORK}/mark-$((++n))"
  mkdir -p "${mark}"
  chmod 0777 "${mark}"
  boot "${img}" root "${mark}" "${TAG}-${n}" >/dev/null
  if [[ -e "${mark}/ran" ]]; then
    pass "${shown}: as root it called the stand-in gosu, so the 999:999 run was a real test"
  else
    fail "${shown}: as root the stand-in gosu was never called, so the 999:999 result proves nothing"
  fi
  docker rm -f "${TAG}-${n}" >/dev/null 2>&1 || true
done

if ((FAILED)); then
  printf '\033[0;31mFAIL\033[0m gosu-skip.txt claims something an image no longer does\n'
  exit 1
fi
printf '\033[0;32mOK\033[0m %d pinned image(s) never run gosu as 999:999, and each control called it as root\n' "${#images[@]}"
