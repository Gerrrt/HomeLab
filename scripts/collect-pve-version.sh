#!/usr/bin/env bash
#
# The Proxmox VE version this hypervisor runs, as a metric (#311).
#
# THE CLAIM WITH NO LIVE COUNTERPART. check_versions.py compares what the
# documents say each host runs against what the host reports, and it skipped
# `Saruman` with a reason rather than passing it: the documents say "Proxmox VE
# 9", and nothing on the wire carries that number.
#
#     node_os_info      Debian GNU/Linux 13 (trixie)   the base PVE 9 is built on
#     node_uname_info   7.0.14-12-pve                  the KERNEL, not the product
#
# Neither is comparable to "Proxmox VE 9", and recording "Debian 13" instead
# would be worse — it would not tell a reader what the box is. So the claim was
# unfalsifiable, which is the condition #292 existed to remove.
#
# WHERE IT RUNS, which #311 called the real content of the issue. It cannot be
# pulled: the monitoring host cannot open TCP/22 to VLAN 30, which is the same
# reason deploy-agent.sh against `Saruman` needs someone at the Mac. So it is an
# AGENT-SIDE collector, installed by scripts/install-agent-collectors.sh
# alongside patch-state and smart-state, and written into the textfile directory
# the Alloy agent already reads. Nothing new is scraped and no new path opens.
#
# NO ROOT. `pveversion` reads /usr/share/perl5/PVE and the local package
# database; it needs no privilege. The unit runs as root only because the
# textfile directory on an agent host is root-owned — the same incidental reason
# the patch-state agent unit does, and stated so it is not mistaken for a
# requirement of the command.
#
# Usage: scripts/collect-pve-version.sh [--print]
#        scripts/collect-pve-version.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/pve-version.prom"
HOSTNAME_LABEL="$(hostname)"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# `pveversion` prints `pve-manager/9.0.10/<hash>`. That is the documented shape
# and the one this parses first — but it is parsed DEFENSIVELY rather than
# assumed, because this collector is written on a host that cannot run the
# command: VLAN 99 cannot reach VLAN 30, so the format could not be confirmed
# before shipping. If the leading form is absent it falls back to the first
# dotted version on the line, and if neither matches it FAILS carrying the raw
# string rather than emitting a version it guessed.
#
# That is the difference between a wrong number in Prometheus and an error
# naming what the host actually printed.
parse_pveversion() {
  awk '
    {
      if (match($0, /pve-manager\/[0-9][^\/ ]*/)) {
        v = substr($0, RSTART + 12, RLENGTH - 12)
        print v; exit
      }
    }
    END { if (v == "") exit 0 }
  ' | head -1
}

parse_fallback() {
  grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -1
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" expect="$2" raw="$3" got
    got="$(printf '%s\n' "$raw" | parse_pveversion)"
    [[ -z "$got" ]] && got="$(printf '%s\n' "$raw" | parse_fallback)"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s -> %s\n' "$name" "${got:-<none>}"
    else
      printf '\033[0;31m  FAIL\033[0m %s -> %s, expected %s\n' "$name" "${got:-<none>}" "$expect"
      fail=1
    fi
  }
  check "the documented shape"            "9.0.10"  "pve-manager/9.0.10/0d1a3c7b2e4f5a6b"
  check "no trailing hash"                "9.0.10"  "pve-manager/9.0.10"
  check "two-component version"           "9.0"     "pve-manager/9.0/abcdef"
  check "pveversion -v first line"        "9.0.10"  "proxmox-ve: 9.0.10 (running kernel: 7.0.14-12-pve)"
  check "bare version only"               "9.0.10"  "9.0.10"
  # The kernel must never be mistaken for the product. This line has both, and
  # the pve-manager form has to win — picking the first dotted number would
  # report 7.0.14 as the PVE version, which is the exact confusion #311 is about.
  check "kernel present, product wins"    "9.0.10"  "pve-manager/9.0.10/abc (running kernel: 7.0.14-12-pve)"
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v pveversion >/dev/null 2>&1 \
  || die "no pveversion on this host — it is not a Proxmox VE node.
This collector covers PVE hypervisors only; see the header."

raw="$(pveversion 2>/dev/null | head -1)"
[[ -n "$raw" ]] || die "pveversion produced no output"

version="$(printf '%s\n' "$raw" | parse_pveversion)"
[[ -n "$version" ]] || version="$(printf '%s\n' "$raw" | parse_fallback)"
[[ -n "$version" ]] || die "could not find a version in pveversion's output, which was:
  ${raw}
Neither the documented 'pve-manager/<version>/<hash>' form nor a bare dotted
version matched. Fix the parse in scripts/collect-pve-version.sh rather than
letting this emit a number it guessed."

# The release line, which is what the documents record and what
# check_versions.py compares on — "Proxmox VE 9", not "9.0.10". Both are
# emitted: the full version because it is the fact, the line because it is the
# claim.
release="${version%%.*}"

emit() {
  cat <<EOF
# HELP pve_version_info The Proxmox VE version this hypervisor runs.
# TYPE pve_version_info gauge
pve_version_info{host="${HOSTNAME_LABEL}",version="${version}",release="${release}"} 1
EOF
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'pve-version host=%s version=%s release=%s\n' "${HOSTNAME_LABEL}" "${version}" "${release}"
