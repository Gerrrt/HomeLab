#!/usr/bin/env bash
#
# Vendor FoxIO's ja4-zeek-scripts into stacks/sensor/zeek/ja4/ at one commit,
# or check that what is vendored is still that commit, byte for byte (#776).
#
# WHY VENDORED. ADR-0069: the compiled zeek/foxio/ja4 plugin needs a toolchain
# build, which would be the first image this repository builds and would sit
# outside the digest pins, the healthcheck probe and Dependabot. The scripts
# package installs by copying it into Zeek's site path, which is how local.zeek
# already reaches the container, as a read-only bind mount. So the scripts live
# here, at a commit, and change only by a PR that runs this.
#
# WHAT COMES IN. The package's zeek/ directory, minus its btest suite and
# traces, which the sensor never runs. Plus LICENSE (FoxIO License 1.1, all
# JA4+ but JA4), LICENSE-JA4 (BSD 3-Clause, JA4 itself) and zkg.meta. The files
# are byte-identical to upstream: the EditorConfig checker excludes this
# directory for that reason, so a re-vendor's diff is upstream's change and
# nothing else, and --check can compare.
#
# WHAT IS OURS, AND KEPT. NOTICE, which says which licence covers what and that
# this repository's MIT licence does not, and VENDORED, which records the
# commit. This script rewrites VENDORED and never touches NOTICE.
#
# A COMMIT, NOT A TAG OR A BRANCH. Both move. The full 40-character SHA is the
# only reference that names one tree forever, and VENDORED records it.
#
# Usage: scripts/vendor-ja4.sh <40-char commit sha>    replace the vendored tree
#        scripts/vendor-ja4.sh --check                 re-fetch VENDORED's commit and diff
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO}/stacks/sensor/zeek/ja4"
UPSTREAM="FoxIO-LLC/ja4-zeek-scripts"
OURS=(NOTICE VENDORED)

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Fetch <sha>'s tree and lay out what is vendored in ${WORK}/tree.
fetch() {
  local sha="$1"
  curl -fsSL "https://codeload.github.com/${UPSTREAM}/tar.gz/${sha}" -o "${WORK}/src.tgz" \
    || die "could not fetch ${UPSTREAM} at ${sha}"
  mkdir -p "${WORK}/src" "${WORK}/tree"
  tar -xzf "${WORK}/src.tgz" -C "${WORK}/src" --strip-components=1
  [[ -f "${WORK}/src/zeek/__load__.zeek" ]] \
    || die "${sha} has no zeek/__load__.zeek: not the package layout this script knows"
  cp -R "${WORK}/src/zeek/." "${WORK}/tree/"
  rm -rf "${WORK}/tree/tests"
  for f in LICENSE LICENSE-JA4 zkg.meta; do
    [[ -f "${WORK}/src/${f}" ]] || die "${sha} has no ${f}: the licence terms this was vendored under may have changed"
    cp "${WORK}/src/${f}" "${WORK}/tree/${f}"
  done
}

if [[ "${1:-}" == "--check" ]]; then
  [[ -f "${DEST}/VENDORED" ]] || die "nothing vendored at ${DEST}"
  # NOTICE is ours and excluded from the diff below, so check it is there
  # first. Without it, deleting the one statement the FoxIO License asks for
  # would still read as a clean match.
  [[ -s "${DEST}/NOTICE" ]] || die "${DEST}/NOTICE is missing or empty: the FoxIO License requires the notice"
  sha="$(awk '/^commit:/ {print $2}' "${DEST}/VENDORED")"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "VENDORED names no commit"
  fetch "${sha}"
  excludes=()
  for f in "${OURS[@]}"; do excludes+=(-x "${f}"); done
  if diff -r "${excludes[@]}" "${WORK}/tree" "${DEST}"; then
    printf 'vendored ja4 matches %s@%s\n' "${UPSTREAM}" "${sha}"
    exit 0
  fi
  die "the vendored tree differs from ${UPSTREAM}@${sha}"
fi

sha="${1:-}"
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] \
  || die "usage: scripts/vendor-ja4.sh <40-char commit sha> | --check — a tag or branch moves, a full SHA does not"

# NOTICE first, before anything is fetched or replaced: a re-vendor with no
# NOTICE would produce a tree that is out of licence, so it refuses instead.
[[ -s "${DEST}/NOTICE" ]] \
  || die "${DEST}/NOTICE is missing or empty. Write it before vendoring: the FoxIO License requires it"

fetch "${sha}"
cp "${DEST}/NOTICE" "${WORK}/tree/NOTICE"
cat > "${WORK}/tree/VENDORED" <<VENDORED
# Vendored by scripts/vendor-ja4.sh. Do not edit the files beside this one by
# hand: re-vendor instead, so the diff is upstream's (ADR-0069).
upstream: https://github.com/${UPSTREAM}
commit: ${sha}
vendored: $(date -u +%Y-%m-%d)
VENDORED

rm -rf "${DEST}"
mkdir -p "$(dirname "${DEST}")"
cp -R "${WORK}/tree" "${DEST}"
printf 'vendored %s@%s into %s\n' "${UPSTREAM}" "${sha}" "${DEST#"${REPO}"/}"
git -C "${REPO}" status --short -- "${DEST}" | head -20
