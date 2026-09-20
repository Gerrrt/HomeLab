#!/usr/bin/env bash
#
# Which key the estate's CA is signing with right now, and when an offline copy
# of it was last proved to be that key.
#
# WHY THE SERIES IS KEYED ON THE KEY'S FINGERPRINT
#
# ADR-0024's argument, one key over. `make certs ARGS='--ca --force'` mints a
# new root, and from that moment the offline copy is a copy of the OLD key: a
# proof recorded against "the CA key" would keep saying proved for up to ninety
# days about a file that can no longer sign anything anyone trusts. One series
# per key identity is the smallest thing that cannot lie about that, exactly as
# one series per age recipient is. The identity is the SHA-256 of the DER
# SubjectPublicKeyInfo, which is what verify-ca-key-backup.sh compares and what
# `openssl x509 -pubkey` gives without a private key anywhere near it.
#
# So this reads certificates/ca.pem — public — and writes one row for its
# fingerprint, carrying that fingerprint's last proof forward and setting none
# of its own except through --proved. A row for a fingerprint that is not the
# current CA's is dropped with a warning: the key it described has been
# replaced, and the honest state of the new one is "never proved", which a 0
# says louder than an absent series would.
#
# A key that has never been proved is recorded as 0 rather than omitted, for
# the reason key-recipients.sh gives: time() - 0 exceeds every threshold, so
# "never" and "not lately" are one alert instead of one alert and one silence.
#
# WHO RUNS --record. verify-ca-key-backup.sh after a proof (with --proved),
# gen-certs.sh after minting a CA (without, so the new key starts at 0 the same
# minute), and the ca-key-state timer every day with neither — so that the file
# exists on a host that has never proved anything, which is the state the alert
# most needs to see (#400 is what happens otherwise).
#
# Usage:
#   scripts/ca-key-state.sh --fingerprint
#   scripts/ca-key-state.sh --record [--proved <sha256 hex>]
#
# Environment:
#   CA_CERT        the CA certificate (default certificates/ca.pem)
#   TEXTFILE_DIR   where the .prom files go
#                  (default /var/lib/node_exporter/textfile_collector)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CA_CERT="${CA_CERT:-${REPO_ROOT}/certificates/ca.pem}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

# `estate` and not the CN: the label has to survive a re-mint that changes the
# subject, and it leaves room for the tier's root on its own row one day.
CA_LABEL="estate"
METRIC="homelab_ca_key_backup_last_proof_timestamp_seconds"

MODE=""
PROVED=""

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }

usage() { sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --fingerprint) MODE="fingerprint"; shift ;;
    --record)      MODE="record"; shift ;;
    --proved)      PROVED="${2:-}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "${MODE}" ]] || { usage >&2; die "--fingerprint or --record is required"; }

command -v openssl >/dev/null 2>&1 || die "openssl not found"

# A workstation, a CI checkout, or a host that is not the CA. Not a failure:
# `certificates/` is gitignored and host-local, and the timer that calls this
# must not be red on a machine that was never meant to hold a CA.
if [[ ! -s "${CA_CERT}" ]]; then
  [[ "${MODE}" == "fingerprint" ]] && die "no CA certificate at ${CA_CERT}"
  warn "no CA certificate at ${CA_CERT} — nothing to record"
  exit 0
fi

# ---------------------------------------------------------------------------
# The key's identity, read out of the public certificate
# ---------------------------------------------------------------------------
# DER rather than PEM so that the hash is of the key and not of a text
# encoding, and `pkey -pubin` rather than `x509 -fingerprint` because the
# latter hashes the whole certificate — a re-signed certificate over the same
# key would look like a new key, and a backup of that key is still good.
if ! FINGERPRINT="$(openssl x509 -in "${CA_CERT}" -pubkey -noout 2>/dev/null \
                     | openssl pkey -pubin -outform DER 2>/dev/null \
                     | sha256sum | cut -d' ' -f1)" || [[ ! "${FINGERPRINT}" =~ ^[0-9a-f]{64}$ ]]; then
  die "${CA_CERT} is not a readable X.509 certificate"
fi

if [[ "${MODE}" == "fingerprint" ]]; then
  printf '%s\n' "${FINGERPRINT}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Record
# ---------------------------------------------------------------------------
if [[ -n "${PROVED}" ]]; then
  [[ "${PROVED}" =~ ^[0-9a-f]{64}$ ]] || die "--proved is not a SHA-256 hex digest: ${PROVED}"
  # Refused rather than silently ignored, as key-recipients.sh refuses a
  # recipient the file does not list: a proof of a key that is not the CA's
  # current key is a proof of nothing this estate signs with, and writing it
  # would be the exact lie the fingerprint label exists to prevent.
  [[ "${PROVED}" == "${FINGERPRINT}" ]] \
    || die "the proved key is not the one ${CA_CERT#"${REPO_ROOT}"/} carries:
  proved:  ${PROVED}
  current: ${FINGERPRINT}"
fi

# Same two failure modes run-scheduled.sh distinguishes, and the same answers.
if [[ ! -d "${TEXTFILE_DIR}" ]]; then
  warn "no textfile directory at ${TEXTFILE_DIR} — not recording the CA key proof"
  exit 0
elif [[ ! -w "${TEXTFILE_DIR}" ]]; then
  die "${TEXTFILE_DIR} is not writable by $(id -un).
Fix the directory, then re-run:
  sudo install -d -m 0755 -o $(id -un) -g $(id -gn) ${TEXTFILE_DIR}"
fi

# ca-key-backup.prom and not <job>.prom: the wrapper writes ca-key-state.prom
# for the timer that calls this, and #360 is what happens when the two are
# the same file.
PROM="${TEXTFILE_DIR}/ca-key-backup.prom"
NOW="$(date +%s)"

# Carry forward what is already there for THIS fingerprint. The file is
# rewritten whole, so without this a daily run would erase the proof.
prior_for() {
  local want="$1"
  [[ -r "${PROM}" ]] || { printf '0'; return; }
  awk -v want="${want}" -v ca="${CA_LABEL}" -v metric="${METRIC}" '
    index($0, metric "{") == 1 {
      if (index($0, "ca=\"" ca "\"") && index($0, "spki_sha256=\"" want "\"")) value = $NF
    }
    END { print (value ~ /^[0-9]+$/) ? value : "0" }
  ' "${PROM}"
}

# Rows for other CAs are carried through untouched, because node_exporter
# merges the directory and a metric name may carry only one HELP across it.
# Rows for THIS ca label under a different fingerprint are the re-mint case
# and are dropped, out loud.
others=""
replaced=""
if [[ -r "${PROM}" ]]; then
  others="$(grep -F "${METRIC}{" "${PROM}" | grep -vF "ca=\"${CA_LABEL}\"" || true)"
  replaced="$(grep -F "${METRIC}{" "${PROM}" | grep -F "ca=\"${CA_LABEL}\"" \
                | grep -vF "spki_sha256=\"${FINGERPRINT}\"" || true)"
fi
if [[ -n "${replaced}" ]]; then
  warn "the CA has been re-minted since this was last recorded. The offline copy"
  warn "is a copy of the OLD key; the new one is unproved until it is backed up"
  warn "and proved again — docs/runbooks/back-up-the-ca-key.md"
fi

if [[ -n "${PROVED}" ]]; then
  ts="${NOW}"
else
  ts="$(prior_for "${FINGERPRINT}")"
fi

tmp="${PROM}.$$"
{
  printf '# HELP %s Unix time an offline copy of this CA private key was last proved to be this key. 0 means never.\n' "${METRIC}"
  printf '# TYPE %s gauge\n' "${METRIC}"
  [[ -n "${others}" ]] && printf '%s\n' "${others}"
  printf '%s{ca="%s",spki_sha256="%s"} %s\n' "${METRIC}" "${CA_LABEL}" "${FINGERPRINT}" "${ts}"
} > "${tmp}"

# 0644 explicitly and rename to publish, for the two reasons run-scheduled.sh
# gives: a 0600 .prom is invisible to the collector, and a truncate-in-place
# exposes a half-written file to a scrape.
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
