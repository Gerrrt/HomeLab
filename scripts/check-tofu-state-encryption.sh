#!/usr/bin/env bash
#
# Prove that tofu/'s state is encrypted, rather than assume it (ADR-0076).
#
# A state file holds every value a provider touched, in cleartext unless
# OpenTofu encrypts it. Dropped into this repository unencrypted, it would undo
# ADR-0005, ADR-0020 and ADR-0024 in one commit, and it would do it quietly:
# nothing about a plaintext state looks wrong until someone reads it. So the
# claim "the state is encrypted" is checked two ways, and each check is also
# seen to FAIL, because a check that has never been seen to fail is a check
# nobody has tested.
#
# Usage:
#   scripts/check-tofu-state-encryption.sh --self-test
#       CI. No Proxmox, no provider download. Copies the REAL tofu/encryption.tf
#       beside a built-in terraform_data canary and proves, against states it
#       writes itself:
#         - with encryption.tf, the canary is absent from state, the gitleaks
#           tfstate-plaintext rule does not match, and the plan is ciphertext
#         - without it, the canary IS in the state and the rule DOES match:
#           the grep can fail, so its silence above means something
#         - a wrong passphrase cannot read the state
#         - `enforced = true` refuses an unencrypted method
#         - .gitignore refuses the state path, and `git add -f` turns
#           check-tracked-artefacts.sh red
#
#   <secret> | scripts/check-tofu-state-encryption.sh <state-file>
#       phoenix, after an apply (provision-lab-guests.md §4). Checks the real
#       state: it is the encrypted wrapper, the gitleaks rule does not match,
#       and the secret read from stdin does not occur in it. The secret comes
#       on stdin, never as an argument, so it is not in `ps` or shell history:
#
#         tofu -chdir=tofu output -raw proof_password \
#           | scripts/check-tofu-state-encryption.sh tofu/state/lab.tfstate
#
# tofu runs from the binary if there is one, else from the image
# stacks/observability/compose.yaml pins (`scripts/image-for.sh tofu`), the way
# scripts/lint.sh runs packer. With neither, the suite SKIPs, and
# `self-tests.sh --require-all` turns that skip into a failure in CI.
#
# The gitleaks regex is read out of .gitleaks.toml rather than restated here, so
# this tests the rule CI scans with, not a copy of it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() { printf '\033[0;33m  SKIP\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }
FAILED=0

# The tfstate-plaintext rule's regex, as gitleaks reads it. RE2 and ERE agree on
# everything it uses (\s, a class, literals), so grep -E runs it unchanged.
tfstate_regex() {
  local q="'''"
  sed -n "/^id *= *\"tfstate-plaintext\"/,/^\[\[/ s/^regex *= *${q}\(.*\)${q}\$/\1/p" \
    "${REPO_ROOT}/.gitleaks.toml" | head -n 1
}
REGEX="$(tfstate_regex)"
[[ -n "${REGEX}" ]] || die "no tfstate-plaintext rule in .gitleaks.toml — the scan this proves is gone"

# Is <file> the encrypted wrapper, with nothing the plaintext rule matches?
# Echoes why not, and returns 1, so both modes report the same reasons.
encrypted_shape() {
  local f="$1"
  grep -q '"encrypted_data"' "${f}" || { echo "no encrypted_data field"; return 1; }
  grep -q '"encryption_version"' "${f}" || { echo "no encryption_version field"; return 1; }
  if grep -Eq "${REGEX}" "${f}"; then echo "the gitleaks tfstate-plaintext rule matches"; return 1; fi
  return 0
}

# ---------------------------------------------------------------------------
# --self-test
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  TOFU=()
  if have tofu; then
    TOFU=(tofu)
  elif have docker && docker info >/dev/null 2>&1; then
    TOFU=(docker)
  else
    skip "tofu: no binary and no docker daemon, so no state can be written to check"
    exit 0
  fi
  have git || { skip "git not installed"; exit 0; }

  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  PASSPHRASE="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  WRONG="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  CANARY="canary-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  # Run tofu in <dir>. From the image, the directory is the only mount, and
  # --user keeps a workstation from collecting root-owned files.
  tofu_in() {
    local dir="$1"; shift
    if [[ "${TOFU[0]}" == tofu ]]; then
      (cd "${dir}" && TF_IN_AUTOMATION=1 TF_VAR_state_passphrase="${PP}" tofu "$@")
    else
      docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e TF_IN_AUTOMATION=1 \
        -e TF_VAR_state_passphrase="${PP}" -v "${dir}:/w" -w /w \
        "$("${REPO_ROOT}/scripts/image-for.sh" tofu)" "$@"
    fi
  }
  canary_tf() {
    cat > "$1/canary.tf" <<EOF
variable "canary" {
  type = string
}

# terraform_data is built in: no provider, so no download and no Proxmox.
resource "terraform_data" "canary" {
  input = var.canary
}
EOF
  }
  # Captures output so a failure prints it, and a success prints nothing.
  run() {  # <dir> <args...> → OUT, RC
    local dir="$1"; shift
    set +e
    OUT="$(tofu_in "${dir}" "$@" 2>&1)"
    RC=$?
    set -e
  }
  must() {  # <what> — the last run() must have succeeded
    if ((RC != 0)); then
      fail "$1 (tofu exited ${RC})"
      printf '%s\n' "${OUT}" | sed 's/^/       | /'
      exit 1
    fi
  }

  # --- encrypted: the real encryption.tf ------------------------------------
  E="${T}/encrypted"
  mkdir -p "${E}"
  cp "${REPO_ROOT}/tofu/encryption.tf" "${E}/"
  canary_tf "${E}"
  PP="${PASSPHRASE}"
  run "${E}" init -input=false;                                       must "tofu init with tofu/encryption.tf"
  run "${E}" plan -input=false -var "canary=${CANARY}" -out=p.tfplan; must "tofu plan -out with tofu/encryption.tf"

  # An unencrypted plan is a zip, so a grep for the canary would miss it either
  # way. The shape is the honest test: ciphertext is the JSON wrapper, a
  # plaintext plan starts PK.
  if [[ "$(head -c 2 "${E}/p.tfplan")" != PK ]] && grep -q '"encrypted_data"' "${E}/p.tfplan"; then
    pass "the plan file is ciphertext, not a zip"
  else
    fail "the plan file written with tofu/encryption.tf is not encrypted"
  fi

  run "${E}" apply -input=false p.tfplan; must "tofu apply with tofu/encryption.tf"
  STATE="${E}/terraform.tfstate"
  [[ -s "${STATE}" ]] || { fail "apply wrote no state at all"; exit 1; }
  if grep -qF "${CANARY}" "${STATE}"; then
    fail "the canary is in the state written with tofu/encryption.tf — it is plaintext"
  else
    pass "the canary is absent from the encrypted state"
  fi
  if why="$(encrypted_shape "${STATE}")"; then
    pass "the encrypted state is the wrapper, and the gitleaks rule does not match it"
  else
    fail "the encrypted state: ${why}"
  fi

  # --- a wrong passphrase cannot read it ------------------------------------
  PP="${WRONG}"
  run "${E}" plan -input=false -var "canary=${CANARY}"
  if ((RC != 0)); then
    pass "a different passphrase cannot read the state"
  else
    fail "a different passphrase read the state — the key is not what protects it"
  fi

  # --- enforced: an unencrypted method is refused, for state and plan alone --
  # One fixture per block, each swapping only that block's method. Swapping
  # both at once would stay green with either `enforced = true` deleted,
  # because the other block would still refuse. `enforced` itself is left as
  # the real file has it, so deleting that one line is what turns its fixture
  # red.
  swap_method() {  # <state|plan> <dst> → encryption.tf with that block's method unencrypted
    awk -v blk="$1" '
      /^[[:space:]]*encryption \{$/ {
        print; match($0, /^[[:space:]]*/)
        printf "%s  method \"unencrypted\" \"off\" {}\n", substr($0, 1, RLENGTH); next
      }
      $1 == blk && $2 == "{" { in_blk = 1 }
      in_blk && /method\.aes_gcm\.phoenix$/ {
        sub(/method\.aes_gcm\.phoenix$/, "method.unencrypted.off"); in_blk = 0
      }
      { print }
    ' "${REPO_ROOT}/tofu/encryption.tf" > "$2"
  }
  for blk in state plan; do
    F="${T}/enforced-${blk}"
    mkdir -p "${F}"
    swap_method "${blk}" "${F}/encryption.tf"
    if [[ "$(grep -c 'method\.unencrypted\.off' "${F}/encryption.tf")" != 1 ]]; then
      fail "could not swap only the ${blk} method in a copy of encryption.tf — its shape changed; update this test"
      continue
    fi
    canary_tf "${F}"
    PP="${PASSPHRASE}"
    # OpenTofu 1.13 refuses at init, before anything is written. If init lets
    # it through, the artefact is written and inspected, so a later release
    # that moves the refusal is tested where it lands, not passed on init's say-so.
    run "${F}" init -input=false
    leaked=0
    if ((RC == 0)); then
      if [[ "${blk}" == state ]]; then
        run "${F}" apply -input=false -auto-approve -var "canary=${CANARY}"
        grep -qF "${CANARY}" "${F}/terraform.tfstate" 2>/dev/null && leaked=1
      else
        run "${F}" plan -input=false -var "canary=${CANARY}" -out=p.tfplan
        [[ "$(head -c 2 "${F}/p.tfplan" 2>/dev/null)" == PK ]] && leaked=1
      fi
    fi
    if ((RC != 0 && leaked == 0)) && [[ "${OUT}" == *enforced* ]]; then
      pass "enforced = true refuses an unencrypted ${blk} method"
    else
      fail "an unencrypted ${blk} method was accepted — enforced = true is missing from the ${blk} block of tofu/encryption.tf"
    fi
  done

  # --- the negative half: no encryption.tf ----------------------------------
  # The same canary with encryption left out. If the grep and the rule do not
  # find it HERE, their silence above proved nothing.
  P="${T}/plaintext"
  mkdir -p "${P}"
  canary_tf "${P}"
  run "${P}" init -input=false;                                       must "tofu init without encryption"
  run "${P}" plan -input=false -var "canary=${CANARY}" -out=p.tfplan; must "tofu plan without encryption"
  if [[ "$(head -c 2 "${P}/p.tfplan")" == PK ]]; then
    pass "without encryption the plan is a plain zip, so the shape test above can fail"
  else
    fail "an unencrypted plan is not a zip — the plan-shape test above proves nothing"
  fi
  run "${P}" apply -input=false p.tfplan; must "tofu apply without encryption"
  if grep -qF "${CANARY}" "${P}/terraform.tfstate"; then
    pass "without encryption the canary IS in the state, so the grep can fail"
  else
    fail "the canary is absent even from unencrypted state — the grep above proves nothing"
  fi
  if grep -Eq "${REGEX}" "${P}/terraform.tfstate"; then
    pass "without encryption the gitleaks tfstate-plaintext rule matches"
  else
    fail "the gitleaks tfstate-plaintext rule does not match a plaintext state"
  fi

  # --- git: ignored, and caught when forced ---------------------------------
  G="${T}/repo"
  mkdir -p "${G}/scripts" "${G}/tofu/state"
  git init -q "${G}"
  cp "${REPO_ROOT}/.gitignore" "${G}/"
  cp "${REPO_ROOT}/scripts/check-tracked-artefacts.sh" "${G}/scripts/"
  cp "${STATE}" "${G}/tofu/state/lab.tfstate"
  if git -C "${G}" add tofu/state/lab.tfstate >/dev/null 2>&1; then
    fail ".gitignore let \`git add tofu/state/lab.tfstate\` through"
  else
    pass ".gitignore refuses \`git add tofu/state/lab.tfstate\`"
  fi
  git -C "${G}" add -f tofu/state/lab.tfstate
  set +e
  out="$("${G}/scripts/check-tracked-artefacts.sh" 2>&1)"; rc=$?
  set -e
  if ((rc == 1)) && [[ "${out}" == *tofu/state/lab.tfstate* ]]; then
    pass "a state added with -f fails check-tracked-artefacts.sh"
  else
    fail "a state added with -f passed check-tracked-artefacts.sh (exit ${rc})"
    printf '%s\n' "${out}" | sed 's/^/       | /'
  fi

  exit "${FAILED}"
fi

# ---------------------------------------------------------------------------
# A real state, on phoenix
# ---------------------------------------------------------------------------
STATE="${1:?usage: $0 --self-test | <secret> | $0 <state-file>}"
[[ -s "${STATE}" ]] || die "${STATE} does not exist or is empty"

if why="$(encrypted_shape "${STATE}")"; then
  pass "${STATE} is the encrypted wrapper, and the gitleaks rule does not match it"
else
  fail "${STATE}: ${why}"
fi

if [[ -t 0 ]]; then
  # Not a skip. Without a known secret the half of the proof the issue asks for
  # did not happen, and saying PASS over it would be the quiet failure again.
  fail "no secret on stdin — pipe one in, e.g. tofu -chdir=tofu output -raw proof_password | $0 ${STATE}"
else
  secret="$(cat)"
  if [[ ${#secret} -lt 8 ]]; then
    fail "the secret on stdin is ${#secret} characters — too short to prove anything by its absence"
  elif grep -qF -- "${secret}" "${STATE}"; then
    fail "the secret occurs in ${STATE} in cleartext"
  else
    pass "the secret does not occur in ${STATE}"
  fi
fi

exit "${FAILED}"
