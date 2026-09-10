#!/usr/bin/env bash
#
# The sensitive tier's certificate authority: mint it on the monitoring host,
# install it on trinity. ADR-0037 is the decision; this is the mechanism.
#
# The tier has a root of its own rather than an intermediate beneath the
# estate's CA, because the estate's root is minted with pathlen:0 and a leaf
# beneath any intermediate of it fails "path length constraint exceeded"
# (measured — the ADR has the table). Caddy on trinity then obtains every
# certificate it serves from the intermediate over ACME, so issuing one is a
# handshake and renewal is nobody's job.
#
# Everything lands under certificates/, which is gitignored, and the tree
# step-ca runs from is produced by `step ca init` in the pinned step-ca image —
# no step binary on the host, the same rule as promtool and caddy validate.
#
# Usage:
#   scripts/tier-ca.sh --mint [--password-file FILE]   monitoring host: create root + intermediate,
#                                                       write the bundle that ships to trinity
#   scripts/tier-ca.sh --install BUNDLE                 trinity: populate step-ca's volume from
#                                                       the bundle, and write the root cert
#                                                       Caddy trusts
#   scripts/tier-ca.sh --list                           show what exists here, and when it expires
#
#   --password-file FILE   the password that encrypts the CA keys at rest. It is
#                          STEPCA_PASSWORD in secrets/sensitive.sops.yaml — the
#                          two must match or step-ca cannot open its own key.
#                          Prompted for if omitted; never taken from argv.
#   --force                overwrite an existing tree (--mint) or a populated
#                          volume (--install). Minting a new root invalidates
#                          every device that trusts the old one.
#
# What the bundle holds, and what it does not:
#   config/ca.json, config/defaults.json   the CA's configuration, ACME included
#   certs/root_ca.crt                      the root CERTIFICATE — public
#   certs/intermediate_ca.crt              the intermediate certificate
#   secrets/intermediate_ca_key            the intermediate's key, encrypted
#   db/                                    empty; step-ca creates its state here
#
#   secrets/root_ca_key                    NEVER. It stays in the tree on the
#                                          monitoring host, and this script
#                                          refuses to report a bundle that
#                                          carries it. ca.json does not
#                                          reference it; step-ca has no use for
#                                          it at runtime.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${REPO_ROOT}/certificates"
TREE="${CERT_DIR}/tier-ca"
BUNDLE="${CERT_DIR}/tier-ca-bundle.tar"
# The root certificate on its own, where compose.yaml mounts it into Caddy as
# the trusted root for the ACME directory, and what every device that reaches
# the tier imports. Public: distribute freely, like the estate's ca.pem.
ROOT_PEM="${CERT_DIR}/tier-ca.pem"

# The compose project is `name: sensitive` and the volume is `step-ca-data`,
# so the volume Docker creates is this. --install creates it FIRST, with the
# labels compose stamps on its own volumes, so that `make up` adopts it silently
# instead of warning that it "was not created by Docker Compose" (measured: the
# labels are what compose checks; without them it warns and proceeds).
# TIER_CA_PROJECT exists for one reason: booting this stack under another
# project name on a host that is not trinity, to prove the ACME path against
# a throwaway root without touching a volume the real project would adopt.
COMPOSE_PROJECT="${TIER_CA_PROJECT:-sensitive}"
VOLUME_NAME="step-ca-data"
VOLUME="${COMPOSE_PROJECT}_${VOLUME_NAME}"

CA_NAME="Matrix Elysium Sensitive Tier"
# Every name the CA's own serving certificate carries. `step-ca` is what Caddy
# dials on the compose network; `localhost` is what the container's healthcheck
# dials; the FQDN and the address are there so a future off-host client (the
# estate's Grafana renewing with `step ca renew`, ADR-0037's reopen) verifies
# without a re-mint. SANs are set at init and cost nothing to include.
CA_DNS=(step-ca localhost trinity.matrix.elysium 10.0.99.40)
CA_ADDRESS=":9000"
# One challenge type, and it is the one that runs over 443, the tier's only
# published port. 168h is the outage budget, not a labour cost — ADR-0037 §3.
ACME_CHALLENGE="tls-alpn-01"
LEAF_DEFAULT="168h"
LEAF_MAX="168h"
LEAF_MIN="5m"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32mok\033[0m — %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

MODE=""
PASSWORD_FILE=""
BUNDLE_IN=""
FORCE=0

while (($#)); do
  case "$1" in
    --mint)    MODE="mint"; shift ;;
    --list)    MODE="list"; shift ;;
    --install) MODE="install"; BUNDLE_IN="${2:?--install needs the bundle path}"; shift 2
               [[ "${BUNDLE_IN}" != --* ]] || die "--install needs the bundle path, got a flag: ${BUNDLE_IN}" ;;
    --password-file) PASSWORD_FILE="${2:?--password-file needs a path}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    # Printed from the header rather than kept as a second copy — gen-certs.sh
    # does the same, and for the same reason.
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${MODE}" ]] || die "nothing to do — try --mint, --install BUNDLE, or --list (see --help)"

# The daemon is checked before anything else so a missing one fails here, by
# name. The image itself is resolved at each call site on its own statement —
# scripts/check_image_pins.py traces `docker run` operands back to an
# assignment that mentions image-for.sh, and a function body is invisible to it.
require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found — the step binary runs from the pinned image"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
}
SENSITIVE_COMPOSE="${REPO_ROOT}/stacks/sensitive/compose.yaml"

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "list" ]]; then
  head_ "certificates/tier-ca/"
  if [[ ! -s "${TREE}/config/ca.json" ]]; then
    printf '  (no tree yet — start with %s --mint)\n\n' "$(basename "$0")"
    exit 0
  fi
  for crt in root_ca intermediate_ca; do
    path="${TREE}/certs/${crt}.crt"
    [[ -s "${path}" ]] || { printf '  %-24s \033[0;31mMISSING\033[0m\n' "${crt}.crt"; continue; }
    subject="$(openssl x509 -in "${path}" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    enddate="$(openssl x509 -in "${path}" -noout -enddate 2>/dev/null | cut -d= -f2)"
    if openssl x509 -in "${path}" -noout -checkend 0 >/dev/null 2>&1; then
      state="valid"
    else
      state="\033[0;31mEXPIRED\033[0m"
    fi
    printf '  %-24s %b  until %s\n    %s\n' "${crt}.crt" "${state}" "${enddate}" "${subject}"
  done
  printf '  %-24s %s\n' "root key" "$([[ -s "${TREE}/secrets/root_ca_key" ]] && echo 'present (stays here)' || echo 'ABSENT')"
  printf '  %-24s %s\n' "bundle" "$([[ -s "${BUNDLE}" ]] && echo "${BUNDLE#"${REPO_ROOT}"/}" || echo '(not built)')"
  printf '  %-24s %s\n\n' "root cert for Caddy" "$([[ -s "${ROOT_PEM}" ]] && echo "${ROOT_PEM#"${REPO_ROOT}"/}" || echo '(not written)')"
  exit 0
fi

# ---------------------------------------------------------------------------
# --mint  (monitoring host)
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "mint" ]]; then
  if [[ -s "${TREE}/config/ca.json" ]] && ((! FORCE)); then
    die "${TREE#"${REPO_ROOT}"/}/config/ca.json already exists.
Minting a new root invalidates every device that trusts the current one —
every phone and laptop that imported ${ROOT_PEM#"${REPO_ROOT}"/}. Pass --force only if
that is what you mean."
  fi
  command -v openssl >/dev/null 2>&1 || die "openssl not found (used to verify the result)"
  command -v python3 >/dev/null 2>&1 || die "python3 not found (used to read ca.json)"
  require_docker
  # The image this stack pins, never a floating tag — see scripts/image-for.sh.
  IMAGE="$(COMPOSE_FILE="${SENSITIVE_COMPOSE}" "${REPO_ROOT}/scripts/image-for.sh" step-ca)"

  # 0700 on the directory, not just the keys — gen-certs.sh's reasoning.
  mkdir -p "${CERT_DIR}"
  chmod 700 "${CERT_DIR}"
  umask 077

  # The password: a file the operator names, or a prompt. Never argv, which
  # every other user on the host can read out of /proc. The prompted copy
  # lives on a private temp file for the length of the run and is shredded.
  TMP="$(mktemp -d)"
  trap 'shred -u "${TMP}"/* 2>/dev/null || rm -f "${TMP}"/*; rm -rf "${TMP}"' EXIT INT TERM
  if [[ -n "${PASSWORD_FILE}" ]]; then
    [[ -s "${PASSWORD_FILE}" ]] || die "password file is missing or empty: ${PASSWORD_FILE}"
    cp "${PASSWORD_FILE}" "${TMP}/pw"
  else
    [[ -t 0 ]] || die "no --password-file and stdin is not a terminal — nothing to prompt on"
    printf 'The password that encrypts the CA keys — STEPCA_PASSWORD in secrets/sensitive.sops.yaml.\n'
    read -rsp 'password: ' pw1; printf '\n'
    read -rsp 'again:    ' pw2; printf '\n'
    [[ "${pw1}" == "${pw2}" ]] || die "the two entries differ"
    [[ -n "${pw1}" ]] || die "empty password"
    printf '%s' "${pw1}" > "${TMP}/pw"
    unset pw1 pw2
  fi
  # A trailing newline in the file becomes part of the password step uses and
  # the one in SOPS has none; strip it so the two cannot differ by one byte.
  printf '%s' "$(cat "${TMP}/pw")" > "${TMP}/pw.trimmed" && mv -f "${TMP}/pw.trimmed" "${TMP}/pw"
  chmod 600 "${TMP}/pw"

  if ((FORCE)) && [[ -d "${TREE}" ]]; then
    info "removing the existing tree (--force)"
    rm -rf "${TREE}"
  fi
  mkdir -p "${TREE}"
  # The container runs as the operator so the tree is owned by the operator
  # here; --install re-owns it to step's uid inside the volume on trinity.
  # Mounted at /home/step — the image's STEPPATH and where compose.yaml mounts
  # the volume — because `step ca init` writes ABSOLUTE paths into ca.json:
  # minted under any other mount point, the CA on trinity fails to open
  # /tree/certs/root_ca.crt, which is what the first trial did.
  chmod 700 "${TREE}"

  dns_flags=()
  for name in "${CA_DNS[@]}"; do dns_flags+=(--dns "${name}"); done

  info "minting the root and intermediate (${CA_NAME})"
  docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    -e STEPPATH=/home/step -e HOME=/home/step \
    -v "${TREE}:/home/step" \
    -v "${TMP}/pw:/pw:ro" \
    --entrypoint step "${IMAGE}" \
    ca init \
      --deployment-type standalone \
      --name "${CA_NAME}" \
      "${dns_flags[@]}" \
      --address "${CA_ADDRESS}" \
      --provisioner operator \
      --password-file /pw \
      --provisioner-password-file /pw \
    >"${TMP}/init.log" 2>&1 || { cat "${TMP}/init.log" >&2; die "step ca init failed"; }

  # The ACME provisioner, added against the file rather than with `--acme` at
  # init, so the challenge and lifetime claims are in ca.json before the CA
  # ever starts — the default provisioner accepts every challenge type and
  # issues 24h leaves, and neither is what ADR-0037 decided.
  info "adding the ACME provisioner (${ACME_CHALLENGE} only, leaves ${LEAF_DEFAULT})"
  docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    -e STEPPATH=/home/step -e HOME=/home/step \
    -v "${TREE}:/home/step" \
    --entrypoint step "${IMAGE}" \
    ca provisioner add acme --type ACME \
      --challenge "${ACME_CHALLENGE}" \
      --x509-min-dur "${LEAF_MIN}" \
      --x509-default-dur "${LEAF_DEFAULT}" \
      --x509-max-dur "${LEAF_MAX}" \
      --ca-config /home/step/config/ca.json \
    >"${TMP}/prov.log" 2>&1 || { cat "${TMP}/prov.log" >&2; die "step ca provisioner add failed"; }

  # ---- Prove the result before reporting it ------------------------------
  # The chain builds, the root is a CA, the provisioner carries exactly the
  # claims above, and ca.json never mentions the root key. Each of these is
  # a thing that would otherwise surface as a trust error on trinity.
  openssl verify -CAfile "${TREE}/certs/root_ca.crt" "${TREE}/certs/intermediate_ca.crt" >/dev/null 2>&1 \
    || die "the intermediate does not verify against the root — refusing to report success"
  openssl x509 -in "${TREE}/certs/root_ca.crt" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' \
    || die "the root certificate is not a CA — refusing to report success"
  grep -q 'root_ca_key' "${TREE}/config/ca.json" \
    && die "ca.json references the root key; the bundle would need it and it must not travel"
  # Every path in ca.json must be the one the service container will see.
  grep -oE '"/[^"]+"' "${TREE}/config/ca.json" | grep -qv '^"/home/step/' \
    && die "ca.json holds a path outside /home/step — the tree was minted at the wrong mount point"
  python3 - "${TREE}/config/ca.json" "${ACME_CHALLENGE}" "${LEAF_DEFAULT}" "${LEAF_MAX}" <<'PY' \
    || die "the ACME provisioner in ca.json does not carry the expected claims"
import json, sys
cfg, challenge, default, maximum = sys.argv[1:]
provs = json.load(open(cfg))["authority"]["provisioners"]
acme = [p for p in provs if p.get("type") == "ACME"]
assert len(acme) == 1, f"expected one ACME provisioner, found {len(acme)}"
p = acme[0]
assert p.get("name") == "acme", p.get("name")
assert p.get("challenges") == [challenge], p.get("challenges")
claims = p.get("claims", {})
def hours(d):  # "168h0m0s" -> "168h"
    return d.split("h")[0] + "h" if "h" in d else d
assert hours(claims.get("defaultTLSCertDuration", "")) == default, claims
assert hours(claims.get("maxTLSCertDuration", "")) == maximum, claims
PY

  # The root certificate on its own, for Caddy's trusted_roots and for every
  # device that reaches the tier.
  cp "${TREE}/certs/root_ca.crt" "${ROOT_PEM}"
  chmod 644 "${ROOT_PEM}"
  chmod 644 "${TREE}/certs/"*.crt

  # ---- The bundle that ships ---------------------------------------------
  # Listed by name, never `secrets/`: that directory holds the root key.
  info "building the bundle for trinity"
  tar -C "${TREE}" -cf "${BUNDLE}" \
    config/ca.json config/defaults.json \
    certs/root_ca.crt certs/intermediate_ca.crt \
    secrets/intermediate_ca_key \
    db
  chmod 600 "${BUNDLE}"
  # The listing is captured once rather than piped into `grep -q`: with
  # pipefail, grep closing the pipe on its first match hands tar SIGPIPE and
  # the pipeline reports failure for a bundle that is fine (observed).
  listing="$(tar -tf "${BUNDLE}")"
  if grep -q 'root_ca_key' <<< "${listing}"; then
    rm -f "${BUNDLE}"
    die "the bundle contained the root key — deleted it; this is a bug in this script"
  fi

  fingerprint="$(openssl x509 -in "${ROOT_PEM}" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
  ok "minted"
  printf '  tree     %s   (stays here; holds the root key)\n' "${TREE#"${REPO_ROOT}"/}"
  printf '  root     %s   (public — this is what devices trust)\n' "${ROOT_PEM#"${REPO_ROOT}"/}"
  printf '  bundle   %s   (what travels to trinity; no root key)\n' "${BUNDLE#"${REPO_ROOT}"/}"
  printf '  root SHA256 %s\n' "${fingerprint}"
  printf '\nNext, on trinity — docs/runbooks/build-the-tier-ca.md:\n'
  printf '  scp the bundle over, then\n'
  printf '  make tier-ca ARGS="--install certificates/tier-ca-bundle.tar"\n\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# --install BUNDLE  (trinity)
# ---------------------------------------------------------------------------
[[ -s "${BUNDLE_IN}" ]] || die "no bundle at ${BUNDLE_IN}"
require_docker
# The image this stack pins, never a floating tag — see scripts/image-for.sh.
IMAGE="$(COMPOSE_FILE="${SENSITIVE_COMPOSE}" "${REPO_ROOT}/scripts/image-for.sh" step-ca)"
BUNDLE_ABS="$(cd "$(dirname "${BUNDLE_IN}")" && pwd)/$(basename "${BUNDLE_IN}")"

# Refuse a bundle that carries the root key, whatever built it. Listed once
# into a variable, not piped into `grep -q` — see the note in --mint.
listing="$(tar -tf "${BUNDLE_ABS}")"
if grep -q 'root_ca_key' <<< "${listing}"; then
  die "this bundle contains secrets/root_ca_key. The root key never reaches trinity —
rebuild the bundle on the monitoring host with $(basename "$0") --mint, and delete this copy."
fi
grep -q '^config/ca.json$' <<< "${listing}" || die "not a tier-ca bundle: no config/ca.json inside"

# A populated volume is a running CA's state. Overwriting it is a re-key of
# the intermediate, which is sometimes the point (a re-mint after a compromise)
# and never an accident.
if docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
  if docker run --rm --network none --user 0 -v "${VOLUME}:/home/step:ro" --entrypoint sh "${IMAGE}" \
       -c 'test -s /home/step/config/ca.json' 2>/dev/null && ((! FORCE)); then
    die "volume ${VOLUME} already holds a CA (config/ca.json).
Installing over it replaces the intermediate every leaf on this tier chains to.
Pass --force only if that is what you mean — and expect Caddy to re-issue every
certificate on its next renewal."
  fi
else
  info "creating volume ${VOLUME} with compose's labels"
  docker volume create \
    --label "com.docker.compose.project=${COMPOSE_PROJECT}" \
    --label "com.docker.compose.volume=${VOLUME_NAME}" \
    "${VOLUME}" >/dev/null
fi

# Extract as root, then hand the tree to step's uid — the compose service runs
# as 1000:1000 with every capability dropped, so it must own what it reads.
# `secrets/` closes to 0700, and the bundle's own modes are not trusted.
info "populating ${VOLUME} from ${BUNDLE_IN}"
docker run --rm --network none --user 0 \
  -v "${VOLUME}:/home/step" \
  -v "${BUNDLE_ABS}:/bundle.tar:ro" \
  --entrypoint sh "${IMAGE}" -c '
    set -e
    rm -rf /home/step/config /home/step/certs /home/step/secrets /home/step/db
    tar -xf /bundle.tar -C /home/step
    chown -R 1000:1000 /home/step
    chmod 700 /home/step/secrets /home/step/config /home/step/db
    chmod 600 /home/step/secrets/*
    chmod 644 /home/step/certs/*
  '

# The root certificate, where compose.yaml mounts it into Caddy. Public.
mkdir -p "${CERT_DIR}"
chmod 700 "${CERT_DIR}"
tar -xOf "${BUNDLE_ABS}" certs/root_ca.crt > "${ROOT_PEM}"
chmod 644 "${ROOT_PEM}"

# Read the result back out of the volume, as step's own uid, so what is
# reported is what the service will see.
head_ "installed"
docker run --rm --network none --user 1000:1000 \
  -v "${VOLUME}:/home/step:ro" \
  --entrypoint step "${IMAGE}" \
  certificate inspect /home/step/certs/intermediate_ca.crt --short
fingerprint="$(openssl x509 -in "${ROOT_PEM}" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true)"
[[ -n "${fingerprint}" ]] && printf '  root SHA256 %s   (compare with what --mint printed)\n' "${fingerprint}"
printf '  root cert   %s   (Caddy trusts this; so should every device)\n' "${ROOT_PEM#"${REPO_ROOT}"/}"
printf '\nNext:\n'
printf '  make secrets-edit STACK=sensitive     STEPCA_PASSWORD must be the password --mint was given\n'
printf '  make up STACK=sensitive\n\n'
