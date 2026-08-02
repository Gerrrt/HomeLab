#!/usr/bin/env bash
#
# Pin every compose image to an immutable digest.
#
# A tag is a mutable pointer. `prom/prometheus:v3.13.2` is whatever the
# publisher last pushed under that name — a tag can be moved, and a compromised
# or coerced publisher can move it silently. A digest is the content hash: it
# either matches or the pull fails.
#
# Images are written as `repo:tag@sha256:...`, keeping both. The tag stays
# human-readable and tells you which version you are on at a glance; the digest
# is what Docker actually enforces. Dependabot understands this form and updates
# both halves together.
#
# Resolves through the registry HTTP API rather than `docker pull`, so it works
# without a daemon and without downloading hundreds of megabytes of layers.
#
# Usage:
#   scripts/pin-digests.sh            # report drift, change nothing
#   scripts/pin-digests.sh --write    # update compose.yaml in place

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_FILE:-${REPO_ROOT}/stacks/observability/compose.yaml}"
WRITE=0
[[ "${1:-}" == "--write" ]] && WRITE=1

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

[[ -f "${COMPOSE}" ]] || die "no compose file at ${COMPOSE}"
command -v curl >/dev/null 2>&1 || die "curl is required"

# Resolve repo:tag to its manifest digest.
#
# Accepts all four media types: multi-arch images return an OCI index or a
# Docker manifest list, single-arch ones return a plain manifest. Omitting any
# of these makes the registry return a 404 or the wrong digest for some images.
resolve_digest() {
  local repo="$1" tag="$2" token digest

  # Official images live under library/ but are written without it.
  [[ "${repo}" == */* ]] || repo="library/${repo}"

  token="$(curl -sS --fail --max-time 30 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')" \
    || { printf 'could not get a pull token for %s\n' "${repo}" >&2; return 1; }

  digest="$(curl -sS --fail --max-time 30 -I \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')" \
    || { printf 'manifest request failed for %s:%s\n' "${repo}" "${tag}" >&2; return 1; }

  [[ "${digest}" == sha256:* ]] || { printf 'no digest returned for %s:%s\n' "${repo}" "${tag}" >&2; return 1; }
  printf '%s\n' "${digest}"
}

mapfile -t refs < <(awk '$1 == "image:" { print $2 }' "${COMPOSE}")
((${#refs[@]} > 0)) || die "no image: lines found in ${COMPOSE}"

changed=0
declare -a updates=()

for ref in "${refs[@]}"; do
  repo_tag="${ref%%@*}"
  current_digest=""
  [[ "${ref}" == *@* ]] && current_digest="${ref##*@}"

  repo="${repo_tag%:*}"
  tag="${repo_tag##*:}"
  [[ "${repo}" != "${tag}" ]] || die "image ${ref} has no tag — refusing to pin a floating reference"

  if ! digest="$(resolve_digest "${repo}" "${tag}")"; then
    die "could not resolve ${repo}:${tag}"
  fi

  if [[ "${current_digest}" == "${digest}" ]]; then
    printf '  \033[0;32mok\033[0m       %s\n' "${repo_tag}"
  elif [[ -z "${current_digest}" ]]; then
    printf '  \033[0;33munpinned\033[0m %s -> %s\n' "${repo_tag}" "${digest}"
    updates+=("${ref}|${repo_tag}@${digest}")
    changed=1
  else
    printf '  \033[0;31mDRIFT\033[0m    %s\n           pinned:   %s\n           registry: %s\n' \
      "${repo_tag}" "${current_digest}" "${digest}"
    updates+=("${ref}|${repo_tag}@${digest}")
    changed=1
  fi
done

if ((changed == 0)); then
  printf '\n\033[0;32mall images pinned to their current digest\033[0m\n'
  exit 0
fi

if ((WRITE == 0)); then
  printf '\n%s image(s) need pinning. Re-run with --write to apply.\n' "${#updates[@]}"
  # Non-zero so CI can use this as a drift check.
  exit 1
fi

for u in "${updates[@]}"; do
  old="${u%%|*}"; new="${u##*|}"
  # Fixed-string replace via python: digests contain no regex metacharacters,
  # but repo names contain / and . which sed would need escaping for.
  python3 - "${COMPOSE}" "${old}" "${new}" <<'PY'
import sys, pathlib
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
text = p.read_text(encoding="utf-8")
if old not in text:
    sys.exit(f"expected to find {old} in {path}")
p.write_text(text.replace(old, new), encoding="utf-8")
PY
done

info "updated ${#updates[@]} image reference(s) in $(basename "${COMPOSE}")"
printf '\033[0;33mReview the diff, then re-run make validate.\033[0m\n'
