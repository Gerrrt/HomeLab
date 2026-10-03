#!/usr/bin/env bash
#
# Archive Immich's library off its USB disk, encrypt it here, prove it, and
# copy it to oracle. The interim copy ADR-0064 decides, until #455's exists.
#
# WHAT THIS PROTECTS, AND WHAT IT DOES NOT
#
# The photographs. backup-volumes.sh covers immich-db, the metadata, but the
# originals are a bind mount on trinity's 2 TB USB disk (IMMICH_UPLOAD_LOCATION,
# /data in immich-server) and no volume set can contain a bind mount. Since
# 2026-09-28 that disk has held the household's real photographs, and until
# this ran it was the only copy of them anywhere (stacks/sensitive/README.md,
# "What backs Immich up").
#
# One archive per set, immich-library.tar.gz.age, holding:
#
#   ./upload ./library    the originals — every asset.originalPath is in one
#   ./profile             profile pictures
#   ./backups             Immich's own nightly pg_dump, 02:00, fourteen kept
#   ./thumbs/.immich      the two regenerable trees' markers, and nothing else
#   ./encoded-video/.immich
#
# thumbs/ and encoded-video/ are derived from the originals, and Immich's Jobs
# page regenerates them. Their .immich markers ARE archived: the server refuses
# to start when a folder's marker is missing, so a set without them would
# restore a library that will not boot until the markers are made by hand.
#
# This copy is OFF-HOST and NOT OFF-ESTATE. oracle is on the same shelf, in
# the same room, on the same power, and every set here is encrypted to the
# recipients of secrets/sensitive.sops.yaml — trinity's key and, since #835,
# the technical second's — and, since ADR-0073, to
# stacks/sensitive/household.recipients as well. Sets taken before #835 landed
# open with trinity's key alone. It protects against the USB disk failing, and
# against trinity failing only if one of those keys has a proven copy
# (`make secrets-verify-backup STACK=sensitive`).
# It does NOT satisfy ADR-0023's Durable row, and ADR-0064 says so: that needs
# the copy on #455's drive, encrypted to a key the operator does not solely
# hold. The set format is the estate's standard one so that #455 can carry
# these sets beside the others rather than building a second mechanism.
#
# WHY NOTHING IS STOPPED
#
# backup-volumes.sh stops a service because a copy of a live database is a
# file that looks like a backup. There is no database here. Originals are
# written once and never modified in place; the dump in ./backups is a
# finished file by the time this runs (05:15, after Immich's 02:00). The order
# is upstream's rule for a consistent backup — database first, then the files
# — and every set carries both halves, so a set is a restore unit on its own:
# an asset uploaded after the dump is a file no row names, which costs a
# re-upload, and a row with no file cannot arise from this order.
#
# ./upload is read before ./library because Immich's storage template MOVES
# files from the first to the second. A file moved mid-run is then read in one
# place or the other, never neither. A file that changes or vanishes while tar
# reads it is GNU tar's exit 1, and it means an upload or a move landed during
# the read: the archive is discarded and the read repeated, up to LIB_ATTEMPTS
# times, and then the run fails by name. Anything else from tar is fatal.
#
# WHY IT SOURCES backup-volumes.sh
#
# The same reasons backup-nas.sh gives: one sentinel table (immich-library is
# an ARCHIVE name there, like jellyfin-config), one verify(), one set layout,
# and the far-side helpers #535 built — copy_offhost, the far-side sha256
# check, prune_offhost. The sets are in backups/immich-library/, not
# backups/volumes/, so neither KEEP nor verify_set's volume list can see the
# other kind.
#
# WHAT CROSSES THE WIRE
#
# Everything backup-volumes.sh sends, under its rules (oracle's login shell is
# zsh with nomatch on), plus one command of this script's own, sent before any
# tar runs:
#
#   mkdir -p '<dir>' && df -Pk '<dir>'
#
# oracle's backups/ is on its ROOT logical volume, beside the volume, NAS and
# firewall sets and beneath its own dead man's switch. A library that outgrows
# it must fail this run, loudly, and not fill that filesystem: the preflight
# refuses unless the free space after one more set would still be at least
# LIB_OFFHOST_RESERVE_KB. When it refuses, ADR-0064 has expired — #455's drive,
# or an lvextend on oracle, is the answer, and the message names both.
#
# WHY LIB_KEEP AND NOT KEEP
#
# Every unit reads /etc/default/homelab-timers and backup-volumes.sh owns KEEP
# there, as backup-nas.sh owns NAS_KEEP. Two, not seven: each set is the whole
# library, oracle's room is the constraint, and deletion is not what this copy
# is for — Immich's own trash keeps a deleted asset thirty days. Two nights is
# the window to notice that the disk under the newest set was already wrong.
#
# --prove
#
# The claim the 2026-09-28 rehearsal made about the disk, made about a set:
# every original the live database names is in the set, and hashes to the
# SHA-1 the database holds for it (asset.checksum). The archive is decrypted
# as a stream into python's tarfile, so no plaintext reaches a disk. An asset
# created after the set's stamp is `newer`, not bad; one whose path is absent
# but whose checksum is in the set under another path is `moved` — the
# storage template — and not bad either. bad > 0 fails.
#
# Usage:
#   scripts/backup-library.sh                        archive, verify, copy to oracle, prune
#   scripts/backup-library.sh --local-only           any of the below without the far side
#   scripts/backup-library.sh --copy-only            copy every set oracle lacks; seeding, catch-up
#   scripts/backup-library.sh --list                 show the sets that exist, here and there
#   scripts/backup-library.sh --verify-only          re-verify the newest set, here and there
#   scripts/backup-library.sh --verify-only --all    re-verify every retained set, here and there
#   scripts/backup-library.sh --verify-only --set <STAMP>
#   scripts/backup-library.sh --prune                apply retention only, both sides
#   scripts/backup-library.sh --prove [--set <STAMP>]  hash every original in a set against immich-db
#   scripts/backup-library.sh --self-test            the refusals, the set and the proof, against a throwaway tree
#
# Environment:
#   LIB_SOURCE              default IMMICH_UPLOAD_LOCATION from stacks/sensitive/.env, else /srv/immich
#   LIB_OFFHOST             default atropos@10.0.99.30:backups/immich-library
#   LIB_KEEP                default 2          complete sets to retain, here and there
#   LIB_ATTEMPTS            default 3          reads of a library that keeps changing before the run fails
#   LIB_OFFHOST_RESERVE_KB  default 15728640   KiB that must stay free on the far side after a set lands
#   LIB_DB_CONTAINER        default sensitive-immich-db   where --prove reads the asset table
#   SOPS_AGE_KEY_FILE       default ~/.config/sops/age/keys.txt
#   LIB_UNSAFE_SELF_TEST    the self-test's, and nobody else's: it lifts the
#                           mountpoint check and lets LIB_OUT_DIR, LIB_RECIPIENTS,
#                           LIB_HOUSEHOLD_RECIPIENTS_FILE and LIB_PROVE_ROWS stand
#                           in for the host

# shellcheck disable=SC2016
# ^ the self-test hands assert() test expressions as single-quoted strings, on purpose.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# --self-test, before anything reads the host
#
# CI has no age binary and no key, so the fixtures put a pass-through `age` on
# PATH: it writes its input to --output and cats a file back on --decrypt.
# Everything else — the guards, tar, verify(), the MANIFEST, retention, the
# room arithmetic and the proof — is the real code. What no fixture can cover
# is the real encryption and the real far side; the first real run is where
# those are proven, and stacks/sensitive/README.md records it.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  T="$(mktemp -d)"
  trap 'rc=$?; rm -rf "${T}"; exit "${rc}"' EXIT INT TERM
  mkdir -p "${T}/bin"
  cat > "${T}/bin/age" <<'SHIM'
#!/usr/bin/env bash
# Self-test stand-in for age: no encryption, the same argv shape.
out="" dec=0 last=""
while (($#)); do
  case "$1" in
    -d|--decrypt) dec=1 ;;
    -i|--identity|-r|--recipient) shift ;;
    -o|--output) out="$2"; shift ;;
    *) last="$1" ;;
  esac
  shift
done
if ((dec)); then
  if [[ -n ${last} ]]; then cat -- "${last}"; else cat; fi
else
  cat > "${out}"
fi
SHIM
  chmod +x "${T}/bin/age"
  : > "${T}/identity"
  # Real recipients, public halves only: the household holder and the fallback.
  HH=age1mt2p3n6xqzevjyqq7qpxhwc3zk6wlc3qace6rj5qfhhkzhl3gyqsq5r349
  HS=age1vfe5xddxdzh5ggqmhhte0l78s2ktvmuzyjrfpjsemuez5q9z8u2q9cdlwz
  printf '# role: household\n%s\n# role: technical-second\n%s\n' "${HH}" "${HS}" > "${T}/household"

  # A library the shape trinity's is: markers in every folder, originals in
  # both trees, a dump, and derived files that must NOT travel.
  mklib() {  # <dir>
    local d="$1" f
    mkdir -p "$d"/{library/admin/2020,upload/u1/ab,profile,backups,thumbs/u1,encoded-video/u1}
    for f in library upload profile backups thumbs encoded-video; do printf 'immich\n' > "$d/$f/.immich"; done
    printf 'photo-a\n' > "$d/library/admin/2020/a.jpg"
    printf 'photo-b\n' > "$d/upload/u1/ab/b.jpg"
    printf 'dump\n' | gzip > "$d/backups/immich-db-backup-20260929T020000-v3.2.4-pg17.6.sql.gz"
    printf 'thumb\n' > "$d/thumbs/u1/x.webp"
    printf 'video\n' > "$d/encoded-video/u1/y.mp4"
  }
  mklib "${T}/lib"

  fail=0
  run() {  # <args...> → OUT, RC
    set +e
    OUT="$(PATH="${T}/bin:${PATH}" LIB_UNSAFE_SELF_TEST="${UNSAFE-1}" \
           LIB_SOURCE="${SRC_FOR_TEST:-${T}/lib}" LIB_OUT_DIR="${T}/out" LIB_KEEP=2 \
           LIB_RECIPIENTS=age1fixture LIB_HOUSEHOLD_RECIPIENTS_FILE="${HH_FOR_TEST:-${T}/household}" \
           LIB_PROVE_ROWS="${ROWS_FOR_TEST:-${T}/rows}" \
           SOPS_AGE_KEY_FILE="${T}/identity" "${BASH_SOURCE[0]}" "$@" 2>&1)"
    RC=$?
    set -e
  }
  check() {  # <name> <expected rc> <expected substring>
    if [[ ${RC} == "$2" && ${OUT} == *"$3"* ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$1"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       exit %s, wanted %s; wanted output containing: %s\n' "$1" "${RC}" "$2" "$3"
      printf '%s\n' "${OUT}" | sed 's/^/       | /'
      fail=1
    fi
  }
  assert() {  # <name> <bash test expression, as a string>
    if eval "$2"; then printf '\033[0;32m  PASS\033[0m %s\n' "$1"
    else printf '\033[0;31m  FAIL\033[0m %s\n' "$1"; fail=1; fi
  }

  run --local-only
  check "a set is written from the library, with nothing stopped" 0 "nothing stopped"
  first="$(find "${T}/out" -mindepth 1 -maxdepth 1 -type d -name '2*' | sort | tail -1)"
  assert "the set is complete: one archive, and the MANIFEST written last" \
    '[[ -f ${first}/MANIFEST && -f ${first}/immich-library.tar.gz.age && ! -e ${first}/immich-library.tar.gz.age.part ]]'
  assert "the MANIFEST says what was read and which dump rides with it" \
    'grep -qx "mode	live" "${first}/MANIFEST" && grep -q "^db_dump	immich-db-backup-20260929T020000" "${first}/MANIFEST" && grep -qx "files	2" "${first}/MANIFEST"'
  assert "the set is encrypted to the household's keys as well as the tier's (ADR-0073)" \
    'grep -qx "recipient	age1fixture,${HH},${HS}" "${first}/MANIFEST"'
  # shellcheck disable=SC2034  # read by the assert() strings below
  listing="$(tar -tzf "${first}/immich-library.tar.gz.age")"
  assert "the originals, the profile and the dump travel" \
    '[[ ${listing} == *"./library/admin/2020/a.jpg"* && ${listing} == *"./upload/u1/ab/b.jpg"* && ${listing} == *"./backups/immich-db-backup-"* && ${listing} == *"./profile/.immich"* ]]'
  assert "the derived trees do not, but their markers do" \
    '[[ ${listing} == *"./thumbs/.immich"* && ${listing} == *"./encoded-video/.immich"* && ${listing} != *"x.webp"* && ${listing} != *"y.mp4"* ]]'

  run --verify-only --local-only
  check "--verify-only proves the set it wrote" 0 "./library/.immich present"

  mkdir -p "${T}/empty"
  SRC_FOR_TEST="${T}/empty" run --local-only
  check "a source without the library's marker is refused" 1 "no .immich marker"
  assert "and the refusal wrote no set" \
    '[[ $(find "${T}/out" -mindepth 1 -maxdepth 1 -type d -name "2*" | wc -l) -eq 1 ]]'

  printf '%s\n' "${HH}" > "${T}/household.bad"
  HH_FOR_TEST="${T}/household.bad" run --local-only
  check "a household file that does not parse fails the run, not the encryption" 1 "cannot read the household's recipients"

  UNSAFE="" run --local-only
  check "a source that is not a mountpoint is refused outside the self-test" 1 "not a mountpoint"

  sleep 1; run --local-only
  sleep 1; run --local-only
  check "a third set prunes to LIB_KEEP" 0 "pruning $(basename "${first}")"
  assert "two sets remain, and the oldest is gone" \
    '[[ ! -e ${first} && $(find "${T}/out" -mindepth 2 -maxdepth 2 -name MANIFEST | wc -l) -eq 2 ]]'

  # The room arithmetic, called directly: a function with no side effects.
  eval "$(sed -n '/^lib_room_ok()/,/^}/p' "${BASH_SOURCE[0]}")"
  assert "room: a set that leaves the reserve free fits" 'lib_room_ok 100 30 50'
  assert "room: a set that would eat into the reserve does not" '! lib_room_ok 100 60 50'
  assert "room: a set that fits only without the reserve does not" '! lib_room_ok 100 90 20'

  # The proof. Rows are sha1 epoch path, the shape --prove reads from psql.
  sa="$(sha1sum "${T}/lib/library/admin/2020/a.jpg" | cut -d' ' -f1)"
  sb="$(sha1sum "${T}/lib/upload/u1/ab/b.jpg" | cut -d' ' -f1)"
  printf '%s 1 /data/library/admin/2020/a.jpg\n%s 1 /data/upload/u1/ab/b.jpg\n' "${sa}" "${sb}" > "${T}/rows"
  run --prove
  check "--prove: every original hashes to its row" 0 "ok=2 moved=0 newer=0 bad=0"
  printf '%s 1 /data/library/admin/2020/a.jpg\n%s 1 /data/upload/u1/ab/b.jpg\n' "${sa}" "${sa}" > "${T}/rows.bad"
  ROWS_FOR_TEST="${T}/rows.bad" run --prove
  check "--prove: a file that is not the one the database names is bad" 1 "bad=1"
  printf '%s 1 /data/library/admin/2020/a.jpg\n%s 4102444800 /data/upload/u1/zz/new.jpg\n' "${sa}" "${sb}0" > "${T}/rows.newer"
  ROWS_FOR_TEST="${T}/rows.newer" run --prove
  check "--prove: an asset created after the set is newer, not bad" 0 "ok=1 moved=0 newer=1 bad=0"
  printf '%s 1 /data/library/admin/2021/a.jpg\n' "${sa}" > "${T}/rows.moved"
  ROWS_FOR_TEST="${T}/rows.moved" run --prove
  check "--prove: an original the storage template moved is found by checksum" 0 "ok=0 moved=1 newer=0 bad=0"

  # A crossed mapping: another archive's content under this name must not
  # verify, whatever it is called.
  newest="$(find "${T}/out" -mindepth 1 -maxdepth 1 -type d -name '2*' | sort | tail -1)"
  mkdir -p "${T}/vault" && head -c 2048 /dev/urandom > "${T}/vault/db.sqlite3" && printf 'y\n' > "${T}/vault/rsa_key.pem"
  tar -czf "${newest}/immich-library.tar.gz.age" -C "${T}/vault" .
  run --verify-only --local-only
  check "an archive that is not the library does not verify under its name" 1 "not a immich-library backup"

  exit "${fail}"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Set before the source line: backup-volumes.sh validates VOL_OFFHOST as it
# loads. Set unconditionally, because the value the volume unit puts in
# /etc/default/homelab-timers names the wrong directory for this set.
STACK=sensitive
VOL_OFFHOST="${LIB_OFFHOST:-atropos@10.0.99.30:backups/immich-library}"
# shellcheck source=scripts/backup-volumes.sh
source "${REPO_ROOT}/scripts/backup-volumes.sh"

UNSAFE=0
[[ -n ${LIB_UNSAFE_SELF_TEST:-} ]] && UNSAFE=1

OUT_DIR="${REPO_ROOT}/backups/immich-library"
((UNSAFE)) && [[ -n ${LIB_OUT_DIR:-} ]] && OUT_DIR="${LIB_OUT_DIR}"

LIB_KEEP="${LIB_KEEP:-2}"
LIB_ATTEMPTS="${LIB_ATTEMPTS:-3}"
LIB_OFFHOST_RESERVE_KB="${LIB_OFFHOST_RESERVE_KB:-15728640}"
LIB_DB_CONTAINER="${LIB_DB_CONTAINER:-sensitive-immich-db}"

# Rejected rather than clamped, as backup-nas.sh rejects NAS_KEEP.
if ! [[ ${LIB_KEEP} =~ ^[0-9]+$ ]] || ((LIB_KEEP < 1)); then
  die "LIB_KEEP must be a positive integer, got '${LIB_KEEP}'"
fi
KEEP="${LIB_KEEP}"
if ! [[ ${LIB_ATTEMPTS} =~ ^[0-9]+$ ]] || ((LIB_ATTEMPTS < 1)); then
  die "LIB_ATTEMPTS must be a positive integer, got '${LIB_ATTEMPTS}'"
fi
[[ ${LIB_OFFHOST_RESERVE_KB} =~ ^[0-9]+$ ]] \
  || die "LIB_OFFHOST_RESERVE_KB must be a number of KiB, got '${LIB_OFFHOST_RESERVE_KB}'"
[[ ${LIB_DB_CONTAINER} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || die "LIB_DB_CONTAINER must be a container name, got '${LIB_DB_CONTAINER}'"

# The source. Read out of the stack's rendered .env with a plain match, not by
# sourcing it: that file carries secrets, and this needs one line of it.
if [[ -n ${LIB_SOURCE:-} ]]; then
  SRC="${LIB_SOURCE}"
else
  SRC="$(sed -n 's/^IMMICH_UPLOAD_LOCATION=//p' "${REPO_ROOT}/stacks/sensitive/.env" 2>/dev/null | tail -1 || true)"
  SRC="${SRC:-/srv/immich}"
fi
[[ ${SRC} =~ ^/[A-Za-z0-9._/-]+$ && ${SRC} != *..* ]] \
  || die "the library source must be an absolute path of letters, digits, . _ - and /, got '${SRC}'"
SRC="${SRC%/}"

# The archive name is the SENTINEL key in backup-volumes.sh; a single archive
# per set, so VOLUMES is it.
VOLUMES=(immich-library)
ONLY_VOLUMES=()
check_sentinel_table
[[ -n ${SENTINEL[immich-library]:-} ]] \
  || die "no sentinel for immich-library in backup-volumes.sh — this script will not write a backup it cannot verify"

# upload before library: see WHY NOTHING IS STOPPED.
MEMBERS=(./upload ./library ./profile ./backups ./thumbs/.immich ./encoded-video/.immich)
MARKERS=(library upload profile backups)

# Whether a set of need_kb fits in avail_kb and still leaves reserve_kb free.
# Pure, so the self-test calls it with numbers.
lib_room_ok() {  # <avail_kb> <need_kb> <reserve_kb>
  (($1 - $2 >= $3))
}

# ---------------------------------------------------------------------------
# --prove: the python half. stdin is the decrypted tar.gz stream; fd 3 is one
# row per asset, "sha1hex epoch originalPath". Nothing is extracted.
# ---------------------------------------------------------------------------
PROVE_PY='
import hashlib, os, sys, tarfile
stamp = int(os.environ["LIB_SET_EPOCH"])
got = {}
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|gz") as t:
    for m in t:
        if not m.isfile():
            continue
        name = m.name[2:] if m.name.startswith("./") else m.name
        if not name.startswith(("library/", "upload/")) or name.endswith("/.immich"):
            continue
        h = hashlib.sha1()
        f = t.extractfile(m)
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
        got[name] = h.hexdigest()
sums = set(got.values())
ok = moved = newer = bad = rows = 0
with os.fdopen(3) as fd:
    for line in fd:
        line = line.rstrip("\n")
        if not line:
            continue
        rows += 1
        s, e, p = line.split(" ", 2)
        rel = p[len("/data/"):] if p.startswith("/data/") else p
        if got.get(rel) == s:
            ok += 1
        elif rel in got:
            bad += 1
            print("BAD (differs)", p)
        elif int(e) > stamp:
            newer += 1
        elif s in sums:
            moved += 1
        else:
            bad += 1
            print("BAD (absent)", p)
print(f"ok={ok} moved={moved} newer={newer} bad={bad} — {rows} asset rows, {len(got)} originals in the set")
sys.exit(1 if bad or rows == 0 else 0)
'

# ---------------------------------------------------------------------------
# Arguments — backup-nas.sh's shape, plus --prove.
# ---------------------------------------------------------------------------
usage() { sed -n 's|^# \{0,1\}||; /^Usage:/,/^$/p' "$0" | head -14; }

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
    --prove)       set_mode prove ;;
    --local-only)  LOCAL_ONLY=1 ;;
    --all)         ALL=1 ;;
    --set)
      SET_ARG="${2:-}"
      [[ ${SET_ARG} =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "--set wants a stamp like 20260929T051500Z, got '${SET_ARG}'"
      shift
      ;;
    -h|--help)     usage; exit 0 ;;
    "")            ;;
    *)             usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done
[[ ${MODE} == verify || ${ALL} == 0 ]] || die "--all belongs to --verify-only"
[[ ${MODE} == verify || ${MODE} == prove || -z ${SET_ARG} ]] || die "--set belongs to --verify-only and --prove"
if [[ ${MODE} == copy ]] && ((LOCAL_ONLY)); then
  die "--copy-only --local-only would do nothing"
fi

case "${MODE}" in
  list)
    list_sets
    ((LOCAL_ONLY)) || list_remote_sets
    exit 0
    ;;
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
      verify_set "${t}" immich-library || failed=1
    done
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
  prove)
    need python3
    take_lock wait
    if [[ -n ${SET_ARG} ]]; then
      target="${OUT_DIR}/${SET_ARG}"
    else
      target="$(newest_complete)"
    fi
    [[ -n ${target} && -f ${target}/MANIFEST ]] || die "no complete set to prove in ${OUT_DIR}"
    stamp="$(basename "${target}")"
    set_epoch="$(date -u -d "${stamp:0:8} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s)"
    if ((UNSAFE)) && [[ -n ${LIB_PROVE_ROWS:-} ]]; then
      rows="$(cat -- "${LIB_PROVE_ROWS}")"
    else
      need docker
      # Every asset the library holds, external libraries excepted: those are
      # read from paths this set does not cover, and are not uploads.
      rows="$(docker exec "${LIB_DB_CONTAINER}" psql -U postgres -d immich -AtF' ' \
                -c "select encode(checksum,'hex'), extract(epoch from \"createdAt\")::bigint, \"originalPath\" from asset where not \"isExternal\"")" \
        || die "cannot read the asset table from ${LIB_DB_CONTAINER} — is the sensitive stack up?"
    fi
    info "proving ${stamp} against ${LIB_DB_CONTAINER}'s asset table"
    set +e
    age --decrypt -i "${AGE_IDENTITY}" "${target}/immich-library.tar.gz.age" \
      | LIB_SET_EPOCH="${set_epoch}" python3 -c "${PROVE_PY}" 3<<<"${rows}"
    rcs=("${PIPESTATUS[@]}")
    set -e
    ((rcs[0] == 0)) || die "FAILED to decrypt ${stamp}/immich-library.tar.gz.age"
    ((rcs[1] == 0)) || die "${stamp} does not hold every original the database names — see the BAD lines above"
    green "${stamp} holds every original the database named when it was written, each the file its checksum says"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Main path
#
# Everything that can fail is made to fail BEFORE anything is written.
# ---------------------------------------------------------------------------
need tar
need gzip
need awk
need flock
need numfmt
need sha256sum
need mountpoint
((LOCAL_ONLY)) || { need ssh; need cmp; }

# A locked LUKS disk, or one that did not mount at boot, leaves /srv/immich an
# empty directory on the root filesystem — build-the-sensitive-tier-host.md §5
# makes it immutable for exactly that reason. An archive of it would verify as
# nothing at all, but it is refused here, by name, first.
if ((UNSAFE == 0)); then
  mountpoint -q "${SRC}" \
    || die "${SRC} is not a mountpoint — the library disk is not mounted (build-the-sensitive-tier-host.md §5); refusing to archive whatever is underneath"
fi
for m in "${MARKERS[@]}"; do
  [[ -r ${SRC}/${m}/.immich ]] \
    || die "no .immich marker in ${SRC}/${m} — this is not Immich's library, or it is not all there"
done

# After the guards, because take_lock creates OUT_DIR: a refused run leaves
# nothing behind.
take_lock

if ((UNSAFE)) && [[ -n ${LIB_RECIPIENTS:-} ]]; then
  IFS=, read -r -a AGE_RECIPIENTS <<<"${LIB_RECIPIENTS}"
else
  mapfile -t AGE_RECIPIENTS < <("${REPO_ROOT}/scripts/key-recipients.sh" --list --stack sensitive)
fi
((${#AGE_RECIPIENTS[@]})) || die "no age recipients from secrets/sensitive.sops.yaml — nothing to encrypt to"
# And the household's (ADR-0073): the keys that open the copy on the household
# drive, which are deliberately not in the sops rule. Encrypted to here, once,
# so the drive carries these bytes unchanged and nothing re-encrypts the
# library with trinity's key in hand. A file that does not parse fails the run:
# a set made without them is one the drive will refuse as unfit.
HOUSEHOLD_FILE="${REPO_ROOT}/stacks/sensitive/household.recipients"
((UNSAFE)) && [[ -n ${LIB_HOUSEHOLD_RECIPIENTS_FILE:-} ]] && HOUSEHOLD_FILE="${LIB_HOUSEHOLD_RECIPIENTS_FILE}"
household="$("${REPO_ROOT}/scripts/household-recipients.sh" --file "${HOUSEHOLD_FILE}" --list)" \
  || die "cannot read the household's recipients from ${HOUSEHOLD_FILE} — fix it before the next set (ADR-0073)"
while IFS= read -r r; do
  [[ " ${AGE_RECIPIENTS[*]} " == *" ${r} "* ]] || AGE_RECIPIENTS+=("${r}")
done <<<"${household}"
unset household
AGE_ARGS=()
for r in "${AGE_RECIPIENTS[@]}"; do AGE_ARGS+=(--recipient "${r}"); done
AGE_RECIPIENT="$(IFS=,; printf '%s' "${AGE_RECIPIENTS[*]}")"
unset r

# Sizes, uncompressed. Photographs do not compress, so this is the set's size
# to within a few percent, and it is what both sides are checked against.
total_kb="$(cd "${SRC}" && du -sck "${MEMBERS[@]}" | awk 'END { print $1 }')"
[[ ${total_kb} =~ ^[0-9]+$ ]] || die "du on ${SRC} returned '${total_kb}', not a size"
info "${SRC} holds $(human $((total_kb * 1024))) to archive"
avail_kb="$(df --output=avail -k "${OUT_DIR}" | tail -1 | tr -d ' ')"
if ((avail_kb < total_kb * 11 / 10)); then
  die "only $(human $((avail_kb * 1024))) free at ${OUT_DIR}, and the library is $(human $((total_kb * 1024))) — refusing to start"
fi

if ((LOCAL_ONLY == 0)); then
  far="$(remote "mkdir -p '${OFFHOST_DIR}' && df -Pk '${OFFHOST_DIR}'")" \
    || die "cannot ask ${OFFHOST_TARGET} how much room ${OFFHOST_DIR} has — check it is reachable (docs/runbooks/restore-the-stack.md §0), or run with --local-only"
  far_kb="$(awk 'NR == 2 { print $4 }' <<<"${far}")"
  [[ ${far_kb} =~ ^[0-9]+$ ]] || die "df on ${OFFHOST_TARGET} returned '${far}', not a size"
  if ! lib_room_ok "${far_kb}" "${total_kb}" "${LIB_OFFHOST_RESERVE_KB}"; then
    die "${OFFHOST_TARGET}:${OFFHOST_DIR} has $(human $((far_kb * 1024))) free; one more set of $(human $((total_kb * 1024))) would leave less than the $(human $((LIB_OFFHOST_RESERVE_KB * 1024))) reserve on oracle's root volume. ADR-0064 has run out: land #455's copy, or lvextend oracle and raise nothing here"
  fi
fi

# What rides with the originals: the newest of Immich's own dumps, and the
# newest volume set holding immich-db. Recorded, not required — the dump is
# in the archive either way.
db_dump="$(find "${SRC}/backups" -maxdepth 1 -name '*.sql.gz' -printf '%f\n' 2>/dev/null | sort | tail -1 || true)"
db_set="$(find "${REPO_ROOT}/backups/volumes" -mindepth 2 -maxdepth 2 -name MANIFEST -printf '%h\n' 2>/dev/null | sort | tail -1 || true)"
files="$(cd "${SRC}" && find ./upload ./library -type f ! -name .immich | wc -l)"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SET_DIR="${OUT_DIR}/${STAMP}"
mkdir "${SET_DIR}" || die "set ${STAMP} already exists"

started=${SECONDS}
part="${SET_DIR}/immich-library.tar.gz.age.part"
attempt=0
while :; do
  attempt=$((attempt + 1))
  info "archiving ${SRC} (attempt ${attempt} of ${LIB_ATTEMPTS})"
  # The host's GNU tar, not the archiver image: the library is owned by the
  # deploying user, and nothing here needs a container. -1 because photos do
  # not compress and the CPU is better spent not trying. The plaintext never
  # touches a disk: tar's stdout is age's stdin.
  set +e
  tar --numeric-owner -C "${SRC}" -cf - "${MEMBERS[@]}" \
    | gzip -1 \
    | age "${AGE_ARGS[@]}" --output "${part}"
  rcs=("${PIPESTATUS[@]}")
  set -e
  ((rcs[1] == 0 && rcs[2] == 0)) || { rm -f "${part}"; die "gzip or age failed writing ${part} (rc ${rcs[1]}, ${rcs[2]}) — the incomplete set is at ${SET_DIR}"; }
  case "${rcs[0]}" in
    0) break ;;
    1)
      rm -f "${part}"
      if ((attempt >= LIB_ATTEMPTS)); then
        die "the library changed under every one of ${LIB_ATTEMPTS} reads — uploads or a storage-template migration are running; the incomplete set is at ${SET_DIR}, nothing pruned"
      fi
      warn "a file changed or moved while tar read it — an upload landed; reading again"
      ;;
    *)
      rm -f "${part}"
      die "tar failed reading ${SRC} (rc ${rcs[0]}) — a file the deploying user cannot read? The incomplete set is at ${SET_DIR}, nothing pruned"
      ;;
  esac
done

# Strict: the sentinel must be present, and another archive's must not be.
if ! verify "${part}" immich-library 0; then
  red "the library archive did not verify — the incomplete set is at ${SET_DIR}, no manifest written, nothing pruned"
  exit 1
fi
bytes="$(stat -c %s "${part}")"
sha="$(sha256sum "${part}" | awk '{print $1}')"
mv "${part}" "${SET_DIR}/immich-library.tar.gz.age"

# Written last: its presence is what marks the set complete. The same shape
# backup-volumes.sh writes, so every set helper and the far-side checks read it
# unchanged. `live` rather than `quiesced`: nothing was stopped, and nothing
# needed to be.
{
  printf '# %s set %s\n' "$(basename "$0")" "${STAMP}"
  printf 'stack\t%s\n' sensitive
  printf 'project\t%s\n' sensitive
  printf 'mode\t%s\n' live
  printf 'source\t%s\n' "${SRC}"
  printf 'members\t%s\n' "${MEMBERS[*]}"
  printf 'recipient\t%s\n' "${AGE_RECIPIENT}"
  printf 'archiver\t%s\n' host-tar
  printf 'attempts\t%s\n' "${attempt}"
  printf 'files\t%s\n' "${files}"
  printf 'db_dump\t%s\n' "${db_dump:--}"
  printf 'db_set\t%s\n' "$(basename "${db_set:--}")"
  printf 'downtime\t0\n'
  printf '#volume\tservice\tmount\tbytes\tsha256\n'
  printf '%s\t%s\t%s\t%s\t%s\n' immich-library immich-server /data "${bytes}" "${sha}"
} > "${SET_DIR}/MANIFEST"

prune

printf '\n'
green "wrote ${SET_DIR#"${REPO_ROOT}"/} — ${files} originals, $(human "${bytes}"), nothing stopped, $((SECONDS - started))s"
printf '\n'

if ((LOCAL_ONLY)); then
  info "--local-only: this set is on trinity's SSD and nowhere else. Copy it: make backup-library ARGS=--copy-only"
else
  if ! copy_offhost; then
    printf '\n'
    red "wrote ${STAMP} but the off-host copy FAILED — the library is on the USB disk and trinity's SSD only"
    red "check: ${OFFHOST_TARGET} reachable, its host key in ~/.ssh/known_hosts, and this"
    red "host's key authorised there — docs/runbooks/restore-the-stack.md §0"
    exit 1
  fi
  if ! prune_offhost; then
    printf '\n'
    red "wrote and copied ${STAMP} but retention on ${OFFHOST_TARGET} FAILED"
    red "the backup is safe; the far side is growing, and its reserve is what stops it"
    exit 1
  fi
  printf '\n'
  info "Copied to ${OFFHOST_TARGET}:${OFFHOST_DIR} — off-host, NOT off-estate (ADR-0064). ADR-0023's copy is #455's."
fi
info "Proving it against the database: make backup-library ARGS=--prove"
info "Restoring it: docs/runbooks/restore-the-sensitive-tier.md § Restore Immich."
