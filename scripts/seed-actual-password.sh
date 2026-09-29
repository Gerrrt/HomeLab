#!/usr/bin/env bash
#
# Set Actual's server password from SOPS before anything can reach it, and
# check it on every deploy after that.
#
#   scripts/seed-actual-password.sh            seed an unclaimed server; check a claimed one
#   scripts/seed-actual-password.sh --check    only check the running container; change nothing
#
# WHY THIS EXISTS
#
# Actual has no setting for its password. A fresh server is *unclaimed*: the
# first client to reach it is offered "set a password", and whatever it sends
# becomes the password (POST /account/bootstrap, accepted once, then 400
# already-bootstrapped). Behind Caddy that first client is anything on Hicks
# that finds the name before the operator does. The image's own CLI,
# src/scripts/reset-password.js, cannot close the gap from a script: it reads
# the password with stdin in raw mode and needs a terminal.
#
# So the claim is made here, over the same HTTP call the first-run page makes,
# from inside the pinned image with `--network none`, before the service's
# first start. Read off 26.9.0 on 2026-09-29: the server boots and answers
# /health with no network at all, bootstrap sets the password, and a login with
# it returns a token. The live container then starts on a volume that was
# never unclaimed.
#
# The password goes in on stdin and never into an environment: `docker
# inspect` on neither the throwaway container nor sensitive-actual shows it,
# and it is not in stacks/sensitive/.env, because the service itself never
# needs it.
#
# WHAT IT NEVER DOES
#
# It never changes a password that is already set. A server that is claimed
# is only checked: a login with the SOPS value. If that fails, the password was
# changed in Actual's own settings, or the SOPS value was, and one of them is
# now wrong. It says so and changes nothing. The README has the reset.
#
# It never boots a second server on the live volume: with sensitive-actual
# running, the check goes through `docker exec` into it.
#
# `make up STACK=sensitive` runs it first, as it runs seed-ha-http.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/stacks/sensitive/compose.yaml"

# Overridable so the proof can run against a throwaway project and never
# touch the live one, as for seed-ha-http.sh.
PROJECT="${ACTUAL_SEED_PROJECT:-sensitive}"
VOLUME_NAME="actual-data"
VOLUME="${PROJECT}_${VOLUME_NAME}"
CONTAINER="${ACTUAL_SEED_CONTAINER:-sensitive-actual}"

MODE=seed
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  -h|--help) sed -n '/^#   scripts/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32mok\033[0m — %s\n' "$*"; }

# The password is read here, not from .env: see above. ACTUAL_SEED_PASSWORD
# stands in for SOPS in the proof, where no age key is present.
if [[ -n "${ACTUAL_SEED_PASSWORD:-}" ]]; then
  ACTUAL_SERVER_PASSWORD="${ACTUAL_SEED_PASSWORD}"
else
  # shellcheck source=scripts/secrets-env.sh
  source "${REPO_ROOT}/scripts/secrets-env.sh"
  load_secrets sensitive
fi
[[ -n "${ACTUAL_SERVER_PASSWORD:-}" ]] \
  || die "ACTUAL_SERVER_PASSWORD is not set in secrets/sensitive.sops.yaml (make secrets-edit STACK=sensitive)"

# The image's own user, which owns /data in the image and so, on first mount,
# the volume. compose.yaml runs the service as the same pair.
USER_SPEC="1001:1001"

actual_running() { [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" == true ]]; }

# One program for both paths. With SPAWN=1 it starts the server itself,
# inside a container with no network, and stops it afterwards; without, it
# talks to the server already running in the container it was exec'd into.
# The password is the whole of stdin. It prints one line the shell reads back.
# shellcheck disable=SC2016  # JavaScript, not shell
JS='
const base = "http://localhost:5006";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const post = (path, body) =>
  fetch(base + path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })
    .then(async (r) => ({ status: r.status, body: await r.json().catch(() => ({})) }));
let child = null;
async function main(password) {
  if (process.env.SPAWN === "1") {
    const { spawn } = await import("node:child_process");
    child = spawn("node", ["app.js"], { stdio: "ignore", env: { ...process.env, ACTUAL_LOGIN_METHOD: "password" } });
  }
  let up = false;
  for (let i = 0; i < 60 && !up; i++) {
    up = await fetch(base + "/health").then((r) => r.ok, () => false);
    if (!up) await sleep(500);
  }
  if (!up) return "down";
  const nb = await fetch(base + "/account/needs-bootstrap").then((r) => r.json());
  if (!nb.data.bootstrapped) {
    if (process.env.MODE === "check") return "unclaimed";
    const r = await post("/account/bootstrap", { password });
    return r.status === 200 && r.body.data && r.body.data.token ? "claimed" : "bootstrap-failed " + r.status;
  }
  const r = await post("/account/login", { loginMethod: "password", password });
  return r.status === 200 && r.body.data && r.body.data.token ? "present matches" : "present MISMATCH";
}
let password = "";
process.stdin.on("data", (d) => (password += d)).on("end", () => {
  main(password)
    .then((out) => console.log(out), (err) => console.log("error " + String(err).split("\n")[0]))
    .finally(() => { if (child) child.kill("SIGTERM"); });
});
'

if actual_running; then
  info "${CONTAINER} is running; checking it in place"
  out="$(printf '%s' "${ACTUAL_SERVER_PASSWORD}" \
    | docker exec -i -e MODE="${MODE}" -e SPAWN=0 "${CONTAINER}" node -e "${JS}")" \
    || die "the check failed inside ${CONTAINER}"
else
  [[ ${MODE} == check ]] && die "${CONTAINER} is not running; --check only checks the live service"
  IMAGE="$(COMPOSE_FILE="${COMPOSE_FILE}" "${REPO_ROOT}/scripts/image-for.sh" actual)" \
    || die "could not resolve the pinned actual image"
  if ! docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
    # compose's own labels, so `make up` adopts the volume rather than warning
    # that it "was not created by Docker Compose" — as seed-ha-http.sh does.
    info "creating ${VOLUME} with compose's labels"
    docker volume create \
      --label "com.docker.compose.project=${PROJECT}" \
      --label "com.docker.compose.volume=${VOLUME_NAME}" \
      "${VOLUME}" >/dev/null
  fi
  # The service's own hardening, so the seed writes nothing the service could
  # not: the same user, no capabilities, a read-only root and no network.
  out="$(printf '%s' "${ACTUAL_SERVER_PASSWORD}" \
    | docker run --rm -i --network none --user "${USER_SPEC}" \
        --cap-drop ALL --security-opt no-new-privileges:true \
        --read-only --tmpfs /tmp:size=16m \
        -e MODE="${MODE}" -e SPAWN=1 \
        -v "${VOLUME}:/data" \
        --entrypoint node "${IMAGE}" -e "${JS}")" \
    || die "the seed step failed inside ${IMAGE}"
fi

[[ -n ${out} ]] || die "the seed step printed nothing (was stdin passed through?)"
case "${out}" in
  claimed)
    ok "${VOLUME}: claimed with the SOPS password before first start" ;;
  "present matches")
    ok "${VOLUME}: already claimed, and the SOPS password logs in; left alone" ;;
  "present MISMATCH")
    printf '\033[0;33mwarning:\033[0m %s\n' "${VOLUME}: claimed, but the SOPS password does NOT log in." >&2
    printf '         It was changed in Actual or in SOPS. stacks/sensitive/README.md has the reset.\n' >&2
    [[ ${MODE} == check ]] && exit 1 ;;
  unclaimed)
    die "${CONTAINER} is running UNCLAIMED: anyone who reaches it can set the password. Run $0 without --check now" ;;
  *)
    die "unexpected result from the seed step: ${out}" ;;
esac
