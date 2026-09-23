#!/usr/bin/env bash
#
# Whether the hypervisor's Proxmox firewall is on, and how many rules it holds (#576).
#
# THE GAP. #566 found `Saruman`'s firewall disabled — `pve-firewall status`
# read `disabled/running`, with no `cluster.fw` and no `host.fw` — while ADR-0014
# and ADR-0043 both described the management-plane rule as standing. #566
# turned it on (`build-the-playground.md` §4). Nothing proved it STAYED on,
# and the ways it goes off again are ordinary: a `pve-firewall stop` while
# debugging a guest that cannot reach the API, an upgrade that rewrites
# /etc/pve/firewall, or a rebuild that skips §4 the way the first build did.
# The check that would notice, `nc -z 10.0.30.110 8006` from off the segment, is
# something a person does once.
#
# WHY RULE COUNTS AS WELL AS THE SWITCH. "Enabled with zero rules" and
# "enabled" have to be told apart. With the default `policy_in: DROP` an empty
# host.fw locks everyone out, and someone fixing that in a hurry sets ACCEPT,
# which is a firewall that is on and admits everything. Counts per file make
# that visible without publishing the rules themselves.
#
# WHAT IT DOES NOT PROVE. The `local_network` alias from §4 is what stops
# Proxmox's `management` IP set from admitting the whole segment, and a count
# cannot see it. The off-segment `nc` probe in §4 is still the proof of what the
# rules DO; this proves only that they are loaded and switched on.
#
# NO GUEST DATA (ADR-0028). This reads the hypervisor's own firewall state; the
# per-guest firewall is deliberately off (§4) and is not read.
#
# Usage: scripts/collect-pve-firewall-state.sh [--print]
#        scripts/collect-pve-firewall-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/pve-firewall-state.prom"
HOSTNAME_LABEL="$(hostname)"

# /etc/pve/local is Proxmox's own symlink to /etc/pve/nodes/<NODE>, so the
# node's capitalisation — `Saruman`, not `saruman` — is the host's problem and
# not this script's. §4 records a mis-cased host.fw as a rule set that silently
# does not exist; reading through the symlink cannot make that mistake.
CLUSTER_FW="${CLUSTER_FW:-/etc/pve/firewall/cluster.fw}"
HOST_FW="${HOST_FW:-/etc/pve/local/host.fw}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

STDERR_FILE="$(mktemp)"
trap 'rm -f "${STDERR_FILE}"' EXIT

# `pve-firewall status` prints `Status: <config>/<service>`: enabled or
# disabled, then running or stopped. Only `enabled/running` is a firewall
# filtering packets. `enabled/stopped` is a configuration nobody is applying,
# and is the state `pve-firewall stop` leaves behind — which is the ordinary way
# this goes off. Prints 1, 0, or nothing for output it does not recognise.
parse_status() {
  awk '
    /^Status:/ {
      split($2, s, "/")
      if ((s[1] == "enabled" || s[1] == "disabled") && (s[2] == "running" || s[2] == "stopped")) {
        print (s[1] == "enabled" && s[2] == "running") ? 1 : 0
        exit
      }
    }
  '
}

# Active rules in a .fw file's [RULES] section. A rule is a line opening with
# IN, OUT or GROUP; a leading `|` is Proxmox's spelling of a DISABLED rule and
# is not counted, since a rule switched off filters nothing. [group ...]
# sections carry rules too, but only fire when [RULES] calls the group, which
# is the line counted here.
count_rules() {
  awk '
    /^\[/ { in_rules = (toupper($0) ~ /^\[RULES\]/); next }
    in_rules && /^[[:space:]]*(IN|OUT|GROUP)[[:space:]]/ { n++ }
    END { print n + 0 }
  '
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" fn="$2" expect="$3" got
    got="$(printf '%s\n' "$4" | "$fn")"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  check "enabled/running is on" parse_status 1 "Status: enabled/running"
  # The state #566 found, word for word.
  check "disabled/running is off" parse_status 0 "Status: disabled/running"
  check "enabled/stopped is off — pve-firewall stop leaves this" parse_status 0 "Status: enabled/stopped"
  check "unrecognised output is not a verdict" parse_status "" "ipset: command not found"
  check "empty output is not a verdict" parse_status "" ""

  # Saruman's host.fw as §4 writes it: ADR-0014's three and ADR-0043's fourth.
  check "Saruman's host.fw counts four" count_rules 4 \
"[OPTIONS]
enable: 1

[RULES]
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8006 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8007 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 22 -log nolog
IN ACCEPT -source 10.0.30.70 -p tcp -dport 8006 -log nolog"
  # §4's cluster.fw carries an alias and options and no rules at all, and that
  # is correct — it must read 0, not fail.
  check "cluster.fw with options and an alias counts zero" count_rules 0 \
"[OPTIONS]
enable: 1
policy_in: ACCEPT

[ALIASES]
local_network 10.0.30.110"
  check "a disabled rule is not counted" count_rules 1 \
"[RULES]
|IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8006
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 22"
  check "a group call counts, the group body does not" count_rules 1 \
"[group mgmt]
IN ACCEPT -p tcp -dport 22

[RULES]
GROUP mgmt"
  check "an absent file counts zero" count_rules 0 ""
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v pve-firewall >/dev/null 2>&1 \
  || die "no pve-firewall on this host — it is not a Proxmox VE node."

# A STATUS THAT CANNOT BE READ IS NOT A FIREWALL THAT IS OFF, and it is not one
# that is on. Nothing is written, so PveFirewallStateStale says the reading
# stopped rather than PveFirewallDisabled guessing at it.
raw="$(pve-firewall status 2>"${STDERR_FILE}")"
rc=$?
enabled="$(printf '%s\n' "$raw" | parse_status)"
if ((rc != 0)) || [[ -z "$enabled" ]]; then
  detail="$(tr -d '\r' < "${STDERR_FILE}" | grep -v '^$' | tail -2 | paste -sd'; ' -)"
  die "pve-firewall status (exit ${rc}) gave no recognisable Status line:
${raw:-<empty>}${detail:+
${detail}}"
fi

# An absent file is 0 rules, which is a true reading: #566 found both absent.
rules_in() { if [[ -r "$1" ]]; then count_rules < "$1"; else echo 0; fi; }
cluster_rules="$(rules_in "${CLUSTER_FW}")"
host_rules="$(rules_in "${HOST_FW}")"

emit() {
  printf '# HELP homelab_pve_firewall_enabled 1 when pve-firewall status reads enabled/running.\n'
  printf '# TYPE homelab_pve_firewall_enabled gauge\n'
  printf 'homelab_pve_firewall_enabled{host="%s"} %s\n' "$HOSTNAME_LABEL" "$enabled"
  printf '# HELP homelab_pve_firewall_rules Active rules in a Proxmox firewall file'"'"'s [RULES] section.\n'
  printf '# TYPE homelab_pve_firewall_rules gauge\n'
  printf 'homelab_pve_firewall_rules{host="%s",file="cluster"} %s\n' "$HOSTNAME_LABEL" "$cluster_rules"
  printf 'homelab_pve_firewall_rules{host="%s",file="host"} %s\n' "$HOSTNAME_LABEL" "$host_rules"
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'pve-firewall-state host=%s enabled=%s cluster_rules=%s host_rules=%s\n' \
  "$HOSTNAME_LABEL" "$enabled" "$cluster_rules" "$host_rules"
