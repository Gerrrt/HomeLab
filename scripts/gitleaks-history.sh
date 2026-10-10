#!/usr/bin/env bash
#
# Scan the full git history for secrets, and refuse a scan that read nothing.
#
# Usage: scripts/gitleaks-history.sh <command that runs gitleaks>...
#   e.g. scripts/gitleaks-history.sh gitleaks
#        scripts/gitleaks-history.sh docker run --rm -v "$PWD:/repo" -w /repo "$GITLEAKS_IMAGE"
#
# Run from the repository root. The arguments are the gitleaks command, without
# a subcommand. This script adds `detect` and the flags, so CI and validate.sh
# cannot drift apart on them.
#
# gitleaks exits 0 when git fails. It logs `fatal: not a git repository`, then
# reports "0 commits scanned" and "no leaks found". validate.sh's docker
# fallback did exactly that from every git worktree, because a worktree's .git
# names a directory outside the mount, and it printed PASS for a history it
# never read. So the exit code is not enough: the scan must also report a commit
# count above zero. It does not catch a shallow clone, which has commits to
# scan. CI's `fetch-depth: 0` is what covers that.
#
# gitleaks's output is always printed, then one verdict line.

set -uo pipefail

if (($# == 0)); then
  echo "usage: $0 <command that runs gitleaks>..." >&2
  exit 2
fi

out="$("$@" detect --no-banner --redact -c .gitleaks.toml --log-opts="--all" -v 2>&1)"
rc=$?
printf '%s\n' "${out}"

if ((rc != 0)); then
  echo "gitleaks exited ${rc}: a leak in history, or the scan itself failed"
  exit "${rc}"
fi

if [[ "${out}" =~ ([0-9]+)\ commits\ scanned ]] && ((BASH_REMATCH[1] > 0)); then
  echo "${BASH_REMATCH[1]} commits scanned, no leaks found"
  exit 0
fi

echo "gitleaks exited 0 but scanned no commits: git could not read the repository"
exit 1
