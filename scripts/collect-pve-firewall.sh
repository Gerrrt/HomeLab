#!/usr/bin/env bash
#
# Whether the hypervisor's Proxmox firewall is on, and holding a wall (#576).
#
# THE CONTROL. #566 found `Saruman`'s firewall DISABLED — `pve-firewall status`
# read `disabled/running`, with no `cluster.fw` and no `host.fw` — while ADR-0014
# and ADR-0043 both described the management-plane rule as standing. #566 turned
# it on. This is what makes sure it is still on next month.
#
# THE WAYS IT GOES OFF AGAIN are ordinary and none of them pages anything: a
# `pve-firewall stop` while debugging a guest that cannot reach the API; an
# upgrade that rewrites /etc/pve/firewall; `policy_in` set back to ACCEPT to get
# out of a lockout and never set back; a reinstall from the runbook. The check a
# person would do — `nc -z 10.0.30.110 8006` from off the segment — is done once.
#
# THREE READINGS, because "on" is not one fact:
#
#   homelab_pve_firewall_enabled      `pve-firewall status` says enabled/running
#   homelab_pve_firewall_policy_drop  cluster.fw's policy_in is DROP (or REJECT)
#   homelab_pve_firewall_rules{file}  enabled rules in cluster.fw and host.fw
#
# Enabled with `policy_in: ACCEPT` admits everything the rules do not refuse,
# which is the whole segment — the firewall reads as on and the wall is not
# there. That is `build-the-playground.md` §4's intermediate step, and the easy
# one to be left in. The rule count separates "enabled" from "enabled with
# nothing in it", which the status line alone cannot.
#
# ROOT for the textfile directory and for `pve-firewall status`, which reads the
# daemon's state. The files under /etc/pve are pmxcfs, a FUSE mount, which is
# why the unit carries no mount-namespace hardening — see
# homelab-guest-state.service, which learned that on its first run.
#
# Usage: scripts/collect-pve-firewall.sh [--print]
#        scripts/collect-pve-firewall.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/pve-firewall.prom"
HOSTNAME_LABEL="$(hostname)"

# /etc/pve/local is pmxcfs's own link to nodes/<this node>, so the node name —
# `Saruman`, capitalised, where a mis-cased path is a file Proxmox never reads —
# never has to be spelled here.
CLUSTER_FW="${CLUSTER_FW:-/etc/pve/firewall/cluster.fw}"
HOST_FW="${HOST_FW:-/etc/pve/local/host.fw}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

STDERR_FILE="$(mktemp)"
trap 'rm -f "${STDERR_FILE}"' EXIT

# `Status: enabled/running`, sometimes with ` (pending changes)` after it.
# Prints 1 for enabled/running, 0 for any other status it recognises, and
# nothing for a line it does not — so an unrecognised answer is a failure below
# rather than a confident zero or one.
parse_status() {
  awk '
    /^Status:/ {
      s = $2
      if (s == "enabled/running") { print 1; exit }
      if (s ~ /^(enabled|disabled)\/(running|stopped)$/) { print 0; exit }
    }
  '
}

# The enabled rules in a .fw file's [RULES] section. A rule prefixed with `|` is
# written but disabled, so it does not count; neither do comments, blanks, or
# the rules inside a [group ...] definition, which apply only where referenced.
count_rules() {
  awk '
    /^[ \t]*\[/ { in_rules = (toupper($0) ~ /^[ \t]*\[RULES\]/); next }
    !in_rules { next }
    /^[ \t]*(#|$)/ { next }
    /^[ \t]*\|/ { next }
    /^[ \t]*(IN|OUT|GROUP)[ \t]/ { n++ }
    END { print n + 0 }
  '
}

# 1 when cluster.fw's inbound policy refuses what no rule admits. Proxmox's
# default for an unset policy_in is DROP, so an absent key is 1.
parse_policy_drop() {
  awk '
    /^[ \t]*\[/ { in_opts = (toupper($0) ~ /^[ \t]*\[OPTIONS\]/); next }
    in_opts && /^[ \t]*policy_in[ \t]*:/ {
      v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+$/, "", v); policy = toupper(v)
    }
    END { print (policy == "" || policy == "DROP" || policy == "REJECT") ? 1 : 0 }
  '
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" fn="$2" expect="$3" got
    got="$(printf '%s\n' "$4" | "$fn" | tr '\n' ';')"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  check "enabled/running is on" parse_status "1;" "Status: enabled/running"
  check "pending changes is still on" parse_status "1;" "Status: enabled/running (pending changes)"
  # What #566 found on Saruman: the daemon running, the firewall not.
  check "disabled/running is off" parse_status "0;" "Status: disabled/running"
  check "enabled/stopped is off" parse_status "0;" "Status: enabled/stopped"
  check "an unknown answer is not a reading" parse_status "" "pve-firewall: something else"

  # host.fw as build-the-playground.md §4 writes it on Saruman: ADR-0014's three
  # lines and ADR-0043's fourth.
  check "Saruman's host.fw has four rules" count_rules "4;" \
"[OPTIONS]
enable: 1

[RULES]
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8006 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8007 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 22 -log nolog
IN ACCEPT -source 10.0.30.70 -p tcp -dport 8006 -log nolog"
  check "a disabled rule and a comment do not count" count_rules "1;" \
"[RULES]
# admitted for the jumpbox
|IN ACCEPT -source 10.0.30.70 -p tcp -dport 8006
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 22"
  check "rules inside a security group are not the host's" count_rules "0;" \
"[group webservers]
IN ACCEPT -p tcp -dport 443"
  check "cluster.fw with options and an alias only" count_rules "0;" \
"[OPTIONS]
enable: 1
policy_in: DROP

[ALIASES]
local_network 10.0.30.110"
  check "a missing file is zero rules" count_rules "0;" ""

  check "policy_in DROP" parse_policy_drop "1;" \
"[OPTIONS]
enable: 1
policy_in: DROP"
  # §4's intermediate step, and the one it is easy to be left in.
  check "policy_in ACCEPT is no wall" parse_policy_drop "0;" \
"[OPTIONS]
enable: 1
policy_in: ACCEPT"
  check "an unset policy_in is Proxmox's default, DROP" parse_policy_drop "1;" \
"[OPTIONS]
enable: 1"
  check "policy_in outside [OPTIONS] is not the policy" parse_policy_drop "1;" \
"[OPTIONS]
enable: 1
[ALIASES]
policy_in: ACCEPT"
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v pve-firewall >/dev/null 2>&1 \
  || die "no pve-firewall on this host — it is not a Proxmox VE node."

# A status this does not understand is a failure, not a zero. Reporting the
# firewall off on a parse error would page critical for a wording change; reporting
# it on would be worse. Nothing is written, the timestamp stops, and
# PveFirewallStateStopped says the reading is stale.
status_raw="$(pve-firewall status 2>"${STDERR_FILE}")"
rc=$?
enabled="$(printf '%s\n' "$status_raw" | parse_status)"
if [[ -z "$enabled" ]]; then
  detail="$(grep -v '^$' "${STDERR_FILE}" | tail -2 | paste -sd'; ' -)"
  die "pve-firewall status (exit ${rc}) gave no status this recognises:
${status_raw:-<empty>}${detail:+
${detail}}"
fi

# A file that does not exist is zero rules, which is a true reading: it is what
# #566 found. A file that exists and cannot be read is not.
read_fw() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  cat -- "$f" 2>"${STDERR_FILE}" || die "cannot read ${f}: $(cat "${STDERR_FILE}")"
}
cluster_raw="$(read_fw "${CLUSTER_FW}")" || exit 1
host_raw="$(read_fw "${HOST_FW}")" || exit 1
cluster_rules="$(printf '%s\n' "$cluster_raw" | count_rules)"
host_rules="$(printf '%s\n' "$host_raw" | count_rules)"
policy_drop="$(printf '%s\n' "$cluster_raw" | parse_policy_drop)"

emit() {
  printf '# HELP homelab_pve_firewall_enabled 1 when pve-firewall status reads enabled/running.\n'
  printf '# TYPE homelab_pve_firewall_enabled gauge\n'
  printf 'homelab_pve_firewall_enabled{host="%s"} %s\n' "$HOSTNAME_LABEL" "$enabled"
  printf '# HELP homelab_pve_firewall_policy_drop 1 when cluster.fw policy_in refuses unmatched inbound traffic.\n'
  printf '# TYPE homelab_pve_firewall_policy_drop gauge\n'
  printf 'homelab_pve_firewall_policy_drop{host="%s"} %s\n' "$HOSTNAME_LABEL" "$policy_drop"
  printf '# HELP homelab_pve_firewall_rules Enabled rules in the [RULES] section of each firewall file.\n'
  printf '# TYPE homelab_pve_firewall_rules gauge\n'
  printf 'homelab_pve_firewall_rules{host="%s",file="cluster"} %s\n' "$HOSTNAME_LABEL" "$cluster_rules"
  printf 'homelab_pve_firewall_rules{host="%s",file="host"} %s\n' "$HOSTNAME_LABEL" "$host_rules"
  # A timestamp for the staleness rule, for the reason collect-thin-pools.sh
  # gives: the file persists, so presence says nothing about a stopped timer.
  printf '# HELP homelab_pve_firewall_last_run_timestamp_seconds When this collector last read the firewall.\n'
  printf '# TYPE homelab_pve_firewall_last_run_timestamp_seconds gauge\n'
  printf 'homelab_pve_firewall_last_run_timestamp_seconds{host="%s"} %s\n' "$HOSTNAME_LABEL" "$(date +%s)"
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'pve-firewall host=%s enabled=%s policy_drop=%s rules cluster=%s host=%s\n' \
  "$HOSTNAME_LABEL" "$enabled" "$policy_drop" "$cluster_rules" "$host_rules"
