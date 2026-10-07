# shellcheck shell=bash
# Its variables are the sourcing suite's to read, so shellcheck sees them unused:
# shellcheck disable=SC2034
#
# The fixture behind `backup-volumes.sh --self-test` and
# `restore-volumes.sh --self-test` (#854). Sourced, never run: it has no
# dispatch of its own, so scripts/self-tests.sh does not count it as a suite.
#
# WHAT IT BUILDS, AND WHY NOTHING IS STUBBED
#
# The two scripts are the path a backup takes and the path taken on the worst
# day. Every other fixture in this repository that touches them puts a
# pass-through `age` on PATH, so the encryption, the recipients and the
# decrypting verify() have only ever been tested by the weekly run itself. This
# runs the real CLIs, with the real age and the real docker, against:
#
#   - a throwaway repository: copies of the scripts the two shell out to, a
#     compose file with one service owning `grafana-data` (a real SENTINEL key,
#     so verify() is the real one) and the archiver image lifted from the real
#     compose file, and a secrets file whose `sops:` block lists two
#     recipients — all key-recipients.sh reads;
#   - three throwaway age identities: K1 and K2 are the recipients, K3 is not;
#   - docker volumes under compose projects named for this process, so nothing
#     an operator runs can collide with them, removed on exit.
#
# The trap is installed by vf_setup and preserves the suite's exit status.
#
# After vf_setup:
#   VF          the scratch directory
#   VF_REPO     the throwaway repository; its scripts/ are what is run
#   VF_K1..3    identity files; VF_R1, VF_R2 the recipients of K1 and K2
#   VF_IMAGE    the archiver image
#   VF_P        the prefix every fixture project name starts with
#   fail        0, set to 1 by any FAIL

VF=""
VF_VOLUMES=()

# vf_setup <real repo root> [extra command needed]...
# Returns 1, having printed a SKIP, when the host cannot run the fixture.
vf_setup() {
  local real="$1" c
  shift
  fail=0
  for c in docker age age-keygen tar sha256sum flock numfmt "$@"; do
    if ! command -v "${c}" >/dev/null 2>&1; then
      printf '\033[0;33m  SKIP\033[0m volume round trip: %s is not installed\n' "${c}"
      return 1
    fi
  done
  if ! docker info >/dev/null 2>&1; then
    printf '\033[0;33m  SKIP\033[0m volume round trip: cannot reach the docker daemon\n'
    return 1
  fi

  VF="$(mktemp -d)"
  VF_P="hlst$$"
  # shellcheck disable=SC2154  # rc is the trap's own
  trap 'rc=$?; vf_cleanup; exit "${rc}"' EXIT INT TERM

  VF_REPO="${VF}/repo"
  mkdir -p "${VF_REPO}/scripts" "${VF_REPO}/stacks/observability" "${VF_REPO}/secrets"
  cp "${real}/scripts/backup-volumes.sh" "${real}/scripts/restore-volumes.sh" \
     "${real}/scripts/key-recipients.sh" "${real}/scripts/image-for.sh" \
     "${VF_REPO}/scripts/"

  VF_IMAGE="$(COMPOSE_FILE="${real}/stacks/observability/compose.yaml" "${real}/scripts/image-for.sh" archiver)"
  cat > "${VF_REPO}/stacks/observability/compose.yaml" <<EOF
name: hlst-fixture
services:
  grafana:
    image: ${VF_IMAGE}
    command: ["true"]
    volumes:
      - grafana-data:/var/lib/grafana
  archiver:
    profiles: ["backup"]
    image: ${VF_IMAGE}
    command: ["true"]
volumes:
  grafana-data:
EOF

  age-keygen -o "${VF}/k1" 2>/dev/null
  age-keygen -o "${VF}/k2" 2>/dev/null
  age-keygen -o "${VF}/k3" 2>/dev/null
  VF_K1="${VF}/k1" VF_K2="${VF}/k2" VF_K3="${VF}/k3"
  VF_R1="$(age-keygen -y "${VF_K1}")"
  VF_R2="$(age-keygen -y "${VF_K2}")"
  # The shape sops writes, which is the shape key-recipients.sh greps.
  cat > "${VF_REPO}/secrets/observability.sops.yaml" <<EOF
placeholder: ENC[AES256_GCM,data:fixture,type:str]
sops:
    age:
        - recipient: ${VF_R1}
          enc: fixture
        - recipient: ${VF_R2}
          enc: fixture
EOF

  docker image inspect "${VF_IMAGE}" >/dev/null 2>&1 || docker pull -q "${VF_IMAGE}" >/dev/null
}

vf_cleanup() {
  local v
  for v in "${VF_VOLUMES[@]}"; do docker volume rm -f "${v}" >/dev/null 2>&1 || :; done
  [[ -n ${VF} ]] && rm -rf "${VF}"
}

# vf_docker <volume> <sh script>: run a script in the archiver with the volume
# at /data, labelled like every other throwaway container here (#883).
vf_docker() {
  docker run --rm --network none --log-driver none --label homelab.logs=off \
    -v "$1:/data" "${VF_IMAGE}" sh -c "$2"
}

# vf_volume <project> <shape>: create <project>_grafana-data and fill it.
#   grafana    what a grafana-data looks like to verify(): the sentinel, the
#              companions, a binary file, a symlink, an empty directory, and
#              ownership and modes a restore must carry back verbatim
#   unmarked   the same without ./grafana.db: not provably grafana-data
#   foreign    grafana's tree with loki-data's sentinel in it: not ONLY grafana
vf_volume() {
  local vol="$1_grafana-data"
  VF_VOLUMES+=("${vol}")
  docker volume create "${vol}" >/dev/null
  vf_docker "${vol}" '
    set -e
    cd /data
    printf "SQLite format 3\000fixture\n" > grafana.db
    mkdir -p plugins/fixture-panel dashboards png empty
    printf "{\"id\": \"fixture-panel\"}\n" > plugins/fixture-panel/plugin.json
    head -c 70000 /dev/urandom > png/render.png
    ln -s ../grafana.db dashboards/db-link
    printf "a name with spaces\n" > "dashboards/with space.json"
    chown -R 472:472 /data
    chown 0:0 png/render.png
    chmod 0640 grafana.db
    chmod 0750 plugins
    chmod 1777 empty
  '
  case "$2" in
    grafana)  ;;
    unmarked) vf_docker "${vol}" 'rm /data/grafana.db' ;;
    foreign)  vf_docker "${vol}" 'mkdir /data/chunks && echo x > /data/chunks/000001' ;;
  esac
}

# vf_fingerprint <volume>: every path with its type, mode, owner and link
# target, a file's size, then every file's sha256 — two volumes with the same
# fingerprint hold the same tree. Not a directory's size: that is the
# filesystem's bookkeeping, and differs between two identical trees on btrfs.
vf_fingerprint() {
  docker run --rm --network none --log-driver none --label homelab.logs=off \
    -v "$1:/data:ro" "${VF_IMAGE}" sh -c '
      cd /data
      find . \( -type f -printf "%p f %s %m %U:%G\n" \) -o \( ! -type f -printf "%p %y %m %U:%G %l\n" \) \
        | LC_ALL=C sort
      find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2'
}

vf_exists() { docker volume inspect "$1" >/dev/null 2>&1; }

# vf_run <env assignment>... -- <script> <args...>   -> OUT, RC
# The script is the copy in VF_REPO/scripts. stdin is /dev/null: nothing here
# is a terminal unless vf_tty says so.
vf_run() {
  local -a env=()
  while [[ $1 != -- ]]; do env+=("$1"); shift; done
  shift
  local script="${VF_REPO}/scripts/$1"
  shift
  set +e
  OUT="$(env "${env[@]}" "${script}" "$@" </dev/null 2>&1)"
  RC=$?
  set -e
}

# vf_tty <typed line> <env assignment>... -- <script> <args...>   -> OUT, RC
# The same, under a pseudo-terminal from util-linux script(1), with one line
# typed at it. That is how restore-volumes.sh's confirmation is answered: it
# refuses a stdin that is not a terminal, by design.
vf_tty() {
  local typed="$1" cmd
  shift
  local -a env=()
  while [[ $1 != -- ]]; do env+=("$1"); shift; done
  shift
  cmd="$(printf '%q ' env "${env[@]}" "${VF_REPO}/scripts/$1")"
  shift
  cmd+="$(printf '%q ' "$@")"
  set +e
  OUT="$(printf '%s\n' "${typed}" | script -qec "${cmd}" /dev/null 2>&1)"
  RC=$?
  set -e
}

# vf_newest_set: the stamp of the newest complete set in the fixture repository.
vf_newest_set() {
  find "${VF_REPO}/backups/volumes" -mindepth 2 -maxdepth 2 -name MANIFEST -printf '%h\n' 2>/dev/null \
    | sort -r | head -1 | xargs -r basename
}

# vf_new_second: wait until no set is named for the current second.
#
# A set is named for the second it starts in, `mkdir` refuses a name that
# exists, and a failed backup leaves its incomplete set behind on purpose. So
# two backups in one second make the second one fail on "already exists" and
# never reach the guard it was written to test. Nothing names a set for a
# second still to come, so once the current second is free, any later one the
# backup reads from the clock is free too.
vf_new_second() {
  while [[ -e "${VF_REPO}/backups/volumes/$(date -u +%Y%m%dT%H%M%SZ)" ]]; do sleep 0.2; done
}

# vf_flip <file>: change one byte in the middle, always to a different value.
vf_flip() {
  local f="$1" off byte
  off=$(( $(stat -c %s "${f}") / 2 ))
  byte="$(od -An -tu1 -j "${off}" -N1 "${f}" | tr -d ' ')"
  printf '%b' "\\0$(printf '%03o' $(( (byte + 1) % 256 )))" \
    | dd of="${f}" bs=1 seek="${off}" conv=notrunc status=none
}

# expect <name> <rc> <output substring>
expect() {
  if [[ ${RC} == "$2" && ${OUT} == *"$3"* ]]; then
    printf '\033[0;32m  PASS\033[0m %s\n' "$1"
  else
    printf '\033[0;31m  FAIL\033[0m %s\n       exit %s, wanted %s; wanted output containing: %s\n' "$1" "${RC}" "$2" "$3"
    printf '%s\n' "${OUT}" | sed 's/^/       | /'
    fail=1
  fi
}

# check <name> <got> <expected>
check() {
  if [[ "$2" == "$3" ]]; then printf '\033[0;32m  PASS\033[0m %s\n' "$1"
  else printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$1" "$2" "$3"; fail=1; fi
}
