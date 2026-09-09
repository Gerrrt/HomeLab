#!/usr/bin/env bash
#
# Validate every stack's Caddyfile the way promtool validates the alert rules.
#
# A Caddyfile with a typo does not fail at `docker compose config`, which never
# reads it; it fails when the container starts, and `restart: unless-stopped`
# then retries forever behind a healthcheck that never goes green. That is the
# shape of failure this repository keeps finding — a config that is wrong and a
# service that looks merely slow — so the file is checked where the alert rules
# are: before a commit lands, by the same binary that will serve it (#129).
#
# Two checks, both against the pinned image rather than a host-installed caddy,
# for the reason scripts/check_loki_rules.sh gives: the only thing that
# genuinely understands the format is the thing that will run it.
#
#   1. `caddy validate` — adapts and provisions the config without starting it.
#      Provisioning loads the TLS files the Caddyfile names, so a throwaway
#      keypair is generated into a temp dir and mounted where compose.yaml
#      mounts the real one. The real leaf never exists on a CI runner and must
#      not: certificates/ is gitignored and stays that way.
#   2. `caddy fmt --diff` — the file is formatted the way `caddy fmt` would
#      write it, so a diff shows a change and not a reindent.
#
# Skips are recorded, not just printed, on the contract scripts/validate.sh
# and scripts/check_loki_rules.sh share: without docker there is nothing to run
# and the caller counts the skip rather than reading exit 0 as a pass (#68).
#
# Usage: scripts/check_caddyfile.sh [--stack NAME] [--skips-file PATH]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIPS_FILE=""
STACK_NAME=""
while (($#)); do
  case "$1" in
    --skips-file) SKIPS_FILE="${2:?--skips-file needs a path}"; shift ;;
    --stack) STACK_NAME="${2:?--stack needs a name}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

if [[ -n "${STACK_NAME}" ]]; then
  STACKS=("${STACK_NAME}")
else
  mapfile -t STACKS < <("${REPO_ROOT}/scripts/stacks.sh")
fi

status=0
for stack in "${STACKS[@]}"; do
  stack_dir="${REPO_ROOT}/stacks/${stack}"
  caddyfile="${stack_dir}/Caddyfile"
  if [[ ! -f "${caddyfile}" ]]; then
    pass "${stack}: no Caddyfile — nothing to validate"
    continue
  fi

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    msg="${stack}: no docker daemon — Caddyfile unchecked"
    printf '\033[0;33m  SKIP\033[0m %s\n' "${msg}"
    [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "${msg}" >> "${SKIPS_FILE}"
    continue
  fi

  # The image this stack pins, never a floating tag — see scripts/image-for.sh.
  image="$(COMPOSE_FILE="${stack_dir}/compose.yaml" "${REPO_ROOT}/scripts/image-for.sh" caddy)"

  work="$(mktemp -d)"
  trap 'rm -rf "${work}" 2>/dev/null || true' EXIT
  # A throwaway pair, one day, unrelated to any CA this estate has ever run.
  # It exists so `tls /etc/caddy/tls/cert.pem /etc/caddy/tls/key.pem` has files
  # to load; it proves nothing about the real certificate and is not meant to.
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=caddyfile-validation' \
    -keyout "${work}/key.pem" -out "${work}/cert.pem" >/dev/null 2>&1
  cp "${work}/cert.pem" "${work}/ca.pem"
  chmod 644 "${work}"/*.pem
  chmod 755 "${work}"

  # cp rather than a bind of the tracked file: the container reads as root and
  # writes nothing, but a bind mount of a file inside the checkout is one
  # `caddy fmt --overwrite` away from an edit nobody asked for.
  cp "${caddyfile}" "${work}/Caddyfile"

  # Backslash-continued on purpose: scripts/check_image_pins.py reads a docker
  # command as one statement only across `\` continuations, and it has to see
  # the image token on the same statement as `docker run` to trace it back to
  # image-for.sh above.
  run=(docker run --rm --network none \
    -v "${work}/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "${work}/cert.pem:/etc/caddy/tls/cert.pem:ro" \
    -v "${work}/key.pem:/etc/caddy/tls/key.pem:ro" \
    -v "${work}/ca.pem:/etc/caddy/tls/ca.pem:ro" \
    "${image}")

  info "${stack}: caddy validate against $(basename "${image%%@*}")"
  if "${run[@]}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
    pass "${stack}: Caddyfile adapts and provisions"
  else
    fail "${stack}: Caddyfile does not validate — see above"
    status=1
  fi

  if "${run[@]}" caddy fmt --diff /etc/caddy/Caddyfile >/dev/null 2>&1; then
    pass "${stack}: Caddyfile is formatted"
  else
    fail "${stack}: Caddyfile is not formatted — run \`caddy fmt\` (the diff:)"
    "${run[@]}" caddy fmt --diff /etc/caddy/Caddyfile || true
    status=1
  fi

  rm -rf "${work}"
  trap - EXIT
done

exit "${status}"
