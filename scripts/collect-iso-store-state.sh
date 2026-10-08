#!/usr/bin/env bash
#
# Whether the ISOs on `smaug-iso` are the ones this repository expects (#440,
# ADR-0072).
#
# THE GAP. The ISO store is an NFSv4 export of `erebor/iso` to `10.0.30.110`
# alone, and NFS with sec=sys authenticates by address. Anything on VLAN 30
# that took `Saruman`'s address could replace an installer, and every template
# Packer built from it afterwards would carry the change. ADR-0072 named the
# control: verify each ISO against a checksum kept in the repository. Packer
# cannot be that control. It checks `iso_checksum` when it downloads an ISO,
# not when it is handed one already in storage, which is how packer/ uses
# them (`iso_file`).
#
# WHY HERE AND NOT ON phoenix. phoenix runs Packer but reaches `Saruman` on
# 8006 alone (ADR-0043), has no route to `2049`, and the Proxmox API has no
# call that hashes a stored file. `Saruman` is the one host that mounts the
# share, so the check runs on it, daily, and the estate is told when it fails.
# A check run by hand before a build is the one scripts/packer-smoke.sh's
# header says drifts.
#
# WHAT IT REPORTS, per file in the share's template/iso directory and per file
# in EXPECTED below:
#   match     present, and its SHA-256 is the one listed
#   mismatch  present, and its SHA-256 is NOT the one listed   -> IsoChecksumMismatch
#   missing   listed, and not present                          -> IsoStoreUnexpected
#   unlisted  present, and not listed                          -> IsoStoreUnexpected
# and whether the share is mounted at all. An unmounted share is NOT hashed:
# the mountpoint is an empty immutable directory then (build-the-nas.md §5b
# step 6), and "every ISO missing" would be the wrong finding.
#
# THE WHOLE FILE, EVERY DAY. A tamperer can restore an mtime and a size, so
# caching by either would let a replaced ISO through until something else
# changed. The first four installers were about 15 GB, and #920's Debian and
# Fedora netinsts add under 2 GB, read once a day over NFS from the mirror at
# idle priority: minutes, not hours.
#
# Usage: scripts/collect-iso-store-state.sh [--print]
#        scripts/collect-iso-store-state.sh --self-test
set -uo pipefail

# THE EXPECTED LIST, and the only one. `sha256sum` format: hash, two spaces,
# the file's name as it sits in template/iso. A line is added when an ISO is
# placed on the share, from `sha256sum` on `Saruman`, cross-checked against
# the vendor's published hash where one exists (build-the-lab-templates.md
# §2b). Changing it means re-running `make install-agent-collectors
# AGENT=root@10.0.30.110 ARGS='--only iso-store-state'`, because the host has
# no checkout of this repository.
EXPECTED="$(cat <<'LIST'
# Ubuntu 26.04.1 live server. releases.ubuntu.com SHA256SUMS, with a good
# signature from Ubuntu's CD image key 8439 38DF 228D 22F7 B374 2BC0 D94A A3F0
# EFE2 1092. Matches Saruman's copy, 2026-10-01.
cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927  ubuntu-26.04.1-live-server-amd64.iso
# VirtIO 0.1.302. Fedora publishes no ISO hash, so the ISO was downloaded from
# fedorapeople.org over HTTPS on another host and hashed there: identical to
# Saruman's copy and to the virtio-win.iso the domain was built with.
303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d  virtio-win-0.1.302.iso
# Windows 11 26H2, English 64-bit. Microsoft's own hash, from the table on
# microsoft.com/software-download/windows11, read 2026-10-01. Listed from the
# publisher rather than from a download, so the file placed must be this one.
bd4307df32bc8af33b39ccecb1174aeb345386630f89a2b86c7a4e36b55ea650  windows-11-26h2.iso
# Kali 2026.2 installer, for #790's template. cdimage.kali.org/current
# SHA256SUMS, with a good signature from the Kali Linux Archive Automatic
# Signing Key (2025), 827C 8569 F251 8CC6 77FE CA1A ED65 462E C8D5 E4C5: the
# fingerprint kali.org's download docs and its new-signing-key post publish.
# Matches Saruman's copy, 2026-10-08.
6dbefacc95e3b556c19c48e8bae39b8b505e2d3a1aba0bfb7ab62b036c3d2ba3  kali-linux-2026.2-installer-amd64.iso
# Windows Server 2025 evaluation. Microsoft publishes no hash for evaluation
# media, so this is trusted from its download (build-the-lab-domain.md §1),
# not from a publisher. Matches Saruman's local copy, 2026-10-01.
7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51  windows-server-2025-eval.iso
# Debian 13.7.0 netinst, for tpl-debian-13 (#920). cdimage.debian.org
# SHA256SUMS, with a good signature from the Debian CD signing key DF9B 9C49
# EAA9 2984 3258 9D76 DA87 E80D 6294 BE9B, read 2026-10-07. Listed from the
# publisher, so the file placed must be this one.
a7ef94ac2fb9a7fec454552abd629b7cc9d5155c886165a45649f5ce6167e355  debian-13.7.0-amd64-netinst.iso
# Fedora Server 44 netinst, for tpl-fedora-server (#920). The release's
# CHECKSUM file, with a good signature from Fedora 44's primary key 36F6 12DC
# F27F 7D1A 48A8 35E4 DBFC F71C 6D9F 90A6, read 2026-10-07. Listed from the
# publisher, so the file placed must be this one.
ae20c06bea746913cadea7d80463e13f4bf55bee4df2918111c921c674b70283  Fedora-Server-netinst-x86_64-44-1.7.iso
LIST
)"

MOUNT_POINT="${ISO_MOUNT_POINT:-/mnt/smaug-iso}"
ISO_DIR="${ISO_DIR:-${MOUNT_POINT}/template/iso}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/iso-store-state.prom"
HOSTNAME_LABEL="$(hostname)"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Expected lines on stdin as "E <hash>  <name>", observed as "O <hash>  <name>".
# Output: "<state> <name>", sorted by name. Hashes compare case-insensitively,
# because vendors publish them in either case.
classify() {
  awk '
    function name_of(line) { sub(/^[EO] [^ ]+ +\*?/, "", line); return line }
    $1 == "E" { want[name_of($0)] = tolower($2); next }
    $1 == "O" { seen[name_of($0)] = tolower($2); next }
    END {
      for (f in seen) {
        if (!(f in want))            print "unlisted", f
        else if (seen[f] == want[f]) print "match", f
        else                         print "mismatch", f
      }
      for (f in want) if (!(f in seen)) print "missing", f
    }
  ' | sort -k2
}

# The files in a directory, NUL-separated, into a file, sorted. Returns
# non-zero if `find` or `sort` failed, and the caller then writes nothing.
# A listing is captured whole and checked BEFORE anything is hashed: a
# directory read that fails partway over NFS can still have printed some
# names, and hashing those would turn the rest into false `missing` states
# over the last good result. In a process substitution the failure would
# never reach this shell at all, which is how the first version had it.
enumerate_into() {
  local dir="$1" out="$2" raw="${2}.raw"
  find "$dir" -maxdepth 1 -type f -print0 > "$raw" || { rm -f "$raw"; return 1; }
  sort -z "$raw" > "$out" || { rm -f "$raw"; return 1; }
  rm -f "$raw"
}

# Every non-blank, non-comment line of EXPECTED must be a 64-hex hash, two
# spaces, and a name with no slash. A malformed line would otherwise be a file
# that can never match, which reads as tampering.
validate_expected() {
  local bad
  bad="$(printf '%s\n' "$1" | grep -v -E '^[[:space:]]*(#|$)' \
    | grep -v -E '^[0-9A-Fa-f]{64}  [^/]+$' || true)"
  [[ -z "$bad" ]] || { printf '%s\n' "$bad"; return 1; }
}

# Prometheus label values escape backslash, double quote and newline.
esc() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s//$'\n'/\\n}"
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  H1="$(printf 'a%.0s' {1..64})"
  H2="$(printf 'b%.0s' {1..64})"
  H3="$(printf 'c%.0s' {1..64})"
  check() {
    local name="$1" expect="$2" got
    got="$(printf '%s\n' "$3" | classify | tr '\n' ';')"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  check "a listed file with its hash matches" "match virtio-win-0.1.302.iso;" \
"E ${H1}  virtio-win-0.1.302.iso
O ${H1}  virtio-win-0.1.302.iso"
  check "a listed file with another hash is a mismatch, the finding that matters" \
    "mismatch windows-11.iso;" \
"E ${H1}  windows-11.iso
O ${H2}  windows-11.iso"
  check "a vendor's upper-case hash still matches sha256sum's lower case" \
    "match windows-11.iso;" \
"E $(printf '%s' "$H1" | tr a-f A-F)  windows-11.iso
O ${H1}  windows-11.iso"
  check "listed and absent is missing; present and unlisted is unlisted" \
    "unlisted stray.iso;missing ubuntu.iso;" \
"E ${H1}  ubuntu.iso
O ${H3}  stray.iso"
  check "sha256sum's binary-mode asterisk is not part of the name" \
    "match virtio-win.iso;" \
"E ${H1}  virtio-win.iso
O ${H1} *virtio-win.iso"
  check "a name with a space survives" "match Win 11.iso;" \
"E ${H1}  Win 11.iso
O ${H1}  Win 11.iso"
  check "an empty share with an empty list reports nothing" "" ""

  if validate_expected "${H1}  ok.iso
# a comment

${H2}  also-ok.iso" >/dev/null; then
    printf '\033[0;32m  PASS\033[0m %s\n' "a well-formed list validates"
  else
    printf '\033[0;31m  FAIL\033[0m %s\n' "a well-formed list validates"; fail=1
  fi
  if validate_expected "${H1} one-space.iso" >/dev/null \
     || validate_expected "abc  short-hash.iso" >/dev/null \
     || validate_expected "${H1}  sub/dir.iso" >/dev/null; then
    printf '\033[0;31m  FAIL\033[0m %s\n' "a malformed line is refused"; fail=1
  else
    printf '\033[0;32m  PASS\033[0m %s\n' "a malformed line is refused"
  fi
  # Enumeration: a directory that cannot be read must fail, not list nothing.
  tdir="$(mktemp -d)"
  printf x > "${tdir}/b.iso"; printf y > "${tdir}/a.iso"
  if enumerate_into "$tdir" "${tdir}.list" \
     && [[ "$(tr '\0' ';' < "${tdir}.list")" == "${tdir}/a.iso;${tdir}/b.iso;" ]]; then
    printf '\033[0;32m  PASS\033[0m %s\n' "a readable directory lists every file, sorted"
  else
    printf '\033[0;31m  FAIL\033[0m %s\n' "a readable directory lists every file, sorted"; fail=1
  fi
  if enumerate_into "${tdir}/does-not-exist" "${tdir}.list2" 2>/dev/null; then
    printf '\033[0;31m  FAIL\033[0m %s\n' "a failed listing is a failure, not an empty share"; fail=1
  else
    printf '\033[0;32m  PASS\033[0m %s\n' "a failed listing is a failure, not an empty share"
  fi
  rm -rf "$tdir" "${tdir}.list" "${tdir}.list2"
  # The list this script ships with, which is what CI is really guarding.
  if bad="$(validate_expected "$EXPECTED")"; then
    printf '\033[0;32m  PASS\033[0m %s\n' "the embedded EXPECTED list is well-formed"
  else
    printf '\033[0;31m  FAIL\033[0m %s\n%s\n' "the embedded EXPECTED list is well-formed" "$bad"; fail=1
  fi
  if [[ "$(esc 'a"b\c')" == 'a\"b\\c' ]]; then
    printf '\033[0;32m  PASS\033[0m %s\n' "label values are escaped"
  else
    printf '\033[0;31m  FAIL\033[0m %s\n' "label values are escaped"; fail=1
  fi
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

bad="$(validate_expected "$EXPECTED")" \
  || die "the EXPECTED list in this script has malformed lines:
${bad}"

mounted=0
mountpoint -q "${MOUNT_POINT}" 2>/dev/null && mounted=1

states=""
if ((mounted)); then
  [[ -d "${ISO_DIR}" ]] || die "${MOUNT_POINT} is mounted but has no ${ISO_DIR#"${MOUNT_POINT}"/}"
  # Hash first, then classify, so a read error is a failure and not a
  # "missing". Nothing is written on failure, and IsoStoreStateStale says so.
  listing="$(mktemp)"
  trap 'rm -f "${listing}"' EXIT
  enumerate_into "${ISO_DIR}" "${listing}" \
    || die "could not list ${ISO_DIR} — not writing a result that would read as missing"
  observed=""
  while IFS= read -r -d '' f; do
    line="$(ionice -c3 nice -n 19 sha256sum -- "$f")" \
      || die "could not hash ${f} — not writing a result that would read as missing"
    observed+="O ${line%% *}  ${f##*/}"$'\n'
  done < "${listing}"
  states="$( { printf '%s\n' "$EXPECTED" | grep -E '^[0-9A-Fa-f]{64}  ' | sed 's/^/E /'
               printf '%s' "$observed"; } | classify)"
fi

emit() {
  printf '# HELP homelab_iso_store_mounted 1 when the ISO store share is mounted on this host.\n'
  printf '# TYPE homelab_iso_store_mounted gauge\n'
  printf 'homelab_iso_store_mounted{host="%s",mountpoint="%s"} %s\n' \
    "$(esc "$HOSTNAME_LABEL")" "$(esc "$MOUNT_POINT")" "$mounted"
  printf '# HELP homelab_iso_state One series per ISO: match, mismatch, missing (listed, absent) or unlisted (present, not listed).\n'
  printf '# TYPE homelab_iso_state gauge\n'
  [[ -n "$states" ]] || return 0
  while read -r state file; do
    [[ -n "$state" ]] || continue
    printf 'homelab_iso_state{host="%s",file="%s",state="%s"} 1\n' \
      "$(esc "$HOSTNAME_LABEL")" "$(esc "$file")" "$state"
  done <<<"$states"
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'iso-store-state host=%s mounted=%s %s\n' "$HOSTNAME_LABEL" "$mounted" \
  "$(printf '%s\n' "$states" | awk 'NF { n[$1]++ } END { for (s in n) printf "%s=%d ", s, n[s] }')"
