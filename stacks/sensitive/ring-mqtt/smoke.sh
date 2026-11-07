#!/usr/bin/env bash
#
# Prove ring-mqtt starts and reads its configuration under its hardening
# (ADR-0104). Run by scripts/check_hardened_boot.sh after the boot, with the
# container id as $1.
#
# WHY. ring-mqtt has no healthcheck (compose.yaml says why), so the boot's
# --wait passes the moment the process starts. What can go wrong under this
# compose is all at start: the config written to the tmpfs and linked into
# /data unread, the state file unwritable as RENDER_UID, or Node unable to run
# from a read-only root. Each of those stops it within seconds, so this waits,
# then reads its log.
#
# In CI there is no Ring sign-in and no internet, so the furthest a healthy
# start gets is the point where it asks for a token. That is what is checked.
set -euo pipefail

cid="${1:?usage: smoke.sh <container id>}"

for _ in $(seq 30); do
  docker logs "${cid}" 2>&1 | grep -q 'No refresh token was found' && break
  sleep 1
done
log="$(docker logs "${cid}" 2>&1)"
fail() { echo "smoke: $*" >&2; printf '%s\n' "${log}" | tail -20 >&2; exit 1; }

grep -q 'Detected runmode: docker' <<<"${log}" || fail "ring-mqtt did not start in docker run mode"
grep -q 'Configuration file: /data/config.json' <<<"${log}" || fail "ring-mqtt did not read /data/config.json"
grep -q 'could not be read' <<<"${log}" && fail "ring-mqtt could not read its configuration"
grep -q 'MQTT URL: mqtt://ring-mqtt:\*\*\*\*\*\*\*\*@mosquitto:1883' <<<"${log}" || fail "the configuration did not carry the broker URL"
grep -q 'No refresh token was found' <<<"${log}" || fail "ring-mqtt did not reach the point of asking for a Ring token"
[[ "$(docker inspect -f '{{.State.Running}}' "${cid}")" == true ]] || fail "ring-mqtt stopped after starting"
echo "smoke: ring-mqtt starts, reads its configuration and waits for a Ring token"
