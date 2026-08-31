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
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# The registry a reference with no host in it means.
DEFAULT_REGISTRY='registry-1.docker.io'

# Accept all four media types: multi-arch images return an OCI index or a Docker
# manifest list, single-arch ones return a plain manifest. Omitting any of these
# makes the registry return a 404 or the wrong digest for some images.
ACCEPT=(
  -H 'Accept: application/vnd.oci.image.index.v1+json'
  -H 'Accept: application/vnd.oci.image.manifest.v1+json'
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json'
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json'
)

# Split an image reference into REF_HOST, REF_REPO and REF_TAG.
#
# `prom/prometheus:v3.14.0` and `ghcr.io/foo/bar:v1` look alike and are not.
# Docker's own rule is that the first path component is a registry host if it
# contains a dot or a colon, or is exactly `localhost` — that is the only thing
# separating the hostname `example.com` from the Hub namespace `library`, and
# there is no way to tell them apart without it.
#
# Everything downstream depends on this. The version this replaced assumed Hub
# unconditionally, so it read `ghcr.io` as a namespace, and it split the tag
# with `${ref%:*}`, which takes the last colon *anywhere* in the string — so
# `registry:5000/foo` lost its port and gained a tag named `5000/foo`.
parse_ref() {
  local ref="$1" first rest name

  # A digest already on the reference is the caller's business, not ours.
  ref="${ref%%@*}"
  first="${ref%%/*}"

  if [[ "${ref}" == */* ]] &&
     { [[ "${first}" == *.* ]] || [[ "${first}" == *:* ]] || [[ "${first}" == localhost ]]; }; then
    REF_HOST="${first}"
    rest="${ref#*/}"
  else
    REF_HOST="${DEFAULT_REGISTRY}"
    rest="${ref}"
    # Official images live under library/ but are written without it. This is a
    # Hub convention and only a Hub convention: a one-component repository on
    # any other registry is simply a one-component repository.
    [[ "${rest}" == */* ]] || rest="library/${rest}"
  fi

  # The tag is whatever follows the last colon, but only when that colon comes
  # after the last slash. Otherwise the colon belongs to a port.
  name="${rest##*/}"
  if [[ "${name}" == *:* ]]; then
    REF_TAG="${name##*:}"
    REF_REPO="${rest%:*}"
  else
    REF_TAG=""
    REF_REPO="${rest}"
  fi
}

# Resolve host/repo:tag to its manifest digest.
#
# Registries do not agree on how, or whether, to authenticate an anonymous pull,
# so this asks rather than assumes. The unauthenticated request is made first
# and the registry's own answer decides what happens next — which is the
# `WWW-Authenticate` handshake from the distribution spec, and needs no
# knowledge of any particular registry:
#
#   docker.io       401 + realm https://auth.docker.io/token
#   ghcr.io         401 + realm https://ghcr.io/token
#   quay.io         200, no challenge at all — a public pull needs no token
#   registry.k8s.io 307, so the request has to be followed
#
# quay.io is why the 401 branch is conditional rather than assumed, and
# registry.k8s.io is why `-L` is not optional. The version this replaced
# hardcoded auth.docker.io and registry-1.docker.io and did neither, so an image
# from anywhere else failed — silently making `make pin-digests`, the tool that
# enforces this repository's digest-pinning policy, unable to enforce it for a
# whole class of image (#80).
#
# `-I` throughout: the digest is a response header, and the manifest body can be
# megabytes.
resolve_digest() {
  local host="$1" repo="$2" tag="$3"
  local url headers status challenge realm service token_json token digest
  local -a token_args

  url="https://${host}/v2/${repo}/manifests/${tag}"

  headers="$(curl -sS -L -I --max-time 30 "${ACCEPT[@]}" "${url}" | tr -d '\r')" \
    || { printf 'manifest request failed for %s/%s:%s\n' "${host}" "${repo}" "${tag}" >&2; return 1; }

  # The last status line and the last challenge, not the first: -L means these
  # can carry a redirect's headers ahead of the ones that answer the question.
  status="$(awk '$1 ~ /^HTTP\// { s = $2 } END { print s }' <<<"${headers}")"

  if [[ "${status}" == 401 ]]; then
    challenge="$(awk 'tolower($1) == "www-authenticate:" { $1 = ""; c = $0 } END { print c }' <<<"${headers}")"
    realm="$(sed -n 's/.*[Rr]ealm="\([^"]*\)".*/\1/p' <<<"${challenge}")"
    service="$(sed -n 's/.*[Ss]ervice="\([^"]*\)".*/\1/p' <<<"${challenge}")"
    [[ -n "${realm}" ]] \
      || { printf '%s asked for authentication but named no realm: %s\n' "${host}" "${challenge}" >&2; return 1; }

    token_args=(-G "${realm}" --data-urlencode "scope=repository:${repo}:pull")
    # Some registries omit service= from the challenge; sending an empty one
    # back is not the same as omitting it.
    if [[ -n "${service}" ]]; then
      token_args+=(--data-urlencode "service=${service}")
    fi

    # curl and python3 are two statements rather than a pipeline on purpose. As
    # `$(curl ... | python3 ...)`, the `||` only ever sees python3's status, so
    # a registry that was down reported itself as a JSON parse failure — the one
    # error message guaranteed not to help.
    token_json="$(curl -sS --fail --max-time 30 "${token_args[@]}")" \
      || { printf 'could not reach the token endpoint %s for %s\n' "${realm}" "${repo}" >&2; return 1; }

    token="$(printf '%s' "${token_json}" | python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
except ValueError:
    sys.exit("the token endpoint did not return JSON")
tok = body.get("token") or body.get("access_token")
if not tok:
    sys.exit("the token endpoint returned JSON with no token in it")
print(tok)
')" || { printf 'no usable pull token from %s for %s\n' "${realm}" "${repo}" >&2; return 1; }

    headers="$(curl -sS -L -I --max-time 30 \
      -H "Authorization: Bearer ${token}" "${ACCEPT[@]}" "${url}" | tr -d '\r')" \
      || { printf 'authenticated manifest request failed for %s/%s:%s\n' "${host}" "${repo}" "${tag}" >&2; return 1; }
  fi

  # Last value wins, for the same redirect reason as the status above.
  digest="$(awk 'tolower($1) == "docker-content-digest:" { d = $2 } END { print d }' <<<"${headers}")"

  [[ "${digest}" == sha256:* ]] \
    || { printf 'no digest returned for %s/%s:%s (HTTP %s)\n' "${host}" "${repo}" "${tag}" "${status:-?}" >&2; return 1; }
  printf '%s\n' "${digest}"
}

# `image:` values, unquoted. $2 already drops a trailing comment, since awk
# splits on whitespace and the comment is a later field; the quote stripping is
# for `image: "repo:tag"`, which YAML permits and this file does not currently
# use. \047 is a single quote — spelling it that way keeps the awk program
# inside one pair of shell quotes.
mapfile -t refs < <(awk '
  $1 == "image:" {
    v = $2
    sub(/^"/, "", v); sub(/"$/, "", v)
    sub(/^\047/, "", v); sub(/\047$/, "", v)
    if (v != "") print v
  }
' "${COMPOSE}")
((${#refs[@]} > 0)) || die "no image: lines found in ${COMPOSE}"

changed=0
declare -a updates=()

for ref in "${refs[@]}"; do
  repo_tag="${ref%%@*}"
  current_digest=""
  [[ "${ref}" == *@* ]] && current_digest="${ref##*@}"

  parse_ref "${ref}"
  [[ -n "${REF_TAG}" ]] || die "image ${ref} has no tag — refusing to pin a floating reference"

  if ! digest="$(resolve_digest "${REF_HOST}" "${REF_REPO}" "${REF_TAG}")"; then
    die "could not resolve ${ref}"
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
