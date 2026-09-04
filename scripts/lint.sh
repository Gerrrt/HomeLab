#!/usr/bin/env bash
#
# The list of linters, in one place, for all three callers.
#
# It lived in three: the lint job in .github/workflows/ci.yml, the lint section
# of scripts/validate.sh, and the Makefile's `lint` target — and all three
# disagreed. CI ran `yamllint --strict`; the other two left warnings as
# warnings, so a warning passed `make validate` and failed the pull request that
# followed. actionlint and editorconfig-checker were GitHub Actions, which meant
# they could not be run here at all: two linters whose first and only feedback
# was a red build. That is #68.
#
# Same fix as scripts/seed-validation-env.sh — one script, every caller calls
# it. The self-check at the bottom asserts the callers really do call it,
# because one definition only helps for as long as nothing routes around it.
#
# actionlint and editorconfig-checker run from images pinned in
# stacks/observability/compose.yaml behind the `lint` profile, for the same
# reason `archiver` and `gitleaks` are there: an image this repository runs must
# be one Dependabot bumps and `make pin-digests` can re-digest (#65). yamllint,
# markdownlint-cli2 and shellcheck keep their binary/pipx/npx runners — CI has
# used those exact runners for as long as this job has existed, and they need no
# install to be reachable.
#
# Usage:
#   scripts/lint.sh                       every linter; an unreachable one SKIPs
#   scripts/lint.sh --require-all         an unreachable linter FAILs (CI)
#   scripts/lint.sh --skips-file <path>   append one line per skip
#
# --require-all is the asymmetry that matters: a local run may honestly skip a
# linter it cannot reach, CI may not, because a linter skipped there is one
# nobody will ever run.
#
# WHAT EACH LINTER LOOKS AT, AND WHY THAT IS NOT OBVIOUS
#
# Three of these decide their own file list, and none of them reads .gitignore.
# That only matters because a workstation has trees a CI checkout does not —
# rendered config, certificates, backups, and another session's git worktree
# under .claude/worktrees/, which is an entire second copy of this repository.
# A linter that walks the tree finds all of it and fails locally for a change
# that is clean, while CI stays green. Green where nothing runs and red where
# everything does is the wrong way round, and it is how a check stops being
# read.
#
# So, measured rather than assumed:
#
#   - yamllint walks `.`, so its exclusions live in .yamllint.yaml
#   - markdownlint-cli2 globs `**/*.md`, which DOES match dot directories, so
#     its exclusions live in .markdownlint-cli2.yaml
#   - shellcheck is handed scripts/*.sh below — one literal glob, cannot wander
#   - actionlint reads only <repo root>/.github/workflows. Verified with
#     -verbose: it lints 2 files with a worktree present, not 4
#   - editorconfig-checker is handed a `git ls-files` list built below, so it
#     sees tracked files and nothing else
#
# The last of those is the shape to copy when this comes up again: a list built
# from git cannot drift, whereas the first two carry a list of exclusions that
# has to be extended by hand every time a new ignored directory appears.
#
# --skips-file follows seed-validation-env.sh's contract: the caller owns the
# path and its lifetime. scripts/validate.sh passes an mktemp it removes on exit
# and adds the line count to its SKIPPED counter. Without it a skip here would
# be invisible there, and validate.sh would sign off with an unqualified "all
# checks passed" over a linter that never ran.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

REQUIRE_ALL=0
SKIPS_FILE=""
while (($#)); do
  case "$1" in
    --require-all) REQUIRE_ALL=1 ;;
    --skips-file)  SKIPS_FILE="${2:?--skips-file needs a path}"; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

FAILED=0
SKIPPED=0
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() {
  printf '\033[0;33m  SKIP\033[0m %s\n' "$*"
  SKIPPED=$((SKIPPED + 1))
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "$*" >> "${SKIPS_FILE}"
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }
have_docker() { have docker && docker info >/dev/null 2>&1; }

# Resolve a linter to the command that runs it.
#
# yamllint, markdownlint-cli2 and shellcheck were all reported as "not
# installed" on a host where CI ran them successfully every push — because CI
# invokes them through `pipx run` and `npx --yes`, and validate.sh only probed
# for a globally installed binary and gave up. Two red CI runs were spent on
# defects a local run could have caught, and reported as passing instead.
#
# So: prefer the real binary, fall back to the runner CI uses. For actionlint
# and editorconfig-checker that runner is the pinned image from compose.yaml —
# neither has a pipx/npx equivalent worth trusting, and an image this repository
# runs has to come from compose.yaml anyway.
#
# Sets an array rather than returning a string to word-split: the docker forms
# embed ${REPO_ROOT}, and word-splitting a path is how that breaks on the first
# directory with a space in it.
RUNNER=()
runner_for() {
  local tool="$1" img
  RUNNER=()
  if have "${tool}"; then RUNNER=("${tool}"); return 0; fi
  case "${tool}" in
    yamllint)
      if have pipx; then RUNNER=(pipx run yamllint); return 0; fi ;;
    markdownlint-cli2)
      if have npx; then RUNNER=(npx --yes markdownlint-cli2); return 0; fi ;;
    actionlint)
      # No --user: this image's entrypoint IS actionlint and it already drops to
      # USER guest. It locates .github/workflows by walking up to the .git
      # directory, which is why the whole repository is mounted.
      if have_docker; then
        img="$(./scripts/image-for.sh actionlint)"
        RUNNER=(docker run --rm -v "${REPO_ROOT}:/repo" -w /repo "${img}")
        return 0
      fi ;;
    editorconfig-checker)
      # The binary is named after the image reference because this image sets
      # Cmd and not Entrypoint: anything appended would replace the binary
      # rather than be passed to it.
      #
      # No --user, deliberately: running as another uid steps outside the path
      # upstream tests, and the checker writes nothing.
      #
      # This image installs git and marks /check a safe.directory so that the
      # checker can list files itself. That is no longer relied on — the list is
      # built on the host and passed in at the call site below, for the reason
      # recorded there. The mount is still the whole repository, because
      # .editorconfig, .editorconfig-checker.json and every file being checked
      # all have to be visible from inside it.
      if have_docker; then
        img="$(./scripts/image-for.sh editorconfig-checker)"
        RUNNER=(docker run --rm -v "${REPO_ROOT}:/check" -w /check "${img}" editorconfig-checker)
        return 0
      fi ;;
  esac
  return 1
}

# "markdownlint-cli2 unavailable" with no hint sends the reader to a search
# engine. Say what to install.
hint_for() {
  case "$1" in
    yamllint)          printf 'pip install yamllint, or install pipx' ;;
    markdownlint-cli2) printf 'npm i -g markdownlint-cli2, or install npx' ;;
    shellcheck)        printf 'apt install shellcheck' ;;
    *)                 printf 'needs a docker daemon, or the binary on PATH' ;;
  esac
}

run_linter() {
  local tool="$1"; shift
  if ! runner_for "${tool}"; then
    if ((REQUIRE_ALL)); then
      fail "${tool} is unreachable, and this run requires every linter"
    else
      skip "${tool} unavailable ($(hint_for "${tool}"))"
    fi
    return 0
  fi
  # Output is captured and printed only on failure, rather than validate.sh's
  # run-quietly-then-re-run-verbosely pattern: two of these pull an image, and
  # paying that twice just to see the message is a poor trade.
  local out rc=0
  out="$("${RUNNER[@]}" "$@" 2>&1)" || rc=$?
  if ((rc == 0)); then
    pass "${tool}"
  else
    printf '%s\n' "${out}"
    fail "${tool}"
  fi
}

# ---------------------------------------------------------------------------
# The list. This is the only copy of it.
# ---------------------------------------------------------------------------
# --strict is the point of the exercise: without it yamllint exits 0 on a
# warning, which is how a clean `make validate` and a red CI run came to
# describe the same tree (#68).
run_linter yamllint --strict .
# No arguments: the globs live in .markdownlint-cli2.yaml.
run_linter markdownlint-cli2
run_linter shellcheck scripts/*.sh
# No arguments: actionlint finds the workflows from the repository root.
run_linter actionlint
# The file list is built here rather than left to the checker, which is the one
# linter in this list that decides for itself what to look at.
#
# Given no arguments it lists files with `git ls-files`, and inside the
# container that call fails silently. A git worktree's .git is a *file* holding
# a path to a gitdir outside the bind mount, so git answers "not a git
# repository" and the checker falls back to walking the filesystem — picking up
# the gitignored backups/, certificates/, .venv/ and .rendered/ trees that exist
# on a workstation and not in a CI checkout. `make validate` then failed on the
# deploy host, where `make up` had rendered the Alertmanager URLs, and passed in
# CI, which never renders. Green where nothing runs and red where everything
# does is the wrong way round, and a validate that is red for a reason the
# operator learns to dismiss is worse than one that does not run.
#
# Listing on the host fixes every caller at once: the host's git resolves a
# worktree, and the checker is handed the same tracked files whether it runs
# from the image or from a local binary. Nothing can substitute a different set
# without saying so. -z because a tracked path may contain a space, and the
# existence test because a tracked file deleted from the working tree makes the
# checker panic with a Go stack trace instead of reporting anything.
ec_files=()
if have git; then
  while IFS= read -r -d '' f; do
    [[ -e "${f}" ]] && ec_files+=("${f}")
  done < <(git ls-files -z)
fi
if ((${#ec_files[@]})); then
  run_linter editorconfig-checker "${ec_files[@]}"
else
  # Not a skip: a skip says the linter could not be reached. This says it could,
  # and there is no trustworthy answer to what it should check — which is the
  # state the checker used to paper over by walking the tree.
  fail "editorconfig-checker: git listed no files to check"
fi

# ---------------------------------------------------------------------------
# Self-check: the three callers must actually be callers
# ---------------------------------------------------------------------------
# One list only removes the drift for as long as nothing routes around it, and
# routing around it is easy and looks perfectly reasonable: adding
# `- name: mylinter` / `run: npx mylinter` to the lint job is precisely how the
# five-step list this replaced came to exist. So the lint job may contain a
# checkout and this script and nothing else, the Makefile target may contain
# this script and nothing else, and validate.sh must call it.
# seed-validation-env.sh asserts against compose.yaml for the same reason; this
# asserts against its callers.
#
# Three greps rather than a Python checker: this must never become the check
# that skips because python3 is missing, and asserting the *absence* of anything
# but one exact line needs no YAML semantics. If it ever needs them, promote it
# to scripts/check_lint_callers.py.
callers_ok=1

job="$(awk '/^  lint:/ {i=1; next} i && /^  [^[:space:]]/ {i=0} i' \
       .github/workflows/ci.yml)"
if [[ -z "${job}" ]]; then
  fail "no lint job in .github/workflows/ci.yml — CI is not running these linters"
  callers_ok=0
else
  stray="$(printf '%s\n' "${job}" \
    | grep -E '^[[:space:]]*(-[[:space:]]*)?(run|uses):' \
    | grep -vE '^[[:space:]]*-[[:space:]]*uses:[[:space:]]*actions/checkout@' \
    | grep -vE '^[[:space:]]*run:[[:space:]]*\./scripts/lint\.sh --require-all[[:space:]]*$' \
    || true)"
  if [[ -n "${stray}" ]]; then
    fail "ci.yml's lint job runs something this script does not know about:"
    printf '%s\n' "${stray}" | sed 's/^[[:space:]]*/        /'
    printf '        Add the linter to %s instead — CI has to call it.\n' \
      "${BASH_SOURCE[0]}"
    callers_ok=0
  fi
fi

recipe="$(awk '/^lint:/ {i=1; next} i && /^[^\t]/ {i=0} i' Makefile \
          | grep -v '^[[:space:]]*$' || true)"
if [[ "${recipe}" != $'\t./scripts/lint.sh' ]]; then
  fail "the Makefile's lint target does not delegate to this script:"
  printf '%s\n' "${recipe}" | sed 's/^/        /'
  callers_ok=0
fi

if ! grep -q 'scripts/lint\.sh' scripts/validate.sh; then
  fail "scripts/validate.sh does not call this script — make validate would lint nothing"
  callers_ok=0
fi

((callers_ok)) && pass "ci.yml, the Makefile and validate.sh all delegate here"

# ---------------------------------------------------------------------------
# When a caller passed --skips-file it owns the summary: validate.sh folds these
# skips into its own count and prints one, and two summaries is one too many.
if [[ -z "${SKIPS_FILE}" ]]; then
  printf '\n'
  if ((FAILED)); then
    printf '\033[0;31mlint failed\033[0m\n'
  elif ((SKIPPED)); then
    printf '\033[0;32mlint passed\033[0m \033[0;33m(%d skipped — NOT run)\033[0m\n' \
      "${SKIPPED}"
  else
    printf '\033[0;32mlint passed\033[0m\n'
  fi
fi

exit "${FAILED}"
