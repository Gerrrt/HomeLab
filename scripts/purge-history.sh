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
# The literals to scrub are read from a gitignored file, NOT hardcoded here.
# An earlier version of this script embedded the leaked community string
# directly — which meant that after a successful history rewrite the secret was
# still sitting in the working tree, in the very script written to remove it.
# The dry run proved it: `git grep` on the rewritten mirror still found the
# string in this file. A purge tool must not itself be a copy of the secret.
#
# Usage:
#   scripts/purge-history.sh --dry-run     # rewrite a scratch mirror, report
#   scripts/purge-history.sh --execute     # rewrite ./ for real
#
#   --secrets-file PATH   literals to redact, one per line
#                         (default: .purge-secrets.txt, gitignored)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="--dry-run"
SECRETS_LIST="${REPO_ROOT}/.purge-secrets.txt"

while (($#)); do
  case "$1" in
    --dry-run|--execute) MODE="$1"; shift ;;
    --secrets-file) SECRETS_LIST="${2:?--secrets-file needs a path}"; shift 2 ;;
    *) printf 'usage: %s [--dry-run|--execute] [--secrets-file PATH]\n' \
         "$(basename "$0")" >&2; exit 1 ;;
  esac
done

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

if [[ ! -f "${SECRETS_LIST}" ]]; then
  die "no secrets list at ${SECRETS_LIST}

Create it with one literal per line — the values to redact from history:

  printf '%s\\n' 'the-old-snmp-community' > .purge-secrets.txt

It is gitignored, so the secret never enters a commit. Delete it when done.
Pass --secrets-file PATH to use a different location."
fi

REPLACEMENTS="$(mktemp)"
PATHS_FILE="$(mktemp)"
trap 'rm -f "${REPLACEMENTS}" "${PATHS_FILE}"' EXIT
chmod 600 "${REPLACEMENTS}"

# Read the list once into an array. Everything downstream uses the array rather
# than re-reading the file, so the secret is touched on disk exactly once.
LITERALS=()
while IFS= read -r literal; do
  [[ -z "${literal}" || "${literal}" =~ ^[[:space:]]*# ]] && continue
  LITERALS+=("${literal}")
done < "${SECRETS_LIST}"
((${#LITERALS[@]} > 0)) || die "${SECRETS_LIST} contains no literals"

# git-filter-repo replacement syntax: <literal>==><replacement>
for literal in "${LITERALS[@]}"; do
  printf '%s==>REDACTED-ROTATED-CREDENTIAL\n' "${literal}" >> "${REPLACEMENTS}"
done
info "loaded ${#LITERALS[@]} literal(s) to redact"

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

  # Check every literal across every commit. The earlier version only checked
  # one string and reported PASS while the same string was still sitting in the
  # working tree of the rewritten repo, inside this script. Scan the checked-out
  # tree as well as history.
  # Detect by OUTPUT PRESENCE, never by exit status.
  #
  # `git rev-list --all | xargs -I{} git grep -q ... {}` looks correct and is
  # not: xargs returns 123 when *any* invocation exits 1-125, so a literal
  # present in some commits but absent from others makes the whole pipeline
  # non-zero and the check silently reports clean. Measured on this repo: a
  # string present in 17 of 49 commits was reported as absent. A security check
  # that fails open is worse than no check.
  # -F throughout: a rotated community is a random string and may contain regex
  # metacharacters. Without it, values containing [ ] ( ) . * + ? are either
  # mis-parsed or make grep error out — and a grep that errors reports no match,
  # which is one more way to fail open.
  local leaked=0 literal hit
  local ignore_name; ignore_name="$(basename "${SECRETS_LIST}")"
  for literal in "${LITERALS[@]}"; do
    # `|| true` is load-bearing: under `set -o pipefail` the xargs 123 above
    # would abort the whole script before this check ever printed anything.
    hit="$(git -C "${target}" rev-list --all \
             | xargs -r -I{} git -C "${target}" grep -lIF -e "${literal}" {} -- 2>/dev/null \
             | head -n1 || true)"
    [[ -n "${hit}" ]] && { leaked=1; printf '         history:  %s\n' "${hit}"; }

    hit="$(grep -rlIF -e "${literal}" "${target}" \
             --exclude-dir=.git --exclude="${ignore_name}" 2>/dev/null | head -n1 || true)"
    [[ -n "${hit}" ]] && { leaked=1; printf '         worktree: %s\n' "${hit}"; }
  done

  if ((leaked)); then
    printf '\033[0;31m  FAIL\033[0m a redacted literal is still present (history or worktree)\n'
  else
    printf '\033[0;32m  PASS\033[0m no redacted literal in any commit or in the worktree\n'
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
