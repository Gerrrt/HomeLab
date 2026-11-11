#!/usr/bin/env bash
#
# Print the commands that put repository files on smaug, pinned and verified.
#
# smaug (TrueNAS) has no checkout of this repository. build-the-nas.md used to
# `curl` its compose file and the root-run cron scripts straight from
# raw.githubusercontent.com/…/main/, so whatever `main` held at that second ran
# as root on the NAS, unreviewed and unrecorded (#1424). This is run on YOUR
# machine, in a checkout of `main`, and prints a block to paste into the
# TrueNAS shell. Each file in it is fetched from one commit, not from `main`,
# and checked against a sha256 computed here, from the checkout you have read,
# before it replaces anything. A file that does not match is not installed.
#
# Usage:
#   scripts/smaug-fetch.sh [--dir D] PATH[:NAME]...    fetch commands
#   scripts/smaug-fetch.sh --verify [--dir D] PATH[:NAME]...
#                                    a command that checks what smaug has
#   scripts/smaug-fetch.sh --self-test
#
#   PATH is repository-relative. NAME is the file's name in D, by default
#   PATH's basename (stacks/media/.env.example:.env installs it as .env).
#   D defaults to /mnt/erebor/apps/stack. A .sh is made executable.
#
# It refuses a dirty tree, and a HEAD that is not on origin/main: the commit
# has to be one GitHub serves and one that went through review, or the URL it
# prints fetches something else or nothing.
#
# --verify is the drift check: it prints one `sha256sum -c` to run on smaug,
# which says OK or FAILED for each installed file against this checkout.
set -euo pipefail

REPO_SLUG="Gerrrt/HomeLab"
DIR="/mnt/erebor/apps/stack"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi \
    | cut -d' ' -f1
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# <rev> <dir> <spec>... -> the fetch block, on stdout
emit_fetch() {
  local rev="$1" dir="$2" spec path name sum
  shift 2
  printf 'cd %s \\\n' "${dir}"
  for spec in "$@"; do
    path="${spec%%:*}"
    name="$(basename "${path}")"
    [[ "${spec}" == *:* ]] && name="${spec#*:}"
    sum="$(sha256_of "${path}")"
    printf '  && curl -fsSL https://raw.githubusercontent.com/%s/%s/%s -o %s.new \\\n' \
      "${REPO_SLUG}" "${rev}" "${path}" "${name}"
    printf "  && echo '%s  %s.new' | sha256sum -c - \\\\\n" "${sum}" "${name}"
    printf '  && mv %s.new %s \\\n' "${name}" "${name}"
    [[ "${name}" == *.sh ]] && printf '  && chmod 0755 %s \\\n' "${name}"
  done
  printf "  && echo 'fetched from %s, every sha256 matched'\n" "${rev:0:12}"
}

# <dir> <spec>... -> the drift check, on stdout
emit_verify() {
  local dir="$1" spec path name
  shift
  printf 'cd %s && sha256sum -c - <<'"'"'EOF'"'"'\n' "${dir}"
  for spec in "$@"; do
    path="${spec%%:*}"
    name="$(basename "${path}")"
    [[ "${spec}" == *:* ]] && name="${spec#*:}"
    printf '%s  %s\n' "$(sha256_of "${path}")" "${name}"
  done
  printf 'EOF\n'
}

if [[ "${1:-}" == "--self-test" ]]; then
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  fail=0
  ok()  { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
  bad() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; fail=1; }
  mkdir -p "${T}/scripts" "${T}/stacks/media" "${T}/smaug"
  printf '#!/bin/sh\necho hi\n' > "${T}/scripts/a.sh"
  printf 'X=1\n' > "${T}/stacks/media/.env.example"
  cd "${T}"
  out="$(emit_fetch deadbeefcafe "${T}/smaug" scripts/a.sh stacks/media/.env.example:.env)"
  # Run the printed block against a stand-in curl that copies from here.
  # The stand-ins' own $1 and $# are meant literally, so single quotes.
  mkdir -p "${T}/bin"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nsrc=""; out=""\nwhile [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; -*) shift;; *) src="$1"; shift;; esac; done\ncp "%s/${src#*deadbeefcafe/}" "$out"\n' "${T}" > "${T}/bin/curl"
  chmod +x "${T}/bin/curl"
  if PATH="${T}/bin:${PATH}" bash -c "${out}" >/dev/null 2>&1 \
     && [[ -x "${T}/smaug/a.sh" && -f "${T}/smaug/.env" && ! -e "${T}/smaug/a.sh.new" ]]; then
    ok "the fetch block installs matching files, renames by NAME, and makes .sh executable"
  else
    bad "the fetch block did not install matching files"
  fi
  if [[ "${out}" == *"/deadbeefcafe/scripts/a.sh"* && "${out}" != *"/main/"* ]]; then
    ok "the URL names the commit, not main"
  else
    bad "the URL does not name the commit"
  fi
  printf 'tampered\n' > "${T}/smaug/a.sh"
  printf '#!/bin/sh\necho evil\n' > "${T}/evil"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nout=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done\ncp "%s/evil" "$out"\n' "${T}" > "${T}/bin/curl"
  if ! PATH="${T}/bin:${PATH}" bash -c "${out}" >/dev/null 2>&1 \
     && [[ "$(cat "${T}/smaug/a.sh")" == tampered ]]; then
    ok "a fetched file whose sha256 does not match is not installed"
  else
    bad "a mismatched file was installed"
  fi
  cp scripts/a.sh "${T}/smaug/a.sh"; cp stacks/media/.env.example "${T}/smaug/.env"
  v="$(emit_verify "${T}/smaug" scripts/a.sh stacks/media/.env.example:.env)"
  if bash -c "${v}" >/dev/null 2>&1; then ok "--verify passes files that match"; else bad "--verify failed matching files"; fi
  echo drift >> "${T}/smaug/a.sh"
  if ! bash -c "${v}" >/dev/null 2>&1; then ok "--verify fails a file that drifted"; else bad "--verify passed a drifted file"; fi
  exit "${fail}"
fi

VERIFY=0
specs=()
while (($#)); do
  case "$1" in
    --verify) VERIFY=1; shift ;;
    --dir) DIR="${2:?--dir needs a directory}"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^#   D defaults/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) specs+=("$1"); shift ;;
  esac
done
((${#specs[@]})) || die "no file named. Usage: $0 [--verify] [--dir D] PATH[:NAME]..."

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for spec in "${specs[@]}"; do
  [[ -f "${spec%%:*}" ]] || die "no such file in the repository: ${spec%%:*}"
done

if ((VERIFY)); then
  emit_verify "${DIR}" "${specs[@]}"
  exit 0
fi

[[ -z "$(git status --porcelain -- "${specs[@]%%:*}")" ]] \
  || die "uncommitted changes to a named file: the hash would describe what GitHub does not serve"
rev="$(git rev-parse HEAD)"
git fetch -q origin main 2>/dev/null || die "cannot fetch origin/main to check that HEAD is published"
git merge-base --is-ancestor "${rev}" origin/main \
  || die "HEAD ${rev:0:12} is not on origin/main: fetch from a reviewed, published commit"
emit_fetch "${rev}" "${DIR}" "${specs[@]}"
