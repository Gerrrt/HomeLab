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
# tofu/'s state, plans and provider cache are on the list because a state file
# holds every value a provider touched (ADR-0076). tofu/ encrypts state and
# refuses to write it otherwise, so a committed one would be ciphertext. It is
# listed anyway: a check that only holds while encryption.tf is right is not a
# second check. `.terraform.lock.hcl` is meant to be tracked and is not matched,
# because `\.terraform/` needs the slash.
#
# ansible/.ansible/ and ansible/.collections/ are on the list because
# .gitleaks.toml allowlists them. They hold third-party collections that
# ansible-lint and ansible-galaxy download, and ansible.windows ships PEM keys
# and passwords as test fixtures. An allowlisted path is invisible to BOTH
# gitleaks scans, working tree and history, so being untracked is the only
# control left. This is what asserts it, against `git add -f` too (#968).
#
# Usage:
#   scripts/check-tracked-artefacts.sh               names every offender, exit 1 if any
#   scripts/check-tracked-artefacts.sh --root <dir>  the same, against another checkout
#   scripts/check-tracked-artefacts.sh --self-test   fixtures, in throwaway repositories
#
# --self-test exists because this check had never been seen to fail. Every
# pattern below is force-added to a scratch repository and must be named; every
# file that must stay committable is added beside them and must not be.
#
# `git ls-files` and not the filesystem: the question is what is TRACKED. A
# rendered .env sitting in the working tree is correct and expected — that is
# what `make render` produces — and only its being committed is the defect.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${REPO_ROOT}"

# Each entry is a fixed path fragment matched anywhere in a tracked path. The
# leading (^|/) makes it a whole path segment, so `certificates/` matches
# `certificates/x` and `a/certificates/x` but not `my-certificates-notes/x`.
PATTERNS=(
  '\.env'
  '\.rendered/'
  '\.purge-secrets\.txt'
  'certificates/'
  'backups/'
  '[^/]*\.tfstate'
  '[^/]*\.tfplan'
  '\.terraform/'
  'ansible/\.ansible/'
  'ansible/\.collections/'
)

# ---------------------------------------------------------------------------
# --self-test
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  have() { command -v "$1" >/dev/null 2>&1; }
  if ! have git; then
    printf '\033[0;33m  SKIP\033[0m git not installed\n'
    exit 0
  fi
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  fail=0
  ok()  { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
  bad() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; fail=1; }

  # Files that must stay committable. Every scratch repository carries them,
  # so an over-broad pattern fails every fixture rather than none.
  BENIGN=(
    stacks/x/.env.example
    tofu/.terraform.lock.hcl
    tofu/versions.tf
    docs/tfstate-notes.md
    docs/runbooks/back-up-the-age-key.md
    ansible/requirements.yml
    ansible/ansible.cfg
    ansible/.ansible-lint
  )
  scratch() {  # <name> [<offender>] → a repository at ${T}/<name>, everything added -f
    local dir="${T}/$1" f
    git init -q "${dir}"
    for f in "${BENIGN[@]}" ${2:+"$2"}; do
      mkdir -p "${dir}/$(dirname "${f}")"
      printf 'x\n' > "${dir}/${f}"
    done
    # -f: the question is what happens AFTER .gitignore has been walked past.
    git -C "${dir}" add -f -A
  }
  run() {  # <dir> → OUT, RC
    set +e
    OUT="$("${BASH_SOURCE[0]}" --root "$1" 2>&1)"
    RC=$?
    set -e
  }

  scratch clean
  run "${T}/clean"
  if ((RC == 0)); then
    ok "the committable files pass: ${BENIGN[*]}"
  else
    bad "a committable file was named as an artefact"
    printf '%s\n' "${OUT}" | sed 's/^/       | /'
  fi

  OFFENDERS=(
    stacks/observability/.env
    stacks/other/.env
    a/.rendered/alertmanager.yml
    .purge-secrets.txt
    nested/certificates/key.pem
    backups/volumes/x.age
    tofu/state/lab.tfstate
    terraform.tfstate
    a/b/terraform.tfstate.backup
    tofu/terraform.tfstate.d/proof/terraform.tfstate
    tofu/proof.tfplan
    tofu/.terraform/providers/registry.opentofu.org/x
    modules/y/.terraform/terraform.tfstate
    ansible/.ansible/collections/ansible_collections/ansible/windows/tests/root-key.pem
    ansible/.collections/ansible_collections/ansible/windows/tests/cert.pfx
  )
  i=0
  for f in "${OFFENDERS[@]}"; do
    i=$((i + 1))
    scratch "o${i}" "${f}"
    run "${T}/o${i}"
    if ((RC == 1)) && [[ "${OUT}" == *"  ${f}"* ]]; then
      ok "a tracked ${f} is named"
    else
      bad "a tracked ${f} passed (exit ${RC})"
      printf '%s\n' "${OUT}" | sed 's/^/       | /'
    fi
  done
  exit "${fail}"
fi

if [[ "${1:-}" == "--root" ]]; then
  ROOT="${2:?--root needs a directory}"
fi
cd "${ROOT}"

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

printf 'no rendered, decrypted, purge-secrets, certificate, backup, tofu state or downloaded ansible collection files tracked\n'
