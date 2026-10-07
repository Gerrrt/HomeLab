#!/usr/bin/env bash
#
# Assert the committed ingest CA is one CA certificate, and the estate's.
#
# stacks/observability/alloy/ingest-ca.pem is the only .pem the repository
# tracks (#764). It is the public half of the estate CA in certificates/ca.pem,
# committed so that every checkout that deploys a client of the ingest ports —
# deploy-agent.sh on the Mac for Saruman, trinity's for Homepage and Home
# Assistant — has the file without a copy step to forget. .gitignore lets this
# one path through `*.pem`, which is the reason for this check: the exception is
# a filename, and a filename does not know what is in it. Paste the key into it
# by mistake and gitleaks is the only other thing between it and a public repo.
#
# What it asserts:
#   - exactly one PEM block, and it is a CERTIFICATE (no key, no chain);
#   - nothing else at all: the file, whitespace aside, is byte for byte what
#     openssl writes back for that certificate. OpenSSL ignores text before
#     and after the block, so without this a CA with anything appended — a
#     note, a pasted secret with no PEM header — passed every other line;
#   - that certificate is a CA (basicConstraints CA:TRUE);
#   - where certificates/ca.pem exists (the monitoring host), it is the same
#     certificate. A re-minted CA with a stale committed copy would have every
#     client refuse the proxy at the next deploy, so the drift fails here first.
#     CI has no certificates/, and says so rather than passing silently.
#
# Usage:
#   scripts/check_ingest_ca.sh               check the committed file
#   scripts/check_ingest_ca.sh --self-test   fixtures, in a scratch directory

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMITTED="${INGEST_CA:-${REPO_ROOT}/stacks/observability/alloy/ingest-ca.pem}"
HOST_CA="${HOST_CA:-${REPO_ROOT}/certificates/ca.pem}"

if [[ "${1:-}" == "--self-test" ]]; then
  command -v openssl >/dev/null 2>&1 || { printf '\033[0;33m  SKIP\033[0m openssl not installed\n'; exit 0; }
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  fail=0
  ok()  { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
  bad() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; fail=1; }
  mkca() {  # <name> → ${T}/<name>.pem and ${T}/<name>-key.pem
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "${T}/$1-key.pem" -out "${T}/$1.pem" -days 1 -subj "/CN=$1" \
      -addext basicConstraints=critical,CA:TRUE 2>/dev/null
  }
  mkca ca; mkca other
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "${T}/leaf-key.pem" \
    -subj /CN=leaf -out "${T}/leaf.csr" 2>/dev/null
  openssl x509 -req -in "${T}/leaf.csr" -CA "${T}/ca.pem" -CAkey "${T}/ca-key.pem" -CAcreateserial \
    -days 1 -extfile <(printf 'basicConstraints=CA:FALSE\n') -out "${T}/leaf.pem" 2>/dev/null
  cat "${T}/ca.pem" "${T}/ca-key.pem" > "${T}/with-key.pem"
  cat "${T}/ca.pem" "${T}/other.pem" > "${T}/two.pem"
  { cat "${T}/ca.pem"; printf 'appended text\n'; } > "${T}/trailing.pem"
  { printf 'leading text\n'; cat "${T}/ca.pem"; } > "${T}/leading.pem"
  { cat "${T}/ca.pem"; printf '\n\n'; } > "${T}/blank-lines.pem"
  case_() {  # <want 0|1> <committed> <host ca> <what>
    local rc=0
    INGEST_CA="$2" HOST_CA="$3" "${BASH_SOURCE[0]}" >/dev/null 2>&1 || rc=$?
    if ((rc == $1)); then ok "$4"; else bad "$4 (exit ${rc}, wanted $1)"; fi
  }
  case_ 0 "${T}/ca.pem"       "${T}/ca.pem"      "the CA, matching the host's, passes"
  case_ 0 "${T}/ca.pem"       "${T}/absent.pem"  "the CA with no host copy passes"
  case_ 1 "${T}/with-key.pem" "${T}/ca.pem"      "a certificate with its key appended fails"
  case_ 1 "${T}/ca-key.pem"   "${T}/ca.pem"      "a bare key fails"
  case_ 1 "${T}/two.pem"      "${T}/ca.pem"      "two certificates fail"
  case_ 1 "${T}/trailing.pem" "${T}/ca.pem"      "a CA with text after it fails"
  case_ 1 "${T}/leading.pem"  "${T}/ca.pem"      "a CA with text before it fails"
  case_ 0 "${T}/blank-lines.pem" "${T}/ca.pem"   "a CA with trailing blank lines passes"
  case_ 1 "${T}/leaf.pem"     "${T}/leaf.pem"    "a leaf (CA:FALSE) fails"
  case_ 1 "${T}/ca.pem"       "${T}/other.pem"   "a CA other than the host's fails"
  case_ 1 "${T}/absent.pem"   "${T}/ca.pem"      "a missing file fails"
  exit "${fail}"
fi

die() { printf 'check_ingest_ca: %s\n' "$*" >&2; exit 1; }
rel="${COMMITTED#"${REPO_ROOT}"/}"

[[ -s "${COMMITTED}" ]] || die "${rel} is missing or empty"
blocks="$(grep -c -- '-----BEGIN ' "${COMMITTED}" || true)"
certs="$(grep -c -- '-----BEGIN CERTIFICATE-----' "${COMMITTED}" || true)"
((blocks == 1 && certs == 1)) \
  || die "${rel} must hold exactly one CERTIFICATE block and nothing else (found ${blocks} block(s), ${certs} certificate(s)). If a key ever reached it, treat the CA as compromised: docs/runbooks/generate-certificates.md"
[[ "$(tr -d '[:space:]' < "${COMMITTED}")" == "$(openssl x509 -in "${COMMITTED}" 2>/dev/null | tr -d '[:space:]')" ]] \
  || die "${rel} holds something besides its certificate: text before or after the PEM block. The file must be the certificate and nothing else"
openssl x509 -in "${COMMITTED}" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' \
  || die "${rel} is not a CA certificate (no basicConstraints CA:TRUE)"

if [[ -f "${HOST_CA}" ]]; then
  fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null; }
  [[ "$(fp "${COMMITTED}")" == "$(fp "${HOST_CA}")" ]] \
    || die "${rel} is not certificates/ca.pem. After a re-mint, copy the new certificate over it and commit (cat certificates/ca.pem > ${rel})"
  printf '%s is one CA certificate, and the same as certificates/ca.pem\n' "${rel}"
else
  printf '%s is one CA certificate (no certificates/ca.pem here to compare with)\n' "${rel}"
fi
