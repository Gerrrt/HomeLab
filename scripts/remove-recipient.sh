#!/usr/bin/env bash
#
# Remove an age recipient from a stack's secrets: take its public half out of
# .sops.yaml and re-key the encrypted file so the removed key no longer opens it.
#
# The other half of add-recipient.sh, and it exists for the same reason that
# script does: .sops.yaml edited without `sops updatekeys` is the worst state
# this repository can be in. Here the drift runs the other way — policy says a
# key is gone while the ciphertext still opens to it — and it is just as silent.
#
# WRITTEN FOR #294. The second holder's key, age1cutv5…, was never kept, and
# its replacement age19mkg76v0… was added on 2026-09-22 (6de8509). Nothing
# could take the lost one out without a hand-edit.
#
# WHAT A REMOVAL LOCKS OUT, AND WHAT IT DOES NOT. From the next commit on, the
# removed key opens nothing. Every ciphertext already in git history still
# opens to it, because those commits are still there. So removing a key that
# was LOST is complete; removing one that may have been SEEN is not, and every
# credential it could open has to be rotated as well — "revocation is still
# rotation", docs/runbooks/back-up-the-age-key.md. This script says so at the
# end rather than deciding which case you are in.
#
# THE GUARDS, each one a way a removal can cost the recovery it exists for:
#
#   - It will not remove the key this host decrypts with. The re-key needs it,
#     and afterwards this host could open nothing.
#   - It will not leave fewer than two recipients. ADR-0024 is the decision
#     that there are two; removing down to one undoes it quietly.
#   - It will not leave only recipients that have never been proved. A proved
#     key is the only kind known to open anything; key-recipients.prom is the
#     record, and 0 there means never.
#
# Usage: scripts/remove-recipient.sh <age1-public-key> [stack]
#        scripts/remove-recipient.sh --self-test
#        make secrets-remove-recipient PUBKEY=age1...

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE_KEY="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

# Take one recipient line out of .sops.yaml, in place.
#
# The keys sit one per line in a folded `age: >-` scalar, comma-separated —
# add-recipient.sh's shape. Removing a line in the middle leaves the commas
# right. Removing the LAST line leaves the new last one ending in a comma,
# which sops reads as an empty recipient and refuses; so that comma goes too.
# A key that is the only line of its rule is refused: a rule with no
# recipients is not a removal, it is a broken file.
#
# Exactly one line must match. Two means the key covers two creation_rules,
# which add-recipient.sh refuses to create for ADR-0020's reason, and which this
# will not guess its way through.
drop_recipient_line() {  # <sops config> <age1 key>
  python3 - "$1" "$2" <<'PY'
import re, sys
path, key = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
hits = [i for i, l in enumerate(lines) if l.strip().rstrip(",").strip() == key]
if len(hits) != 1:
    sys.exit(f"{key} appears on {len(hits)} lines of .sops.yaml, not 1")
i = hits[0]
is_key = lambda l: re.fullmatch(r"\s+age1[a-z0-9]+,?\s*", l) is not None
prev_is_key = i > 0 and is_key(lines[i - 1])
next_is_key = i + 1 < len(lines) and is_key(lines[i + 1])
if not prev_is_key and not next_is_key:
    sys.exit(f"{key} is the only recipient of its rule; removing it would leave the rule empty")
if not lines[i].rstrip().endswith(","):
    # The last of the list: the one before it becomes last and loses its comma.
    lines[i - 1] = lines[i - 1].rstrip().rstrip(",")
del lines[i]
open(path, "w").write("\n".join(lines))
PY
}

if [[ "${1:-}" == "--self-test" ]]; then
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  fail=0
  A=age1yrdu996u5mhdh0qf93l7s8zz8stneqnqxpncrcarrmgxvsy264rqmkcs6x
  B=age1cutv5qvkwxxy9n5clznnvm2hgseeuw9ecswgnspkmxs6d69hrpqqx2wxp4
  C=age19mkg76v0x70wkqwuykxxqpdwrq8mhgklpjw44j6xw73psnhwyvcqa9995j
  rule() {  # <keys...> — a catch-all rule in add-recipient.sh's shape
    printf 'creation_rules:\n  - path_regex: secrets/.*\\.sops\\.ya?ml$\n    age: >-\n'
    local k n=$#
    for k in "$@"; do
      n=$((n - 1))
      if ((n)); then printf '      %s,\n' "${k}"; else printf '      %s\n' "${k}"; fi
    done
  }
  check() {  # <name> <expected file after, or FAIL> <key to remove> <keys before...>
    local name="$1" want="$2" key="$3"; shift 3
    rule "$@" > "${T}/sops.yaml"
    local rc=0
    drop_recipient_line "${T}/sops.yaml" "${key}" 2>/dev/null || rc=$?
    if [[ "${want}" == FAIL ]]; then
      if ((rc)) && [[ "$(cat "${T}/sops.yaml")" == "$(rule "$@")" ]]; then
        printf '\033[0;32m  PASS\033[0m %s\n' "${name}"
      else
        printf '\033[0;31m  FAIL\033[0m %s (expected a refusal that leaves the file untouched)\n' "${name}"; fail=1
      fi
    elif ((rc == 0)) && [[ "$(cat "${T}/sops.yaml")" == "${want}" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "${name}"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n' "${name}"
      diff <(printf '%s\n' "${want}") "${T}/sops.yaml" | sed 's/^/       /'
      fail=1
    fi
  }
  # #294's own case, on the rule as it reads on main: the middle one of three.
  check "the middle key of three goes, and the commas stay right" "$(rule "${A}" "${C}")" "${B}" "${A}" "${B}" "${C}"
  # The trailing comma is the failure a hand-edit makes: sops reads it as an
  # empty recipient and refuses the file.
  check "the last key goes, and the new last line loses its comma" "$(rule "${A}" "${B}")" "${C}" "${A}" "${B}" "${C}"
  check "the first key goes" "$(rule "${B}" "${C}")" "${A}" "${A}" "${B}" "${C}"
  check "a key that is not there is refused, file untouched" FAIL "${B}" "${A}" "${C}"
  check "the only key of a rule is refused, file untouched" FAIL "${A}" "${A}"
  # ADR-0020's collapse: one key in two rules. Built by hand, since rule()
  # writes one rule.
  { rule "${A}" "${B}"; printf '  - path_regex: secrets/lab.*\n    age: >-\n      %s,\n      %s\n' "${B}" "${C}"; } > "${T}/sops.yaml"
  before="$(cat "${T}/sops.yaml")"
  if ! drop_recipient_line "${T}/sops.yaml" "${B}" 2>/dev/null && [[ "$(cat "${T}/sops.yaml")" == "${before}" ]]; then
    printf '\033[0;32m  PASS\033[0m %s\n' "a key in two rules is refused, file untouched"
  else
    printf '\033[0;31m  FAIL\033[0m %s\n' "a key in two rules is refused, file untouched"; fail=1
  fi
  exit "${fail}"
fi

PUBKEY="${1:-}"
STACK="${2:-observability}"
SECRETS_FILE="${REPO_ROOT}/secrets/${STACK}.sops.yaml"
SOPS_CONFIG="${REPO_ROOT}/.sops.yaml"

if [[ -z "${PUBKEY}" ]]; then
  cat >&2 <<EOF
usage: scripts/remove-recipient.sh <age1-public-key> [stack]
   or: make secrets-remove-recipient PUBKEY=age1...

Removes a recipient from secrets/${STACK}.sops.yaml and re-keys it.
Run it where the live key is. Procedure: docs/runbooks/back-up-the-age-key.md
EOF
  exit 2
fi

command -v sops >/dev/null 2>&1 || die "sops not found.
  https://github.com/getsops/sops/releases"
[[ -f "${SECRETS_FILE}" ]] || die "no encrypted secrets at secrets/${STACK}.sops.yaml"
[[ -f "${SOPS_CONFIG}" ]] || die "no ${SOPS_CONFIG}"

if ! [[ "${PUBKEY}" =~ ^age1[a-z0-9]+$ ]] || ((${#PUBKEY} != 62)); then
  die "not an age public key: ${PUBKEY}
It should start with 'age1', be 62 characters, and contain only lowercase
letters and digits."
fi

# ---------------------------------------------------------------------------
# 1. Is it a recipient, in the ciphertext and in the policy?
# ---------------------------------------------------------------------------
mapfile -t CURRENT < <("${REPO_ROOT}/scripts/key-recipients.sh" --list --stack "${STACK}")
((${#CURRENT[@]})) || die "could not read the recipients of secrets/${STACK}.sops.yaml — see above"

in_ciphertext=0
printf '%s\n' "${CURRENT[@]}" | grep -qxF "${PUBKEY}" && in_ciphertext=1
in_policy=0
grep -qE "^[[:space:]]+${PUBKEY},?[[:space:]]*$" "${SOPS_CONFIG}" && in_policy=1

if ((!in_ciphertext && !in_policy)); then
  info "secrets/${STACK}.sops.yaml is not encrypted to ${PUBKEY}, and .sops.yaml does not list it"
  info "nothing to do"
  exit 0
fi
if ((in_ciphertext != in_policy)); then
  die ".sops.yaml and secrets/${STACK}.sops.yaml disagree about ${PUBKEY}:
  .sops.yaml lists it: $( ((in_policy)) && echo yes || echo no)
  the ciphertext opens to it: $( ((in_ciphertext)) && echo yes || echo no)

That is the drift this script exists to prevent, already present. This script
cannot tell which half is right. Fix it by hand; the recipients the file actually
uses are:
$(printf '  %s\n' "${CURRENT[@]}")"
fi

REMAINING=()
for r in "${CURRENT[@]}"; do [[ "${r}" == "${PUBKEY}" ]] || REMAINING+=("${r}"); done

# ---------------------------------------------------------------------------
# 2. Two stay (ADR-0024)
# ---------------------------------------------------------------------------
((${#REMAINING[@]} >= 2)) || die "removing ${PUBKEY} would leave ${#REMAINING[@]} recipient(s).

ADR-0024 holds two, so that the secrets outlive any one copy of a key. Add the
replacement first — make secrets-add-recipient PUBKEY=age1... — then remove this."

# ---------------------------------------------------------------------------
# 3. Not this host's own key, and this host's key stays
# ---------------------------------------------------------------------------
# sops updatekeys needs a key that can decrypt now, and a host whose own key is
# not among the recipients afterwards can open nothing it renders from.
[[ -r "${LIVE_KEY}" ]] || die "no live key at ${LIVE_KEY}.
The re-key needs a key that can decrypt now. Run this where the existing key is."
command -v age-keygen >/dev/null 2>&1 || die "age-keygen not found — it is how this checks which key this host holds"
LIVE_PUB="$(age-keygen -y "${LIVE_KEY}" 2>/dev/null)" || die "could not read the public half of ${LIVE_KEY}"
[[ "${LIVE_PUB}" != "${PUBKEY}" ]] || die "that is this host's own key, at ${LIVE_KEY}.
Removing it would leave this host unable to decrypt the secrets it renders."
printf '%s\n' "${REMAINING[@]}" | grep -qxF "${LIVE_PUB}" || die "this host's key, ${LIVE_PUB},
is not among the recipients that would remain. Afterwards this host could open
nothing, and the re-key itself would fail."

# ---------------------------------------------------------------------------
# 4. At least one remaining recipient has been proved
# ---------------------------------------------------------------------------
# key-recipients.prom is the record ADR-0024 keeps per recipient. A missing
# file is not "no proofs", it is "no record", and removing a key on no record
# is the thing this guard exists to stop.
PROM="${TEXTFILE_DIR}/key-recipients.prom"
[[ -r "${PROM}" ]] || die "no ${PROM}, so which recipients have been proved cannot be read.
Run 'make recipient-state' to write it, then this again."
proved=()
for r in "${REMAINING[@]}"; do
  ts="$(awk -v stack="${STACK}" -v r="${r}" '
    /^homelab_key_recipient_last_proof_timestamp_seconds\{/ &&
      index($0, "stack=\"" stack "\"") && index($0, "recipient=\"" r "\"") { v = $NF }
    END { print (v ~ /^[0-9]+$/) ? v : 0 }' "${PROM}")"
  ((ts > 0)) && proved+=("${r}")
done
((${#proved[@]})) || die "none of the recipients that would remain has ever been proved:
$(printf '  %s\n' "${REMAINING[@]}")
Prove one with 'make secrets-verify-backup KEY=…' before removing ${PUBKEY}."

# ---------------------------------------------------------------------------
# 5. Take it out, re-key, and check the ciphertext rather than the exit status
# ---------------------------------------------------------------------------
BACKUP="$(mktemp)"
cp "${SOPS_CONFIG}" "${BACKUP}"
restore() { cp "${BACKUP}" "${SOPS_CONFIG}"; }
trap 'restore; rm -f "${BACKUP}"' EXIT INT TERM

drop_recipient_line "${SOPS_CONFIG}" "${PUBKEY}" || die "could not edit .sops.yaml — rolled back, nothing changed"
info "removed ${PUBKEY} from .sops.yaml"

info "re-keying secrets/${STACK}.sops.yaml"
sops updatekeys "${SECRETS_FILE}" || die "sops updatekeys failed — .sops.yaml has been rolled back. Nothing changed."

# `updatekeys` exits 0 when the answer at its prompt is no, which would leave
# .sops.yaml saying the key is gone while the file still opens to it.
AFTER="$("${REPO_ROOT}/scripts/key-recipients.sh" --list --stack "${STACK}")"
if grep -qxF "${PUBKEY}" <<< "${AFTER}"; then
  die "sops exited 0 but secrets/${STACK}.sops.yaml still opens to ${PUBKEY} —
answering 'no' at the prompt does exactly this. .sops.yaml has been rolled back."
fi
for r in "${REMAINING[@]}"; do
  grep -qxF "${r}" <<< "${AFTER}" || die "the re-key dropped ${r} as well, which it was not asked to.
Do not commit anything. .sops.yaml has been rolled back; restore the secrets
file with: git checkout -- secrets/${STACK}.sops.yaml"
done

trap - EXIT INT TERM
rm -f "${BACKUP}"

# Rewrites key-recipients.prom from the ciphertext, which drops the removed
# key's row and carries every remaining proof over unchanged.
"${REPO_ROOT}/scripts/key-recipients.sh" --record --stack "${STACK}" || true

cat <<EOF

$(printf '\033[0;32mok\033[0m') — secrets/${STACK}.sops.yaml now opens to ${#REMAINING[@]} recipients, and not to
${PUBKEY}.

  1. Commit both files together, as one change:
         git add .sops.yaml secrets/${STACK}.sops.yaml

  2. Every ciphertext already in git history still opens to the removed key.
     If it was lost, that is the end of it. If it may have been seen, rotate
     every credential it could open — docs/runbooks/back-up-the-age-key.md,
     "Revocation is still rotation".
EOF
