#!/usr/bin/env bash
#
# Make every running service re-read its config from disk.
#
# This exists because `docker compose up -d` recreates a container only when its
# *service definition* changes. A changed bind-mounted file is invisible to it:
# compose compares the config hash of the service (image, command, mounts,
# environment), not the contents of what those mounts point at. So
# render-config.sh can write a brand-new snmp.yaml, `make up` reports success,
# and snmp-exporter keeps serving the config it parsed at startup.
#
# That is not hypothetical. The corrected pfSense walk in PR #18 was rendered to
# disk, `make up` ran clean, and the exporter kept timing out at 45s until
# someone restarted the container by hand. The failure mode is the bad one: the
# tool says done, and only the target tells you otherwise, minutes later.
#
# Reload rather than restart, for all three:
#
#   prometheus    POST /-/reload, gated behind --web.enable-lifecycle, which
#                 compose.yaml sets. A restart would drop the TSDB head.
#   alertmanager  POST /-/reload. Its .rendered/webhook_url is read at notify
#                 time so it does not need this, but alertmanager.yaml is a
#                 bind mount with exactly the staleness problem above.
#   snmp-exporter POST /-/reload. v0.30.1 serves this unconditionally — there
#                 is no lifecycle flag to enable, unlike Prometheus. That is
#                 what lets an SNMP community rotation be `make render && make
#                 reload` rather than a container recreate.
#
# The snmp-exporter reload works only because render-config.sh writes the
# rendered file with `>`, truncating in place and keeping the inode. The
# container bind-mounts the file, not the directory, so switching to
# write-temp-then-mv would leave the mount pointing at the old inode and this
# reload would cheerfully re-read the old community.
#
# Failing is the point. An earlier sketch of this swallowed reload errors so
# `make up` would not break on a slow box — which rebuilds the exact defect it
# was written to close, because a swallowed reload leaves `make up` reporting
# success over a stale config. A reload that never lands is a failed deploy and
# says so.
#
# Usage: scripts/reload-config.sh [stack]      (default: observability)
#
# RELOAD_TIMEOUT=<seconds> bounds how long a running-but-not-yet-listening
# container is given to answer. Only reached on a cold `make up`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:-observability}"
COMPOSE_FILE="${REPO_ROOT}/stacks/${STACK}/compose.yaml"
TIMEOUT="${RELOAD_TIMEOUT:-60}"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[0;32m  reloaded\033[0m %s\n' "$*"; }

[[ -f "${COMPOSE_FILE}" ]] || die "no such stack: ${COMPOSE_FILE}"

COMPOSE=(docker compose -f "${COMPOSE_FILE}")

# service:port. Ordered cheapest-to-diagnose first: if the whole stack is down,
# the operator sees prometheus fail rather than waiting out three timeouts.
SERVICES=(
  prometheus:9090
  alertmanager:9093
  snmp-exporter:9116
)

# Whether compose considers the service up right now. Checked before the retry
# loop so a stopped container fails immediately with advice, instead of burning
# the full timeout re-discovering that it is stopped — `make reload` against a
# stopped stack is a documented, ordinary mistake.
is_running() {
  local cid
  # `compose ps -q` and `docker inspect -f`, not `compose ps --format
  # '{{.State}}'`: custom Go templates only reached `compose ps` in a later
  # Compose v2, and on an older one the template is taken as a literal format
  # name, so every service reads as not-running and `make up` fails on a
  # perfectly healthy stack. `-q` has meant the same thing since v1.
  #
  # `compose ps` without --all lists running containers only, so a stopped
  # service yields an empty id. A crash-looping one is listed, and inspect
  # reports `restarting` — which is correctly not `running`, since a container
  # that is always restarting looks alive and reloads nothing.
  cid="$("${COMPOSE[@]}" ps -q "$1" 2>/dev/null)" || return 1
  [[ -n "${cid}" ]] || return 1
  [[ "$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null)" == "running" ]]
}

reload_one() {
  local svc="$1" port="$2" deadline out rc
  deadline=$((SECONDS + TIMEOUT))

  is_running "${svc}" || die \
    "${svc} is not running, so there is nothing to reload. Check 'make ps', then 'make up'."

  while :; do
    # -T: no TTY allocation, so the response body is capturable and this
    # behaves the same under make, CI and a bare shell.
    #
    # rc is captured with `|| rc=$?` rather than read from $? after an `if`.
    # An `if` whose condition fails and which has no else branch exits 0, so
    # `$?` afterwards is the status of the *if*, not of the command — which
    # silently disarmed the rc == 8 branch below and turned every bad config
    # into a full-timeout wait.
    rc=0
    out="$("${COMPOSE[@]}" exec -T "${svc}" \
      wget -q -O- --post-data='' "http://localhost:${port}/-/reload" 2>&1)" || rc=$?
    if ((rc == 0)); then
      ok "${svc}"
      return 0
    fi

    # "The service answered and refused" means a config on disk that does not
    # parse, and no amount of waiting fixes it — so do not spend the timeout
    # pretending otherwise.
    #
    # Detected by message, not by exit status, because all three images ship
    # BusyBox wget and BusyBox exits 1 for everything: a refused connection and
    # an HTTP 500 are indistinguishable by status. This was written against GNU
    # wget's exit 8 first, which meant the branch could never fire and every
    # unparseable config waited out the full timeout before reporting a
    # misleading "did not accept a reload" — the wrong diagnosis for a service
    # that had answered immediately and said exactly what was wrong. The exit 8
    # test is kept for an image that ever ships GNU wget; on these three it is
    # the string that fires.
    if ((rc == 8)) || [[ "${out}" == *"server returned error"* ]]; then
      [[ -n "${out}" ]] && printf '%s\n' "${out}" >&2
      die "${svc} refused the reload: its config on disk does not parse. It is still serving the previous config."
    fi

    # Anything else is almost always wget exit 4, connection refused, because
    # the container is running but has not bound its listener yet. `compose up
    # -d` returns when containers are started, not when they are ready.
    if ((SECONDS >= deadline)); then
      [[ -n "${out}" ]] && printf '%s\n' "${out}" >&2
      die "${svc} did not accept a reload within ${TIMEOUT}s. It may be serving a stale config — check 'make logs SERVICE=${svc}'."
    fi
    sleep 1
  done
}

for entry in "${SERVICES[@]}"; do
  reload_one "${entry%%:*}" "${entry##*:}"
done

printf '\033[0;32mreloaded\033[0m — every service re-read its config from disk\n'
