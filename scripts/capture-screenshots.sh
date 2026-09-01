#!/usr/bin/env bash
#
# Render each provisioned dashboard to a PNG in docs/images/.
#
# Screenshots were the one artefact this repository could not produce from its
# own tooling. The monitoring host has no browser and no image libraries, and
# Grafana has no built-in PNG export — /render only answers when an image
# renderer is reachable. So this starts one behind the `capture` compose
# profile, renders, and stops it again. Nothing is left running.
#
# The Grafana password is read in-process via scripts/secrets-env.sh and passed
# to curl on stdin through --config, never in argv: everything in argv is
# visible in `ps` to every user on the host for the life of the request.
#
# Usage: scripts/capture-screenshots.sh [stack]      (default: observability)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:-observability}"
STACK_DIR="${REPO_ROOT}/stacks/${STACK}"
OUT_DIR="${REPO_ROOT}/docs/images"
COMPOSE=(docker compose -f "${STACK_DIR}/compose.yaml")

# The window each dashboard is rendered over. 24h is what docs/images/README.md
# has always specified: long enough that the rate() panels have a shape, short
# enough that the SNMP counters have not been downsampled into a flat line.
FROM="${CAPTURE_FROM:-now-24h}"
TO="${CAPTURE_TO:-now}"
WIDTH="${CAPTURE_WIDTH:-1600}"

# Height is NOT fixed. Grafana renders the viewport it is given and crops
# everything below it, so a constant height silently truncates the dashboard —
# the first run of this script produced five images that stopped halfway down
# and looked deliberate. It is derived per dashboard from the JSON instead, so
# adding a panel grows the screenshot rather than pushing content off it.
#
# The renderer's own ceiling is BROWSER_MAX_HEIGHT; a request above it is
# silently clamped, which would truncate again — the same crop, one layer down,
# and just as quiet. compose.yaml sets it to 5000 because `homelab-stack` is
# 4582px and the 3000 default cut its whole Alloy row off a capture that still
# reported success. The two numbers only work in step: raising either alone
# leaves the lower one deciding.
MAX_HEIGHT=5000

# How long to give one render. A full dashboard is 15-35 panels, each a
# separate query, and Chromium will not paint until they settle. Grafana's own
# default is 60s and that is not enough for the network dashboard on this
# hardware.
TIMEOUT="${CAPTURE_TIMEOUT:-180}"

# uid:filename. The uid is the contract — the filename is only what
# docs/images/README.md and the README's image block expect to find.
#
# homelab-logs is deliberately absent. Its Authentication log panel renders
# auth.log verbatim, so a capture contains real usernames, real source addresses
# and real session IDs — and there is no way to shoot it that does not, because
# showing log lines is what the dashboard is for. Adding it back means solving
# redaction first, not remembering to check afterwards.
DASHBOARDS=(
  "homelab-host-overview:host-overview.png"
  "homelab-docker:docker-containers.png"
  "homelab-network:network-snmp.png"
  "homelab-ups:ups-power.png"
  "homelab-stack:observability-stack.png"
)

# shellcheck source=secrets-env.sh
source "${REPO_ROOT}/scripts/secrets-env.sh"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m  ok\033[0m %s\n' "$*"; }

# dashboard_height <uid>
#
# The tallest point of the dashboard, in pixels, from its own JSON. Grafana's
# grid row is 30px with 8px of padding, and kiosk mode still draws a top bar.
dashboard_height() {
  python3 - "$1" "${STACK_DIR}/grafana/dashboards" "${MAX_HEIGHT}" <<'DASHBOARD_HEIGHT_PY'
import json, pathlib, sys

uid, dashboard_dir, max_height = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])

def panels(items):
    for panel in items:
        yield panel
        yield from panels(panel.get("panels", []))

for path in sorted(dashboard_dir.glob("*.json")):
    dashboard = json.loads(path.read_text())
    if dashboard.get("uid") != uid:
        continue
    rows = max(p["gridPos"]["y"] + p["gridPos"]["h"]
               for p in panels(dashboard["panels"]) if "gridPos" in p)
    print(min(rows * 38 + 60, max_height))
    break
else:
    sys.exit("no dashboard with uid " + uid + " in " + str(dashboard_dir))
DASHBOARD_HEIGHT_PY
}

[[ -d "${STACK_DIR}" ]] || die "no such stack: ${STACK_DIR}"

# The renderer is useless without Grafana already serving, and starting the
# whole stack from here would hide a stack that is down behind a screenshot
# job that "worked".
"${COMPOSE[@]}" ps --status running --services 2>/dev/null | grep -qx grafana \
  || die "grafana is not running — run 'make up' first"

# Grafana only learns the renderer's address from GF_RENDERING_SERVER_URL, which
# is set in compose.yaml. A Grafana container created before those lines existed
# is still running without them, and every render would 500 with a message about
# no remote rendering available — which reads like a renderer fault.
if ! docker inspect grafana --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -q '^GF_RENDERING_SERVER_URL='; then
  die "grafana has no GF_RENDERING_SERVER_URL — run 'make up' to recreate it"
fi

info "decrypting $(basename "${STACK}").sops.yaml"
load_secrets "${STACK}"
[[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] \
  || die "GRAFANA_ADMIN_PASSWORD missing from secrets/${STACK}.sops.yaml"

GRAFANA_USER="${GRAFANA_ADMIN_USER:-admin}"

# Read back the published port rather than assuming 3000, for the same reason
# `make up` does: GRAFANA_PORT lives in the rendered .env, which this script
# does not otherwise read, and a wrong URL here looks exactly like a hung render.
PORT="$(grep -E '^GRAFANA_PORT=' "${STACK_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
PORT="${PORT:-3000}"
BASE="https://localhost:${PORT}"

CURL_CONFIG="$(mktemp)"
RENDERER_STARTED=0
cleanup() {
  rm -f "${CURL_CONFIG}"
  if ((RENDERER_STARTED)); then
    info "stopping renderer"
    "${COMPOSE[@]}" --profile capture stop renderer >/dev/null 2>&1 || true
    "${COMPOSE[@]}" --profile capture rm -f renderer >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --config keeps the credential out of argv. The file is created by mktemp at
# 0600 and removed by the trap above on every exit path.
{
  printf 'user = "%s:%s"\n' "${GRAFANA_USER}" "${GRAFANA_ADMIN_PASSWORD}"
  # The lab CA signs grafana.matrix.elysium; this request is to localhost, so
  # the name cannot match. Verification is not what this script is testing.
  printf 'insecure\n'
  printf 'silent\n'
  printf 'show-error\n'
  printf 'fail\n'
} > "${CURL_CONFIG}"

info "starting renderer (capture profile)"
"${COMPOSE[@]}" --profile capture up -d renderer
RENDERER_STARTED=1

# The renderer's HTTP server binds well after the container reports running,
# and a render fired into that gap fails with a connection error that looks
# like a misconfiguration. Poll rather than sleep a guessed interval.
#
# Probed from inside grafana rather than the renderer: the renderer image is a
# single Go binary with no shell utilities to probe with, and its port is
# deliberately not published, so grafana — which has busybox wget, as its own
# healthcheck relies on — is the only thing that can reach it.
info "waiting for the renderer"
ready=0
for _ in $(seq 1 30); do
  if "${COMPOSE[@]}" exec -T grafana \
      wget --spider -q http://renderer:8081/healthz >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
((ready)) || die "renderer did not answer /healthz within 60s"

mkdir -p "${OUT_DIR}"
failed=()

for entry in "${DASHBOARDS[@]}"; do
  uid="${entry%%:*}"
  file="${entry#*:}"
  out="${OUT_DIR}/${file}"
  tmp="${out}.part"

  height="$(dashboard_height "${uid}")"
  info "rendering ${uid} -> docs/images/${file} (${WIDTH}x${height})"

  # kiosk drops the chrome; the slug after the uid is cosmetic and Grafana
  # redirects to the real one.
  url="${BASE}/render/d/${uid}/x"
  url+="?orgId=1&from=${FROM}&to=${TO}"
  url+="&width=${WIDTH}&height=${height}&kiosk&tz=UTC"

  if ! curl --config "${CURL_CONFIG}" --max-time "${TIMEOUT}" -o "${tmp}" "${url}"; then
    rm -f "${tmp}"
    failed+=("${file}")
    continue
  fi

  # Grafana answers a failed render with 200 and a PNG of an error message, so
  # the exit status above proves only that something arrived. Check the magic
  # bytes and the size: an error card is a few kB, a real dashboard is hundreds.
  if [[ "$(head -c 8 "${tmp}" | od -An -tx1 | tr -d ' \n')" != "89504e470d0a1a0a" ]]; then
    rm -f "${tmp}"
    failed+=("${file} (not a PNG)")
    continue
  fi
  size="$(stat -c %s "${tmp}")"
  if ((size < 20000)); then
    rm -f "${tmp}"
    failed+=("${file} (${size} bytes — too small to be a rendered dashboard)")
    continue
  fi

  mv "${tmp}" "${out}"
  ok "${file} (${size} bytes)"
done

if ((${#failed[@]})); then
  printf '\n\033[0;31mfailed:\033[0m\n' >&2
  printf '  %s\n' "${failed[@]}" >&2
  die "${#failed[@]} of ${#DASHBOARDS[@]} dashboards did not render"
fi

printf '\n\033[0;32mcaptured\033[0m — %d screenshots in docs/images/\n' "${#DASHBOARDS[@]}"
printf 'Review every image against the checklist in docs/images/README.md\n'
printf 'before committing: these go into a public repository.\n'
