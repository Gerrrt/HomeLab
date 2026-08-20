#!/usr/bin/env bash
#
# Prove that a backup copy of the age private key can decrypt this stack's SOPS
# file — and that it decrypted because of *that* file rather than because the
# live key on this host was quietly picked up instead.
#
# The second half is the whole point. `SOPS_AGE_KEY_FILE=<backup> sops -d ...`
# typed by hand looks like a verification and is not one: sops consults
# SOPS_AGE_KEY and the default ~/.config/sops/age/keys.txt as well, so on the
# host that already holds the real key it prints the secrets whatever is in the
# file you named. Measured, not theorised — pointing that command at a freshly
# generated unrelated keypair with SOPS_AGE_KEY set exits 0 and prints every
# secret. A backup that has never been verified and a backup that has been
# verified wrongly are the same backup; only one of them feels safe.
#
# Nothing here writes a secret to disk, to a temp file, or to the terminal.
#
# Usage: scripts/verify-key-backup.sh <backup-key-file> [stack]
#        make secrets-verify-backup KEY=/path/to/backup/keys.txt
#
# See docs/runbooks/back-up-the-age-key.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP="${1:-}"
STACK="${2:-observability}"
SECRETS_FILE="${REPO_ROOT}/secrets/${STACK}.sops.yaml"
SOPS_CONFIG="${REPO_ROOT}/.sops.yaml"

# Where the *live* key is. Read before the decrypt below scrubs the environment,
# and only ever used to refuse to verify the original by mistake.
LIVE_KEY="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*"; }

if [[ -z "${BACKUP}" ]]; then
  cat >&2 <<EOF
usage: scripts/verify-key-backup.sh <backup-key-file> [stack]
   or: make secrets-verify-backup KEY=/path/to/backup/keys.txt

Checks that the age key in <backup-key-file> decrypts secrets/${STACK}.sops.yaml.
Procedure: docs/runbooks/back-up-the-age-key.md
EOF
  exit 2
fi

for tool in sops age-keygen; do
  command -v "${tool}" >/dev/null 2>&1 || die "${tool} not found.
  age:  https://github.com/FiloSottile/age/releases
  sops: https://github.com/getsops/sops/releases"
done

[[ -f "${SECRETS_FILE}" ]] || die "no encrypted secrets at ${SECRETS_FILE}
There is nothing to verify a key against. Run 'make secrets-init' first."
[[ -f "${BACKUP}" ]] || die "no such file: ${BACKUP}"
[[ -r "${BACKUP}" ]] || die "${BACKUP} is not readable by $(id -un)"

# Directory symlinks are resolved with `pwd -P`; the leaf is left alone so the
# stat comparison below is what catches a symlink pointing back at the live key.
BACKUP_ABS="$(cd "$(dirname "${BACKUP}")" && pwd -P)/$(basename "${BACKUP}")"

# ---------------------------------------------------------------------------
# 1. It has to be a different file from the live key
# ---------------------------------------------------------------------------
# Verifying the original proves nothing at all, and it is an easy mistake: the
# obvious way to test the command before pointing it at the real backup is to
# point it at the key you already have. Device + inode rather than path, so a
# symlink or a hard link back to the original is caught too.
# -L dereferences: without it GNU stat reports the symlink's own inode, and a
# symlink pointing straight back at the live key sails through as a "backup".
file_id() { stat -Lc '%d:%i' "$1" 2>/dev/null || stat -Lf '%d:%i' "$1" 2>/dev/null; }

if [[ -e "${LIVE_KEY}" ]]; then
  backup_id="$(file_id "${BACKUP}" || true)"
  live_id="$(file_id "${LIVE_KEY}" || true)"
  live_abs="$(cd "$(dirname "${LIVE_KEY}")" && pwd -P)/$(basename "${LIVE_KEY}")"

  if { [[ -n "${backup_id}" ]] && [[ "${backup_id}" == "${live_id}" ]]; } \
     || [[ "${BACKUP_ABS}" == "${live_abs}" ]]; then
    die "that is the live key on this host, not a backup of it:
  ${BACKUP_ABS}

A copy that lives on the same disk as the original is not a backup, and
verifying the original proves only that the original works. Point this at the
copy — a mounted USB stick, or a file you pasted back out of your password
manager. See docs/runbooks/back-up-the-age-key.md."
  fi
fi

# ---------------------------------------------------------------------------
# 2. It must not be somewhere that republishes it
# ---------------------------------------------------------------------------
# Issue #11's third checkbox. The repo case is a hard failure because this tree
# is a public repository and .gitignore's `keys.txt` rule is a filename match,
# not a guarantee — a copy named anything else is committable.
if [[ "${BACKUP_ABS}" == "${REPO_ROOT}/"* ]]; then
  die "the backup is inside this repository:
  ${BACKUP_ABS}

This tree is published. Move it out before verifying it, and check that it was
never committed:  git log --all --oneline -- $(printf '%q' "${BACKUP_ABS#"${REPO_ROOT}/"}")"
fi

# Advice, not a verdict: the script cannot know what a directory syncs to, and
# for some people a synced vault *is* the durable copy. Saying so out loud is
# the useful part.
for pattern in Dropbox OneDrive 'Google Drive' Nextcloud ownCloud Syncthing iCloud 'Mobile Documents'; do
  shopt -s nocasematch
  if [[ "${BACKUP_ABS}" == *"${pattern}"* ]]; then
    warn "the path contains '${pattern}' — if that folder syncs to a third party,"
    warn "the private key is now wherever that service keeps it."
  fi
  shopt -u nocasematch
done

# ---------------------------------------------------------------------------
# 3. Is it even the right key? (offline, no ciphertext involved)
# ---------------------------------------------------------------------------
# A decrypt failure alone cannot distinguish "this is not the key the file was
# encrypted to" from "this file is not an age identity at all", and those have
# completely different fixes.
if ! PUBLIC_KEYS="$(age-keygen -y "${BACKUP}" 2>&1)"; then
  die "${BACKUP_ABS}
is not a readable age identity file.

age-keygen said: ${PUBLIC_KEYS}

An age key file holds a line beginning AGE-SECRET-KEY-1. If you transcribed
this from paper, check for a truncated or wrapped line."
fi

matched=""
while IFS= read -r pub; do
  [[ -n "${pub}" ]] || continue
  if grep -qF "${pub}" "${SOPS_CONFIG}"; then
    matched="${pub}"
    break
  fi
done <<< "${PUBLIC_KEYS}"

if [[ -z "${matched}" ]]; then
  die "this is a valid age key, but not one the secrets are encrypted to.

  backup holds:  $(printf '%s' "${PUBLIC_KEYS}" | tr '\n' ' ')
  .sops.yaml wants: $(grep -oE 'age1[a-z0-9]+' "${SOPS_CONFIG}" | tr '\n' ' ')

A freshly generated keypair looks exactly like this. If you meant to add a new
recipient rather than restore an old one, that is 'sops updatekeys' — see
secrets/README.md."
fi
info "recipient matches .sops.yaml: ${matched}"

# ---------------------------------------------------------------------------
# 4. The real test: decrypt with nothing but the backup available
# ---------------------------------------------------------------------------
# Every element of the env line below is load-bearing:
#
#   -u SOPS_AGE_KEY        takes precedence over SOPS_AGE_KEY_FILE, so an
#                          inherited value would make any file "pass"
#   HOME / XDG_CONFIG_HOME pointed at an empty directory, so that if sops falls
#                          back to the default ~/.config/sops/age/keys.txt it
#                          finds nothing and fails — rather than decrypting with
#                          the live key and reporting the backup good
#
# Remove any one of them and this script becomes the hand-typed command it
# exists to replace.
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "${TMP_HOME}"' EXIT INT TERM

info "decrypting $(basename "${SECRETS_FILE}") with the backup key only"

# Plaintext is captured into a shell variable and never redirected anywhere. A
# here-string is deliberately not used to search it further down: bash may
# implement one as a temp file, which is exactly what this is avoiding.
if ! plaintext="$(env -u SOPS_AGE_KEY -u XDG_CONFIG_HOME \
                     HOME="${TMP_HOME}" SOPS_AGE_KEY_FILE="${BACKUP}" \
                     sops --decrypt "${SECRETS_FILE}" 2>"${TMP_HOME}/sops.err")"; then
  die "decryption failed with this key.

sops said:
$(sed 's/^/  /' "${TMP_HOME}/sops.err")

The public half matched .sops.yaml, so the secret half is damaged or truncated —
the usual cause is a partial copy or a mis-transcribed line."
fi

# ---------------------------------------------------------------------------
# 5. Do not trust the exit status alone
# ---------------------------------------------------------------------------
# Same reasoning as bootstrap.sh: a zero exit and an empty or partial result are
# indistinguishable from the caller's side, and this is the one check standing
# between a lost key and a lost network.
REQUIRED=(
  GRAFANA_ADMIN_PASSWORD
  ALERTMANAGER_WEBHOOK_URL
  SNMP_COMMUNITY_PFSENSE
  SNMP_COMMUNITY_APC
  SNMP_COMMUNITY_MOKERLINK
  SNMP_COMMUNITY_ILO
)
found=0
missing=()
for var in "${REQUIRED[@]}"; do
  # Pure bash matching: no grep, no process substitution, nothing that could put
  # a decrypted value into another process's argv or into a file.
  if [[ $'\n'"${plaintext}" == *$'\n'"${var}":* ]]; then
    found=$((found + 1))
  else
    missing+=("${var}")
  fi
done
unset plaintext

if ((${#missing[@]} > 0)); then
  die "the key decrypted the file, but the result is missing keys that
render-config.sh requires: ${missing[*]}

The backup is fine; the encrypted file is incomplete. Fix it with
'make secrets-edit' on a working host, then verify the backup again."
fi

# ---------------------------------------------------------------------------
# 6. Housekeeping notes on the copy itself
# ---------------------------------------------------------------------------
mode="$(stat -Lc '%a' "${BACKUP}" 2>/dev/null || stat -Lf '%Lp' "${BACKUP}" 2>/dev/null || true)"
if [[ -n "${mode}" && "${mode: -2}" != "00" ]]; then
  warn "mode ${mode} — group or other can read this copy:  chmod 600 $(printf '%q' "${BACKUP_ABS}")"
fi

printf '\033[0;32mok\033[0m — %s decrypts secrets/%s.sops.yaml (%d/%d keys)\n' \
  "$(basename "${BACKUP}")" "${STACK}" "${found}" "${#REQUIRED[@]}"
printf '   Proven: this key, on its own, recovers every secret in the repo.\n'
printf '   Not proven: that where you keep it will still exist after a fire,\n'
printf '   a theft, or a forgotten password. That part is your judgement.\n'
