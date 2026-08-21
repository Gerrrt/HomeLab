#!/usr/bin/env bash
#
# Decrypt secrets and render the config files that cannot take environment
# variables at runtime.
#
# snmp_exporter reads its config once at startup and does no variable
# expansion, so the community strings have to be substituted into a real file.
# That file is written to a gitignored .rendered/ directory and is the only
# thing the container mounts — the tracked snmp.yaml keeps its ${PLACEHOLDERS}.
#
# Usage: scripts/render-config.sh [stack]      (default: observability)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:-observability}"
STACK_DIR="${REPO_ROOT}/stacks/${STACK}"
SECRETS_FILE="${REPO_ROOT}/secrets/${STACK}.sops.yaml"

# shellcheck source=secrets-env.sh
source "${REPO_ROOT}/scripts/secrets-env.sh"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

[[ -d "${STACK_DIR}" ]] || die "no such stack: ${STACK_DIR}"

# ---------------------------------------------------------------------------
# Decrypt. Keep the plaintext in a variable, never in a file.
#
# The decrypt-and-parse lives in scripts/secrets-env.sh because snmp-verify.sh
# needs the same values, and two copies of a hand-rolled YAML parser will
# eventually disagree about some edge case — at which point verification passes
# for a string that this script renders differently. Sourcing also drops the
# `export` this loop used to do: the secrets are read below via ${!var} in this
# process, and exporting them handed every child (mkdir, cat, grep, chmod, id)
# a copy of all four communities for no reason.
# ---------------------------------------------------------------------------
info "decrypting $(basename "${SECRETS_FILE}")"
load_secrets "${STACK}"

REQUIRED=(
  GRAFANA_ADMIN_PASSWORD
  GRAFANA_RENDERER_TOKEN
  ALERTMANAGER_WEBHOOK_URL
  SNMP_COMMUNITY_PFSENSE
  SNMP_COMMUNITY_APC
  SNMP_COMMUNITY_MOKERLINK
  SNMP_COMMUNITY_ILO
)
missing=()
for var in "${REQUIRED[@]}"; do
  [[ -n "${!var:-}" ]] || missing+=("${var}")
done
((${#missing[@]} == 0)) || die "missing keys in ${SECRETS_FILE}: ${missing[*]}"

# ---------------------------------------------------------------------------
# Render snmp.yaml
# ---------------------------------------------------------------------------
SNMP_SRC="${STACK_DIR}/snmp-exporter/snmp.yaml"
SNMP_OUT_DIR="${STACK_DIR}/snmp-exporter/.rendered"
if [[ -f "${SNMP_SRC}" ]]; then
  info "rendering snmp.yaml"
  mkdir -p "${SNMP_OUT_DIR}"
  chmod 700 "${SNMP_OUT_DIR}"

  # Substitution is done with bash parameter expansion rather than envsubst or
  # sed. envsubst lives in gettext-base, which is not guaranteed on a minimal
  # server install, and sed would mangle any community string containing / & or
  # a backslash. This also touches only the four SNMP_COMMUNITY_* names, so no
  # other ${...} sequence in 14k lines of OID definitions can be affected.
  #
  # bash 5.2 enables patsub_replacement by default, which makes an unescaped '&'
  # in the replacement expand to the matched text — so a community string
  # containing '&' would silently render as the placeholder it was meant to
  # replace. Disabling it makes the replacement literal. The redirect keeps this
  # a no-op on bash < 5.2, where the option does not exist.
  shopt -u patsub_replacement 2>/dev/null || true

  # The substitution list is derived from REQUIRED rather than repeated, so
  # adding a device means editing one list instead of two that silently drift.
  # The prefix filter is what makes that safe: a REQUIRED entry that is not an
  # SNMP community has no ${...} placeholder in snmp.yaml, so substituting it
  # is a no-op. And a name in REQUIRED whose placeholder is misspelled in
  # snmp.yaml is still caught by the independent grep below.
  snmp_content="$(cat "${SNMP_SRC}")"
  for var in "${REQUIRED[@]}"; do
    [[ "${var}" == SNMP_COMMUNITY_* ]] || continue
    snmp_content="${snmp_content//\$\{${var}\}/${!var}}"
  done

  umask 077
  printf '%s\n' "${snmp_content}" > "${SNMP_OUT_DIR}/snmp.yaml"
  unset snmp_content
  chmod 600 "${SNMP_OUT_DIR}/snmp.yaml"

  # shellcheck disable=SC2016  # matching the literal text "${SNMP_COMMUNITY..."
  if grep -q '\${SNMP_COMMUNITY' "${SNMP_OUT_DIR}/snmp.yaml"; then
    die "unsubstituted placeholders remain in the rendered snmp.yaml"
  fi
fi

# ---------------------------------------------------------------------------
# Render the Alertmanager webhook URL
#
# Alertmanager does not expand environment variables in its config. `url_file`
# is the supported mechanism, so the URL is written to a file that compose
# mounts read-only.
# ---------------------------------------------------------------------------
AM_OUT_DIR="${STACK_DIR}/alertmanager/.rendered"
if [[ -f "${STACK_DIR}/alertmanager/alertmanager.yaml" ]]; then
  info "rendering alertmanager webhook_url"
  mkdir -p "${AM_OUT_DIR}"
  printf '%s' "${ALERTMANAGER_WEBHOOK_URL}" > "${AM_OUT_DIR}/webhook_url"
  chmod 600 "${AM_OUT_DIR}/webhook_url"
fi

# ---------------------------------------------------------------------------
# Write .env for compose interpolation
#
# Only the values compose actually interpolates are written here. The SNMP
# communities go into the rendered snmp.yaml and the webhook URL into
# webhook_url; copying them into .env as well would spread the same secret
# across three files for no benefit.
# ---------------------------------------------------------------------------
COMPOSE_VARS=(GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD GRAFANA_RENDERER_TOKEN)
ENV_FILE="${STACK_DIR}/.env"
info "writing $(basename "${STACK_DIR}")/.env"

{
  echo "# Generated by scripts/render-config.sh — do not edit, do not commit."
  echo "# Non-sensitive defaults come from .env.example; secrets from SOPS."
  if [[ -f "${STACK_DIR}/.env.example" ]]; then
    grep -vE '^\s*#|^\s*$' "${STACK_DIR}/.env.example" || true
  fi

  # The rendered secrets above are 0600 and owned by whoever ran this script.
  # The two containers that mount them (alertmanager, snmp-exporter) must run as
  # that same UID or they cannot read their own config. Hardcoding 65534 here is
  # what left snmp-exporter crash-looping on "permission denied" for two weeks —
  # silently, because `restart: unless-stopped` retries forever and a container
  # that is always restarting looks alive.
  printf 'RENDER_UID=%s\n' "$(id -u)"
  printf 'RENDER_GID=%s\n' "$(id -g)"

  # Alloy labels every log and metric it produces with constants.hostname,
  # which inside a container is the CONTAINER ID unless compose sets one.
  # Left alone, `host` is a 12-character hex string that changes every time the
  # container is recreated — so it identifies nothing, and each redeploy mints a
  # new label value and therefore a new Loki stream. Observed: two values for
  # one machine after a single restart, and `sum by (host)` in the auth and
  # system alert rules grouping by something meaningless.
  #
  # Written here rather than hardcoded in compose.yaml so that config.alloy and
  # the compose file stay identical on every monitored host, which is the
  # property ADR-0003 leans on.
  printf 'ALLOY_HOSTNAME=%s\n' "$(hostname)"
  for var in "${COMPOSE_VARS[@]}"; do
    [[ -n "${!var:-}" ]] && printf '%s=%s\n' "${var}" "${!var}"
  done
} > "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

info "done — ${STACK} is ready to start"
