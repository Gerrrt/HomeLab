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
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() { printf '\033[0;33m  SKIP\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }
have_docker() { have docker && docker info >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
head_ "Compose"
# ---------------------------------------------------------------------------
if have docker; then
  # A .env is required for the ${VAR:?} guards; use the example values plus
  # throwaway secrets so validation does not depend on a decryption key.
  TMP_ENV="$(mktemp)"
  trap 'rm -f "${TMP_ENV}"' EXIT
  cat "${STACK}/.env.example" > "${TMP_ENV}"
  {
    echo "GRAFANA_ADMIN_PASSWORD=validation-only"
    # RENDER_UID/GID come from the deploying user via render-config.sh and are
    # host-specific, so they are deliberately not in .env.example. Any value
    # validates — this only needs to satisfy the ${VAR:?} guards.
    echo "RENDER_UID=65534"
    echo "RENDER_GID=65534"
  } >> "${TMP_ENV}"
  if docker compose --env-file "${TMP_ENV}" -f "${STACK}/compose.yaml" config -q 2>/dev/null; then
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
if have yamllint; then
  if yamllint . >/dev/null 2>&1; then pass "yamllint"; else yamllint .; fail "yamllint"; fi
else
  skip "yamllint not installed (pip install yamllint)"
fi

if have markdownlint-cli2; then
  if markdownlint-cli2 >/dev/null 2>&1; then pass "markdownlint"; else markdownlint-cli2; fail "markdownlint"; fi
else
  skip "markdownlint-cli2 not installed (npm i -g markdownlint-cli2)"
fi

if have shellcheck; then
  if shellcheck scripts/*.sh; then pass "shellcheck"; else fail "shellcheck"; fi
else
  skip "shellcheck not installed"
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
if git ls-files --error-unmatch "${STACK}/.env" >/dev/null 2>&1 \
   || git ls-files "${STACK}/snmp-exporter/.rendered" | grep -q . \
   || git ls-files | grep -q '\.purge-secrets\.txt'; then
  fail "a rendered, decrypted or purge-secrets file is tracked by git"
else
  pass "no rendered, decrypted or purge-secrets files tracked"
fi

printf '\n'
if ((FAILED)); then
  printf '\033[0;31mvalidation failed\033[0m\n'; exit 1
fi
printf '\033[0;32mall checks passed\033[0m\n'
