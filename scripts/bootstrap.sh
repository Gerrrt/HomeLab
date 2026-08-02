#!/usr/bin/env bash
#
# One-time setup on a new deployment host: generate an age keypair, register its
# public half in .sops.yaml, and create the encrypted secrets file.
#
# Safe to re-run — it refuses to overwrite an existing key or secrets file.
#
# Usage: scripts/bootstrap.sh [stack]      (default: observability)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:-observability}"
KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
SECRETS_FILE="${REPO_ROOT}/secrets/${STACK}.sops.yaml"
EXAMPLE_FILE="${REPO_ROOT}/secrets/${STACK}.example.yaml"
SOPS_CONFIG="${REPO_ROOT}/.sops.yaml"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*"; }

for tool in age-keygen sops; do
  command -v "${tool}" >/dev/null 2>&1 || die "${tool} not found.
  age:  https://github.com/FiloSottile/age/releases
  sops: https://github.com/getsops/sops/releases"
done

[[ -f "${EXAMPLE_FILE}" ]] || die "missing template: ${EXAMPLE_FILE}"

# ---------------------------------------------------------------------------
# 1. age keypair
# ---------------------------------------------------------------------------
if [[ -f "${KEY_FILE}" ]]; then
  info "reusing existing key at ${KEY_FILE}"
else
  info "generating age keypair at ${KEY_FILE}"
  mkdir -p "$(dirname "${KEY_FILE}")"
  age-keygen -o "${KEY_FILE}" 2>/dev/null
  chmod 600 "${KEY_FILE}"
  warn "BACK THIS FILE UP OFF THIS MACHINE. Without it the encrypted secrets"
  warn "in this repository are unrecoverable."
fi

PUBLIC_KEY="$(grep -oE 'age1[a-z0-9]+' "${KEY_FILE}" | head -n1)"
[[ -n "${PUBLIC_KEY}" ]] || die "could not read a public key out of ${KEY_FILE}"
info "public key: ${PUBLIC_KEY}"

# ---------------------------------------------------------------------------
# 2. register it in .sops.yaml
# ---------------------------------------------------------------------------
if grep -q "REPLACE_WITH_YOUR_AGE_PUBLIC_KEY" "${SOPS_CONFIG}"; then
  info "writing public key into .sops.yaml"
  sed -i.bak "s|REPLACE_WITH_YOUR_AGE_PUBLIC_KEY|${PUBLIC_KEY}|" "${SOPS_CONFIG}"
  rm -f "${SOPS_CONFIG}.bak"
elif grep -q "${PUBLIC_KEY}" "${SOPS_CONFIG}"; then
  info ".sops.yaml already lists this key"
else
  warn ".sops.yaml lists a different age recipient."
  warn "Add this key as an additional recipient by hand, then run:"
  warn "  sops updatekeys ${SECRETS_FILE}"
fi

# ---------------------------------------------------------------------------
# 3. encrypted secrets file
# ---------------------------------------------------------------------------
if [[ -f "${SECRETS_FILE}" ]]; then
  info "$(basename "${SECRETS_FILE}") already exists — leaving it alone"
else
  info "creating $(basename "${SECRETS_FILE}") from the template"

  # Copy to the destination name FIRST, then encrypt in place.
  #
  # SOPS chooses a creation_rule by matching path_regex against the *input*
  # path. Encrypting the template directly — `sops -e observability.example.yaml
  # > observability.sops.yaml` — makes SOPS test the rule against the example
  # filename, which does not end in .sops.yaml, so no rule matches and it exits
  # with "no matching creation rules found". The output name is never consulted.
  cp "${EXAMPLE_FILE}" "${SECRETS_FILE}"
  chmod 600 "${SECRETS_FILE}"

  if ! sops --encrypt --in-place "${SECRETS_FILE}"; then
    rm -f "${SECRETS_FILE}"
    die "encryption failed — removed the partial file rather than leave
plaintext credentials sitting at a path that looks encrypted.

Check that .sops.yaml lists a valid age recipient:
  grep -A2 creation_rules ${SOPS_CONFIG}"
  fi

  # A plaintext file at this path would be committed as if it were encrypted,
  # and CI only catches that after the push. Verify before claiming success.
  if ! grep -q '^sops:' "${SECRETS_FILE}"; then
    rm -f "${SECRETS_FILE}"
    die "sops reported success but produced no encrypted output — file removed"
  fi

  warn "It still contains the placeholder values. Edit it now:"
  warn "  make secrets-edit"
fi

cat <<EOF

Next steps:
  1. make secrets-edit     # replace every change-me value
  2. make validate         # confirm the configs are sound
  3. make up               # render config and start the stack
EOF
