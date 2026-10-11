#!/usr/bin/env bash
#
# The entrypoint of the wazuh.certs-generator service (stacks/soc, stacks/scratch):
# mint the SOC's mTLS CA and leaves with the VENDORED Wazuh cert tool, offline,
# and refuse a tool whose sha256 is not the one VENDORED records (#1008, ADR-0093).
#
# WHAT IT REPLACES. The image's /entrypoint.sh downloads the tool at run time
# from packages.wazuh.com, with no checksum, falls back silently to
# packages-dev.wazuh.com if that fails, and sources whatever arrived, as root,
# with /certificates mounted. This does what that script does AFTER the
# download, the same steps in the same order, and does no download at all. The
# service runs with `network_mode: none`, so there is no network to fall back to.
#
# Runs inside wazuh/wazuh-certs-generator (Amazon Linux 2023, bash, openssl),
# mounted at /wazuh-certs-mint.sh. It must sit at / because the tool takes its
# base_path from $0, the script that sources it, and reads ${base_path}/config.yml
# and writes ${base_path}/wazuh-certificates, as it did under the image's own
# /entrypoint.sh. /certs-tool is stacks/soc/wazuh/certs-tool, read-only.
#
# Usage (by compose, never by hand on a host):
#   docker compose -f stacks/soc/compose.yaml --profile certs run --rm wazuh.certs-generator
#   scripts/wazuh-certs-mint.sh --self-test     the hash refusal, against fake tools
set -uo pipefail

CERTS_TOOL_DIR="${CERTS_TOOL_DIR:-/certs-tool}"
TOOL="wazuh-certs-tool.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# verify DIR: 0 if DIR/wazuh-certs-tool.sh's sha256 is DIR/VENDORED's, else why not.
verify() {
  local dir="$1" want have
  [[ -f "${dir}/VENDORED" ]] || { echo "no VENDORED in ${dir}"; return 1; }
  [[ -f "${dir}/${TOOL}" ]] || { echo "no ${TOOL} in ${dir}"; return 1; }
  want="$(awk '$1 == "sha256:" {print $2; exit}' "${dir}/VENDORED")"
  [[ "${want}" =~ ^[0-9a-f]{64}$ ]] || { echo "VENDORED records no sha256"; return 1; }
  have="$(sha256sum "${dir}/${TOOL}" | cut -d' ' -f1)"
  [[ "${have}" == "${want}" ]] || { echo "${TOOL} is ${have}, VENDORED pins ${want}"; return 1; }
  echo "${want}"
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  ok()  { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
  bad() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; fail=1; }
  case_() {  # <want 0|1> <what> — against ${T}/d as it stands
    local rc=0
    verify "${T}/d" >/dev/null || rc=$?
    if ((rc == $1)); then ok "$2"; else bad "$2 (rc ${rc}, wanted $1)"; fi
  }
  mkdir -p "${T}/d"
  printf '#!/bin/bash\necho tool\n' > "${T}/d/${TOOL}"
  sum="$(sha256sum "${T}/d/${TOOL}" | cut -d' ' -f1)"
  printf 'url: https://example.invalid/%s\nsha256: %s\n' "${TOOL}" "${sum}" > "${T}/d/VENDORED"
  case_ 0 "the tool VENDORED pins passes"
  printf '\n' >> "${T}/d/${TOOL}"
  case_ 1 "one byte added to the tool refuses"
  printf '#!/bin/bash\necho tool\n' > "${T}/d/${TOOL}"
  printf 'sha256: %s\n' "${sum^^}" > "${T}/d/VENDORED"
  case_ 1 "a hash that is not lowercase hex refuses rather than half-matching"
  printf 'url: x\n' > "${T}/d/VENDORED"
  case_ 1 "a VENDORED with no sha256 refuses"
  command rm -f "${T}/d/VENDORED"
  case_ 1 "no VENDORED at all refuses"
  printf 'sha256: %s\n' "${sum}" > "${T}/d/VENDORED"
  command rm -f "${T}/d/${TOOL}"
  case_ 1 "no tool at all refuses"
  # The repository's own vendored copy, as the service will see it.
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if verify "${repo}/stacks/soc/wazuh/certs-tool" >/dev/null; then
    ok "the vendored tool in stacks/soc/wazuh/certs-tool matches its VENDORED"
  else
    bad "the vendored tool does not match its VENDORED: $(verify "${repo}/stacks/soc/wazuh/certs-tool")"
  fi
  exit "${fail}"
fi

[[ "$0" == "/wazuh-certs-mint.sh" ]] \
  || die "run by the certs profile in compose, mounted at /wazuh-certs-mint.sh, not as $0"

if ! pinned="$(verify "${CERTS_TOOL_DIR}")"; then
  die "refusing to mint: ${pinned}. Re-vendor with scripts/vendor-wazuh-certs-tool.sh, read the diff, and commit both files together."
fi
echo "Wazuh cert tool sha256 ${pinned}, as VENDORED pins. Minting offline."

# From here, the image's /entrypoint.sh after its download step (wazuh-docker,
# GPLv2), with its paths. The vendored tool isn't written for `set -u`.
set +u
cp /config/certs.yml /config.yml || die "no /config/certs.yml mounted"

## Execute cert tool and parse cert.yml to set UID permissions
# shellcheck source=/dev/null
source "${CERTS_TOOL_DIR}/${TOOL}" -A
nodes_server=$(cert_parseYaml /config.yml | grep -E "nodes[_]+server[_]+[0-9]+=" | sed -e 's/nodes__server__[0-9]=//' | sed 's/"//g')
# Every name, one per line, as upstream's unquoted `node_names=($nodes_server)`
# splits them. A plain `read -a` would stop at the first newline.
read -r -d '' -a node_names <<< "${nodes_server}" || true

compgen -G "/wazuh-certificates/*" >/dev/null || die "the tool wrote no certificates to /wazuh-certificates"

echo "Moving created certificates to the destination directory"
cp /wazuh-certificates/* /certificates/ || die "could not copy into /certificates"
echo "Changing certificate permissions"
chmod -R 500 /certificates
chmod -R 400 /certificates/*
echo "Setting UID indexer and dashboard"
chown 1000:1000 /certificates/*
echo "Setting UID for wazuh manager and worker"
cp /certificates/root-ca.pem /certificates/root-ca-manager.pem
cp /certificates/root-ca.key /certificates/root-ca-manager.key
chown 999:999 /certificates/root-ca-manager.pem
chown 999:999 /certificates/root-ca-manager.key

for i in "${node_names[@]}"; do
  chown 999:999 "/certificates/${i}.pem"
  chown 999:999 "/certificates/${i}-key.pem"
done
