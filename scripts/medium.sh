# shellcheck shell=bash
#
# What every script that writes to a medium leaving the house shares: the
# refusals that keep the medium from being this host in disguise, and the
# standard set's copy, proof and retention on it.
#
# Two scripts source this, and their media differ. backup-offsite.sh writes the
# estate's sets to the second age recipient's medium (ADR-0048).
# carry-household-copy.sh writes the household's sets to the drive at the
# holder's address (ADR-0073). Everything here is the same for both, so it was
# moved out of backup-offsite.sh rather than copied, with only the names that
# differ between the two passed in as arguments. The offsite
# self-test still asserts every refusal and every proof through the original
# script, and it passed unedited after the move.
#
# Sourced AFTER scripts/backup-volumes.sh, which supplies is_stamp,
# manifest_volumes, manifest_sha and the colours. Defines functions only, and
# does nothing at load.

# ---------------------------------------------------------------------------
# The destination has to be somewhere else
# ---------------------------------------------------------------------------
# medium_refuse <dest_abs> <source_root> <skip> <alert> <runbook> <which medium>
#
#   skip          1 lifts the refusals 2a-2d: the self-tests' setting, never
#                 an operator's. The caller names its own variable for it.
#   alert         the deadline alert a false success would silence
#   runbook       where to read how to mount the medium
#   which medium  completes "Point this at the mounted medium — …"
#
# Each refusal dies with the diagnosis that fits it. The history behind them is
# backup-offsite.sh's, and is kept here with the code it explains.
#
# This shipped with only the device-number check (2c), on the reasoning that
# a medium is never the filesystem the sets live on. That is true, and far
# weaker than it reads: /dev/shm is a different filesystem too, and it is RAM
# on the host being insured. On 2026-09-21, an hour after backup-offsite.sh
# merged, `make backup-offsite DEST=/dev/shm` ran to a green line — 1.7 GB into
# tmpfs on a host with 216 MB free, gone on the next reboot, and a recorded
# success buying ninety days of silence from OffsiteCopyStale for a copy that
# existed nowhere. A backup that cannot survive a power cut is not a backup, so
# these are refusals, not warnings.
medium_refuse() {
  local dest_abs="$1" source_root="$2" skip="$3" alert="$4" runbook="$5" which="$6"

  # 1. Not inside this repository. This tree is published; backups/ is
  #    gitignored by path, which protects nothing under another name.
  if [[ "${dest_abs}" == "${REPO_ROOT}" || "${dest_abs}" == "${REPO_ROOT}/"* ]]; then
    die "the destination is inside this repository:
  ${dest_abs}

This tree is published. A copy of these backups belongs on a medium that
leaves the house, not in a working tree of a public repository."
  fi

  if ((skip)); then
    warn "the medium checks are OFF for this run."
    warn "It will accept RAM, /tmp or this host's own disk as the destination,"
    warn "and record a success for it. That is the self-test's setting, not yours."
  else
    # 2a. Not an in-memory or synthetic filesystem, wherever it is mounted.
    local dest_fstype
    dest_fstype="$(stat -f -c %T "${dest_abs}" 2>/dev/null || true)"
    case "${dest_fstype}" in
      tmpfs | ramfs | devtmpfs | overlay | overlayfs | squashfs | proc | sysfs | devpts | configfs | debugfs | tracefs | cgroup*)
        die "the destination is a ${dest_fstype} filesystem, which is not a medium:
  ${dest_abs}

tmpfs and ramfs live in this host's RAM. A copy there disappears on the next
reboot, and this run would record a success that silences ${alert} for
ninety days on a copy that no longer exists — which is worse than no copy,
because it is read with confidence. Mount the medium and point DEST at it:
${runbook}"
        ;;
    esac

    # 2b. Not one of the trees this host clears or recreates, whatever is
    #     mounted there — a separate /tmp partition passes 2a and 2c both.
    case "${dest_abs}" in
      /dev | /dev/* | /proc | /proc/* | /sys | /sys/* | /run | /run/* | /tmp | /tmp/*)
        die "the destination is under /${dest_abs#/}, which this host clears or recreates:
  ${dest_abs}

Whatever filesystem is mounted there, it is not a medium that leaves the
house. Mount the medium and point DEST at it:
${runbook}"
        ;;
    esac

    # 2c. Not the filesystem the sets already live on. Device number, not path,
    #     so a bind mount or a symlink into the root filesystem is caught too;
    #     compared against both the sets' filesystem and /, since a laptop with
    #     one partition has those be the same and a medium never is.
    local src_probe="${source_root}" dest_fs
    while [[ ! -e ${src_probe} && ${src_probe} != / ]]; do src_probe="$(dirname "${src_probe}")"; done
    dest_fs="$(stat -c %d "${dest_abs}" 2>/dev/null || true)"
    if [[ -n ${dest_fs} ]] && { [[ ${dest_fs} == "$(stat -c %d "${src_probe}" 2>/dev/null)" ]] || [[ ${dest_fs} == "$(stat -c %d / 2>/dev/null)" ]]; }; then
      die "the destination is on the same filesystem as the sets it would copy:
  ${dest_abs}

A copy on this host's own disk is off-host to nowhere. Point this at the
mounted medium — ${which}:
${runbook}"
    fi

    # 2d. Does it look removable? A warning, not a verdict: a second internal
    #     disk and a network mount are both legitimate for someone who has
    #     decided so, and neither reports as removable. What no check here can
    #     establish is the property that matters — that the medium leaves the
    #     house — so this says what it sees and stops.
    if command -v findmnt >/dev/null 2>&1; then
      local dest_src dest_base
      dest_src="$(findmnt -no SOURCE --target "${dest_abs}" 2>/dev/null || true)"
      if [[ ${dest_src} == /dev/* ]]; then
        dest_base="$(basename "${dest_src}")"
        while [[ -n ${dest_base} && ! -e /sys/block/${dest_base} && ${dest_base} =~ [0-9]$ ]]; do
          dest_base="${dest_base%[0-9]}"
        done
        if [[ -r /sys/block/${dest_base}/removable ]] \
           && [[ "$(cat "/sys/block/${dest_base}/removable")" == 0 ]]; then
          warn "${dest_src} does not report as removable media."
          warn "That is fine for a disk you unplug and carry; it is not fine for a second"
          warn "drive that stays in this house. Only you can tell the two apart."
        fi
      fi
    fi
  fi

  # 3. Advice, not a verdict, as verify-key-backup.sh gives it. The script
  #    cannot see whether a working tree has a remote or what a folder syncs to.
  local dest_repo pattern
  if dest_repo="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "${dest_abs}" rev-parse --show-toplevel 2>/dev/null)"; then
    warn "the destination is inside a git working tree:  ${dest_repo}"
    warn "if that repository has a remote, one 'git add .' publishes these backups."
  fi
  for pattern in Dropbox OneDrive 'Google Drive' Nextcloud ownCloud Syncthing iCloud 'Mobile Documents'; do
    shopt -s nocasematch
    if [[ "${dest_abs}" == *"${pattern}"* ]]; then
      warn "the path contains '${pattern}' — if that folder syncs to a third party, the sets are now wherever that service keeps them."
    fi
    shopt -u nocasematch
  done
  return 0
}

# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------
# Complete sets under a directory, newest first — complete_sets() from the
# library reads OUT_DIR, and a medium has one directory per kind. A `.part` is
# not a set even with a MANIFEST in it: copy_set writes the MANIFEST before
# the rename, so a copy that died between the two left exactly that, and
# counting it here made verify_medium refuse its name and wedge every later
# visit until someone deleted it by hand (#613).
sets_in()      { find "$1" -mindepth 2 -maxdepth 2 -name MANIFEST -not -path '*.part/MANIFEST' -printf '%h\n' 2>/dev/null | sort -r; }
all_dirs_in()  { find "$1" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r; }

# The keys in <want> that <have> does not include, one per line. Empty means
# every key that must open the thing can.
cannot_open() {  # <have, newline-separated> <want, newline-separated>
  comm -13 <(grep -v '^$' <<<"$1" | sort -u) <(grep -v '^$' <<<"$2" | sort -u)
}

# ---------------------------------------------------------------------------
# Proof: every archive of a set hashes to its MANIFEST
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

# ---------------------------------------------------------------------------
# Retention on the medium: <keep> per kind, newest never, only names a copy
# writes, strays counted and never touched.
# ---------------------------------------------------------------------------
prune_sets() {  # <kind dir on the medium> <keep>
  local dir="$1" keep_n="$2" n name
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
  if ((${#keep[@]} > keep_n)); then
    for n in "${keep[@]:keep_n}"; do
      if [[ -z ${n} || ${n} != "${dir}/"[0-9]* || ! -f ${n}/MANIFEST ]]; then
        red "refusing to prune ${n}"; continue
      fi
      info "pruning $(basename "${n}") from ${dir}"
      rm -rf -- "${n}"
    done
  fi
}

# Leftovers of set copies that died, of any stamp: <stamp>.part directories,
# and nothing else. copy_set only ever cleared the .part of the stamp it was
# about to write, so one from an older stamp was immortal: prune counted it as
# a stray and left it, and it held up to a set's worth of the medium (#613).
#
# NOT SAFE ALONGSIDE A COPY: a live copy's .part matches too. Callers hold the
# `backups` lock.
sweep_set_parts() {  # <kind dir on the medium>...
  local dir x base
  for dir in "$@"; do
    [[ -d ${dir} ]] || continue
    while read -r x; do
      [[ -n ${x} ]] || continue
      base="${x%.part}"
      is_stamp "${base}" || continue
      info "removing ${x} from ${dir} — a copy that did not finish"
      rm -rf -- "${dir:?}/${x}"
    done < <(find "${dir}" -mindepth 1 -maxdepth 1 -type d -name '*.part' -printf '%f\n' 2>/dev/null)
  done
}
