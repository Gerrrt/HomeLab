#!/usr/bin/env bash
#
# Put a backup set back into the stack's data volumes.
#
# This is the destructive half of scripts/backup-volumes.sh, and it is a
# separate script on purpose: one program that both writes archives and
# overwrites live volumes is one mistyped flag away from an outage, and
# scripts/backup-firewall.sh — the model for both — never writes to the thing
# it backs up and never deletes outside its own retention window (#92).
# The volume inventory is not duplicated either; it comes from
# `backup-volumes.sh --inventory`, the way every SNMP tool reads
# scripts/snmp-targets.sh.
#
# THE ORDER MATTERS MORE THAN ANYTHING ELSE HERE
#
# Every selected archive is decrypted and read end to end BEFORE a single byte
# of live data is removed. A restore that destroys the current volume and then
# discovers the backup will not decrypt has taken a recoverable situation and
# made it final. That is the one property this script exists to guarantee, and
# --dry-run runs exactly that phase and stops.
#
# WHY THERE IS NO DEFAULT SET
#
# --from is mandatory. docs/runbooks/restore-the-firewall.md already states the
# principle: "a config that predates the change you are trying to recover from
# restores you into the problem". Here it inverts — the NEWEST set is the one
# most likely to contain the corruption you are recovering from. A bad Grafana
# upgrade at 22:00 and a backup at 03:00 means the newest grafana.db is the
# broken one. `--from latest` exists, resolves the stamp, prints it and its age,
# and still asks you to confirm against the resolved stamp, so "newest" is
# something you chose rather than something that happened to you.
#
# WHY IT DOES NOT RESTART THE STACK
#
# It stops the stack and leaves it stopped. Bringing it back up is `make up`,
# followed by section 4 of the runbook. A script that restarts the stack itself
# invites reading "it came back up" as "the restore worked", and those are
# different claims — the dashboards, rules and datasources all come from git and
# render perfectly over a volume that never came back.
#
# Usage:
#   scripts/restore-volumes.sh --list
#   scripts/restore-volumes.sh --dry-run --from <STAMP>       verify, touch nothing
#   scripts/restore-volumes.sh --from <STAMP>                 restore the whole set
#   scripts/restore-volumes.sh --from <STAMP> --only grafana-data[,loki-data]
#   scripts/restore-volumes.sh --from latest
#
# Options:
#   --no-safety-net   skip the pre-restore snapshot of the current contents
#
# Environment:
#   STACK              default observability
#   COMPOSE_PROJECT_NAME   overrides the volume prefix, as it does for compose.
#                          This is how a set is rehearsed into a scratch stack
#                          rather than restored over the live one — see the last
#                          section of docs/runbooks/restore-the-stack.md.
#   SOPS_AGE_KEY_FILE  default ~/.config/sops/age/keys.txt
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${STACK:-observability}"
STACK_DIR="${REPO_ROOT}/stacks/${STACK}"
COMPOSE_FILE="${STACK_DIR}/compose.yaml"
COMPOSE=(docker compose -f "${COMPOSE_FILE}")
OUT_DIR="${REPO_ROOT}/backups/volumes"
SOPS_POLICY="${REPO_ROOT}/.sops.yaml"
AGE_IDENTITY="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
BACKUP="${REPO_ROOT}/scripts/backup-volumes.sh"

umask 077

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33mwarning:\033[0m %s\n' "$*" >&2; }
die()   { red "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%sB' "$1"; }

recipient() { grep -oE 'age1[0-9a-z]{50,}' "${SOPS_POLICY}" | head -1; }

manifest_field() {
  awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1/MANIFEST" 2>/dev/null
}

manifest_sha() {
  awk -F'\t' -v v="$2" '$1 == v { print $5; exit }' "$1/MANIFEST" 2>/dev/null
}

manifest_bytes() {
  awk -F'\t' -v v="$2" '$1 == v { print $4; exit }' "$1/MANIFEST" 2>/dev/null
}

# 20260829T062231Z -> "3 day(s) old". Best-effort: a set whose name will not
# parse is still restorable, it just does not get an age printed next to it.
stamp_age() {
  local s="$1" epoch now
  epoch="$(date -u -d "${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}:${s:13:2} UTC" +%s 2>/dev/null)" || return 0
  [[ -n ${epoch} ]] || return 0
  now="$(date +%s)"
  printf '%s day(s) old' "$(( (now - epoch) / 86400 ))"
}

# The uid each service runs as, and therefore the uid its volume's contents must
# come back owned by. A restore that returns every byte and leaves Grafana
# unable to write its own database is a restore that failed.
declare -A EXPECT_UID=(
  [prometheus-data]=65534
  [loki-data]=10001
  [grafana-data]=472
)

FROM=""
ONLY=""
SNAP_DIR=""
DRY=0
SAFETY=1
MODE=restore

while (($#)); do
  case "$1" in
    --from)           FROM="${2:?--from needs a stamp, or 'latest'}"; shift ;;
    --only)           ONLY="${2:?--only needs a comma-separated volume list}"; shift ;;
    --dry-run)        DRY=1 ;;
    --no-safety-net)  SAFETY=0 ;;
    --list)           MODE=list ;;
    -h|--help)        sed -n 's|^# \{0,1\}||; /^Usage:/,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    "")               ;;
    *)                die "unknown argument: $1" ;;
  esac
  shift
done

if [[ ${MODE} == list ]]; then
  exec "${BACKUP}" --list
fi

need docker
need age
need tar
need numfmt
need sha256sum
docker info >/dev/null 2>&1 || die "cannot reach the docker daemon"
[[ -f ${AGE_IDENTITY} ]] || die "no age identity at ${AGE_IDENTITY} — the archives cannot be read without it"

[[ -n ${FROM} ]] || die "--from is required. Run --list to see the sets, and read docs/runbooks/restore-the-stack.md before picking the newest one by reflex."

# ---------------------------------------------------------------------------
# Inventory, from backup-volumes.sh rather than restated here
# ---------------------------------------------------------------------------
VOLUMES=()
declare -A VOL_SERVICE=()
while IFS=$'\t' read -r v s _; do
  [[ -n ${v} ]] || continue
  VOLUMES+=("${v}")
  VOL_SERVICE["${v}"]="${s}"
done < <("${BACKUP}" --inventory)
((${#VOLUMES[@]})) || die "could not read the volume inventory from ${BACKUP}"

PROJECT="$("${BACKUP}" --project)"
[[ -n ${PROJECT} ]] || die "could not read the compose project name"

TARGETS=()
if [[ -n ${ONLY} ]]; then
  IFS=',' read -r -a TARGETS <<<"${ONLY}"
  for v in "${TARGETS[@]}"; do
    [[ -n ${VOL_SERVICE[$v]:-} ]] || die "unknown volume: ${v} (have: ${VOLUMES[*]})"
  done
else
  TARGETS=("${VOLUMES[@]}")
fi

# ---------------------------------------------------------------------------
# Resolve the set
# ---------------------------------------------------------------------------
if [[ ${FROM} == latest ]]; then
  SET_DIR="$(find "${OUT_DIR}" -mindepth 2 -maxdepth 2 -name MANIFEST -printf '%h\n' 2>/dev/null | sort -r | head -1)"
  [[ -n ${SET_DIR} ]] || die "no complete sets in ${OUT_DIR}"
  STAMP="$(basename "${SET_DIR}")"
  info "--from latest resolves to ${STAMP}"
else
  STAMP="${FROM}"
  SET_DIR="${OUT_DIR}/${STAMP}"
fi

[[ -d ${SET_DIR} ]] || die "no such set: ${SET_DIR}"
[[ -f ${SET_DIR}/MANIFEST ]] \
  || die "${STAMP} has no MANIFEST — it is an incomplete set left by a failed backup, and this script will not restore from one"

SET_MODE="$(manifest_field "${SET_DIR}" mode)"
SET_RECIPIENT="$(manifest_field "${SET_DIR}" recipient)"
ARCHIVER="$(manifest_field "${SET_DIR}" archiver)"

if [[ -n ${SET_RECIPIENT} && ${SET_RECIPIENT} != "$(recipient)" ]]; then
  warn "this set was encrypted to ${SET_RECIPIENT}, which is not the recipient currently in .sops.yaml."
  warn "the key has been rotated since. Decryption below will tell you whether the old identity is still on this host."
fi

# The archiver image is what does the extraction. Prefer the one recorded in the
# manifest, so a set is put back by the same tar that took it.
if [[ -z ${ARCHIVER} ]]; then
  ARCHIVER="$("${REPO_ROOT}/scripts/image-for.sh" archiver)"
fi
docker image inspect "${ARCHIVER}" >/dev/null 2>&1 || {
  info "pulling ${ARCHIVER}"
  docker pull -q "${ARCHIVER}" >/dev/null
}

# ---------------------------------------------------------------------------
# Phase 1 — read-only. Nothing below this section touches a live volume.
# ---------------------------------------------------------------------------
info "phase 1: proving every selected archive is readable before anything is destroyed"

failed=0
for v in "${TARGETS[@]}"; do
  f="${SET_DIR}/${v}.tar.gz.age"
  if [[ ! -f ${f} ]]; then
    red "${v}: no archive in ${STAMP}"
    failed=1
    continue
  fi
  want="$(manifest_sha "${SET_DIR}" "${v}")"
  if [[ -n ${want} ]]; then
    got="$(sha256sum "${f}" | awk '{print $1}')"
    if [[ ${got} != "${want}" ]]; then
      red "${v}: sha256 does not match the manifest — the file has changed since it was written"
      red "  manifest: ${want}"
      red "  on disk:  ${got}"
      failed=1
      continue
    fi
  else
    warn "${v}: no sha256 in the manifest to check against"
  fi
done
((failed == 0)) || die "phase 1 failed — nothing was touched"

# The decrypt-and-read pass is backup-volumes.sh's own verify(), not a second
# implementation of it. One sentinel table, one set of assertions, used by the
# script that writes archives and the script that consumes them.
"${BACKUP}" --verify-only --set "${STAMP}" ${ONLY:+--only "${ONLY}"} \
  || die "phase 1 failed — the archives did not verify, and nothing was touched"

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------
printf '\n'
printf 'Restoring set %s — %s, %s\n\n' "${STAMP}" "${SET_MODE:-unknown mode}" "$(stamp_age "${STAMP}")"
printf '  %-32s %14s %14s\n' "volume" "live now" "in the set"
for v in "${TARGETS[@]}"; do
  live="?"
  if docker volume inspect "${PROJECT}_${v}" >/dev/null 2>&1; then
    kb="$(docker run --rm --network none --log-driver none --label homelab.logs=off \
          -v "${PROJECT}_${v}:/data:ro" "${ARCHIVER}" du -sk /data | awk '{print $1}')"
    live="$(human $((kb * 1024)))"
  else
    live="does not exist"
  fi
  printf '  %-32s %14s %14s\n' "${PROJECT}_${v}" "${live}" "$(human "$(manifest_bytes "${SET_DIR}" "${v}")")"
done
printf '\n'

if ((DRY)); then
  green "--dry-run: every selected archive decrypts and reads clean. Nothing was changed."
  printf '\n'
  info "That proves the key works, the ciphertext is intact, each archive unpacks to a"
  info "complete tar, and each holds the volume its name claims. It does NOT prove that"
  info "Prometheus will open the restored TSDB, that Grafana will read the restored"
  info "grafana.db, or that ownership survives the round trip. See"
  info "docs/runbooks/restore-the-stack.md."
  exit 0
fi

# ---------------------------------------------------------------------------
# Confirmation — before the stop, because stopping the stack is itself
# disruptive and must not happen on a set that is about to be rejected.
# ---------------------------------------------------------------------------
[[ -t 0 ]] || die "restore needs a terminal — it will not run unattended, and there is deliberately no --yes"

printf '\033[0;33mThis destroys the current contents of the %s volume(s) above.\033[0m\n' "${#TARGETS[@]}"
((SAFETY)) && printf 'A pre-restore snapshot is written first.\n'
read -r -p "Type '${STAMP}' to continue: " reply
[[ ${reply} == "${STAMP}" ]] || die "not confirmed — nothing was touched"

if [[ ${SET_MODE} == hot ]]; then
  # A hot copy of Prometheus or Loki can hold a torn WAL. Prometheus will either
  # refuse to start or silently drop the head block, and the second is worse.
  printf '\033[0;33m%s was taken with --hot: the services were running, so nothing in it is proven restorable.\033[0m\n' "${STAMP}"
  read -r -p "Type 'unproven' to continue anyway: " reply2
  [[ ${reply2} == unproven ]] || die "not confirmed — nothing was touched"
fi

# ---------------------------------------------------------------------------
# Phase 2 — destructive
# ---------------------------------------------------------------------------
info "stopping the stack"
"${COMPOSE[@]}" stop -t 60

for v in "${TARGETS[@]}"; do
  holders="$(docker ps -q --filter "volume=${PROJECT}_${v}")"
  [[ -z ${holders} ]] \
    || die "a container is still running against ${PROJECT}_${v} — refusing to replace a volume in use"
done

if ((SAFETY)); then
  SNAP_DIR="${OUT_DIR}/.pre-restore-${STAMP}"
  mkdir -p "${SNAP_DIR}"
  AGE_RECIPIENT="$(recipient)"
  [[ -n ${AGE_RECIPIENT} ]] || die "no age recipient in ${SOPS_POLICY} — cannot write the safety snapshot"
  info "snapshotting the current contents to ${SNAP_DIR#"${REPO_ROOT}"/}"
  snapped=()
  for v in "${TARGETS[@]}"; do
    docker volume inspect "${PROJECT}_${v}" >/dev/null 2>&1 || continue
    # --log-driver none for the reason archive_one() in backup-volumes.sh
    # spells out: stdout here is the gzip stream, and without this it is shipped
    # into Loki as log lines (#286).
    docker run --rm --network none --read-only --security-opt no-new-privileges \
        --log-driver none --label homelab.logs=off \
        -v "${PROJECT}_${v}:/data:ro" "${ARCHIVER}" \
        tar --numeric-owner -czf - -C /data . 2>/dev/null \
      | age --recipient "${AGE_RECIPIENT}" --output "${SNAP_DIR}/${v}.tar.gz.age"
    snapped+=("${v}")
  done
  # The snapshot gets a manifest of its own, in the same shape, so rolling back
  # is `--from .pre-restore-<STAMP>` rather than a hand-written docker command
  # typed under pressure. The leading dot keeps it out of backup-volumes.sh's
  # set listing and therefore out of retention: nothing prunes it but you.
  {
    printf '# pre-restore snapshot taken before restoring %s\n' "${STAMP}"
    printf 'stack\t%s\n' "${STACK}"
    printf 'project\t%s\n' "${PROJECT}"
    printf 'mode\tquiesced\n'
    printf 'recipient\t%s\n' "${AGE_RECIPIENT}"
    printf 'archiver\t%s\n' "${ARCHIVER}"
    printf '#volume\tservice\tmount\tbytes\tsha256\n'
    for v in "${snapped[@]}"; do
      printf '%s\t%s\t-\t%s\t%s\n' "${v}" "${VOL_SERVICE[$v]}" \
        "$(stat -c %s "${SNAP_DIR}/${v}.tar.gz.age")" \
        "$(sha256sum "${SNAP_DIR}/${v}.tar.gz.age" | awk '{print $1}')"
    done
  } > "${SNAP_DIR}/MANIFEST"

  # Restoring onto a bare host replaces nothing, so there is nothing to snapshot
  # and an empty directory claiming to hold "the only copy" of what was replaced
  # is worse than no directory at all.
  if ((${#snapped[@]} == 0)); then
    rm -rf -- "${SNAP_DIR}"
    SNAP_DIR=""
    info "no existing volumes to snapshot — nothing is being replaced"
  fi
fi

for v in "${TARGETS[@]}"; do
  info "restoring ${PROJECT}_${v}"
  # Empty and extract in ONE container invocation, so a half-emptied volume
  # needs the container to die between the two. It cannot be made properly
  # transactional — Docker cannot rename a volume, so "extract to a scratch
  # volume and swap" is really "wipe the real one and copy", the same window and
  # twice the disk. The honest answer to an unavoidable window is the snapshot
  # above, not pretending the window is closed.
  #
  # Extracted as root, with --numeric-owner, so tar can put back the uids the
  # services run as (65534, 10001, 472) rather than remapping them.
  age --decrypt -i "${AGE_IDENTITY}" "${SET_DIR}/${v}.tar.gz.age" \
    | docker run --rm -i --network none --log-driver none --label homelab.logs=off \
        -v "${PROJECT}_${v}:/data" "${ARCHIVER}" \
        sh -c 'set -e; cd /data && find . -mindepth 1 -delete && tar --numeric-owner -xzf - -C /data'
done

# ---------------------------------------------------------------------------
# Ownership — reported, never silently corrected
# ---------------------------------------------------------------------------
printf '\n'
for v in "${TARGETS[@]}"; do
  want="${EXPECT_UID[$v]:-}"
  [[ -n ${want} ]] || continue
  got="$(docker run --rm --network none --log-driver none --label homelab.logs=off \
        -v "${PROJECT}_${v}:/data:ro" "${ARCHIVER}" \
        stat -c '%u' /data/. 2>/dev/null || echo '?')"
  if [[ ${got} == "${want}" ]]; then
    green "${v}: owned by uid ${got}, as ${VOL_SERVICE[$v]} expects"
  else
    warn "${v}: owned by uid ${got}, but ${VOL_SERVICE[$v]} runs as ${want}."
    warn "  ${VOL_SERVICE[$v]} will not be able to write to it. To correct, deliberately:"
    warn "  docker run --rm -v ${PROJECT}_${v}:/data ${ARCHIVER} chown -R ${want}:${want} /data"
  fi
done

printf '\n'
green "restored ${#TARGETS[@]} volume(s) from ${STAMP}"
printf '\n'
if ((SAFETY)) && [[ -n ${SNAP_DIR} ]]; then
  info "What you replaced is in ${SNAP_DIR#"${REPO_ROOT}"/} — the only copy. To roll back:"
  info "  make restore ARGS=\"--from .pre-restore-${STAMP}\""
fi
info "The stack is STOPPED. Bring it up and then verify:"
info "  make up"
info "  docs/runbooks/restore-the-stack.md section 4"
printf '\n'
warn "Four things a restore gets right mechanically and wrong operationally:"
warn "  Grafana's admin password now comes from the restored grafana.db, not .env —"
warn "  GF_SECURITY_ADMIN_PASSWORD only applies when the admin user is created."
warn "  Silences live at ${STAMP} are back and are suppressing alerts nobody remembers silencing."
warn "  Prometheus ages restored blocks from their own timestamps, so 30d of retention"
warn "  against a 20-day-old set is 10 days of history, shrinking."
warn "  Alloy's log positions went back to their old offsets — expect either duplicate"
warn "  lines in Loki, or a silent gap where the files have since rotated."
printf '\n'
warn "This put data back. It did not verify the data is correct. Run section 4."
