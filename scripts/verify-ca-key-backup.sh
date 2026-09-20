#!/usr/bin/env bash
#
# Prove that an offline copy of the estate CA's private key is a copy of THAT
# key — the one certificates/ca.pem carries and every client here trusts — and
# that it was the copy that was tested rather than the live key on this host.
#
# No decryption and no signing is involved, which is what makes this cheaper
# than verify-key-backup.sh: a private key determines its public half, so the
# public half of the backup either equals the public half of ca.pem or the file
# is not this key. Everything else the sibling checks still applies — a copy on
# the same disk is not a backup, a copy in a git tree is one `git add .` from
# public, and a copy in a synced folder is on someone else's disk — so those
# sections are the same as its, on purpose.
#
# Nothing here writes a secret to disk, to a temp file, or to the terminal. The
# only thing that leaves the backup file is its PUBLIC key, in DER, into
# sha256sum. No `set -x`, no here-string of the file, no editor.
#
# Usage: scripts/verify-ca-key-backup.sh <backup-key-file>
#        make certs-verify-backup KEY=/path/to/backup/ca-key.pem
#        scripts/verify-ca-key-backup.sh --self-test
#
# Environment (for the self-test and for a checkout that is not the CA host):
#   CA_CERT        the CA certificate (default certificates/ca.pem)
#   LIVE_KEY       the live CA key this refuses to test (default certificates/ca-key.pem)
#   TEXTFILE_DIR   passed through to ca-key-state.sh
#
# See docs/runbooks/back-up-the-ca-key.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA_CERT="${CA_CERT:-${REPO_ROOT}/certificates/ca.pem}"
LIVE_KEY="${LIVE_KEY:-${REPO_ROOT}/certificates/ca-key.pem}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# --self-test: the refusals and the proof, against a throwaway CA
# ---------------------------------------------------------------------------
# The real proof needs a copy on removable media and cannot run in CI; the
# logic can, against a CA minted into a temp directory and never against
# certificates/. Every case sets CA_CERT, LIVE_KEY and TEXTFILE_DIR, so nothing
# here touches the host's CA or its textfile directory.
if [[ "${1:-}" == "--self-test" ]]; then
  command -v openssl >/dev/null 2>&1 || die "openssl not found"
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT INT TERM
  mkdir -p "${T}/live" "${T}/media" "${T}/textfile"
  mint() {  # <dir>  — same shape as gen-certs.sh --ca, smaller key for speed
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
      -keyout "$1/ca-key.pem" -out "$1/ca.pem" -days 30 \
      -subj "/CN=self-test CA/O=self-test" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    chmod 600 "$1/ca-key.pem"
  }
  mint "${T}/live"
  cat "${T}/live/ca-key.pem" > "${T}/media/ca-key.pem"; chmod 600 "${T}/media/ca-key.pem"
  ln -s "${T}/live/ca-key.pem" "${T}/media/symlink.pem"
  ln "${T}/live/ca-key.pem" "${T}/live/hardlink.pem"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${T}/media/other-key.pem" 2>/dev/null
  printf 'not a key\n' > "${T}/media/notes.txt"

  fail=0
  run() {  # <backup>  → OUT, RC
    set +e
    OUT="$(CA_CERT="${T}/live/ca.pem" LIVE_KEY="${T}/live/ca-key.pem" TEXTFILE_DIR="${T}/textfile" \
           "${BASH_SOURCE[0]}" "$1" 2>&1)"
    RC=$?
    set -e
  }
  check() {  # <name> <expected rc> <expected substring>
    if [[ "${RC}" == "$2" && "${OUT}" == *"$3"* ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$1"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       exit %s, wanted %s; wanted output containing: %s\n' "$1" "${RC}" "$2" "$3"
      printf '%s\n' "${OUT}" | sed 's/^/       | /'
      fail=1
    fi
  }

  run "${T}/media/ca-key.pem";   check "a true copy is proved" 0 "ok"
  fp="$(CA_CERT="${T}/live/ca.pem" "${REPO_ROOT}/scripts/ca-key-state.sh" --fingerprint)"
  if grep -qE "^homelab_ca_key_backup_last_proof_timestamp_seconds\{ca=\"estate\",spki_sha256=\"${fp}\"\} [1-9][0-9]*$" "${T}/textfile/ca-key-backup.prom"; then
    printf '\033[0;32m  PASS\033[0m the proof is recorded against the key'"'"'s fingerprint\n'
  else
    printf '\033[0;31m  FAIL\033[0m the proof is recorded against the key'"'"'s fingerprint\n'
    sed 's/^/       | /' "${T}/textfile/ca-key-backup.prom" 2>/dev/null; fail=1
  fi
  run "${T}/media/symlink.pem";  check "a symlink to the live key is refused" 1 "that is the live key"
  run "${T}/live/hardlink.pem";  check "a hard link to the live key is refused" 1 "that is the live key"
  run "${T}/media/other-key.pem"; check "an unrelated key is refused" 1 "not this CA's key"
  run "${T}/media/notes.txt";    check "a file that is not a key is refused" 1 "not a readable PEM private key"

  # The re-mint: a new CA over the same path. The daily record must drop the
  # old fingerprint's proof and start the new one at 0 — the state ADR-0024
  # calls "never proved", said out loud rather than inherited.
  mint "${T}/live"
  OUT="$(CA_CERT="${T}/live/ca.pem" TEXTFILE_DIR="${T}/textfile" "${REPO_ROOT}/scripts/ca-key-state.sh" --record 2>&1)"; RC=$?
  fp2="$(CA_CERT="${T}/live/ca.pem" "${REPO_ROOT}/scripts/ca-key-state.sh" --fingerprint)"
  if [[ "${RC}" == 0 && "${OUT}" == *"re-minted"* ]] \
     && grep -qF "spki_sha256=\"${fp2}\"} 0" "${T}/textfile/ca-key-backup.prom" \
     && ! grep -qF "spki_sha256=\"${fp}\"" "${T}/textfile/ca-key-backup.prom"; then
    printf '\033[0;32m  PASS\033[0m a re-minted CA starts at 0 and the old key'"'"'s row is dropped\n'
  else
    printf '\033[0;31m  FAIL\033[0m a re-minted CA starts at 0 and the old key'"'"'s row is dropped\n'
    printf '%s\n' "${OUT}" | sed 's/^/       | /'; sed 's/^/       | /' "${T}/textfile/ca-key-backup.prom" 2>/dev/null; fail=1
  fi
  run "${T}/media/ca-key.pem";   check "the old copy is refused against the new CA" 1 "not this CA's key"

  # A host with no CA at all — a workstation, CI — is not a failure for the
  # daily record, or the timer would be red everywhere but one machine.
  OUT="$(CA_CERT="${T}/nowhere.pem" TEXTFILE_DIR="${T}/textfile" "${REPO_ROOT}/scripts/ca-key-state.sh" --record 2>&1)"; RC=$?
  check "--record without a CA warns and exits 0" 0 "nothing to record"
  exit "${fail}"
fi

BACKUP="${1:-}"
if [[ -z "${BACKUP}" ]]; then
  cat >&2 <<USAGE
usage: scripts/verify-ca-key-backup.sh <backup-key-file>
   or: make certs-verify-backup KEY=/path/to/backup/ca-key.pem

Checks that the private key in <backup-key-file> is the key behind
${CA_CERT#"${REPO_ROOT}"/}, without using it for anything.
Procedure: docs/runbooks/back-up-the-ca-key.md
USAGE
  exit 2
fi

command -v openssl >/dev/null 2>&1 || die "openssl not found"

[[ -s "${CA_CERT}" ]] || die "no CA certificate at ${CA_CERT}
There is nothing to verify a key against. This runs on the host that holds
the CA — see docs/runbooks/generate-certificates.md."
[[ -f "${BACKUP}" ]] || die "no such file: ${BACKUP}"
[[ -r "${BACKUP}" ]] || die "${BACKUP} is not readable by $(id -un)"

BACKUP_ABS="$(cd "$(dirname "${BACKUP}")" && pwd -P)/$(basename "${BACKUP}")"

# ---------------------------------------------------------------------------
# 1. It has to be a different file from the live key
# ---------------------------------------------------------------------------
# Verifying the original proves only that the original works, and it is the
# obvious way to try the command out. Device + inode rather than path, so a
# symlink or a hard link back to the original is caught too; -L dereferences,
# because without it a symlink reports its own inode and sails through.
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
copy on the mounted medium. See docs/runbooks/back-up-the-ca-key.md."
  fi
fi

# ---------------------------------------------------------------------------
# 2. It must not be somewhere that republishes it
# ---------------------------------------------------------------------------
# The same three checks as verify-key-backup.sh, for the same reasons. This
# tree is public and `.gitignore`'s `certificates/` rule is a path match: a copy
# named anything, anywhere else in the tree, is committable — and this key is
# one of the ones that was once committed and had to be purged from history.
if [[ "${BACKUP_ABS}" == "${REPO_ROOT}/"* ]]; then
  die "the backup is inside this repository:
  ${BACKUP_ABS}

This tree is published. Move it out before verifying it, and check that it was
never committed:  git log --all --oneline -- $(printf '%q' "${BACKUP_ABS#"${REPO_ROOT}/"}")"
fi

if backup_repo="$(env -u GIT_DIR -u GIT_WORK_TREE \
                    git -C "$(dirname "${BACKUP_ABS}")" \
                    rev-parse --show-toplevel 2>/dev/null)"; then
  warn "the backup is inside a git working tree:  ${backup_repo}"
  warn "if that repository has a remote, one 'git add .' publishes the private key."
  warn "check whether it is even ignored there:"
  warn "  git -C $(printf '%q' "${backup_repo}") check-ignore -v $(printf '%q' "${BACKUP_ABS}")"
fi

for pattern in Dropbox OneDrive 'Google Drive' Nextcloud ownCloud Syncthing iCloud 'Mobile Documents'; do
  shopt -s nocasematch
  if [[ "${BACKUP_ABS}" == *"${pattern}"* ]]; then
    warn "the path contains '${pattern}' — if that folder syncs to a third party,"
    warn "the private key is now wherever that service keeps it."
  fi
  shopt -u nocasematch
done

# ---------------------------------------------------------------------------
# 3. Is it a private key at all?
# ---------------------------------------------------------------------------
# Separated from the comparison below because the two have different fixes:
# a file that does not parse was copied wrong; a key that parses and does not
# match is the wrong key. `-passin pass:` so that an encrypted key — which this
# CA's is deliberately not — fails here instead of stopping at a prompt.
if ! openssl pkey -in "${BACKUP}" -passin pass: -noout 2>/dev/null; then
  die "${BACKUP_ABS}
is not a readable PEM private key.

gen-certs.sh writes the CA key as an unencrypted PKCS#8 file — one PEM block
whose header reads BEGIN PRIVATE KEY. A partial copy or a file with a
passphrase on it both fail here."
fi

# ---------------------------------------------------------------------------
# 4. The proof: the public half of the backup is the public half of ca.pem
# ---------------------------------------------------------------------------
# Both sides are DER SubjectPublicKeyInfo, hashed, so what is compared is the
# key and not a text encoding of it. `pkey`, not `rsa`, so an EC re-mint of the
# CA needs no change here. The only bytes that leave the backup file are its
# public key.
backup_fp="$(openssl pkey -in "${BACKUP}" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)"
ca_fp="$(CA_CERT="${CA_CERT}" "${REPO_ROOT}/scripts/ca-key-state.sh" --fingerprint)"

if [[ "${backup_fp}" != "${ca_fp}" ]]; then
  die "this is a valid private key, but not this CA's key.

  backup public key:    sha256 ${backup_fp}
  ${CA_CERT#"${REPO_ROOT}"/} public key:  sha256 ${ca_fp}

If the CA was re-minted (make certs ARGS='--ca --force') since this copy was
made, the copy is of the old key and cannot sign anything anyone trusts now:
back up the new key. Otherwise, find the right copy — a key that was never
this CA's has nothing to prove."
fi
info "public key sha256 ${ca_fp} — the backup is this CA's key"

# ---------------------------------------------------------------------------
# 5. Housekeeping notes on the copy itself
# ---------------------------------------------------------------------------
mode="$(stat -Lc '%a' "${BACKUP}" 2>/dev/null || stat -Lf '%Lp' "${BACKUP}" 2>/dev/null || true)"
if [[ -n "${mode}" && "${mode: -2}" != "00" ]]; then
  warn "mode ${mode} — group or other can read this copy:  chmod 600 $(printf '%q' "${BACKUP_ABS}")"
fi

# ---------------------------------------------------------------------------
# 6. Record the proof, against this key's fingerprint
# ---------------------------------------------------------------------------
# Before the ok line and allowed to be fatal, for the reason verify-key-backup.sh
# gives: an unrecorded proof is a job that ran and that nothing can see ran.
# CaKeyBackupUnproven reads what this writes.
CA_CERT="${CA_CERT}" "${REPO_ROOT}/scripts/ca-key-state.sh" --record --proved "${ca_fp}"

printf '\033[0;32mok\033[0m — %s is the private key behind %s\n' \
  "$(basename "${BACKUP}")" "${CA_CERT#"${REPO_ROOT}"/}"
printf '   Proven: this copy, on its own, is the key that signed every leaf this CA issued.\n'
printf '   Not proven: that where you keep it will still exist after a fire, a theft,\n'
printf '   or a lost medium. That part is your judgement.\n'
printf '   Not proven: that the list of devices trusting ca.pem is complete. That list\n'
printf '   is docs/runbooks/generate-certificates.md §4, and only you can check it.\n'
