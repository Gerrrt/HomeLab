#!/usr/bin/env bash
#
# Put the agent installers into the directory the SOC stack's caddy service
# (container soc-agent-msi) serves on :8448: the two MSIs roles/soc_agents
# fetches (#1068), and the two Debian packages garuda installs (ADR-0092). Run on odin, as root, from the
# repository checkout, after `make up STACK=soc` and after any bump of either
# pin in ansible/roles/soc_agents/defaults/main.yml or stacks/soc/linux-agents.yaml,
# and after the Velociraptor server's image is bumped.
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
# AND FOR GARUDA, the same two as Debian packages:
#   Wazuh         the vendor's .deb from its apt pool, pinned by version and
#                 sha256 in stacks/soc/linux-agents.yaml.
#   Velociraptor  a .deb the server builds: its client config, dumped with
#                 `config client`, packaged with the server's own binary by
#                 `debian client`, so the client is the server's version. A
#                 build is not byte-reproducible, so it has no pin; one already
#                 staged for the running server's version is kept rather than
#                 rebuilt, and its sha256 is printed here. garuda's runbook
#                 checks the downloaded file against that hash.
#
# The MSIs are written as <name>-<version>.msi and the packages as
# <name>_<version>_amd64.deb, mode 0644, and anything else in the directory is
# removed. All four are fetched or built and verified before any is moved in,
# so a failed run leaves the last good set being served.
#
# Usage: sudo scripts/stage-agent-msis.sh
set -euo pipefail

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS="${REPO}/ansible/roles/soc_agents/defaults/main.yml"
LINUX_PINS="${REPO}/stacks/soc/linux-agents.yaml"
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
WAZUH_DEB_BASE="${WAZUH_DEB_BASE:-https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent}"
VELO_CONTAINER="${VELO_CONTAINER:-soc-velociraptor}"

[[ ${EUID} -eq 0 ]] || die "run as root: the Velociraptor datastore is root's"
[[ -f "${DEFAULTS}" ]] || die "no ${DEFAULTS}; run from the repository checkout"
[[ -f "${LINUX_PINS}" ]] || die "no ${LINUX_PINS}; run from the repository checkout"
command -v docker >/dev/null || die "docker is required, to build the Velociraptor .deb"
command -v curl >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

# A top-level `key: "value"` from a pins file (the role's defaults unless
# named), quotes stripped.
pin() {
  local v file="${2:-${DEFAULTS}}"
  v="$(sed -nE "s/^$1:[[:space:]]*\"?([^\"#[:space:]]+)\"?.*$/\1/p" "${file}")"
  [[ -n "${v}" ]] || die "no $1 in ${file}"
  printf '%s' "${v}"
}

wazuh_version="$(pin soc_agents_wazuh_version)"
wazuh_sha="$(pin soc_agents_wazuh_msi_sha256)"
velo_version="$(pin soc_agents_velociraptor_version)"
velo_sha="$(pin soc_agents_velociraptor_msi_sha256)"
wazuh_deb_version="$(pin wazuh_agent_deb_version "${LINUX_PINS}")"
wazuh_deb_sha="$(pin wazuh_agent_deb_sha256 "${LINUX_PINS}")"

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

wazuh_deb="wazuh-agent_${wazuh_deb_version}_amd64.deb"
info "Wazuh ${wazuh_deb_version} for Debian, from ${WAZUH_DEB_BASE}"
curl -fsSL --proto '=https' -o "${stage}/${wazuh_deb}" \
  "${WAZUH_DEB_BASE}/wazuh-agent_${wazuh_deb_version}-1_amd64.deb" \
  || die "could not fetch wazuh-agent_${wazuh_deb_version}-1_amd64.deb"
got="$(sha256sum "${stage}/${wazuh_deb}" | cut -d' ' -f1)"
[[ "${got}" == "${wazuh_deb_sha}" ]] \
  || die "wazuh-agent_${wazuh_deb_version}-1_amd64.deb is ${got}, linux-agents.yaml pins ${wazuh_deb_sha}"
ok "${wazuh_deb} matches the pin"

# The server's own version names the client it builds.
velo_server_version="$(docker exec "${VELO_CONTAINER}" velociraptor version 2>/dev/null \
  | sed -nE 's/^version:[[:space:]]*([0-9][0-9.]*).*/\1/p')"
[[ -n "${velo_server_version}" ]] || die "could not read the Velociraptor server's version from ${VELO_CONTAINER}"
velo_deb="velociraptor-client_${velo_server_version}_amd64.deb"
if [[ -f "${OUT}/${velo_deb}" ]]; then
  info "Velociraptor ${velo_server_version} for Debian: keeping the one already staged"
  cp "${OUT}/${velo_deb}" "${stage}/${velo_deb}"
else
  info "Velociraptor ${velo_server_version} for Debian: building it in ${VELO_CONTAINER}"
  # The client config holds the CA and the enrolment nonce, so it is written
  # inside the container, packaged there, and removed there.
  docker exec "${VELO_CONTAINER}" sh -c '
    set -e
    d=$(mktemp -d)
    trap "rm -rf \"$d\"" EXIT
    velociraptor --config /etc/velociraptor/server.config.yaml config client > "$d/client.config.yaml"
    mkdir "$d/out"
    velociraptor --config "$d/client.config.yaml" --nobanner debian client --output "$d/out/" >/dev/null 2>&1
    set -- "$d"/out/*.deb
    [ "$#" -eq 1 ] && [ -f "$1" ]
    cat "$1"' > "${stage}/${velo_deb}" \
    || die "the Velociraptor server could not build its Debian client"
fi
# Kept or built, the same checks before it is served and its hash printed: an
# empty or corrupt file kept from an earlier run must not be republished as
# the one garuda checks against. A failure here leaves the staged one in place;
# delete it from ${OUT} to have the next run rebuild it.
[[ -s "${stage}/${velo_deb}" ]] || die "${velo_deb} is empty"
dpkg-deb --field "${stage}/${velo_deb}" Package Version >/dev/null 2>&1 \
  || die "${velo_deb} is not a Debian package"
[[ "$(dpkg-deb --field "${stage}/${velo_deb}" Version)" == "${velo_server_version}" ]] \
  || die "${velo_deb} is not version ${velo_server_version} inside"
velo_deb_sha="$(sha256sum "${stage}/${velo_deb}" | cut -d' ' -f1)"
ok "${velo_deb}, sha256 ${velo_deb_sha}"

# The directory itself stays: the caddy service bind-mounts it, and a bind
# mount holds the directory it was given, so a directory moved into its place
# would never be seen. Each file is renamed in, which is atomic on one
# filesystem, and only then is everything else in it removed, hidden entries
# and directories included: whatever is left there is served.
install -d -m 0755 "${OUT}"
chmod 0644 "${stage}"/*.msi "${stage}"/*.deb
for f in "${stage}"/*.msi "${stage}"/*.deb; do
  mv -f "${f}" "${OUT}/"
done
find "${OUT}" -mindepth 1 -maxdepth 1 \
  ! -name "wazuh-agent-${wazuh_version}.msi" \
  ! -name "velociraptor-client-${velo_version}.msi" \
  ! -name "${wazuh_deb}" \
  ! -name "${velo_deb}" \
  -exec rm -rf -- {} +
ok "staged in ${OUT}: wazuh-agent-${wazuh_version}.msi velociraptor-client-${velo_version}.msi ${wazuh_deb} ${velo_deb}"
