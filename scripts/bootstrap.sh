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
# "The file exists" is not the same as "the secrets are set up". An earlier
# version of this script redirected sops' stdout into this path, and shell
# redirection creates the file before the command runs — so a failed encrypt
# left a 0-byte file behind. Treating that as "already done" made the script
# skip creation silently, and the next `make secrets-edit` failed with the
# unhelpful "sops metadata not found".
#
# Three distinct states, three different answers.
if [[ -f "${SECRETS_FILE}" ]] && grep -q '^sops:' "${SECRETS_FILE}" 2>/dev/null; then
  info "$(basename "${SECRETS_FILE}") already exists and is encrypted — leaving it alone"

elif [[ -s "${SECRETS_FILE}" ]]; then
  # Non-empty but not SOPS-encrypted. Never delete this: it could be real
  # credentials someone wrote by hand and has not encrypted yet.
  die "${SECRETS_FILE}
exists but is not SOPS-encrypted.

If it holds real values you want to keep, encrypt it in place:
  sops --encrypt --in-place ${SECRETS_FILE}

If it is junk from a failed run, remove it and re-run:
  rm ${SECRETS_FILE} && make secrets-init"

else
  # Absent, or an empty file left by a failed run. An empty file carries no
  # data, so removing it is safe.
  if [[ -e "${SECRETS_FILE}" ]]; then
    warn "removing empty $(basename "${SECRETS_FILE}") left by a previous failed run"
    rm -f "${SECRETS_FILE}"
  fi

  info "creating $(basename "${SECRETS_FILE}") from the template"

  # Copy to the destination name FIRST, then encrypt in place.
  #
  # SOPS chooses a creation_rule by matching path_regex against the *input*
  # path. Encrypting the template directly — `sops -e observability.example.yaml
  # > observability.sops.yaml` — makes SOPS test the rule against the example
  # filename, which does not end in .sops.yaml, so no rule matches and it exits
  # with "no matching creation rules found". The output name is never consulted.
  cp "${EXAMPLE_FILE}" "${SECRETS_FILE}"

  # From here until encryption is verified, the file is PLAINTEXT sitting at a
  # path that is meant to be committed and whose name says "encrypted". It is
  # deliberately not gitignored, so anything that leaves it behind is a leak
  # waiting to be committed.
  #
  # The trap covers every exit, not just the two failures checked below: a
  # chmod failure under `set -e`, a Ctrl-C mid-encrypt, a SIGTERM. Cleared only
  # once the sops metadata block is confirmed present.
  trap 'rm -f "${SECRETS_FILE}"' EXIT INT TERM

  chmod 600 "${SECRETS_FILE}"

  if ! sops --encrypt --in-place "${SECRETS_FILE}"; then
    die "encryption failed — the partial file has been removed rather than
leave plaintext credentials at a path that looks encrypted.

Check that .sops.yaml lists a valid age recipient:
  grep -A2 creation_rules ${SOPS_CONFIG}"
  fi

  # Do not trust the exit status alone. CI catches a plaintext secrets file, but
  # only after it has been pushed.
  if ! grep -q '^sops:' "${SECRETS_FILE}"; then
    die "sops reported success but produced no encrypted output — file removed"
  fi

  # Confirmed encrypted: the file may now survive.
  trap - EXIT INT TERM

  warn "It still contains the placeholder values. Edit it now:"
  warn "  make secrets-edit"
fi

cat <<EOF

Next steps:
  1. make secrets-edit     # replace every change-me value
  2. make validate         # confirm the configs are sound
  3. make up               # render config and start the stack
EOF
