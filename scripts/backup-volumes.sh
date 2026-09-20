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
# a 1.4 GB output file for a 1 GB TSDB. `age -r` streams. The recipients are
# still the stack's — read from secrets/<STACK>.sops.yaml by way of
# scripts/key-recipients.sh, see recipients() below — so there is still one
# set of keys, and re-keying the secrets re-keys the next backup.
#
# The recipients are passed in argv and are therefore visible in `ps`. They
# are public keys; they can only encrypt. Do not "fix" this.
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
# WHY THE COPY IS PART OF THE JOB AND NOT A SEPARATE ONE
#
# For three weeks this script ended by printing "copy the set to the backup
# target and offsite — see docs/roadmap.md #92", and nothing did. A set on the
# disk it protects is a copy, not a backup. ADR-0015 gave the copy a home —
# `oracle`, the other laptop on the shelf, which already receives the firewall
# export — and #535 built it, on the model scripts/backup-firewall.sh set: the
# copy is a step of THIS job, after the set is written, verified and the stack
# is back up, and a run whose copy fails exits non-zero even though the local
# set is complete. The weekly timer records the exit code
# (scripts/run-scheduled.sh), so "the sets have stopped leaving this host" is
# ScheduledJobFailed within ten minutes rather than a sentence nobody reads.
# The daily verify-backups run checks the far side too, so a copy that stops
# existing is a failed job the next morning. No new unit, lock, metric or
# alert rule: backup.rules.yaml names no job on purpose.
#
# What lands on oracle is age ciphertext. The private key is NOT there and must
# never be — a compromise of oracle yields nothing. The far side needs sshd and
# coreutils: `ls`, `mkdir`, `cat`, `mv`, `rm`, `sha256sum`, `nice`. The proof
# that a copy is a backup is a far-side sha256sum compared with the MANIFEST's
# column, which was computed on the bytes verify() had just decrypted — the
# same claim backup-firewall.sh makes by pulling the bytes back, without the
# wire time (a set is close to a gigabyte on a 100 Mb/s link). The MANIFEST
# itself is small, so it IS pulled back and compared. Known limit, stated
# rather than engineered away: the key that writes there can also delete
# there. Same trust as the firewall copy; append-only storage is a different
# issue. And same room, so this is off-host and not offsite. A fire still
# takes both.
#
# One retention knob, KEEP, both sides — backup-firewall.sh:80-88 has the
# argument. The far side keeps the newest KEEP complete sets, never the newest,
# and never a set this host still holds: prune() below keeps an extra set when
# the newest quiesced one is past KEEP, and without that clause the far side
# would delete it weekly and the next copy would upload it again. Steady state
# there is KEEP+1 sets, bounded. The far-side directory is per STACK, because
# trinity runs this script as STACK=sensitive against the same oracle and one
# host's prune must not be able to see the other host's sets.
#
# WHAT MAY BE SENT TO THE FAR SIDE
#
# Every remote command is handed to oracle's LOGIN SHELL, which is zsh with
# `nomatch` on: a glob matching nothing is a fatal error, not the literal bash
# would pass through, and a non-zero remote command fails the job. So nothing
# sent from this file may contain a glob, and nothing may be bash-only — no
# arrays, no [[ ]], no $( ). What crosses the wire is cd, ls, mkdir -p, chmod,
# cat, mv, rm, nice, sha256sum and single-quoted literals, each literal a name
# that passed is_stamp() or is_volume_name() first. That character class is the
# point: no quote, space, newline, leading dash or glob metacharacter survives
# it, so a validated name cannot break out of the quotes it is embedded in.
# All the bash stays on this side. The helpers are deliberately a copy of the
# firewall script's rather than a shared library: the unit of transfer differs
# (a directory written MANIFEST-last, not a file) and a bug here must not be
# able to break a nightly job that has run since 2026-09-03.
#
# WHEN SOURCED
#
# scripts/backup-nas.sh sources this file rather than running it: it pulls
# Jellyfin's state off smaug over ssh (ADR-0045), a job this script's docker-
# and-quiesce shape cannot do, and it wants the same sentinel table, the same
# verify() and the same set layout rather than a second copy of them. The
# guard just above the argument parsing returns to the caller, so everything
# above it is a library and everything below it is this script.
#
# Usage:
#   scripts/backup-volumes.sh                       quiesce, archive, verify, copy to oracle
#   scripts/backup-volumes.sh --hot                 skip the stop; UNPROVEN
#   scripts/backup-volumes.sh --local-only          any of the below without the far side
#   scripts/backup-volumes.sh --copy-only           copy every set oracle lacks; seeding, catch-up
#   scripts/backup-volumes.sh --list                show the sets that exist, here and there
#   scripts/backup-volumes.sh --inventory           print the derived volume table
#   scripts/backup-volumes.sh --project             print the compose project name
#   scripts/backup-volumes.sh --verify-only         re-verify the newest set, here and there
#   scripts/backup-volumes.sh --verify-only --all   re-verify every retained set, here and there
#   scripts/backup-volumes.sh --verify-only --set <STAMP> [--only vol,vol]
#   scripts/backup-volumes.sh --prune               apply retention only, both sides
#
# Environment:
#   STACK              default observability   selects stacks/<STACK>/compose.yaml
#   COMPOSE_PROJECT_NAME   overrides the volume prefix, as it does for compose
#   KEEP               default 7               complete sets to retain, here and there
#   VOL_OFFHOST        default atropos@10.0.99.30:backups/volumes/<STACK> — user@host:dir,
#                      the dir relative to that user's home unless absolute. The
#                      weekly unit can override it in /etc/default/homelab-timers.
#   STOP_TIMEOUT       default 60              seconds before SIGKILL on stop
#   SOPS_AGE_KEY_FILE  default ~/.config/sops/age/keys.txt
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${STACK:-observability}"
STACK_DIR="${REPO_ROOT}/stacks/${STACK}"
COMPOSE_FILE="${STACK_DIR}/compose.yaml"
OUT_DIR="${REPO_ROOT}/backups/volumes"
AGE_IDENTITY="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
KEEP="${KEEP:-7}"
STOP_TIMEOUT="${STOP_TIMEOUT:-60}"
VOL_OFFHOST="${VOL_OFFHOST:-atropos@10.0.99.30:backups/volumes/${STACK}}"

# BatchMode so a missing key, or an unknown host key, fails loudly instead of
# hanging a timer on a prompt.
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

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

# ---------------------------------------------------------------------------
# Configuration checks — before any mode is dispatched, because KEEP and
# VOL_OFFHOST now reach `rm -rf` on another host.
# ---------------------------------------------------------------------------

# STACK names the far-side directory, so it is remote command text.
[[ ${STACK} =~ ^[a-z][a-z0-9-]*$ ]] \
  || die "STACK may only contain lowercase letters, digits and -, got '${STACK}'"

# Rejected rather than clamped: a mistyped KEEP in an environment file is not a
# request to delete every set on either side. Before this the local prune
# survived KEEP="" only because \${sets[@]:KEEP} is a bash error; the far-side
# prune would have compared against 0 and removed every set but the newest.
if ! [[ ${KEEP} =~ ^[0-9]+$ ]] || ((KEEP < 1)); then
  die "KEEP must be a positive integer, got '${KEEP}'"
fi

OFFHOST_TARGET="${VOL_OFFHOST%%:*}"
OFFHOST_DIR="${VOL_OFFHOST#*:}"
[[ ${VOL_OFFHOST} == *:* && -n ${OFFHOST_TARGET} && -n ${OFFHOST_DIR} ]] \
  || die "VOL_OFFHOST must be user@host:dir, got '${VOL_OFFHOST}'"
# Enough for a directory handed to ls and cat; retention hands it to rm, and a
# stray quote in an operator-edited /etc/default/homelab-timers would otherwise
# close the quoting and turn the rest of the line into remote command text.
[[ ${OFFHOST_DIR} =~ ^[A-Za-z0-9._/-]+$ ]] \
  || die "VOL_OFFHOST directory may only contain letters, digits, . _ - and /, got '${OFFHOST_DIR}'"
[[ ${OFFHOST_DIR} != "/" && ${OFFHOST_DIR} != *..* ]] \
  || die "VOL_OFFHOST directory may not be / or contain '..', got '${OFFHOST_DIR}'"
# zsh resolves a `cd` argument through CDPATH unless it starts with / ./ or ../
# and oracle's login shell IS zsh. Anchoring it costs two characters.
OFFHOST_CD="${OFFHOST_DIR}"
[[ ${OFFHOST_CD} == /* ]] || OFFHOST_CD="./${OFFHOST_CD}"

# The recipients are the STACK's, read out of its encrypted secrets file by
# key-recipients.sh — the `sops:` metadata, which is fact, where .sops.yaml is
# policy; that script's header carries the argument. This used to take the
# first age1 key in .sops.yaml, whichever rule it sat in, which was right for
# exactly as long as the estate's was the only real key there. The day
# `make secrets-init STACK=sensitive` fills trinity's placeholder — which sits
# ABOVE the catch-all — the estate's weekly backup would have been encrypted
# to trinity's key, one this host does not hold, and failed at its own verify
# step after stopping the stack for nothing. And on trinity the same line
# picked the estate's key, so the tier's backups could never have been opened
# where they were made (#131).
#
# EVERY recipient of the file, not the first. A volume archive holds what the
# secrets file holds — grafana-data carries the admin password hash and every
# datasource credential; vaultwarden-data is the vault — so whoever can open
# the one is exactly who should be able to open the other. For the estate that
# is ADR-0024's second recipient; for the sensitive tier it is the recipient
# ADR-0023 requires of the off-estate copy, "the key that opens it cannot be
# the one only the operator holds". One --recipient each to age; the manifest
# records them comma-separated.
#
# Called on the main path only, after the mode dispatch: --inventory, --list
# and --verify-only need no recipient and must keep working on a host whose
# secrets file is not yet there.
recipients() {
  "${REPO_ROOT}/scripts/key-recipients.sh" --list --stack "${STACK}"
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
#
# The table is the union across stacks; load_inventory() takes the entries the
# selected compose file declares. A nested path is as good a sentinel as a
# top-level one — the match is the whole listing line — and the two Caddy
# volumes need that: both hold a single `./caddy` directory, so a top-level
# entry would be the crossed mapping this exists to catch, present in both.
#
# A sentinel must also be unique across the union — load_inventory() refuses
# the table if two volumes share one — but it MAY coincide with an entry some
# other volume legitimately carries, and one does: paperless-data's ./index is
# Loki's index directory, listed under loki-data in COMPANIONS below. From
# 2026-09-13, the first weekly run after #133's table reached the host, every
# Loki archive — five sets that had verified clean the day before — was refused
# as "a paperless-data backup", and no manifest was written since (#468).
# verify() now reads a foreign sentinel that is one of the volume's own
# companions as evidence only when the volume's own sentinel is ALSO missing,
# which is what a mislabelled archive looks like and what a real Loki volume
# never does.
#
# The sensitive tier's (STACK=sensitive) were read off the volumes after a
# boot of the pinned images, not guessed — and this table is the reason a
# stack backup on trinity works at all: load_inventory() below dies on the
# first declared volume with no entry here, and the foundation's three had
# none until Vaultwarden (#131) and Paperless-ngx (#133) each needed the
# mechanism on the same day. Caddy writes ./caddy/instance.uuid to /data and
# ./caddy/autosave.json to /config on every start, admin API or not. step-ca's
# is the one entry here written from construction rather than a boot: the
# image's entrypoint refuses to start without config/ca.json, so a
# step-ca-data that lacks it is a volume that never held a CA. Vaultwarden
# creates ./db.sqlite3 and ./rsa_key.pem on first start (read off a boot of
# the pinned image on 2026-09-09; the WAL beside the database is where a
# stopped container's last writes sit, see COMPANIONS). Home Assistant writes
# ./.HA_VERSION at the top of /config on every start (read off a boot of the
# pinned image on 2026-09-10; the volume also carries .storage/ and the
# recorder's home-assistant_v2.db, and the bind-mounted configuration.yaml
# appears in it as an empty placeholder). AdGuard's ./data/sessions.db is
# there ten seconds into a first start, beside stats.db and the filters
# directory (read off a boot of the pinned image on 2026-09-10, ports
# unpublished). Immich's Postgres (17, mounted at .../data) has ./PG_VERSION
# at the top, where Paperless's 18 nests it under ./18/docker; its model cache
# gains ./huggingface — huggingface_hub's own store — on the first fetch of
# either model, beside ./clip or ./facial-recognition (one CLIP text model
# fetched into the pinned image on 2026-09-10). Before that fetch the cache is
# EMPTY, and an empty archive is fatal in verify() by design — which is why
# the cache is not archived at all: DISPOSABLE, below. Paperless:
# paperless-data holds the Tantivy index the container rebuilds at every
# start, so ./index is there from the first boot; paperless-media is
# ./documents/{originals,archive,thumbnails} from the first consume and
# ./documents alone before it; Postgres 18 lays its cluster out one level down
# as ./18/docker, so the sentinel carries the major and a bump to 19 has to
# move it here — loudly, since the script refuses to write an archive it
# cannot verify; and Valkey's ./dump.rdb is written by `--save 60 1` and again
# on the SIGTERM a quiesce sends, which is the case that was checked.
#
# Jellyfin's (jellyfin-config) is the one entry here that no compose file on
# this host declares: it is an ARCHIVE name, consumed by scripts/backup-nas.sh,
# which sources this file for the tables and verify() and pulls the directory
# off smaug over ssh (ADR-0045). Read off a boot of the pinned image on
# 2026-09-19: ./data/jellyfin.db is created about thirty seconds into a first
# start, when the migration service seeds it — a listing taken at twenty
# seconds shows ./data holding only its .jellyfin-data marker — and the log
# names the path outright ("Data Source=/config/data/jellyfin.db"). The WAL
# beside it is where the writes are, as with Vaultwarden: 1.6 MB in
# jellyfin.db-wal against 12 KB in jellyfin.db while running, and a clean stop
# checkpoints it into a 536 KB main file with no -wal at all. A ZFS snapshot
# taken while Jellyfin runs carries all three files (db, -wal, -shm) at one
# instant, which is what makes reading one consistent; see COMPANIONS.
declare -A SENTINEL=(
  [prometheus-data]="./chunks_head"
  [loki-data]="./chunks"
  [grafana-data]="./grafana.db"
  [alertmanager-data]="./nflog"
  [alloy-data]="./alloy_seed.json"
  [caddy-data]="./caddy/instance.uuid"
  [caddy-config]="./caddy/autosave.json"
  [step-ca-data]="./config/ca.json"
  [vaultwarden-data]="./db.sqlite3"
  [home-assistant-config]="./.HA_VERSION"
  [adguard-work]="./data/sessions.db"
  [immich-db]="./PG_VERSION"
  [paperless-data]="./index"
  [paperless-media]="./documents"
  [paperless-db-data]="./18/docker/PG_VERSION"
  [paperless-broker-data]="./dump.rdb"
  [jellyfin-config]="./data/jellyfin.db"
)

# Reported when absent, never fatal. These cover the fresh-volume case, where
# the discriminating entry above may not exist yet.
#
# rsa_key.pem signs every Vaultwarden session token: a restore without it
# logs every client out, which is not data loss but is worth seeing in the
# verify line. attachments, sends and icon_cache appear on first use. The WAL
# is listed because it is where the last writes ARE: measured on the pinned
# image, a `docker stop` leaves a 12 KB db.sqlite3-wal holding the account
# registered a minute earlier, and db.sqlite3 read on its own shows no such
# user. The quiesced archive carries all three files, so a restore is
# consistent; a check that copies the main file alone is not.
declare -A COMPANIONS=(
  [prometheus-data]="./wal ./lock ./queries.active"
  [loki-data]="./wal ./index ./compactor"
  [grafana-data]="./plugins ./dashboards ./png"
  [alertmanager-data]="./silences"
  [alloy-data]="./remotecfg"
  [caddy-data]="./caddy/locks ./caddy/last_clean.json"
  [caddy-config]=""
  [step-ca-data]="./certs ./secrets ./db"
  [vaultwarden-data]="./rsa_key.pem ./db.sqlite3-wal ./attachments ./sends ./icon_cache"
  [home-assistant-config]="./.storage ./home-assistant_v2.db"
  [adguard-work]="./data/stats.db ./data/filters"
  [immich-db]="./base ./pg_wal ./postgresql.conf"
  [paperless-data]="./log ./celerybeat-schedule.db"
  [paperless-media]="./documents/originals ./documents/archive ./documents/thumbnails"
  [paperless-db-data]="./18/docker/base ./18/docker/pg_wal"
  [paperless-broker-data]=""
  [jellyfin-config]="./data/jellyfin.db-wal ./config/system.xml ./metadata ./plugins"
)

# Volumes archived by NOTHING, each with the reason — the third table, and
# the only way a declared volume leaves a set without the run failing. A
# cache the service re-fetches on first use is not data: archiving Immich's
# model cache would add a gigabyte of downloadable weights to every set and,
# worse, fail the run on a host where the models have not been fetched yet,
# because an empty archive is refused above and rightly so. Listed by name so
# the omission is a decision recorded here rather than a volume that fell
# through; a volume in neither this table nor SENTINEL is still fatal (#131).
#
# jellyfin-cache is here for the same reason and one more: stacks/media runs
# on smaug, where this script does not, so the entry exists to make
# `STACK=media backup-volumes.sh --inventory` say the true thing — nothing in
# that file is this script's to archive — instead of dying over a sentinel.
# What IS archived from that host is backup-nas.sh's, and it is a bind mount
# on erebor/apps rather than a volume, which is why no jellyfin-config is
# declared there at all (ADR-0045).
declare -A DISPOSABLE=(
  [immich-model-cache]="a model cache immich-machine-learning re-downloads on first use"
  [jellyfin-cache]="transcode scratch and image caches Jellyfin regenerates on demand"
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

# Two volumes sharing a sentinel is the one thing verify() cannot recover from:
# owner[] keeps whichever came last, so one of the two would always read as the
# other's archive. Refused at load, before any volume is stopped, for the same
# reason a missing sentinel is — a named error beats an archive nothing can
# verify. A sentinel that merely appears among another volume's COMPANIONS is
# allowed, and verify() says how it is treated (#468).
check_sentinel_table() {
  local v w
  for v in "${!SENTINEL[@]}"; do
    for w in "${!SENTINEL[@]}"; do
      if [[ ${v} < ${w} && ${SENTINEL[$v]} == "${SENTINEL[$w]}" ]]; then
        die "${v} and ${w} share the sentinel ${SENTINEL[$v]} in $(basename "$0") — verify() could not tell their archives apart; give one of them a nested path"
      fi
    done
  done
}

load_inventory() {
  [[ -f ${COMPOSE_FILE} ]] || die "no compose file at ${COMPOSE_FILE}"
  check_sentinel_table

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
    # To stderr: --inventory's stdout is a table restore-volumes.sh parses.
    if [[ -n ${DISPOSABLE[$v]:-} ]]; then
      printf '\033[0;34m--\033[0m not archiving %s: %s\n' "${v}" "${DISPOSABLE[$v]}" >&2
      continue
    fi
    # Derivation solves one inventory; the sentinel table is a second one.
    # Making its absence fatal means adding a sixth volume produces a named
    # error rather than an archive nothing can verify.
    [[ -n ${SENTINEL[$v]:-} ]] \
      || die "no sentinel defined for ${v} in $(basename "$0") — add one; this script will not write a backup it cannot verify"
    VOLUMES+=("${v}")
  done

  ((${#VOLUMES[@]} > 0)) || die "every volume ${COMPOSE_FILE} declares is listed as disposable — nothing to archive"

  # The services stopped are the owners of what is ARCHIVED, not of every
  # mount: immich-machine-learning owns only a cache nobody is copying, and
  # quiescing it would cost the tier its search for the length of the run.
  mapfile -t SERVICES < <(for v in "${VOLUMES[@]}"; do printf '%s\n' "${VOL_SERVICE[$v]}"; done | sort -u)
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

# The volumes a MANIFEST lists, and the sha256 it recorded for one of them.
# The five-field rows are the volume table; everything else is two fields.
manifest_volumes() { awk -F'\t' 'NF == 5 && $1 !~ /^#/ { print $1 }' "$1/MANIFEST" 2>/dev/null; }
manifest_sha()     { awk -F'\t' -v v="$2" 'NF == 5 && $1 == v { print $5; exit }' "$1/MANIFEST" 2>/dev/null; }
manifest_bytes()   { awk -F'\t' 'NF == 5 && $1 !~ /^#/ { s += $4 } END { print s + 0 }' "$1/MANIFEST" 2>/dev/null; }

# ---------------------------------------------------------------------------
# The far side — see WHAT MAY BE SENT TO THE FAR SIDE in the header.
#
# Nothing here needs more than sshd and coreutils on the target: no rsync, no
# agent, no key. Files are streamed over ssh into a .part name and renamed, and
# a set's MANIFEST goes last, so a copy that dies mid-transfer leaves a
# directory with no MANIFEST — INCOMPLETE, by the same rule as here — and never
# a plausible-looking set that is short.
# ---------------------------------------------------------------------------

# stdin closed by default so a command that does not stream cannot eat the
# caller's. The copy is the one that streams, and says so.
remote()       { "${SSH[@]}" "${OFFHOST_TARGET}" "$@" </dev/null; }
remote_stdin() { "${SSH[@]}" "${OFFHOST_TARGET}" "$@"; }

# The two predicates every name passes before it is embedded in a quoted remote
# command. Stamps are what this script writes (date -u +%Y%m%dT%H%M%SZ);
# volume names come from compose.yaml, not from this file.
is_stamp()       { [[ $1 =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; }
is_volume_name() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]]; }

# Everything known about the far side, in two round trips, into three arrays:
# the stamp-named directories (newest first), those of them that hold a
# MANIFEST (newest first), and the top-level names that are not stamps —
# counted and reported, never touched. Returns non-zero only when the host
# could not be asked; an empty directory and a missing one are the same
# finding. The MANIFEST probe names each directory explicitly: `ls */MANIFEST`
# is a glob, and `find` is not something the far side is required to have.
REMOTE_STAMPS=()
REMOTE_COMPLETE=()
REMOTE_STRAYS=()
read_remote() {
  local out cmd s
  REMOTE_STAMPS=(); REMOTE_COMPLETE=(); REMOTE_STRAYS=()
  out="$(remote "ls -1 '${OFFHOST_DIR}' 2>/dev/null; true")" || return 1
  while IFS= read -r s; do
    [[ -n ${s} ]] || continue
    if is_stamp "${s}"; then REMOTE_STAMPS+=("${s}"); else REMOTE_STRAYS+=("${s}"); fi
  done < <(sort -r <<<"${out}")
  ((${#REMOTE_STAMPS[@]})) || return 0
  cmd="cd -- '${OFFHOST_CD}' && ls -1 --"
  for s in "${REMOTE_STAMPS[@]}"; do cmd+=" '${s}/MANIFEST'"; done
  cmd+=" 2>/dev/null; true"
  out="$(remote "${cmd}")" || return 1
  while IFS= read -r s; do
    [[ ${s} == */MANIFEST ]] || continue
    s="${s%/MANIFEST}"
    is_stamp "${s}" && REMOTE_COMPLETE+=("${s}")
  done < <(sort -r <<<"${out}")
  return 0
}

remote_has_complete() {
  local s
  for s in "${REMOTE_COMPLETE[@]}"; do [[ ${s} == "$1" ]] && return 0; done
  return 1
}

is_local_complete() {
  local d
  while read -r d; do
    [[ -n ${d} && "$(basename "${d}")" == "$1" ]] && return 0
  done < <(complete_sets)
  return 1
}

# The proof that a copy is a backup: the far side hashes what it holds and the
# hashes must equal the MANIFEST's column, which was computed on the bytes
# verify() had just decrypted. One round trip for every archive of every set
# named — one handshake on that CPU instead of one per file. stdout is kept
# whatever the exit status: sha256sum reports a missing name and hashes the
# rest, so a partial answer is the finding, and only ssh's own 255 means the
# host could not be asked. Honours --only, like verify_set.
verify_remote_archives() {
  local -a dirs=("$@") names=() want=()
  local d stamp vol sha n out rc failed=0
  local -A expect=() got=()
  for d in "${dirs[@]}"; do
    stamp="$(basename "${d}")"
    is_stamp "${stamp}" || { red "refusing to check a set with an unexpected name: ${stamp}"; return 1; }
    if ((${#ONLY_VOLUMES[@]})); then want=("${ONLY_VOLUMES[@]}"); else mapfile -t want < <(manifest_volumes "${d}"); fi
    ((${#want[@]})) || { red "${stamp}: the MANIFEST lists no volumes"; failed=1; continue; }
    for vol in "${want[@]}"; do
      is_volume_name "${vol}" || { red "refusing to send an unexpected volume name: ${vol}"; return 1; }
      sha="$(manifest_sha "${d}" "${vol}")"
      [[ -n ${sha} ]] || { red "${stamp}: no sha256 for ${vol} in the MANIFEST"; failed=1; continue; }
      n="${stamp}/${vol}.tar.gz.age"
      expect["${n}"]="${sha}"
      names+=("${n}")
    done
  done
  ((${#names[@]})) || return "${failed}"

  local cmd="cd -- '${OFFHOST_CD}' && nice -n 19 sha256sum --"
  for n in "${names[@]}"; do cmd+=" '${n}'"; done
  cmd+=" 2>/dev/null"
  rc=0
  out="$(remote "${cmd}")" || rc=$?
  ((rc != 255)) || { red "cannot reach ${OFFHOST_TARGET}"; return 1; }
  while read -r sha n; do
    [[ -n ${n} ]] && got["${n}"]="${sha}"
  done <<<"${out}"
  for n in "${names[@]}"; do
    if [[ -z ${got[${n}]:-} ]]; then
      red "${OFFHOST_TARGET}:${OFFHOST_DIR}/${n} is missing"
      failed=1
    elif [[ ${got[${n}]} != "${expect[${n}]}" ]]; then
      red "${OFFHOST_TARGET}:${OFFHOST_DIR}/${n} differs from the local copy (sha256 ${got[${n}]:0:12}… there, ${expect[${n}]:0:12}… in the MANIFEST)"
      failed=1
    fi
  done
  return "${failed}"
}

# Small, so this one IS pulled back and compared byte for byte.
verify_remote_manifest() {
  local d="$1" stamp
  stamp="$(basename "${d}")"
  is_stamp "${stamp}" || return 1
  if remote "cat '${OFFHOST_DIR}/${stamp}/MANIFEST'" 2>/dev/null | cmp -s - "${d}/MANIFEST"; then
    return 0
  fi
  red "${OFFHOST_TARGET}:${OFFHOST_DIR}/${stamp}/MANIFEST is missing or differs from the local copy"
  return 1
}

# What --verify-only asks of the far side: every archive of every target, then
# each MANIFEST. A set that fails is named with its repair, and the repair is
# by hand: this script never deletes anything on a failure path (#64), and a
# copy that differs is a finding to look at before it is overwritten.
verify_remote_sets() {
  local d failed=0 n=0
  verify_remote_archives "$@" || failed=1
  for d in "$@"; do
    verify_remote_manifest "${d}" || failed=1
    n=$((n + 1))
  done
  if ((failed)); then
    red "repair: on ${OFFHOST_TARGET} remove the set named above — rm -rf '${OFFHOST_DIR}/<STAMP>' — then here: make backup ARGS=--copy-only"
    return 1
  fi
  green "verified ${n} set(s) on ${OFFHOST_TARGET}:${OFFHOST_DIR} — every archive hashes to its MANIFEST entry, every MANIFEST byte-identical"
}

# Every complete local set the far side does not have, newest first, not just
# the one this run wrote. A Sunday oracle was off would otherwise leave one set
# that never left this host, and nothing would ever go back for it. Archives
# first, then the hashes are checked, then the MANIFEST — so the far side's
# "complete" means what it means here.
copy_offhost() {
  local -a local_sets=() vols=()
  local d stamp vol name copied=0
  mapfile -t local_sets < <(complete_sets)
  if ((${#local_sets[@]} == 0)) || [[ -z ${local_sets[0]} ]]; then
    info "no complete sets in ${OUT_DIR} — nothing to copy"
    return 0
  fi
  read_remote || { red "cannot reach ${OFFHOST_TARGET}"; return 1; }
  remote "mkdir -p '${OFFHOST_DIR}' && chmod 700 '${OFFHOST_DIR}'" \
    || { red "cannot create ${OFFHOST_DIR} on ${OFFHOST_TARGET}"; return 1; }
  for d in "${local_sets[@]}"; do
    stamp="$(basename "${d}")"
    is_stamp "${stamp}" || { warn "skipping ${stamp} — not a stamp this script writes"; continue; }
    remote_has_complete "${stamp}" && continue
    mapfile -t vols < <(manifest_volumes "${d}")
    ((${#vols[@]})) || { red "${stamp}: the MANIFEST lists no volumes — not copying it"; return 1; }
    info "copying ${stamp} ($(human "$(manifest_bytes "${d}")")) to ${OFFHOST_TARGET}:${OFFHOST_DIR}"
    remote "mkdir -p '${OFFHOST_DIR}/${stamp}' && chmod 700 '${OFFHOST_DIR}/${stamp}'" \
      || { red "cannot create ${OFFHOST_DIR}/${stamp} on ${OFFHOST_TARGET}"; return 1; }
    for vol in "${vols[@]}"; do
      is_volume_name "${vol}" || { red "refusing to send an unexpected volume name: ${vol}"; return 1; }
      name="${vol}.tar.gz.age"
      [[ -f ${d}/${name} ]] || { red "${stamp}: ${name} is missing here although the MANIFEST lists it"; return 1; }
      remote_stdin "cat > '${OFFHOST_DIR}/${stamp}/${name}.part' && mv -f '${OFFHOST_DIR}/${stamp}/${name}.part' '${OFFHOST_DIR}/${stamp}/${name}'" < "${d}/${name}" \
        || { red "copy of ${stamp}/${name} to ${OFFHOST_TARGET} failed"; return 1; }
    done
    verify_remote_archives "${d}" || return 1
    remote_stdin "cat > '${OFFHOST_DIR}/${stamp}/MANIFEST.part' && mv -f '${OFFHOST_DIR}/${stamp}/MANIFEST.part' '${OFFHOST_DIR}/${stamp}/MANIFEST'" < "${d}/MANIFEST" \
      || { red "copy of ${stamp}/MANIFEST to ${OFFHOST_TARGET} failed"; return 1; }
    verify_remote_manifest "${d}" || return 1
    green "copied ${stamp} to ${OFFHOST_TARGET} — every archive hashes to its MANIFEST entry"
    copied=$((copied + 1))
  done
  ((copied)) || info "${OFFHOST_TARGET}:${OFFHOST_DIR} already has every complete set here"
}

# ---------------------------------------------------------------------------
# Far-side retention
#
# ORDER on the main path: prune (here), then copy_offhost, then prune_offhost
# — backup-firewall.sh:321-341 explains both boundaries; getting either wrong
# is a loop rather than a wrong answer.
#
# Two classes of victim, computed from read_remote()'s picture and the local
# complete list, and printed by one function so --list cannot disagree with
# --prune:
#   (a) a complete far-side set beyond the newest KEEP there — never the
#       newest, and never one this host still holds, which is the clause that
#       keeps one KEEP correct for both sides (header). A set only the far
#       side holds, inside the newest KEEP, is left alone: that is what a
#       local wipe looks like from there, and the far side then IS the backup.
#   (b) a far-side directory with no MANIFEST whose stamp this host no longer
#       holds complete. A directory is only ever created there for a set that
#       is complete here, so this is a copy that died, and nothing will ever
#       retry it. One this host does hold is retried by the next copy step,
#       which reuses the same .part names, so it is left alone.
# ---------------------------------------------------------------------------
offhost_victims() {
  local s i=0 newest="${REMOTE_COMPLETE[0]:-}"
  for s in "${REMOTE_COMPLETE[@]}"; do
    i=$((i + 1))
    ((i > KEEP)) || continue
    [[ ${s} == "${newest}" ]] && continue
    is_local_complete "${s}" && continue
    printf '%s\n' "${s}"
  done
  for s in "${REMOTE_STAMPS[@]}"; do
    remote_has_complete "${s}" && continue
    is_local_complete "${s}" && continue
    printf '%s\n' "${s}"
  done
}

prune_offhost() {
  local -a victims=()
  local s out cmd
  read_remote || { red "cannot reach ${OFFHOST_TARGET}"; return 1; }
  ((${#REMOTE_STRAYS[@]} == 0)) \
    || warn "${#REMOTE_STRAYS[@]} name(s) in ${OFFHOST_TARGET}:${OFFHOST_DIR} not written by this script — never pruned, inspect by hand"
  mapfile -t victims < <(offhost_victims)
  if ((${#victims[@]} == 0)) || [[ -z ${victims[0]} ]]; then
    info "${OFFHOST_TARGET}:${OFFHOST_DIR} holds ${#REMOTE_COMPLETE[@]} complete set(s), keeping ${KEEP} — nothing to prune"
    return 0
  fi
  # Every name here came back from the far side and passed is_stamp, so the
  # delete set is by construction a subset of what we were just shown. cd
  # first and name the directories relatively: no path is concatenated over
  # there, and a cd that fails for any reason short-circuits before the rm.
  cmd="cd -- '${OFFHOST_CD}' && rm -rf --"
  for s in "${victims[@]}"; do
    is_stamp "${s}" || { red "refusing to prune ${s} on ${OFFHOST_TARGET}"; return 1; }
    cmd+=" '${s}'"
  done
  info "pruning ${#victims[@]} set(s) on ${OFFHOST_TARGET}: ${victims[*]}"
  out="$(remote "${cmd}" 2>&1)" || { red "prune on ${OFFHOST_TARGET} failed: ${out}"; return 1; }
}

# The far-side half of --list: the dry run for retention, from the same
# picture and the same victim function prune_offhost uses.
list_remote_sets() {
  local -a victims=()
  local s state flag
  printf '\n'
  info "on ${OFFHOST_TARGET}:${OFFHOST_DIR}"
  read_remote || { red "unreachable — nothing off this host is known to exist"; return 0; }
  if ((${#REMOTE_STAMPS[@]} == 0)); then
    info "(nothing)"
  else
    mapfile -t victims < <(offhost_victims)
    for s in "${REMOTE_STAMPS[@]}"; do
      state=INCOMPLETE; flag=""
      remote_has_complete "${s}" && state=complete
      printf '%s\n' "${victims[@]}" | grep -qxF "${s}" && flag=$'\t'"prunes next run"
      printf '%s\t%s%s\n' "${s}" "${state}" "${flag}"
    done
  fi
  info "${#REMOTE_STAMPS[@]} set(s) there (${#REMOTE_COMPLETE[@]} complete), keeping ${KEEP}"
  ((${#REMOTE_STRAYS[@]} == 0)) \
    || warn "${#REMOTE_STRAYS[@]} name(s) there not written by this script — never pruned, inspect by hand"
}

# The lock every mode that reads or changes a set takes. Without it a hand-run
# copy and the daily verify overlap freely — the outer lock in
# scripts/run-scheduled.sh is held by timer runs only — and the verify sees a
# set mid-stream on the far side, reports it missing and pages. The main path
# refuses to wait, as it always has: a second backup queued behind a first
# would stop the stack twice. Everything else queues for as long as the timer
# units do (--lock-wait 900), so a hand seed delays the verify instead of
# failing it.
take_lock() {
  mkdir -p "${OUT_DIR}"
  exec 9>"${OUT_DIR}/.lock"
  if [[ ${1:-} == wait ]]; then
    flock -w 900 9 || die "timed out waiting for another $(basename "$0") to finish"
  else
    flock -n 9 || die "another $(basename "$0") is already running"
  fi
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
  #
  # Unless the other volume's sentinel is an entry THIS volume is documented to
  # carry. paperless-data's ./index is loki-data's index directory (COMPANIONS),
  # so on its own it proves nothing about a Loki archive — every Loki set on
  # the host was refused on that basis from 2026-09-13 (#468). Such a hit is
  # "soft": awk counts it as foreign only when the volume's own sentinel is
  # absent too, in --hot as well as strict, because an archive that carries
  # paperless-data's marker and lacks loki-data's IS the crossed mapping.
  all=""
  soft=""
  for v in "${!SENTINEL[@]}"; do
    all+=" ${v}|${SENTINEL[$v]}"
    if [[ ${v} != "${vol}" && " ${companions} " == *" ${SENTINEL[$v]} "* ]]; then
      soft+=" ${v}"
    fi
  done

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
                | awk -v vol="${vol}" -v all="${all# }" -v companions="${companions}" \
                      -v soft="${soft# }" '
                    BEGIN {
                      n = split(all, pairs, " ")
                      for (i = 1; i <= n; i++) {
                        split(pairs[i], kv, "|")
                        owner[kv[2]] = kv[1]
                      }
                      m = split(companions, c, " ")
                      for (i = 1; i <= m; i++) want[c[i]] = 1
                      k = split(soft, sv, " ")
                      for (i = 1; i <= k; i++) softvol[sv[i]] = 1
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
                      for (v in hit) {
                        if (v == vol) continue
                        # A soft hit (see above) is not foreign while the
                        # sentinel of this volume is itself present.
                        if ((v in softvol) && (vol in hit)) continue
                        foreign = foreign " " v
                      }
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
    | age "${AGE_ARGS[@]}" --output "${out}"
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
# When sourced
#
# scripts/backup-nas.sh sources this file for everything above this line — the
# three tables, check_sentinel_table(), the set helpers, verify(), verify_set()
# and prune() — and stops here, so one sentinel table and one set of
# assertions cover the archives written on this host AND the one pulled off
# smaug (ADR-0045). Nothing above this line may gain a side effect beyond
# `set -euo pipefail`, `umask 077` and definitions: a sourcing caller has not
# parsed its own arguments yet, and OUT_DIR, KEEP and VOLUMES are what it
# overrides after this returns.
# ---------------------------------------------------------------------------
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

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
LOCAL_ONLY=0
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
    --local-only)  LOCAL_ONLY=1 ;;
    --copy-only)   set_mode copy ;;
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

if [[ ${MODE} == copy ]]; then
  ((HOT == 0))        || die "--copy-only takes no --hot: it archives nothing"
  ((LOCAL_ONLY == 0)) || die "--copy-only --local-only would do nothing"
fi

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
    ((LOCAL_ONLY)) || list_remote_sets
    exit 0
    ;;
  # Needs ssh and cmp, not age, docker or the identity: it moves ciphertext
  # that has already been proven, and never stops the stack. This is how the
  # sets that predate the copy get seeded, and how a stretch with oracle off
  # is caught up.
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
      verify_set "${t}" "${ONLY_VOLUMES[@]}" || failed=1
    done
    # The far side is checked even when a local set failed, and both are
    # reported: they are different findings with different repairs. Skipped
    # with --local-only, which is what restore-volumes.sh passes — a restore
    # happens when things are broken, and oracle may be one of them.
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
# Everything that can fail is made to fail BEFORE anything is stopped.
# ---------------------------------------------------------------------------
need docker
need tar
need awk
need flock
need numfmt
if ((LOCAL_ONLY == 0)); then
  need ssh
  need cmp
fi
docker info >/dev/null 2>&1 || die "cannot reach the docker daemon"

# Without this a cron run and a manual run overlap: one stops the stack while
# the other is mid-archive, and the first to finish restarts it under the second.
take_lock

# A warning and not a refusal: the local set is still worth taking, and the
# copy step will say the same thing as a failure. This just says it before the
# stack goes down rather than after.
if ((LOCAL_ONLY == 0)) && ! remote true >/dev/null 2>&1; then
  warn "cannot reach ${OFFHOST_TARGET} now — the set will be written here and the copy step will fail"
fi

# mapfile over a process substitution loses the child's exit status, so the
# check is on what arrived: key-recipients.sh has already said why on stderr.
mapfile -t AGE_RECIPIENTS < <(recipients)
((${#AGE_RECIPIENTS[@]})) || die "no age recipients for stack ${STACK} — nothing to encrypt to"
AGE_ARGS=()
for r in "${AGE_RECIPIENTS[@]}"; do AGE_ARGS+=(--recipient "${r}"); done
AGE_RECIPIENT="$(IFS=,; printf '%s' "${AGE_RECIPIENTS[*]}")"
unset r

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

# Local retention before the copy: a set past KEEP here would be past it there
# too, and copying it first would move a gigabyte that prune_offhost then
# removes in the same run.
prune

set_bytes=0
for v in "${VOLUMES[@]}"; do set_bytes=$((set_bytes + BYTES[$v])); done

printf '\n'
green "wrote ${SET_DIR#"${REPO_ROOT}"/} — ${#VOLUMES[@]} volumes, $(human "${set_bytes}"), $( ((HOT)) && echo "stack never stopped (UNPROVEN)" || echo "stack down ${downtime}s" ), $((SECONDS - started))s total"
printf '\n'

if ((LOCAL_ONLY)); then
  info "--local-only: this is on the same host as everything it protects."
  info "Retention was applied here; ${OFFHOST_TARGET} was not touched. Copy it: make backup ARGS=--copy-only"
else
  # The set is written and proven and the stack is up. From here a failure is
  # still a failure of the JOB — see the header — but the message has to say
  # which half.
  if ! copy_offhost; then
    printf '\n'
    red "wrote ${STAMP} but the off-host copy FAILED — this backup is on the machine it protects"
    red "the local set is complete and verified, and the stack is up"
    red "check: ${OFFHOST_TARGET} reachable, its host key in ~/.ssh/known_hosts, and this"
    red "host's key authorised there — docs/runbooks/restore-the-stack.md §0"
    exit 1
  fi
  # Only once the copy has succeeded, so the far side is never shortened in a
  # run that then re-uploads what it removed.
  if ! prune_offhost; then
    printf '\n'
    red "wrote and copied ${STAMP} but retention on ${OFFHOST_TARGET} FAILED"
    red "the backup is safe; the far side is growing unbounded"
    exit 1
  fi
  printf '\n'
  info "Copied to ${OFFHOST_TARGET}:${OFFHOST_DIR} — off-host, not offsite; a fire takes both. Offsite is make backup-offsite, on the medium's visit (ADR-0047)."
fi
info "On a timer: systemctl list-timers 'homelab-*' — docs/runbooks/schedule-maintenance.md."
case "${STACK}" in
  sensitive) info "Restoring it: docs/runbooks/restore-the-sensitive-tier.md" ;;
  *)         info "Restoring it: docs/runbooks/restore-the-stack.md" ;;
esac
