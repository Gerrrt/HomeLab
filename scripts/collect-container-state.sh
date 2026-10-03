#!/usr/bin/env bash
#
# Write whether each container of one compose project is running, for the
# textfile collector (#838).
#
#   scripts/collect-container-state.sh --project media [--host smaug] [--print]
#   scripts/collect-container-state.sh --self-test
#
# WHY THIS EXISTS
#
# A container that exits and stays down is silent everywhere cAdvisor is not.
# On the Docker hosts that run Alloy, ContainerGone (containers.rules.yaml)
# catches it from cAdvisor's series disappearing. smaug runs no Alloy and no
# cAdvisor (ADR-0016, ADR-0040): Prometheus scrapes its node_exporter and
# nothing else, so Jellyfin, Audiobookshelf and Navidrome could stop and stay
# stopped until a television said so.
#
# This is ADR-0047's answer for SMART, reused: a root cron job in TrueNAS's UI
# runs this script from the copy on the pool, writes a file into the directory
# the media stack's node_exporter already serves, and the existing scrape
# carries it. No new service, no new image, no firewall pass.
#
# WHAT IT WRITES
#
#   homelab_container_running{project, name}        1 running, 0 anything else
#   homelab_container_state_timestamp_seconds{project}  when this last ran
#
# `docker ps -a`, so a stopped container is a 0 rather than an absence: the
# question is answered directly, and needs none of the look-back ContainerGone
# has to use. Only the named compose project, so TrueNAS's own app containers,
# which it stops and starts on its own schedule, are not this script's to
# report. Containers labelled homelab.logs=off are skipped: that label already
# marks the estate's throwaway containers (backup-volumes.sh), which exit by
# design.
#
# The stale-timestamp alert, ContainerStateStale, is what notices the cron job
# itself stopping.

set -euo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROJECT=""
HOST=""
PRINT=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# docker ps lines on stdin: NAME TAB STATE TAB homelab.logs-label.
# Prints the metrics for one run at time $1.
render() {
  local now="$1" name state logs
  printf '# HELP homelab_container_running 1 when the container is running, 0 when it exists and is not.\n'
  printf '# TYPE homelab_container_running gauge\n'
  while IFS=$'\t' read -r name state logs; do
    [[ -n "${name}" ]] || continue
    [[ "${logs}" == "off" ]] && continue
    # Container names are compose's or container_name:, both of which Docker
    # restricts to [a-zA-Z0-9][a-zA-Z0-9_.-]. Refused otherwise, because the
    # name goes into a label value.
    [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || continue
    printf 'homelab_container_running{project="%s",name="%s"} %d\n' \
      "${PROJECT}" "${name}" "$([[ "${state}" == running ]] && echo 1 || echo 0)"
  done
  printf '# HELP homelab_container_state_timestamp_seconds When collect-container-state.sh last wrote this file.\n'
  printf '# TYPE homelab_container_state_timestamp_seconds gauge\n'
  printf 'homelab_container_state_timestamp_seconds{project="%s"} %s\n' "${PROJECT}" "${now}"
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    if [[ "$2" == "$3" ]]; then printf '\033[0;32m  PASS\033[0m %s\n' "$1"
    else printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$1" "$2" "$3"; fail=1; fi
  }
  PROJECT=media
  run() { printf '%b' "$1" | render 1700000000 | grep -v '^#'; }
  check "a running container is 1" \
    "$(run 'jellyfin\trunning\t\n')" \
    "$(printf 'homelab_container_running{project="media",name="jellyfin"} 1\nhomelab_container_state_timestamp_seconds{project="media"} 1700000000')"
  check "an exited container is 0, not absent" \
    "$(run 'audiobookshelf\texited\t\n' | head -1)" \
    'homelab_container_running{project="media",name="audiobookshelf"} 0'
  check "restarting is not running" \
    "$(run 'navidrome\trestarting\t\n' | head -1)" \
    'homelab_container_running{project="media",name="navidrome"} 0'
  check "a homelab.logs=off throwaway is skipped" \
    "$(run 'archiver-x\texited\toff\n' | grep -c container_running || true)" "0"
  check "a name that would break the label is skipped" \
    "$(run 'bad"name\trunning\t\n' | grep -c container_running || true)" "0"
  check "an empty project still writes its timestamp" \
    "$(run '' | grep -c state_timestamp)" "1"
  exit "${fail}"
fi

while (($#)); do
  case "$1" in
    --project) PROJECT="${2:?--project needs a compose project name}"; shift ;;
    --host)    HOST="${2:?--host needs a name}"; shift ;;
    --print)   PRINT=1 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
[[ "${PROJECT}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "--project must name a compose project"
# --host is accepted for the same command line as collect-smart-state.sh; the
# scrape supplies `instance`, so it is not written as a label.
: "${HOST}"
command -v docker >/dev/null 2>&1 || die "no docker on PATH (cron's PATH: see build-the-nas.md)"

out="$(docker ps -a --filter "label=com.docker.compose.project=${PROJECT}" \
         --format $'{{.Names}}\t{{.State}}\t{{.Label "homelab.logs"}}' \
       | render "$(date +%s)")"

if ((PRINT)); then
  printf '%s\n' "${out}"
  exit 0
fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no textfile directory at ${TEXTFILE_DIR}"
prom="${TEXTFILE_DIR}/homelab-containers-${PROJECT}.prom"
tmp="${prom}.$$"
printf '%s\n' "${out}" > "${tmp}"
chmod 0644 "${tmp}"
mv -f "${tmp}" "${prom}"
