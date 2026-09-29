#!/usr/bin/env bash
#
# Write Home Assistant's HTTP config into its volume before its first start,
# so that it trusts Caddy from the first request.
#
#   scripts/seed-ha-http.sh            seed a missing store; check an existing one
#   scripts/seed-ha-http.sh --check    only check; change nothing
#   scripts/seed-ha-http.sh --force    overwrite an existing store (HA must be stopped)
#
# WHY THIS EXISTS
#
# Since 2026.9, Home Assistant keeps its `http:` settings in
# /config/.storage/http, not in configuration.yaml. The YAML block was imported
# once, as a *pending* config, which Home Assistant reverts to defaults unless an
# admin promotes it within five minutes. Those defaults trust no proxy. After
# the import it ignored the YAML, and from 2027.2 it does not read it at all.
# On trinity's first start (2026-09-28) nobody could promote it in time, and
# every request through Caddy got `400: Bad Request`. The page that fixes it,
# Settings > System > Network, is itself only reachable through Caddy.
#
# So the config is written here, as the *stable* slot, with `pending` empty and
# `yaml_migration_done` set. Home Assistant then runs it as-is: no trial, no
# revert, nothing to promote. That was read from
# homeassistant/components/http/config.py (async_activate_config) in the
# pinned image, 2026.9.4.
#
# The file is built INSIDE the pinned image, from Home Assistant's own
# HTTP_STORAGE_SCHEMA and STORAGE_VERSION constants, not from a JSON blob here.
# A future release that changes the defaults or bumps the store version then
# gets a file in its own format, and migrates it with its own code.
#
# WHAT IT NEVER DOES
#
# It never overwrites an existing store without --force, and never with the
# container running. A volume restored from backup already carries its store,
# and a live one may have been changed from the UI since. Without --force it
# only checks that store, and warns if it would not trust Caddy.
#
# `make up STACK=sensitive` runs it first, so a fresh volume is seeded without
# anyone remembering to.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/stacks/sensitive/compose.yaml"

# The compose project and the volume, overridable so the proof can run against
# a throwaway project and never touch the live one.
PROJECT="${HA_SEED_PROJECT:-sensitive}"
VOLUME_NAME="home-assistant-config"
VOLUME="${PROJECT}_${VOLUME_NAME}"
CONTAINER="${HA_SEED_CONTAINER:-sensitive-home-assistant}"

MODE=seed
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  --force) MODE=force ;;
  -h|--help) sed -n '/^#   scripts/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32mok\033[0m — %s\n' "$*"; }

# Caddy's address is written once, in compose.yaml, where Docker assigns it.
# Reading it from there means the seed cannot drift from the proxy it names.
# Exactly one ipv4_address exists in that file, and anything else is refused.
mapfile -t ADDRS < <(grep -E '^[[:space:]]+ipv4_address:' "${COMPOSE_FILE}" | awk '{print $2}')
((${#ADDRS[@]} == 1)) || die "expected exactly one ipv4_address in ${COMPOSE_FILE} (Caddy's), found ${#ADDRS[@]}"
PROXY="${ADDRS[0]}"

IMAGE="$(COMPOSE_FILE="${COMPOSE_FILE}" "${REPO_ROOT}/scripts/image-for.sh" home-assistant)" \
  || die "could not resolve the pinned home-assistant image"

volume_exists() { docker volume inspect "${VOLUME}" >/dev/null 2>&1; }
ha_running() { [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" == true ]]; }

if ! volume_exists; then
  [[ ${MODE} == check ]] && die "${VOLUME} does not exist; nothing to check"
  # compose's own labels, so a later `make up` adopts the volume silently rather
  # than warning that it "was not created by Docker Compose". tier-ca.sh does
  # the same for step-ca-data.
  info "creating ${VOLUME} with compose's labels"
  docker volume create \
    --label "com.docker.compose.project=${PROJECT}" \
    --label "com.docker.compose.volume=${VOLUME_NAME}" \
    "${VOLUME}" >/dev/null
fi

if [[ ${MODE} == force ]] && ha_running; then
  die "${CONTAINER} is running. Stop it first: docker compose -f stacks/sensitive/compose.yaml stop home-assistant"
fi

# Everything below runs in the pinned image, with the volume mounted and no
# network. It prints one line the shell reads back: an outcome, then details.
# The volume is mounted read-only unless this run may write.
RO=":ro"
[[ ${MODE} == check ]] || RO=""

out="$(docker run --rm -i --network none --user 0 \
  -e MODE="${MODE}" -e PROXY="${PROXY}" \
  -v "${VOLUME}:/config${RO}" \
  --entrypoint python3 "${IMAGE}" - <<'PY'
import json, os, sys, tempfile
from homeassistant.components.http import config as c
from homeassistant.util import dt as dt_util

mode, proxy = os.environ["MODE"], os.environ["PROXY"]
path = "/config/.storage/http"
proxy_net = str(c._ip_network_str(proxy))

def trusts(stable):
    return bool(stable.get("use_x_forwarded_for")) and proxy_net in stable.get("trusted_proxies", [])

if os.path.exists(path) and mode != "force":
    data = json.load(open(path))["data"]
    stable, pending = data.get("stable") or {}, data.get("pending")
    state = "trusted" if trusts(stable) else "UNTRUSTED"
    print(f"present {state} pending={'yes' if pending else 'no'} yaml_migration_done={data.get('yaml_migration_done')}")
    sys.exit(0)
if mode == "check":
    print("absent")
    sys.exit(0)

# Home Assistant's own schema fills every default the way its YAML import
# would have, and normalises the proxy to a network (172.28.99.2 -> /32).
stable = dict(c.HTTP_STORAGE_SCHEMA({
    "use_x_forwarded_for": True,
    "trusted_proxies": [proxy],
    # Five failed logins from one address bans it. The ban list is
    # /config/ip_bans.yaml, in the volume; lifting one is editing that file.
    "ip_ban_enabled": True,
    "login_attempts_threshold": 5,
}))
stable.update(created_at=dt_util.utcnow().isoformat(), error=None, error_message=None)
doc = {
    "version": c.STORAGE_VERSION,
    "minor_version": c.STORAGE_MINOR_VERSION,
    "key": c.STORAGE_KEY,
    "data": {"stable": stable, "pending": None, "yaml_migration_done": True},
}
os.makedirs("/config/.storage", exist_ok=True)
fd, tmp = tempfile.mkstemp(dir="/config/.storage", prefix=".http.")
with os.fdopen(fd, "w") as f:
    json.dump(doc, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(f"written trusted version={c.STORAGE_VERSION}.{c.STORAGE_MINOR_VERSION} proxy={proxy_net}")
PY
)" || die "the seed step failed inside ${IMAGE}"

[[ -n ${out} ]] || die "the seed step printed nothing inside ${IMAGE} (was stdin passed to docker run?)"
read -r outcome state rest <<<"${out}"
case "${outcome}/${state}" in
  written/trusted)
    ok "${VOLUME}: .storage/http written, trusting ${PROXY} (${rest})" ;;
  present/trusted)
    ok "${VOLUME}: .storage/http already present and trusts ${PROXY} (${rest}); left alone" ;;
  present/UNTRUSTED)
    printf '\033[0;33mwarning:\033[0m %s\n' "${VOLUME}: .storage/http is present but does NOT trust ${PROXY} (${rest})." >&2
    printf '         Every request through Caddy will get 400. Stop Home Assistant, then: %s --force\n' "$0" >&2
    [[ ${MODE} == check ]] && exit 1 ;;
  absent/*)
    die "${VOLUME}: no .storage/http. Run $0 before Home Assistant's first start" ;;
  *)
    die "unexpected result from the seed step: ${out}" ;;
esac
