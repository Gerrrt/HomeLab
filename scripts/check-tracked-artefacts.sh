#!/usr/bin/env bash
#
# Assert no decrypted, rendered or otherwise secret-bearing artefact is tracked.
#
# This check existed twice — inline in ci.yml and again in scripts/validate.sh —
# as two independent implementations of one sentence, and they had already
# drifted (#175):
#
#   tracked file                   CI      validate.sh
#   stacks/observability/.env      caught  caught
#   stacks/other-stack/.env        caught  MISSED  — it matched ${STACK}/.env only
#   some/other/.rendered/x         caught  MISSED  — one hardcoded subdirectory
#   nested/certificates/key.pem    caught  MISSED  — anchored ^certificates/
#
# Every miss failed on push instead of locally, which is the better direction to
# fail in and still the wrong number of implementations. This is the one, and
# both callers run it.
#
# The patterns are unanchored on purpose, which is where validate.sh's copy went
# wrong: `certificates/` matched only at the repository root, so the same key
# one directory down was invisible. A secret does not become safe by being
# nested.
#
# certificates/ is on the list because its contents were committed once and had
# to be removed by rewriting every commit in the repository. .purge-secrets.txt
# is on it because gitleaks cannot cover that file — it is gitignored, so the
# filesystem scan skips it, and it holds bare literals with no keyword context
# to match. Being untracked is the only control either has.
#
# Usage:
#   scripts/check-tracked-artefacts.sh     names every offender, exit 1 if any
#
# `git ls-files` and not the filesystem: the question is what is TRACKED. A
# rendered .env sitting in the working tree is correct and expected — that is
# what `make render` produces — and only its being committed is the defect.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Each entry is a fixed path fragment matched anywhere in a tracked path. The
# leading (^|/) makes it a whole path segment, so `certificates/` matches
# `certificates/x` and `a/certificates/x` but not `my-certificates-notes/x`.
PATTERNS=(
  '\.env'
  '\.rendered/'
  '\.purge-secrets\.txt'
  'certificates/'
  'backups/'
)

# .env.example is the documented template and is meant to be tracked. It is the
# only exception, and it is spelled out rather than pattern-matched so that a
# second exception has to be argued for in a diff.
tracked="$(git ls-files)"
fail=0
for pattern in "${PATTERNS[@]}"; do
  hits="$(printf '%s\n' "${tracked}" \
          | grep -E "(^|/)${pattern}" \
          | grep -v '\.env\.example$' || true)"
  if [[ -n "${hits}" ]]; then
    printf 'tracked artefact(s) matching %s — these must be gitignored:\n' "${pattern}" >&2
    printf '%s\n' "${hits}" | sed 's/^/  /' >&2
    fail=1
  fi
done

if ((fail)); then
  printf '\nA tracked secret cannot be fixed by deleting it in a later commit —\n' >&2
  printf 'it stays in history. See docs/runbooks/purge-git-history.md\n' >&2
  exit 1
fi

printf 'no rendered, decrypted, purge-secrets, certificate or backup files tracked\n'
