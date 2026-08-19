#!/usr/bin/env bash
#
# Generate the lab's internal CA and the leaf certificates it signs.
#
# Everything lands in certificates/, which is gitignored — along with *.pem and
# *.key — because the previous set of these was committed to a public repository
# and had to be purged from history. See docs/runbooks/purge-git-history.md.
# The control that matters is not the file mode, it is that these never become
# tracked files. `make validate` asserts that; so does CI.
#
# Nothing in this repository terminates TLS yet. This exists so that when
# something does — Grafana is the first candidate, see docs/roadmap.md — issuing
# a certificate is one command rather than a research project, and so the CA is
# created deliberately rather than improvised at the point of need.
#
# Usage:
#   scripts/gen-certs.sh --ca                     create the CA (refuses if it exists)
#   scripts/gen-certs.sh --host <fqdn> [--ip IP]  issue a leaf signed by the CA
#   scripts/gen-certs.sh --list                   show what exists, and when it expires
#
#   --ip <addr>     add an IP SAN; repeatable. Internal DNS is unresolved in
#                   this lab (docs/roadmap.md), so most leaves want one.
#   --days <n>      leaf lifetime, default 825
#   --force         overwrite an existing CA or leaf
#
# The CA key is not passphrase-protected. That is a deliberate trade and worth
# stating: a passphrase is what made the previous leak survivable, but it also
# means every issuance is interactive, which is how a lab ends up with one
# long-lived certificate nobody dares reissue. The exposure this time is bounded
# by the key never leaving this host and never being committed. If you would
# rather have the passphrase, add -aes256 to the CA key generation below and
# accept the prompt on every issue.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${REPO_ROOT}/certificates"
CA_KEY="${CERT_DIR}/ca-key.pem"
CA_CRT="${CERT_DIR}/ca.pem"

CA_SUBJECT='/CN=Matrix Elysium Internal CA/O=matrix.elysium'
CA_DAYS=3650
LEAF_DAYS=825

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32mok\033[0m — %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

MODE=""
HOST=""
IPS=()
FORCE=0

while (($#)); do
  case "$1" in
    --ca)    MODE="ca"; shift ;;
    --list)  MODE="list"; shift ;;
    --host)  MODE="leaf"; HOST="${2:?--host needs an FQDN}"; shift 2 ;;
    --ip)    IPS+=("${2:?--ip needs an address}"); shift 2 ;;
    --days)  LEAF_DAYS="${2:?--days needs a number}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${MODE}" ]] || die "nothing to do — try --ca, --host <fqdn>, or --list (see --help)"
command -v openssl >/dev/null 2>&1 || die "openssl not found"

# 0700: the directory itself, not just the keys. A 0644 directory with 0600 keys
# still tells any local user exactly which hosts have certificates.
mkdir -p "${CERT_DIR}"
chmod 700 "${CERT_DIR}"
umask 077

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "list" ]]; then
  head_ "certificates/"
  shopt -s nullglob
  found=0
  for crt in "${CERT_DIR}"/*.pem; do
    [[ "${crt}" == *-key.pem ]] && continue
    found=1
    subject="$(openssl x509 -in "${crt}" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    enddate="$(openssl x509 -in "${crt}" -noout -enddate 2>/dev/null | cut -d= -f2)"
    if openssl x509 -in "${crt}" -noout -checkend 0 >/dev/null 2>&1; then
      state="valid"
    else
      state="\033[0;31mEXPIRED\033[0m"
    fi
    printf '  %-28s %b  until %s\n' "$(basename "${crt}")" "${state}" "${enddate}"
    printf '    %s\n' "${subject}"
  done
  ((found)) || printf '  (nothing yet — start with %s --ca)\n' "$(basename "$0")"
  printf '\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# --ca
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "ca" ]]; then
  if [[ -s "${CA_KEY}" ]] && ((! FORCE)); then
    die "${CA_KEY#"${REPO_ROOT}"/} already exists.
Regenerating the CA invalidates every leaf it has signed and every trust store
that holds it. Pass --force only if that is what you mean."
  fi

  info "creating the CA (${CA_DAYS} days)"
  openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
    -keyout "${CA_KEY}" -out "${CA_CRT}" -days "${CA_DAYS}" \
    -subj "${CA_SUBJECT}" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 600 "${CA_KEY}"
  chmod 644 "${CA_CRT}"

  ok "CA created"
  printf '  key  %s  (never commit, never copy off this host)\n' "${CA_KEY#"${REPO_ROOT}"/}"
  printf '  cert %s  (safe to distribute — this is what clients trust)\n' "${CA_CRT#"${REPO_ROOT}"/}"
  printf '\nIssue a leaf with:\n  scripts/gen-certs.sh --host grafana.matrix.elysium --ip 10.0.99.20\n\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# --host <fqdn>
# ---------------------------------------------------------------------------
[[ -s "${CA_KEY}" && -s "${CA_CRT}" ]] || die "no CA yet — run: scripts/gen-certs.sh --ca"

KEY="${CERT_DIR}/${HOST}-key.pem"
CRT="${CERT_DIR}/${HOST}.pem"

if [[ -s "${KEY}" ]] && ((! FORCE)); then
  die "${KEY#"${REPO_ROOT}"/} already exists — pass --force to replace it"
fi

# A certificate with no subjectAltName is rejected outright by every current
# browser and by Go's crypto/tls, which is what Prometheus, Alertmanager and
# Grafana are built on. CN alone has not been sufficient for years, and the
# failure — "x509: certificate relies on legacy Common Name field" — reads as a
# trust problem rather than a missing field, so it costs an hour to diagnose.
SAN="DNS:${HOST}"
for ip in "${IPS[@]}"; do
  SAN+=",IP:${ip}"
done

# 825 days is not arbitrary: browsers reject leaf certificates valid for longer.
# A 10-year leaf looks like less work and produces something nothing will trust.
if ((LEAF_DAYS > 825)); then
  die "leaf lifetime ${LEAF_DAYS} exceeds 825 days, which browsers reject outright"
fi

info "issuing ${HOST} (${LEAF_DAYS} days)"
info "SANs: ${SAN}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout "${KEY}" -out "${TMP}/csr.pem" \
  -subj "/CN=${HOST}/O=matrix.elysium" 2>/dev/null

openssl x509 -req -in "${TMP}/csr.pem" -sha256 \
  -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
  -CAserial "${CERT_DIR}/ca.srl" \
  -out "${CRT}" -days "${LEAF_DAYS}" \
  -extfile <(printf 'subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "${SAN}") 2>/dev/null

chmod 600 "${KEY}"
chmod 644 "${CRT}"

# Prove it verifies against the CA now, rather than discovering at deploy time
# that the chain does not build.
openssl verify -CAfile "${CA_CRT}" "${CRT}" >/dev/null 2>&1 \
  || die "the issued certificate does not verify against the CA — refusing to report success"

ok "issued ${CRT#"${REPO_ROOT}"/}"
printf '  key  %s\n' "${KEY#"${REPO_ROOT}"/}"
printf '  SANs %s\n' "${SAN}"
printf '  verified against %s\n\n' "${CA_CRT#"${REPO_ROOT}"/}"
