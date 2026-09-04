#!/usr/bin/env bash
#
# Who can actually open this stack's secrets, and when each of them was last
# proved to still work.
#
# WHY THE ENCRYPTED FILE AND NOT .sops.yaml
#
# .sops.yaml is policy: the recipients the NEXT encryption will use. The `sops:`
# block inside secrets/<stack>.sops.yaml is fact: the recipients this file is
# encrypted to right now. They differ for exactly as long as it takes somebody
# to add a key and forget `sops updatekeys` — a window in which .sops.yaml
# promises a recovery path that does not exist, and every check reading it
# reports a backup that cannot open anything.
#
# So this reads the file. No decryption is involved: the recipient list is
# plaintext metadata, which is the same reason the key names are.
#
# WHY THE TIMESTAMPS ARE PER RECIPIENT
#
# ADR-0024. `homelab_job_last_success_timestamp_seconds{homelab_job=
# "verify-key-backup"}` is one series, and `make secrets-verify-backup` records
# it whichever key was mounted. With one recipient that is exactly right. With
# two it says "a key was proved" when the question is "was THIS key proved" —
# so proving one resets the ninety-day deadline for both and the other is free
# to rot behind a green alert. One series per recipient is the smallest thing
# that cannot lie about that.
#
# A recipient that has never been verified is recorded as 0 rather than omitted.
# time() - 0 is about 1.8 billion seconds, which exceeds every threshold, so
# "never proved" and "not proved lately" are one alert — the same choice
# run-scheduled.sh makes and for the same reason.
#
# Usage:
#   scripts/key-recipients.sh --list [--stack <name>]
#   scripts/key-recipients.sh --record [--stack <name>] [--proved <age1...>]
#
# Environment:
#   TEXTFILE_DIR   where the .prom files go
#                  (default /var/lib/node_exporter/textfile_collector)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

STACK="observability"
MODE=""
PROVED=""

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }

usage() { sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --list)   MODE="list"; shift ;;
    --record) MODE="record"; shift ;;
    --stack)  STACK="${2:-}"; shift 2 ;;
    --proved) PROVED="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "${MODE}" ]] || { usage >&2; die "--list or --record is required"; }

# Same shape run-scheduled.sh enforces on a job name, for the same reason: this
# becomes a path segment and a Prometheus label value.
[[ "${STACK}" =~ ^[a-z][a-z0-9-]{0,30}$ ]] \
  || die "stack name '${STACK}' must match ^[a-z][a-z0-9-]{0,30}\$"

SECRETS_FILE="${REPO_ROOT}/secrets/${STACK}.sops.yaml"
[[ -f "${SECRETS_FILE}" ]] || die "no encrypted secrets at secrets/${STACK}.sops.yaml"

# ---------------------------------------------------------------------------
# The recipients, read out of the file's own metadata
# ---------------------------------------------------------------------------
# grep and not a YAML parser. The `recipient:` keys sit inside the `sops:` block
# and nowhere else in these files — every other value is ciphertext — and a
# bech32 age public key cannot appear in an ENC[...] literal or an armoured age
# blob, both of which are base64. Keeping this dependency-free matters because
# verify-key-backup.sh calls it on a host that has just been rebuilt from bare
# metal, where python3 and PyYAML are not yet a given.
mapfile -t RECIPIENTS < <(grep -oE '^[[:space:]]*(-[[:space:]]+)?recipient:[[:space:]]*age1[a-z0-9]+' "${SECRETS_FILE}" \
                           | grep -oE 'age1[a-z0-9]+' | sort -u)

((${#RECIPIENTS[@]})) \
  || die "secrets/${STACK}.sops.yaml lists no age recipients.
Either it is not SOPS-encrypted, or it is encrypted to a KMS this repository
does not use. Check:  grep -A3 '^sops:' secrets/${STACK}.sops.yaml"

if [[ "${MODE}" == "list" ]]; then
  printf '%s\n' "${RECIPIENTS[@]}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Record
# ---------------------------------------------------------------------------
if [[ -n "${PROVED}" ]]; then
  [[ "${PROVED}" =~ ^age1[a-z0-9]+$ ]] || die "--proved is not an age public key: ${PROVED}"
  # Refused rather than silently ignored. Reaching here means a key decrypted
  # the file while not being one of the recipients the file records, which is
  # not a thing that can happen — so it is a bug in the caller, and writing a
  # proof row for a recipient that does not exist would age out and fire an
  # alert naming a key nobody can find.
  printf '%s\n' "${RECIPIENTS[@]}" | grep -qxF "${PROVED}" \
    || die "${PROVED} is not a recipient of secrets/${STACK}.sops.yaml"
fi

# Same two failure modes run-scheduled.sh distinguishes, and the same answers:
# a missing directory is a human on a workstation and must not break the
# command; an unwritable one is a broken monitoring host and must not be
# reported as a recorded outcome.
if [[ ! -d "${TEXTFILE_DIR}" ]]; then
  warn "no textfile directory at ${TEXTFILE_DIR} — not recording which recipients are proved"
  exit 0
elif [[ ! -w "${TEXTFILE_DIR}" ]]; then
  die "${TEXTFILE_DIR} is not writable by $(id -un).
Fix the directory, then re-run:
  sudo install -d -m 0755 -o $(id -un) -g $(id -gn) ${TEXTFILE_DIR}"
fi

PROM="${TEXTFILE_DIR}/key-recipients.prom"
NOW="$(date +%s)"

# Carry forward what is already there, exactly as run-scheduled.sh carries
# forward prior_success: this file is rewritten in full on every run, so a
# recipient's proof would otherwise be lost the moment a different one was
# verified — which is the failure this whole file exists to prevent.
prior_for() {
  local want="$1"
  [[ -r "${PROM}" ]] || { printf '0'; return; }
  awk -v want="${want}" '
    $0 ~ /^homelab_key_recipient_last_proof_timestamp_seconds\{/ {
      if (index($0, "recipient=\"" want "\"")) value = $NF
    }
    END { print (value ~ /^[0-9]+$/) ? value : "0" }
  ' "${PROM}"
}

# Every recipient of every stack shares one file, because node_exporter merges
# the directory and a metric name may carry only one HELP string across it. A
# second stack writing its own file would collide on that, not on the series.
# So rows for other stacks are carried through untouched.
others=""
if [[ -r "${PROM}" ]]; then
  others="$(grep -F 'homelab_key_recipient_last_proof_timestamp_seconds{' "${PROM}" \
              | grep -vF "stack=\"${STACK}\"" || true)"
fi

tmp="${PROM}.$$"
{
  printf '# HELP homelab_key_recipient_last_proof_timestamp_seconds Unix time an offline copy of this age recipient private key was last proved to decrypt the stack secrets. 0 means never.\n'
  printf '# TYPE homelab_key_recipient_last_proof_timestamp_seconds gauge\n'
  [[ -n "${others}" ]] && printf '%s\n' "${others}"
  for recipient in "${RECIPIENTS[@]}"; do
    if [[ "${recipient}" == "${PROVED}" ]]; then
      ts="${NOW}"
    else
      ts="$(prior_for "${recipient}")"
    fi
    printf 'homelab_key_recipient_last_proof_timestamp_seconds{stack="%s",recipient="%s"} %s\n' \
      "${STACK}" "${recipient}" "${ts}"
  done
} > "${tmp}"

# 0644 explicitly and rename to publish, for the two reasons run-scheduled.sh
# gives: a 0600 .prom is invisible to the collector, and a truncate-in-place
# exposes a half-written file to a scrape.
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
