#!/usr/bin/env bash
#
# Add a second age recipient to a stack's secrets: register its public half in
# .sops.yaml and re-key the encrypted file so the new key can actually open it.
#
# ADR-0024 decides that this repository holds more than one recipient and why.
# This is the mechanism, and it exists rather than "edit .sops.yaml and run sops
# updatekeys" for the two reasons bootstrap.sh already refuses to be a one-liner:
#
#   - .sops.yaml has more than one creation_rule, and writing a key into the
#     wrong one is silent. ADR-0020 gives `lab` a rule of its own precisely so a
#     lab-guest key cannot decrypt the estate's SNMP communities; a hand-edit
#     into the general rule undoes that and still looks like it worked.
#   - Editing .sops.yaml WITHOUT running `sops updatekeys` produces the worst
#     possible state: a recipient this repository advertises as a recovery path
#     which cannot decrypt anything. That is not a hypothetical failure, it is
#     the default outcome of doing this by hand and forgetting the second step.
#
# ONLY THE PUBLIC HALF EVER REACHES THIS SCRIPT. The private half of the key
# being added must never exist on this host — see the guard in section 2, and
# docs/runbooks/back-up-the-age-key.md for where it should live instead.
#
# Usage: scripts/add-recipient.sh <age1-public-key> [stack]
#        make secrets-add-recipient PUBKEY=age1...

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBKEY="${1:-}"
STACK="${2:-observability}"
SECRETS_FILE="${REPO_ROOT}/secrets/${STACK}.sops.yaml"
SOPS_CONFIG="${REPO_ROOT}/.sops.yaml"
LIVE_KEY="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*"; }

if [[ -z "${PUBKEY}" ]]; then
  cat >&2 <<EOF
usage: scripts/add-recipient.sh <age1-public-key> [stack]
   or: make secrets-add-recipient PUBKEY=age1...

Adds a recipient to secrets/${STACK}.sops.yaml. Public half only — generate the
keypair on the machine that will HOLD it, never here.
Procedure: docs/runbooks/back-up-the-age-key.md
EOF
  exit 2
fi

command -v sops >/dev/null 2>&1 || die "sops not found.
  https://github.com/getsops/sops/releases"

[[ -f "${SECRETS_FILE}" ]] || die "no encrypted secrets at secrets/${STACK}.sops.yaml
Run 'make secrets-init' first."
[[ -f "${SOPS_CONFIG}" ]] || die "no ${SOPS_CONFIG}"

# ---------------------------------------------------------------------------
# 1. Is it an age public key at all?
# ---------------------------------------------------------------------------
# Checked before anything is written, because the failure mode of a typo is a
# .sops.yaml that sops refuses to parse — which breaks `make render` and takes
# the stack down at the next converge, for a value nobody can decrypt with
# anyway.
#
# An age X25519 public key is bech32 with the `age1` HRP and is always 62
# characters. Length is checked rather than left to the regex so that a
# truncated paste is named as truncated.
[[ "${PUBKEY}" =~ ^age1[a-z0-9]+$ ]] \
  || die "not an age public key: ${PUBKEY}
It should start with 'age1' and contain only lowercase letters and digits.
A private key starts with AGE-SECRET-KEY-1 and must never be pasted here."

((${#PUBKEY} == 62)) \
  || die "'${PUBKEY}' is ${#PUBKEY} characters; an age public key is 62.
Usually a truncated or wrapped paste. Take it from 'age-keygen -y <keyfile>' on
the machine that holds the private half."

# ---------------------------------------------------------------------------
# 2. Is it already a recipient?
# ---------------------------------------------------------------------------
mapfile -t CURRENT < <("${REPO_ROOT}/scripts/key-recipients.sh" --list --stack "${STACK}")

# key-recipients.sh dies with its own message when the file lists none, but it
# dies inside a process substitution, whose exit status this shell never sees.
# Without this the next line would index an empty array and report a bash error
# instead of the real one.
((${#CURRENT[@]})) || die "could not read the recipients of secrets/${STACK}.sops.yaml — see above"

if printf '%s\n' "${CURRENT[@]}" | grep -qxF "${PUBKEY}"; then
  info "secrets/${STACK}.sops.yaml is already encrypted to ${PUBKEY}"
  info "nothing to do"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. It must not be a key this host already holds
# ---------------------------------------------------------------------------
# The whole value of a second recipient is that its private half is somewhere
# this machine is not. A key generated here and then added here is a second copy
# on the disk being insured, wearing the costume of a second recovery path — and
# it would pass every other check in this script and in verify-key-backup.sh.
#
# ADR-0015 rejects `oracle` as a recipient on the same argument one host over:
# the backups and the means to open them must not share a disk.
if [[ -r "${LIVE_KEY}" ]] && command -v age-keygen >/dev/null 2>&1; then
  if age-keygen -y "${LIVE_KEY}" 2>/dev/null | grep -qxF "${PUBKEY}"; then
    die "that is this host's own key.

Its private half is at ${LIVE_KEY}, on the disk these secrets already live on.
Adding it as a second recipient records a recovery path that dies with the
machine it is supposed to survive.

Generate the keypair on the machine or the medium that will hold it, and bring
only the public half back here:  age-keygen -y /path/to/its/keys.txt"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Which creation_rule does this stack's file actually use?
# ---------------------------------------------------------------------------
# Derived from the file rather than by re-implementing sops' first-match-wins
# path_regex resolution. The rule that governs this file is, by definition, the
# one listing the recipients the file is already encrypted to — so the anchor is
# a fact about the ciphertext, not a guess about the policy.
#
# That also makes the ADR-0020 mistake structurally impossible: the lab rule
# does not list the estate's recipient, so `--stack observability` cannot land
# in it, and vice versa.
ANCHOR="${CURRENT[0]}"

mapfile -t ANCHOR_LINES < <(grep -nE "^[[:space:]]+${ANCHOR},?[[:space:]]*$" "${SOPS_CONFIG}" | cut -d: -f1)

if ((${#ANCHOR_LINES[@]} == 0)); then
  die "secrets/${STACK}.sops.yaml is encrypted to
  ${ANCHOR}
but no creation_rule in .sops.yaml lists that key.

The policy and the ciphertext disagree, and this script cannot tell which one is
right. Fix .sops.yaml by hand — the recipients the file actually uses are:
$(printf '  %s\n' "${CURRENT[@]}")"
fi

if ((${#ANCHOR_LINES[@]} > 1)); then
  die "${ANCHOR}
appears in ${#ANCHOR_LINES[@]} creation_rules in .sops.yaml (lines: ${ANCHOR_LINES[*]}).

One key covering two rules is the collapse those rules exist to prevent —
bootstrap.sh refuses the same thing. Untangle .sops.yaml by hand first."
fi

LINE="${ANCHOR_LINES[0]}"
ANCHOR_TEXT="$(sed -n "${LINE}p" "${SOPS_CONFIG}")"

# The anchor line matched ^[[:space:]]+age1...,?[[:space:]]*$ to get here, so
# these two are total: everything before the key is the indent, and the key
# itself is what the new line has to line up with.
INDENT="${ANCHOR_TEXT%%age1*}"
ANCHOR_TEXT="${ANCHOR_TEXT%"${ANCHOR_TEXT##*[![:space:]]}"}"

# ---------------------------------------------------------------------------
# 5. Write it in
# ---------------------------------------------------------------------------
# One recipient per line, comma-separated. sops reads `age:` as a single string
# and splits it on commas, trimming each part — so a folded scalar that puts one
# key per line is the same value as one long line, and reviews far better.
# Measured on sops 3.9.4 rather than assumed, because a wrong guess here is a
# .sops.yaml that parses as YAML and decrypts nothing.
#
# The anchor keeps whatever trailing comma it had: if it already ended in one it
# was not the last entry, and the new line needs one too.
if [[ "${ANCHOR_TEXT}" == *, ]]; then
  NEW_LINE="${INDENT}${PUBKEY},"
  REWRITTEN="${ANCHOR_TEXT}"
else
  NEW_LINE="${INDENT}${PUBKEY}"
  REWRITTEN="${ANCHOR_TEXT},"
fi

BACKUP="$(mktemp)"
cp "${SOPS_CONFIG}" "${BACKUP}"
# Restores .sops.yaml on any exit before the re-key is confirmed. A half-applied
# change here is the state described at the top of this file: an advertised
# recovery path that cannot decrypt.
restore() { cp "${BACKUP}" "${SOPS_CONFIG}"; }
trap 'restore; rm -f "${BACKUP}"' EXIT INT TERM

python3 - "${SOPS_CONFIG}" "${LINE}" "${REWRITTEN}" "${NEW_LINE}" <<'PY'
import sys
path, line, rewritten, new_line = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
lines = open(path).read().split("\n")
lines[line - 1] = rewritten
lines.insert(line, new_line)
open(path, "w").write("\n".join(lines))
PY

info "added ${PUBKEY} to .sops.yaml"

# ---------------------------------------------------------------------------
# 6. Re-key, which is the half that does the work
# ---------------------------------------------------------------------------
# Needs the private half of a key that can ALREADY decrypt — normally the live
# key on this host. sops prints the group change and asks; that prompt is worth
# keeping, because it is the last point at which a wrong recipient is cheap.
info "re-keying secrets/${STACK}.sops.yaml"
if ! sops updatekeys "${SECRETS_FILE}"; then
  die "sops updatekeys failed — .sops.yaml has been rolled back.

Nothing changed. The usual cause is that this host cannot decrypt the file, and
re-keying requires a key that can. Run this where the existing key is."
fi

# ---------------------------------------------------------------------------
# 7. Do not trust the exit status alone
# ---------------------------------------------------------------------------
# The same rule bootstrap.sh and verify-key-backup.sh apply. `updatekeys` exits
# 0 when the user answers no at its prompt, which leaves .sops.yaml advertising
# a recipient the ciphertext has never heard of.
if ! "${REPO_ROOT}/scripts/key-recipients.sh" --list --stack "${STACK}" | grep -qxF "${PUBKEY}"; then
  die "sops exited 0 but secrets/${STACK}.sops.yaml is still not encrypted to
${PUBKEY} — answering 'no' at the prompt does exactly this.

.sops.yaml has been rolled back so the two still agree. Re-run when ready."
fi

trap - EXIT INT TERM
rm -f "${BACKUP}"

# The new recipient starts life unproven, and says so out loud rather than
# waiting for the next verification of some OTHER key to notice it exists.
# key-recipients.sh writes 0 for it, SecretsKeyBackupUnproven reads that as
# "never", and the nagging starts now instead of in ninety days.
"${REPO_ROOT}/scripts/key-recipients.sh" --record --stack "${STACK}" || true

cat <<EOF

$(printf '\033[0;32mok\033[0m') — secrets/${STACK}.sops.yaml is now encrypted to $((${#CURRENT[@]} + 1)) recipients.

Not yet done, and the alert is already saying so:

  1. Put the private half somewhere this machine is not, and somewhere the
     existing backup is not. Two copies in one drawer is one copy.
         docs/runbooks/back-up-the-age-key.md

  2. Prove it opens the file. Until this runs, the new recipient is recorded as
     never verified and SecretsKeyBackupUnproven names it:
         make secrets-verify-backup KEY=/path/to/the/new/copy

  3. Commit both files together. .sops.yaml and the re-keyed secrets file are
     one change; splitting them across commits leaves main in the state this
     script spends most of its length preventing:
         git add .sops.yaml secrets/${STACK}.sops.yaml
EOF
