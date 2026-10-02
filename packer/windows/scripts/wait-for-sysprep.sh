#!/usr/bin/env bash
#
# The last step of a Windows build, run on phoenix (shell-local): wait for the
# guest to power itself off, which is sysprep saying it has generalised.
#
# sysprep.ps1 starts sysprep as a scheduled task with /shutdown and returns at
# once, because generalising uninstalls the network adapter and kills any
# WinRM session waiting on it (2026-10-02). From here nothing can reach the
# guest, but the Proxmox API can still see whether it is running. Once it is
# stopped, the builder converts it to a template.
#
# If it never stops, sysprep failed or hung. The image is half-generalised and
# must not be booted to look at, because booting spends the generalisation.
# Read its log from the disk instead, as build-the-lab-templates.md §4 says.
#
# Environment, from windows.pkr.hcl: PROXMOX_URL, PROXMOX_TOKEN_ID,
# PROXMOX_TOKEN_SECRET, NODE, VMID. TLS is verified, as packer-smoke.sh does,
# with PROXMOX_CA_FILE for a host whose trust store lacks the cluster CA.
set -euo pipefail

for v in PROXMOX_URL PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET NODE VMID; do
  [[ -n "${!v:-}" ]] || { printf 'wait-for-sysprep: %s is unset\n' "$v" >&2; exit 1; }
done

CURL_TLS=()
[[ -n "${PROXMOX_CA_FILE:-}" ]] && CURL_TLS=(--cacert "${PROXMOX_CA_FILE}")
status() {
  curl -fsS "${CURL_TLS[@]}" \
    -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
    "${PROXMOX_URL}/nodes/${NODE}/qemu/${VMID}/status/current" \
    | jq -r '.data.status'
}

# 45 minutes. Sysprep on this host took about a minute to reach the device
# uninstall that killed it; a whole generalise is usually a few minutes more.
printf 'waiting for VM %s to power off after sysprep' "${VMID}"
for _ in $(seq 1 180); do
  s="$(status || true)"
  if [[ "${s}" == stopped ]]; then
    printf '\nVM %s is stopped: sysprep finished\n' "${VMID}"
    exit 0
  fi
  printf '.'
  sleep 15
done
printf '\n' >&2
printf 'VM %s is still %s after 45 minutes. Sysprep failed or hung.\n' "${VMID}" "${s:-unknown}" >&2
printf 'Do not boot it. Read C:\\Windows\\System32\\Sysprep\\Panther\\setupact.log and setuperr.log from its disk.\n' >&2
exit 1
