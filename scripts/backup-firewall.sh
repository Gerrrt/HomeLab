#!/usr/bin/env bash
#
# Pull morpheus's pfSense configuration and encrypt it at rest.
#
# morpheus routes every VLAN in this lab. If it dies, the house has no DHCP, no
# DNS and no internet until it is rebuilt — and until this script existed there
# was no config export, no runbook and no spare. That is the single largest
# unmitigated failure in the estate; see docs/runbooks/restore-the-firewall.md.
#
# WHY THE OUTPUT IS NOT COMMITTED
#
# Every other secret here lives in the repository, SOPS-encrypted, because
# `git log -p` then shows which credential rotated and when. A firewall config
# is different in kind. config.xml carries the WAN address, the full rule set,
# user password hashes and any certificate material — and docs/security.md
# states plainly that rule bodies and the WAN address are deliberately not
# published. Committing them, even encrypted, to a public repository means one
# age-key compromise hands over the complete blueprint of the network. This
# repository has already had one credential exposure; that is enough.
#
# So backups/ is gitignored, `make validate` asserts nothing under it is
# tracked, and CI asserts the same. The repository holds the tooling. The
# artifact goes to the backup target and offsite.
#
# Usage:
#   scripts/backup-firewall.sh                    pull, encrypt, verify
#   scripts/backup-firewall.sh --verify-only      re-verify the newest backup
#   scripts/backup-firewall.sh --list             show what exists
#
# Environment:
#   FW_HOST   default morpheus.matrix.elysium (falls back to 10.0.99.1)
#   FW_USER   default root
#   FW_PATH   default /cf/conf/config.xml
set -euo pipefail

FW_HOST="${FW_HOST:-10.0.99.1}"
FW_USER="${FW_USER:-root}"
FW_PATH="${FW_PATH:-/cf/conf/config.xml}"
OUT_DIR="backups/firewall"
SOPS_POLICY=".sops.yaml"

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;34m--\033[0m %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { red "missing dependency: $1"; exit 1; }; }

# The age recipient is read from .sops.yaml rather than duplicated here. One
# source of truth for the key; rotating it in .sops.yaml rotates it here too.
recipient() {
  grep -oE 'age1[0-9a-z]{50,}' "$SOPS_POLICY" | head -1
}

list_backups() {
  if [[ -d $OUT_DIR ]] && compgen -G "$OUT_DIR/*.sops.yaml" >/dev/null; then
    ls -1t "$OUT_DIR"/*.sops.yaml
  fi
}

newest() { list_backups | head -1; }

# An untested backup is not a backup. Decrypt what we just wrote, in a clean
# environment, and confirm it is a pfSense config rather than an empty file or
# an error page.
verify() {
  local f="$1" plain
  [[ -f $f ]] || { red "no such backup: $f"; exit 1; }
  plain="$(env -i "PATH=$PATH" "HOME=$HOME" sops --decrypt --input-type binary --output-type binary "$f" 2>/dev/null)" \
    || { red "FAILED to decrypt $f"; exit 1; }
  grep -q '<pfsense>' <<<"$plain" \
    || { red "decrypted $f but it does not look like a pfSense config"; exit 1; }
  local rules ver
  rules=$(grep -c '<rule>' <<<"$plain" || true)
  ver=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' <<<"$plain" | head -1)
  green "verified $(basename "$f") — config version ${ver:-unknown}, ${rules} firewall rules"
}

case "${1:-}" in
  --list)
    list_backups || true
    exit 0 ;;
  --verify-only)
    need sops
    f="$(newest)"; [[ -n $f ]] || { red "no backups in $OUT_DIR"; exit 1; }
    verify "$f"; exit 0 ;;
  "") ;;
  *) red "unknown argument: $1"; exit 1 ;;
esac

need ssh
need sops

AGE_RECIPIENT="$(recipient)"
[[ -n $AGE_RECIPIENT ]] || { red "no age recipient found in $SOPS_POLICY"; exit 1; }

mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$OUT_DIR/config-$STAMP.sops.yaml"

info "pulling $FW_PATH from $FW_USER@$FW_HOST"

# Piped straight into sops — the plaintext config never touches this disk.
# BatchMode so a missing key fails loudly instead of hanging on a prompt.
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$FW_USER@$FW_HOST" "cat $FW_PATH" \
     | sops --encrypt --age "$AGE_RECIPIENT" --input-type binary --output-type yaml /dev/stdin \
     > "$DEST"; then
  rm -f "$DEST"
  red "pull or encrypt failed — nothing written"
  red "check: SSH enabled on pfSense, key authorised for $FW_USER, and sops on PATH"
  exit 1
fi

# A zero-byte or tiny result means the pipeline succeeded while producing
# nothing useful — which is exactly the failure a backup script must not
# report as success.
if [[ $(wc -c < "$DEST") -lt 512 ]]; then
  rm -f "$DEST"
  red "result was implausibly small — nothing written"
  exit 1
fi

verify "$DEST"
green "wrote $DEST"
printf '\n'
info "This is on the same host as everything else it protects."
info "Copy it to the backup target and offsite — see docs/runbooks/restore-the-firewall.md"
