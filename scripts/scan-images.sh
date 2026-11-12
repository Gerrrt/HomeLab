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
# An image whose service is profiled `lint` or `scan` only is reported under
# the pseudo-stack `tooling`, not the stack whose compose.yaml pins it. Those
# are the linters and scanners CI and the Mac run (markdownlint, tofu, packer,
# gitleaks, trivy, ...); they are pinned in stacks/observability/compose.yaml
# so Dependabot sees them, and never run on prometheus. Reported under
# `observability`, their CVE issues said they did. cve_report.py labels
# `tooling` as `ci`. Every other profile (capture, backup, rip, ml, certs)
# runs on its stack's host, and keeps its stack.
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
# skipped is gosu, and only in the repositories scripts/gosu-skip.txt lists,
# under the rule that file states and two checks enforce (#995, #980).
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
#   --self-test   run the compose-reading fixtures, then exit (no docker)
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

# Every `image:` in a compose file, one per line as `<reference>\t<tool>`,
# where <tool> is 1 when the image's service is profiled `lint` or `scan` and
# nothing else, and 0 otherwise. A service's `profiles:` may come before or
# after its `image:` (gitleaks lists it first), so each service is held until
# the next one starts. Only the inline list form (`profiles: ["lint"]`) is read,
# which is the only form in this tree; any other form counts as not a tool, so a
# misread keeps an image under its stack rather than moving it. Quotes are
# stripped as pin-digests.sh strips them.
images_of() {
  awk '
    function flush() {
      if (img != "") print img "\t" ((prof != "" && tool) ? 1 : 0)
      img = ""; prof = ""; tool = 1
    }
    BEGIN { tool = 1 }
    /^[^[:space:]#]/ { flush(); in_services = ($0 ~ /^services:[[:space:]]*$/); next }
    in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { flush(); next }
    $1 == "image:" {
      v = $2
      sub(/^"/, "", v); sub(/"$/, "", v)
      sub(/^\047/, "", v); sub(/\047$/, "", v)
      if (v == "") next
      if (!in_services) { print v "\t0"; next }
      img = v; next
    }
    in_services && $1 == "profiles:" {
      line = $0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      if (line !~ /^\[.*\]/) { prof = "?"; tool = 0; next }
      gsub(/[][\"\047[:space:]]/, "", line)
      n = split(line, names, ",")
      prof = line
      for (k = 1; k <= n; k++) if (names[k] != "lint" && names[k] != "scan") tool = 0
      if (n == 0) tool = 0
      next
    }
    END { flush() }
  ' "$1"
}

self_test() {
  local dir failed=0 got want
  dir="$(mktemp -d)" || die "mktemp failed"
  trap 'rm -rf "${dir}"' RETURN
  ok() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
  bad() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; failed=1; }
  cat >"${dir}/compose.yaml" <<'YAML'
x-defaults: &defaults
  restart: unless-stopped

services:
  app:
    <<: *defaults
    image: "app:1@sha256:aa"
  gitleaks:
    profiles: ["scan"]
    image: zricethezav/gitleaks:v8@sha256:bb
  markdownlint:
    image: 'davidanson/markdownlint-cli2:v0@sha256:cc'
    profiles: ["lint"]
  capture:
    image: tcpdump:1@sha256:dd
    profiles: ["capture"]
  mixed:
    image: tool:1@sha256:ee
    profiles: ["lint", "backup"]
  block:
    image: other:1@sha256:ff
    profiles:
      - lint

volumes:
  data:
YAML
  got="$(images_of "${dir}/compose.yaml")"
  want="$(printf '%s\n' 'app:1@sha256:aa	0' 'zricethezav/gitleaks:v8@sha256:bb	1' \
    'davidanson/markdownlint-cli2:v0@sha256:cc	1' 'tcpdump:1@sha256:dd	0' \
    'tool:1@sha256:ee	0' 'other:1@sha256:ff	0')"
  check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
  check "a service with no profile keeps its stack" "$(sed -n 1p <<<"${got}")" "$(sed -n 1p <<<"${want}")"
  check "profiles before image: a scan tool" "$(sed -n 2p <<<"${got}")" "$(sed -n 2p <<<"${want}")"
  check "profiles after image: a lint tool, quotes stripped" "$(sed -n 3p <<<"${got}")" "$(sed -n 3p <<<"${want}")"
  check "a host-side profile keeps its stack" "$(sed -n 4p <<<"${got}")" "$(sed -n 4p <<<"${want}")"
  check "lint plus a host profile keeps its stack" "$(sed -n 5p <<<"${got}")" "$(sed -n 5p <<<"${want}")"
  check "a block-list profile is not read as a tool" "$(sed -n 6p <<<"${got}")" "$(sed -n 6p <<<"${want}")"
  check "every image is listed once, none outside services invented" "$(wc -l <<<"${got}" | tr -d ' ')" "6"
  return "${failed}"
}

while (($#)); do
  case "$1" in
    --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
    --cache) CACHE="${2:?--cache needs a directory}"; shift 2 ;;
    --extra) EXTRA="${2:-}"; shift 2 ;;
    --self-test) self_test; exit $? ;;
    -h | --help) sed -n '55,65p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  while IFS=$'\t' read -r ref tool; do
    [[ "${ref}" == *@sha256:* ]] || { unpinned+=("${stack}: ${ref}"); continue; }
    if ((tool)); then add "${ref}" "tooling"; else add "${ref}" "${stack}"; fi
  done < <(images_of "${REPO_ROOT}/${sd}/compose.yaml")
done <<<"${stack_paths}"

((${#unpinned[@]} == 0)) || die "refusing to scan unpinned references: ${unpinned[*]}"
((${#order[@]} > 0)) || die "no image: lines found under stacks/"

if [[ -n "${EXTRA}" ]]; then
  [[ "${EXTRA}" == *@sha256:* ]] || die "--extra ${EXTRA} has no digest; pin it as compose.yaml would"
  add "${EXTRA}" "test"
fi

# --user keeps the cache and reports owned by whoever ran this, not root.
# --network bridge: Trivy downloads its vulnerability databases below.
trivy() {
  docker run --network bridge --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "${CACHE}:/cache" "${TRIVY_IMAGE}" "$@" --cache-dir /cache
}

info "trivy: ${TRIVY_IMAGE}"
info "updating the vulnerability databases"
trivy image --quiet --download-db-only --db-repository "${DB_REPOS}"
trivy image --quiet --download-java-db-only --java-db-repository "${JAVA_DB_REPOS}"

# The repositories whose gosu is skipped, comments and blank lines removed.
GOSU_SKIP="$(grep -vE '^[[:space:]]*(#|$)' "${REPO_ROOT}/scripts/gosu-skip.txt")" \
  || die "scripts/gosu-skip.txt lists no repository"

failed=0
i=0
for ref in "${order[@]}"; do
  i=$((i + 1))
  n="$(printf '%03d' "${i}")"
  printf '%s\t%s\t%s\n' "${n}" "${ref}" "${stacks_of[${ref}]}" >>"${OUT}/images.tsv"
  info "[${i}/${#order[@]}] ${ref%%@*}"
  # The one skipped file: gosu, in a repository scripts/gosu-skip.txt lists
  # (#995, #980). That file states the rule: gosu runs only when the container
  # starts as root, and every service runs the image as 999:999.
  # check_compose_health.py enforces the second half and check_gosu_skip.sh
  # proves the first, on each pinned image. gosu in any other image is still
  # reported.
  skip=()
  name="${ref%%@*}"
  # A tag comes off only the last path component, so a registry port stays:
  # `registry:5000/postgres@sha256:…` is `registry:5000/postgres`, as in
  # check_compose_health.py's image_repository().
  [[ "${name##*/}" == *:* ]] && name="${name%:*}"
  if grep -qxF "${name}" <<<"${GOSU_SKIP}"; then
    skip=(--skip-files usr/local/bin/gosu)
  fi
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
