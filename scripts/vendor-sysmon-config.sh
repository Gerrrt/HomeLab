#!/usr/bin/env bash
#
# Vendor sysmon-modular's balanced Sysmon configuration into
# ansible/roles/sysmon/files/ from one release, or check that what is vendored
# is still that release's file, byte for byte (#450).
#
# WHY VENDORED. ADR-0080: the config decides what every guest in the lab domain
# records, so a change to it is a reviewed diff in a PR, not whatever upstream
# published last. The same reasoning as ADR-0069's JA4 scripts.
#
# WHY A RELEASE ASSET. sysmon-modular stopped committing the merged XML: the
# repository holds the modules, and CI builds the profiles per Sysmon version
# and publishes them, with a SHA256SUMS manifest, as a release named after the
# commit they came from (configs-<12 hex>). That manifest is checked here, and
# the sha256 is recorded in VENDORED, so a release whose asset is later replaced
# still fails --check.
#
# WHAT COMES IN. sysmonconfig-<target>.xml, the "balanced" profile built for
# the Sysmon version named, and the repository's license.md (MIT) at the
# release's commit, as LICENSE. The XML is byte-identical to upstream, CRs and
# trailing spaces included: .gitattributes marks it -text and the EditorConfig
# checker excludes it, because ansible/verify.yml compares the guests' Sysmon
# ConfigHash with this file's sha256.
#
# WHAT IS OURS, AND KEPT. NOTICE, which says this repository's MIT licence
# does not extend to the vendored files, and VENDORED, which records where
# they came from. This script rewrites VENDORED and never touches NOTICE.
#
# Usage: scripts/vendor-sysmon-config.sh <configs-tag> [sysmon-target]
#          replace the vendored config (target defaults to 15.21)
#        scripts/vendor-sysmon-config.sh --check
#          re-fetch VENDORED's release and diff
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO}/ansible/roles/sysmon/files"
UPSTREAM="olafhartong/sysmon-modular"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Fetch <tag>'s profile for <target>, check it against the release's own
# manifest, and fetch the licence at the commit the tag names.
fetch() {
  local tag="$1" target="$2" asset="sysmonconfig-${2}.xml" short
  [[ "${tag}" =~ ^configs-([0-9a-f]{12})$ ]] \
    || die "${tag} is not a configs-<12 hex> release tag"
  short="${BASH_REMATCH[1]}"
  local base="https://github.com/${UPSTREAM}/releases/download/${tag}"
  curl -fsSL "${base}/${asset}" -o "${WORK}/${asset}" || die "${tag} has no ${asset}"
  curl -fsSL "${base}/SHA256SUMS" -o "${WORK}/SHA256SUMS" || die "${tag} has no SHA256SUMS"
  (cd "${WORK}" && grep -E "  ${asset}\$" SHA256SUMS | sha256sum -c --quiet -) \
    || die "${asset} does not match ${tag}'s SHA256SUMS"
  curl -fsSL "https://raw.githubusercontent.com/${UPSTREAM}/${short}/license.md" -o "${WORK}/LICENSE" \
    || die "no license.md at ${short}: the licence terms this was vendored under may have changed"
  grep -q 'Permission is hereby granted, free of charge' "${WORK}/LICENSE" \
    || die "license.md at ${short} is no longer the MIT text NOTICE describes"
}

if [[ "${1:-}" == "--check" ]]; then
  [[ -f "${DEST}/VENDORED" ]] || die "nothing vendored at ${DEST}"
  [[ -s "${DEST}/NOTICE" ]] || die "${DEST}/NOTICE is missing or empty"
  tag="$(awk '/^release:/ {print $2}' "${DEST}/VENDORED")"
  target="$(awk '/^target:/ {print $2}' "${DEST}/VENDORED")"
  want="$(awk '/^sha256:/ {print $2}' "${DEST}/VENDORED")"
  fetch "${tag}" "${target}"
  [[ "$(sha256sum < "${DEST}/sysmonconfig.xml" | cut -d' ' -f1)" == "${want}" ]] \
    || die "sysmonconfig.xml is not the sha256 VENDORED records"
  cmp -s "${WORK}/sysmonconfig-${target}.xml" "${DEST}/sysmonconfig.xml" \
    || die "sysmonconfig.xml differs from ${UPSTREAM} ${tag}"
  cmp -s "${WORK}/LICENSE" "${DEST}/LICENSE" || die "LICENSE differs from ${UPSTREAM} at ${tag}"
  printf 'vendored sysmon config matches %s %s (%s)\n' "${UPSTREAM}" "${tag}" "${target}"
  exit 0
fi

tag="${1:-}"
target="${2:-15.21}"
[[ -n "${tag}" ]] || die "usage: scripts/vendor-sysmon-config.sh <configs-tag> [sysmon-target] | --check"
[[ -s "${DEST}/NOTICE" ]] || die "${DEST}/NOTICE is missing or empty. Write it before vendoring"

fetch "${tag}" "${target}"
cp "${WORK}/sysmonconfig-${target}.xml" "${DEST}/sysmonconfig.xml"
cp "${WORK}/LICENSE" "${DEST}/LICENSE"
cat > "${DEST}/VENDORED" <<VENDORED
# Vendored by scripts/vendor-sysmon-config.sh. Do not edit sysmonconfig.xml or
# LICENSE by hand: re-vendor instead, so the diff is upstream's (ADR-0080).
upstream: https://github.com/${UPSTREAM}
release: ${tag}
target: ${target}
sha256: $(sha256sum < "${DEST}/sysmonconfig.xml" | cut -d' ' -f1)
vendored: $(date -u +%Y-%m-%d)
VENDORED
printf 'vendored %s %s (%s) into %s\n' "${UPSTREAM}" "${tag}" "${target}" "${DEST#"${REPO}"/}"
git -C "${REPO}" status --short -- "${DEST}"
