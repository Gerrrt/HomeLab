#!/usr/bin/env bash
#
# Pin the lab domain's SSH host keys for ansible/, read through the guest agent
# rather than learned over the network (#846, ADR-0082).
#
# WHY. ansible/ sends LAB_ADMIN_PASSWORD and LAB_DSRM_PASSWORD over SSH to
# guests on VLAN 30, a segment built to hold attackers and where ARP spoofing
# is expected (docs/security.md). With host keys unchecked, anything that
# answered for 10.0.30.50 would be handed the domain's Administrator password.
# Pinning on first use would not help either: every rebuild replaces the keys,
# so the first use is every use. The guest agent is a channel that does not
# cross the segment. Proxmox reads the file from inside the guest, and phoenix
# asks Proxmox over verified TLS. So the keys are read again after every
# rebuild, and a key the network presents is checked against them.
#
# WHAT IT DOES. For each host in ansible/inventory/hosts.yaml it finds the
# guest of that name in /cluster/resources and reads
# C:\ProgramData\ssh\ssh_host_ed25519_key.pub through agent/file-read. It
# writes "<ansible_host> <type> <key>" to ansible/.known_hosts, which
# group_vars/all.yaml names as the only known_hosts file ssh may use. The
# file is replaced only when all six reads succeed, so a failed run leaves the
# last good file, not a partial one.
#
# WHEN. After `tofu apply` creates or replaces any of the six, before the first
# `ansible-playbook`. Until it runs, ansible/ refuses every guest whose key
# changed: "REMOTE HOST IDENTIFICATION HAS CHANGED", which is the point.
#
# WHAT IT NEEDS. phoenix.env exported (PROXMOX_URL, PROXMOX_TOKEN_ID,
# PROXMOX_TOKEN_SECRET), curl, jq, ansible-inventory, and the token holding
# VM.GuestAgent.FileRead on the six. That grant is the PhoenixHostKeys role on
# /pool/lab-domain (provision-lab-guests.md §2). It is not in PhoenixBuilder,
# because PhoenixBuilder is granted on /vms, and FileRead there would let
# phoenix read any file on any guest on Saruman, the SOC's included.
#
# Usage (from the repository root or anywhere):
#   scripts/lab-known-hosts.sh
set -euo pipefail

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${REPO}/ansible/inventory/hosts.yaml"
OUT="${REPO}/ansible/.known_hosts"
KEY_FILE='C:\ProgramData\ssh\ssh_host_ed25519_key.pub'

for v in PROXMOX_URL PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET; do
  [[ -n "${!v:-}" ]] || die "${v} is unset — set -a; . ~/.config/proxmox/phoenix.env; set +a"
done
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required (apt install jq)"
command -v ssh-keygen >/dev/null || die "ssh-keygen is required"
command -v ansible-inventory >/dev/null || die "ansible-inventory is required (build-the-lab-domain.md, Run it from phoenix)"

# Verified TLS and the token on stdin, as scripts/packer-smoke.sh does and for
# its reasons: a guest that answered for Saruman would collect a header, and
# an argument is readable in ps.
CURL_TLS=()
[[ -n "${PROXMOX_CA_FILE:-}" ]] && CURL_TLS=(--cacert "${PROXMOX_CA_FILE}")
api_get() {
  local path="$1"; shift
  printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "${PROXMOX_TOKEN_ID}" "${PROXMOX_TOKEN_SECRET}" \
    | curl -K - -fsS --max-time 60 "${CURL_TLS[@]}" -G "$@" "${PROXMOX_URL}${path}"
}

hosts="$(ansible-inventory -i "${INVENTORY}" --list \
  | jq -r '._meta.hostvars | to_entries[] | "\(.key) \(.value.ansible_host // "")"')"
[[ -n "${hosts}" ]] || die "no hosts in ${INVENTORY}"
guests="$(api_get /cluster/resources --data-urlencode type=vm)" || die "cannot list guests on ${PROXMOX_URL}"

tmp="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT

while read -r name addr; do
  [[ -n "${addr}" ]] || die "${name} has no ansible_host in ${INVENTORY}"
  # Exactly one guest of that name. Two would mean a stray clone, and reading
  # the wrong one's key would pin a guest ansible/ is not about to talk to.
  match="$(jq -c --arg n "${name}" '[.data[] | select(.name == $n and .template != 1)]' <<<"${guests}")"
  [[ "$(jq length <<<"${match}")" == 1 ]] \
    || die "${name}: expected one guest of that name, found $(jq length <<<"${match}")"
  vmid="$(jq -r '.[0].vmid' <<<"${match}")"
  node="$(jq -r '.[0].node' <<<"${match}")"

  # Three tries. A Windows agent answers a file read with "got timeout" now and
  # then, and the next read succeeds: leviathan, one read in three, on
  # 2026-10-06. A token without FileRead fails all three the same way.
  body=""
  for try in 1 2 3; do
    body="$(api_get "/nodes/${node}/qemu/${vmid}/agent/file-read" --data-urlencode "file=${KEY_FILE}")" && break
    body=""
    ((try < 3)) && sleep 5
  done
  [[ -n "${body}" ]] \
    || die "${name} (${vmid}): agent/file-read failed three times — is the agent running, and does the token hold VM.GuestAgent.FileRead there?"
  # The file ends "system@<name>\r\n". Keep the type and the key: the comment
  # is the guest's to choose, and the CR would end up inside the key.
  read -r ktype kblob _ <<<"$(jq -r '.data.content' <<<"${body}" | tr -d '\r')"
  [[ "${ktype}" == ssh-ed25519 && "${kblob}" =~ ^[A-Za-z0-9+/]{68}$ ]] \
    || die "${name} (${vmid}): ${KEY_FILE} is not an ed25519 public key"
  printf '%s %s %s\n' "${addr}" "${ktype}" "${kblob}" >>"${tmp}"
  ok "${name} ${addr} (VMID ${vmid}): $(ssh-keygen -lf - <<<"${ktype} ${kblob}" | cut -d' ' -f2)"
done <<<"${hosts}"

chmod 0644 "${tmp}"
mv -f "${tmp}" "${OUT}"
trap - EXIT
info "wrote ${OUT}"
