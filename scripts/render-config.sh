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

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

[[ -d "${STACK_DIR}" ]] || die "no such stack: ${STACK_DIR}"

command -v sops >/dev/null 2>&1 \
  || die "sops not found. Install it: https://github.com/getsops/sops/releases"

if [[ ! -f "${SECRETS_FILE}" ]]; then
  die "${SECRETS_FILE} does not exist. Run 'make secrets-init' first."
fi

# ---------------------------------------------------------------------------
# Decrypt. Keep the plaintext in a variable, never in a file.
# ---------------------------------------------------------------------------
info "decrypting $(basename "${SECRETS_FILE}")"
PLAINTEXT="$(sops --decrypt "${SECRETS_FILE}")" \
  || die "decryption failed. Is ~/.config/sops/age/keys.txt present?"

# Turn "key: value" YAML into shell exports. Values are single-quoted, with
# embedded single quotes escaped, so passwords containing shell metacharacters
# survive intact.
while IFS= read -r line; do
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
  [[ "${line}" =~ ^---$ ]] && continue
  key="${line%%:*}"
  value="${line#*: }"
  [[ "${key}" == "${line}" ]] && continue
  # strip surrounding quotes if the YAML had them
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf -v "${key}" '%s' "${value}"
  export "${key?}"
done <<< "${PLAINTEXT}"

REQUIRED=(
  GRAFANA_ADMIN_PASSWORD
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

  snmp_content="$(cat "${SNMP_SRC}")"
  for var in SNMP_COMMUNITY_PFSENSE SNMP_COMMUNITY_APC \
             SNMP_COMMUNITY_MOKERLINK SNMP_COMMUNITY_ILO; do
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
COMPOSE_VARS=(GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD)
ENV_FILE="${STACK_DIR}/.env"
info "writing $(basename "${STACK_DIR}")/.env"

{
  echo "# Generated by scripts/render-config.sh — do not edit, do not commit."
  echo "# Non-sensitive defaults come from .env.example; secrets from SOPS."
  if [[ -f "${STACK_DIR}/.env.example" ]]; then
    grep -vE '^\s*#|^\s*$' "${STACK_DIR}/.env.example" || true
  fi
  for var in "${COMPOSE_VARS[@]}"; do
    [[ -n "${!var:-}" ]] && printf '%s=%s\n' "${var}" "${!var}"
  done
} > "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

info "done — ${STACK} is ready to start"
