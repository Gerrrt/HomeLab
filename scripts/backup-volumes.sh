#!/usr/bin/env bash
#
# Quiesce the observability stack, archive its data volumes, encrypt them, and
# prove every archive is readable before calling the run a success.
#
# WHAT THIS REPLACES
#
# `make backup` used to be seven lines inline in the Makefile, and every defect
# in #64 followed from that. It wrote backups/<volume>.tar.gz — one fixed name,
# no timestamp, no rotation — and tar truncates at open(2), so a run that failed
# had already destroyed the last good backup: the only way to lose a backup was
# to take one. It hardcoded four volume names and had silently skipped
# alloy-data since Alloy was added. It ran an unpinned `alpine`. It tarred
# /prometheus while Prometheus was writing to it. It verified nothing — tar's
# exit status was the whole of the quality control. And it bind-mounted
# backups/ into a container running as root, so every archive came out
# root-owned and could not be rotated without sudo.
#
# WHY IT STOPS THE STACK
#
# The default is to `docker compose stop` the services that own the volumes,
# archive, then start them again. A copy of a live store is not a backup, it is
# a file that looks like one:
#
#   prometheus-data    the head block is mmap'd and the WAL is append-only
#                      mid-record. Prometheus replays and discards a torn tail,
#                      so this usually survives — but "usually" is not a restore
#                      procedure.
#   grafana-data       grafana.db is SQLite. A copy taken mid-transaction, with
#                      no journal to go with it, is the classic corruption case:
#                      the file opens, and is quietly missing writes. This is
#                      the volume a hot copy is most likely to ruin.
#   alertmanager-data  nflog and silences are snapshots written on the
#                      maintenance tick or at shutdown. SIGTERM is what makes
#                      them exist and be current.
#
# A trap restarts whatever was stopped on every exit path, including Ctrl-C and
# an error mid-archive. A backup script must never leave the monitoring stack
# down; that turns a routine job into an outage with nothing left watching.
#
# WHY age AND NOT sops
#
# Every other artefact here is encrypted with sops, and backup-firewall.sh pipes
# straight into it. sops holds the whole document in memory and stores it
# base64-encoded inside YAML: free for a 6 KB config.xml, a gigabyte of RSS and
# a 1.4 GB output file for a 1 GB TSDB. `age -r` streams. The recipient is still
# read from .sops.yaml, so there is still exactly one key — rotating it there
# rotates it here.
#
# The recipient is passed in argv and is therefore visible in `ps`. It is a
# public key; it can only encrypt. Do not "fix" this.
#
# Verification decrypts, so the private key must be on this host. That is no new
# exposure — render-config.sh already needs it — but it is a choice, and it
# forecloses a write-only design where the host can produce backups it cannot
# read. Recorded here so a future reader knows it was decided rather than
# overlooked.
#
# WHY THE OUTPUT IS NOT COMMITTED
#
# backups/ is gitignored, `make validate` asserts nothing under it is tracked
# and CI asserts the same — see the header of scripts/backup-firewall.sh for the
# argument. It applies here with more force: grafana.db carries the admin
# password hash, every API token and every datasource credential.
#
# Usage:
#   scripts/backup-volumes.sh                       quiesce, archive, verify
#   scripts/backup-volumes.sh --hot                 skip the stop; UNPROVEN
#   scripts/backup-volumes.sh --list                show the sets that exist
#   scripts/backup-volumes.sh --inventory           print the derived volume table
#   scripts/backup-volumes.sh --project             print the compose project name
#   scripts/backup-volumes.sh --verify-only         re-verify the newest set
#   scripts/backup-volumes.sh --verify-only --all   re-verify every retained set
#   scripts/backup-volumes.sh --verify-only --set <STAMP> [--only vol,vol]
#   scripts/backup-volumes.sh --prune               apply retention only
#
# Environment:
#   STACK              default observability   selects stacks/<STACK>/compose.yaml
#   COMPOSE_PROJECT_NAME   overrides the volume prefix, as it does for compose
#   KEEP               default 7               complete sets to retain
#   STOP_TIMEOUT       default 60              seconds before SIGKILL on stop
#   SOPS_AGE_KEY_FILE  default ~/.config/sops/age/keys.txt
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${STACK:-observability}"
STACK_DIR="${REPO_ROOT}/stacks/${STACK}"
COMPOSE_FILE="${STACK_DIR}/compose.yaml"
OUT_DIR="${REPO_ROOT}/backups/volumes"
SOPS_POLICY="${REPO_ROOT}/.sops.yaml"
AGE_IDENTITY="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
KEEP="${KEEP:-7}"
STOP_TIMEOUT="${STOP_TIMEOUT:-60}"

# An archive smaller than this is not a backup. Measured on this host: an empty
# volume encrypts to 306 bytes, and the smallest real one (alertmanager-data,
# 12 KB of mostly-sparse nflog and silences) to 872. 512 sits between them, and
# is the same floor backup-firewall.sh:116 uses on a smaller artefact. The
# structural guard is the entry count in verify(); this is belt and braces.
MIN_BYTES=512

# The archives are age-encrypted, so this is defence in depth rather than the
# control. grafana-data is in here; it is cheap.
umask 077

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33mwarning:\033[0m %s\n' "$*" >&2; }
die()   { red "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# The age recipient is read from .sops.yaml rather than duplicated here. One
# source of truth for the key; rotating it in .sops.yaml rotates it here too.
recipient() {
  grep -oE 'age1[0-9a-z]{50,}' "${SOPS_POLICY}" | head -1
}

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%sB' "$1"; }

# ---------------------------------------------------------------------------
# Inventory
#
# The volume list is DERIVED, not written down. alloy-data was missing from the
# old recipe precisely because the list was hardcoded; adding a fifth entry
# would have fixed today's symptom and left the mechanism in place. Text
# parsing rather than PyYAML or `docker compose config`, for the reasons in the
# header of scripts/image-for.sh: this must work before either is guaranteed
# present, and needs no .env for the ${VAR:?} guards.
#
# A named volume is discriminated from a bind mount by its source not starting
# with . or / — which is what compose itself uses.
# ---------------------------------------------------------------------------

# Volume -> the one entry that proves an archive holds THAT volume.
#
# This is the analogue of backup-firewall.sh's `<pfsense>` grep, and it carries
# more weight than it looks: `age -r` has no associated data, so
# loki-data.tar.gz.age and prometheus-data.tar.gz.age are interchangeable as far
# as age is concerned. The sentinel is the only thing binding a filename to its
# content, so it has to discriminate rather than merely be present.
#
# ./wal is deliberately NOT the sentinel for Prometheus or Loki even though it
# is the most reliably present entry in both — both have it, so a crossed
# mapping, the exact failure this exists to catch, would sail through.
declare -A SENTINEL=(
  [prometheus-data]="./chunks_head"
  [loki-data]="./chunks"
  [grafana-data]="./grafana.db"
  [alertmanager-data]="./nflog"
  [alloy-data]="./alloy_seed.json"
)

# Reported when absent, never fatal. These cover the fresh-volume case, where
# the discriminating entry above may not exist yet.
declare -A COMPANIONS=(
  [prometheus-data]="./wal ./lock ./queries.active"
  [loki-data]="./wal ./index ./compactor"
  [grafana-data]="./plugins ./dashboards ./png"
  [alertmanager-data]="./silences"
  [alloy-data]="./remotecfg"
)

VOLUMES=()
SERVICES=()
declare -A VOL_SERVICE=()
declare -A VOL_MOUNT=()
PROJECT=""

parse_compose() {
  awk '
    /^services:/     { in_services = 1; in_volumes = 0; next }
    /^volumes:/      { in_services = 0; in_volumes = 1; next }
    /^[^[:space:]#]/ { in_services = 0; in_volumes = 0 }

    /^name:/ && !printed_name { printf "project\t%s\n", $2; printed_name = 1 }

    in_volumes && /^  [A-Za-z0-9_.-]+:/ {
      n = $0; sub(/^  /, "", n); sub(/:.*/, "", n)
      printf "declared\t%s\n", n
      next
    }

    in_services && /^  [A-Za-z0-9_.-]+:/ {
      s = $0; sub(/^  /, "", s); sub(/:.*/, "", s)
      svc = s; inlist = 0
      next
    }
    in_services && /^    volumes:[[:space:]]*$/ { inlist = 1; next }
    in_services && /^    [A-Za-z_<]/           { inlist = 0 }
    in_services && inlist && /^      - / {
      if ($2 ~ /^[.\/]/) next
      split($2, p, ":")
      if (p[1] == "" || p[2] == "") next
      printf "mount\t%s\t%s\t%s\n", p[1], svc, p[2]
    }
  ' "${COMPOSE_FILE}"
}

load_inventory() {
  [[ -f ${COMPOSE_FILE} ]] || die "no compose file at ${COMPOSE_FILE}"

  local -a declared=()
  local kind a b c
  while IFS=$'\t' read -r kind a b c; do
    case "${kind}" in
      project)  PROJECT="${a}" ;;
      declared) declared+=("${a}") ;;
      mount)
        [[ -z ${VOL_SERVICE[$a]:-} ]] \
          || die "volume ${a} is mounted by both ${VOL_SERVICE[$a]} and ${b} — this script cannot say which service to stop"
        VOL_SERVICE["${a}"]="${b}"
        VOL_MOUNT["${a}"]="${c}"
        ;;
    esac
  done < <(parse_compose)

  # The project name is what prefixes the volumes, and it is NOT $STACK. STACK
  # is a directory name; this host still carries orphan prometheus_grafana-data
  # and prometheus_loki-data volumes from when the two diverged.
  #
  # COMPOSE_PROJECT_NAME wins over the file's name: key, because that is the
  # order docker compose itself resolves them in. Getting this backwards would
  # archive one project's volumes while compose ran another's — and the restore
  # would then overwrite the wrong ones. It is also what makes a rehearsal
  # possible: COMPOSE_PROJECT_NAME=restoretest restores a set into a scratch
  # stack instead of over the live one. See docs/runbooks/restore-the-stack.md.
  PROJECT="${COMPOSE_PROJECT_NAME:-${PROJECT}}"
  [[ -n ${PROJECT} ]] || die "no top-level name: in ${COMPOSE_FILE} — cannot derive the volume prefix"
  ((${#declared[@]} > 0)) || die "no named volumes declared in ${COMPOSE_FILE}"

  local v
  for v in "${declared[@]}"; do
    # A volume nothing mounts is a volume this script cannot attribute, and a
    # volume it cannot attribute is one it would silently skip. That is exactly
    # how alloy-data went missing.
    [[ -n ${VOL_SERVICE[$v]:-} ]] \
      || die "volume ${v} is declared in ${COMPOSE_FILE} but no service mounts it — refusing to run"
    # Derivation solves one inventory; the sentinel table is a second one.
    # Making its absence fatal means adding a sixth volume produces a named
    # error rather than an archive nothing can verify.
    [[ -n ${SENTINEL[$v]:-} ]] \
      || die "no sentinel defined for ${v} in $(basename "$0") — add one; this script will not write a backup it cannot verify"
    VOLUMES+=("${v}")
  done

  mapfile -t SERVICES < <(printf '%s\n' "${VOL_SERVICE[@]}" | sort -u)
}

print_inventory() {
  local v
  for v in "${VOLUMES[@]}"; do
    printf '%s\t%s\t%s\n' "${v}" "${VOL_SERVICE[$v]}" "${VOL_MOUNT[$v]}"
  done
}

# ---------------------------------------------------------------------------
# Sets
# ---------------------------------------------------------------------------

# A set is complete when its MANIFEST exists; the manifest is written last.
# Sorted by name, not mtime — mtime can be touched, and the stamp is UTC
# ISO-8601 basic form, so a name sort IS a chronological sort.
complete_sets() {
  find "${OUT_DIR}" -mindepth 2 -maxdepth 2 -name MANIFEST -printf '%h\n' 2>/dev/null | sort -r
}

all_sets() {
  find "${OUT_DIR}" -mindepth 1 -maxdepth 1 -type d -name '2*' -printf '%p\n' 2>/dev/null | sort -r
}

newest_complete() { complete_sets | head -1; }

manifest_field() {
  awk -F'\t' -v k="$2" '$1 == k { print $2; exit }' "$1/MANIFEST" 2>/dev/null
}

newest_quiesced() {
  local d
  while read -r d; do
    [[ -n ${d} ]] || continue
    [[ "$(manifest_field "${d}" mode)" == quiesced ]] && { printf '%s\n' "${d}"; return 0; }
  done < <(complete_sets)
  return 0
}

list_sets() {
  local d state mode count n=0
  if [[ ! -d ${OUT_DIR} ]] || [[ -z "$(all_sets)" ]]; then
    info "no sets in ${OUT_DIR}"
    return 0
  fi
  while read -r d; do
    [[ -n ${d} ]] || continue
    if [[ -f ${d}/MANIFEST ]]; then
      state=complete
      mode="$(manifest_field "${d}" mode)"
      # A complete set whose manifest will not parse is not a proven-quiesced
      # set. Say so rather than printing a blank column.
      [[ -n ${mode} ]] || mode=unreadable
    else
      state=INCOMPLETE
      mode=unknown
    fi
    count=$(find "${d}" -maxdepth 1 -name '*.tar.gz.age' | wc -l)
    printf '%s\t%s\t%s\t%s archive(s)\n' "$(basename "${d}")" "${state}" "${mode}" "${count}"
    n=$((n + 1))
  done < <(all_sets)
  info "${n} set(s), keeping ${KEEP}"
}

# ---------------------------------------------------------------------------
# Verification — the tarball analogue of backup-firewall.sh:62-76
#
# Three escalating assertions, one streaming pass, nothing extracted:
#   (a) it decrypts at all. age's STREAM construction is AEAD per chunk with a
#       final-chunk flag, so this also rejects a truncated, bit-flipped or
#       tampered file — strictly stronger than the sops case.
#   (b) it is the right KIND of thing: the whole gzip stream parses as a tar
#       (CRC32 and ISIZE are checked at end of stream) and the volume's own
#       sentinel is present.
#   (c) report semantic content back to the operator — the analogue of
#       backup-firewall.sh printing the config version and rule count.
# ---------------------------------------------------------------------------
verify() {
  local f="$1" vol="$2" lenient="${3:-0}"
  local bytes out entries found foreign missing must companions all v

  [[ -f ${f} ]] || { red "no such archive: ${f}"; return 1; }

  bytes=$(stat -c %s "${f}")
  if ((bytes < MIN_BYTES)); then
    red "$(basename "${f}") is ${bytes} bytes — implausibly small; that is not a backup"
    return 1
  fi

  must="${SENTINEL[$vol]:-}"
  companions="${COMPANIONS[$vol]:-}"
  [[ -n ${must} ]] || { red "no sentinel for ${vol}"; return 1; }

  # Every volume's sentinel is handed to awk, not just this one's. Finding
  # somebody else's is how a crossed mapping is caught, and that has to be fatal
  # in both modes — see below.
  all=""
  for v in "${!SENTINEL[@]}"; do all+=" ${v}|${SENTINEL[$v]}"; done

  # The listing is NOT piped through head, grep -q or grep -m1. Any reader that
  # exits early SIGPIPEs tar, tar dies on signal 13, the shell reports 141, and
  # `set -o pipefail` turns a perfectly good archive into a failed verification
  # — a backup script reporting corruption it invented. awk consumes every line
  # to EOF and does the matching itself.
  #
  # Whole-line comparison rather than $NF, and -tzf rather than -tzvf, because
  # Grafana's plugin and dashboard trees contain filenames with spaces. Matching
  # whole lines also means only top-level entries can satisfy a sentinel.
  if ! out="$(age --decrypt -i "${AGE_IDENTITY}" "${f}" \
                | tar -tzf - \
                | awk -v vol="${vol}" -v all="${all# }" -v companions="${companions}" '
                    BEGIN {
                      n = split(all, pairs, " ")
                      for (i = 1; i <= n; i++) {
                        split(pairs[i], kv, "|")
                        owner[kv[2]] = kv[1]
                      }
                      m = split(companions, c, " ")
                      for (i = 1; i <= m; i++) want[c[i]] = 1
                    }
                    {
                      entries++
                      line = $0
                      sub(/\/$/, "", line)         # tar suffixes directories
                      if (line in owner) hit[owner[line]] = 1
                      if (line in want)  seen[line] = 1
                    }
                    END {
                      foreign = ""
                      for (v in hit) if (v != vol) foreign = foreign " " v
                      missing = ""
                      for (k in want) if (!(k in seen)) missing = missing " " k
                      # "-" rather than "" for an empty list. Tab is an IFS
                      # WHITESPACE character, so bash collapses a run of them
                      # into one delimiter — an empty field here silently
                      # shifts every later field left, and `missing` arrives in
                      # `foreign` as a phantom crossed-mapping report.
                      if (foreign == "") foreign = "-"
                      if (missing == "") missing = "-"
                      printf "%d\t%d\t%s\t%s\n", entries, (vol in hit), foreign, missing
                    }')"; then
    red "FAILED to decrypt or read $(basename "${f}")"
    return 1
  fi

  IFS=$'\t' read -r entries found foreign missing <<<"${out}"

  if ((entries <= 1)); then
    red "$(basename "${f}") unpacks to ${entries} entries — that is an empty archive, not a backup"
    return 1
  fi

  # Fatal in BOTH modes. --hot forgives a sentinel that is merely absent, but an
  # archive carrying another volume's sentinel is not a fresh volume — it is the
  # wrong file under this name. age -r has no associated data, so nothing but
  # this check binds a filename to its content.
  if [[ ${foreign} != "-" ]]; then
    red "${vol}: this archive carries the sentinel of${foreign} — it is not a ${vol} backup"
    return 1
  fi

  if ((found == 0)); then
    if ((lenient)); then
      # --hot only. alertmanager-data has no entry that survives a fresh,
      # never-cleanly-stopped Alertmanager: nflog and silences are snapshots
      # written on the maintenance tick or at SIGTERM — and SIGTERM is exactly
      # what quiescing sends. So this falls out of the mode rather than needing
      # a per-volume exception.
      warn "${vol}: ${must} is not in the archive. A hot copy of a service that has never shut down cleanly may legitimately lack it, but nothing here proves this archive is ${vol}."
      warn "checked $(basename "${f}") — ${entries} entries, $(human "${bytes}"), ${must} MISSING"
    else
      red "${vol}: ${must} is not in the archive — this does not look like a ${vol} backup"
      return 1
    fi
  else
    green "verified $(basename "${f}") — ${entries} entries, $(human "${bytes}"), ${must} present"
  fi

  [[ ${missing} != "-" ]] && info "  not present: ${missing# }"
  return 0
}

verify_set() {
  local d="$1"; shift
  local lenient=0 vol failed=0
  local -a want=("$@")
  ((${#want[@]})) || want=("${VOLUMES[@]}")
  [[ -d ${d} ]] || die "no such set: ${d}"
  [[ "$(manifest_field "${d}" mode)" == hot ]] && lenient=1
  info "verifying $(basename "${d}")"
  for vol in "${want[@]}"; do
    if [[ ! -f ${d}/${vol}.tar.gz.age ]]; then
      red "${vol}: no archive in $(basename "${d}")"
      failed=1
      continue
    fi
    verify "${d}/${vol}.tar.gz.age" "${vol}" "${lenient}" || failed=1
  done
  return "${failed}"
}

# ---------------------------------------------------------------------------
# Quiesce
# ---------------------------------------------------------------------------
STOPPED=()

quiesce() {
  # Only the services that are actually running. If prometheus is deliberately
  # down for maintenance, this must not quietly bring it back up.
  mapfile -t STOPPED < <(
    "${COMPOSE[@]}" ps --status running --services 2>/dev/null \
      | grep -Fx -f <(printf '%s\n' "${SERVICES[@]}") || true
  )
  if ((${#STOPPED[@]} == 0)); then
    info "nothing to stop — the stack is already down"
    return 0
  fi

  # -t 60, not the 10s default. Prometheus flushing its head block and
  # Alertmanager writing its nflog and silences snapshots are exactly what
  # quiescing is for; a SIGKILL at ten seconds skips both and leaves the WAL to
  # carry state the archive was meant to capture cleanly.
  info "stopping ${STOPPED[*]} (timeout ${STOP_TIMEOUT}s)"
  "${COMPOSE[@]}" stop -t "${STOP_TIMEOUT}" "${STOPPED[@]}"
}

cleanup() {
  local rc=$?
  ((${#STOPPED[@]})) || return "${rc}"
  info "restarting ${STOPPED[*]}"
  # `start`, not `up -d`: the containers still exist, and up -d would recreate
  # them from a compose file that may need a rendered .env. errexit is off
  # inside a trap on purpose — the restart must be attempted whatever failed.
  if ! "${COMPOSE[@]}" start "${STOPPED[@]}" >/dev/null 2>&1 \
    && ! "${COMPOSE[@]}" up -d "${STOPPED[@]}" >/dev/null 2>&1; then
    red "############################################################"
    red "THE STACK IS DOWN. backup-volumes.sh stopped these services"
    red "and could not start them again:"
    red "  ${STOPPED[*]}"
    red "Run: make up"
    red "############################################################"
    STOPPED=()
    return 1
  fi
  STOPPED=()
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Archiving
# ---------------------------------------------------------------------------
TORN=()

archive_one() {
  local vol="$1" out="$2" tar_rc age_rc
  local -a rcs=()

  # tar writes to stdout and age writes the file as the operator. The plaintext
  # never touches this disk — the property backup-firewall.sh gets by piping ssh
  # into sops — and backups/ is never bind-mounted into a container, which is
  # what used to make every archive root-owned and unrotatable.
  #
  # :ro on the source: a backup must not be able to write to the thing it is
  # backing up. --network none and --read-only because tar to stdout needs
  # neither. --numeric-owner because these volumes belong to uids the container
  # has no names for (65534, 10001, 472) and the restore path needs them back
  # verbatim.
  #
  # errexit is lifted for the pipeline because BOTH statuses are needed, and
  # `rc=$?` afterwards would clobber PIPESTATUS.
  # --log-driver none, and it is load-bearing rather than tidiness. This
  # container's stdout IS the gzip stream, the json-file driver records stdout
  # whether or not anyone reads it, and Alloy's loki.source.docker tails every
  # container on the socket — so this line used to ship each archive back into
  # Loki as log lines. Measured on 2026-08-29: 765 MB across three volumes in
  # about three minutes, 2.7 MiB/s against a 950 B/s baseline, which took loki's
  # RSS to 1015 MiB and is the whole reason its mem_limit is 1536M (#286, #114).
  #
  # It also undid this function's own argument. The comment above says the
  # plaintext never touches this disk; the *compressed* plaintext was landing in
  # the loki-data volume, which is not encrypted, and staying there for the
  # 30-day retention.
  #
  # `none` rather than a size cap: there is no volume of this that is useful.
  # The stream is binary, nothing reads `docker logs` on a container the shell
  # is already piping, and a cap would only change how much of it arrives.
  set +e
  docker run --rm --network none --read-only \
      --security-opt no-new-privileges \
      --log-driver none --label homelab.logs=off \
      -v "${PROJECT}_${vol}:/data:ro" \
      "${TAR_IMAGE}" \
      tar --numeric-owner -czf - -C /data . \
    | age --recipient "${AGE_RECIPIENT}" --output "${out}"
  # Copied in one go: reading PIPESTATUS is itself a command, and the first
  # assignment would reset it before the second could see index 1.
  rcs=("${PIPESTATUS[@]}")
  set -e
  tar_rc="${rcs[0]}"; age_rc="${rcs[1]}"

  ((age_rc == 0)) || { red "${vol}: age failed (rc ${age_rc})"; return 1; }

  case "${tar_rc}" in
    0) ;;
    # GNU tar exits 1 — not 2 — for "file changed as we read it", which is
    # precisely the hot-copy hazard. BusyBox tar cannot report it at all, which
    # is why the archiver image is Debian; see compose.yaml.
    1)
      if ((HOT)); then
        warn "${vol}: a file changed while tar was reading it — this archive is torn"
        TORN+=("${vol}")
      else
        red "${vol}: a file changed while tar was reading it, with the service stopped — something else is writing to this volume"
        return 1
      fi
      ;;
    *) red "${vol}: tar failed (rc ${tar_rc})"; return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------
prune() {
  local -a sets=()
  mapfile -t sets < <(complete_sets)

  local d incomplete
  incomplete=$(comm -23 <(all_sets | sort) <(printf '%s\n' "${sets[@]}" | sort) | wc -l)
  if ((incomplete > 0)); then
    # Reported, never deleted. Deleting data on a failure path is the exact bug
    # class #64 is about.
    warn "${incomplete} incomplete set(s) in ${OUT_DIR} — a failed run left these. Inspect, then remove them by hand."
  fi

  if ((${#sets[@]} <= KEEP)); then
    info "${#sets[@]} complete set(s), keeping ${KEEP} — nothing to prune"
    return 0
  fi

  local keep_quiesced
  keep_quiesced="$(newest_quiesced)"

  for d in "${sets[@]:KEEP}"; do
    # Never construct an rm -rf target from an unvalidated variable.
    if [[ -z ${d} || ${d} != "${OUT_DIR}/"[0-9]* || ! -f ${d}/MANIFEST ]]; then
      red "refusing to prune ${d}"
      continue
    fi
    # A run of --hot backups must not evict the last archive anyone has actually
    # proven restorable.
    if [[ ${d} == "${keep_quiesced}" ]]; then
      info "keeping $(basename "${d}") — the newest quiesced set"
      continue
    fi
    info "pruning $(basename "${d}")"
    rm -rf -- "${d}"
  done
}

# ---------------------------------------------------------------------------
# Arguments
#
# --hot is a modifier that still runs the main path, so a bare case on $1 will
# not do. The loop keeps the recognisable shape — an explicit "" arm and a
# rejecting * arm — and refuses a second mode rather than letting the last one
# win silently.
# ---------------------------------------------------------------------------
usage() { sed -n 's|^# \{0,1\}||; /^Usage:/,/^$/p' "$0" | head -20; }

MODE=backup
MODE_SET=""
HOT=0
ALL=0
SET_ARG=""
ONLY=""

set_mode() {
  [[ -z ${MODE_SET} ]] || die "conflicting modes: --${MODE_SET} and --$1"
  MODE="$1"; MODE_SET="$1"
}

while (($#)); do
  case "$1" in
    --hot)         HOT=1 ;;
    --all)         ALL=1 ;;
    --set)         SET_ARG="${2:?--set needs a stamp}"; shift ;;
    --only)        ONLY="${2:?--only needs a comma-separated volume list}"; shift ;;
    --list)        set_mode list ;;
    --inventory)   set_mode inventory ;;
    --project)     set_mode project ;;
    --verify-only) set_mode verify ;;
    --prune)       set_mode prune ;;
    -h|--help)     usage; exit 0 ;;
    "")            ;;
    *)             die "unknown argument: $1" ;;
  esac
  shift
done

COMPOSE=(docker compose -f "${COMPOSE_FILE}")

load_inventory

# Resolved after the inventory so a typo is checked against the real volume list
# rather than silently restoring nothing.
ONLY_VOLUMES=()
if [[ -n ${ONLY} ]]; then
  IFS=',' read -r -a ONLY_VOLUMES <<<"${ONLY}"
  for v in "${ONLY_VOLUMES[@]}"; do
    [[ -n ${SENTINEL[$v]:-} && -n ${VOL_SERVICE[$v]:-} ]] \
      || die "unknown volume: ${v} (have: ${VOLUMES[*]})"
  done
fi

case "${MODE}" in
  inventory)
    print_inventory
    exit 0
    ;;
  # The compose project name is what prefixes the volumes. Exposed so
  # restore-volumes.sh does not have to derive it a second time.
  project)
    printf '%s\n' "${PROJECT}"
    exit 0
    ;;
  list)
    list_sets
    exit 0
    ;;
esac

need age
[[ -f ${AGE_IDENTITY} ]] \
  || die "no age identity at ${AGE_IDENTITY} — verification decrypts what it just wrote, and an unverified backup is not a backup"

case "${MODE}" in
  verify)
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
      verify_set "${t}" "${ONLY_VOLUMES[@]}" || failed=1
    done
    ((failed == 0)) || die "verification FAILED"
    exit 0
    ;;
  prune)
    prune
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Main path
#
# Everything that can fail is made to fail BEFORE anything is stopped.
# ---------------------------------------------------------------------------
need docker
need tar
need awk
need flock
need numfmt
docker info >/dev/null 2>&1 || die "cannot reach the docker daemon"

mkdir -p "${OUT_DIR}"

# Without this a cron run and a manual run overlap: one stops the stack while
# the other is mid-archive, and the first to finish restarts it under the second.
exec 9>"${OUT_DIR}/.lock"
flock -n 9 || die "another $(basename "$0") is already running"

AGE_RECIPIENT="$(recipient)"
[[ -n ${AGE_RECIPIENT} ]] || die "no age recipient found in ${SOPS_POLICY}"

"${COMPOSE[@]}" config -q >/dev/null 2>&1 \
  || die "docker compose config failed — the \${VAR:?} guards need a rendered .env. Run: make render"

# `docker run -v missing_volume:/data` CREATES an empty volume, so a wrong
# prefix produces five plausible-looking 45-byte archives and exit 0. This host
# already carries orphan prometheus_* volumes from an older project name.
for v in "${VOLUMES[@]}"; do
  docker volume inspect "${PROJECT}_${v}" >/dev/null 2>&1 \
    || die "no volume ${PROJECT}_${v} — the stack has not been started under project '${PROJECT}', or it was created under a different one (docker volume ls)"
done

TAR_IMAGE="$("${REPO_ROOT}/scripts/image-for.sh" archiver)"
docker image inspect "${TAR_IMAGE}" >/dev/null 2>&1 || {
  info "pulling ${TAR_IMAGE}"
  docker pull -q "${TAR_IMAGE}" >/dev/null
}

# The sizing pass doubles as proof the archiver image actually runs, before the
# stack goes down. This is what stops the classic "stack is down, and now the
# registry is unreachable".
info "sizing ${#VOLUMES[@]} volume(s)"
total_kb=0
for v in "${VOLUMES[@]}"; do
  kb="$(docker run --rm --network none --log-driver none --label homelab.logs=off \
        -v "${PROJECT}_${v}:/data:ro" "${TAR_IMAGE}" \
        du -sk /data | awk '{print $1}')"
  total_kb=$((total_kb + kb))
done
avail_kb="$(df --output=avail -k "${OUT_DIR}" | tail -1 | tr -d ' ')"
if ((avail_kb < total_kb * 11 / 10)); then
  die "only $(human $((avail_kb * 1024))) free at ${OUT_DIR}, and the volumes hold $(human $((total_kb * 1024))) uncompressed — refusing to start"
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SET_DIR="${OUT_DIR}/${STAMP}"
# No -p: a duplicate stamp is a named error, not a merge.
mkdir "${SET_DIR}" || die "set ${STAMP} already exists"

if ((HOT)); then
  warn "--hot: the stack keeps running, so nothing here is proven restorable."
  warn "grafana.db in particular is SQLite; a copy taken mid-transaction, with no"
  warn "journal to go with it, opens fine and is silently missing writes."
else
  # EXIT alone does not cover an uncaught SIGINT. Turning the signal into a
  # normal exit is what guarantees the EXIT trap runs exactly once, on every
  # path a backup can die on. SIGKILL cannot be trapped, and note that
  # `restart: unless-stopped` does NOT help — a container stopped by
  # `docker compose stop` is one Docker has been told to leave alone.
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi

started=${SECONDS}
((HOT)) || quiesce
downtime_start=${SECONDS}

failed=0
declare -A BYTES=() SHA=()
for v in "${VOLUMES[@]}"; do
  info "archiving ${v} (${VOL_SERVICE[$v]}${VOL_MOUNT[$v]})"
  part="${SET_DIR}/${v}.tar.gz.age.part"
  if ! archive_one "${v}" "${part}"; then
    rm -f "${part}"
    failed=1
    continue
  fi
  if ! verify "${part}" "${v}" "${HOT}"; then
    failed=1
    continue
  fi
  BYTES["${v}"]="$(stat -c %s "${part}")"
  SHA["${v}"]="$(sha256sum "${part}" | awk '{print $1}')"
  mv "${part}" "${SET_DIR}/${v}.tar.gz.age"
done

downtime=$((SECONDS - downtime_start))

# Restart before writing the manifest: the stack matters more than the paperwork.
if ((HOT == 0)); then
  trap - EXIT INT TERM
  cleanup || failed=1
fi

if ((failed)); then
  red "one or more volumes failed — no manifest written, nothing pruned"
  red "the incomplete set is at ${SET_DIR}"
  exit 1
fi

# Written last: its presence is what marks the set complete. Extension-free on
# purpose — .yamllint.yaml has no backups/ ignore and markdownlint globs
# **/*.md, so MANIFEST.yaml or MANIFEST.md would be linted by `make lint`.
{
  printf '# %s set %s\n' "$(basename "$0")" "${STAMP}"
  printf 'stack\t%s\n' "${STACK}"
  printf 'project\t%s\n' "${PROJECT}"
  printf 'mode\t%s\n' "$( ((HOT)) && echo hot || echo quiesced )"
  # Which key is needed to read this set, and so which sets survived a rotation.
  printf 'recipient\t%s\n' "${AGE_RECIPIENT}"
  printf 'archiver\t%s\n' "${TAR_IMAGE}"
  printf 'downtime\t%s\n' "${downtime}"
  ((${#TORN[@]})) && printf 'torn\t%s\n' "${TORN[*]}"
  printf '#volume\tservice\tmount\tbytes\tsha256\n'
  for v in "${VOLUMES[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${v}" "${VOL_SERVICE[$v]}" "${VOL_MOUNT[$v]}" "${BYTES[$v]}" "${SHA[$v]}"
  done
} > "${SET_DIR}/MANIFEST"

prune

set_bytes=0
for v in "${VOLUMES[@]}"; do set_bytes=$((set_bytes + BYTES[$v])); done

printf '\n'
green "wrote ${SET_DIR#"${REPO_ROOT}"/} — ${#VOLUMES[@]} volumes, $(human "${set_bytes}"), $( ((HOT)) && echo "stack never stopped (UNPROVEN)" || echo "stack down ${downtime}s" ), $((SECONDS - started))s total"
printf '\n'
info "This is on the same host as everything it protects."
info "Copy the set to the backup target and offsite — see docs/roadmap.md #92."
info "On a timer: systemctl list-timers 'homelab-*' — docs/runbooks/schedule-maintenance.md."
info "Restoring it: docs/runbooks/restore-the-stack.md"
