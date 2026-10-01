#!/usr/bin/env bash
#
# Carry the household's photographs and documents onto the drive the holder
# keeps at their own address, prove what landed, and leave them the means to
# open it without anyone from here.
#
# WHAT THIS IS
#
# ADR-0023's off-estate copy, as ADR-0073 decides it. Immich and Paperless-ngx
# are Durable: an off-estate copy has to exist, its staleness has to be
# visible, and it has to open with a key the operator does not solely hold.
# This script writes that copy. It runs on trinity, where the sets are, onto
# the WD Elements mounted at DEST. Like backup-offsite.sh, it is a job with a
# deadline and no timer, because no timer can mount a drive that lives at
# someone else's address. A successful copy of record is the household-copy
# job, and HouseholdCopyStale fires ninety days after the last one.
#
# WHAT LANDS ON THE DRIVE
#
#   household/immich-library/<STAMP>/       the newest library set backup-library.sh made
#   household/paperless-documents/<STAMP>/  a Paperless export made by this run
#   tools/age-v*-<os>-<arch>.{zip,tar.gz}   age for Windows, macOS and Linux, hash-checked
#   PROOF/proof.txt.age, PROOF/ID           a code only the household key opens
#   HOW-TO-OPEN.txt                         docs/runbooks/open-the-household-copy.md, verbatim
#
# The sets are the estate's standard ones, already encrypted where they were
# made to the sensitive rule's recipients and to
# stacks/sensitive/household.recipients. Nothing here re-encrypts the library
# or reads a key to do it. A library set made before a household key was added
# cannot be opened by that key however well it hashes, so it is refused by
# name, the way backup-offsite.sh refuses a set its medium's key cannot open.
#
# Paperless is the exception, because nothing else makes its export. Each run
# runs document_exporter into stacks/sensitive/export/ (gitignored, and kept in
# sync with -d so the next run is incremental), then archives, encrypts and
# verifies it into backups/paperless-documents/<STAMP>/ as a standard set. That
# is the original files plus manifest.json, which a holder can browse as files
# and which re-imports into the same Paperless version. The volume set cannot
# go: it carries the vault beside the documents.
#
# NO HOLDER, NO COPY OF RECORD
#
# Until stacks/sensitive/household.recipients has a `household` key, the copy
# of record is refused. A success recorded with only the technical second's key
# would buy ninety days of silence for a copy that fails ADR-0023's first
# condition. --rehearse writes the same copy without recording anything and
# marks the drive REHEARSAL-NOT-THE-HOUSEHOLD-COPY.txt. With
# --proof-recipient, the rehearsal's PROOF opens with a throwaway key made on
# the machine that will rehearse the holder's side.
#
# THE PROOF
#
# ADR-0023's second condition: the copy is opened once from the other
# person's device, signed into their own account, without the operator
# present. Nothing here can watch that happen, but it can make it
# checkable. A copy of record writes a random code into PROOF/proof.txt.age,
# encrypted to the household keys ONLY: not trinity's, not the technical
# second's. Trinity keeps the code's sha256 and never the code. The holder
# opens it on their own device and reads the code back over the phone, and
# `make household-proof CODE=…` records the household-proof job. The code
# stays the same across visits until it is proved, then the next copy of
# record replaces it.
#
# Usage:
#   scripts/carry-household-copy.sh <DEST>                    the copy of record: make household-copy DEST=…
#   scripts/carry-household-copy.sh <DEST> --rehearse [--proof-recipient <age1…>]
#   scripts/carry-household-copy.sh <DEST> --list             what is here and what is on the drive
#   scripts/carry-household-copy.sh <DEST> --verify-only      re-hash everything on the drive
#   scripts/carry-household-copy.sh <DEST> --prune            retention and leftovers only
#   scripts/carry-household-copy.sh --check-code <code>       does this code match the open challenge
#   scripts/carry-household-copy.sh --prove-code <code>       the same, and mark it proved: make household-proof
#   scripts/carry-household-copy.sh --self-test
#
# Environment:
#   HOUSEHOLD_KEEP        default 1     complete sets of each kind kept on the drive
#   SOPS_AGE_KEY_FILE     default ~/.config/sops/age/keys.txt   verifies the Paperless set
#   HOUSEHOLD_UNSAFE_SELF_TEST   the self-test's, and nobody else's: it lifts
#                         the medium checks and lets HOUSEHOLD_SOURCE,
#                         HOUSEHOLD_RECIPIENTS_FILE, HOUSEHOLD_SENSITIVE_RECIPIENTS
#                         and HOUSEHOLD_EXPORT_DIR stand in for the host

# shellcheck disable=SC2016
# ^ the self-test hands assert() test expressions as single-quoted strings, on purpose.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# --self-test, before anything reads the host
#
# CI has no age binary and no key, so the fixtures put a pass-through `age` on
# PATH that also logs every recipient it was handed. That is how the proof's
# keys are asserted: the shim cannot show that only the household key opens
# PROOF, but it can show which keys it was encrypted to. Everything else —
# the refusals, the holder guard, fitness, the copy and its proof, retention,
# the tools and the code — is the real code.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  mkdir -p "${T}/bin"
  cat > "${T}/bin/age" <<'SHIM'
#!/usr/bin/env bash
# Self-test stand-in for age: no encryption, the same argv shape, recipients
# logged one call per block, each block opened by a "--" line.
printf -- '--\n' >> "${AGE_SHIM_LOG:-/dev/null}"
out="" dec=0 last=""
while (($#)); do
  case "$1" in
    -d|--decrypt) dec=1 ;;
    -i|--identity) shift ;;
    -r|--recipient) printf '%s\n' "$2" >> "${AGE_SHIM_LOG:-/dev/null}"; shift ;;
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

  # Real recipients, made with age-keygen for this test; public halves only.
  KH=age1mt2p3n6xqzevjyqq7qpxhwc3zk6wlc3qace6rj5qfhhkzhl3gyqsq5r349   # the household holder
  KS=age1vfe5xddxdzh5ggqmhhte0l78s2ktvmuzyjrfpjsemuez5q9z8u2q9cdlwz   # the technical second
  KT=age1zkk7g3ufhfs5e78mkn80q3wawj8497y4d9lcffvjndw6fjepy4mq0ccxds   # trinity
  KR=age1x9dgekxhr2y9sxsfvth4dmm3l0pv2l2hdhc7w7dkf3gpflvlmarq3z5qe5   # a rehearsal's throwaway
  # The recipients of the newest age call the shim saw, one per line.
  # shellcheck disable=SC2329  # called from assert()'s eval strings
  last_call() { awk '/^--$/ { n = 0; delete k; next } { k[++n] = $0 } END { for (i = 1; i <= n; i++) print k[i] }' "${T}/recipients.log"; }
  printf '# role: household\n%s\n# role: technical-second\n%s\n' "${KH}" "${KS}" > "${T}/both"
  printf '# role: technical-second\n%s\n' "${KS}" > "${T}/second"

  # The repository the script reads, in miniature: a library set, a Paperless
  # export, the runbook and the tools.
  R="${T}/repo"
  mkdir -p "${R}/backups/immich-library" "${R}/backups/household/tools" "${T}/export"
  mklibset() {  # <stamp> <recipients, comma-joined>
    local d="${R}/backups/immich-library/$1" sha bytes
    mkdir -p "${T}/lib/library" && printf 'immich\n' > "${T}/lib/library/.immich" && printf 'photo-%s\n' "$1" > "${T}/lib/library/a.jpg"
    mkdir -p "${d}"
    tar -C "${T}/lib" -czf "${d}/immich-library.tar.gz.age" .
    sha="$(sha256sum "${d}/immich-library.tar.gz.age" | cut -d' ' -f1)"
    bytes="$(stat -c %s "${d}/immich-library.tar.gz.age")"
    printf '# fixture set %s\nrecipient\t%s\n#volume\tservice\tmount\tbytes\tsha256\nimmich-library\timmich-server\t/data\t%s\t%s\n' \
      "$1" "$2" "${bytes}" "${sha}" > "${d}/MANIFEST"
  }
  mklibset 20260929T051500Z "${KT},${KS}"
  printf '[]\n' > "${T}/export/manifest.json"
  printf '{"version": "3.2.1"}\n' > "${T}/export/metadata.json"
  head -c 4096 /dev/urandom > "${T}/export/0000001.pdf"
  mkdir -p "${R}/docs/runbooks" "${R}/stacks/sensitive"
  printf 'How to open it.\n' > "${R}/docs/runbooks/open-the-household-copy.md"
  printf 'age-for-windows\n' > "${R}/backups/household/tools/age-v0-windows-amd64.zip"
  printf '%s  age-v0-windows-amd64.zip\n' "$(sha256sum "${R}/backups/household/tools/age-v0-windows-amd64.zip" | cut -d' ' -f1)" \
    > "${R}/stacks/sensitive/household-age.sha256"
  M="${T}/medium"; mkdir -p "${M}"

  fail=0
  run() {  # <args...> → OUT, RC
    set +e
    OUT="$(PATH="${T}/bin:${PATH}" HOUSEHOLD_UNSAFE_SELF_TEST="${UNSAFE-1}" HOUSEHOLD_REPO="${R}" \
           HOUSEHOLD_RECIPIENTS_FILE="${RECIPIENTS_FOR_TEST:-${T}/both}" HOUSEHOLD_SENSITIVE_RECIPIENTS="${KT}" \
           HOUSEHOLD_EXPORT_DIR="${T}/export" HOMELAB_LOCK_DIR="${T}" AGE_SHIM_LOG="${T}/recipients.log" \
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

  # The refusals, with the medium checks ON.
  run;                                check "no DEST is a usage error" 2 "usage"
  run "${R}";                         check "a DEST inside the repository is refused" 1 "inside this repository"
  UNSAFE="" run "${T}/medium";        check "a DEST under /tmp, or in RAM, is refused outside the self-test" 1 "the destination is"

  # No holder.
  RECIPIENTS_FOR_TEST="${T}/second" run "${M}"
  check "no household key: the copy of record is refused" 1 "no household holder"
  assert "and nothing was written to the drive" '[[ -z $(ls -A "${M}") ]]'

  # A library set the household key cannot open.
  run "${M}"
  check "a library set made before the household key was added is refused by name" 1 "20260929T051500Z is not encrypted to ${KH}"
  assert "and nothing reached the drive" '[[ ! -e "${M}/household/immich-library" ]]'

  # The rehearsal: no holder needed, nothing recorded, the drive marked.
  : > "${T}/recipients.log"
  RECIPIENTS_FOR_TEST="${T}/second" run "${M}" --rehearse --proof-recipient "${KR}"
  check "--rehearse needs no holder" 0 "REHEARSAL"
  assert "the rehearsal marks the drive" '[[ -f "${M}/REHEARSAL-NOT-THE-HOUSEHOLD-COPY.txt" ]]'
  assert "the rehearsal's PROOF is encrypted to the throwaway key alone" '[[ $(last_call) == "${KR}" ]]'

  # A fit library set, and the copy of record.
  sleep 1; mklibset 20260930T051500Z "${KT},${KS},${KH}"
  : > "${T}/recipients.log"
  run "${M}"
  check "the copy of record lands and is proved" 0 "the drive holds the household's copy"
  assert "the library set and a Paperless set are on the drive, complete" \
    '[[ -f "${M}/household/immich-library/20260930T051500Z/MANIFEST" && $(find "${M}/household/paperless-documents" -mindepth 2 -name MANIFEST | wc -l) -eq 1 ]]'
  assert "the Paperless set is encrypted to the tier and the household both" \
    'grep -q "^recipient	${KT},${KH},${KS}$" "$(find "${M}/household/paperless-documents" -mindepth 2 -name MANIFEST)"'
  assert "the Paperless set holds the export" \
    'tar -tzf "$(find "${M}/household/paperless-documents" -name "*.tar.gz.age")" | grep -qx "./0000001.pdf"'
  assert "the proof is encrypted to the household key and nothing else" '[[ $(last_call) == "${KH}" ]]'
  assert "the rehearsal marker is gone" '[[ ! -e "${M}/REHEARSAL-NOT-THE-HOUSEHOLD-COPY.txt" ]]'
  assert "the holder's instructions and the tools travelled" \
    'cmp -s "${M}/HOW-TO-OPEN.txt" "${R}/docs/runbooks/open-the-household-copy.md" && [[ -f "${M}/tools/age-v0-windows-amd64.zip" ]]'
  assert "the code is not stored on trinity, only its hash" \
    'code="$(cat "${M}/PROOF/proof.txt.age" | grep -oE "[0-9]{4}-[0-9]{4}-[0-9]{4}")" && ! grep -rq "${code}" "${R}/backups/household"'

  code="$(grep -oE '[0-9]{4}-[0-9]{4}-[0-9]{4}' "${M}/PROOF/proof.txt.age")"
  run --check-code "1111-2222-3333"; check "a wrong code does not match" 1 "does not match"
  run --check-code "${code}";        check "the right code matches" 0 "matches"
  run --check-code "${code//-/ }";   check "spaces instead of dashes still match" 0 "matches"
  sleep 1; run "${M}";               check "a second visit keeps the unproved challenge" 0 "the drive holds the household's copy"
  assert "the code on the drive did not change" 'grep -q "${code}" "${M}/PROOF/proof.txt.age"'
  run --prove-code "${code}";        check "--prove-code marks it proved" 0 "proved"
  run --check-code "${code}";        check "a proved code is not open any more" 1 "no open challenge"
  sleep 1; run "${M}";               check "the next visit after a proof" 0 "new proof challenge"
  assert "replaced the code" '! grep -q "${code}" "${M}/PROOF/proof.txt.age"'

  run "${M}" --verify-only;          check "--verify-only proves what the drive holds" 0 "every set on the drive verifies"
  lib="${M}/household/immich-library/20260930T051500Z/immich-library.tar.gz.age"
  printf 'x' | dd of="${lib}" bs=1 seek=10 conv=notrunc 2>/dev/null
  run "${M}" --verify-only;          check "a changed byte on the drive fails the verify" 1 "differs from its MANIFEST"
  run "${M}";                        check "and the copy refuses to write over it" 1 "differs from its MANIFEST"
  assert "nothing was deleted" '[[ -f ${lib} ]]'
  rm -rf "${M}/household/immich-library/20260930T051500Z"

  printf 'not-age\n' > "${R}/backups/household/tools/age-v0-windows-amd64.zip"
  run "${M}";                        check "a tool that is not the pinned build is refused" 1 "does not match"
  printf 'age-for-windows\n' > "${R}/backups/household/tools/age-v0-windows-amd64.zip"

  mkdir -p "${M}/household/immich-library/20260101T000000Z.part" "${M}/household/immich-library/not-a-stamp"
  sleep 1; run "${M}"
  check "a run after the bad set was removed copies it again" 0 "copied 20260930T051500Z"
  assert "the dead copy's .part is swept and the stray is left" \
    '[[ ! -e "${M}/household/immich-library/20260101T000000Z.part" && -d "${M}/household/immich-library/not-a-stamp" ]]'
  assert "HOUSEHOLD_KEEP=1 holds one Paperless set on the drive" \
    '[[ $(find "${M}/household/paperless-documents" -mindepth 2 -name MANIFEST | wc -l) -eq 1 ]]'

  printf 'age1notakey\n' > "${T}/bad"
  RECIPIENTS_FOR_TEST="${T}/bad" run "${M}"
  check "a recipients file that does not parse stops the run" 1 "is not an age recipient"

  exit "${fail}"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
UNSAFE=0
[[ -n ${HOUSEHOLD_UNSAFE_SELF_TEST:-} ]] && UNSAFE=1
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set before the source line: backup-volumes.sh validates VOL_OFFHOST as it
# loads. Nothing here contacts it.
STACK=sensitive
VOL_OFFHOST="atropos@10.0.99.30:backups/volumes/sensitive"
# shellcheck source=scripts/backup-volumes.sh
source "${SCRIPTS}/backup-volumes.sh"
# shellcheck source=scripts/medium.sh
source "${SCRIPTS}/medium.sh"
# After the sources: backup-volumes.sh sets REPO_ROOT as it loads.
((UNSAFE)) && [[ -n ${HOUSEHOLD_REPO:-} ]] && REPO_ROOT="${HOUSEHOLD_REPO}"

HOUSEHOLD_KEEP="${HOUSEHOLD_KEEP:-1}"
if ! [[ ${HOUSEHOLD_KEEP} =~ ^[0-9]+$ ]] || ((HOUSEHOLD_KEEP < 1)); then
  die "HOUSEHOLD_KEEP must be a positive integer, got '${HOUSEHOLD_KEEP}'"
fi

RECIPIENTS_FILE="${REPO_ROOT}/stacks/sensitive/household.recipients"
((UNSAFE)) && [[ -n ${HOUSEHOLD_RECIPIENTS_FILE:-} ]] && RECIPIENTS_FILE="${HOUSEHOLD_RECIPIENTS_FILE}"
EXPORT_DIR="${REPO_ROOT}/stacks/sensitive/export"
((UNSAFE)) && [[ -n ${HOUSEHOLD_EXPORT_DIR:-} ]] && EXPORT_DIR="${HOUSEHOLD_EXPORT_DIR}"
LIB_SRC="${REPO_ROOT}/backups/immich-library"
DOC_OUT="${REPO_ROOT}/backups/paperless-documents"
STATE_DIR="${REPO_ROOT}/backups/household"
TOOLS_SRC="${STATE_DIR}/tools"
TOOLS_SHA="${REPO_ROOT}/stacks/sensitive/household-age.sha256"
RUNBOOK="${REPO_ROOT}/docs/runbooks/open-the-household-copy.md"
PROOF_STATE="${STATE_DIR}/proof"
PAPERLESS_CONTAINER=sensitive-paperless

hh() { "${SCRIPTS}/household-recipients.sh" --file "${RECIPIENTS_FILE}" "$@"; }

# ---------------------------------------------------------------------------
# The proof's codes. Twelve digits in three groups, read over a phone. Only the
# sha256 of the digits is kept, in PROOF_STATE: "<id>\t<sha256>\t<pending|proved>".
# ---------------------------------------------------------------------------
norm_code() { tr -cd '0-9' <<<"$1"; }
code_sha()  { printf '%s' "$(norm_code "$1")" | sha256sum | cut -d' ' -f1; }
new_code()  { od -An -N12 -tu1 /dev/urandom | awk '{ for (i = 1; i <= NF; i++) printf "%d", $i % 10 }' | sed -E 's/^(....)(....)(....)$/\1-\2-\3/'; }
proof_field() { [[ -r ${PROOF_STATE} ]] && awk -F'\t' -v n="$1" 'NR == 1 { print $n }' "${PROOF_STATE}"; }

if [[ ${1:-} == --check-code || ${1:-} == --prove-code ]]; then
  mode="$1" given="${2:-}"
  [[ -n ${given} ]] || die "${mode} needs the code the holder read out"
  [[ $(norm_code "${given}") =~ ^[0-9]{12}$ ]] || die "a code is twelve digits, got '${given}'"
  [[ $(proof_field 3 || true) == pending ]] \
    || die "no open challenge on trinity — the last code was proved, or no copy of record has written one yet"
  if [[ $(code_sha "${given}") != "$(proof_field 2)" ]]; then
    die "the code does not match the open challenge ($(proof_field 1)). Read it again from PROOF/proof.txt.age on the holder's device"
  fi
  if [[ ${mode} == --check-code ]]; then
    green "the code matches the open challenge $(proof_field 1)"
    exit 0
  fi
  printf '%s\t%s\tproved\t%s\n' "$(proof_field 1)" "$(proof_field 2)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${PROOF_STATE}.new"
  mv "${PROOF_STATE}.new" "${PROOF_STATE}"
  green "proved: the holder opened challenge $(proof_field 1) on their own device. ADR-0023's second condition holds as of today; record it in the changelog"
  exit 0
fi

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
usage() { sed -n 's|^# \{0,1\}||; /^Usage:/,/^$/p' "${BASH_SOURCE[0]}" | head -12; }
MODE=copy
DEST=""
PROOF_RECIPIENT=""
while (($#)); do
  case "$1" in
    --rehearse)        MODE=rehearse ;;
    --proof-recipient) PROOF_RECIPIENT="${2:-}"; shift ;;
    --list)            MODE=list ;;
    --verify-only)     MODE=verify ;;
    --prune)           MODE=prune ;;
    -h|--help)         usage; exit 0 ;;
    --*)               usage >&2; die "unknown argument: $1" ;;
    *)                 [[ -z ${DEST} ]] || die "one DEST only, got '${DEST}' and '$1'"; DEST="$1" ;;
  esac
  shift
done
if [[ -z ${DEST} ]]; then
  usage >&2
  printf '\nusage: mount the drive, then:  make household-copy DEST=/path/to/the/drive\n' >&2
  exit 2
fi
[[ -z ${PROOF_RECIPIENT} || ${MODE} == rehearse ]] || die "--proof-recipient is for --rehearse only; a copy of record proves the household's own key"
[[ -z ${PROOF_RECIPIENT} || ${PROOF_RECIPIENT} =~ ^age1[02-9ac-hj-np-z]{58}$ ]] || die "--proof-recipient '${PROOF_RECIPIENT}' is not an age recipient"

need sha256sum
need cmp
need df
need age

[[ -d ${DEST} ]] || die "no such directory: ${DEST}
Mount the drive first. The path is a directory on it, not a device."
DEST_ABS="$(cd "${DEST}" && pwd -P)"
medium_refuse "${DEST_ABS}" "${REPO_ROOT}/backups" "${UNSAFE}" HouseholdCopyStale \
  docs/runbooks/carry-the-household-copy.md "the household's drive (ADR-0073)"

LIB_DST="${DEST_ABS}/household/immich-library"
DOC_DST="${DEST_ABS}/household/paperless-documents"
REHEARSAL_MARK="${DEST_ABS}/REHEARSAL-NOT-THE-HOUSEHOLD-COPY.txt"

# Who must be able to open what travels: every key in the household file.
WANT="$(hh --list)" || exit 1

# A sentence naming why a set cannot travel, or nothing.
unfit() {  # <set dir>
  local have missing
  have="$(manifest_field "$1" recipient | tr ',' '\n')"
  if [[ -z ${have//[[:space:]]/} ]]; then
    printf '%s records no recipients, so which keys open it is unknown\n' "$(basename "$1")"
    return
  fi
  missing="$(cannot_open "${have}" "${WANT}")"
  [[ -z ${missing} ]] || printf '%s is not encrypted to %s, so that key cannot open it\n' \
    "$(basename "$1")" "$(paste -sd, <<<"${missing}")"
}

# Every complete set on the drive hashes to its MANIFEST, and every tool to
# its pinned line. 2 means there was nothing to check.
verify_drive() {
  local d n=0 failed=0 name want
  while read -r d; do
    [[ -n ${d} ]] || continue
    verify_set_dir "${d}" || failed=1
    n=$((n + 1))
  done < <(sets_in "${LIB_DST}"; sets_in "${DOC_DST}")
  while read -r want name; do
    [[ -f ${DEST_ABS}/tools/${name} ]] || continue
    if [[ $(sha256sum -- "${DEST_ABS}/tools/${name}" | cut -d' ' -f1) != "${want}" ]]; then
      red "${DEST_ABS}/tools/${name} does not match its pinned sha256 in stacks/sensitive/household-age.sha256"
      failed=1
    fi
  done < <(pinned_tools)
  ((failed)) && return 1
  ((n)) || return 2
  green "every set on the drive verifies — ${n} set(s), each archive hashes to its MANIFEST entry"
}

pinned_tools() { [[ -r ${TOOLS_SHA} ]] && awk '!/^#/ && NF == 2 { print $1, $2 }' "${TOOLS_SHA}"; }

take_backups_lock() {
  local lock_file="${HOMELAB_LOCK_DIR:-/run/lock}/homelab-backups.lock"
  exec 8>"${lock_file}" || die "cannot open ${lock_file}"
  flock -w 900 8 || die "another job holds the backups lock (${lock_file}) — a backup is running; waiting longer than 900s for it"
}

# ---------------------------------------------------------------------------
# --list, --verify-only, --prune
# ---------------------------------------------------------------------------
case "${MODE}" in
  list)
    hh --check
    printf '\nhere:\n'
    printf '  library:   %s\n' "$(sets_in "${LIB_SRC}" | head -1 | xargs -r basename || true)"
    printf '  documents: %s\n' "$(sets_in "${DOC_OUT}" | head -1 | xargs -r basename || true)"
    printf '  proof:     %s\n' "$(cut -f1,3,4 "${PROOF_STATE}" 2>/dev/null | tr '\t' ' ' || printf 'none written')"
    printf 'on the drive:\n'
    printf '  library:   %s\n' "$(sets_in "${LIB_DST}" | xargs -r -n1 basename | paste -sd' ' || true)"
    printf '  documents: %s\n' "$(sets_in "${DOC_DST}" | xargs -r -n1 basename | paste -sd' ' || true)"
    [[ -e ${REHEARSAL_MARK} ]] && printf '  a REHEARSAL, not the household copy\n'
    exit 0
    ;;
  verify)
    rc=0; verify_drive || rc=$?
    ((rc == 2)) && die "nothing to verify on ${DEST_ABS} — no complete set; an empty drive is not a proof"
    exit "${rc}"
    ;;
  prune)
    take_backups_lock
    sweep_set_parts "${LIB_DST}" "${DOC_DST}"
    prune_sets "${LIB_DST}" "${HOUSEHOLD_KEEP}"
    prune_sets "${DOC_DST}" "${HOUSEHOLD_KEEP}"
    green "pruned ${DEST_ABS} to ${HOUSEHOLD_KEEP} set(s) of each kind"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# The copy: of record, or a rehearsal
# ---------------------------------------------------------------------------
# The rehearsal runs unwrapped, so it takes the lock a copy of record runs
# under itself; the copy of record already holds it through run-scheduled.sh.
[[ ${MODE} == rehearse ]] && take_backups_lock

HOLDERS="$(hh --list --role household)" || exit 1
if [[ ${MODE} == copy && -z ${HOLDERS} ]]; then
  die "no household holder in ${RECIPIENTS_FILE#"${REPO_ROOT}"/} — the copy of record needs a key the operator does not solely hold (ADR-0023, ADR-0073).
Rehearse instead:  make household-copy DEST=${DEST} ARGS=--rehearse"
fi

# 1. What is already on the drive is still what was written.
rc=0; verify_drive || rc=$?
((rc == 1)) && die "the drive does not verify — nothing written. Remove what differs, then run again: docs/runbooks/carry-the-household-copy.md"

# 2. The newest library set, and it must open with every household key.
lib_set="$(sets_in "${LIB_SRC}" | head -1 || true)"
[[ -n ${lib_set} ]] || die "no complete library set under ${LIB_SRC} — run make backup-library first"
why="$(unfit "${lib_set}")"
[[ -z ${why} ]] || die "${why}. Make a set now that it is in the recipients file: make backup-library"

# 3. The tools are the pinned builds, before anything is written.
mapfile -t tools < <(pinned_tools)
((${#tools[@]})) || die "no pinned tools in ${TOOLS_SHA}"
for line in "${tools[@]}"; do
  read -r want name <<<"${line}"
  if [[ ! -f ${TOOLS_SRC}/${name} ]]; then
    [[ ${MODE} == rehearse ]] && { warn "${name} is not in ${TOOLS_SRC} — the rehearsal goes without it"; continue; }
    die "${name} is not in ${TOOLS_SRC} — download it once: docs/runbooks/carry-the-household-copy.md §1"
  fi
  [[ $(sha256sum -- "${TOOLS_SRC}/${name}" | cut -d' ' -f1) == "${want}" ]] \
    || die "${TOOLS_SRC}/${name} does not match its pinned sha256 — not the build stacks/sensitive/household-age.sha256 names; delete it and download it again"
done

# 4. The Paperless set: export, archive, encrypt, verify, MANIFEST last.
mapfile -t TIER < <(
  if ((UNSAFE)) && [[ -n ${HOUSEHOLD_SENSITIVE_RECIPIENTS:-} ]]; then tr ',' '\n' <<<"${HOUSEHOLD_SENSITIVE_RECIPIENTS}"
  else "${SCRIPTS}/key-recipients.sh" --list --stack sensitive; fi)
((${#TIER[@]})) || die "no age recipients from secrets/sensitive.sops.yaml"
RECIPS=("${TIER[@]}")
while IFS= read -r r; do
  [[ -n ${r} && " ${RECIPS[*]} " != *" ${r} "* ]] && RECIPS+=("${r}")
done <<<"${WANT}"
AGE_ARGS=()
for r in "${RECIPS[@]}"; do AGE_ARGS+=(--recipient "${r}"); done

if ! ((UNSAFE)) || [[ -z ${HOUSEHOLD_EXPORT_DIR:-} ]]; then
  docker inspect -f '{{.State.Running}}' "${PAPERLESS_CONTAINER}" 2>/dev/null | grep -qx true \
    || die "${PAPERLESS_CONTAINER} is not running — the export needs it; nothing written"
  info "exporting Paperless-ngx into ${EXPORT_DIR#"${REPO_ROOT}"/}"
  docker exec "${PAPERLESS_CONTAINER}" document_exporter ../export --no-progress-bar -d -nt -c \
    || die "document_exporter failed — nothing written"
fi
[[ -f ${EXPORT_DIR}/manifest.json ]] || die "no manifest.json in ${EXPORT_DIR} — that is not a Paperless export"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
doc_set="${DOC_OUT}/${STAMP}"
mkdir -p "${DOC_OUT}"
mkdir "${doc_set}" || die "set ${STAMP} already exists"
part="${doc_set}/paperless-documents.tar.gz.age.part"
tar --numeric-owner -C "${EXPORT_DIR}" -cf - . | gzip | age "${AGE_ARGS[@]}" --output "${part}" \
  || die "tar, gzip or age failed writing ${part} — the incomplete set is at ${doc_set}"
verify "${part}" paperless-documents 0 || die "the Paperless archive did not verify — the incomplete set is at ${doc_set}"
bytes="$(stat -c %s "${part}")"
sha="$(sha256sum "${part}" | cut -d' ' -f1)"
mv "${part}" "${doc_set}/paperless-documents.tar.gz.age"
{
  printf '# %s set %s\n' "$(basename "$0")" "${STAMP}"
  printf 'stack\tsensitive\nproject\tsensitive\nmode\tlive\n'
  printf 'source\t%s\n' "${EXPORT_DIR}"
  printf 'recipient\t%s\n' "$(IFS=,; printf '%s' "${RECIPS[*]}")"
  printf 'archiver\thost-tar\n'
  printf 'documents\t%s\n' "$(find "${EXPORT_DIR}" -type f ! -name '*.json' | wc -l)"
  printf '#volume\tservice\tmount\tbytes\tsha256\n'
  printf '%s\t%s\t%s\t%s\t%s\n' paperless-documents paperless /usr/src/paperless/export "${bytes}" "${sha}"
} > "${doc_set}/MANIFEST"
prune_sets "${DOC_OUT}" 1

# 5. Room: the new sets land before the old are pruned, so the drive needs
#    room for both. A library past roughly 2.4 TB no longer fits twice on 5 TB.
need_bytes=0
todo=()
for s in "${lib_set}" "${doc_set}"; do
  kind="$(manifest_volumes "${s}" | head -1)"
  [[ -f ${DEST_ABS}/household/${kind}/$(basename "${s}")/MANIFEST ]] && continue
  todo+=("${s}")
  need_bytes=$((need_bytes + $(manifest_bytes "${s}")))
done
avail_bytes=$(($(df --output=avail -k "${DEST_ABS}" | tail -1 | tr -d ' ') * 1024))
if ((need_bytes + need_bytes / 50 > avail_bytes)); then
  die "the drive has $(human "${avail_bytes}") free and this visit needs $(human "${need_bytes}") before the old sets are pruned. Prune first (ARGS=--prune), or the library has outgrown a 5 TB drive (ADR-0073's ceiling); nothing written"
fi

# 6. Copy, then the rest of what the holder needs.
failed=0
for s in "${todo[@]}"; do
  kind="$(manifest_volumes "${s}" | head -1)"
  mkdir -p -- "${DEST_ABS}/household/${kind}"
  copy_set "${s}" "${DEST_ABS}/household/${kind}" || failed=1
done
((failed)) && die "the copy did not complete — the drive may hold a .part; the next run removes it and copies again"
for s in "${lib_set}" "${doc_set}"; do
  kind="$(manifest_volumes "${s}" | head -1)"
  [[ " ${todo[*]} " == *" ${s} "* ]] || info "the drive already holds ${kind} $(basename "${s}")"
done

mkdir -p -- "${DEST_ABS}/tools"
for line in "${tools[@]}"; do
  read -r want name <<<"${line}"
  [[ -f ${TOOLS_SRC}/${name} ]] || continue
  cmp -s -- "${TOOLS_SRC}/${name}" "${DEST_ABS}/tools/${name}" 2>/dev/null && continue
  cp -- "${TOOLS_SRC}/${name}" "${DEST_ABS}/tools/${name}.part"
  mv -- "${DEST_ABS}/tools/${name}.part" "${DEST_ABS}/tools/${name}"
done
cp -- "${RUNBOOK}" "${DEST_ABS}/HOW-TO-OPEN.txt"
cmp -s -- "${RUNBOOK}" "${DEST_ABS}/HOW-TO-OPEN.txt" || die "HOW-TO-OPEN.txt on the drive is not the runbook"

# 7. The proof challenge.
write_proof() {  # <code> <id> <recipient...>
  local code="$1" id="$2"; shift 2
  local -a args=()
  for r in "$@"; do args+=(--recipient "${r}"); done
  mkdir -p -- "${DEST_ABS}/PROOF"
  printf 'The code is:  %s\n\nRead it to the person who asked you to open this.\n' "${code}" \
    | age "${args[@]}" --output "${DEST_ABS}/PROOF/proof.txt.age.part"
  printf '%s\n' "${id}" > "${DEST_ABS}/PROOF/ID"
  mv -- "${DEST_ABS}/PROOF/proof.txt.age.part" "${DEST_ABS}/PROOF/proof.txt.age"
}
if [[ ${MODE} == rehearse ]]; then
  if [[ -n ${PROOF_RECIPIENT} ]]; then
    write_proof "$(new_code)" "rehearsal-${STAMP}" "${PROOF_RECIPIENT}"
    info "PROOF/ opens with the rehearsal key only; its code proves the rehearsal, not the holder"
  fi
  printf 'This drive holds a REHEARSAL of the household copy, written %s.\nIt is not the copy ADR-0023 asks for until a copy of record replaces this file.\n' "${STAMP}" > "${REHEARSAL_MARK}"
else
  open_id="$(proof_field 1 || true)"
  if [[ $(proof_field 3 || true) == pending && -f ${DEST_ABS}/PROOF/proof.txt.age \
        && $(cat "${DEST_ABS}/PROOF/ID" 2>/dev/null) == "${open_id}" ]]; then
    info "the open proof challenge ${open_id} stays on the drive until it is proved"
  else
    mapfile -t holders <<<"${HOLDERS}"
    code="$(new_code)"
    write_proof "${code}" "${STAMP}" "${holders[@]}"
    mkdir -p "${STATE_DIR}"
    printf '%s\t%s\tpending\n' "${STAMP}" "$(code_sha "${code}")" > "${PROOF_STATE}.new"
    mv "${PROOF_STATE}.new" "${PROOF_STATE}"
    unset code
    info "new proof challenge ${STAMP} written to PROOF/, encrypted to the household key only"
  fi
  rm -f -- "${REHEARSAL_MARK}"
fi

sync -f "${DEST_ABS}" 2>/dev/null || sync
sweep_set_parts "${LIB_DST}" "${DOC_DST}"
prune_sets "${LIB_DST}" "${HOUSEHOLD_KEEP}"
prune_sets "${DOC_DST}" "${HOUSEHOLD_KEEP}"

printf '\n'
if [[ ${MODE} == rehearse ]]; then
  green "REHEARSAL written and proved on ${DEST_ABS} — nothing recorded; this is not the household's copy"
else
  green "the drive holds the household's copy, proved: library $(basename "${lib_set}"), documents ${STAMP}. Unmount it and take it to the holder's address"
fi
