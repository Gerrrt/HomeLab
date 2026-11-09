#!/usr/bin/env bash
#
# Make the range's attack VM, ragnarok, on gandalf from tpl-kali (902), and
# prove it does not forward (#421, build-the-playground.md §5).
#
# WHY A SCRIPT. The range is rebuilt, not repaired (ADR-0017), so the one guest
# on it worth configuring carefully is one command to make again. The
# isolation it depends on is in what this sets, and §8's third check runs at
# the end of every make rather than when someone remembers to.
#
# WHAT IT MAKES. A full clone of 902 at VMID 130, its disk on `range`:
#   net0  vmbr0, ImaginationLAN, DHCP from the pool. No reservation: nothing
#         points at it (§5).
#   net1  vmbr1, the range bridge, 172.30.30.10/24 and NO gateway.
# Both with the guest firewall flag off (§4's last step). Cloud-init user
# `kali`, phoenix's key. Then, over SSH: /etc/sysctl.d/99-no-forward.conf,
# `sysctl --system`, and §8 check three: both forwarding sysctls 0 and no NAT
# in nft or legacy iptables.
#
# WHAT IT NEEDS. gandalf.env sourced (PROXMOX_URL at 10.0.30.30, the
# phoenix@pve!builder token on gandalf), gandalf's CA in phoenix's trust store
# (build-the-lab-templates.md §5), curl and jq.
#
# Usage:
#   set -a; . ~/.config/proxmox/gandalf.env; set +a
#   scripts/make-attack-vm.sh
set -euo pipefail

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }

NODE=gandalf
TEMPLATE=902
VMID=130
NAME=ragnarok
RANGE_ADDR=172.30.30.10/24
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"

for v in PROXMOX_URL PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET; do
  [[ -n "${!v:-}" ]] || die "${v} is unset — set -a; . ~/.config/proxmox/gandalf.env; set +a"
done
[[ "${PROXMOX_URL}" == *10.0.30.30* ]] || die "PROXMOX_URL is not gandalf's: source gandalf.env, not phoenix.env"
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required (apt install jq)"

# The token goes to curl on stdin, never as -H, as in packer-smoke.sh (#846).
api() {
  local method="$1" path="$2"; shift 2
  printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "${PROXMOX_TOKEN_ID}" "${PROXMOX_TOKEN_SECRET}" \
    | curl -K - -fsS -X "${method}" "$@" "${PROXMOX_URL}${path}"
}

wait_task() {
  local upid="$1"
  for _ in $(seq 1 360); do
    if [[ "$(api GET "/nodes/${NODE}/tasks/${upid}/status" | jq -r '.data.status')" == stopped ]]; then
      api GET "/nodes/${NODE}/tasks/${upid}/status" | jq -e '.data.exitstatus == "OK"' >/dev/null \
        || die "task ${upid} did not finish OK"
      return 0
    fi
    sleep 5
  done
  die "task ${upid} still running after 30 minutes"
}

api GET "/nodes/${NODE}/qemu/${TEMPLATE}/config" | jq -e '.data.template == 1' >/dev/null \
  || die "VM ${TEMPLATE} on ${NODE} is not a template: build tpl-kali first"
if api GET "/nodes/${NODE}/qemu/${VMID}/status/current" >/dev/null 2>&1; then
  die "VMID ${VMID} already exists on ${NODE}. The range is rebuilt, not repaired: destroy it first"
fi

info "full clone ${TEMPLATE} -> ${VMID} (${NAME}) on range"
wait_task "$(api POST "/nodes/${NODE}/qemu/${TEMPLATE}/clone" \
  --data-urlencode "newid=${VMID}" --data-urlencode "name=${NAME}" \
  --data-urlencode "full=1" --data-urlencode "storage=range" | jq -r '.data')"
ok "cloned"

# sshkeys is URL-encoded inside the form value, as packer-smoke.sh does.
keys="$(jq -rn --arg k "$(cat "${SSH_KEY}.pub")" '$k | @uri')"
api PUT "/nodes/${NODE}/qemu/${VMID}/config" \
  --data-urlencode "cores=4" --data-urlencode "memory=8192" \
  --data-urlencode "net0=virtio,bridge=vmbr0,firewall=0" \
  --data-urlencode "net1=virtio,bridge=vmbr1,firewall=0" \
  --data-urlencode "ipconfig0=ip=dhcp" \
  --data-urlencode "ipconfig1=ip=${RANGE_ADDR}" \
  --data-urlencode "ciuser=kali" --data-urlencode "sshkeys=${keys}" \
  --data-urlencode "tags=range;attack" \
  --data-urlencode "description=The range's attack VM (#421, build-the-playground.md §5). Made by scripts/make-attack-vm.sh." \
  >/dev/null
ok "net0 vmbr0 DHCP, net1 vmbr1 ${RANGE_ADDR} no gateway, firewall flags off"

# The one thing a typo here would break is the isolation, so read it back.
cfg="$(api GET "/nodes/${NODE}/qemu/${VMID}/config")"
jq -e '(.data.net1 | test("bridge=vmbr1")) and (.data.net0 | test("bridge=vmbr0"))
       and ((.data.ipconfig1 // "") | test("gw") | not)' <<<"${cfg}" >/dev/null \
  || die "the config did not read back as written: $(jq -c '.data | {net0,net1,ipconfig0,ipconfig1}' <<<"${cfg}")"
ok "config reads back"

info "starting"
wait_task "$(api POST "/nodes/${NODE}/qemu/${VMID}/status/start" | jq -r '.data')"

info "waiting for the guest agent to report the VLAN 30 lease"
addr=""
for _ in $(seq 1 60); do
  addr="$(api GET "/nodes/${NODE}/qemu/${VMID}/agent/network-get-interfaces" 2>/dev/null \
    | jq -r '[.data.result[]? | .["ip-addresses"][]? | select(."ip-address-type" == "ipv4")
              | ."ip-address" | select(startswith("10.0.30."))][0] // empty' || true)"
  [[ -n "${addr}" ]] && break
  sleep 10
done
[[ -n "${addr}" ]] || die "no 10.0.30.x address from the guest agent after 10 minutes"
ok "agent reports ${addr}"

SSH=(ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
for _ in $(seq 1 18); do
  "${SSH[@]}" "kali@${addr}" true 2>/dev/null && break
  sleep 10
done
"${SSH[@]}" "kali@${addr}" true || die "kali@${addr} admitted no SSH login in three minutes"
ok "phoenix's key opens kali@${addr}"

info "forwarding off, persistently (§5), then §8 check three"
# shellcheck disable=SC2016 # expanded on the guest, not here
"${SSH[@]}" "kali@${addr}" 'sudo sh -eu -c "
printf \"net.ipv4.ip_forward = 0\nnet.ipv6.conf.all.forwarding = 0\n\" > /etc/sysctl.d/99-no-forward.conf
sysctl --system >/dev/null
"'
out="$("${SSH[@]}" "kali@${addr}" 'sudo sh -c "
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
nft list ruleset 2>/dev/null | grep -Ei \"masquerade|snat\" || echo \"no NAT\"
iptables -t nat -S 2>/dev/null | grep -- \"-j MASQUERADE\" || echo \"no legacy NAT\"
ip -br addr; ip route
"')"
printf '%s\n' "${out}"
grep -qx 'net.ipv4.ip_forward = 0' <<<"${out}" || die "ip_forward is not 0"
grep -qx 'net.ipv6.conf.all.forwarding = 0' <<<"${out}" || die "IPv6 forwarding is not 0"
grep -qx 'no NAT' <<<"${out}" || die "nft has a NAT rule"
grep -qx 'no legacy NAT' <<<"${out}" || die "iptables-legacy has a MASQUERADE rule"
grep -q "${RANGE_ADDR%/*}/24" <<<"${out}" || die "${RANGE_ADDR} is not on any interface"
[[ "$(grep -c '^default' <<<"${out}")" == 1 ]] || die "expected exactly one default route"
grep -q '^default via 10\.0\.30\.1 ' <<<"${out}" || die "the default route is not via 10.0.30.1"
ok "no forwarding, no NAT, one default route via 10.0.30.1, ${RANGE_ADDR} on the range"

printf '\n\033[0;32m%s is up at %s and %s\033[0m\n' "${NAME}" "${addr}" "${RANGE_ADDR%/*}"
