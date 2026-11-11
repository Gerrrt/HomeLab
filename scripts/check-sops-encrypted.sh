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
# Two tests, both required. The `sops:` metadata block, which sops appends to
# every file it encrypts and which `sops --decrypt` writing over the source
# removes; and, above that block, every value being ciphertext — `ENC[...]`,
# which is what sops writes for a scalar and a list item alike. The block alone
# was the test until 2026-10-14, and it is necessary rather than sufficient: a
# value pasted back in the clear leaves the block in place, so the file passed
# here, passed gitleaks (secrets/*.sops.yaml is path-allowlisted there, because
# ciphertext trips the entropy rules), and `make render` would have decrypted
# the rest and copied the plaintext through. sops itself refuses such a file
# on its MAC, but only on a host that holds the key, which the push does not.
#
# Usage:
#   scripts/check-sops-encrypted.sh                one line per file, exit 1 on any failure
#   scripts/check-sops-encrypted.sh --history      every *.sops.yaml blob in all of history
#   scripts/check-sops-encrypted.sh --self-test    fixtures, in a temporary directory
#
# --history exists because gitleaks cannot see this. Its history scan reads
# .gitleaks.toml, which path-allowlists secrets/*.sops.yaml so ciphertext does
# not trip the entropy rules, and a path allowlist applies to every commit the
# scan walks. A past revision of a SOPS file holding a value in the clear was
# therefore invisible to every check here: this script read HEAD only, and
# gitleaks skipped the path. --history reads every blob ever committed under a
# *.sops.yaml name, at any path, with the same two tests. It needs the full
# history (CI's secret-scan job checks out with fetch-depth: 0) and refuses a
# shallow clone rather than pass over the commits it cannot see.
#
# No other options. Both callers — scripts/validate.sh and the workflow — want
# exactly these, and a --quiet nobody asked for is a flag that can be passed by
# accident in the one place the output matters.

set -euo pipefail

# Why one file fails, or nothing. Lines before the `sops:` block that carry
# a value — `key: value`, `- item` or `- key: value` — must carry `ENC[`. A
# key that opens a mapping has no value and is not a line this reads, nor is a
# bare `-`; comments and blank lines are skipped. A quoted ENC[ is tolerated:
# sops does not quote ciphertext, so that is a hand edit holding no plaintext.
# POSIX awk only — the hosts run mawk, and a gawk-only form would fail the read
# rather than the file, which is why a failed read is itself a failure below.
# The reason names a line NUMBER, never the line: the value on it may be a live
# credential, and this prints into CI logs. With <allow-redacted> set, a value
# that is exactly purge-history.sh's placeholder passes: a past revision that
# the documented purge rewrote holds no secret, and failing it would leave CI
# red for good after the purge worked.
plaintext_reason() {  # <file> [allow-redacted]  prints a reason and returns 1, or returns 0
  local f="$1" redacted="${2:-0}" line
  if ! grep -q '^sops:' "${f}"; then
    printf 'no sops: metadata block'
    return 1
  fi
  # The quote characters arrive in a variable: a single quote cannot appear
  # inside a single-quoted awk program, and \x27 is not POSIX.
  if ! line="$(awk -v q="'\"" -v redacted="${redacted}" '
    BEGIN { key = "^[^[:space:]" q "][^:]*:([[:space:]]|$)"; quote = "^[" q "]" }
    /^sops:/ { exit }
    /^[[:space:]]*(#|$)/ { next }
    {
      v = $0
      sub(/^[[:space:]]+/, "", v)
      if (v ~ /^-([[:space:]]+|$)/) sub(/^-[[:space:]]*/, "", v)
      if (v == "") next
      if (v ~ key) {
        if (v ~ /^[^:]*:[[:space:]]*$/) next
        sub(/^[^:]*:[[:space:]]+/, "", v)
      }
      sub(quote, "", v)
      if (redacted && v ~ ("^REDACTED-ROTATED-CREDENTIAL[" q "]?$")) next
      if (v !~ /^ENC\[/) { print NR; exit }
    }' "${f}")"; then
    printf 'the awk read failed'
    return 1
  fi
  if [[ -n "${line}" ]]; then
    printf 'plaintext value at line %s' "${line}"
    return 1
  fi
  return 0
}

if [[ "${1:-}" == "--self-test" ]] && (($# == 1)); then
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  fail=0
  ok()  { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
  bad() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; fail=1; }
  SOPS_BLOCK=$'sops:\n    age:\n        - recipient: age1example\n    lastmodified: "2026-10-14T00:00:00Z"\n    version: 3.13.3\n'
  case_() {  # <want rc> <what> <file body, in one or more parts>
    local f="${T}/case.sops.yaml" rc=0
    printf '%s' "${@:3}" > "${f}"
    plaintext_reason "${f}" >/dev/null || rc=$?
    if ((rc == $1)); then ok "$2"; else bad "$2 (got ${rc}, wanted $1)"; fi
  }
  case_ 0 "scalars, a nested map, a list item and a comment, all ENC[, pass" \
    $'# a comment\nGRAFANA_ADMIN_PASSWORD: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\nsnmp:\n    community: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\n    hosts:\n        - ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\n'"${SOPS_BLOCK}"
  case_ 1 "no sops: block at all fails" \
    $'GRAFANA_ADMIN_PASSWORD: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\n'
  case_ 1 "a scalar pasted back in the clear, block intact, fails" \
    $'GRAFANA_ADMIN_PASSWORD: hunter2\nOTHER: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\n'"${SOPS_BLOCK}"
  case_ 1 "a nested scalar in the clear fails" \
    $'snmp:\n    community: public\n'"${SOPS_BLOCK}"
  case_ 1 "a list item in the clear fails" \
    $'hosts:\n    - 10.0.99.1\n'"${SOPS_BLOCK}"
  case_ 0 "a quoted ENC[ value is not plaintext" \
    $'KEY: "ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]"\n'"${SOPS_BLOCK}"
  case_ 0 "values inside the sops: block are not read" \
    $'KEY: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\n'"${SOPS_BLOCK}"
  case_ 0 "a list of maps with ENC[ values, and a bare - opening one, pass" \
    $'peers:\n    - name: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\n' \
    $'      key: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\n    -\n' \
    $'      name: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\n'"${SOPS_BLOCK}"
  case_ 1 "a map inside a list with a value in the clear fails" \
    $'peers:\n    - name: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\n' \
    $'      key: wg-private-key-in-the-clear\n'"${SOPS_BLOCK}"
  # The fixture is not shaped like a key on purpose: the working-tree scan
  # reads this file too, and found the first draft's PEM header (#1187).
  case_ 1 "a block scalar, which sops never writes, fails" \
    $'KEY: |\n    several lines of something\n    pasted in the clear\n'"${SOPS_BLOCK}"
  case_ 1 "an empty file fails" ""

  # --history, against throwaway repositories holding a copy of this script.
  ENC_FILE=$'KEY: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]\n'"${SOPS_BLOCK}"
  hist_case() {  # <want rc> <what> <dir>
    local rc=0
    "$3/scripts/check-sops-encrypted.sh" --history >/dev/null 2>&1 || rc=$?
    if ((rc == $1)); then ok "$2"; else bad "$2 (got ${rc}, wanted $1)"; fi
  }
  mkrepo() {  # <dir>: a repository with this script in scripts/
    mkdir -p "$1/scripts" "$1/secrets"
    cp "${BASH_SOURCE[0]}" "$1/scripts/check-sops-encrypted.sh"
    git -C "$1" init -q
  }
  commit() {  # <dir> <path> <body>
    printf '%s' "$3" > "$1/$2"
    git -C "$1" add -A
    git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m x
  }
  mkrepo "${T}/clean"
  commit "${T}/clean" .sops.yaml $'creation_rules: []\n'
  commit "${T}/clean" secrets/a.sops.yaml "${ENC_FILE}"
  hist_case 0 "--history: every revision encrypted passes, and .sops.yaml is not read" "${T}/clean"
  mkrepo "${T}/fixed"
  commit "${T}/fixed" secrets/a.sops.yaml $'KEY: hunter2\n'"${SOPS_BLOCK}"
  commit "${T}/fixed" secrets/a.sops.yaml "${ENC_FILE}"
  hist_case 1 "--history: a plaintext revision fails though HEAD is encrypted" "${T}/fixed"
  mkrepo "${T}/nested"
  commit "${T}/nested" secrets/a.sops.yaml "${ENC_FILE}"
  mkdir -p "${T}/nested/stacks/x/secrets"
  commit "${T}/nested" stacks/x/secrets/b.sops.yaml $'KEY: hunter2\n'"${SOPS_BLOCK}"
  hist_case 1 "--history: a plaintext SOPS file outside secrets/ fails" "${T}/nested"
  mkrepo "${T}/none"
  commit "${T}/none" README $'nothing\n'
  hist_case 1 "--history: no SOPS blob in history at all fails" "${T}/none"
  mkrepo "${T}/shared"
  commit "${T}/shared" secrets/a.sops.yaml "${ENC_FILE}"
  commit "${T}/shared" notes.yaml $'KEY: hunter2\n'"${SOPS_BLOCK}"
  commit "${T}/shared" secrets/b.sops.yaml $'KEY: hunter2\n'"${SOPS_BLOCK}"
  hist_case 1 "--history: a plaintext revision whose blob is also a non-SOPS file fails" "${T}/shared"
  mkrepo "${T}/purged"
  commit "${T}/purged" secrets/a.sops.yaml $'KEY: REDACTED-ROTATED-CREDENTIAL\n'"${SOPS_BLOCK}"
  commit "${T}/purged" secrets/a.sops.yaml "${ENC_FILE}"
  hist_case 0 "--history: a revision purge-history.sh redacted passes" "${T}/purged"
  case_ 1 "the purge placeholder at HEAD still fails" \
    $'KEY: REDACTED-ROTATED-CREDENTIAL\n'"${SOPS_BLOCK}"
  out="$("${T}/fixed/scripts/check-sops-encrypted.sh" --history 2>&1 || true)"
  if [[ "${out}" == *"line 1"* && "${out}" != *hunter2* ]]; then
    ok "--history names the line and never prints the value"
  else
    bad "--history output leaks the value or names no line: ${out//hunter2/<VALUE>}"
  fi
  git clone -q --depth 1 "file://${T}/clean" "${T}/shallow" 2>/dev/null
  mkdir -p "${T}/shallow/scripts" && cp "${BASH_SOURCE[0]}" "${T}/shallow/scripts/"
  hist_case 1 "--history: a shallow clone is refused, not passed" "${T}/shallow"
  exit "${fail}"
fi

HISTORY=0
if [[ "${1:-}" == "--history" ]] && (($# == 1)); then
  HISTORY=1
elif (($# > 0)); then
  printf 'usage: %s [--history | --self-test]\n' "$0" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if ((HISTORY)); then
  if [[ "$(git rev-parse --is-shallow-repository)" != "false" ]]; then
    printf 'shallow clone: history this check cannot see would pass unread.\n' >&2
    printf 'Run git fetch --unshallow first.\n' >&2
    exit 1
  fi
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  # Every (blob, path) a commit on any ref introduced, merge resolutions
  # included (--diff-merges=separate), and root commits (--root). Not
  # `git rev-list --objects`: that names each blob once, under whichever path
  # it met first, so a plaintext revision byte-identical to a file committed
  # under another name would be read under that name and filtered out here.
  # A name with something before .sops.yaml, so .sops.yaml (the rules) is not
  # read. Any directory, so a SOPS file committed outside secrets/ is read too.
  # Each blob is read once, under the first SOPS path it appears at.
  git log --all --root --diff-merges=separate --no-renames --no-abbrev \
    --format= --raw > "${T}/raw"
  awk -F '\t' '
    $1 ~ /^:/ {
      split($1, m, " "); blob = m[4]
      if (blob ~ /^0+$/) next
      if ($2 !~ /(^|\/)[^\/]+\.sops\.yaml$/) next
      if (!(blob in seen)) { seen[blob] = 1; print blob " " $2 }
    }' "${T}/raw" > "${T}/objects"
  n=0
  bad=0
  while read -r blob path; do
    n=$((n + 1))
    git cat-file blob "${blob}" > "${T}/blob"
    if ! reason="$(plaintext_reason "${T}/blob" 1)"; then
      commit="$(git log --all --format=%h -1 --find-object="${blob}")"
      printf '  PLAINTEXT  %s at %s (blob %s) — %s\n' \
        "${path}" "${commit}" "${blob:0:12}" "${reason}" >&2
      bad=1
    fi
  done < "${T}/objects"
  if ((n == 0)); then
    printf 'no *.sops.yaml blob in history — this check has stopped checking anything\n' >&2
    exit 1
  fi
  if ((bad)); then
    printf '\nA SOPS file was committed with a value in the clear. Re-encrypting it\n' >&2
    printf 'now does not remove it: rotate the value, then purge it from history\n' >&2
    printf 'per docs/runbooks/purge-git-history.md.\n' >&2
    exit 1
  fi
  printf '%d SOPS blob(s) across history, all encrypted\n' "${n}"
  exit 0
fi

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
  if reason="$(plaintext_reason "$f")"; then
    printf '  encrypted  %s\n' "$f"
  else
    printf '  PLAINTEXT  %s — %s\n' "$f" "${reason}" >&2
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
