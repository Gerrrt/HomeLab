#!/usr/bin/env bash
#
# One deploy of a stack at a time, from one checkout.
#
#   scripts/deploy-lock.sh [--wait SECONDS] STACK -- COMMAND [ARG...]
#                                   run COMMAND holding STACK's deploy lock
#   scripts/deploy-lock.sh --holder STACK   print who holds it (empty if free)
#   scripts/deploy-lock.sh --self-test
#
#   source scripts/deploy-lock.sh, then deploy_lock_acquire STACK SECONDS
#                                   take it for the rest of the calling process
#
# THE INCIDENT. On 2026-10-07 two sessions on `prometheus` deployed the
# observability stack from the same checkout eighteen seconds apart: a
# `make up` at 15:41:49 and a `make converge` at 15:42:07. Both recreated
# alertmanager and blackbox-exporter at once. Compose renames a container to
# <id>_<name> while it replaces it, so the second run's recreate met the
# first's temporary name ("/ee680d332de7_alertmanager is already in use"),
# check_mounted_config.py failed, and that `make up` exited 2 halfway through,
# before record-applied.sh. The first run happened to finish and record, so the
# host was fine. Nothing made it so: the hourly converge timer and a hand
# `make up` can meet the same way, and a stack half-recreated by two runs is
# not one either of them checked.
#
# So `make up` runs under this lock, and converge.sh holds it for its whole run,
# from reading HEAD to recording what it applied. A deploy that finds it held
# waits, says who holds it, and gives up after --wait seconds with exit 75
# (EX_TEMPFAIL) rather than hanging.
#
# NESTING. converge.sh holds the lock and then runs `make up`, which asks for it
# again. flock(2) locks belong to an open file description, so a second open of
# the same file by the child would wait forever on its own parent. The holder
# therefore exports HOMELAB_DEPLOY_LOCK_HELD with the lock's path, and a request
# for that same path runs straight through. Only processes started under the
# holder inherit it, and those are part of the deploy that holds the lock.
#
# WHERE: beside record-applied.sh's record, inside the checkout's git directory
# (`git rev-parse --git-path`): per checkout, so a worktree has its own and
# cannot block the deployment checkout, never shown by `git status`, never
# committed. One file per stack, because `make up STACK=x` deploys only x.
#
# The lock file's content says who holds it. It is written after the lock is
# taken and is informational only: the lock is the flock, not the text, so a
# holder that died leaves stale text and a FREE lock, and the next deploy takes
# it at once.
#
# WITHOUT flock (util-linux) this warns and runs unlocked. Refusing to deploy
# on a host missing a coreutils-level tool would turn a missing guard into an
# outage, and every deployment host here has it.

deploy_lock_path() {
  git rev-parse --path-format=absolute --git-path "homelab-deploy-$1.lock"
}

deploy_lock_holder() {
  local path
  path="$(deploy_lock_path "$1")"
  [[ -f "$path" ]] || return 0
  # Free means nothing to report, whatever stale text a dead holder left.
  if command -v flock >/dev/null 2>&1 && flock -n "$path" true 2>/dev/null; then
    return 0
  fi
  cat "$path"
}

# Take STACK's lock for the rest of the calling process, waiting up to SECONDS.
# Returns 0 holding it (or already holding it, or with no flock to take it
# with), 75 when another deploy still held it at the deadline.
deploy_lock_acquire() {
  local stack="$1" wait="$2" path holder
  path="$(deploy_lock_path "$stack")"
  if [[ "${HOMELAB_DEPLOY_LOCK_HELD:-}" == "$path" ]]; then
    return 0
  fi
  if ! command -v flock >/dev/null 2>&1; then
    printf '\033[0;33mwarning:\033[0m no flock here, so deploying %s without the deploy lock\n' "$stack" >&2
    return 0
  fi
  exec {DEPLOY_LOCK_FD}>>"$path"
  if ! flock -n "$DEPLOY_LOCK_FD"; then
    holder="$(cat "$path" 2>/dev/null || true)"
    printf '\033[0;34m--\033[0m another deploy of %s holds %s:\n     %s\n     waiting up to %ss for it to finish\n' \
      "$stack" "$path" "${holder:-(no holder recorded)}" "$wait" >&2
    if ! flock -w "$wait" "$DEPLOY_LOCK_FD"; then
      exec {DEPLOY_LOCK_FD}>&-
      printf '\033[0;31merror:\033[0m %s is still held after %ss, by:\n     %s\n' \
        "$path" "$wait" "${holder:-(no holder recorded)}" >&2
      return 75
    fi
  fi
  # Overwrite through a second open: truncating does not touch the flock,
  # which belongs to DEPLOY_LOCK_FD's open file description.
  printf 'pid=%s user=%s since=%s cmd=%s\n' \
    "$$" "$(id -un)" "$(date -u +%FT%TZ)" "${DEPLOY_LOCK_CMD:-${0##*/}}" > "$path"
  export HOMELAB_DEPLOY_LOCK_HELD="$path"
}

# Run as a command rather than sourced. A function, not code after a `return`
# guard: a top-level `return` in a sourced file reads to shellcheck as the end
# of the script that sources it. And `dl_die`, not `die`, so sourcing this does
# not replace the caller's own.
deploy_lock_main() {
  dl_die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

  if [[ "${1:-}" == "--self-test" ]]; then
    fail=0
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    check() {
      if [[ "$2" == "$3" ]]; then printf '\033[0;32m  PASS\033[0m %s\n' "$1"
      else printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$1" "$2" "$3"; fail=1; fi
    }
    command -v flock >/dev/null 2>&1 || { printf '\033[0;33m  SKIP\033[0m no flock here\n'; exit 0; }
    git -C "$tmp" init -q -b main .
    cd "$tmp"
    unset HOMELAB_DEPLOY_LOCK_HELD

    check "a free lock has no holder" "$("$here" --holder observability)" ""
    check "a command runs and its status comes back" \
      "$("$here" observability -- sh -c 'echo ran; exit 3'; echo "rc=$?")" "$(printf 'ran\nrc=3')"
    check "it is not in the working tree" "$(git status --porcelain)" ""

    # Two holders at once: the second waits for the first, never overlaps it.
    : > order
    "$here" observability -- sh -c 'echo a-start >> order; sleep 2; echo a-end >> order' &
    first=$!
    sleep 0.5
    check "a running deploy is named as the holder" \
      "$("$here" --holder observability | grep -o 'cmd=sh' || true)" "cmd=sh"
    "$here" --wait 10 observability -- sh -c 'echo b-start >> order; echo b-end >> order' 2>/dev/null
    wait "$first"
    check "a second deploy waits for the first and does not overlap it" \
      "$(tr '\n' ' ' < order)" "a-start a-end b-start b-end "

    # A deadline that passes is exit 75 and the command never runs.
    "$here" observability -- sleep 3 &
    first=$!
    sleep 0.5
    rc=0
    out="$("$here" --wait 1 observability -- echo should-not-run 2>/dev/null)" || rc=$?
    wait "$first"
    check "a lock still held at the deadline exits 75" "$rc" "75"
    check "and the command did not run" "$out" ""

    # Another stack is another lock.
    "$here" observability -- sleep 2 &
    first=$!
    sleep 0.5
    check "a deploy of another stack is not blocked" \
      "$("$here" --wait 0 lab -- echo lab-ran 2>/dev/null)" "lab-ran"
    wait "$first"

    # Nesting: converge holds the lock and runs `make up`, which asks again.
    check "a holder's own child runs straight through" \
      "$(timeout 5 "$here" --wait 1 observability -- "$here" --wait 1 observability -- echo nested 2>/dev/null)" "nested"

    # The sourced form, as converge.sh uses it, holds the lock for the rest of
    # the calling process: an unrelated deploy started meanwhile cannot take it.
    bash -c "source '$here'; deploy_lock_acquire observability 1; sleep 2" &
    first=$!
    sleep 0.5
    rc=0
    env -u HOMELAB_DEPLOY_LOCK_HELD "$here" --wait 1 observability -- true 2>/dev/null || rc=$?
    wait "$first"
    check "an unrelated deploy cannot take a lock held by the sourced form" "$rc" "75"

    # A holder that died leaves stale text and a free lock.
    printf 'pid=1 user=ghost since=then cmd=dead\n' > "$(git rev-parse --path-format=absolute --git-path homelab-deploy-observability.lock)"
    check "stale text from a dead holder does not block" "$("$here" --wait 0 observability -- echo free)" "free"
    check "and is not reported as a holder" "$("$here" --holder observability)" ""
    exit $fail
  fi

  if [[ "${1:-}" == "--holder" ]]; then
    [[ "${2:-}" =~ ^[a-z0-9-]+$ ]] || dl_die "usage: $0 --holder STACK"
    deploy_lock_holder "$2"
    exit 0
  fi

  wait_s="${HOMELAB_DEPLOY_LOCK_WAIT:-900}"
  if [[ "${1:-}" == "--wait" ]]; then wait_s="${2:-}"; shift 2; fi
  [[ "$wait_s" =~ ^[0-9]+$ ]] || dl_die "--wait must be whole seconds, not '${wait_s}'"
  stack="${1:-}"
  [[ "$stack" =~ ^[a-z0-9-]+$ && "${2:-}" == "--" && -n "${3:-}" ]] \
    || dl_die "usage: $0 [--wait SECONDS] STACK -- COMMAND [ARG...]"
  shift 2

  DEPLOY_LOCK_CMD="$*"
  rc=0
  deploy_lock_acquire "$stack" "$wait_s" || rc=$?
  ((rc == 0)) || exit "$rc"
  # The command runs as a child, so this process keeps the lock for exactly as
  # long as it runs. Its own copy of the descriptor is closed: a daemon it leaves
  # behind must not hold the lock after the deploy has finished.
  if [[ -n "${DEPLOY_LOCK_FD:-}" ]]; then
    "$@" {DEPLOY_LOCK_FD}>&- || rc=$?
  else
    "$@" || rc=$?
  fi
  exit "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  deploy_lock_main "$@"
fi
