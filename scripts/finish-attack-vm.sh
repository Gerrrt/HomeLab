#!/usr/bin/env bash
#
# Finish the range's attack VM, ragnarok, after tofu has made it on gandalf,
# and prove it does not forward (#421, build-the-playground.md §5, ADR-0116).
#
# WHAT TOFU MAKES (tofu/guests.tf, module.range_guest). A full clone of 902
# (tpl-kali) at VMID 130 on `range`, with:
#   net0  vmbr0, ImaginationLAN, DHCP from the pool. Its MAC is pinned, but
#         nothing points at it, so morpheus holds no reservation (§5).
#   net1  vmbr1, the range bridge, 172.30.30.10/24 and NO gateway.
# Both with the guest firewall flag off. Cloud-init user `kali`, phoenix's key.
#
# WHAT THIS DOES, AFTER EVERY APPLY. It reads the config back, because the one
# thing a mistake there would break is the isolation. It starts the guest if it
# is stopped. Then, over SSH: /etc/sysctl.d/99-no-forward.conf,
# `sysctl --system`, and §8 check three: both forwarding sysctls 0 and no NAT
# in nft or legacy iptables. Writing the sysctl file stays here rather than in
# cloud-init, because a cloud-init snippet would need tofu to upload it to
# gandalf over SSH, a second credential path for one file (ADR-0116). The
# range is still rebuilt, not repaired (ADR-0017): a change is a tofu
# destroy and apply of 130, then this.
#
# HOST KEY. The SSH that reports §8 check three crosses VLAN 30, where ARP
# spoofing is expected (docs/security.md), so the key ragnarok presents is
# checked against one read through the guest agent, as ADR-0085 does for the
# lab domain: Proxmox reads /etc/ssh/ssh_host_ed25519_key.pub inside the
# guest, and phoenix asks Proxmox over verified TLS. Anything else answering
# for the lease is refused, so a PASS is ragnarok's own.
#
# WHAT IT NEEDS. gandalf.env sourced (PROXMOX_URL at 10.0.30.30, the
# phoenix@pve!builder token on gandalf), gandalf's CA in phoenix's trust store
# (build-the-lab-templates.md §5), curl, jq and ssh-keygen, and the token
# holding VM.GuestAgent.FileRead on /vms/130 alone (PhoenixHostKeys,
# build-the-playground.md §5). Destroying the VM drops that ACL, so it is
# checked first.
#
# Usage:
#   set -a; . ~/.config/proxmox/gandalf.env; set +a
#   scripts/finish-attack-vm.sh
set -euo pipefail

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }

NODE=gandalf
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
command -v ssh-keygen >/dev/null || die "ssh-keygen is required"

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

api GET "/nodes/${NODE}/qemu/${VMID}/status/current" >/dev/null 2>&1 \
  || die "VMID ${VMID} does not exist on ${NODE}: tofu makes it (build-the-playground.md §5), then this runs"
# The host-key read needs FileRead on this VMID, and a destroy removes the
# VMID's ACLs, so a fresh apply of 130 needs the grant again. Stop here, not
# after waiting ten minutes for cloud-init.
api GET /access/permissions -G --data-urlencode "path=/vms/${VMID}" \
  | jq -e --arg p "/vms/${VMID}" '.data[$p]["VM.GuestAgent.FileRead"] == 1' >/dev/null \
  || die "${PROXMOX_TOKEN_ID} lacks VM.GuestAgent.FileRead on /vms/${VMID}. On ${NODE} as root:
  pveum acl modify /vms/${VMID} --users phoenix@pve --roles PhoenixBuilder,PhoenixHostKeys
(build-the-playground.md §5)"

# The one thing a mistake in tofu/guests.tf would break is the isolation, so
# read it back before anything else.
cfg="$(api GET "/nodes/${NODE}/qemu/${VMID}/config")"
jq -e '(.data.net1 | test("bridge=vmbr1")) and (.data.net0 | test("bridge=vmbr0"))
       and ((.data.ipconfig1 // "") | test("ip=172\\.30\\.30\\.10/24"))
       and ((.data.ipconfig1 // "") | test("gw") | not)' <<<"${cfg}" >/dev/null \
  || die "the config did not read back as written: $(jq -c '.data | {net0,net1,ipconfig0,ipconfig1}' <<<"${cfg}")"
ok "config reads back"

if [[ "$(api GET "/nodes/${NODE}/qemu/${VMID}/status/current" | jq -r '.data.status')" != running ]]; then
  info "starting"
  wait_task "$(api POST "/nodes/${NODE}/qemu/${VMID}/status/start" | jq -r '.data')"
fi

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

# Read the host key once cloud-init has finished, not before: its first boot
# deletes the template's keys and makes new ones (ssh_deletekeys), and a key
# read in between would be the one about to go. boot-finished marks the end.
agent_read() {
  api GET "/nodes/${NODE}/qemu/${VMID}/agent/file-read" -G --data-urlencode "file=$1" 2>/dev/null \
    | jq -er '.data.content'
}
info "reading the host key through the guest agent (ADR-0085)"
for _ in $(seq 1 60); do
  agent_read /var/lib/cloud/instance/boot-finished >/dev/null && break
  sleep 10
done
agent_read /var/lib/cloud/instance/boot-finished >/dev/null \
  || die "cloud-init on ${NAME} has not finished after 10 minutes"
read -r ktype kblob _ <<<"$(agent_read /etc/ssh/ssh_host_ed25519_key.pub)" \
  || die "agent/file-read of ${NAME}'s host key failed"
[[ "${ktype}" == ssh-ed25519 && "${kblob}" =~ ^[A-Za-z0-9+/]{68}$ ]] \
  || die "${NAME}'s /etc/ssh/ssh_host_ed25519_key.pub is not an ed25519 public key"
KNOWN_HOSTS="$(mktemp)"
trap 'rm -f "${KNOWN_HOSTS}"' EXIT
printf '%s %s %s\n' "${addr}" "${ktype}" "${kblob}" >"${KNOWN_HOSTS}"
ok "host key $(ssh-keygen -lf "${KNOWN_HOSTS}" | cut -d' ' -f2)"

# ControlPath=none: a multiplexed session (ControlMaster auto in a user's
# ssh_config) does no key exchange, so it would skip the check altogether,
# and a master opened earlier by an unchecked ssh would be trusted. Found on
# phoenix 2026-11-09, where a key that was not ragnarok's passed that way.
SSH=(ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=yes
     -o UserKnownHostsFile="${KNOWN_HOSTS}" -o GlobalKnownHostsFile=/dev/null
     -o HostKeyAlgorithms=ssh-ed25519 -o ControlMaster=no -o ControlPath=none
     -o LogLevel=ERROR -o ConnectTimeout=10)
for _ in $(seq 1 18); do
  "${SSH[@]}" "kali@${addr}" true 2>/dev/null && break
  sleep 10
done
"${SSH[@]}" "kali@${addr}" true || die "kali@${addr} admitted no SSH login in three minutes"
ok "phoenix's key opens kali@${addr}, which presents the agent-read host key"

info "forwarding off, persistently (§5), then §8 check three"
"${SSH[@]}" "kali@${addr}" 'sudo sh -eu -s' <<'GUEST' || die "writing 99-no-forward.conf failed"
printf 'net.ipv4.ip_forward = 0\nnet.ipv6.conf.all.forwarding = 0\n' > /etc/sysctl.d/99-no-forward.conf
sysctl --system >/dev/null
GUEST
# Each "no ... NAT" line is printed only after its read succeeded, so a failed
# read cannot pass for an empty table. Kali's iptables is the nft one, so
# legacy tables are read with iptables-legacy, and only if the kernel has a
# legacy nat table at all: /proc/net/ip{,6}_tables_names lists them.
out="$("${SSH[@]}" "kali@${addr}" 'sudo sh -eu -s' <<'GUEST'
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
rs="$(nft list ruleset)" || { echo "nft list ruleset failed"; exit 1; }
if printf '%s\n' "$rs" | grep -Eiq 'masquerade|snat'; then echo "nft has NAT"; else echo "no NAT"; fi
legacy=""
for fam in ip ip6; do
  grep -qsx nat "/proc/net/${fam}_tables_names" || continue
  cmd="iptables-legacy"; [ "$fam" = ip6 ] && cmd="ip6tables-legacy"
  rules="$("$cmd" -t nat -S)" || { echo "$cmd -t nat -S failed"; exit 1; }
  printf '%s\n' "$rules" | grep -Eq -- '-j (MASQUERADE|SNAT)' && legacy=1
done
if [ -n "$legacy" ]; then echo "legacy NAT present"; else echo "no legacy NAT"; fi
ip -br addr
ip route
GUEST
)" || die "§8 check three did not run to the end on ${NAME}: ${out:-no output}"
printf '%s\n' "${out}"
grep -qx 'net.ipv4.ip_forward = 0' <<<"${out}" || die "ip_forward is not 0"
grep -qx 'net.ipv6.conf.all.forwarding = 0' <<<"${out}" || die "IPv6 forwarding is not 0"
grep -qx 'no NAT' <<<"${out}" || die "nft has a NAT rule"
grep -qx 'no legacy NAT' <<<"${out}" || die "a legacy nat table has a MASQUERADE or SNAT rule"
grep -q "${RANGE_ADDR%/*}/24" <<<"${out}" || die "${RANGE_ADDR} is not on any interface"
[[ "$(grep -c '^default' <<<"${out}")" == 1 ]] || die "expected exactly one default route"
grep -q '^default via 10\.0\.30\.1 ' <<<"${out}" || die "the default route is not via 10.0.30.1"
ok "no forwarding, no NAT, one default route via 10.0.30.1, ${RANGE_ADDR} on the range"

printf '\n\033[0;32m%s is up at %s and %s\033[0m\n' "${NAME}" "${addr}" "${RANGE_ADDR%/*}"
