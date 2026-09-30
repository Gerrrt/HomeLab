#!/usr/bin/env bash
#
# Pull a dump of the wiki's database off oracle, encrypt it here, and prove it
# is readable before calling the run a success. ADR-0065; #251.
#
# WHAT THIS PROTECTS, AND WHAT IT DOES NOT
#
# The Lemmiwinks wiki's Postgres: the accounts, every page's history, the
# navigation, the settings, and the git storage target's configuration. The
# pages themselves are ALSO in the Gerrrt/Lemmiwinks repository, which Wiki.js
# syncs to, so they would survive without this; nothing else in the database
# would. Measured on 2026-09-30: 18 MB of database, 5.3 MB as a gzipped dump.
#
# Nothing else on oracle is archived, by decision: stacks/wiki/compose.yaml's
# header lists what lives under /wiki/data and why all of it is derived from
# the database or from GitHub.
#
# The database holds the git target's deploy key, so a set holds it too. What
# lands here is ciphertext to the estate's recipients, the same two that open
# grafana.db; the key is a deploy key on one repository, and rotating it is a
# GitHub setting and a field in the wiki's admin page.
#
# WHY IT PULLS, AND WHY A DUMP
#
# backup-nas.sh's argument, one host over. oracle holds the estate's backup
# sets and, by ADR-0015's condition, no age identity — so it cannot be the
# host that encrypts, and a set written ON oracle would sit on the one disk
# this exists to get it off. This host already holds a key oracle accepts (the
# one every off-host copy uses), and `atropos` there is in the docker group.
# So this host asks oracle's Postgres for a dump, over ssh, and encrypts what
# arrives: pg_dump's stdout on oracle is gzip's stdin here, then age's, and
# nothing plaintext touches either disk.
#
# A dump rather than backup-volumes.sh's stop-and-tar, and this is the first
# one in the repository (ADR-0065 says why it is not the last word on the
# others). pg_dump reads one consistent snapshot of a RUNNING database, so
# nothing on oracle stops, and the wiki the household reads never goes away
# for a backup. Its output is independent of the cluster's on-disk format, so
# a set taken from 17 restores into 18 — the upgrade this stack will one day
# need is a restore of one of these, not a second mechanism. And it is 5 MB
# instead of a data directory.
#
# The tar format (-Ft), not custom: a tar is what verify() in
# backup-volumes.sh already knows how to prove, so this set is checked by the
# same code as every other — it decrypts, the whole gzip stream parses, and
# the listing carries the sentinel `toc.dat` (pg_dump's table of contents) and
# no other volume's. pg_restore reads the tar directly.
#
# WHAT CROSSES THE WIRE
#
# Three commands, each handed to oracle's login shell, which is zsh with
# nomatch on — so no glob, no bash-only syntax, and every interpolated value is
# the container name, held to a character class below:
#
#   docker exec '<container>' pg_isready -q -U wiki -d wiki
#   docker exec '<container>' psql -U wiki -d wiki -Atc '<the count query>'
#   docker exec '<container>' pg_dump -U wiki -d wiki -Ft
#
# The count is recorded in the MANIFEST so that --prove has something to
# compare a restore against. It is read before the dump, so a page saved in
# between makes the two differ by one; --prove reports that rather than
# failing on it.
#
# WHY NOTHING IS COPIED ANYWHERE ELSE
#
# The set leaving oracle IS the off-host copy. Copying it back to oracle's
# backups/ would put the backup on the disk it is a backup of. It is not yet
# on the offline medium: scripts/backup-offsite.sh carries the volume, NAS and
# firewall sets, and adding this kind to it is its own change.
#
# --prove
#
# A restore, not a listing. The set is decrypted as a stream into pg_restore
# inside a throwaway Postgres — the image stacks/wiki pins, no network, its
# data on a tmpfs — and the pages and users tables are counted there and set
# against what the MANIFEST recorded. Zero of either fails.
#
# Usage:
#   scripts/backup-wiki.sh                        dump, encrypt, verify, prune
#   scripts/backup-wiki.sh --list                 show the sets that exist here
#   scripts/backup-wiki.sh --verify-only          re-verify the newest set
#   scripts/backup-wiki.sh --verify-only --all    re-verify every retained set
#   scripts/backup-wiki.sh --verify-only --set <STAMP>
#   scripts/backup-wiki.sh --prune                apply retention only
#   scripts/backup-wiki.sh --prove [--set <STAMP>]  restore a set into a scratch Postgres and count it
#   scripts/backup-wiki.sh --self-test            the set, the refusals and the proof, against fixtures
#
# Environment:
#   WIKI_SSH_TARGET        default atropos@10.0.99.30   the host the dump is pulled FROM
#   WIKI_DB_CONTAINER      default wiki-db              the Postgres container there
#   WIKI_KEEP              default 14                   complete sets to retain
#   WIKI_RECIPIENT_STACK   default observability        whose secrets file names the recipients
#   SOPS_AGE_KEY_FILE      default ~/.config/sops/age/keys.txt
#   WIKI_UNSAFE_SELF_TEST  the self-test's, and nobody else's: it lets
#                          WIKI_OUT_DIR, WIKI_RECIPIENTS and WIKI_PROVE_COUNTS
#                          stand in for the host

# shellcheck disable=SC2016
# ^ the self-test hands assert() test expressions as single-quoted strings, on purpose.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# --self-test, before anything reads the host
#
# CI has no age, no key and no oracle, so the fixtures put two stand-ins on
# PATH: a pass-through `age`, backup-library.sh's, and an `ssh` that answers
# the three commands above from a fake dump. Everything else — the guards,
# gzip, verify(), the MANIFEST, retention and the proof's comparison — is the
# real code. What no fixture can cover is the real encryption, the real
# oracle and the real restore; the first real run is where those are proven,
# and stacks/wiki/README.md records it.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  T="$(mktemp -d)"
  trap 'rc=$?; rm -rf "${T}"; exit "${rc}"' EXIT INT TERM
  mkdir -p "${T}/bin" "${T}/dump"
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
  # The last argument is the remote command, as ssh receives it. WIKI_FAKE
  # breaks one part of the far side at a time.
  cat > "${T}/bin/ssh" <<'SHIM'
#!/usr/bin/env bash
cmd="${*: -1}"
[[ ${WIKI_FAKE:-} == unreachable ]] && { echo "ssh: connect to host: No route to host" >&2; exit 255; }
case "${cmd}" in
  *" pg_isready "*) [[ ${WIKI_FAKE:-} == down ]] && exit 2; exit 0 ;;
  *" psql "*)       printf '108|4\n' ;;
  *" pg_dump "*)
    [[ ${WIKI_FAKE:-} == dump ]] && { echo 'pg_dump: error: connection failed' >&2; exit 1; }
    tar -cf - -C "${WIKI_FAKE_DUMP}" toc.dat 3722.dat restore.sql
    ;;
  *) echo "unexpected remote command: ${cmd}" >&2; exit 127 ;;
esac
SHIM
  chmod +x "${T}/bin/age" "${T}/bin/ssh"
  : > "${T}/identity"
  head -c 4096 /dev/urandom > "${T}/dump/toc.dat"
  printf 'COPY public.pages ...\n' > "${T}/dump/3722.dat"
  printf -- '-- restore script\n' > "${T}/dump/restore.sql"

  fail=0
  run() {  # <args...> → OUT, RC
    set +e
    OUT="$(PATH="${T}/bin:${PATH}" WIKI_UNSAFE_SELF_TEST=1 WIKI_FAKE="${FAKE:-}" \
           WIKI_FAKE_DUMP="${T}/dump" WIKI_OUT_DIR="${T}/out" WIKI_KEEP=2 \
           WIKI_RECIPIENTS=age1fixture WIKI_PROVE_COUNTS="${COUNTS:-108|4}" \
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
  sets() { find "${T}/out" -mindepth 1 -maxdepth 1 -type d -name '2*' 2>/dev/null | sort; }

  FAKE=down run
  check "a database that is not up is refused" 1 "is not accepting connections"
  assert "and a refused first run leaves no backups directory for verify-backups to trip on" \
    '[[ ! -e ${T}/out ]]'

  run
  check "a set is written from the dump, with nothing stopped" 0 "nothing on oracle stopped"
  first="$(sets | tail -1)"
  assert "the set is complete: one archive, and the MANIFEST written last" \
    '[[ -f ${first}/MANIFEST && -f ${first}/wiki-db.tar.gz.age && ! -e ${first}/wiki-db.tar.gz.age.part ]]'
  assert "the MANIFEST records what was counted before the dump" \
    'grep -qx "pages	108" "${first}/MANIFEST" && grep -qx "users	4" "${first}/MANIFEST" && grep -qx "mode	online" "${first}/MANIFEST"'
  # shellcheck disable=SC2034  # read by the assert() string below
  listing="$(tar -tzf "${first}/wiki-db.tar.gz.age")"
  assert "the archive is pg_dump's tar, as it came off the far side" \
    '[[ ${listing} == *"toc.dat"* && ${listing} == *"restore.sql"* ]]'

  run --verify-only
  check "--verify-only proves the set it wrote" 0 "toc.dat present"

  sleep 1; FAKE=dump run
  check "a pg_dump that fails fails the run, by name" 1 "pg_dump on oracle failed"
  assert "and leaves no partial archive, and no second MANIFEST" \
    '[[ -z $(find "${T}/out" -name "*.part") && $(find "${T}/out" -name MANIFEST | wc -l) -eq 1 ]]'

  FAKE=unreachable run
  check "an unreachable oracle is refused before a set directory exists" 1 "cannot reach"
  FAKE=down run
  check "a database that is not up is refused before a set directory exists" 1 "is not accepting connections"

  sleep 1; run
  sleep 1; run
  check "a third set prunes to WIKI_KEEP" 0 "pruning $(basename "${first}")"
  assert "the oldest is gone" '[[ ! -e ${first} ]]'
  assert "the incomplete set from the failed dump is reported, never deleted" \
    '[[ ${OUT} == *"incomplete set"* ]]'

  run --prove
  check "--prove: a restore that counts what the MANIFEST recorded passes" 0 "pages=108 users=4"
  COUNTS="109|4" run --prove
  check "--prove: a page saved between count and dump is reported, not failed" 0 "differs from the MANIFEST"
  COUNTS="0|0" run --prove
  check "--prove: a restore with no pages fails" 1 "restored no pages"

  # A crossed mapping: another archive's content under this name must not
  # verify, whatever it is called.
  newest="$(sets | tail -1)"
  mkdir -p "${T}/vault" && head -c 2048 /dev/urandom > "${T}/vault/db.sqlite3" && printf 'y\n' > "${T}/vault/rsa_key.pem"
  tar -czf "${newest}/wiki-db.tar.gz.age" -C "${T}/vault" .
  run --verify-only
  check "an archive that is not the wiki's dump does not verify under its name" 1 "it is not a wiki-db backup"

  exit "${fail}"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The tables, verify(), the set helpers, prune(), take_lock(), the colours and
# die() are backup-volumes.sh's; it returns before its own arguments when
# sourced. Its far-side helpers are not used — see WHY NOTHING IS COPIED.
# shellcheck source=scripts/backup-volumes.sh
source "${REPO_ROOT}/scripts/backup-volumes.sh"

UNSAFE=0
[[ -n ${WIKI_UNSAFE_SELF_TEST:-} ]] && UNSAFE=1

OUT_DIR="${REPO_ROOT}/backups/wiki"
((UNSAFE)) && [[ -n ${WIKI_OUT_DIR:-} ]] && OUT_DIR="${WIKI_OUT_DIR}"

WIKI_SSH_TARGET="${WIKI_SSH_TARGET:-atropos@10.0.99.30}"
WIKI_DB_CONTAINER="${WIKI_DB_CONTAINER:-wiki-db}"
WIKI_KEEP="${WIKI_KEEP:-14}"
WIKI_RECIPIENT_STACK="${WIKI_RECIPIENT_STACK:-observability}"

# Rejected rather than clamped, as backup-nas.sh rejects NAS_KEEP. Fourteen,
# not seven: a set is 5 MB, and a wiki edit that went wrong is the kind of
# thing noticed a week late.
if ! [[ ${WIKI_KEEP} =~ ^[0-9]+$ ]] || ((WIKI_KEEP < 1)); then
  die "WIKI_KEEP must be a positive integer, got '${WIKI_KEEP}'"
fi
KEEP="${WIKI_KEEP}"

# Both reach the far side's shell, so the character classes are the control.
[[ ${WIKI_SSH_TARGET} =~ ^[a-z_][a-z0-9_.-]*@[A-Za-z0-9.-]+$ ]] \
  || die "WIKI_SSH_TARGET must be user@host, got '${WIKI_SSH_TARGET}'"
[[ ${WIKI_DB_CONTAINER} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || die "WIKI_DB_CONTAINER must be a container name, got '${WIKI_DB_CONTAINER}'"
[[ ${WIKI_RECIPIENT_STACK} =~ ^[a-z][a-z0-9-]*$ ]] \
  || die "WIKI_RECIPIENT_STACK must be a stack name, got '${WIKI_RECIPIENT_STACK}'"

VOLUMES=(wiki-db)
ONLY_VOLUMES=()
check_sentinel_table
[[ -n ${SENTINEL[wiki-db]:-} ]] \
  || die "no sentinel for wiki-db in backup-volumes.sh — this script will not write a backup it cannot verify"

# The ssh to oracle. Not remote(): that name is backup-volumes.sh's and means
# the far side of a copy, which this script does not make. stdin closed.
wiki_remote() { "${SSH[@]}" "${WIKI_SSH_TARGET}" "$@" </dev/null; }
DOCKER_EXEC="docker exec '${WIKI_DB_CONTAINER}'"
COUNT_SQL='select (select count(*) from pages), (select count(*) from users)'

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
usage() { sed -n 's|^# \{0,1\}||; /^Usage:/,/^$/p' "$0" | head -10; }

MODE=backup
MODE_SET=""
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
    --prove)       set_mode prove ;;
    --all)         ALL=1 ;;
    --set)
      SET_ARG="${2:-}"
      [[ ${SET_ARG} =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "--set wants a stamp like 20260930T033000Z, got '${SET_ARG}'"
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

case "${MODE}" in
  list)
    list_sets
    exit 0
    ;;
  prune)
    take_lock wait
    prune
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
      verify_set "${t}" wiki-db || failed=1
    done
    ((failed == 0)) || die "verification FAILED"
    exit 0
    ;;
  prove)
    take_lock wait
    if [[ -n ${SET_ARG} ]]; then
      target="${OUT_DIR}/${SET_ARG}"
    else
      target="$(newest_complete)"
    fi
    [[ -n ${target} && -f ${target}/MANIFEST ]] || die "no complete set to prove in ${OUT_DIR}"
    stamp="$(basename "${target}")"
    want_pages="$(manifest_field "${target}" pages)"
    want_users="$(manifest_field "${target}" users)"

    if ((UNSAFE)) && [[ -n ${WIKI_PROVE_COUNTS:-} ]]; then
      # The restore is the one step the fixture cannot run; the decrypt and
      # the stream still are, into the listing that stands in for pg_restore.
      age --decrypt -i "${AGE_IDENTITY}" "${target}/wiki-db.tar.gz.age" | gzip -dc | tar -tf - >/dev/null
      counts="${WIKI_PROVE_COUNTS}"
    else
      need docker
      # The image stacks/wiki pins, never a floating tag: a restore proven
      # into a different Postgres than production runs proves the wrong thing.
      PG_IMAGE="$(COMPOSE_FILE="${REPO_ROOT}/stacks/wiki/compose.yaml" "${REPO_ROOT}/scripts/image-for.sh" db)"
      scratch="wiki-prove-$$"
      trap 'docker rm -f "${scratch}" >/dev/null 2>&1 || true' EXIT
      info "proving ${stamp}: restoring it into a scratch ${PG_IMAGE%%@*}, no network, data on tmpfs"
      docker run -d --rm --name "${scratch}" --network none \
        --tmpfs /var/lib/postgresql/data:size=512m \
        -e POSTGRES_USER=wiki -e POSTGRES_DB=wiki -e POSTGRES_PASSWORD=scratch \
        "${PG_IMAGE}" >/dev/null
      # The entrypoint initialises behind a socket-only server and then
      # restarts, so pg_isready alone can answer too early. Its closing line
      # is the signal that the real server is next.
      for _ in $(seq 60); do
        if docker logs "${scratch}" 2>&1 | grep -q 'PostgreSQL init process complete' \
           && docker exec "${scratch}" pg_isready -q -U wiki -d wiki; then
          break
        fi
        sleep 1
      done
      docker exec "${scratch}" pg_isready -q -U wiki -d wiki \
        || die "the scratch Postgres did not come up in 60 s — docker logs ${scratch}"
      set +e
      age --decrypt -i "${AGE_IDENTITY}" "${target}/wiki-db.tar.gz.age" \
        | gzip -dc \
        | docker exec -i "${scratch}" pg_restore -U wiki -d wiki --no-owner --exit-on-error
      rcs=("${PIPESTATUS[@]}")
      set -e
      ((rcs[0] == 0)) || die "FAILED to decrypt ${stamp}/wiki-db.tar.gz.age"
      ((rcs[1] == 0)) || die "${stamp}/wiki-db.tar.gz.age is not a gzip stream"
      ((rcs[2] == 0)) || die "pg_restore FAILED on ${stamp} — the set does not restore"
      counts="$(docker exec "${scratch}" psql -U wiki -d wiki -Atc "${COUNT_SQL}")"
    fi

    IFS='|' read -r pages users <<<"${counts}"
    [[ ${pages} =~ ^[0-9]+$ && ${users} =~ ^[0-9]+$ ]] || die "the restored database returned '${counts}', not two counts"
    ((pages > 0)) || die "${stamp} restored no pages — that is not the wiki"
    ((users > 0)) || die "${stamp} restored no users — that is not the wiki"
    if [[ ${pages} != "${want_pages}" || ${users} != "${want_users}" ]]; then
      warn "pages=${pages} users=${users} differs from the MANIFEST's ${want_pages:-?}/${want_users:-?} — counted before the dump, so an edit in between explains one"
    fi
    green "${stamp} restores: pages=${pages} users=${users}"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Main path
#
# Everything that can fail is made to fail BEFORE a set directory exists.
# ---------------------------------------------------------------------------
need ssh
need tar
need gzip
need awk
need flock
need numfmt
need sha256sum

if ((UNSAFE)) && [[ -n ${WIKI_RECIPIENTS:-} ]]; then
  IFS=, read -r -a AGE_RECIPIENTS <<<"${WIKI_RECIPIENTS}"
else
  # This stack has no secrets file, as stacks/media has none, so the
  # recipients are the observability stack's: the estate's two keys (ADR-0024),
  # the ones that open grafana.db and the NAS sets. Same class of thing.
  mapfile -t AGE_RECIPIENTS < <("${REPO_ROOT}/scripts/key-recipients.sh" --list --stack "${WIKI_RECIPIENT_STACK}")
fi
((${#AGE_RECIPIENTS[@]})) || die "no age recipients from secrets/${WIKI_RECIPIENT_STACK}.sops.yaml — nothing to encrypt to"
AGE_ARGS=()
for r in "${AGE_RECIPIENTS[@]}"; do AGE_ARGS+=(--recipient "${r}"); done
AGE_RECIPIENT="$(IFS=,; printf '%s' "${AGE_RECIPIENTS[*]}")"
unset r

# ssh's own failure is 255; anything else came from docker or pg_isready.
set +e
wiki_remote "${DOCKER_EXEC} pg_isready -q -U wiki -d wiki"
rc=$?
set -e
case "${rc}" in
  0)   ;;
  255) die "cannot reach ${WIKI_SSH_TARGET} non-interactively — oracle is down, this host's key is not in its authorized keys, or its host key is not in ~/.ssh/known_hosts (docs/runbooks/restore-the-stack.md §0)" ;;
  *)   die "${WIKI_DB_CONTAINER} on ${WIKI_SSH_TARGET} is not accepting connections (exit ${rc}) — is the wiki stack up? stacks/wiki/README.md" ;;
esac

counts="$(wiki_remote "${DOCKER_EXEC} psql -U wiki -d wiki -Atc '${COUNT_SQL}'")" \
  || die "cannot count pages and users in ${WIKI_DB_CONTAINER} on ${WIKI_SSH_TARGET}"
IFS='|' read -r pages users <<<"${counts}"
[[ ${pages} =~ ^[0-9]+$ && ${users} =~ ^[0-9]+$ ]] || die "the count on ${WIKI_SSH_TARGET} returned '${counts}', not two numbers"
((pages > 0 && users > 0)) \
  || die "${WIKI_DB_CONTAINER} holds pages=${pages} users=${users} — that is not the wiki, or it has been emptied; refusing to write a set that would prune a good one"

# After the preflight, because take_lock creates OUT_DIR. A refused run must
# leave nothing behind: `make verify-backups` walks backups/wiki/ once it
# exists, and an empty one fails it with "no complete sets" — which is what
# the first primed run did on 2026-09-30, before the stack was cut over.
take_lock

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SET_DIR="${OUT_DIR}/${STAMP}"
mkdir "${SET_DIR}" || die "set ${STAMP} already exists"

started=${SECONDS}
part="${SET_DIR}/wiki-db.tar.gz.age.part"
fail_set() {
  red "$*"
  rm -f "${part}"
  red "the incomplete set is at ${SET_DIR} — no manifest written, nothing pruned"
  exit 1
}

info "dumping ${WIKI_DB_CONTAINER} on ${WIKI_SSH_TARGET} (pages=${pages} users=${users})"
set +e
wiki_remote "${DOCKER_EXEC} pg_dump -U wiki -d wiki -Ft" \
  | gzip -1 \
  | age "${AGE_ARGS[@]}" --output "${part}"
rcs=("${PIPESTATUS[@]}")
set -e
case "${rcs[0]}" in
  0)   ;;
  255) fail_set "ssh to ${WIKI_SSH_TARGET} failed mid-dump" ;;
  *)   fail_set "pg_dump on oracle failed (exit ${rcs[0]}) — see its message above" ;;
esac
((rcs[1] == 0 && rcs[2] == 0)) || fail_set "gzip or age failed writing ${part} (rc ${rcs[1]}, ${rcs[2]})"

# Strict: toc.dat must be present, and no other archive's sentinel may be.
if ! verify "${part}" wiki-db 0; then
  fail_set "the dump did not verify"
fi
bytes="$(stat -c %s "${part}")"
sha="$(sha256sum "${part}" | awk '{print $1}')"
mv "${part}" "${SET_DIR}/wiki-db.tar.gz.age"

# Written last: its presence is what marks the set complete. The shape every
# other set has, so list_sets, prune and verify_set read it unchanged. `online`
# rather than `quiesced`: pg_dump's snapshot is the consistency, not a stop.
{
  printf '# %s set %s\n' "$(basename "$0")" "${STAMP}"
  printf 'stack\t%s\n' wiki
  printf 'project\t%s\n' wiki
  printf 'mode\t%s\n' online
  printf 'source\t%s:%s\n' "${WIKI_SSH_TARGET}" "${WIKI_DB_CONTAINER}"
  printf 'format\t%s\n' pg_dump-tar
  printf 'pages\t%s\n' "${pages}"
  printf 'users\t%s\n' "${users}"
  printf 'recipient\t%s\n' "${AGE_RECIPIENT}"
  printf 'archiver\t%s\n' ssh-pg_dump
  printf 'downtime\t0\n'
  printf '#volume\tservice\tmount\tbytes\tsha256\n'
  printf '%s\t%s\t%s\t%s\t%s\n' wiki-db db /var/lib/postgresql/data "${bytes}" "${sha}"
} > "${SET_DIR}/MANIFEST"

prune

printf '\n'
green "wrote ${SET_DIR#"${REPO_ROOT}"/} — $(human "${bytes}"), nothing on oracle stopped, $((SECONDS - started))s"
info "Proving it restores: make backup-wiki ARGS=--prove"
info "Restoring it: stacks/wiki/README.md § Restore."
