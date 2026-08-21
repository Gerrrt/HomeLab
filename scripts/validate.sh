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

# Run a linter that does not need to be installed to be available.
#
# yamllint, markdownlint-cli2 and shellcheck were all reported as "not
# installed" on a host where CI runs them successfully every push — because CI
# invokes them through `pipx run` and `npx --yes`, and this script only probed
# for a globally installed binary and gave up. Two red CI runs were spent on
# defects that a local `make validate` could have caught and reported as passing
# instead.
#
# So: prefer the real binary, fall back to the same runner CI uses. The fallback
# needs a network on first use and caches afterwards; if it is unavailable the
# check still skips, but now it skips because the tool is genuinely unreachable
# rather than because it was not apt-installed.
runner_for() {
  local tool="$1"
  if have "${tool}"; then printf '%s' "${tool}"; return 0; fi
  case "${tool}" in
    yamllint)
      have pipx && printf 'pipx run %s' "${tool}" && return 0 ;;
    markdownlint-cli2)
      have npx && printf 'npx --yes %s' "${tool}" && return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
head_ "Compose"
# ---------------------------------------------------------------------------
if have docker; then
  # A .env is required for the ${VAR:?} guards; seeded by the same script CI
  # uses, so a variable added there cannot pass locally and fail in CI. Written
  # to a temp file rather than ${STACK}/.env so a local run never leaves an .env
  # sitting next to a real one.
  TMP_ENV="$(mktemp)"
  trap 'rm -f "${TMP_ENV}"' EXIT
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
if ((${#ALLOY[@]})); then
  if "${ALLOY[@]}" fmt --test "${STACK}/alloy/config.alloy" >/dev/null 2>&1; then
    pass "alloy fmt --test"
  else
    "${ALLOY[@]}" fmt --test "${STACK}/alloy/config.alloy"
    fail "alloy fmt --test"
  fi
else
  skip "no alloy binary and no docker daemon"
fi

# ---------------------------------------------------------------------------
head_ "Compose health dependencies"
# ---------------------------------------------------------------------------
if have python3; then
  if python3 scripts/check_compose_health.py; then
    pass "compose health dependencies"
  else
    fail "compose health dependencies"
  fi
else
  skip "python3 not installed"
fi

# ---------------------------------------------------------------------------
head_ "Loki rules"
# ---------------------------------------------------------------------------
if ./scripts/check_loki_rules.sh; then
  :
else
  FAILED=1
fi

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

# ---------------------------------------------------------------------------
head_ "YAML / Markdown / shell"
# ---------------------------------------------------------------------------
if YAMLLINT="$(runner_for yamllint)"; then
  # shellcheck disable=SC2086  # deliberately word-split: may be "pipx run yamllint"
  if $YAMLLINT . >/dev/null 2>&1; then pass "yamllint"; else $YAMLLINT .; fail "yamllint"; fi
else
  skip "yamllint unavailable (pip install yamllint, or install pipx)"
fi

if MDLINT="$(runner_for markdownlint-cli2)"; then
  # shellcheck disable=SC2086  # deliberately word-split: may be "npx --yes markdownlint-cli2"
  if $MDLINT >/dev/null 2>&1; then pass "markdownlint"; else $MDLINT; fail "markdownlint"; fi
else
  skip "markdownlint-cli2 unavailable (npm i -g markdownlint-cli2, or install npx)"
fi

if have shellcheck; then
  if shellcheck scripts/*.sh; then pass "shellcheck"; else fail "shellcheck"; fi
else
  skip "shellcheck not installed"
fi

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
head_ "Secrets"
# ---------------------------------------------------------------------------
# Both scans, matching CI exactly. Running only the working-tree scan locally
# would let `make validate` pass while CI fails on history, or vice versa.
if have gitleaks; then
  if gitleaks detect --no-git --no-banner --redact -c .gitleaks.toml >/dev/null 2>&1; then
    pass "gitleaks (working tree)"
  else
    gitleaks detect --no-git --no-banner --redact -c .gitleaks.toml
    fail "gitleaks (working tree)"
  fi

  if gitleaks detect --no-banner --redact -c .gitleaks.toml --log-opts="--all" >/dev/null 2>&1; then
    pass "gitleaks (full history)"
  else
    gitleaks detect --no-banner --redact -c .gitleaks.toml --log-opts="--all"
    fail "gitleaks (full history)"
  fi
else
  skip "gitleaks not installed"
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
