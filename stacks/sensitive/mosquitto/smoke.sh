#!/usr/bin/env bash
#
# Prove the broker lets its two users in and keeps everyone else out
# (ADR-0104). Run by scripts/check_hardened_boot.sh after a healthy, hardened
# boot, with the container id as $1.
#
# WHY THE HEALTHCHECK IS NOT ENOUGH. It only proves the listener answers. A
# password file the start command failed to hash, or an ACL that no longer
# parses the way it did, still leaves 1883 open while every login fails, and
# Home Assistant would show nothing but an unavailable alarm.
#
# WHAT IT DOES, inside the container, with the clients the image ships and
# the passwords the environment seeded:
#   1. each user publishes to a topic it is granted;
#   2. a wrong password and an anonymous client are both refused;
#   3. ring-mqtt cannot publish outside ring/ and homeassistant/: a message
#      it sends to another topic never reaches a subscriber.
# Nothing leaves the container, and the network is internal during the boot.
set -euo pipefail

cid="${1:?usage: smoke.sh <container id>}"

docker exec -i "${cid}" sh -s <<'IN_CONTAINER'
set -eu
pub() { mosquitto_pub -h 127.0.0.1 -q 1 "$@" -m smoke; }
fail() { echo "smoke: $*" >&2; exit 1; }

pub -u homeassistant -P "${MQTT_HA_PASSWORD}" -t smoke/ha || fail "homeassistant could not publish"
pub -u ring-mqtt -P "${MQTT_RING_PASSWORD}" -t ring/smoke || fail "ring-mqtt could not publish to ring/"
pub -u ring-mqtt -P "${MQTT_RING_PASSWORD}" -t homeassistant/smoke || fail "ring-mqtt could not publish to homeassistant/"
if pub -u ring-mqtt -P wrong -t ring/smoke 2>/dev/null; then fail "a wrong password was accepted"; fi
if pub -t ring/smoke 2>/dev/null; then fail "an anonymous client was accepted"; fi

out=/tmp/smoke-sub.txt
mosquitto_sub -h 127.0.0.1 -u homeassistant -P "${MQTT_HA_PASSWORD}" -t '#' -v -W 3 > "${out}" 2>/dev/null &
sleep 1
pub -u ring-mqtt -P "${MQTT_RING_PASSWORD}" -t elsewhere/smoke
pub -u ring-mqtt -P "${MQTT_RING_PASSWORD}" -t ring/visible
wait || true
grep -q '^ring/visible ' "${out}" || fail "an allowed message from ring-mqtt did not arrive"
if grep -q '^elsewhere/' "${out}"; then fail "ring-mqtt published outside its ACL"; fi
rm -f "${out}"
echo "smoke: logins, refusals and the ring-mqtt ACL behave"
IN_CONTAINER
