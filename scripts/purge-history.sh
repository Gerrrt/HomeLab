#!/usr/bin/env bash
#
# Remove committed secrets from the *entire* git history.
#
# Deleting a secret in a later commit does not remove it from history — every
# earlier commit still contains it, and `git show <sha>:<path>` will hand it
# straight back. This rewrites history so those blobs stop existing.
#
# What it removes:
#   * certificates/           — TLS private keys deleted in commit 647d90a but
#                               still reachable at 647d90a~1
#   * the shared SNMP community string, wherever it appears
#
# This rewrites every commit SHA. Read docs/runbooks/purge-git-history.md before
# running it, and rotate the credentials regardless — assume anything that was
# ever pushed to a public repository is compromised.
#
# Usage:
#   scripts/purge-history.sh --dry-run     # rewrite a scratch mirror, report
#   scripts/purge-history.sh --execute     # rewrite ./ for real

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---dry-run}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*"; }

# git resolves `git filter-repo` to a git-filter-repo executable on PATH, so
# this single check covers both installation styles.
if ! git filter-repo --help >/dev/null 2>&1; then
  die "git-filter-repo not found. Install it:
  pipx install git-filter-repo    (or: pip install git-filter-repo)
  https://github.com/newren/git-filter-repo"
fi

# The literal to scrub. Kept here rather than in a tracked replacements file so
# the string itself is not re-committed by the very script meant to remove it.
LEAKED_COMMUNITY='REDACTED-ROTATED-CREDENTIAL'

REPLACEMENTS="$(mktemp)"
PATHS_FILE="$(mktemp)"
trap 'rm -f "${REPLACEMENTS}" "${PATHS_FILE}"' EXIT

printf '%s==>REDACTED-ROTATED-CREDENTIAL\n' "${LEAKED_COMMUNITY}" > "${REPLACEMENTS}"
cat > "${PATHS_FILE}" <<'EOF'
certificates/
EOF

run_filter() {
  local target="$1"
  git -C "${target}" filter-repo --force \
    --invert-paths --paths-from-file "${PATHS_FILE}" \
    --replace-text "${REPLACEMENTS}"
}

report() {
  local target="$1"
  printf '\n\033[1mVerification\033[0m\n'
  if git -C "${target}" log --all --oneline -- certificates/ 2>/dev/null | grep -q .; then
    printf '\033[0;31m  FAIL\033[0m certificates/ still referenced in history\n'
  else
    printf '\033[0;32m  PASS\033[0m no commit touches certificates/\n'
  fi

  if git -C "${target}" grep -qI "${LEAKED_COMMUNITY}" "$(git -C "${target}" rev-list --all)" -- 2>/dev/null; then
    printf '\033[0;31m  FAIL\033[0m leaked community string still present\n'
  else
    printf '\033[0;32m  PASS\033[0m leaked community string absent from all commits\n'
  fi

  printf '  commits: %s\n' "$(git -C "${target}" rev-list --all --count)"
}

case "${MODE}" in
  --dry-run)
    SCRATCH="$(mktemp -d)"
    info "cloning a scratch mirror to ${SCRATCH}/repo"
    git clone --no-local --quiet "${REPO_ROOT}" "${SCRATCH}/repo"
    git -C "${SCRATCH}/repo" fetch --quiet origin '+refs/heads/*:refs/heads/*' 2>/dev/null || true
    info "rewriting the scratch copy (the real repository is untouched)"
    run_filter "${SCRATCH}/repo" >/dev/null
    report "${SCRATCH}/repo"
    printf '\nScratch copy left at %s for inspection.\n' "${SCRATCH}/repo"
    printf 'Re-run with --execute to rewrite this repository for real.\n'
    ;;

  --execute)
    warn "This rewrites every commit SHA in ${REPO_ROOT}."
    warn "Anyone with an existing clone will have to re-clone."
    read -r -p "Type 'rewrite' to continue: " confirm
    [[ "${confirm}" == "rewrite" ]] || die "aborted"

    [[ -z "$(git -C "${REPO_ROOT}" status --porcelain)" ]] \
      || die "working tree is not clean — commit or stash first"

    BACKUP="${REPO_ROOT}/../HomeLab-backup-$(git -C "${REPO_ROOT}" rev-parse --short HEAD).bundle"
    info "writing a full backup bundle to ${BACKUP}"
    git -C "${REPO_ROOT}" bundle create "${BACKUP}" --all

    info "rewriting history"
    run_filter "${REPO_ROOT}"
    report "${REPO_ROOT}"

    cat <<EOF

History rewritten locally. Nothing has been pushed.

Next:
  1. Inspect:  git log --oneline | head -20
  2. Re-add the remote (filter-repo removes it as a safety measure):
       git remote add origin <url>
  3. Force-push every branch and tag:
       git push --force --all origin
       git push --force --tags origin
  4. Tell anyone with a clone to re-clone. Old clones can reintroduce the
     removed blobs on their next push.
  5. Rotate the credentials — see docs/runbooks/rotate-snmp-community.md.
     Assume everything that was ever public is compromised.

Backup bundle: ${BACKUP}
Restore with:  git clone ${BACKUP} HomeLab-restored
EOF
    ;;

  *)
    die "usage: $(basename "$0") [--dry-run|--execute]"
    ;;
esac
