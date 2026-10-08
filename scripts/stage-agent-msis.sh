#!/usr/bin/env bash
#
# Put the two installers roles/soc_agents fetches into the directory the SOC
# stack's caddy service (container soc-agent-msi) serves (#1068). Run on odin, as root, from the
# repository checkout, after `make up STACK=soc` and after any bump of either
# pin in ansible/roles/soc_agents/defaults/main.yml.
#
# WHY A SCRIPT. The role pins each MSI by version and sha256, and installs only
# a file whose hash matches. The file has to be on odin under the same name the
# role asks for, or the next rebuild stops at `--tags soc`, which is how #448's
# did. Reading the pins from the role's own defaults keeps one copy of them: a
# bump there is a bump here, and an MSI that no longer matches is refused here
# rather than at install time on six guests.
#
# WHAT IT STAGES, PER INSTALLER.
#   Wazuh         the vendor's MSI, fetched from packages.wazuh.com. It carries
#                 no secret; the enrolment password is the role's, at install.
#   Velociraptor  the MSI this guest's Velociraptor server repacked with the
#                 client config inside (Server.Utils.CreateMSI, build-the-soc-
#                 guest.md §11). It is found in the server's datastore by its
#                 hash, not its name, because the server keeps every MSI it ever
#                 built and their names carry the server's version, not the
#                 client's. If none matches, the pin and the server have moved
#                 apart, and that is for a person to settle.
#
# Each is written as <name>-<version>.msi, mode 0644, and anything else in the
# directory is removed. Both are fetched and verified before either is moved
# in, so a failed run leaves the last good pair being served.
#
# Usage: sudo scripts/stage-agent-msis.sh
set -euo pipefail

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS="${REPO}/ansible/roles/soc_agents/defaults/main.yml"
# The same SOC_DATA_DIR compose.yaml mounts: the environment if set, else the
# stack's rendered .env, else .env.example, which is what .env is rendered from.
# Run under plain `sudo`, nothing else would carry it, and a custom value would
# stage into one directory while the caddy service served another.
stack_setting() {
  local f
  for f in "${REPO}/stacks/soc/.env" "${REPO}/stacks/soc/.env.example"; do
    [[ -f "${f}" ]] || continue
    sed -nE "s/^$1=[\"']?([^\"'#[:space:]]+)[\"']?.*$/\1/p" "${f}" | tail -n1
    return 0
  done
}
DATA="${SOC_DATA_DIR:-$(stack_setting SOC_DATA_DIR)}"
DATA="${DATA:-/srv/soc-data}"
OUT="${DATA}/agent-msi"
DATASTORE="${DATA}/velociraptor"
WAZUH_BASE="${WAZUH_MSI_BASE:-https://packages.wazuh.com/4.x/windows}"

[[ ${EUID} -eq 0 ]] || die "run as root: the Velociraptor datastore is root's"
[[ -f "${DEFAULTS}" ]] || die "no ${DEFAULTS}; run from the repository checkout"
command -v curl >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

# A top-level `key: "value"` from the role's defaults, quotes stripped.
pin() {
  local v
  v="$(sed -nE "s/^$1:[[:space:]]*\"?([^\"#[:space:]]+)\"?.*$/\1/p" "${DEFAULTS}")"
  [[ -n "${v}" ]] || die "no $1 in ${DEFAULTS}"
  printf '%s' "${v}"
}

wazuh_version="$(pin soc_agents_wazuh_version)"
wazuh_sha="$(pin soc_agents_wazuh_msi_sha256)"
velo_version="$(pin soc_agents_velociraptor_version)"
velo_sha="$(pin soc_agents_velociraptor_msi_sha256)"

stage="$(mktemp -d "${DATA}/.agent-msi.XXXXXX")"
trap 'rm -rf "${stage}"' EXIT

info "Wazuh ${wazuh_version}, from ${WAZUH_BASE}"
curl -fsSL --proto '=https' -o "${stage}/wazuh-agent-${wazuh_version}.msi" \
  "${WAZUH_BASE}/wazuh-agent-${wazuh_version}-1.msi" \
  || die "could not fetch wazuh-agent-${wazuh_version}-1.msi"
got="$(sha256sum "${stage}/wazuh-agent-${wazuh_version}.msi" | cut -d' ' -f1)"
[[ "${got}" == "${wazuh_sha}" ]] \
  || die "wazuh-agent-${wazuh_version}-1.msi is ${got}, the role pins ${wazuh_sha}"
ok "wazuh-agent-${wazuh_version}.msi matches the pin"

info "Velociraptor ${velo_version}, by hash, from ${DATASTORE}"
[[ -d "${DATASTORE}" ]] || die "no ${DATASTORE}: is the SOC stack up on this guest?"
found=""
while IFS= read -r -d '' f; do
  if [[ "$(sha256sum "${f}" | cut -d' ' -f1)" == "${velo_sha}" ]]; then
    found="${f}"
    break
  fi
done < <(find "${DATASTORE}" -type f -iname '*.msi' -print0)
[[ -n "${found}" ]] || die "no MSI in ${DATASTORE} has the pinned sha256 ${velo_sha}.
  Rebuild it with Server.Utils.CreateMSI (build-the-soc-guest.md §11) and move
  soc_agents_velociraptor_* in the role's defaults to what it built."
cp "${found}" "${stage}/velociraptor-client-${velo_version}.msi"
ok "velociraptor-client-${velo_version}.msi matches the pin (${found#"${DATASTORE}/"})"

# The directory itself stays: the caddy service bind-mounts it, and a bind
# mount holds the directory it was given, so a directory moved into its place
# would never be seen. Each file is renamed in, which is atomic on one
# filesystem, and only then is everything else in it removed, hidden entries
# and directories included: whatever is left there is served.
install -d -m 0755 "${OUT}"
chmod 0644 "${stage}"/*.msi
for f in "${stage}"/*.msi; do
  mv -f "${f}" "${OUT}/"
done
find "${OUT}" -mindepth 1 -maxdepth 1 \
  ! -name "wazuh-agent-${wazuh_version}.msi" \
  ! -name "velociraptor-client-${velo_version}.msi" \
  -exec rm -rf -- {} +
ok "staged in ${OUT}: wazuh-agent-${wazuh_version}.msi velociraptor-client-${velo_version}.msi"
