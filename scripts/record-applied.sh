#!/usr/bin/env bash
#
# Record the revision `make up` just applied, so scripts/converge.sh can tell a
# checkout that was DEPLOYED from one that was only MOVED.
#
#   scripts/record-applied.sh STACK          write the record for STACK
#   scripts/record-applied.sh --read STACK   print it (empty if never written)
#   scripts/record-applied.sh --self-test
#
# THE INCIDENT. On 2026-10-01 PR #781 merged four alert rules. The deployment
# checkout on `prometheus` reached the merge by some path other than converge —
# most likely a `git pull` by hand — and nothing ran `make up`. converge then
# compared HEAD with `main`, found them equal, printed "converged" and recorded
# behind=0, every hour, while Prometheus served the pre-merge rules. Every
# deploy alert stayed quiet, because every one of them reads HEAD. It was found
# by looking at the Rules page.
#
# So HEAD is where the checkout IS, and this is what was last APPLIED from it.
# Written as the last step of `make up`, after every check in it has passed, so
# a record exists only for a deploy that finished; a hand `make up` counts the
# same as converge's.
#
# A DIRTY TREE IS RECORDED AS <sha>-dirty, which never equals any HEAD. What it
# applied is not that commit, so once the tree is cleaned the next converge
# redeploys rather than trusting a record of something no commit describes.
#
# WHERE: inside the checkout's git directory, via `git rev-parse --git-path`,
# so it is per checkout (a worktree has its own), never shown by `git status`,
# never committed, and gone with the clone. One file per stack, because `make
# up STACK=x` deploys x and nothing else.
set -euo pipefail

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

record_path() { git rev-parse --git-path "homelab-applied-$1"; }

applied_value() {
  local sha
  sha="$(git rev-parse HEAD)"
  # The same test converge uses for drift, ignored files excluded: .rendered/
  # and .env are written by the deploy itself and are not drift.
  if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    printf '%s-dirty\n' "$sha"
  else
    printf '%s\n' "$sha"
  fi
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  check() {
    if [[ "$2" == "$3" ]]; then printf '\033[0;32m  PASS\033[0m %s\n' "$1"
    else printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$1" "$2" "$3"; fail=1; fi
  }
  (
    cd "$tmp"
    git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
    printf '.rendered/\n' > .gitignore
    git add .gitignore && git -c user.email=t@t -c user.name=t commit -q -m two
  )
  sha="$(git -C "$tmp" rev-parse HEAD)"
  check "never deployed reads as empty" "$(cd "$tmp" && "$here" --read observability)" ""
  (cd "$tmp" && "$here" observability)
  check "a clean deploy records HEAD" "$(cd "$tmp" && "$here" --read observability)" "$sha"
  check "it is not in the working tree" "$(git -C "$tmp" status --porcelain)" ""
  check "another stack has its own record" "$(cd "$tmp" && "$here" --read lab)" ""
  mkdir -p "$tmp/.rendered" && : > "$tmp/.rendered/.env"
  (cd "$tmp" && "$here" observability)
  check "ignored files written by the deploy are not drift" "$(cd "$tmp" && "$here" --read observability)" "$sha"
  printf 'edit\n' > "$tmp/.gitignore"
  (cd "$tmp" && "$here" observability)
  check "a dirty deploy never matches a HEAD" "$(cd "$tmp" && "$here" --read observability)" "${sha}-dirty"
  git -C "$tmp" checkout -q -- .
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q --allow-empty -m three
  check "moving HEAD does not move the record" "$(cd "$tmp" && "$here" --read observability)" "${sha}-dirty"
  exit $fail
fi

READ=0
if [[ "${1:-}" == "--read" ]]; then READ=1; shift; fi
stack="${1:-}"
[[ "$stack" =~ ^[a-z0-9-]+$ ]] || die "usage: $0 [--read] STACK"

path="$(record_path "$stack")"
if ((READ)); then
  [[ -f "$path" ]] && cat "$path"
  exit 0
fi

tmp="${path}.$$"
applied_value > "$tmp"
mv -f "$tmp" "$path"
