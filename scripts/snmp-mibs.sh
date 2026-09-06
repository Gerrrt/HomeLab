#!/usr/bin/env bash
#
# Download the MIBs that `make snmp-generate` needs into a gitignored mibs/
# directory.
#
# The generator resolves numeric OIDs to names and types through net-snmp, and
# net-snmp can only do that for MIBs it has on disk. The prom/snmp-generator
# image ships thirteen NET-SNMP/UCD MIBs and none of the IETF or vendor ones,
# so without this `make snmp-generate` dies with
#
#   Error generating config netsnmp: cannot find oid '1.3.6.1.2.1.33.1' to walk
#
# These are not vendored into the repository: the HPE bundle alone is 5.5 MB of
# vendor-licensed files, and they are a build-time input rather than
# configuration. snmp.yaml — the thing the generator produces — IS committed,
# so a normal deploy never needs any of this.
#
# Sources mirror prometheus/snmp_exporter's own generator Makefile, so this
# tracks whatever upstream considers canonical — with one deliberate exception,
# written out at UPS_MIB_URL below.
#
# Usage:
#   scripts/snmp-mibs.sh            download anything missing
#   scripts/snmp-mibs.sh --force    re-download everything

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIBDIR="${REPO_ROOT}/stacks/observability/snmp-exporter/mibs"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

command -v curl >/dev/null 2>&1 || die "curl not found"
command -v tar  >/dev/null 2>&1 || die "tar not found"

# Pinned refs. net-snmp and FreeBSD are tags; the HPE URL embeds its own
# version; UPS-MIB is a commit.
#
# The UPS-MIB pin is the one place this deliberately diverges from upstream.
# snmp_exporter's generator Makefile fetches it from this mirror's master
# branch, and copying that verbatim is what this line used to do — which made
# it the single source in this file that could move under us. The generator
# resolves OIDs through whatever is on disk, so a changed MIB does not fail: it
# renders a different snmp.yaml, and the diff arrives looking like it came from
# nowhere. The `DEFINITIONS` sniff in fetch() below would not catch it either,
# because a moved MIB is still a MIB.
#
# 9064fa3 is the last commit to touch mibs/UPS-MIB there, in 2015. Pinning it
# changes the URL and not the bytes — verify with `make snmp-mibs ARGS=--force`
# followed by `make snmp-generate`, which must leave snmp.yaml untouched. Do not
# revert this to refs/heads/master when syncing the other sources against
# upstream; upstream not pinning it is not a reason for us not to.
#
# The other three are pinned by tag and by vendor build path, which is weaker
# than a commit — a tag can be moved too. Left as they are: they are first-party
# refs on projects that do not move release tags, which is a different risk from
# a branch on a third-party mirror. Nothing here is pinned by content.
NET_SNMP_URL='https://raw.githubusercontent.com/net-snmp/net-snmp/v5.9/mibs'
FREEBSD_URL='https://raw.githubusercontent.com/freebsd/freebsd-src/release/14.2.0'
UPS_MIB_URL='https://raw.githubusercontent.com/pgmillon/observium/9064fa3ae1ae634709198decf99aca7380693351/mibs/UPS-MIB'
# PowerNet, from the SAME observium commit as UPS-MIB above, which is the whole
# reason this line is cheap. #249 expected adding APC's vendor MIB to be "a
# pinning decision, not a URL" — Schneider distribute it as a versioned download
# rather than a git ref, so the options were vendoring 2.2 MB into the tree or
# trusting a moving vendor path. Neither is needed: the commit this repository
# already pins for UPS-MIB carries mibs/apc/PowerNet-MIB too, so this adds a
# path to an existing pin and inherits its argument unchanged.
POWERNET_MIB_URL='https://raw.githubusercontent.com/pgmillon/observium/9064fa3ae1ae634709198decf99aca7380693351/mibs/apc/PowerNet-MIB'
HPE_URL='https://downloads.hpe.com/pub/softlib2/software1/pubsw-linux/p1580676047/v229101/upd11.85mib.tar.gz'

CURL_OPTS=(-L -sS --retry 3 --retry-delay 3 --fail --max-time 180)

mkdir -p "${MIBDIR}"

# fetch <destination-name> <url>
fetch() {
  local name="$1" url="$2" dest="${MIBDIR}/$1"
  if [[ -s "${dest}" ]] && ((! FORCE)); then
    return 0
  fi
  curl "${CURL_OPTS[@]}" -o "${dest}" "${url}" || die "failed to download ${name} from ${url}"
  # A 200 that is not a MIB (a login page, an error document) would otherwise
  # sit there and produce a baffling parse failure much later.
  grep -q 'DEFINITIONS' "${dest}" \
    || die "${name} does not look like a MIB — the URL may have moved: ${url}"
}

# ---------------------------------------------------------------------------
# IETF core, from net-snmp. IF-MIB covers the switch, and everything else here
# is a dependency of one of the four modules rather than a module in its own
# right.
# ---------------------------------------------------------------------------
info "IETF core MIBs (net-snmp v5.9)"
for m in SNMPv2-SMI SNMPv2-TC SNMPv2-CONF SNMPv2-MIB IF-MIB IP-MIB \
         INET-ADDRESS-MIB HCNUM-TC HOST-RESOURCES-MIB IANAifType-MIB; do
  fetch "${m}" "${NET_SNMP_URL}/${m}.txt"
done

# ---------------------------------------------------------------------------
# UPS-MIB (RFC 1628) for the APC. net-snmp does not ship it.
# ---------------------------------------------------------------------------
info "UPS-MIB"
fetch UPS-MIB "${UPS_MIB_URL}"

# ---------------------------------------------------------------------------
# PowerNet, APC's own tree (1.3.6.1.4.1.318). UPS-MIB above covers battery,
# input, output and the LAST self-test result; it has no concept of a self-test
# SCHEDULE, which is the control #93 set and #249 found nothing watching.
#
# 2.2 MB and 70,663 lines for three scalars, which looks disproportionate and is
# not: the generator reads the whole tree to resolve three OIDs and emits only
# what generator.yaml asks for. The apc_ups module walks
# 1.3.6.1.4.1.318.1.1.1.7.2 and nothing else of 318 — walking the enterprise
# root is the pfTablesAddrTable mistake, one vendor along.
# ---------------------------------------------------------------------------
info "PowerNet-MIB (APC)"
fetch PowerNet-MIB "${POWERNET_MIB_URL}"

# ---------------------------------------------------------------------------
# pfSense exposes pf through FreeBSD's bsnmpd. BEGEMOT-PF-MIB imports from
# BEGEMOT-MIB, which imports from FOKUS-MIB; miss either and the generator
# fails with "Missing MIB" rather than merely losing the pfsense module.
# ---------------------------------------------------------------------------
info "FreeBSD bsnmpd MIBs (pfSense)"
fetch FOKUS-MIB      "${FREEBSD_URL}/contrib/bsnmp/snmpd/FOKUS-MIB.txt"
fetch BEGEMOT-MIB    "${FREEBSD_URL}/contrib/bsnmp/snmpd/BEGEMOT-MIB.txt"
fetch BEGEMOT-PF-MIB "${FREEBSD_URL}/usr.sbin/bsnmpd/modules/snmp_pf/BEGEMOT-PF-MIB.txt"

# ---------------------------------------------------------------------------
# HPE Insight, for the iLO. Only the *cpq* files are kept — the bundle also
# carries Cisco and VMware MIBs that nothing here walks. Matches what upstream
# extracts.
# ---------------------------------------------------------------------------
if [[ -n "$(find "${MIBDIR}" -maxdepth 1 -name 'cpq*' -print -quit)" ]] && ((! FORCE)); then
  info "HPE Insight MIBs already present"
else
  info "HPE Insight MIBs (5.5 MB download)"
  tmp="$(mktemp)"; tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmp}" "${tmpdir}"' EXIT INT TERM
  curl "${CURL_OPTS[@]}" \
    -H 'user-agent: Mozilla/5.0 snmp_exporter/generator' \
    -o "${tmp}" "${HPE_URL}" || die "failed to download the HPE MIB bundle from ${HPE_URL}"
  tar -xf "${tmp}" -C "${tmpdir}" || die "could not extract the HPE MIB bundle"
  # shellcheck disable=SC2312  # the find's own failure is what the -z tests
  if [[ -z "$(find "${tmpdir}" -name '*cpq*.mib' -print -quit)" ]]; then
    die "the HPE bundle contained no cpq*.mib files — its layout may have changed"
  fi
  find "${tmpdir}" -name '*cpq*.mib' -exec cp {} "${MIBDIR}/" \;
fi

count="$(find "${MIBDIR}" -maxdepth 1 -type f | wc -l)"
info "done — ${count} MIB(s) in stacks/observability/snmp-exporter/mibs/"
