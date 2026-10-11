#!/usr/bin/env bash
#
# Vendor Wazuh's wazuh-certs-tool.sh into stacks/soc/wazuh/certs-tool/, or check
# that what is vendored is what VENDORED records (#1008).
#
# WHY VENDORED. The wazuh-certs-generator image's own entrypoint downloads this
# tool at run time, with no checksum or signature, falls back silently to
# Wazuh's dev bucket if the download fails, and sources the result as root with
# the certificate directory mounted. The file at
# packages.wazuh.com/<major.minor>/wazuh-certs-tool.sh changes in place under
# the same URL (Last-Modified 2026-09-23 when this was written), so whatever was
# served on the day generated the CA. Pinning a hash on that URL would refuse at
# the next upstream edit, which is the day certificates need reissuing and the
# old bytes may no longer be served. So the tool lives here, and
# scripts/wazuh-certs-mint.sh runs it offline, refusing unless its sha256 is the
# one VENDORED records (ADR-0093).
#
# THE PIN IS THE SHA256, NOT THE URL. Unlike scripts/vendor-ja4.sh, there is no
# immutable upstream reference to re-fetch, because a commit SHA names a tree
# forever and a bucket path names nothing. So --check is offline: the file here
# against the hash VENDORED records. --upstream is the separate, informational
# question of whether Wazuh's copy has moved since, and it gates nothing.
#
# WHAT IS OURS, AND KEPT. NOTICE (the tool is GPLv2, and this repository's MIT
# licence does not extend to it) and VENDORED (URL, sha256, the server's
# Last-Modified, the date). LICENSE is the GPLv2 text, which the licence
# requires to travel with the program. This script rewrites the tool, LICENSE
# and VENDORED, and never touches NOTICE.
#
# BEFORE RE-VENDORING, READ THE DIFF. A re-vendor is a decision to trust new
# code that will mint the SOC's CA. `git diff` after running this is the review,
# and the PR is where it is recorded.
#
# Usage: scripts/vendor-wazuh-certs-tool.sh <major.minor>   replace the vendored tool
#        scripts/vendor-wazuh-certs-tool.sh --check         the file matches VENDORED (offline)
#        scripts/vendor-wazuh-certs-tool.sh --upstream      has Wazuh's copy moved? (informational)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${DEST:-${REPO}/stacks/soc/wazuh/certs-tool}"
TOOL="wazuh-certs-tool.sh"
GPL_URL="https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
field() { awk -v k="$1:" '$1 == k {print $2; exit}' "${DEST}/VENDORED"; }

case "${1:-}" in
  --check)
    [[ -f "${DEST}/VENDORED" ]] || die "nothing vendored at ${DEST}"
    [[ -s "${DEST}/NOTICE" ]] || die "${DEST}/NOTICE is missing or empty: it says the GPLv2 covers the tool"
    [[ -s "${DEST}/LICENSE" ]] || die "${DEST}/LICENSE is missing or empty: the GPLv2 text must travel with the tool"
    # The same test the vendoring step applies to what it fetched. Non-empty
    # alone would pass any file, which isn't what the message above claims.
    if ! { grep -q 'GNU GENERAL PUBLIC LICENSE' "${DEST}/LICENSE" && grep -q 'Version 2, June 1991' "${DEST}/LICENSE"; }; then
      die "${DEST}/LICENSE is not the GPLv2 text: re-vendor rather than edit"
    fi
    want="$(field sha256)"
    [[ "${want}" =~ ^[0-9a-f]{64}$ ]] || die "VENDORED records no sha256"
    have="$(sha256sum "${DEST}/${TOOL}" | cut -d' ' -f1)"
    [[ "${have}" == "${want}" ]] || die "${TOOL} is ${have}, VENDORED says ${want}: re-vendor, don't edit"
    printf 'vendored %s matches VENDORED (%s)\n' "${TOOL}" "${want}"
    exit 0
    ;;
  --upstream)
    command -v curl >/dev/null || die "curl is required"
    url="$(field url)"
    [[ -n "${url}" ]] || die "VENDORED records no url"
    now="$(curl -fsSL "${url}" | sha256sum | cut -d' ' -f1)" || die "could not fetch ${url}"
    if [[ "${now}" == "$(field sha256)" ]]; then
      printf 'upstream %s is still the vendored bytes\n' "${url}"
    else
      printf 'upstream %s has moved: %s now, %s vendored. Re-vendor only after reading the diff.\n' \
        "${url}" "${now}" "$(field sha256)"
    fi
    exit 0
    ;;
esac

version="${1:-}"
[[ "${version}" =~ ^[0-9]+\.[0-9]+$ ]] \
  || die "usage: scripts/vendor-wazuh-certs-tool.sh <major.minor> | --check | --upstream"
command -v curl >/dev/null || die "curl is required"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Only the production bucket. The image's fallback to packages-dev is exactly
# what this replaces.
url="https://packages.wazuh.com/${version}/${TOOL}"
curl -fsSL -D "${WORK}/headers" "${url}" -o "${WORK}/${TOOL}" || die "could not fetch ${url}"
head -n 1 "${WORK}/${TOOL}" | grep -qx '#!/bin/bash' || die "${url} is not the shell script this expects"
grep -q 'GNU General Public' "${WORK}/${TOOL}" || die "${url} no longer states the GPL: read its terms before vendoring"
curl -fsSL "${GPL_URL}" -o "${WORK}/LICENSE" || die "could not fetch ${GPL_URL}"
grep -q 'GNU GENERAL PUBLIC LICENSE' "${WORK}/LICENSE" || die "${GPL_URL} is not the GPLv2 text"

modified="$(awk -F': ' 'tolower($1) == "last-modified" {sub(/\r$/, "", $2); print $2}' "${WORK}/headers")"
sum="$(sha256sum "${WORK}/${TOOL}" | cut -d' ' -f1)"

mkdir -p "${DEST}"
cp "${WORK}/${TOOL}" "${DEST}/${TOOL}"
cp "${WORK}/LICENSE" "${DEST}/LICENSE"
cat > "${DEST}/VENDORED" <<EOF
# Vendored by scripts/vendor-wazuh-certs-tool.sh. Do not edit the tool beside
# this file by hand: re-vendor instead, so the diff is upstream's (ADR-0093).
# scripts/wazuh-certs-mint.sh refuses to run a tool whose sha256 is not this one.
url: ${url}
sha256: ${sum}
last-modified: ${modified:-unknown}
vendored: $(date -u +%F)
EOF
printf 'vendored %s (%s). Read the git diff of %s before committing.\n' "${url}" "${sum}" "${DEST#"${REPO}/"}"
