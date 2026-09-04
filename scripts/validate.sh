#!/usr/bin/env bash
#
# Everything CI runs, runnable locally.
#
# Image versions come from compose.yaml via scripts/image-for.sh, so the
# containers used here are the ones actually deployed. A locally installed
# binary is preferred when present for speed — if yours is a different version
# from the pin, CI is the authority.
#
# Usage: scripts/validate.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

STACK="stacks/observability"
# Resolved from compose.yaml so Dependabot's bumps reach the checks. Hardcoding
# these meant CI validated Prometheus v3.1.0 configs while the stack ran v3.13.2.
PROM_IMAGE="$(./scripts/image-for.sh prometheus)"
AM_IMAGE="$(./scripts/image-for.sh alertmanager)"
ALLOY_IMAGE="$(./scripts/image-for.sh alloy)"
GITLEAKS_IMAGE="$(./scripts/image-for.sh gitleaks)"

FAILED=0
SKIPPED=0
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
# Skips are counted, and the count is printed in the summary. A run that ends
# `all checks passed` while five checks never executed is making a claim it has
# not earned — the same shape of lie as a UPS reporting a battery it does not
# have, which this repository has been bitten by. See the summary at the bottom.
skip() { printf '\033[0;33m  SKIP\033[0m %s\n' "$*"; SKIPPED=$((SKIPPED + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }
have_docker() { have docker && docker info >/dev/null 2>&1; }

# One trap for every temporary file this script owns. A second `trap ... EXIT`
# replaces the first rather than adding to it, so they are registered together
# here instead of next to the code that creates them.
TMP_ENV=""
LINT_SKIPS=""
LOKI_SKIPS=""
TIMER_SKIPS=""
ROUNDTRIP_SKIPS=""
cleanup() {
  [[ -n "${TMP_ENV}" ]] && rm -f "${TMP_ENV}"
  [[ -n "${LINT_SKIPS}" ]] && rm -f "${LINT_SKIPS}"
  [[ -n "${LOKI_SKIPS}" ]] && rm -f "${LOKI_SKIPS}"
  [[ -n "${TIMER_SKIPS}" ]] && rm -f "${TIMER_SKIPS}"
  [[ -n "${ROUNDTRIP_SKIPS}" ]] && rm -f "${ROUNDTRIP_SKIPS}"
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
head_ "Compose"
# ---------------------------------------------------------------------------
if have docker; then
  # A .env is required for the ${VAR:?} guards; seeded by the same script CI
  # uses, so a variable added there cannot pass locally and fail in CI. Written
  # to a temp file rather than ${STACK}/.env so a local run never leaves an .env
  # sitting next to a real one.
  TMP_ENV="$(mktemp)"
  if ! ./scripts/seed-validation-env.sh "${TMP_ENV}"; then
    fail "seed a validation-only .env"
  elif docker compose --env-file "${TMP_ENV}" -f "${STACK}/compose.yaml" config -q 2>/dev/null; then
    pass "docker compose config"
  else
    docker compose --env-file "${TMP_ENV}" -f "${STACK}/compose.yaml" config -q
    fail "docker compose config"
  fi
else
  skip "docker not installed"
fi

# ---------------------------------------------------------------------------
head_ "Prometheus"
# ---------------------------------------------------------------------------
if have promtool; then
  PROMTOOL=(promtool)
elif have_docker; then
  PROMTOOL=(docker run --rm --entrypoint promtool -v "${REPO_ROOT}:/repo" -w /repo "${PROM_IMAGE}")
else
  PROMTOOL=()
fi

if ((${#PROMTOOL[@]})); then
  if "${PROMTOOL[@]}" check config "${STACK}/prometheus/prometheus.yaml" 2>&1 \
      | grep -qE '^\s*SUCCESS'; then
    pass "promtool check config"
  else
    "${PROMTOOL[@]}" check config "${STACK}/prometheus/prometheus.yaml"
    fail "promtool check config"
  fi

  if "${PROMTOOL[@]}" check rules "${STACK}"/prometheus/rules/*.rules.yaml >/dev/null 2>&1; then
    pass "promtool check rules"
  else
    "${PROMTOOL[@]}" check rules "${STACK}"/prometheus/rules/*.rules.yaml
    fail "promtool check rules"
  fi

  # `check rules` only parses PromQL; it cannot tell whether an expression can
  # ever be true. ContainerHighMemory passed it for months while being
  # unfireable (#63). The unit tests are what actually assert the rules fire.
  if "${PROMTOOL[@]}" test rules "${STACK}"/prometheus/tests/*.test.yaml >/dev/null 2>&1; then
    pass "promtool test rules"
  else
    "${PROMTOOL[@]}" test rules "${STACK}"/prometheus/tests/*.test.yaml
    fail "promtool test rules"
  fi
else
  skip "no promtool and no docker daemon"
fi

# ---------------------------------------------------------------------------
head_ "Alertmanager"
# ---------------------------------------------------------------------------
if have amtool; then
  AMTOOL=(amtool)
elif have_docker; then
  AMTOOL=(docker run --rm --entrypoint amtool \
          -v "${REPO_ROOT}:/repo" -w /repo "${AM_IMAGE}")
else
  AMTOOL=()
fi

# The receiver URL comes from url_file, which Alertmanager reads at notify time
# rather than at load time — so this validates without any secret present.
if ((${#AMTOOL[@]})); then
  if "${AMTOOL[@]}" check-config "${STACK}/alertmanager/alertmanager.yaml" >/dev/null 2>&1; then
    pass "amtool check-config"
  else
    "${AMTOOL[@]}" check-config "${STACK}/alertmanager/alertmanager.yaml"
    fail "amtool check-config"
  fi

  # check-config proves the tree parses and that every route names a receiver
  # that exists. It says nothing about WHICH receiver an alert reaches, and the
  # routing tree is first-match-wins with no `continue` anywhere — so moving a
  # category route below the bare `severity` routes stops it matching while
  # check-config still passes. That is the #66 failure shape exactly: a config
  # that loads, validates, and delivers to the wrong place.
  #
  # Each line below is one row of the table in alertmanager.yaml.
  # --verify.receivers exits non-zero when the resolved receiver differs.
  #
  # The Watchdog row expects TWO receivers because its first route sets
  # `continue: true` — the one place in the tree that does. That row is also
  # what catches a `severity` slip on the watchdog rule: with `info` it would
  # resolve to "null" and the dead man's switch would be silently disarmed.
  routes_ok=1
  while read -r expected labels; do
    [[ -n "${expected}" ]] || continue
    # shellcheck disable=SC2086  # labels is a deliberate word-split list
    if ! "${AMTOOL[@]}" config routes test \
         --config.file="${STACK}/alertmanager/alertmanager.yaml" \
         --verify.receivers="${expected}" ${labels} >/dev/null 2>&1; then
      printf 'expected %s for %s, got: ' "${expected}" "${labels}" >&2
      "${AMTOOL[@]}" config routes test \
        --config.file="${STACK}/alertmanager/alertmanager.yaml" ${labels} >&2
      routes_ok=0
    fi
  done <<'ROUTES'
heartbeat,default alertname=Watchdog severity=none category=monitoring
urgent    severity=critical category=power
security  severity=critical category=security
security  severity=warning category=security
urgent    severity=critical category=availability
default   severity=warning category=capacity
default   severity=warning category=hardware
null      severity=info category=correctness
ROUTES

  if ((routes_ok)); then
    pass "amtool config routes test (8 assertions)"
  else
    fail "amtool config routes test"
  fi
else
  skip "no amtool and no docker daemon"
fi

# ---------------------------------------------------------------------------
head_ "Alloy"
# ---------------------------------------------------------------------------
if have alloy; then
  ALLOY=(alloy)
elif have_docker; then
  ALLOY=(docker run --rm -v "${REPO_ROOT}:/repo" -w /repo --entrypoint alloy "${ALLOY_IMAGE}")
else
  ALLOY=()
fi

# `fmt --test` fails on a syntax error and on non-canonical formatting. It does
# not check component configuration — Alloy has no `validate` subcommand.
#
# Every file in the directory, because that is what the agent loads: the
# monitoring host mounts all of them, and deploy-agent.sh ships a subset. One
# unformatted file used to be impossible to have; now it is one `fmt -w` away
# from being missed, and this is the check that misses nothing.
if ((${#ALLOY[@]})); then
  for alloy_file in "${STACK}"/alloy/*.alloy; do
    if "${ALLOY[@]}" fmt --test "${alloy_file}" >/dev/null 2>&1; then
      pass "alloy fmt --test ${alloy_file##*/}"
    else
      "${ALLOY[@]}" fmt --test "${alloy_file}"
      fail "alloy fmt --test ${alloy_file##*/}"
    fi
  done
else
  skip "no alloy binary and no docker daemon"
fi

# ---------------------------------------------------------------------------
head_ "Compose health dependencies"
# ---------------------------------------------------------------------------
# The static half needs python3 and nothing else, which is why this block is not
# docker-gated as a whole. --probe is the half that needs a daemon: it execs each
# healthcheck's binary inside that service's pinned image, which is the only way
# to know an image has not moved to a distroless base under a Dependabot bump
# (#79). Without it the static half still runs — it just proves less, and the
# SKIP below is what says so. CI always passes --probe and may not skip it.
if have python3; then
  HEALTH=(python3 scripts/check_compose_health.py)
  if have_docker; then
    HEALTH+=(--probe)
  else
    skip "no docker daemon — healthcheck binaries not probed inside their images"
  fi
  if "${HEALTH[@]}"; then
    pass "compose health dependencies"
  else
    fail "compose health dependencies"
  fi
else
  skip "python3 not installed"
fi

# ---------------------------------------------------------------------------
head_ "Image pins"
# ---------------------------------------------------------------------------
# Every docker run/pull/create in this repository must take its image from
# compose.yaml via scripts/image-for.sh. `make backup` ran a bare `alpine` past
# all three of CI's pattern-based image checks (#65), because the defect was a
# pin that was absent rather than wrong. Kept in step with ci.yml — this pair
# has drifted before (#68).
if have python3; then
  if python3 scripts/check_image_pins.py; then
    pass "every docker image comes from compose.yaml"
  else
    fail "a docker image does not come from compose.yaml"
  fi
else
  skip "python3 not installed"
fi

# ---------------------------------------------------------------------------
head_ "Loki rules and dashboard LogQL"
# ---------------------------------------------------------------------------
# The skips file is why this is not a bare call: check_loki_rules.sh prints its
# own SKIP and exits 0 when there is no loki binary and no docker, which read as
# a pass here and left SKIPPED untouched — so this script could sign off with an
# unqualified "all checks passed" over rules it never validated (#68).
LOKI_SKIPS="$(mktemp)"
if ./scripts/check_loki_rules.sh --skips-file "${LOKI_SKIPS}"; then
  :
else
  FAILED=1
fi
SKIPPED=$((SKIPPED + $(wc -l < "${LOKI_SKIPS}")))

# ---------------------------------------------------------------------------
head_ "Grafana dashboards"
# ---------------------------------------------------------------------------
if have python3; then
  if python3 scripts/check_dashboards.py; then
    pass "dashboard JSON and datasource references"
  else
    fail "dashboard JSON and datasource references"
  fi
else
  skip "python3 not installed"
fi

# check_dashboards.py reads the JSON; this boots the pinned Grafana and makes it
# serve the JSON back. They answer different questions and neither covers the
# other: the first says the dashboards are internally coherent, the second says
# the committed form is the form Grafana produces — and that a UI edit can still
# be saved at all, which is the one condition `make dashboards-export` cannot
# work without and cannot detect for itself (#100).
#
# Owns its own skips file for the same reason check_loki_rules.sh does: it
# prints its own SKIP and exits 0 with no docker, which would read as a pass
# here and leave SKIPPED untouched (#68).
ROUNDTRIP_SKIPS="$(mktemp)"
./scripts/check_dashboard_roundtrip.sh --skips-file "${ROUNDTRIP_SKIPS}" || FAILED=1
SKIPPED=$((SKIPPED + $(wc -l < "${ROUNDTRIP_SKIPS}")))

# ---------------------------------------------------------------------------
head_ "Documentation"
# ---------------------------------------------------------------------------
# Asserts the prose still agrees with the configs it describes: rule and panel
# counts, the SNMP inventory against docs/network.md, the host/stack and ports
# tables against compose.yaml, and image versions quoted in Markdown. Doc drift
# is the one defect class here that had no check — see #72, #73 and #104.
if have python3; then
  if python3 scripts/check_docs.py; then
    pass "documents agree with the configs"
  else
    fail "documents disagree with the configs"
  fi
else
  skip "python3 not installed"
fi

# ---------------------------------------------------------------------------
head_ "Lint"
# ---------------------------------------------------------------------------
# The list of linters lives in scripts/lint.sh and nowhere else. CI runs the
# same script with --require-all, so a linter added here cannot be absent there,
# and a yamllint warning cannot pass here and fail there (#68). lint.sh prints
# its own PASS/FAIL/SKIP lines, the way check_loki_rules.sh does.
#
# --skips-file follows seed-validation-env.sh's contract: this caller owns the
# path and its lifetime. The file exists only so the SKIPPED count below stays
# true — without it an unreachable markdownlint would print SKIP and this script
# would still sign off with an unqualified "all checks passed".
LINT_SKIPS="$(mktemp)"
./scripts/lint.sh --skips-file "${LINT_SKIPS}" || FAILED=1
SKIPPED=$((SKIPPED + $(wc -l < "${LINT_SKIPS}")))

# ---------------------------------------------------------------------------
head_ "SNMP inventory"
# ---------------------------------------------------------------------------
# The device list is spread across prometheus/targets/snmp.yaml, generator.yaml,
# render-config.sh's REQUIRED array and secrets/observability.example.yaml. Drift
# between them is invisible until a poll goes out with an empty community — and
# the generator path fails *open*, so nothing downstream catches it. This is
# offline: no decryption, no network.
if ./scripts/snmp-targets.sh --check >/dev/null 2>&1; then
  pass "snmp inventory consistent across targets, generator, render and example"
else
  ./scripts/snmp-targets.sh --check
  fail "snmp inventory is inconsistent"
fi

# ---------------------------------------------------------------------------
head_ "Scheduled jobs"
# ---------------------------------------------------------------------------
# The cadence lives in systemd/*.timer and the staleness threshold lives in the
# JOBS table in install-timers.sh, and an alert that fires a week after every
# normal run is the failure mode when they disagree. --check derives each
# timer's real period from `systemd-analyze calendar` and asserts the threshold
# is at least twice it, so the two cannot drift the way the amtool route
# assertions did (#68).
#
# It also asserts every ExecStart= goes through run-scheduled.sh. That is the
# one guard standing between a unit file and an unpinned `docker run`:
# check_image_pins.py scans the Makefile, scripts, workflows and Markdown, but
# not systemd units.
#
# Offline and unprivileged, which is why it is here and not under Maintenance
# with `make install-timers`. It owns its own skips file so a host without
# systemd-analyze does not silently claim the schedule was checked.
TIMER_SKIPS="$(mktemp)"
if ./scripts/install-timers.sh --check --skips-file "${TIMER_SKIPS}"; then
  pass "scheduled job cadences, thresholds and units agree"
else
  fail "the schedule and its thresholds disagree"
fi
if [[ -s "${TIMER_SKIPS}" ]]; then
  SKIPPED=$((SKIPPED + $(wc -l < "${TIMER_SKIPS}")))
fi

# ...and whether any of it reached this host.
#
# --check above compares two copies of the schedule that both live in git: the
# cadence in systemd/*.timer against the threshold in install-timers.sh. It is
# a good check and it is entirely repo-internal, which is why it passed every
# run while this host had no homelab units installed at all, no textfile
# directory, and had therefore never taken a scheduled backup (#215). The
# repository agreed with itself and nothing ran.
#
# So this asks the other question. It is deliberately conditional on the stack
# running here, because that is what distinguishes the deployment host from a
# checkout: a laptop with the repository on it owes nothing, and a host serving
# the stack while running none of its maintenance is exactly the condition #215
# was. That is also why this is a fail and not a warning — the four rules in
# backup.rules.yaml that would notice a missed job all join against a series
# install-timers.sh writes, so none of them can fire until it has been run.
if ! have systemctl; then
  skip "systemctl absent — cannot tell whether the schedule is installed"
elif ! have_docker; then
  skip "docker unavailable — cannot tell whether this is the deployment host"
elif ! docker compose -f "${STACK}/compose.yaml" ps --status running -q 2>/dev/null | grep -q .; then
  skip "the stack is not running here — this is not the deployment host"
elif systemctl list-unit-files 'homelab-*' --no-legend 2>/dev/null | grep -q .; then
  pass "the schedule is installed on this host"
else
  fail "the stack runs here but no homelab-* units are installed — run 'make install-timers' (#215)"
fi

# ---------------------------------------------------------------------------
head_ "Secrets"
# ---------------------------------------------------------------------------
# Both scans, matching CI exactly. Running only the working-tree scan locally
# would let `make validate` pass while CI fails on history, or vice versa.
# The docker fallback is the same shape promtool, amtool and alloy have above,
# and its absence here meant both scans skipped on a host with docker running
# and the pinned image one `docker run` away — while CI ran them every push.
# Silently, because a skip was all it printed (#68).
if have gitleaks; then
  GITLEAKS=(gitleaks)
elif have_docker; then
  GITLEAKS=(docker run --rm -v "${REPO_ROOT}:/repo" -w /repo "${GITLEAKS_IMAGE}")
else
  GITLEAKS=()
fi

if ((${#GITLEAKS[@]})); then
  if "${GITLEAKS[@]}" detect --no-git --no-banner --redact -c .gitleaks.toml >/dev/null 2>&1; then
    pass "gitleaks (working tree)"
  else
    "${GITLEAKS[@]}" detect --no-git --no-banner --redact -c .gitleaks.toml
    fail "gitleaks (working tree)"
  fi

  if "${GITLEAKS[@]}" detect --no-banner --redact -c .gitleaks.toml --log-opts="--all" >/dev/null 2>&1; then
    pass "gitleaks (full history)"
  else
    "${GITLEAKS[@]}" detect --no-banner --redact -c .gitleaks.toml --log-opts="--all"
    fail "gitleaks (full history)"
  fi
else
  skip "no gitleaks binary and no docker daemon"
fi

# Cheap belt-and-braces check that no rendered or decrypted artefact is staged.
# gitleaks cannot cover .purge-secrets.txt — it is gitignored (so the filesystem
# scan skips it) and holds bare literals with no keyword context to match. Being
# untracked is the control.
# certificates/ is in that list because its contents were committed once and
# had to be removed by rewriting every commit in the repository. The cheapest
# possible check is that it never becomes tracked again.
if git ls-files --error-unmatch "${STACK}/.env" >/dev/null 2>&1 \
   || git ls-files "${STACK}/snmp-exporter/.rendered" | grep -q . \
   || git ls-files | grep -q '\.purge-secrets\.txt' \
   || git ls-files | grep -q '^certificates/' \
   || git ls-files | grep -q '^backups/'; then
  fail "a rendered, decrypted, purge-secrets, certificate or backup file is tracked by git"
else
  pass "no rendered, decrypted, purge-secrets, certificate or backup files tracked"
fi

printf '\n'
if ((FAILED)); then
  printf '\033[0;31mvalidation failed\033[0m\n'; exit 1
fi
if ((SKIPPED)); then
  printf '\033[0;32mall checks passed\033[0m \033[0;33m(%d skipped — NOT run, not verified)\033[0m\n' "${SKIPPED}"
  printf 'Skipped checks prove nothing. CI runs the full set; a clean run here is\n'
  printf 'weaker evidence than it looks.\n'
else
  printf '\033[0;32mall checks passed\033[0m\n'
fi
