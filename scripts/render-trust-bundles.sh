#!/usr/bin/env bash
#
# Write the sensitive tier's trust bundles for the estate's ingest proxy (#764).
#
# Homepage and Home Assistant on trinity query Prometheus through the proxy on
# 10.0.99.20:9090, whose leaf the estate CA issued. Each takes its trust from
# ONE file, so the estate CA is appended to what each already trusts:
#
#   homepage-ca.pem        tier-ca.pem + the estate CA. NODE_EXTRA_CA_CERTS adds
#                          to Node's built-in roots, so the tier's root
#                          (step-ca's leaves, ADR-0037) and the estate's are the
#                          whole of what it needs.
#   home-assistant-ca.pem  the host's public roots + the estate CA. Home
#                          Assistant builds every client SSL context from
#                          REQUESTS_CA_BUNDLE when it is set and certifi
#                          otherwise (homeassistant/util/ssl.py, read on the
#                          pinned 2026.9.4 image), and the bundle REPLACES
#                          certifi, so it must still hold the public roots its
#                          cloud integrations need. The host's are Ubuntu's
#                          ca-certificates, which unattended-upgrades keeps
#                          current.
#
# The estate CA is the committed stacks/observability/alloy/ingest-ca.pem,
# because trinity's checkout has no certificates/ca.pem (check_ingest_ca.sh
# keeps the two the same).
#
# A CHANGED BUNDLE GETS A NEW INODE, AND AN UNCHANGED ONE IS LEFT ALONE. Node
# reads NODE_EXTRA_CA_CERTS once at startup and Home Assistant builds its
# contexts once, so a bundle rewritten in place (`>`, which keeps the inode)
# would be read by nobody until something else recreated the containers.
# Written to a temporary file and renamed over the old one, the running
# container keeps the old inode, check_mounted_config.py --fix — which `make
# up` runs — sees bytes that differ, and recreates both. That is the opposite
# of what render-config.sh does for its reloadable files, on purpose. A bundle
# whose bytes have not changed is not touched, so an ordinary `make up`
# recreates nothing.
#
# Nothing here is secret, and nothing is decrypted, so it is also how
# check_hardened_boot.sh gets a real bundle to boot Home Assistant with in CI.
#
# Usage: scripts/render-trust-bundles.sh <out-dir> [--home-assistant-only]
#
#   --home-assistant-only  skip homepage-ca.pem, which needs
#                          certificates/tier-ca.pem (absent in CI)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?usage: render-trust-bundles.sh <out-dir> [--home-assistant-only]}"
HA_ONLY=0
[[ "${2:-}" == "--home-assistant-only" ]] && HA_ONLY=1

INGEST_CA="${REPO_ROOT}/stacks/observability/alloy/ingest-ca.pem"
TIER_CA="${REPO_ROOT}/certificates/tier-ca.pem"
SYSTEM_ROOTS="${SYSTEM_ROOTS:-/etc/ssl/certs/ca-certificates.crt}"

die() { printf 'render-trust-bundles: %s\n' "$*" >&2; exit 1; }

need=("${INGEST_CA}" "${SYSTEM_ROOTS}")
((HA_ONLY)) || need+=("${TIER_CA}")
for f in "${need[@]}"; do
  [[ -s "${f}" ]] || die "cannot build the trust bundles: ${f} is missing or empty"
done

mkdir -p "${OUT}"

publish() {  # <name> <source>... → OUT/<name>, renamed into place only if it changed
  local name="$1" dst="${OUT}/$1" tmp
  shift
  tmp="$(mktemp "${OUT}/.${name}.XXXXXX")"
  cat "$@" > "${tmp}"
  chmod 644 "${tmp}"
  if [[ -f "${dst}" ]] && cmp -s "${tmp}" "${dst}"; then
    rm -f "${tmp}"
    printf 'unchanged %s\n' "${name}"
  else
    mv -f "${tmp}" "${dst}"
    printf 'wrote %s\n' "${name}"
  fi
}

publish home-assistant-ca.pem "${SYSTEM_ROOTS}" "${INGEST_CA}"
((HA_ONLY)) || publish homepage-ca.pem "${TIER_CA}" "${INGEST_CA}"
