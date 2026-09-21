#!/usr/bin/env bash
#
# Carry the newest set of each kind onto the medium that leaves the estate,
# and prove that what is on it is what was written.
#
# WHAT THIS IS
#
# Three artefacts leave the monitoring host today — the firewall export
# (backup-firewall.sh, nightly), the volume sets (backup-volumes.sh, weekly)
# and the NAS set (backup-nas.sh, weekly) — and every copy of each sits on the
# same shelf: here, and on oracle. ADR-0048 sends one copy of each beyond it,
# on the offline medium that holds the second age recipient (ADR-0024, #294),
# which is off-estate by construction and already owes this host a visit every
# ninety days to prove that key. This script is what that visit runs against
# the medium, and it is the third human job with a deadline and no timer, after
# verify-key-backup and verify-ca-key-backup.
#
# It moves nothing over a network. DEST is a mounted directory, and the whole
# point is that it is a directory on a disk that will be somewhere else by
# tonight. A copy that lands on this host's own disk is not offsite, and the
# script refuses it by filesystem device rather than by path, the way
# verify-key-backup.sh refuses the live key by device and inode.
#
# WHAT IT COPIES, AND WHAT IT KEEPS
#
# The newest COMPLETE set of each kind that the medium does not already hold:
# the newest volume set for STACK, the newest NAS set, the newest firewall
# export. Not every set — the sets change little, a visit is ninety days, and a
# successor rebuilding from nothing wants the newest one of each. OFFSITE_KEEP
# (default 1) bounds each kind on the medium, the newest is never evicted, and
# only names this script would have written are ever removed — the posture
# backup-volumes.sh prune() sets, and backup-firewall.sh after it.
#
# The layout on the medium mirrors oracle's rather than this host's:
#
#   DEST/backups/volumes/<stack>/<STAMP>/   the volume set, MANIFEST last
#   DEST/backups/nas/<STAMP>/               the NAS set, MANIFEST last
#   DEST/backups/firewall/config-<STAMP>.sops.yaml, and a .sha256 beside it
#
# so a restore is "copy the directory back into backups/" and then the restore
# runbook as written. Everything on the medium is ciphertext to the estate's
# age recipients, exactly as it is here and on oracle; nothing is re-encrypted
# and no key is read.
#
# WHAT A RUN PROVES
#
# Before it writes anything, a run re-verifies every complete set already on
# the medium against that set's own MANIFEST — the hashes were computed on
# bytes verify() had just decrypted, and the far-side check on oracle uses the
# same column. That is the proof that LAST visit's bytes survived ninety days
# on the medium, and it is a stronger claim than hashing a copy the page cache
# still holds. Then it copies, syncs, and hashes the new copy the same way. A
# set that differs fails the run and is named with its repair; nothing is
# deleted on a failure path.
#
# The run is wrapped by run-scheduled.sh under the job name offsite-copy, so a
# success is a timestamp Prometheus can read and OffsiteCopyStale fires when it
# passes ninety days — the deadline lives in the JOBS table in
# install-timers.sh, beside the two key proofs, and nowhere else. --list,
# --verify-only and --prune run unwrapped from the Makefile on purpose:
# inspecting the medium is not the same as refreshing it, and must not reset
# the clock.
#
# ONE COPY OF RECORD. ADR-0024's argument applies to sets as much as to keys:
# nothing records a copy, so two media would share one timestamp and proving
# either would vouch for the other. The medium of record is the second
# recipient's. A copy anywhere else is a convenience nothing here can see.
#
# Usage:
#   scripts/backup-offsite.sh <DEST>                 re-verify, copy the newest of each kind, prove, prune
#   scripts/backup-offsite.sh <DEST> --list          what is here and what is on the medium
#   scripts/backup-offsite.sh <DEST> --verify-only   re-verify every complete set on the medium; writes nothing
#   scripts/backup-offsite.sh <DEST> --prune         apply OFFSITE_KEEP on the medium only
#   scripts/backup-offsite.sh --self-test            the refusals and the proof, against a throwaway tree
#
# Environment:
#   STACK           default observability   whose volume sets travel
#   OFFSITE_KEEP    default 1               complete sets of each kind to keep on the medium
#   OFFSITE_SOURCE  default <repo>/backups  where the sets are read from (the self-test overrides it)
#
# See docs/runbooks/copy-the-backups-offsite.md and ADR-0048.

# shellcheck disable=SC2016
# ^ the self-test hands assert() test expressions as single-quoted strings, on purpose.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# --self-test: the refusals and the proof, against a throwaway tree
# ---------------------------------------------------------------------------
# The real run needs a mounted medium and cannot happen in CI; the logic can,
# against a fake backups/ tree in a temp directory and a DEST on /dev/shm,
# which is a different filesystem from anything under /tmp on every Linux this
# runs on. OFFSITE_SOURCE points the script at the fake tree, so nothing here
# reads the host's backups/ or writes its textfile directory (the wrapper is
# not involved: this calls the script directly).
if [[ "${1:-}" == "--self-test" ]]; then
  T="$(mktemp -d)"
  INSIDE="${REPO_ROOT}/backups/.offsite-selftest.$$"
  trap 'rm -rf "${T}" "${INSIDE}"; rmdir "${REPO_ROOT}/backups" 2>/dev/null; [[ -n "${M:-}" ]] && rm -rf "${M}"' EXIT INT TERM
  if [[ -d /dev/shm && -w /dev/shm ]]; then
    M="$(mktemp -d -p /dev/shm homelab-offsite-selftest.XXXXXX)"
  else
    M=""
  fi
  SRC="${T}/backups"
  mkdir -p "${SRC}/volumes" "${SRC}/nas" "${SRC}/firewall" "${T}/same-device" "${INSIDE}"

  # A set is a directory of *.tar.gz.age files and a MANIFEST whose five-field
  # rows are volume, service, mount, bytes, sha256 — the columns
  # backup-volumes.sh writes and manifest_*() below read.
  fake_set() {  # <dir> <stamp> <kind> <vol>...
    local dir="$1" stamp="$2" kind="$3"; shift 3
    local d="${dir}/${stamp}" v bytes sha
    mkdir -p "${d}"
    {
      printf '# %s set %s\nstack\tobservability\nmode\tquiesced\n' "${kind}" "${stamp}"
      printf '#volume\tservice\tmount\tbytes\tsha256\n'
    } > "${d}/MANIFEST.tmp"
    for v in "$@"; do
      head -c 4096 /dev/urandom > "${d}/${v}.tar.gz.age"
      bytes="$(stat -c %s "${d}/${v}.tar.gz.age")"
      sha="$(sha256sum "${d}/${v}.tar.gz.age" | cut -d' ' -f1)"
      printf '%s\t%s\t/x\t%s\t%s\n' "${v}" "${v}" "${bytes}" "${sha}" >> "${d}/MANIFEST.tmp"
    done
    mv "${d}/MANIFEST.tmp" "${d}/MANIFEST"
  }
  fake_set "${SRC}/volumes" 20260901T000000Z backup-volumes.sh grafana-data loki-data
  fake_set "${SRC}/volumes" 20260908T000000Z backup-volumes.sh grafana-data loki-data
  mkdir -p "${SRC}/volumes/20260915T000000Z"           # INCOMPLETE: no MANIFEST
  head -c 100 /dev/urandom > "${SRC}/volumes/20260915T000000Z/grafana-data.tar.gz.age"
  fake_set "${SRC}/nas" 20260907T000000Z backup-nas.sh jellyfin-config
  head -c 2048 /dev/urandom > "${SRC}/firewall/config-20260910T000000Z.sops.yaml"
  head -c 2048 /dev/urandom > "${SRC}/firewall/config-20260911T000000Z.sops.yaml"

  fail=0
  run() {  # <args...>  → OUT, RC
    set +e
    OUT="$(OFFSITE_SOURCE="${SRC}" STACK=observability OFFSITE_KEEP="${KEEP_FOR_TEST:-1}" "${BASH_SOURCE[0]}" "$@" 2>&1)"
    RC=$?
    set -e
  }
  # The expression is a string on purpose: [[ ]] is not a command a function
  # can be handed, and the test must be evaluated inside an `if` so set -e
  # does not end the self-test on the first false assertion.
  assert() {  # <name> <bash test expression, as a string>
    if eval "$2"; then printf '\033[0;32m  PASS\033[0m %s\n' "$1"
    else printf '\033[0;31m  FAIL\033[0m %s\n' "$1"; fail=1; fi
  }
  check() {  # <name> <expected rc> <expected substring>
    if [[ "${RC}" == "$2" && "${OUT}" == *"$3"* ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$1"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       exit %s, wanted %s; wanted output containing: %s\n' "$1" "${RC}" "$2" "$3"
      printf '%s\n' "${OUT}" | sed 's/^/       | /'
      fail=1
    fi
  }

  run;                            check "no DEST is a usage error" 2 "usage"
  run "${T}/nowhere";             check "a DEST that does not exist is refused" 1 "no such directory"
  run "${INSIDE}";                check "a DEST inside this repository is refused" 1 "inside this repository"
  run "${T}/same-device";         check "a DEST on the same filesystem as the sets is refused" 1 "same filesystem"
  # ^ mktemp makes ${T} on the same device as ${SRC} by construction.

  if [[ -z "${M}" ]]; then
    printf '\033[0;33m  SKIP\033[0m /dev/shm is not available — the copy fixtures need a second filesystem\n'
    exit "${fail}"
  fi

  run "${M}" --list;              check "--list on an empty medium says so" 0 "nothing on the medium"
  run "${M}" --verify-only;       check "--verify-only on an empty medium is not a proof" 1 "nothing to verify"
  run "${M}";                     check "the first copy lands and is proved" 0 "copied 20260908T000000Z"
  assert "the newest NAS set and the newest export travelled too" \
    '[[ "${OUT}" == *"copied 20260907T000000Z"* && "${OUT}" == *"copied config-20260911T000000Z"* ]]'
  assert "only the newest COMPLETE set travelled, into the stack directory" \
    '[[ -d "${M}/backups/volumes/observability/20260908T000000Z" && ! -e "${M}/backups/volumes/observability/20260915T000000Z" && ! -e "${M}/backups/volumes/observability/20260901T000000Z" ]]'
  assert "the export carries its sha256 beside it" \
    '[[ -f "${M}/backups/firewall/config-20260911T000000Z.sops.yaml.sha256" ]]'

  run "${M}" --verify-only;       check "--verify-only proves what the medium holds" 0 "every set on the medium verifies"
  run "${M}";                     check "a second run re-verifies and has nothing new to copy" 0 "already holds"

  # A newer set appears here; the medium gets it and OFFSITE_KEEP=1 evicts the
  # old one — after the new one is complete, never before.
  fake_set "${SRC}/volumes" 20260920T000000Z backup-volumes.sh grafana-data loki-data
  run "${M}";                     check "a newer set replaces the old one" 0 "copied 20260920T000000Z"
  assert "OFFSITE_KEEP=1 evicted the older set and kept the newest" \
    '[[ ! -e "${M}/backups/volumes/observability/20260908T000000Z" && -f "${M}/backups/volumes/observability/20260920T000000Z/MANIFEST" ]]'

  # Tamper with one byte on the medium: the next verify must name it.
  printf 'x' | dd of="${M}/backups/volumes/observability/20260920T000000Z/loki-data.tar.gz.age" bs=1 seek=10 conv=notrunc status=none
  run "${M}" --verify-only;       check "a tampered archive on the medium fails the verify" 1 "differs from its MANIFEST"
  run "${M}";                     check "a run does not copy over a medium that fails to verify" 1 "differs from its MANIFEST"
  # Repair by removing the bad set and letting the run copy again.
  rm -rf "${M}/backups/volumes/observability/20260920T000000Z"
  run "${M}";                     check "removing the bad set lets the run copy it again" 0 "copied 20260920T000000Z"

  # An export tampered with fails the same way.
  printf 'x' | dd of="${M}/backups/firewall/config-20260911T000000Z.sops.yaml" bs=1 seek=10 conv=notrunc status=none
  run "${M}" --verify-only;       check "a tampered export on the medium fails the verify" 1 "differs from its recorded sha256"
  rm -f "${M}/backups/firewall/config-20260911T000000Z.sops.yaml" "${M}/backups/firewall/config-20260911T000000Z.sops.yaml.sha256"
  run "${M}";                     check "the export is copied again once removed" 0 "copied config-20260911T000000Z"

  # A stray on the medium is counted and never touched.
  mkdir -p "${M}/backups/volumes/observability/not-a-stamp"
  run "${M}" --prune;             check "a stray directory on the medium is reported, not removed" 0 "not-a-stamp"
  assert "the stray is still there" '[[ -d "${M}/backups/volumes/observability/not-a-stamp" ]]'

  KEEP_FOR_TEST=0 run "${M}" --list; check "OFFSITE_KEEP=0 is rejected" 1 "OFFSITE_KEEP must be a positive integer"
  exit "${fail}"
fi

# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------
# backup-volumes.sh is sourced for the set helpers, the MANIFEST readers,
# is_stamp(), the colours, die() and need(); it returns at its source guard
# before parsing arguments. VOL_OFFHOST is set first only because it validates
# that value while loading and the environment file the timers share could
# hand it something unrelated to this run; nothing here ever contacts it.
STACK="${STACK:-observability}"
VOL_OFFHOST="atropos@10.0.99.30:backups/volumes/${STACK}"
# shellcheck source=scripts/backup-volumes.sh
source "${REPO_ROOT}/scripts/backup-volumes.sh"

SOURCE_ROOT="${OFFSITE_SOURCE:-${REPO_ROOT}/backups}"
OFFSITE_KEEP="${OFFSITE_KEEP:-1}"

# Rejected rather than clamped, as backup-firewall.sh rejects FW_KEEP: a
# mistyped value is not a request to empty the medium.
if ! [[ ${OFFSITE_KEEP} =~ ^[0-9]+$ ]] || ((OFFSITE_KEEP < 1)); then
  die "OFFSITE_KEEP must be a positive integer, got '${OFFSITE_KEEP}'"
fi

usage() { sed -n 's|^# \{0,1\}||; /^Usage:/,/^$/p' "$0" | head -20; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
MODE=copy
DEST=""
while (($#)); do
  case "$1" in
    --list)        MODE=list ;;
    --verify-only) MODE=verify ;;
    --prune)       MODE=prune ;;
    -h|--help)     usage; exit 0 ;;
    --*)           usage >&2; die "unknown argument: $1" ;;
    *)             [[ -z ${DEST} ]] || die "one DEST only, got '${DEST}' and '$1'"; DEST="$1" ;;
  esac
  shift
done

if [[ -z ${DEST} ]]; then
  usage >&2
  printf '\nusage: mount the medium, then:  make backup-offsite DEST=/path/to/the/medium\n' >&2
  exit 2
fi

need sha256sum
need cmp
need df

# ---------------------------------------------------------------------------
# The destination has to be somewhere else
# ---------------------------------------------------------------------------
[[ -d ${DEST} ]] || die "no such directory: ${DEST}
Mount the medium first. The path is a directory on it, not a device."
DEST_ABS="$(cd "${DEST}" && pwd -P)"

# 1. Not inside this repository. This tree is published; backups/ is
#    gitignored by path, which protects nothing under another name.
if [[ "${DEST_ABS}" == "${REPO_ROOT}" || "${DEST_ABS}" == "${REPO_ROOT}/"* ]]; then
  die "the destination is inside this repository:
  ${DEST_ABS}

This tree is published. A copy of the estate's backups belongs on a medium
that leaves the house, not in a working tree of a public repository."
fi

# 2. Not on this host's own disk. Device number, not path: a bind mount or a
#    symlink into the root filesystem would otherwise pass. The comparison is
#    against the filesystem the sets live on and against /, since a laptop
#    with one partition has those be the same thing and a medium never is.
fs_of() { stat -c %d "$1" 2>/dev/null; }
src_probe="${SOURCE_ROOT}"
while [[ ! -e ${src_probe} && ${src_probe} != / ]]; do src_probe="$(dirname "${src_probe}")"; done
dest_fs="$(fs_of "${DEST_ABS}")"
if [[ -n ${dest_fs} ]] && { [[ ${dest_fs} == "$(fs_of "${src_probe}")" ]] || [[ ${dest_fs} == "$(fs_of /)" ]]; }; then
  die "the destination is on the same filesystem as the sets it would copy:
  ${DEST_ABS}

A copy on this host's own disk is off-host to nowhere. Point this at the
mounted medium — the one the second age recipient lives on (ADR-0048):
docs/runbooks/copy-the-backups-offsite.md"
fi

# 3. Advice, not a verdict, as verify-key-backup.sh gives it. The script cannot
#    see whether a working tree has a remote or what a folder syncs to.
if dest_repo="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "${DEST_ABS}" rev-parse --show-toplevel 2>/dev/null)"; then
  warn "the destination is inside a git working tree:  ${dest_repo}"
  warn "if that repository has a remote, one 'git add .' publishes the estate's backups."
fi
for pattern in Dropbox OneDrive 'Google Drive' Nextcloud ownCloud Syncthing iCloud 'Mobile Documents'; do
  shopt -s nocasematch
  if [[ "${DEST_ABS}" == *"${pattern}"* ]]; then
    warn "the path contains '${pattern}' — if that folder syncs to a third party, the sets are now wherever that service keeps them."
  fi
  shopt -u nocasematch
done

# ---------------------------------------------------------------------------
# The three kinds
# ---------------------------------------------------------------------------
VOL_SRC="${SOURCE_ROOT}/volumes"
NAS_SRC="${SOURCE_ROOT}/nas"
FW_SRC="${SOURCE_ROOT}/firewall"
VOL_DST="${DEST_ABS}/backups/volumes/${STACK}"
NAS_DST="${DEST_ABS}/backups/nas"
FW_DST="${DEST_ABS}/backups/firewall"

# Complete sets under a directory, newest first — complete_sets() from the
# library reads OUT_DIR, and there are three directories here.
sets_in()      { find "$1" -mindepth 2 -maxdepth 2 -name MANIFEST -printf '%h\n' 2>/dev/null | sort -r; }
all_dirs_in()  { find "$1" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r; }
exports_in()   { find "$1" -mindepth 1 -maxdepth 1 -type f -name 'config-*.sops.yaml' -printf '%f\n' 2>/dev/null | sort -r; }
is_export()    { [[ $1 =~ ^config-[0-9]{8}T[0-9]{6}Z\.sops\.yaml$ ]]; }

# ---------------------------------------------------------------------------
# Proof: every archive of a set hashes to its MANIFEST; an export to its sidecar
# ---------------------------------------------------------------------------
# The MANIFEST column was computed on bytes verify() had just decrypted, and
# the far-side check on oracle compares against the same column — so the
# medium is held to exactly the standard oracle is. Named with the repair on
# failure; nothing is deleted here.
verify_set_dir() {  # <set dir on the medium>
  local d="$1" stamp vol want got failed=0
  stamp="$(basename "${d}")"
  is_stamp "${stamp}" || { red "refusing to check a set with an unexpected name: ${stamp}"; return 1; }
  local -a vols=()
  mapfile -t vols < <(manifest_volumes "${d}")
  ((${#vols[@]})) || { red "${d}: the MANIFEST lists no volumes"; return 1; }
  for vol in "${vols[@]}"; do
    want="$(manifest_sha "${d}" "${vol}")"
    [[ -n ${want} ]] || { red "${d}: no sha256 for ${vol} in the MANIFEST"; failed=1; continue; }
    if [[ ! -f ${d}/${vol}.tar.gz.age ]]; then
      red "${d}/${vol}.tar.gz.age is missing although the MANIFEST lists it"
      failed=1; continue
    fi
    got="$(sha256sum -- "${d}/${vol}.tar.gz.age" | cut -d' ' -f1)"
    if [[ ${got} != "${want}" ]]; then
      red "${d}/${vol}.tar.gz.age differs from its MANIFEST entry (sha256 ${got:0:12}… on the medium, ${want:0:12}… recorded)"
      failed=1
    fi
  done
  return "${failed}"
}

verify_export_file() {  # <export on the medium>
  local f="$1" want got
  [[ -f ${f}.sha256 ]] || { red "${f} has no .sha256 beside it — not written by this script, or half-copied"; return 1; }
  want="$(cut -d' ' -f1 "${f}.sha256")"
  got="$(sha256sum -- "${f}" | cut -d' ' -f1)"
  if [[ ${got} != "${want}" ]]; then
    red "${f} differs from its recorded sha256 (${got:0:12}… on the medium, ${want:0:12}… recorded)"
    return 1
  fi
  return 0
}

# Every complete thing on the medium. Returns 1 if anything differs, 2 if
# there was nothing to check at all — --verify-only treats an empty medium as
# not a proof, and the copy path treats it as a first visit.
verify_medium() {
  local d f n=0 failed=0
  while read -r d; do
    [[ -n ${d} ]] || continue
    verify_set_dir "${d}" || failed=1
    n=$((n + 1))
  done < <(sets_in "${VOL_DST}"; sets_in "${NAS_DST}")
  while read -r f; do
    [[ -n ${f} ]] || continue
    verify_export_file "${FW_DST}/${f}" || failed=1
    n=$((n + 1))
  done < <(exports_in "${FW_DST}")
  ((n)) || return 2
  ((failed)) && return 1
  green "every set on the medium verifies — ${n} item(s): each archive hashes to its MANIFEST entry, each export to its sha256"
  return 0
}

# ---------------------------------------------------------------------------
# Copy: into a .part name, MANIFEST last, then renamed — a copy that dies
# leaves something INCOMPLETE by the same rule as everywhere else here, never a
# plausible-looking set that is short.
# ---------------------------------------------------------------------------
copy_set() {  # <local set dir> <destination kind dir>
  local src="$1" dstdir="$2" stamp part vol
  stamp="$(basename "${src}")"
  is_stamp "${stamp}" || { red "refusing to copy a set with an unexpected name: ${stamp}"; return 1; }
  part="${dstdir}/${stamp}.part"
  local -a vols=()
  mapfile -t vols < <(manifest_volumes "${src}")
  ((${#vols[@]})) || { red "${stamp}: the MANIFEST lists no volumes — not copying it"; return 1; }
  # A .part of this exact stamp is this script's own leftover from a copy that
  # died; nothing else writes that name.
  rm -rf -- "${part}"
  mkdir -p -- "${part}"
  for vol in "${vols[@]}"; do
    [[ -f ${src}/${vol}.tar.gz.age ]] || { red "${stamp}: ${vol}.tar.gz.age is missing here although the MANIFEST lists it"; return 1; }
    cp -- "${src}/${vol}.tar.gz.age" "${part}/${vol}.tar.gz.age"
  done
  cp -- "${src}/MANIFEST" "${part}/MANIFEST"
  sync -f "${part}" 2>/dev/null || sync
  mv -- "${part}" "${dstdir}/${stamp}"
  verify_set_dir "${dstdir}/${stamp}" || { red "${stamp}: the copy on the medium does not hash to its MANIFEST"; return 1; }
  cmp -s -- "${src}/MANIFEST" "${dstdir}/${stamp}/MANIFEST" \
    || { red "${stamp}: MANIFEST on the medium differs from the local one"; return 1; }
  green "copied ${stamp} to ${dstdir} — every archive hashes to its MANIFEST entry"
}

copy_export() {  # <local export file>
  local src="$1" name sha
  name="$(basename "${src}")"
  is_export "${name}" || { red "refusing to copy an export with an unexpected name: ${name}"; return 1; }
  mkdir -p -- "${FW_DST}"
  sha="$(sha256sum -- "${src}" | cut -d' ' -f1)"
  cp -- "${src}" "${FW_DST}/${name}.part"
  sync -f "${FW_DST}" 2>/dev/null || sync
  printf '%s  %s\n' "${sha}" "${name}" > "${FW_DST}/${name}.sha256"
  mv -- "${FW_DST}/${name}.part" "${FW_DST}/${name}"
  cmp -s -- "${src}" "${FW_DST}/${name}" || { red "${name}: the copy on the medium is not byte-identical"; return 1; }
  green "copied ${name} to ${FW_DST} — byte-identical, sha256 recorded beside it"
}

# ---------------------------------------------------------------------------
# Retention on the medium: OFFSITE_KEEP per kind, newest never, only names
# this script writes, strays counted and never touched.
# ---------------------------------------------------------------------------
prune_kind() {  # <kind dir on the medium>
  local dir="$1" n name
  [[ -d ${dir} ]] || return 0
  local -a keep=() strays=()
  mapfile -t keep < <(sets_in "${dir}")
  while read -r name; do
    [[ -n ${name} ]] || continue
    is_stamp "${name}" || { strays+=("${name}"); continue; }
  done < <(all_dirs_in "${dir}")
  if ((${#strays[@]})); then
    warn "${#strays[@]} name(s) in ${dir} this script did not write and will not touch: ${strays[*]}"
  fi
  if ((${#keep[@]} > OFFSITE_KEEP)); then
    for n in "${keep[@]:OFFSITE_KEEP}"; do
      if [[ -z ${n} || ${n} != "${dir}/"[0-9]* || ! -f ${n}/MANIFEST ]]; then
        red "refusing to prune ${n}"; continue
      fi
      info "pruning $(basename "${n}") from ${dir}"
      rm -rf -- "${n}"
    done
  fi
}

prune_exports() {
  local -a names=()
  [[ -d ${FW_DST} ]] || return 0
  mapfile -t names < <(exports_in "${FW_DST}")
  local n
  if ((${#names[@]} > OFFSITE_KEEP)); then
    for n in "${names[@]:OFFSITE_KEEP}"; do
      is_export "${n}" || { red "refusing to prune ${n}"; continue; }
      info "pruning ${n} from ${FW_DST}"
      rm -f -- "${FW_DST}/${n}" "${FW_DST}/${n}.sha256"
    done
  fi
}

prune_medium() { prune_kind "${VOL_DST}"; prune_kind "${NAS_DST}"; prune_exports; }

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
list_side() {  # <label> <vol dir> <nas dir> <fw dir>
  local label="$1" v="$2" n="$3" f="$4" x c=0
  info "${label}"
  while read -r x; do [[ -n ${x} ]] && { printf '  volumes/%s\t%s\n' "${STACK}" "$(basename "${x}")"; c=$((c + 1)); }; done < <(sets_in "${v}")
  while read -r x; do [[ -n ${x} ]] && { printf '  nas\t\t%s\n' "$(basename "${x}")"; c=$((c + 1)); }; done < <(sets_in "${n}")
  while read -r x; do [[ -n ${x} ]] && { printf '  firewall\t%s\n' "${x}"; c=$((c + 1)); }; done < <(exports_in "${f}")
  ((c)) || printf '  (nothing)\n'
  return 0
}

if [[ ${MODE} == list ]]; then
  list_side "complete here, newest first (${SOURCE_ROOT})" "${VOL_SRC}" "${NAS_SRC}" "${FW_SRC}"
  if [[ -d ${DEST_ABS}/backups ]]; then
    list_side "on the medium (${DEST_ABS}/backups), keeping ${OFFSITE_KEEP} of each" "${VOL_DST}" "${NAS_DST}" "${FW_DST}"
  else
    info "nothing on the medium yet (${DEST_ABS}/backups does not exist)"
  fi
  exit 0
fi

if [[ ${MODE} == verify ]]; then
  rc=0
  verify_medium || rc=$?
  case "${rc}" in
    0) exit 0 ;;
    2) red "nothing to verify on the medium — ${DEST_ABS}/backups holds no complete set"; exit 1 ;;
    *) red "the medium does not verify. A set that differs is not repaired here: remove that one directory (or export) on the medium and run the copy again"; exit 1 ;;
  esac
fi

if [[ ${MODE} == prune ]]; then
  prune_medium
  exit 0
fi

# ---------------------------------------------------------------------------
# The copy of record: re-verify, copy what is missing, prove, prune
# ---------------------------------------------------------------------------
rc=0
verify_medium || rc=$?
case "${rc}" in
  0) ;;
  2) info "first visit — nothing on the medium to re-verify" ;;
  *) die "the medium does not verify, so nothing is written to it. Remove the set (or export) named above from the medium and run again." ;;
esac

# What travels: the newest complete of each kind that the medium lacks.
newest_vol="$(sets_in "${VOL_SRC}" | head -1)"
newest_nas="$(sets_in "${NAS_SRC}" | head -1)"
newest_fw="$(exports_in "${FW_SRC}" | head -1)"
[[ -n ${newest_vol} || -n ${newest_nas} || -n ${newest_fw} ]] \
  || die "nothing complete under ${SOURCE_ROOT} — run the backups first (make backup, make backup-nas, make backup-firewall)"

todo_vol=""; todo_nas=""; todo_fw=""
need_bytes=0
if [[ -n ${newest_vol} ]]; then
  if [[ -f ${VOL_DST}/$(basename "${newest_vol}")/MANIFEST ]]; then
    info "the medium already holds $(basename "${newest_vol}") (volumes/${STACK})"
  else
    todo_vol="${newest_vol}"; need_bytes=$((need_bytes + $(manifest_bytes "${newest_vol}")))
  fi
else
  warn "no complete volume set under ${VOL_SRC}"
fi
if [[ -n ${newest_nas} ]]; then
  if [[ -f ${NAS_DST}/$(basename "${newest_nas}")/MANIFEST ]]; then
    info "the medium already holds $(basename "${newest_nas}") (nas)"
  else
    todo_nas="${newest_nas}"; need_bytes=$((need_bytes + $(manifest_bytes "${newest_nas}")))
  fi
else
  warn "no complete NAS set under ${NAS_SRC}"
fi
if [[ -n ${newest_fw} ]]; then
  if [[ -f ${FW_DST}/${newest_fw} && -f ${FW_DST}/${newest_fw}.sha256 ]]; then
    info "the medium already holds ${newest_fw} (firewall)"
  else
    todo_fw="${FW_SRC}/${newest_fw}"; need_bytes=$((need_bytes + $(stat -c %s "${todo_fw}")))
  fi
else
  warn "no firewall export under ${FW_SRC}"
fi

if [[ -z ${todo_vol} && -z ${todo_nas} && -z ${todo_fw} ]]; then
  prune_medium
  green "the medium already holds the newest of each kind, and it verifies — nothing to copy"
  exit 0
fi

# Enough room, before the first byte. Refused rather than filled: a medium
# that fills mid-set leaves a .part and no MANIFEST, which is recoverable, but
# the newest set of one kind is then missing while the alert says proved.
avail="$(df --output=avail -B1 -- "${DEST_ABS}" | tail -1 | tr -d ' ')"
if [[ ${avail} =~ ^[0-9]+$ ]] && ((need_bytes > avail)); then
  die "not enough room on the medium: ${DEST_ABS} has $(human "${avail}") free and the copy needs $(human "${need_bytes}").
Prune it (make backup-offsite DEST=… ARGS=--prune), or bring a larger medium; nothing was written."
fi

failed=0
if [[ -n ${todo_vol} ]]; then mkdir -p -- "${VOL_DST}"; copy_set "${todo_vol}" "${VOL_DST}" || failed=1; fi
if [[ -n ${todo_nas} ]]; then mkdir -p -- "${NAS_DST}"; copy_set "${todo_nas}" "${NAS_DST}" || failed=1; fi
if [[ -n ${todo_fw} ]];  then copy_export "${todo_fw}" || failed=1; fi

if ((failed)); then
  red "the copy of record did not complete — the medium may hold a .part; the next run removes it and copies again"
  exit 1
fi

prune_medium
green "the medium holds the newest of each kind, proved — offsite, not just off-host. Keep it out of the house."
