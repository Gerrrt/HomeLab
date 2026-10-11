#!/usr/bin/env bash
#
# Build (or tear down) the gvmscan network namespace that fences OpenVAS to the
# lab domain's six (#921 phase 3, ADR-0093). Run by gvm-scan-netns.service, as
# root, with `up` or `down`.
#
# WHY A NAMESPACE. The scanner, openvas, sends raw frames and ARP through
# AF_PACKET, below any IP hook, so a fence on garuda's shared eth0 could only
# filter IP. The scanner instead gets its own interface, scan0, in its own
# namespace, and an nftables netdev egress hook on scan0 filters every frame it
# sends — ARP and raw frames included (scan0-egress.nft).
#
# scan0 IS A MACVLAN on eth0, not a second NIC. It gives the scanner its own
# MAC and its own address, .63, on VLAN 30, sharing garuda's one NIC. No tofu
# or Proxmox change, and nothing to forward: scan0 reaches the six directly,
# on-link, so Docker's FORWARD policy (which blocked a routed design) never
# sees it. macvlan isolates the namespace from garuda's host stack, which is
# why MQTT needs the veth below.
#
# gvmn/gvmh IS A VETH carrying only MQTT. openvas publishes scan state to
# notus-scanner through garuda's mosquitto, on the host. A macvlan cannot reach
# its own host, so this point-to-point link does: the namespace reaches the
# broker at 10.99.0.1, and nothing routes from it to the segment. It is not
# filtered, because it cannot reach a scan target.
#
# WHAT STAYS ON THE HOST. gvmd, notus-scanner, redis and mosquitto, and their
# unix sockets (ospd<->gvmd, openvas<->redis), which a namespace does not
# change. Only ospd-openvas and the openvas it spawns join this namespace, by
# NetworkNamespacePath in ospd-openvas-netns.conf.
set -euo pipefail

NS=gvmscan
PARENT=eth0
SCAN_ADDR=10.0.30.63/24      # garuda's second address, for the scanner only (docs/network.md)
VETH_HOST=10.99.0.1/30       # mosquitto binds this (mosquitto-gvm.conf)
VETH_NS=10.99.0.2/30
RULES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scan0-egress.nft"

die() { printf 'gvm-scan-netns: %s\n' "$*" >&2; exit 1; }

up() {
  [[ -f "${RULES}" ]] || die "no ${RULES}"
  ip netns add "${NS}"

  # The scanner's interface: a macvlan on eth0, moved into the namespace.
  ip link add scan0 link "${PARENT}" type macvlan mode bridge
  ip link set scan0 netns "${NS}"
  ip -n "${NS}" addr add "${SCAN_ADDR}" dev scan0
  ip -n "${NS}" link set scan0 up
  ip -n "${NS}" link set lo up

  # The MQTT veth: host end up with the broker's address, namespace end routed
  # at it. No default route in the namespace: the six are on-link on scan0, and
  # the broker is on-link on gvmn.
  ip link add gvmh type veth peer name gvmn
  ip link set gvmn netns "${NS}"
  ip addr add "${VETH_HOST}" dev gvmh
  ip link set gvmh up
  ip -n "${NS}" addr add "${VETH_NS}" dev gvmn
  ip -n "${NS}" link set gvmn up

  # The egress fence, inside the namespace, on scan0.
  ip netns exec "${NS}" nft -f "${RULES}"
}

down() {
  # Order and `|| true`: tear down whatever is present, so a partial up still
  # cleans. Deleting the namespace takes scan0 and gvmn with it.
  ip link del gvmh 2>/dev/null || true
  ip netns del "${NS}" 2>/dev/null || true
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) die "usage: $0 up|down" ;;
esac
