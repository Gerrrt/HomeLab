#!/usr/bin/env bash
#
# Print the pinned image for a compose service.
#
# Image versions must live in exactly one place: compose.yaml, which is what
# Dependabot updates. They were previously duplicated into ci.yml, validate.sh
# and check_loki_rules.sh, and the duplicates went stale the moment Dependabot
# merged a bump — CI ended up validating configs against Prometheus v3.1.0 while
# the stack deployed v3.13.2. Validation against the wrong version is worse than
# no validation, because it still reports green.
#
# Deliberately parses the text rather than using PyYAML or `docker compose
# config`: this runs before any of those are guaranteed present, and needs no
# .env for the ${VAR:?} guards.
#
# Usage: scripts/image-for.sh <service>        e.g. loki -> grafana/loki:3.7.4

set -euo pipefail

SERVICE="${1:?usage: image-for.sh <service>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE:-${REPO_ROOT}/stacks/observability/compose.yaml}"

[[ -f "${COMPOSE}" ]] || { printf 'no compose file at %s\n' "${COMPOSE}" >&2; exit 1; }

image="$(awk -v svc="${SERVICE}" '
  # Track whether we are inside the services: block.
  /^services:/            { in_services = 1; next }
  /^[^[:space:]#]/        { in_services = 0 }
  !in_services            { next }
  # A two-space-indented key is a service name.
  /^  [A-Za-z0-9_.-]+:/ {
    line = $0
    sub(/^  /, "", line); sub(/:.*/, "", line)
    current = line
  }
  current == svc && $1 == "image:" { print $2; exit }
' "${COMPOSE}")"

if [[ -z "${image}" ]]; then
  printf 'no image found for service %s in %s\n' "${SERVICE}" "${COMPOSE}" >&2
  exit 1
fi

printf '%s\n' "${image}"
