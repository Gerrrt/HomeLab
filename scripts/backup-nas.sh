#!/usr/bin/env bash
#
# Pull Jellyfin's state off smaug, encrypt it here, and prove the archive is
# readable before calling the run a success.
#
# WHAT THIS PROTECTS, AND WHAT IT DOES NOT
#
# erebor/apps on smaug — Jellyfin's database, users, watch history, resume
# positions and metadata: the half of the media tier ADR-0008 ruled
# irreplaceable, and the one build-the-nas.md §4 declared backed up for a week
# before anything backed it up (#484). It does NOT protect erebor/media, the
# library, which ADR-0008 ruled replaceable and 18 TB of which would not fit
# anywhere in this estate; nor jellyfin-cache, transcode scratch that
# backup-volumes.sh lists as DISPOSABLE by name; nor erebor/ix-apps, Docker's
# images and that cache volume. Those omissions are decisions (ADR-0045), and
# stacks/media/README.md states them where the stack is.
#
# WHY IT PULLS, AND WHY THIS IS NOT backup-volumes.sh
#
# Every other stack backs itself up where it runs: backup-volumes.sh stops the
# containers, tars their volumes through a pinned archiver and encrypts them on
# the same host. smaug cannot run that. It has no age binary, no repository
# checkout and no age identity, and it must not have any of them — CasaBonita
# is terminal-outward (ADR-0016), so a NAS that pushed its own backup upward
# would be the first 40 → 99 path in the estate and would move the igc0.40
# tripwire off zero. So the direction is reversed, as it already is for the
# scrape: this host reaches in over the one rule ADR-0016 wrote for exactly
# this job, `10.0.99.20 → 10.0.40.30:22`, which sat inert from 2026-09-16 until
# build-the-nas.md §6.2 turned the service on.
#
# ADR-0016 also said the archive would be encrypted ON the NAS. It is not, and
# ADR-0045 records why: TrueNAS has an immutable root and no age, and there is
# nothing a key on the NAS would buy — `age -r` needs only the recipients, and
# those are argv on this side. Plaintext exists only inside the ssh session:
# tar's stdout on smaug becomes age's stdin here, and nothing unencrypted
# touches this disk.
#
# WHY IT READS A SNAPSHOT AND NEVER STOPS JELLYFIN
#
# backup-volumes.sh stops the stack because a copy of a live SQLite database
# is a file that looks like a backup. Stopping Jellyfin over ssh would need the
# docker socket on smaug, which is root, for a user whose whole design is that
# it can read one directory and do nothing else. A ZFS snapshot is the quiesce
# instead: TrueNAS takes one of erebor/apps every night (the periodic task
# build-the-nas.md §4 records), and this reads the newest one through
# .zfs/snapshot/. A snapshot is atomic across the dataset, so jellyfin.db, its
# -wal and its -shm are captured at one instant — the crash image SQLite's WAL
# mode is designed to recover from. That is a stronger claim than
# backup-volumes.sh's --hot can make and a weaker one than its quiesce, and the
# manifest says `snapshot` rather than `quiesced` for that reason. Two things
# follow. tar can never report "file changed as we read it" on a snapshot, so
# exit 1 from it is treated as the premise breaking rather than as noise. And a
# snapshot that has stopped being taken is a backup that has silently stopped
# being current, so the newest snapshot's age is checked against
# NAS_SNAPSHOT_MAX_AGE and a stale one fails the run by name.
#
# The age is read from the snapshot's NAME, not from `zfs get creation`: the
# naming schema is fixed in §4 (auto-%Y-%m-%d_%H-%M, in smaug's local time,
# hence NAS_SNAPSHOT_TZ), the name is the one thing the far side can hand over
# without /dev/zfs, and it makes the whole pipeline testable against a
# directory on any ssh host — which is how it was tested before smaug's SSH was
# ever turned on.
#
# WHY IT SOURCES backup-volumes.sh
#
# The sentinel table, verify(), the set helpers and prune() are that script's,
# and restore-volumes.sh already reuses them rather than restating them. This
# script sources the file — it returns before parsing arguments when sourced,
# see its "When sourced" note — and overrides OUT_DIR, KEEP and VOLUMES. One
# table, one set of assertions, for the sets written on this host and the one
# pulled in. The sets are NOT in backups/volumes/: verify_set() there checks a
# set against the current stack's volume list, so a media set in that directory
# would fail the nightly verification of the observability sets, and the two
# retentions would count against one KEEP.
#
# WHAT CROSSES THE WIRE
#
# Four commands, all handed to the far side's login shell, which on TrueNAS is
# zsh with nomatch on — backup-firewall.sh's rules apply verbatim: no glob, no
# bash-only syntax, every path single-quoted and built only from values
# validated below and from a snapshot name that matched SNAPSHOT_RE.
#
#   true                                   the reachability preflight
#   ls -1 '<root>'                         the snapshot names
#   du -sk '<root>/<snapshot>/<subpath>'   sizing, and the read preflight
#   tar --numeric-owner -czf - -C '<root>/<snapshot>/<subpath>' .
#
# Compression runs on smaug, so the wire carries gzip and age runs here.
#
# THE USER ON THE FAR SIDE
#
# `frodo`: one ssh key, no password, no SMB, no sudo, and read access to
# erebor/apps and nothing else — build-the-nas.md §6.2 creates it and proves
# the read with the same tar, to /dev/null. The key is this host's operator
# key, the one that already reaches morpheus and oracle. Known limit, stated
# rather than engineered away: whoever holds that key can read Jellyfin's
# configuration, which includes its users' password hashes; what lands here is
# ciphertext to the same two recipients that can open grafana.db.
#
# WHY NAS_KEEP AND NOT KEEP
#
# Every unit reads /etc/default/homelab-timers and backup-volumes.sh owns KEEP
# there; FW_KEEP is the precedent. A line meant for this weekly set must not
# also reset the retention on the observability sets.
#
# WHERE IT GOES AFTER THIS
#
# To oracle, in the same run, by the same helpers and under the same rules as
# the volume sets: #535 built ADR-0015's copy into backup-volumes.sh — a step
# of the job, after the set is written and verified, failing the run if it
# fails — and everything it needs (read_remote, copy_offhost, the far-side
# verify and prune, take_lock) is above that script's source guard. The far
# side is backups/nas on oracle, beside backups/volumes/<stack>, and it is set
# BEFORE the source line because backup-volumes.sh reads VOL_OFFHOST as it
# loads; the value the volume unit puts in /etc/default/homelab-timers is
# deliberately not inherited, since it names the wrong directory. Same shelf,
# same room, not offsite. A fire takes all three; the copy beyond them is
# scripts/backup-offsite.sh, on the second recipient's medium (ADR-0047).
#
# Usage:
#   scripts/backup-nas.sh                        pull the newest snapshot, encrypt, verify, copy to oracle
#   scripts/backup-nas.sh --local-only           any of the below without the far side
#   scripts/backup-nas.sh --copy-only            copy every set oracle lacks; seeding, catch-up
#   scripts/backup-nas.sh --list                 show the sets that exist, here and there
#   scripts/backup-nas.sh --verify-only          re-verify the newest set, here and there
#   scripts/backup-nas.sh --verify-only --all    re-verify every retained set, here and there
#   scripts/backup-nas.sh --verify-only --set <STAMP>
#   scripts/backup-nas.sh --prune                apply retention only, both sides
#
# Environment:
#   NAS_SSH_TARGET        default frodo@10.0.40.30   the host the state is pulled FROM
#   NAS_OFFHOST           default atropos@10.0.99.30:backups/nas   where the set is copied TO
#   NAS_SNAPSHOT_ROOT     default /mnt/erebor/apps/.zfs/snapshot
#   NAS_SUBPATH           default jellyfin/config      under each snapshot
#   NAS_SNAPSHOT_TZ       default America/Los_Angeles  the zone the names are in
#   NAS_SNAPSHOT_MAX_AGE  default 172800               seconds; older fails the run
#   NAS_KEEP              default 7                    complete sets to retain
#   NAS_RECIPIENT_STACK   default observability        whose secrets file names the recipients
#   SOPS_AGE_KEY_FILE     default ~/.config/sops/age/keys.txt
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Everything shared comes from here: the tables, verify(), the set helpers,
# prune(), the far-side helpers, take_lock(), the colours and die(). It sets
# OUT_DIR, KEEP and VOLUMES for its own stack and returns; the lines after the
# source are the overrides. VOL_OFFHOST is the one value it reads WHILE
# loading — the far-side checks run at the top of the file — so it is set
# here, and set unconditionally: the environment file the timer units share
# carries the volume sets' value, which is the wrong directory for this set.
VOL_OFFHOST="${NAS_OFFHOST:-atropos@10.0.99.30:backups/nas}"
# shellcheck source=scripts/backup-volumes.sh
source "${REPO_ROOT}/scripts/backup-volumes.sh"

OUT_DIR="${REPO_ROOT}/backups/nas"
VOL="jellyfin-config"
VOLUMES=("${VOL}")
# verify_remote_archives honours this when set; one archive per set here, so
# it never is.
ONLY_VOLUMES=()

NAS_SSH_TARGET="${NAS_SSH_TARGET:-frodo@10.0.40.30}"
NAS_SNAPSHOT_ROOT="${NAS_SNAPSHOT_ROOT:-/mnt/erebor/apps/.zfs/snapshot}"
NAS_SUBPATH="${NAS_SUBPATH:-jellyfin/config}"
NAS_SNAPSHOT_TZ="${NAS_SNAPSHOT_TZ:-America/Los_Angeles}"
NAS_SNAPSHOT_MAX_AGE="${NAS_SNAPSHOT_MAX_AGE:-172800}"
NAS_KEEP="${NAS_KEEP:-7}"
NAS_RECIPIENT_STACK="${NAS_RECIPIENT_STACK:-observability}"

# Rejected rather than clamped, as backup-firewall.sh rejects FW_KEEP: a
# mistyped line in an environment file is not a request to delete every set.
if ! [[ ${NAS_KEEP} =~ ^[0-9]+$ ]] || ((NAS_KEEP < 1)); then
  die "NAS_KEEP must be a positive integer, got '${NAS_KEEP}'"
fi
KEEP="${NAS_KEEP}"
if ! [[ ${NAS_SNAPSHOT_MAX_AGE} =~ ^[0-9]+$ ]] || ((NAS_SNAPSHOT_MAX_AGE < 1)); then
  die "NAS_SNAPSHOT_MAX_AGE must be a positive number of seconds, got '${NAS_SNAPSHOT_MAX_AGE}'"
fi

# Every one of these is interpolated into a command the far side's shell
# parses, so the character classes are the control — same rule and same
# classes as backup-firewall.sh's FW_OFFHOST. A stray quote in
# /etc/default/homelab-timers must be refused here, not executed there.
[[ ${NAS_SSH_TARGET} =~ ^[a-z_][a-z0-9_.-]*@[A-Za-z0-9.-]+$ ]] \
  || die "NAS_SSH_TARGET must be user@host, got '${NAS_SSH_TARGET}'"
[[ ${NAS_SNAPSHOT_ROOT} =~ ^/[A-Za-z0-9._/-]+$ && ${NAS_SNAPSHOT_ROOT} != *..* ]] \
  || die "NAS_SNAPSHOT_ROOT must be an absolute path of letters, digits, . _ - and /, got '${NAS_SNAPSHOT_ROOT}'"
NAS_SNAPSHOT_ROOT="${NAS_SNAPSHOT_ROOT%/}"
[[ ${NAS_SUBPATH} =~ ^[A-Za-z0-9._-][A-Za-z0-9._/-]*$ && ${NAS_SUBPATH} != *..* && ${NAS_SUBPATH} != */ ]] \
  || die "NAS_SUBPATH must be a relative path of letters, digits, . _ - and /, got '${NAS_SUBPATH}'"
[[ ${NAS_SNAPSHOT_TZ} =~ ^[A-Za-z0-9/_+-]+$ && -f /usr/share/zoneinfo/${NAS_SNAPSHOT_TZ} ]] \
  || die "NAS_SNAPSHOT_TZ is not a zone this host knows: '${NAS_SNAPSHOT_TZ}'"
NAS_USER="${NAS_SSH_TARGET%@*}"

check_sentinel_table
[[ -n ${SENTINEL[$VOL]:-} ]] \
  || die "no sentinel for ${VOL} in backup-volumes.sh — this script will not write a backup it cannot verify"

# The ssh to smaug. NOT remote(): that name is backup-volumes.sh's and points
# at oracle, and the copy step below relies on it doing so. SSH is that
# script's array too — BatchMode, so a missing key or an unknown host key
# fails loudly instead of hanging a timer on a prompt. stdin closed: nothing
# this script sends needs it, and a remote command that read the caller's
# would eat a pipe.
nas_remote() { "${SSH[@]}" "${NAS_SSH_TARGET}" "$@" </dev/null; }

# ---------------------------------------------------------------------------
# Snapshots
#
# The name IS the schema build-the-nas.md §4 fixes for the periodic task, and
# only a name that matches it is ever interpolated into a remote path. Newest
# first by name: the stamp is a zero-padded calendar, so a reverse name sort
# is a reverse chronological sort — the rule backup-volumes.sh's sets follow.
# ---------------------------------------------------------------------------
SNAPSHOT_RE='^auto-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}$'
SNAPSHOT=""
SNAPSHOT_EPOCH=""

snapshot_epoch() {
  local n="${1#auto-}" d t
  d="${n%_*}"
  t="${n#*_}"
  t="${t/-/:}"
  TZ="${NAS_SNAPSHOT_TZ}" date -d "${d} ${t}" +%s
}

pick_snapshot() {
  local listing now age
  local -a snaps=()
  listing="$(nas_remote "ls -1 '${NAS_SNAPSHOT_ROOT}'")" \
    || die "cannot list ${NAS_SNAPSHOT_ROOT} on ${NAS_SSH_TARGET} — the dataset is not mounted, the path is wrong, or ${NAS_USER} cannot traverse it (build-the-nas.md §6.2)"
  mapfile -t snaps < <(grep -E "${SNAPSHOT_RE}" <<<"${listing}" | sort -r || true)
  ((${#snaps[@]})) \
    || die "no periodic snapshots under ${NAS_SNAPSHOT_ROOT} — the task build-the-nas.md §4 records is not created, or names its snapshots some other way"
  SNAPSHOT="${snaps[0]}"
  SNAPSHOT_EPOCH="$(snapshot_epoch "${SNAPSHOT}")" \
    || die "cannot read a time out of ${SNAPSHOT}"
  now="$(date +%s)"
  age=$((now - SNAPSHOT_EPOCH))
  if ((age < 0)); then
    die "newest snapshot ${SNAPSHOT} is $(( -age / 60 )) minutes in the future — NAS_SNAPSHOT_TZ=${NAS_SNAPSHOT_TZ} is not the zone smaug names its snapshots in"
  fi
  if ((age > NAS_SNAPSHOT_MAX_AGE)); then
    die "newest snapshot ${SNAPSHOT} is $((age / 3600)) hours old, over NAS_SNAPSHOT_MAX_AGE=${NAS_SNAPSHOT_MAX_AGE}s — the periodic task on smaug has stopped, and an archive of it would be a backup that stopped being current without saying so"
  fi
  info "newest snapshot ${SNAPSHOT}, $((age / 3600)) hours old (${#snaps[@]} on the far side)"
}

# ---------------------------------------------------------------------------
# Arguments — the shape backup-volumes.sh uses, minus the modes that only make
# sense with a compose file: no --hot (a snapshot is the whole point), no
# --inventory, no --project, no --only (one archive per set).
# ---------------------------------------------------------------------------
usage() { sed -n 's|^# \{0,1\}||; /^Usage:/,/^$/p' "$0" | head -24; }

MODE=backup
MODE_SET=""
LOCAL_ONLY=0
ALL=0
SET_ARG=""

set_mode() {
  [[ -z ${MODE_SET} ]] || die "conflicting modes: --${MODE_SET} and --$1"
  MODE="$1"; MODE_SET="$1"
}

while (($#)); do
  case "$1" in
    --list)        set_mode list ;;
    --verify-only) set_mode verify ;;
    --prune)       set_mode prune ;;
    --copy-only)   set_mode copy ;;
    --local-only)  LOCAL_ONLY=1 ;;
    --all)         ALL=1 ;;
    --set)
      SET_ARG="${2:-}"
      [[ ${SET_ARG} =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "--set wants a stamp like 20260919T033000Z, got '${SET_ARG}'"
      shift
      ;;
    -h|--help)     usage; exit 0 ;;
    "")            ;;
    *)             usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done
[[ ${MODE} == verify || ( ${ALL} == 0 && -z ${SET_ARG} ) ]] \
  || die "--all and --set belong to --verify-only"
if [[ ${MODE} == copy ]] && ((LOCAL_ONLY)); then
  die "--copy-only --local-only would do nothing"
fi

case "${MODE}" in
  list)
    list_sets
    ((LOCAL_ONLY)) || list_remote_sets
    exit 0
    ;;
  # Ciphertext that has already been proven, moved without touching smaug:
  # how the far side is seeded and how a stretch with oracle off is caught up.
  copy)
    need ssh
    need cmp
    take_lock wait
    if ! copy_offhost; then
      red "the off-host copy FAILED — check: ${OFFHOST_TARGET} reachable, its host key in ~/.ssh/known_hosts,"
      red "and this host's key authorised there — docs/runbooks/restore-the-stack.md §0"
      exit 1
    fi
    prune_offhost || exit 1
    exit 0
    ;;
esac

need age
[[ -f ${AGE_IDENTITY} ]] \
  || die "no age identity at ${AGE_IDENTITY} — verification decrypts what it just wrote, and an unverified backup is not a backup"

case "${MODE}" in
  verify)
    take_lock wait
    failed=0
    if ((ALL)); then
      mapfile -t targets < <(complete_sets)
    elif [[ -n ${SET_ARG} ]]; then
      targets=("${OUT_DIR}/${SET_ARG}")
    else
      mapfile -t targets < <(newest_complete)
    fi
    if ((${#targets[@]} == 0)) || [[ -z ${targets[0]} ]]; then
      die "no complete sets in ${OUT_DIR}"
    fi
    for t in "${targets[@]}"; do
      verify_set "${t}" || failed=1
    done
    # The far side is checked even when a local set failed — different
    # findings, different repairs — unless --local-only says oracle may be
    # one of the things that is broken today.
    if ((LOCAL_ONLY)); then
      info "--local-only: the copy on ${OFFHOST_TARGET} was not checked"
    else
      need ssh
      need cmp
      verify_remote_sets "${targets[@]}" || failed=1
    fi
    ((failed == 0)) || die "verification FAILED"
    exit 0
    ;;
  prune)
    take_lock wait
    prune
    if ((LOCAL_ONLY)); then
      info "--local-only: retention was applied here; ${OFFHOST_TARGET} was not touched"
    else
      need ssh
      printf '\n'
      prune_offhost || exit 1
    fi
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Main path
#
# Everything that can fail is made to fail BEFORE anything is written — and
# there is nothing to restart afterwards, because nothing was stopped.
# ---------------------------------------------------------------------------
need ssh
need tar
need gzip
need awk
need flock
need numfmt
need sha256sum
((LOCAL_ONLY)) || need cmp

take_lock

# A warning and not a refusal, as in backup-volumes.sh: the local set is
# worth taking, and the copy step will fail on its own account. This says so
# before the pull rather than after.
if ((LOCAL_ONLY == 0)) && ! remote true >/dev/null 2>&1; then
  warn "cannot reach ${OFFHOST_TARGET} now — the set will be written here and the copy step will fail"
fi

# The recipients are read from a secrets file's `sops:` metadata by
# key-recipients.sh, the way backup-volumes.sh reads its stack's. This stack
# has no secrets file — it needs no secrets, and #528 owns whether it ever
# gets one — so the file is the observability stack's, whose recipients are
# the estate's two keys (ADR-0024). Whoever can open grafana.db is exactly who
# should be able to open Jellyfin's users table, and both are the same class
# of thing. When #528 lands a media file under the same catch-all rule it
# carries the same two keys, and NAS_RECIPIENT_STACK=media says so.
mapfile -t AGE_RECIPIENTS < <("${REPO_ROOT}/scripts/key-recipients.sh" --list --stack "${NAS_RECIPIENT_STACK}")
((${#AGE_RECIPIENTS[@]})) || die "no age recipients from secrets/${NAS_RECIPIENT_STACK}.sops.yaml — nothing to encrypt to"
AGE_ARGS=()
for r in "${AGE_RECIPIENTS[@]}"; do AGE_ARGS+=(--recipient "${r}"); done
AGE_RECIPIENT="$(IFS=,; printf '%s' "${AGE_RECIPIENTS[*]}")"
unset r

nas_remote true \
  || die "cannot reach ${NAS_SSH_TARGET} non-interactively — SSH is off on smaug (build-the-nas.md §6.2 turns it on), the 99 → 40:22 pass is not in position, this host's key is not in ${NAS_USER}'s authorized keys, or smaug's host key is not in ~/.ssh/known_hosts"

pick_snapshot
SRC="${NAS_SNAPSHOT_ROOT}/${SNAPSHOT}/${NAS_SUBPATH}"

# du is the sizing pass and the read preflight in one: it exits non-zero on
# any directory it cannot enter, which is the permission fault §6.2 exists to
# prevent, found before a set directory exists rather than after.
kb="$(nas_remote "du -sk '${SRC}'" | awk '{print $1}')" \
  || die "cannot read ${SRC} as ${NAS_USER} — the subpath is wrong, or ${NAS_USER} lacks read on something under it (build-the-nas.md §6.2)"
[[ ${kb} =~ ^[0-9]+$ ]] || die "du on ${SRC} returned '${kb}', not a size"
avail_kb="$(df --output=avail -k "${OUT_DIR}" | tail -1 | tr -d ' ')"
if ((avail_kb < kb * 11 / 10)); then
  die "only $(human $((avail_kb * 1024))) free at ${OUT_DIR}, and ${SRC} holds $(human $((kb * 1024))) uncompressed — refusing to start"
fi
info "${SRC} is $(human $((kb * 1024))) uncompressed"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SET_DIR="${OUT_DIR}/${STAMP}"
# No -p: a duplicate stamp is a named error, not a merge.
mkdir "${SET_DIR}" || die "set ${STAMP} already exists"

started=${SECONDS}
part="${SET_DIR}/${VOL}.tar.gz.age.part"
info "archiving ${VOL} from ${NAS_SSH_TARGET}:${SRC}"

# tar's stdout on smaug is age's stdin here; nothing plaintext touches this
# disk. The pipeline's statuses are read one at a time because they mean
# different things: 255 is ssh itself, and tar's 1 and 2 are the two faults
# the header argues about.
set +e
nas_remote "tar --numeric-owner -czf - -C '${SRC}' ." | age "${AGE_ARGS[@]}" --output "${part}"
rcs=("${PIPESTATUS[@]}")
set -e

fail_archive() {
  red "$*"
  rm -f "${part}"
  red "the incomplete set is at ${SET_DIR} — no manifest written, nothing pruned"
  exit 1
}
case "${rcs[0]}" in
  0)   ;;
  255) fail_archive "ssh to ${NAS_SSH_TARGET} failed mid-transfer" ;;
  1)   fail_archive "tar reported a file changing while it read ${SRC} — that cannot happen on a snapshot, so this is not one: ${NAS_SNAPSHOT_ROOT} is not a .zfs/snapshot directory, or ${NAS_SUBPATH} is a live path" ;;
  2)   fail_archive "tar could not read something under ${SRC} as ${NAS_USER} — a file Jellyfin wrote without world read; build-the-nas.md §6.2 names the fallback" ;;
  *)   fail_archive "tar on ${NAS_SSH_TARGET} exited ${rcs[0]}" ;;
esac
((rcs[1] == 0)) || fail_archive "age failed to write ${part}"

# Strict, never lenient: --hot's carve-out is for a copy of a live volume, and
# this read a snapshot. A missing sentinel here means the archive is not of
# Jellyfin's config directory, whatever the path was called.
if ! verify "${part}" "${VOL}" 0; then
  red "the archive did not verify — the incomplete set is at ${SET_DIR}, no manifest written, nothing pruned"
  exit 1
fi
ARCHIVE_BYTES="$(stat -c %s "${part}")"
ARCHIVE_SHA="$(sha256sum "${part}" | awk '{print $1}')"
mv "${part}" "${SET_DIR}/${VOL}.tar.gz.age"

# Written last: its presence is what marks the set complete. The same
# tab-separated shape backup-volumes.sh writes, so list_sets, prune and a
# reader who knows one knows the other; the three extra keys say what was
# read and when the far side froze it.
{
  printf '# %s set %s\n' "$(basename "$0")" "${STAMP}"
  printf 'stack\t%s\n' media
  printf 'project\t%s\n' media
  printf 'mode\t%s\n' snapshot
  printf 'source\t%s:%s\n' "${NAS_SSH_TARGET}" "${SRC}"
  printf 'snapshot\t%s\n' "${SNAPSHOT}"
  printf 'snapshot_epoch\t%s\n' "${SNAPSHOT_EPOCH}"
  printf 'recipient\t%s\n' "${AGE_RECIPIENT}"
  printf 'archiver\t%s\n' "ssh-tar"
  printf 'downtime\t0\n'
  printf '#volume\tservice\tmount\tbytes\tsha256\n'
  printf '%s\t%s\t%s\t%s\t%s\n' "${VOL}" jellyfin /config "${ARCHIVE_BYTES}" "${ARCHIVE_SHA}"
} > "${SET_DIR}/MANIFEST"

# Local retention before the copy, for backup-volumes.sh's reason: a set past
# KEEP here is past it there, and copying it first moves what prune_offhost
# then removes.
prune

printf '\n'
green "wrote ${SET_DIR#"${REPO_ROOT}"/} — ${VOL} from ${SNAPSHOT}, $(human "${ARCHIVE_BYTES}"), Jellyfin never stopped, $((SECONDS - started))s total"
printf '\n'

if ((LOCAL_ONLY)); then
  info "--local-only: this is off smaug and on the same shelf as the volume sets."
  info "Retention was applied here; ${OFFHOST_TARGET} was not touched. Copy it: make backup-nas ARGS=--copy-only"
else
  # The set is written and proven. From here a failure is still a failure of
  # the JOB, and the message says which half.
  if ! copy_offhost; then
    printf '\n'
    red "wrote ${STAMP} but the off-host copy FAILED — this set is off smaug and on the monitoring host only"
    red "the local set is complete and verified"
    red "check: ${OFFHOST_TARGET} reachable, its host key in ~/.ssh/known_hosts, and this"
    red "host's key authorised there — docs/runbooks/restore-the-stack.md §0"
    exit 1
  fi
  if ! prune_offhost; then
    printf '\n'
    red "wrote and copied ${STAMP} but retention on ${OFFHOST_TARGET} FAILED"
    red "the backup is safe; the far side is growing unbounded"
    exit 1
  fi
  printf '\n'
  info "Copied to ${OFFHOST_TARGET}:${OFFHOST_DIR} — off-host, not offsite; a fire takes all three. Offsite is make backup-offsite, on the medium's visit (ADR-0047)."
fi
info "Restoring it: docs/runbooks/build-the-nas.md §6.3."
info "On a timer: systemctl list-timers 'homelab-*' — docs/runbooks/schedule-maintenance.md."
