#!/usr/bin/env bash
#
# Validate stacks/sensitive/glance/glance.yml with the binary that will run it
# (ADR-0098).
#
# Glance exits at start on a config it cannot parse, and `restart:
# unless-stopped` then retries it forever behind a healthcheck that never goes
# green — the shape of failure check_caddyfile.sh exists for, and the same
# answer: check the file before it lands, against the pinned image. Glance's
# own `config:validate` parses the YAML, substitutes the ${…} variables and
# initialises every widget, which is where a misspelt widget type or a bad
# property is refused. It does not run a custom-api template; those are only
# rendered against a live answer.
#
# The two variables glance.yml reads are given placeholders. Glance refuses a
# config that names an unset one, so this also proves the file asks for
# nothing compose.yaml does not hand it. `--network none`: validation fetches
# nothing.
#
# Skips are recorded, not just printed, on the contract check_caddyfile.sh and
# scripts/validate.sh share: without docker there is nothing to run, and the
# caller counts the skip rather than reading exit 0 as a pass (#68).
#
# Usage: scripts/check_glance_config.sh [--skips-file PATH]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIPS_FILE=""
while (($#)); do
  case "$1" in
    --skips-file) SKIPS_FILE="${2:?--skips-file needs a path}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; }

STACK_DIR="${REPO_ROOT}/stacks/sensitive"
CONFIG="${STACK_DIR}/glance/glance.yml"

[[ -f "${CONFIG}" ]] || { fail "sensitive: ${CONFIG#"${REPO_ROOT}"/} is missing"; exit 1; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  msg="sensitive: no docker daemon — glance.yml unchecked"
  printf '\033[0;33m  SKIP\033[0m %s\n' "${msg}"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "${msg}" >> "${SKIPS_FILE}"
  exit 0
fi

# The image this stack pins, never a floating tag — see scripts/image-for.sh.
image="$(COMPOSE_FILE="${STACK_DIR}/compose.yaml" "${REPO_ROOT}/scripts/image-for.sh" glance)"

# Backslash-continued for check_image_pins.py, as in check_caddyfile.sh. As the
# caller and read-only: the image would otherwise run as root over a mount of
# the checkout.
if docker run --rm --network none --user "$(id -u):$(id -g)" \
  -e GLANCE_PROMETHEUS_TOKEN=validation-only \
  -e GLANCE_MINIFLUX_FEVER_KEY=validation-only \
  -v "${CONFIG}:/app/config/glance.yml:ro" \
  "${image}" config:validate; then
  pass "sensitive: glance.yml validates against $(basename "${image%%@*}")"
else
  fail "sensitive: glance.yml does not validate — see above"
  exit 1
fi
