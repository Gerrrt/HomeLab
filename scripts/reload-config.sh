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
#   blackbox-exporter
#                 POST /-/reload. Its modules live in a mounted file, so it has
#                 exactly the failure this script exists for — and it had it:
#                 the file said http_2xx_plain, the running process still knew
#                 only the module names it parsed at startup, and every probe
#                 came back 400 "Unknown module" while `make up` reported
#                 success. Adding a service with a mounted config means adding
#                 it here, and nothing enforces that but this comment.
#   snmp-exporter POST /-/reload. v0.30.1 serves this unconditionally — there
#                 is no lifecycle flag to enable, unlike Prometheus. That is
#                 what lets an SNMP community rotation be `make render && make
#                 reload` rather than a container recreate.
#
# Alloy is deliberately NOT in that list and is restarted instead, at the bottom
# of this file, for reasons written out there. Its absence from this script is
# what made `make up` a silent no-op for every config.alloy change.
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
#
# scripts/check_compose_health.py parses this array and requires each entry to
# name a service whose compose healthcheck probes http://localhost:<that
# port>/-/healthy, because answers_http() below depends on both halves being
# true. Keep the `name:port`, one per line shape — the checker fails loudly if
# it cannot read it, rather than passing on an array it no longer understands.
SERVICES=(
  prometheus:9090
  alertmanager:9093
  snmp-exporter:9116
  blackbox-exporter:9115
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

# Whether the service is listening and answering HTTP right now.
#
# Deliberately the same argv, in the same order, that each of these four already
# runs as its compose healthcheck:
#
#   test: ["CMD", "wget", "--spider", "-q", "http://localhost:<port>/-/healthy"]
#
# Reusing it rather than inventing a probe means the binary, the flag spelling
# and the endpoint are all already known-good in these images rather than hoped
# for — and `scripts/check_compose_health.py --probe` execs that wget inside
# each pinned image on every CI run, so a base change under a Dependabot bump
# cannot quietly take it away (#79). check_compose_health.py also asserts the
# other direction: that every service named in SERVICES below declares a
# healthcheck on this exact URL at that exact port, so the path hardcoded here
# and the ports in that array cannot drift away from compose.yaml.
#
# -T 5 is the one departure from the healthcheck's argv, and it restores
# something the healthcheck already has — docker bounds those probes with
# `timeout: 5s`. Without it, a service that accepts the connection and then
# never answers hangs BusyBox wget for its 900s default and hangs this script
# well past RELOAD_TIMEOUT. That is a failure mode the script does not have
# today, and a readiness probe must not be the thing that introduces it.
#
# If /-/healthy ever stops answering 200 on one of these, this degrades to the
# full-timeout wait that predates it rather than to a wrong answer — and the
# compose healthcheck goes permanently unhealthy in the same instant, which is
# how the snmp-exporter /health-versus-/-/healthy mistake surfaced.
answers_http() {
  "${COMPOSE[@]}" exec -T "$1" \
    wget --spider -q -T 5 "http://localhost:$2/-/healthy" >/dev/null 2>&1
}

reload_one() {
  local svc="$1" port="$2" deadline out rc answered_before=0
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

    # Two things make a reload POST fail, and they want opposite responses. A
    # service that answered and said no has a config on disk that does not
    # parse, and no amount of waiting fixes it. A service that is running but
    # has not bound its listener yet needs exactly that waiting and nothing
    # else. Getting the classification backwards costs either a deploy failed
    # over a config that was fine, or a full timeout spent arriving at the wrong
    # diagnosis.
    #
    # Exit status cannot separate them. All four images ship BusyBox wget, which
    # exits 1 for a refused connection and 1 for an HTTP 500 alike, and does not
    # reliably carry -S to print the status line. So this read the failure's
    # *wording* instead, matching "server returned error" — the substring
    # BusyBox happens to print ahead of the status. That is #80. An upstream
    # rewording, or a base image changing under a Dependabot bump, silently
    # turns every unparseable config back into a full-timeout wait ending in
    # "did not accept a reload / may be serving a stale config", which is the
    # wrong thing to tell someone whose service answered instantly and said
    # exactly which line was bad. Nothing fails when a load-bearing string stops
    # matching; it quietly stops being true, which is the whole complaint.
    #
    # So ask the service rather than parse English at it. answers_http() is the
    # same /-/healthy probe these four already pass as their compose
    # healthcheck: if they answer that, they are listening, and a reload they
    # refused was a refusal.
    #
    # THE ANSWER USED HERE IS THE ONE TAKEN BEFORE THIS POST, held over from the
    # previous attempt, and never one taken after it. Probing after a failed
    # POST and acting on it in the same iteration reads as equivalent and is
    # not. On a cold `make up` the listener binds at some instant inside this
    # loop, and if it binds in the gap between a POST that was correctly refused
    # the connection and a probe that now correctly succeeds, that ordering
    # fires this branch and the deploy dies claiming the operator's config does
    # not parse — #80 with the sign flipped, which is worse, because a wrong
    # answer outranks a slow one here.
    #
    # How likely that is was measured rather than assumed, and it is rarer than
    # it sounds: the same-iteration ordering was run 13 times against restarts
    # of prometheus and blackbox-exporter and never once misfired, because
    # `compose restart` returns late enough and both bind within about a second,
    # so the POST seldom lands inside the window. The window is real — nothing
    # in the code excludes it, and a slower box or a service with a longer
    # startup is exactly where it widens — but do not repeat the claim that it
    # is common, because the measurement does not support it.
    #
    # Holding the answer over is kept anyway, because it costs nothing to be
    # right by construction instead of by timing. Reading evidence gathered
    # strictly before the POST makes the error one-sided: losing the race costs
    # one extra second before the same correct fail-fast, rather than a
    # confident lie about the operator's config.
    #
    # The flag is sticky for a second reason. Once a service has answered HTTP,
    # "not listening yet" has stopped being an available explanation for it — so
    # if it stops answering later it did not refuse anything, it died, and the
    # is_running check below says that instead of blaming the config.
    #
    # rc == 8 (GNU wget's HTTP-error status, for an image that ever ships it)
    # and the BusyBox substring are kept, OR'd in front, and demoted from the
    # decision to a hint. Neither can invent a refusal: both appear only when an
    # HTTP status came back, which is itself proof the service answered. What
    # they buy is skipping the extra second on the common bad-config case, and
    # when they rot nothing breaks — the probe decides one attempt later. Being
    # allowed to rot harmlessly is the property the string never had while it
    # was the only signal.
    #
    # Rejected, because a reviewer will ask. One `sh -c` exec returning distinct
    # exit codes halves the exec count, but bets on /bin/sh existing in four
    # images where nothing asserts it — check_compose_health.py knows wget is
    # there precisely because wget is the healthcheck binary — and it only
    # narrows the race rather than closing it. `docker inspect
    # .State.Health.Status` needs no exec and reuses a probe we already trust,
    # but it is sampled every 30-60s after a 15-30s start_period, so inside a
    # 60s loop it can still read `starting` long after the listener bound.
    if ((answered_before)) || ((rc == 8)) || [[ "${out}" == *"server returned error"* ]]; then
      [[ -n "${out}" ]] && printf '%s\n' "${out}" >&2
      is_running "${svc}" || die \
        "${svc} answered a moment ago and is no longer running, so this is a crash rather than a refused config. Check 'make logs SERVICE=${svc}'."
      # Two causes, named rather than guessed between. The class this now
      # detects is "up and did not accept the POST", which is wider than "does
      # not parse" — a 404 lands here too, and telling someone their YAML is
      # broken when the endpoint simply is not served would be a guess dressed
      # as a finding. The wget output printed just above distinguishes them, so
      # do not branch on " 404" in "${out}" to pick the wording: that is the
      # pattern this change exists to remove, and it would rot the same way.
      die "${svc} refused the reload: it is answering on :${port} and would not take this config, so it is still serving the one it last parsed. Usually the config on disk does not parse and the wget output above says where; an HTTP 404 instead means this build serves no /-/reload — check that prometheus still has --web.enable-lifecycle."
    fi

    # Anything else is almost always wget exit 4, connection refused, because
    # the container is running but has not bound its listener yet. `compose up
    # -d` returns when containers are started, not when they are ready.
    if ((SECONDS >= deadline)); then
      [[ -n "${out}" ]] && printf '%s\n' "${out}" >&2
      die "${svc} did not accept a reload within ${TIMEOUT}s. It may be serving a stale config — check 'make logs SERVICE=${svc}'."
    fi

    # Ask whether it is listening, and keep the answer for the *next* attempt
    # rather than acting on it now. The one-attempt delay is the point, not an
    # oversight — see above. Deferring it this way also keeps the happy path at
    # one exec per service: this line is only ever reached after a POST has
    # already failed, i.e. while the deploy is sitting in the sleep below
    # anyway.
    if answers_http "${svc}" "${port}"; then
      answered_before=1
    fi

    sleep 1
  done
}

# Alloy is the exception, and gets restarted rather than reloaded.
#
# Not for want of a reload path — Alloy documents both POST /-/reload and
# SIGHUP. The problem is verifying that the reload landed, which is the whole
# point of this script:
#
#   * `compose exec ... wget` works for the three above because their images are
#     Alpine/BusyBox based. grafana/alloy is not. There is no wget and no curl
#     inside it to POST with.
#   * SIGHUP needs nothing in-container, but it is silent. Alloy keeps serving
#     the previous config when the new one fails to parse and reports it only in
#     its logs — precisely the failure this script exists to catch.
#   * Alloy's controller metrics cover component health, not config loading. A
#     rejected reload leaves the old components running and healthy, so nothing
#     there moves either.
#
# A restart has none of that ambiguity. If the config parses, the process comes
# back running it; if it does not, Alloy exits, and `restart: unless-stopped`
# turns that into a crash loop that docker reports as `restarting` rather than
# `running`. The state is readable from outside with no cooperation from the
# image.
#
# It is affordable here in a way it would not be for Prometheus. Alloy's WAL and
# file positions live in the alloy-data volume, so a restart re-reads from where
# it left off rather than re-sending or skipping. There is no TSDB head to drop.
#
# This gap is why `make up` was a no-op for config.alloy: nothing recreated the
# container and nothing reloaded it, so a fifty-minute-old process kept serving
# the config it booted with while the deploy reported success. Measured on
# prometheus: container started 02:48:40, config written 03:38:45, and the
# deploy in between changed nothing.
#
# The cost is a restart of Alloy on every `make up`, including the ones where
# config.alloy did not change. A few seconds of collection gap, resumed from the
# WAL, is the right trade against a deploy that silently does nothing — and
# comparing file mtime against container start time to skip it would reintroduce
# a decision this script exists to stop making.
restart_alloy() {
  local stable=0 deadline

  is_running alloy || die \
    "alloy is not running, so there is nothing to reload. Check 'make ps', then 'make up'."

  "${COMPOSE[@]}" restart alloy >/dev/null 2>&1 || die "could not restart alloy"

  # A container about to die from a bad config is briefly `running`, so require
  # it to stay that way rather than sampling once and believing the first answer.
  deadline=$((SECONDS + TIMEOUT))
  while ((stable < 3)); do
    if is_running alloy; then stable=$((stable + 1)); else stable=0; fi
    if ((SECONDS >= deadline)); then
      die "alloy did not stay up within ${TIMEOUT}s. Its config on disk probably does not parse — check 'make logs SERVICE=alloy'."
    fi
    sleep 1
  done

  ok "alloy (restarted)"
}

# SERVICES above is the union across every stack, not the contents of this one.
# `stacks/lab` runs Prometheus, Loki, Grafana and Alloy and no Alertmanager,
# snmp-exporter or blackbox-exporter (ADR-0020), so reloading the array as
# written died on the first service that stack does not have — and it died
# through reload_one's "is not running, so there is nothing to reload", which is
# the correct message for a stopped service and a wrong one for an absent one.
#
# The two cases must stay separate, which is why this filters on what the
# compose file DEFINES rather than on what is running. A service this stack
# declares and is not running is still a failed deploy and still dies below;
# only one it never declared is skipped.
#
# `compose config --services` rather than grepping for two-space-indented keys:
# the answer is compose's own, so a service list this script disagrees with is
# not a shape it can be tricked by. It needs the ${VAR:?} guards satisfied,
# which is true wherever this runs — `make up` renders .env immediately before
# calling this, and `make reload` acts on a stack that is already up. If it
# cannot answer at all, fall back to the full array: that is exactly today's
# behaviour, so the failure mode is the one that has always been there rather
# than a new one.
declared=""
if ! declared="$("${COMPOSE[@]}" config --services 2>/dev/null)"; then
  declared=""
fi

for entry in "${SERVICES[@]}"; do
  svc="${entry%%:*}"
  if [[ -n "${declared}" ]] && ! grep -qx "${svc}" <<<"${declared}"; then
    continue
  fi
  reload_one "${svc}" "${entry##*:}"
done

restart_alloy

printf '\033[0;32mreloaded\033[0m — every service re-read its config from disk\n'
