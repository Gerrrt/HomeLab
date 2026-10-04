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
#            comes up with an address. The agent is disabled in the template
#            and started by SetupComplete.cmd as its last act, so an address
#            from it means first-boot Setup has finished, not merely begun.
#            Then phoenix's key opens an SSH session as Administrator, which is
#            how ansible/ reaches every guest (ADR-0077). Its name is sysprep's
#            random one; the real name is set by ansible/. The SID check needs
#            two clones and a console, so --keep leaves this one running for it
#            (build-the-lab-templates.md §7).
#
# WHAT IT NEEDS. phoenix.env sourced (PROXMOX_URL, PROXMOX_TOKEN_ID,
# PROXMOX_TOKEN_SECRET), curl and jq, and PhoenixBuilder holding VM.Clone,
# VM.Allocate, VM.Config.Cloudinit, VM.Config.Options (the tag below),
# VM.PowerMgmt, VM.Audit and, on PVE 9, VM.GuestAgent.Audit for the agent
# reads.
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

# Verified TLS, as packer/variables.pkr.hcl does: the token rides in a header,
# and a guest on VLAN 30 that answered for Saruman would otherwise collect it.
# The cluster CA is in phoenix's trust store (build-the-lab-templates.md §2);
# PROXMOX_CA_FILE points at a copy instead, for a host where it is not.
CURL_TLS=()
[[ -n "${PROXMOX_CA_FILE:-}" ]] && CURL_TLS=(--cacert "${PROXMOX_CA_FILE}")
api() {
  local method="$1" path="$2"; shift 2
  curl -fsS "${CURL_TLS[@]}" -X "${method}" -H "${AUTH}" "$@" "${PROXMOX_URL}${path}"
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

# Full clone, always: ADR-0074 rebuilds templates in place, and a linked clone
# would pin the old one.
info "full clone ${TEMPLATE} -> ${CLONE} (${NAME})"
upid="$(api POST "/nodes/${NODE}/qemu/${TEMPLATE}/clone" \
  --data-urlencode "newid=${CLONE}" --data-urlencode "name=${NAME}" \
  --data-urlencode "full=1" | jq -r '.data')"
trap cleanup EXIT
wait_task "${upid}"
ok "cloned"

# Tagged `disposable` (ADR-0071), the way tofu tags its proof guest. A template
# is stopped, so its clone sits stopped until it boots below, and a clone that
# HypervisorGuestStopped can see went pending on every smoke run. Disposable
# guests are outside that rule. The tag also makes a clone that outlives its
# run visible: --keep, or a destroy that failed, is DisposableGuestOutlived's
# case at a fortnight, instead of a VMID 999 nobody is watching. Set before
# boot, so the hypervisor's collector never sees the clone untagged.
api PUT "/nodes/${NODE}/qemu/${CLONE}/config" \
  --data-urlencode "tags=disposable;smoke" >/dev/null
ok "tagged disposable"

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

# Windows runs specialize and OOBE first, with a reboot between them, and its
# agent only starts once SetupComplete.cmd has run, so this waits a good while
# before calling it a failure.
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

# The guest agent answers before the guest admits logins. On Ubuntu,
# pam_nologin refuses every session with "System is booting up" until boot
# has finished, and a single attempt the moment an address appeared lost
# that race on both builds of 901 on 2026-10-02. So retry for three minutes:
# a refusal while boot finishes is "not yet", and a guest that still admits
# nobody after that is a failure. Only the last attempt's error is printed,
# so a real refusal is still readable.
#
# BOUNDED BY THE CLOCK, NOT A COUNT. A dropped connection spends the full
# ConnectTimeout before it fails, so eighteen tries with a sleep after each
# could take six minutes. No attempt starts once fewer than ConnectTimeout
# seconds remain, and none sleeps after the last, so the wait is three
# minutes and at most one attempt's timeout more.
SSH_WAIT_SECONDS=180
SSH_CONNECT_TIMEOUT=10
ssh_hostname() {
  local user="$1" out err deadline
  err="$(mktemp)"
  deadline=$((SECONDS + SSH_WAIT_SECONDS))
  while :; do
    if out="$(ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" \
        "${user}@${addr}" hostname 2>"${err}" | tr -d '\r')" && [[ -n "${out}" ]]; then
      rm -f "${err}"; printf '%s' "${out}"; return 0
    fi
    ((SECONDS + 10 + SSH_CONNECT_TIMEOUT <= deadline)) || break
    sleep 10
  done
  cat "${err}" >&2; rm -f "${err}"
  return 1
}

host="$(api GET "/nodes/${NODE}/qemu/${CLONE}/agent/get-host-name" | jq -r '.data.result."host-name"')"
if [[ "${ostype}" == l26 ]]; then
  [[ "${host}" == "${NAME}" ]] || die "hostname is ${host}, expected ${NAME}"
  ok "hostname ${host}"
  got="$(ssh_hostname smoke)" || die "smoke@${addr} admitted no SSH login in three minutes"
  [[ "${got}" == "${NAME}" ]] || die "ssh smoke@${addr} printed ${got}, expected ${NAME}"
  ok "phoenix's key opens smoke@${addr}"
else
  ok "hostname ${host} (sysprep's random name; the real one is ansible/'s)"
  # The way ansible/ reaches every guest (ADR-0077): sshd, started by
  # SetupComplete.cmd, admitting phoenix's key as Administrator. Windows names
  # are upper-case and the agent's need not be, so compare without case.
  got="$(ssh_hostname Administrator)" || die "Administrator@${addr} admitted no SSH login in three minutes"
  [[ "${got,,}" == "${host,,}" ]] || die "ssh Administrator@${addr} printed ${got}, expected ${host}"
  ok "phoenix's key opens Administrator@${addr}"
fi

printf '\n\033[0;32mtemplate %s is usable\033[0m\n' "${TEMPLATE}"
