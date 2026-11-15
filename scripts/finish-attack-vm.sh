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
# `sysctl --system`, then /etc/nftables.conf with ADR-0014's outbound scope
# (below), and §8 check three: both forwarding sysctls 0, no NAT in nft or
# legacy iptables, and nothing reached past the segment. Writing both files
# stays here rather than in cloud-init, because a cloud-init snippet would
# need tofu to upload it to gandalf over SSH, a second credential path
# (ADR-0116). The
# range is still rebuilt, not repaired (ADR-0017): a change is a tofu
# destroy and apply of 130, then this.
#
# OUTBOUND SCOPE (ADR-0014). "Its own outbound scope is limited on the VM
# itself, to 10.0.30.0/24 and the target subnet." The table range_scope drops
# every new outbound connection except to those two, plus what the segment's
# own plumbing needs: DHCP's broadcast, link-local multicast (LLMNR and mDNS,
# which the range's layer-2 tooling speaks) and IPv6 link-local and multicast
# (neighbour discovery, DHCPv6, mitm6). Replies to inbound connections, such as
# SSH or the C2 console from Hicks, are established and pass. The default route
# via 10.0.30.1 stays: the filter is the boundary, not a missing route.
#
# RAW ETHERNET. The inet output hook sees only what the IP stack sends. A
# packet socket (AF_PACKET: nmap --send-eth, masscan, anything on libpcap's
# inject) skips it and writes frames straight to eth0. So a second table,
# range_scope_l2, sits on eth0's netdev egress hook, which both paths cross
# on their way to the wire. Frames the inet chain passed carry its mark and go
# out as they are, replies to Hicks included; that is how the IP stack keeps
# conntrack's verdict, which netdev has no view of. Anything unmarked is a
# packet socket's, and passes only as ARP or to the same destinations, else
# it is counted and dropped. The check proves it by sending such a frame to
# 1.1.1.1 and reading the counter.
#
# To install a package, lift both tables for the install and put them back:
#   sudo nft delete table inet range_scope
#   sudo nft delete table netdev range_scope_l2   # ... apt install ...
#   sudo systemctl restart nftables               # or rerun this script
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
info "outbound scope (ADR-0014): /etc/nftables.conf, loaded now and at boot"
"${SSH[@]}" "kali@${addr}" 'sudo sh -eu -s' <<'GUEST' || die "writing the outbound scope failed"
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
# Written by scripts/finish-attack-vm.sh: ragnarok's outbound scope, ADR-0014.
# Lift it for a package install by deleting both tables (inet range_scope and
# netdev range_scope_l2), and restore it with `systemctl restart nftables`.
table inet range_scope
delete table inet range_scope
table inet range_scope {
  chain output {
    type filter hook output priority filter; policy drop;
    # The mark tells range_scope_l2 this left through here. Set on every
    # packet, but only the ones accepted below ever reach eth0.
    meta mark set 0x00000014
    oifname "lo" accept
    ct state established,related accept
    ip daddr { 10.0.30.0/24, 172.30.30.0/24 } accept
    ip daddr 255.255.255.255 udp dport 67 accept
    ip daddr 224.0.0.0/24 accept
    ip6 daddr { fe80::/10, ff02::/16 } accept
  }
}
# Packet sockets (AF_PACKET) never cross the chain above. eth0's egress hook
# sees what they send as well as what the IP stack sends.
table netdev range_scope_l2
delete table netdev range_scope_l2
table netdev range_scope_l2 {
  counter out_of_scope { }
  chain egress {
    type filter hook egress device "eth0" priority filter; policy drop;
    meta mark 0x00000014 accept
    ether type arp accept
    ip daddr { 10.0.30.0/24, 172.30.30.0/24, 224.0.0.0/24, 255.255.255.255 } accept
    ip6 daddr { fe80::/10, ff02::/16 } accept
    counter name "out_of_scope" drop
  }
}
NFT
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable nftables >/dev/null 2>&1
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
# The scope, as loaded and as it will load at boot. Then the proof: the
# default route still points out, so a refused send ("Operation not
# permitted") can only be the filter, while a timeout would be the internet
# being down and proves nothing. The gateway is the control: the filter must
# let it out, whether or not it answers.
echo "nftables $(systemctl is-enabled nftables 2>/dev/null || echo disabled)"
chain="$(nft list chain inet range_scope output 2>/dev/null)" || chain=""
if printf '%s\n' "$chain" | grep -q 'policy drop;'; then echo "scope policy drop"; else echo "scope missing"; fi
p="$(ping -n -c1 -W2 1.1.1.1 2>&1)" || true
if printf '%s\n' "$p" | grep -q 'Operation not permitted'; then echo "egress refused"; else echo "egress not refused"; fi
p="$(ping -n -c1 -W2 10.0.30.1 2>&1)" || true
if printf '%s\n' "$p" | grep -q 'Operation not permitted'; then echo "segment refused"; else echo "segment allowed"; fi
# Raw Ethernet, which the ping cannot test: one ICMP echo to 1.1.1.1 written
# to eth0 through a packet socket, addressed to the gateway's MAC the ping
# above just resolved. The send may fail with ENOBUFS once the egress hook
# drops it, which is why the counter, not the send, is the verdict.
l2="$(nft list chain netdev range_scope_l2 egress 2>/dev/null)" || l2=""
if printf '%s\n' "$l2" | grep -q 'policy drop;'; then echo "l2 scope policy drop"; else echo "l2 scope missing"; fi
count() { nft list counter netdev range_scope_l2 out_of_scope 2>/dev/null | sed -n 's/.*packets \([0-9][0-9]*\).*/\1/p'; }
c0="$(count)"
python3 - <<'PY' || true
import re, socket, struct, subprocess

def csum(b):
    if len(b) % 2:
        b += b"\0"
    s = sum(struct.unpack("!%dH" % (len(b) // 2), b))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF

def run(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout

mac = re.search(r"lladdr ([0-9a-f:]{17})", run("ip", "neigh", "show", "10.0.30.1", "dev", "eth0"))
src_ip = re.search(r"inet ([0-9.]+)/", run("ip", "-4", "-o", "addr", "show", "dev", "eth0")).group(1)
dst_mac = bytes.fromhex((mac.group(1) if mac else "ff:ff:ff:ff:ff:ff").replace(":", ""))
icmp = struct.pack("!BBHHH", 8, 0, 0, 0x5241, 1) + b"range-scope-probe"
icmp = icmp[:2] + struct.pack("!H", csum(icmp)) + icmp[4:]
ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(icmp), 0, 0, 64, 1, 0,
                 socket.inet_aton(src_ip), socket.inet_aton("1.1.1.1"))
ip = ip[:10] + struct.pack("!H", csum(ip)) + ip[12:]
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind(("eth0", 0))
try:
    s.send(dst_mac + s.getsockname()[4] + b"\x08\x00" + ip + icmp)
except OSError:
    pass
PY
c1="$(count)"
if [ -n "$c0" ] && [ -n "$c1" ] && [ "$c1" -gt "$c0" ]; then echo "raw egress refused"; else echo "raw egress not refused"; fi
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
grep -qx 'nftables enabled' <<<"${out}" || die "nftables.service is not enabled, so the scope would not survive a reboot"
grep -qx 'scope policy drop' <<<"${out}" || die "the range_scope output chain is not loaded with policy drop"
grep -qx 'egress refused' <<<"${out}" || die "a send to 1.1.1.1 was not refused by the filter: the outbound scope does not hold"
grep -qx 'segment allowed' <<<"${out}" || die "the filter refused 10.0.30.1: the scope cuts off the segment it exists to allow"
grep -qx 'l2 scope policy drop' <<<"${out}" || die "the range_scope_l2 egress chain on eth0 is not loaded with policy drop"
grep -qx 'raw egress refused' <<<"${out}" || die "a raw Ethernet frame to 1.1.1.1 was not dropped at eth0's egress: packet sockets escape the scope"
ok "outbound scope: 10.0.30.0/24 and 172.30.30.0/24 only, 1.1.1.1 refused by the IP stack and at eth0's egress, persistent (ADR-0014)"

printf '\n\033[0;32m%s is up at %s and %s\033[0m\n' "${NAME}" "${addr}" "${RANGE_ADDR%/*}"
