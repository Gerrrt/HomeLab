#!/usr/bin/env bash
#
# Assert every committed SOPS file is actually encrypted.
#
# A `secrets/<stack>.sops.yaml` that is not encrypted is a committed plaintext
# secret, and nothing else in this repository would notice: it is tracked on
# purpose, so the tracked-artefact check passes it; it is valid YAML, so every
# parser reads it happily; and `make render` would decrypt-and-copy it without
# complaint because sops treats an unencrypted file as nothing to do.
#
# The failure needs no mistake in this repository to happen — `sops --decrypt`
# writing over the source, an editor saving the decrypted buffer to the original
# path, or a merge resolved in favour of a decrypted side all produce it, and
# all of them look like an ordinary file change in a diff nobody reads closely.
#
# Until #175 the only thing that checked was a CI job, which is the one place
# you cannot consult before pushing. A plaintext secret that reaches the remote
# has to be purged from history rather than reverted, so the check is worth
# far more before the push than after it — see docs/runbooks/purge-git-history.md.
#
# The test is the `sops:` metadata block, which sops appends to every file it
# encrypts and which cannot survive the file being written back in the clear.
# Not "does it contain something that looks like ciphertext": a partially
# decrypted file is still a leak, and the block is absent for that too.
#
# Usage:
#   scripts/check-sops-encrypted.sh                one line per file, exit 1 on any failure
#
# No arguments and no options. Both callers — scripts/validate.sh and the
# workflow — want exactly this, and a --quiet nobody asked for is a flag that
# can be passed by accident in the one place the output matters.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

shopt -s nullglob
FILES=(secrets/*.sops.yaml)

# Zero files is a failure, not a pass. This check exists because the encrypted
# secrets are the one artefact whose absence is silent — a glob that stops
# matching (a rename, a move to secrets/<stack>/) would otherwise report
# "all encrypted" over nothing at all, which is the shape of #68's empty-input
# bug and of the --emit-promql guard in ci.yml.
if ((${#FILES[@]} == 0)); then
  printf 'no secrets/*.sops.yaml found — this check has stopped checking anything\n' >&2
  exit 1
fi

plaintext=()
for f in "${FILES[@]}"; do
  if grep -q '^sops:' "$f"; then
    printf '  encrypted  %s\n' "$f"
  else
    printf '  PLAINTEXT  %s\n' "$f" >&2
    plaintext+=("$f")
  fi
done

if ((${#plaintext[@]})); then
  printf '\nnot SOPS-encrypted: %s\n' "${plaintext[*]}" >&2
  printf 'Do NOT commit these.\n' >&2
  printf 'Re-encrypt with: sops --encrypt --in-place <file>\n' >&2
  printf 'If it has already been pushed, it must be purged from history rather\n' >&2
  printf 'than reverted — see docs/runbooks/purge-git-history.md\n' >&2
  exit 1
fi

printf '%d SOPS file(s), all encrypted\n' "${#FILES[@]}"
