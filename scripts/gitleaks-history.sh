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
#
#   scripts/gitleaks-history.sh --self-test   fixtures, against a fake gitleaks
#
# The verdict rests on parsing gitleaks's log text, so a change to that text
# could pass an empty scan or fail a real one. The fixtures pin the shapes the
# pinned image prints, colour codes included.

set -uo pipefail

if [[ "${1:-}" == "--self-test" ]]; then
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  fail=0
  ok()  { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
  bad() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; fail=1; }
  # The fake gitleaks prints FAKE_OUT, exits FAKE_RC, and records its argv.
  cat > "${T}/fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FAKE_ARGS}"
printf '%b\n' "${FAKE_OUT}"
exit "${FAKE_RC}"
FAKE
  chmod +x "${T}/fake"
  case_() {  # <want rc> <fake rc> <fake output> <what>
    local rc=0
    FAKE_ARGS="${T}/args" FAKE_RC="$2" FAKE_OUT="$3" "${BASH_SOURCE[0]}" "${T}/fake" >/dev/null 2>&1 || rc=$?
    if ((rc == $1)); then ok "$4"; else bad "$4 (exit ${rc}, wanted $1)"; fi
  }
  E='\033[90m3:29PM\033[0m \033[32mINF\033[0m \033[1m'  # the pinned image's line prefix
  case_ 0 0 "${E}1013 commits scanned.\033[0m\n${E}no leaks found\033[0m" \
    "a clean scan of 1013 commits, coloured as the image prints it, passes"
  case_ 0 0 "INF 1 commits scanned." "a clean scan of one commit passes"
  case_ 1 0 "ERR [git] fatal: not a git repository: /x/.git/worktrees/w\n${E}0 commits scanned.\033[0m\n${E}no leaks found\033[0m" \
    "exit 0 after git failed, with 0 commits scanned, fails (the worktree regression)"
  case_ 1 0 "INF no leaks found" "exit 0 with no commit count at all fails"
  case_ 1 0 "INF 1013 commits found" "a count in some other wording fails rather than passes"
  case_ 1 1 "INF 1013 commits scanned.\nWRN leaks found: 1" "a leak fails with gitleaks's own exit code"
  case_ 126 126 "" "a gitleaks that cannot run fails with its exit code"
  rc=0; "${BASH_SOURCE[0]}" >/dev/null 2>&1 || rc=$?
  if ((rc == 2)); then ok "no gitleaks command is a usage error"; else bad "no gitleaks command exited ${rc}, wanted 2"; fi
  FAKE_ARGS="${T}/args" FAKE_RC=0 FAKE_OUT="INF 5 commits scanned." "${BASH_SOURCE[0]}" "${T}/fake" >/dev/null 2>&1
  want='detect --no-banner --redact -c .gitleaks.toml --log-opts=--all -v'
  if [[ "$(cat "${T}/args")" == "${want}" ]]; then
    ok "gitleaks is called with exactly: ${want}"
  else
    bad "gitleaks was called with: $(cat "${T}/args")"
  fi
  exit "${fail}"
fi

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
