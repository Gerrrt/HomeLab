#!/usr/bin/env bash
#
# Whether the hypervisor's Proxmox firewall is on, and how many rules it holds
# (#576).
#
# THE CONTROL, AND WHY IT NEEDS WATCHING. #566 found `Saruman`'s firewall
# DISABLED — `pve-firewall status` read `disabled/running`, with no `cluster.fw`
# and no `host.fw` — while ADR-0014 and ADR-0043 described the management-plane
# rule as standing. #566 turned it on, on 2026-09-20. Nothing noticed it was off
# for the whole of the time before that, and nothing would notice it going off
# again: a `pve-firewall stop` while debugging a guest that cannot reach the API,
# an upgrade that rewrites /etc/pve/firewall, or a reinstall from a runbook that
# skipped the step once already. The only check was a `nc -z` somebody ran once.
#
# WHAT IT EMITS.
#   homelab_pve_firewall_enabled        1 only for `enabled/running`. Enabled in
#                                       the config with the daemon stopped
#                                       filters nothing, and is 0 here.
#   homelab_pve_firewall_rules{file}    ACTIVE rules in cluster.fw and host.fw.
#                                       "Enabled with zero rules" is a firewall
#                                       applying only its policy, which is a
#                                       different state from the one #566 left.
#
# A rule is a line in a [RULES] section that starts with IN, OUT or GROUP. A
# line starting with `|` is a rule disabled in the GUI and is not counted —
# counting it is how "four rules" survives someone unticking all four.
#
# /etc/pve/local, NOT /etc/pve/nodes/$(hostname). pmxcfs points `local` at this
# node's own directory, and build-the-playground.md §4 records why the name is a
# trap: `Saruman` is capitalised, and a mis-cased path is a file Proxmox never
# reads. Reading through `local` cannot get that wrong.
#
# ROOT for the textfile directory, and because /etc/pve/firewall is root-only.
#
# Usage: scripts/collect-pve-firewall.sh [--print]
#        scripts/collect-pve-firewall.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/pve-firewall.prom"
HOSTNAME_LABEL="$(hostname)"
CLUSTER_FW="${CLUSTER_FW:-/etc/pve/firewall/cluster.fw}"
HOST_FW="${HOST_FW:-/etc/pve/local/host.fw}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

STDERR_FILE="$(mktemp)"
trap 'rm -f "${STDERR_FILE}"' EXIT

# `Status: enabled/running` -> `enabled/running`. Anything that does not have
# that shape prints nothing, and the caller refuses it.
parse_status() {
  sed -n 's/^[[:space:]]*Status:[[:space:]]*\([a-z]*\/[a-z]*\)[[:space:]]*$/\1/p' | head -1
}

# Active rules in a .fw file. Section headers are `[NAME]` in any case; rules
# are only counted inside [RULES].
count_rules() {
  awk '
    /^[[:space:]]*\[/ { in_rules = (toupper($0) ~ /^[[:space:]]*\[RULES\]/); next }
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
  check "status: the state #566 left" parse_status "enabled/running" "Status: enabled/running"
  check "status: the state #566 found" parse_status "disabled/running" "Status: disabled/running"
  check "status: enabled in config, daemon stopped" parse_status "enabled/stopped" "Status: enabled/stopped"
  check "status: output this does not recognise" parse_status "" "ipcc_send_rec[1] failed: Connection refused"
  # Saruman's host.fw as build-the-playground.md §4 writes it: ADR-0014's three
  # rules and ADR-0043's fourth.
  check "host.fw: Saruman's four rules" count_rules 4 \
"[OPTIONS]
enable: 1

[RULES]
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8006 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8007 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 22 -log nolog
IN ACCEPT -source 10.0.30.70 -p tcp -dport 8006 -log nolog"
  # The GUI's untick writes a leading `|`. Four lines that are not four rules.
  check "host.fw: disabled rules are not counted" count_rules 1 \
"[RULES]
|IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8006 -log nolog
|IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8007 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 22 -log nolog
|IN ACCEPT -source 10.0.30.70 -p tcp -dport 8006 -log nolog"
  # cluster.fw as §4 leaves it: options and the local_network alias, no rules.
  # The alias line must not be read as anything.
  check "cluster.fw: options and an alias are not rules" count_rules 0 \
"[OPTIONS]
enable: 1
policy_in: DROP

[ALIASES]
local_network 10.0.30.110"
  check "rules outside [RULES] are not counted" count_rules 1 \
"[group management]
IN ACCEPT -p tcp -dport 22

[RULES]
GROUP management"
  check "an absent file is zero rules" count_rules 0 ""
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v pve-firewall >/dev/null 2>&1 \
  || die "no pve-firewall on this host — it is not a Proxmox VE node."

# A STATUS THIS CANNOT READ IS NOT A FIREWALL THAT IS OFF. Reporting 0 for it
# would page PveFirewallDisabled for a broken collector; reporting 1 would hide a
# firewall that is off. So it reports nothing, the old .prom ages out, and
# PveFirewallStateStopped is the alert that says why.
status_raw="$(pve-firewall status 2>"${STDERR_FILE}")"
status_rc=$?
status="$(printf '%s\n' "$status_raw" | parse_status)"
if ((status_rc != 0)) || [[ -z "$status" ]]; then
  detail="$(tr -d '\r' < "${STDERR_FILE}" | grep -v '^$' | tail -2 | paste -sd'; ' -)"
  die "pve-firewall status (exit ${status_rc}) printed no recognisable status:
${status_raw:-<empty>}${detail:+
${detail}}
Refusing to report the firewall as on or off from output this does not understand."
fi

# An ABSENT file is zero rules and is the state #566 found — no cluster.fw, no
# host.fw. An UNREADABLE one is a collector problem, and dies for the same reason
# as the status above.
rules_in() {
  local f="$1"
  if [[ ! -e "$f" ]]; then echo 0; return 0; fi
  [[ -r "$f" ]] || die "${f} exists and cannot be read"
  count_rules < "$f"
}
cluster_rules="$(rules_in "$CLUSTER_FW")" || exit 1
host_rules="$(rules_in "$HOST_FW")" || exit 1

emit() {
  printf '# HELP homelab_pve_firewall_enabled 1 when pve-firewall status reads enabled/running.\n'
  printf '# TYPE homelab_pve_firewall_enabled gauge\n'
  printf 'homelab_pve_firewall_enabled{host="%s",status="%s"} %s\n' \
    "$HOSTNAME_LABEL" "$status" "$([[ "$status" == enabled/running ]] && echo 1 || echo 0)"
  printf '# HELP homelab_pve_firewall_rules Active rules in this Proxmox firewall file.\n'
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
printf 'pve-firewall host=%s status=%s cluster_rules=%s host_rules=%s\n' \
  "$HOSTNAME_LABEL" "$status" "$cluster_rules" "$host_rules"
