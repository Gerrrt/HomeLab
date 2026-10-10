#!/usr/bin/env bash
#
# Scan every pinned image in every stack for fixable HIGH and CRITICAL CVEs.
#
# A digest says which bytes run; it says nothing about whether those bytes are
# safe. digests.yml checks the first claim weekly, and until #852 nothing checked
# the second: Dependabot moves a tag when upstream releases, and is silent about
# a digest that has carried a fixed CVE for a month because no release came.
#
# This is the scan half. It writes one trivy JSON report per image into --out,
# and scripts/cve_report.py turns those into a job summary and issues. The split
# keeps every `docker run` in shell, where scripts/check_image_pins.py can trace
# its image back to image-for.sh, and keeps the issue logic in something that
# can be self-tested.
#
# What is scanned
# ---------------
# Every `image:` line in every compose.yaml that scripts/stacks.sh lists —
# profiled tooling included, because a linter image runs in CI with a token in
# reach — deduplicated, so caddy pinned in three stacks is scanned once and
# reported against all three. A reference without a digest is refused: the scan
# is a statement about what is deployed, and a tag is not that.
#
# How
# ---
# trivy, pinned in stacks/observability/compose.yaml, with --image-src remote:
# it reads manifest and layers from the registry by digest, so nothing is
# pulled into the daemon, the same way pin-digests.sh needs no daemon. The
# vulnerability database is fetched once before the loop, from ghcr.io with
# public.ecr.aws as the fallback, and every scan then runs with
# --skip-db-update, so fifty scans do not mean fifty downloads.
#
# --ignore-unfixed is the filter, and it is the point: a finding with a fixed
# version is one a bump closes. There is deliberately no ignore file —
# see the .gitleaksignore argument in scripts/check_docs.py. The one thing
# cve_report.py drops is a shape of version, not a list of IDs: a Go main
# module's `+dirty` VCS stamp, which trivy cannot order against a release
# (#985). Its docstring says why that cannot grow into one. The one file
# skipped is gosu in postgres, named in the loop below with why (#995).
#
# An image that fails to scan is recorded and the loop carries on, and the
# script exits non-zero at the end. A skipped image must not read as a clean
# one.
#
# Usage:
#   scripts/scan-images.sh [--out DIR] [--cache DIR] [--extra REF]
#
#   --out DIR     where reports go (default: .scan/ in the repo, gitignored)
#   --cache DIR   trivy's cache, i.e. the database (default: ~/.cache/trivy)
#   --extra REF   also scan REF, reported under the pseudo-stack `test`. This
#                 is how a known-vulnerable image proves the issue path works.
#
# Writes DIR/images.tsv (index, reference, comma-separated stacks) and, per
# image, DIR/<index>.json or DIR/<index>.err.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/.scan"
CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/trivy"
EXTRA=""

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*" >&2; }

while (($#)); do
  case "$1" in
    --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
    --cache) CACHE="${2:?--cache needs a directory}"; shift 2 ;;
    --extra) EXTRA="${2:-}"; shift 2 ;;
    -h | --help) sed -n '45,54p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "docker is required"

TRIVY_IMAGE="$("${REPO_ROOT}/scripts/image-for.sh" trivy)"
DB_REPOS='ghcr.io/aquasecurity/trivy-db:2,public.ecr.aws/aquasecurity/trivy-db:2'
JAVA_DB_REPOS='ghcr.io/aquasecurity/trivy-java-db:1,public.ecr.aws/aquasecurity/trivy-java-db:1'

# --out is cleared of the previous run's reports, so it must be a directory
# this script owns: empty, new, or carrying the marker an earlier run left. A
# directory with anything else in it is refused rather than cleaned, because
# `--out ~/somewhere` must not cost someone their settings.json.
MARKER=".scan-images"
if [[ -d "${OUT}" && ! -e "${OUT}/${MARKER}" ]] && [[ -n "$(ls -A "${OUT}")" ]]; then
  die "${OUT} is not empty and was not written by this script; pick a new --out"
fi
mkdir -p "${OUT}" "${CACHE}"
touch "${OUT}/${MARKER}"
# Only the names this script writes: images.tsv and NNN.json / NNN.err.
for f in "${OUT}"/*; do
  [[ "${f##*/}" =~ ^(images\.tsv|[0-9]{3,}\.(json|err))$ ]] && rm -f -- "${f}"
done

# reference -> comma-separated stacks, in first-seen order. Same awk as
# pin-digests.sh, quote stripping included.
declare -A stacks_of=()
declare -a order=()
add() {
  local ref="$1" stack="$2"
  if [[ -z "${stacks_of[${ref}]+x}" ]]; then
    order+=("${ref}")
    stacks_of[${ref}]="${stack}"
  elif [[ ",${stacks_of[${ref}]}," != *",${stack},"* ]]; then
    stacks_of[${ref}]+=",${stack}"
  fi
}

# Captured first, not read from a process substitution: stacks.sh prints the
# good stacks before failing on a malformed one, and `< <(...)` would discard
# that failure and scan an incomplete list as if it were complete.
stack_paths="$("${REPO_ROOT}/scripts/stacks.sh" --paths)" || die "scripts/stacks.sh failed; not scanning a partial list"

unpinned=()
while read -r sd; do
  stack="${sd#stacks/}"
  while read -r ref; do
    [[ "${ref}" == *@sha256:* ]] || { unpinned+=("${stack}: ${ref}"); continue; }
    add "${ref}" "${stack}"
  done < <(awk '
    $1 == "image:" {
      v = $2
      sub(/^"/, "", v); sub(/"$/, "", v)
      sub(/^\047/, "", v); sub(/\047$/, "", v)
      if (v != "") print v
    }
  ' "${REPO_ROOT}/${sd}/compose.yaml")
done <<<"${stack_paths}"

((${#unpinned[@]} == 0)) || die "refusing to scan unpinned references: ${unpinned[*]}"
((${#order[@]} > 0)) || die "no image: lines found under stacks/"

if [[ -n "${EXTRA}" ]]; then
  [[ "${EXTRA}" == *@sha256:* ]] || die "--extra ${EXTRA} has no digest; pin it as compose.yaml would"
  add "${EXTRA}" "test"
fi

# --user keeps the cache and reports owned by whoever ran this, not root.
trivy() {
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "${CACHE}:/cache" "${TRIVY_IMAGE}" "$@" --cache-dir /cache
}

info "trivy: ${TRIVY_IMAGE}"
info "updating the vulnerability databases"
trivy image --quiet --download-db-only --db-repository "${DB_REPOS}"
trivy image --quiet --download-java-db-only --java-db-repository "${JAVA_DB_REPOS}"

failed=0
i=0
for ref in "${order[@]}"; do
  i=$((i + 1))
  n="$(printf '%03d' "${i}")"
  printf '%s\t%s\t%s\n' "${n}" "${ref}" "${stacks_of[${ref}]}" >>"${OUT}/images.tsv"
  info "[${i}/${#order[@]}] ${ref%%@*}"
  # The one skipped file (#995): gosu in the official postgres image. Its Go
  # stdlib rows have no fix to take: gosu's maintainers don't release for
  # scanner-only CVEs, and docker-library changes gosu only when gosu releases.
  # It can't be reached here either: every postgres service starts as
  # 999:999, which check_compose_health.py enforces, and the entrypoint runs
  # gosu only when started as root. Skipped for postgres alone, so gosu
  # anywhere else is still reported. A second exception means a rule both
  # can cite, not another case here.
  skip=()
  [[ "${ref}" == postgres:* ]] && skip=(--skip-files usr/local/bin/gosu)
  if ! trivy image --quiet --image-src remote --platform linux/amd64 \
      --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed "${skip[@]}" \
      --skip-db-update --skip-java-db-update --format json "${ref}" \
      >"${OUT}/${n}.json" 2>"${OUT}/${n}.err"; then
    rm -f "${OUT}/${n}.json"
    printf '  \033[0;31mscan failed\033[0m: %s\n' "$(tail -n 1 "${OUT}/${n}.err")" >&2
    failed=$((failed + 1))
    continue
  fi
  rm -f "${OUT}/${n}.err"
done

info "scanned ${i} image(s) into ${OUT}"
((failed == 0)) || die "${failed} image(s) could not be scanned; see ${OUT}/*.err"
