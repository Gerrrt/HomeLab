#!/usr/bin/env bash
# Run every embedded fixture suite in this repository.
#
# Usage:
#   scripts/self-tests.sh                       run every suite found
#   scripts/self-tests.sh --require-all         a SKIP inside a suite is a failure
#   scripts/self-tests.sh --skips-file <path>   append skipped suites (caller owns it)
#   scripts/self-tests.sh --list                print what would run, then exit
#
# WHY THIS EXISTS, AND WHY IT DISCOVERS RATHER THAN LISTS
#
# Several scripts here can only ever be tested by fixtures. A host cannot be
# asked for a pending security update, a pfSense system upgrade or a drive with
# 850 pending sectors on demand, and VLAN 99 cannot open TCP/22 to VLAN 30 to
# watch the real output even once. The fixtures are not a second opinion about
# those parsers — they are the only opinion. The suites, and the reason each one
# is the only test its script has:
#
#   collect-patch-state.sh    apt-get -s upgrade on a host with no apt-check, and
#                             no fully-patched host produces a pending update (#360)
#   collect-pkg-state.sh      the same, one OS along: a pfSense system meta-package
#                             behind its repository has never been observed live
#   collect-pve-version.sh    pveversion's format, for a host this repo cannot
#                             reach; one fixture stops the kernel being read as
#                             the PVE version (#311)
#   collect-guest-state.sh    qm list, same unreachable host; a stopped guest has
#                             no PID column and a guest name can contain a space
#   collect-gateway-state.sh  the gateway parse, for morpheus
#   collect-smart-state.sh    the collector that shipped WITHOUT fixtures and then
#                             produced a real defect (#483); two fixtures are what
#                             was read off smaug at the console on 2026-09-21
#   verify-ca-key-backup.sh   the real run needs a private key on a mounted medium
#                             and can never happen in CI (#496)
#   backup-offsite.sh         the real run needs the second recipient's medium
#                             mounted (ADR-0048), so the refusals — a DEST inside
#                             this repository, on the same filesystem as the sets,
#                             on an in-memory filesystem, or under a tree this
#                             host clears on boot — run against a fake backups/
#                             tree. /dev/shm is a refusal FIXTURE here, not a
#                             destination: a different filesystem that is still
#                             this host's RAM, which is the #596 regression (#610)
#   collect_silences.py       `issue` is read only from a comment that BEGINS with
#                             #NNN, and the fixture that fails otherwise is the
#                             point (#575)
#
# The list above is prose. What runs is DISCOVERED, because a hand-kept list is a
# second copy of one fact and this repository has already paid for that: when
# this script was written, collect-gateway-state.sh had a --self-test documented
# in its own usage that scripts/validate.sh had never called and no CI job had
# ever run. Nothing said so. Discovery means the next suite is picked up by
# existing, and a suite that stops being discovered fails loudly below rather
# than quietly not running.
#
# The counts are derived too. The line this replaces read
# `PASS backup-offsite.sh --self-test (24 fixtures)` whether 24 fixtures ran or
# 22 did, because two of them skip when $HOME is not writable or /dev/shm is
# absent and the suite still exits 0 (#614). Counting the suite's own PASS lines
# means the number cannot claim more than happened, and --require-all makes such
# a skip a failure where it counts.
#
# The limit of that, stated rather than left to be discovered: the count is
# descriptive, not a target. A fixture DELETED from a suite lowers the number
# and nothing here objects, because nothing here knows what the number should
# be. Pinning it would be a counted claim of the kind check_docs.py keeps, and
# is a deliberate non-goal — the cost is a bump on every PR that adds a fixture,
# and the case it catches is one the diff already shows. What this does catch is
# the case that reaches CI silently: a fixture that ran and disagreed, and a
# fixture that did not run at all.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

REQUIRE_ALL=0
SKIPS_FILE=""
LIST_ONLY=0
while (($#)); do
  case "$1" in
    --require-all) REQUIRE_ALL=1; shift ;;
    --skips-file)  SKIPS_FILE="${2:?--skips-file needs a path}"; shift 2 ;;
    --list)        LIST_ONLY=1; shift ;;
    *) printf 'usage: %s [--require-all] [--skips-file <path>] [--list]\n' "$0" >&2; exit 2 ;;
  esac
done

FAILED=0
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() {
  printf '\033[0;33m  SKIP\033[0m %s\n' "$*"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "$*" >> "${SKIPS_FILE}"
  # Same contract as scripts/lint.sh and scripts/install-timers.sh: under
  # --require-all a skip is a failure, because a check skipped in CI is one
  # nobody will ever run.
  ((REQUIRE_ALL)) && { printf '\033[0;31m  FAIL\033[0m %s (skipped under --require-all)\n' "$*"; FAILED=1; }
  return 0
}
have() { command -v "$1" >/dev/null 2>&1; }

# A script "has a suite" if it DISPATCHES --self-test, not if it mentions one.
# The four shapes in this tree: the `[[ $1 == --self-test ]]` guard most of the
# shell collectors open with, a `--self-test)` case arm, argparse, and the
# hand-rolled argv scan the Python checkers use. Matching the dispatch rather
# than the string is what keeps a usage line or a comment from being mistaken
# for a suite — and a script that advertises the flag without handling it fails
# below when it is run, which is the loud direction.
SELF_TEST_DISPATCH='(== *"--self-test"|--self-test\)|add_argument\("--self-test"|"--self-test" in )'

suites=()
while IFS= read -r f; do
  [[ "${f}" == "scripts/self-tests.sh" ]] && continue
  [[ -f "${f}" ]] || continue
  grep -qE "${SELF_TEST_DISPATCH}" "${f}" 2>/dev/null && suites+=("${f}")
done < <(git ls-files scripts 2>/dev/null || find scripts -type f)

if ((LIST_ONLY)); then
  printf '%s\n' "${suites[@]}"
  exit 0
fi

if ((${#suites[@]} == 0)); then
  # Not "nothing to do". Every suite vanishing at once means the discovery above
  # stopped matching, and reporting that as success is how a green run comes to
  # mean nothing.
  fail "no fixture suites discovered under scripts/ — discovery is broken, not the tree"
  exit 1
fi

total=0
for suite in "${suites[@]}"; do
  name="${suite##*/}"
  cmd=("./${suite}")
  if [[ "${suite}" == *.py ]]; then
    if ! have python3; then
      skip "${name} --self-test: python3 not installed"
      continue
    fi
    cmd=(python3 "${suite}")
  elif [[ ! -x "${suite}" ]]; then
    fail "${suite} is not executable — its suite cannot run"
    continue
  fi

  out="$("${cmd[@]}" --self-test 2>&1)"; rc=$?
  passed="$(printf '%s\n' "${out}" | grep -c 'PASS')"
  skipped="$(printf '%s\n' "${out}" | grep -c 'SKIP')"
  total=$((total + passed))

  if ((rc)); then
    fail "${name} --self-test"
    printf '%s\n' "${out}" | sed 's/^/        /'
    continue
  fi

  pass "${name} --self-test (${passed} fixtures)"
  # A suite that skipped part of itself still exited 0. Print the skip rather
  # than discarding it — the count above already excludes it, and this says
  # which fixture went unexercised and why.
  if ((skipped)); then
    # The suite coloured its own line, so strip the escapes before re-printing:
    # skip() adds its own, and a leftover reset mid-line shows up as literal
    # garbage in a CI log, which has no colour to reset.
    while IFS= read -r line; do
      skip "${name}: $(printf '%s' "${line}" | sed -E 's/\x1b\[[0-9;]*m//g; s/^[[:space:]]*SKIP[[:space:]]*//')"
    done < <(printf '%s\n' "${out}" | grep 'SKIP')
  fi
done

# ---------------------------------------------------------------------------
# That the callers call this.
#
# The same assertion scripts/lint.sh makes about its own callers, in the same
# direction and for the same reason: the check names the jobs that must run it,
# so deleting the step fails the check rather than silently narrowing coverage.
# Before this script existed every suite above ran in scripts/validate.sh and in
# no CI job, so they guarded a `make validate` a contributor might not run and
# guarded the pull request not at all. That is the #68 asymmetry (#614).
#
# Greps rather than a YAML parser, for lint.sh's stated reason: this must never
# become the check that skips because a library is missing.
callers_ok=1
WORKFLOW=".github/workflows/ci.yml"
if [[ ! -f "${WORKFLOW}" ]]; then
  fail "no ${WORKFLOW} — nothing is running these suites in CI"
  callers_ok=0
elif ! grep -qE '^[[:space:]]*run:[[:space:]]*\./scripts/self-tests\.sh --require-all[[:space:]]*$' "${WORKFLOW}"; then
  fail "${WORKFLOW} does not run './scripts/self-tests.sh --require-all'"
  printf '        Without it the fixtures guard make validate only, which is\n'
  printf '        the asymmetry #68 was about.\n'
  callers_ok=0
fi
if ! grep -q 'scripts/self-tests\.sh' scripts/validate.sh; then
  fail "scripts/validate.sh does not call this script — make validate would run no fixtures"
  callers_ok=0
fi
((callers_ok)) && pass "ci.yml and validate.sh both delegate here"

# When a caller passed --skips-file it owns the summary: validate.sh folds these
# skips into its own count and prints one, and two summaries is one too many.
if [[ -z "${SKIPS_FILE}" ]]; then
  printf '\n'
  if ((FAILED)); then
    printf '\033[0;31mfixture suites failed\033[0m\n'
  else
    printf '\033[0;32m%d fixtures across %d suites passed\033[0m\n' "${total}" "${#suites[@]}"
  fi
fi

exit "${FAILED}"
