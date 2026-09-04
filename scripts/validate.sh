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

# Every stack, from the one place that defines what a stack is. This was
# `STACK="stacks/observability"`, which is why `stacks/lab` landed as a stack
# CI had never seen — its compose was not `config`-checked, its rules were not
# promtool-tested, its images were pinned by nothing (#263).
#
# A failure here is fatal rather than an empty loop: stacks.sh exits non-zero
# on a directory under stacks/ with no compose.yaml, and silently validating
# zero stacks is the precise defect this is fixing.
# Command substitution and not `mapfile < <(...)`: a process substitution's
# exit status is not mapfile's, so `if ! mapfile ...` succeeds even when
# stacks.sh has just refused — which would turn "a stack nothing checks" into
# "no stacks checked at all", reported as a pass.
if ! STACK_LIST="$(./scripts/stacks.sh)"; then
  printf '\033[0;31merror:\033[0m could not list the stacks — see above\n' >&2
  exit 1
fi
mapfile -t STACKS <<< "${STACK_LIST}"
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

# Whether ANY stack is up on this machine. Used to decide whether this is a
# deployment host, which was previously "is the observability stack running".
# The lab stack runs on its own guest, and a host running only that one is
# still a deployment host with timers to install.
stack_running() {
  local stack
  for stack in "${STACKS[@]}"; do
    if docker compose -f "stacks/${stack}/compose.yaml" ps --status running -q 2>/dev/null \
       | grep -q .; then
      return 0
    fi
  done
  return 1
}

# One trap for every temporary file this script owns. A second `trap ... EXIT`
# replaces the first rather than adding to it, so they are registered together
# here instead of next to the code that creates them.
TMP_ENV=""
LINT_SKIPS=""
LOKI_SKIPS=""
TIMER_SKIPS=""
ROUNDTRIP_SKIPS=""
DASH_EXPRS=""
cleanup() {
  [[ -n "${TMP_ENV}" ]] && rm -f "${TMP_ENV}"
  [[ -n "${LINT_SKIPS}" ]] && rm -f "${LINT_SKIPS}"
  [[ -n "${LOKI_SKIPS}" ]] && rm -f "${LOKI_SKIPS}"
  [[ -n "${TIMER_SKIPS}" ]] && rm -f "${TIMER_SKIPS}"
  [[ -n "${ROUNDTRIP_SKIPS}" ]] && rm -f "${ROUNDTRIP_SKIPS}"
  [[ -n "${DASH_EXPRS}" ]] && rm -f "${DASH_EXPRS}"
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
head_ "Compose"
# ---------------------------------------------------------------------------
if have docker; then
  # A .env is required for the ${VAR:?} guards; seeded by the same script CI
  # uses, so a variable added there cannot pass locally and fail in CI. Written
  # to a temp file rather than ${sd}/.env so a local run never leaves an .env
  # sitting next to a real one.
  #
  # Seeded PER STACK, because the guard list is derived from that stack's own
  # compose.yaml. Seeding every stack from the estate's guards would prove
  # nothing about the file being validated.
  TMP_ENV="$(mktemp)"
  for stack in "${STACKS[@]}"; do
    sd="stacks/${stack}"
    if ! ./scripts/seed-validation-env.sh "${TMP_ENV}" "${stack}"; then
      fail "${stack}: seed a validation-only .env"
    elif docker compose --env-file "${TMP_ENV}" -f "${sd}/compose.yaml" config -q 2>/dev/null; then
      pass "${stack}: docker compose config"
    else
      docker compose --env-file "${TMP_ENV}" -f "${sd}/compose.yaml" config -q
      fail "${stack}: docker compose config"
    fi
  done
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
  for stack in "${STACKS[@]}"; do
    sd="stacks/${stack}"
    # A stack need not run Prometheus at all. Absence is reported and moved
    # past rather than skipped: a skip means "could not check", and this ran
    # and found nothing to check. Inflating SKIPPED with by-design absences is
    # how the count stops being read (#68).
    if [[ ! -f "${sd}/prometheus/prometheus.yaml" ]]; then
      pass "${stack}: no prometheus.yaml — nothing to check"
      continue
    fi

    if "${PROMTOOL[@]}" check config "${sd}/prometheus/prometheus.yaml" 2>&1 \
        | grep -qE '^\s*SUCCESS'; then
      pass "${stack}: promtool check config"
    else
      "${PROMTOOL[@]}" check config "${sd}/prometheus/prometheus.yaml"
      fail "${stack}: promtool check config"
    fi

    # nullglob so an absent rules/ or tests/ directory does not hand promtool
    # the literal glob, which it reports as a missing file — a failure that
    # reads as a broken rule rather than as a stack that has none.
    shopt -s nullglob
    rule_files=("${sd}"/prometheus/rules/*.rules.yaml)
    test_files=("${sd}"/prometheus/tests/*.test.yaml)
    shopt -u nullglob

    if ((${#rule_files[@]} == 0)); then
      pass "${stack}: no alert rules — nothing to check"
    elif "${PROMTOOL[@]}" check rules "${rule_files[@]}" >/dev/null 2>&1; then
      pass "${stack}: promtool check rules (${#rule_files[@]} file(s))"
    else
      "${PROMTOOL[@]}" check rules "${rule_files[@]}"
      fail "${stack}: promtool check rules"
    fi

    # `check rules` only parses PromQL; it cannot tell whether an expression can
    # ever be true. ContainerHighMemory passed it for months while being
    # unfireable (#63). The unit tests are what actually assert the rules fire.
    #
    # Rules with no tests is a FAIL and not a pass-with-a-note, and that is the
    # one place this loop is stricter than the old single-stack version. A new
    # stack arriving with rules and no tests is #63 waiting to happen, and the
    # moment to say so is when the rules land.
    if ((${#rule_files[@]} == 0)); then
      :
    elif ((${#test_files[@]} == 0)); then
      fail "${stack}: ${#rule_files[@]} rule file(s) and no promtool tests — a rule that cannot fire passes 'check rules' (#63)"
    elif "${PROMTOOL[@]}" test rules "${test_files[@]}" >/dev/null 2>&1; then
      pass "${stack}: promtool test rules (${#test_files[@]} file(s))"
    else
      "${PROMTOOL[@]}" test rules "${test_files[@]}"
      fail "${stack}: promtool test rules"
    fi
  done
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
# Which stacks have an Alertmanager at all. `stacks/lab` has none by decision
# (ADR-0020), so there is no config to parse and no routing tree to assert
# against — the ROUTES table below describes the estate's tree specifically.
am_stacks=()
for stack in "${STACKS[@]}"; do
  [[ -f "stacks/${stack}/alertmanager/alertmanager.yaml" ]] && am_stacks+=("${stack}")
done

if ((${#am_stacks[@]} == 0)); then
  pass "no stack runs an Alertmanager — nothing to check"
elif ((${#AMTOOL[@]})); then
 for stack in "${am_stacks[@]}"; do
  STACK="stacks/${stack}"
  if "${AMTOOL[@]}" check-config "${STACK}/alertmanager/alertmanager.yaml" >/dev/null 2>&1; then
    pass "${stack}: amtool check-config"
  else
    "${AMTOOL[@]}" check-config "${STACK}/alertmanager/alertmanager.yaml"
    fail "${stack}: amtool check-config"
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
    pass "${stack}: amtool config routes test (8 assertions)"
  else
    fail "${stack}: amtool config routes test"
  fi
 done
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
# Every *.alloy in the repository, found rather than assumed to live under one
# stack. `stacks/lab` has no alloy/ directory — it mounts config.alloy and
# docker.alloy straight out of stacks/observability/alloy/ (ADR-0007's "reused
# unchanged"), so those files are checked once here and are the same bytes both
# stacks run. A stack that grows its own agent config is picked up with no
# change to this block.
shopt -s nullglob globstar
alloy_files=(stacks/**/alloy/*.alloy)
shopt -u nullglob globstar

if ((${#alloy_files[@]} == 0)); then
  fail "no *.alloy anywhere under stacks/ — the agent config has gone missing"
elif ((${#ALLOY[@]})); then
  for alloy_file in "${alloy_files[@]}"; do
    if "${ALLOY[@]}" fmt --test "${alloy_file}" >/dev/null 2>&1; then
      pass "alloy fmt --test ${alloy_file#stacks/}"
    else
      "${ALLOY[@]}" fmt --test "${alloy_file}"
      fail "alloy fmt --test ${alloy_file#stacks/}"
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
  for stack in "${STACKS[@]}"; do
    if "${HEALTH[@]}" "stacks/${stack}/compose.yaml"; then
      pass "${stack}: compose health dependencies"
    else
      fail "${stack}: compose health dependencies"
    fi
  done

  # The half no single file can answer: a SERVICES entry, or an
  # ABSENT_BINARIES claim, naming a service that exists in NO stack. Both
  # checks had to stop treating "absent from this compose file" as a defect
  # once a second stack existed, and this is where that catch went.
  if python3 scripts/check_compose_health.py --cross-stack; then
    pass "reloaded and claimed services all exist in some stack"
  else
    fail "reloaded and claimed services all exist in some stack"
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
for stack in "${STACKS[@]}"; do
  if ./scripts/check_loki_rules.sh --stack "${stack}" --skips-file "${LOKI_SKIPS}"; then
    :
  else
    FAILED=1
  fi
done
SKIPPED=$((SKIPPED + $(wc -l < "${LOKI_SKIPS}")))

# ---------------------------------------------------------------------------
head_ "Grafana dashboards"
# ---------------------------------------------------------------------------
if have python3; then
  for stack in "${STACKS[@]}"; do
    if python3 scripts/check_dashboards.py --stack "${stack}"; then
      pass "${stack}: dashboard JSON and datasource references"
    else
      fail "${stack}: dashboard JSON and datasource references"
    fi
  done

  # A panel query that does not parse shows as an empty panel, not an error, so
  # nothing about a broken dashboard is loud. This was CI-only until #175.
  #
  # --emit-promql deliberately fails on a stack with no dashboards: its output
  # is the proof the queries parse, so emitting an empty file would pass
  # promtool over nothing (#68). "This stack ships none" is knowable here, so
  # the guard is here, and it is reported rather than skipped — a skip means
  # "could not check", and this checked and found nothing to check.
  if ((${#PROMTOOL[@]})); then
    for stack in "${STACKS[@]}"; do
      if ! compgen -G "stacks/${stack}/grafana/dashboards/*.json" >/dev/null; then
        pass "${stack}: no dashboards — no panel queries to parse"
        continue
      fi
      # Inside the repository, not /tmp: PROMTOOL may be a docker run that
      # bind-mounts REPO_ROOT and nothing else, so a path outside it does not
      # exist on the other side of the container boundary.
      DASH_EXPRS="$(mktemp "${REPO_ROOT}/.dashboard-exprs-XXXXXX.yaml")"
      # mktemp makes it 0600. When PROMTOOL is the docker fallback the reader
      # is the image's own unprivileged user, not this one, and an unreadable
      # file fails as "permission denied" — which looks exactly like a broken
      # query and is not one.
      chmod 0644 "${DASH_EXPRS}"
      if python3 scripts/check_dashboards.py --stack "${stack}" --emit-promql > "${DASH_EXPRS}" \
         && "${PROMTOOL[@]}" check rules "${DASH_EXPRS#"${REPO_ROOT}/"}" >/dev/null 2>&1; then
        pass "${stack}: dashboard panel queries parse as PromQL"
      else
        "${PROMTOOL[@]}" check rules "${DASH_EXPRS#"${REPO_ROOT}/"}" || true
        fail "${stack}: dashboard panel queries parse as PromQL"
      fi
      rm -f "${DASH_EXPRS}"; DASH_EXPRS=""
    done
  else
    skip "no promtool binary and no docker daemon — panel queries not parsed"
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
elif ! stack_running; then
  skip "no stack is running here — this is not a deployment host"
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

# Both of these were CI-only until #175, and CI is the one place you cannot
# consult before pushing. The SOPS assert is the sharper of the two: a file that
# is not encrypted is a committed plaintext secret, and a plaintext secret that
# reaches the remote has to be purged from history rather than reverted.
#
# One implementation each, shared with the workflow. The tracked-artefact check
# used to be written out twice — here and in ci.yml — and the two had already
# drifted, this copy missing a second stack's .env, a nested .rendered/ and a
# certificates/ anywhere but the repository root.
if ./scripts/check-sops-encrypted.sh; then
  pass "every SOPS file is encrypted"
else
  fail "every SOPS file is encrypted"
fi

if ./scripts/check-tracked-artefacts.sh >/dev/null; then
  pass "no rendered, decrypted, purge-secrets, certificate or backup files tracked"
else
  ./scripts/check-tracked-artefacts.sh || true
  fail "no rendered, decrypted, purge-secrets, certificate or backup files tracked"
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
