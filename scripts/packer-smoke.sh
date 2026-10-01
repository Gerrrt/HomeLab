#!/usr/bin/env bash
#
# Prove a Packer template makes a usable guest: clone it, boot it, wait for the
# guest agent to report an address, check the name, throw it away (#440).
#
# WHY A SCRIPT AND NOT A CHECKLIST. The test #440 asks for is "build the same
# template twice and confirm the second is usable", and that is the operation
# LabWindowsEvaluationExpiring will ask for every 150 days or so. A check that
# only a person can run, from memory, twice a year, is a check that drifts. This
# is the same check every time, and it runs from phoenix through the API alone,
# which is all phoenix has (ADR-0043: 8006, no 22 on Saruman).
#
# WHAT IT PROVES, PER FAMILY.
#   Linux    the clone takes its name, user and key from the Proxmox cloud-init
#            drive: the agent reports an address, get-host-name returns the name
#            given here, and phoenix's key opens an SSH session that prints it.
#   Windows  the generalised image finishes OOBE unattended and the guest agent
#            comes up with an address. Its name is sysprep's random one; the
#            real name is #448's. The SID check needs two clones and a console,
#            so --keep leaves this one running for it (build-the-lab-templates.md
#            §7).
#
# WHAT IT NEEDS. phoenix.env sourced (PROXMOX_URL, PROXMOX_TOKEN_ID,
# PROXMOX_TOKEN_SECRET), curl and jq, and PhoenixBuilder holding VM.Clone,
# VM.Allocate, VM.Config.Cloudinit, VM.PowerMgmt, VM.Audit and, on PVE 9,
# VM.GuestAgent.Audit for the agent reads.
#
# Usage:
#   scripts/packer-smoke.sh <template-vmid> [--vmid N] [--name NAME] [--keep]
#
#   --vmid   VMID for the throwaway clone (default 999, outside every range in use)
#   --name   its name, and for Linux its hostname (default smoke-<template-vmid>)
#   --keep   leave the clone running instead of destroying it
set -euo pipefail

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }

(($# >= 1)) || die "usage: $0 <template-vmid> [--vmid N] [--name NAME] [--keep]"
TEMPLATE="$1"; shift
CLONE=999
NAME="smoke-${TEMPLATE}"
KEEP=0
while (($#)); do
  case "$1" in
    --vmid) CLONE="${2:?--vmid needs a number}"; shift ;;
    --name) NAME="${2:?--name needs a name}"; shift ;;
    --keep) KEEP=1 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

for v in PROXMOX_URL PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET; do
  [[ -n "${!v:-}" ]] || die "${v} is unset — set -a; . ~/.config/proxmox/phoenix.env; set +a"
done
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required (apt install jq)"

NODE="${PROXMOX_NODE:-Saruman}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
AUTH="Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"

# -k for the same reason packer/variables.pkr.hcl skips verification: Saruman's
# API presents its own self-signed certificate, and the token is the control.
api() {
  local method="$1" path="$2"; shift 2
  curl -fsSk -X "${method}" -H "${AUTH}" "$@" "${PROXMOX_URL}${path}"
}

wait_task() {
  local upid="$1" status
  for _ in $(seq 1 360); do
    status="$(api GET "/nodes/${NODE}/tasks/${upid}/status" | jq -r '.data.status')"
    if [[ "${status}" == "stopped" ]]; then
      api GET "/nodes/${NODE}/tasks/${upid}/status" | jq -e '.data.exitstatus == "OK"' >/dev/null \
        || die "task ${upid} did not finish OK"
      return 0
    fi
    sleep 5
  done
  die "task ${upid} still running after 30 minutes"
}

cleanup() {
  ((KEEP)) && { info "--keep: clone ${CLONE} (${NAME}) left running"; return 0; }
  info "destroying clone ${CLONE}"
  api POST "/nodes/${NODE}/qemu/${CLONE}/status/stop" >/dev/null 2>&1 || true
  sleep 10
  api DELETE "/nodes/${NODE}/qemu/${CLONE}?purge=1&destroy-unreferenced-disks=1" >/dev/null 2>&1 \
    || printf 'could not destroy %s; remove it by hand\n' "${CLONE}" >&2
}

config="$(api GET "/nodes/${NODE}/qemu/${TEMPLATE}/config")" || die "cannot read VM ${TEMPLATE} on ${NODE}"
jq -e '.data.template == 1' <<<"${config}" >/dev/null || die "VM ${TEMPLATE} is not a template"
ostype="$(jq -r '.data.ostype' <<<"${config}")"
if api GET "/nodes/${NODE}/qemu/${CLONE}/status/current" >/dev/null 2>&1; then
  die "VMID ${CLONE} already exists; pick another with --vmid"
fi

# Full clone, always: ADR-0071 rebuilds templates in place, and a linked clone
# would pin the old one.
info "full clone ${TEMPLATE} -> ${CLONE} (${NAME})"
upid="$(api POST "/nodes/${NODE}/qemu/${TEMPLATE}/clone" \
  --data-urlencode "newid=${CLONE}" --data-urlencode "name=${NAME}" \
  --data-urlencode "full=1" | jq -r '.data')"
trap cleanup EXIT
wait_task "${upid}"
ok "cloned"

if [[ "${ostype}" == l26 ]]; then
  # Proxmox wants sshkeys URL-encoded inside the form value, hence the jq @uri
  # before curl encodes it again.
  keys="$(jq -rn --arg k "$(cat "${SSH_KEY}.pub")" '$k | @uri')"
  api PUT "/nodes/${NODE}/qemu/${CLONE}/config" \
    --data-urlencode "ciuser=smoke" --data-urlencode "sshkeys=${keys}" \
    --data-urlencode "ipconfig0=ip=dhcp" >/dev/null
  ok "cloud-init: user smoke, phoenix's key, DHCP"
fi

info "starting"
wait_task "$(api POST "/nodes/${NODE}/qemu/${CLONE}/status/start" | jq -r '.data')"

# Windows runs specialize and OOBE first, with a reboot between them, so this
# waits a good while before calling it a failure.
info "waiting for the guest agent to report an address"
addr=""
for _ in $(seq 1 120); do
  addr="$(api GET "/nodes/${NODE}/qemu/${CLONE}/agent/network-get-interfaces" 2>/dev/null \
    | jq -r '[.data.result[]? | select(.name != "lo" and (.name | test("Loopback") | not))
              | .["ip-addresses"][]? | select(."ip-address-type" == "ipv4")
              | ."ip-address" | select(startswith("169.254.") | not)][0] // empty' || true)"
  [[ -n "${addr}" ]] && break
  sleep 10
done
[[ -n "${addr}" ]] || die "no IPv4 address from the guest agent after 20 minutes"
ok "agent reports ${addr}"

host="$(api GET "/nodes/${NODE}/qemu/${CLONE}/agent/get-host-name" | jq -r '.data.result."host-name"')"
if [[ "${ostype}" == l26 ]]; then
  [[ "${host}" == "${NAME}" ]] || die "hostname is ${host}, expected ${NAME}"
  ok "hostname ${host}"
  got="$(ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "smoke@${addr}" hostname)"
  [[ "${got}" == "${NAME}" ]] || die "ssh smoke@${addr} printed ${got}, expected ${NAME}"
  ok "phoenix's key opens smoke@${addr}"
else
  ok "hostname ${host} (sysprep's random name; the real one is #448's)"
fi

printf '\n\033[0;32mtemplate %s is usable\033[0m\n' "${TEMPLATE}"
