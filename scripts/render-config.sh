#!/usr/bin/env bash
#
# Decrypt secrets and render the config files that cannot take environment
# variables at runtime.
#
# snmp_exporter reads its config once at startup and does no variable
# expansion, so the community strings have to be substituted into a real file.
# That file is written to a gitignored .rendered/ directory and is the only
# thing the container mounts — the tracked snmp.yaml keeps its ${PLACEHOLDERS}.
#
# Usage: scripts/render-config.sh [stack]      (default: observability)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:-observability}"
STACK_DIR="${REPO_ROOT}/stacks/${STACK}"
SECRETS_FILE="${REPO_ROOT}/secrets/${STACK}.sops.yaml"

# shellcheck source=secrets-env.sh
source "${REPO_ROOT}/scripts/secrets-env.sh"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }

[[ -d "${STACK_DIR}" ]] || die "no such stack: ${STACK_DIR}"

# ---------------------------------------------------------------------------
# Certificates must exist before anything mounts them
#
# compose.yaml bind-mounts files out of the gitignored certificates/ at
# the repository root. Docker does not fail on a missing bind-mount source — it
# creates a DIRECTORY. So a clean clone that skipped `make certs` starts a stack
# where Prometheus has a directory where its ca_file should be and Grafana has
# directories for its cert and key, and the first symptom is a TLS error inside
# a container rather than "you skipped a step". The quick start omitted `make
# certs` for long enough that this was the documented path (#69).
#
# Same reasoning as the ${RENDER_UID:?} guards in compose.yaml: the failure is
# silent, retried forever by `restart: unless-stopped`, and reads as a fault in
# something other than the step that was missed.
#
# The list is scraped from compose.yaml rather than repeated here so the two
# cannot drift — the same trick seed-validation-env.sh uses for the ${VAR:?}
# guards. Anchored on the mount-list item, not on the path fragment: two
# comments in compose.yaml contain the string "certificates/" and a looser
# pattern reports them as missing files. That exact mistake is recorded in the
# alertmanager url_file cross-check below, where a bare `secrets/[a-z_]+`
# matched this script's own header comment.
# ---------------------------------------------------------------------------
absent=()
clobbered=()
while read -r cert; do
  [[ -n "${cert}" ]] || continue
  [[ -f "${REPO_ROOT}/${cert}" && -s "${REPO_ROOT}/${cert}" ]] && continue
  # Split by kind, because the two need different fixes. -f is what separates
  # them: it is false for a directory where -e and -s are both true. gen-certs.sh
  # guards on -s, so against a Docker-created directory it reports "already
  # exists — pass --force" and --force does not help either. Telling someone to
  # run `make certs` without saying to remove the directories first walks them
  # straight into that.
  if [[ -d "${REPO_ROOT}/${cert}" ]]; then
    clobbered+=("${cert}")
  else
    absent+=("${cert}")
  fi
done < <(grep -oE '^[[:space:]]*-[[:space:]]*\.\./\.\./certificates/[^:]+:' \
           "${STACK_DIR}/compose.yaml" 2>/dev/null \
         | sed 's|^[^.]*\.\./\.\./||; s|:$||' | sort -u)
# Reported with die's multi-line form rather than a heredoc: the repo's
# .editorconfig rejects tabs, and <<- strips only tabs. gen-certs.sh already
# reports its clobber guards this way.
if ((${#clobbered[@]})); then
  die "these are directories, not certificates:
$(printf '  %s\n' "${clobbered[@]}")

Docker creates a directory when a bind-mount source does not exist, so this is
what \`make up\` leaves behind when the certificates were never generated. They
have to be removed before the certificates can be issued: gen-certs.sh tests for
an existing certificate with -s, which is true of a directory, so it would
report \"already exists\" and refuse — and --force would not help either.

  rmdir ${clobbered[*]}

Then issue them — see docs/runbooks/generate-certificates.md."
fi

if ((${#absent[@]})); then
  die "compose.yaml mounts these certificates, which are missing or empty:
$(printf '  %s\n' "${absent[@]}")

Grafana serves https from the leaf and Prometheus verifies it with the CA, so
the stack cannot start without them. Generate them with:

  make certs ARGS=--ca
  make certs ARGS=\"--host grafana.matrix.elysium --ip 10.0.99.20 --dns grafana\"

Full procedure in docs/runbooks/generate-certificates.md."
fi
unset absent clobbered cert

# ---------------------------------------------------------------------------
# Decrypt. Keep the plaintext in a variable, never in a file.
#
# The decrypt-and-parse lives in scripts/secrets-env.sh because snmp-verify.sh
# needs the same values, and two copies of a hand-rolled YAML parser will
# eventually disagree about some edge case — at which point verification passes
# for a string that this script renders differently. Sourcing also drops the
# `export` this loop used to do: the secrets are read below via ${!var} in this
# process, and exporting them handed every child (mkdir, cat, grep, chmod, id)
# a copy of all four communities for no reason.
# ---------------------------------------------------------------------------
info "decrypting $(basename "${SECRETS_FILE}")"
load_secrets "${STACK}"

# The two inputs whose presence decides what this stack needs. Declared here
# rather than beside the blocks that render them, because the required-key list
# below is built from whether they exist.
SNMP_SRC="${STACK_DIR}/snmp-exporter/snmp.yaml"
AM_CONFIG="${STACK_DIR}/alertmanager/alertmanager.yaml"

# ---------------------------------------------------------------------------
# What this stack requires
#
# Derived from the stack, not listed for one of them. Every render below is
# already guarded by `[[ -f ... ]]`, so the script has always coped with a
# stack that has no snmp-exporter — but this list was a flat array of all ten
# keys, which demanded four SNMP communities and four Alertmanager URLs from
# any stack at all. `make render STACK=lab` died on a lab that runs neither,
# naming secrets that stack has no use for.
#
# The Grafana half is read out of the stack's own compose.yaml: a ${VAR:?}
# guard IS the declaration that the service cannot start without it, so a
# second copy here could only ever drift from it. Same derivation
# seed-validation-env.sh uses against the same guards, for the same reason.
# The three excluded names are the ones THIS script writes into .env further
# down — they are guarded in compose.yaml but they are not secrets, and asking
# SOPS for them would fail every render.
#
# For `stacks/observability` this produces the identical ten names the flat
# array held, which is the property that makes the change safe: the two Grafana
# keys come from its compose guards, and both conditionals below are true.
# ---------------------------------------------------------------------------
REQUIRED=()
while read -r var; do
  [[ -n "${var}" ]] || continue
  case "${var}" in RENDER_UID | RENDER_GID | LOG_READ_GID) continue ;; esac
  REQUIRED+=("${var}")
done < <(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:\?' "${STACK_DIR}/compose.yaml" \
         | sed 's/^\${//; s/:?$//' | sort -u)

# The SNMP community names stay written out rather than derived from the
# placeholders in snmp.yaml, and that is deliberate. scripts/snmp-targets.sh
# --check asserts this array against the device inventory by grepping for each
# name on a line of its own — it is one of the five copies of the device list
# that check exists to hold together, and deriving it here would remove the
# copy rather than the drift, leaving --check asserting nothing. Keep the
# one-name-per-line shape.
if [[ -f "${SNMP_SRC}" ]]; then
  REQUIRED+=(
    SNMP_COMMUNITY_PFSENSE
    SNMP_COMMUNITY_APC
    SNMP_COMMUNITY_MOKERLINK
    SNMP_COMMUNITY_ILO
  )
fi

# One entry per AM_CHANNELS entry below; the pairing is asserted after they are
# rendered, so a channel added there without a key here fails at deploy time.
if [[ -f "${AM_CONFIG}" ]]; then
  REQUIRED+=(
    ALERTMANAGER_WEBHOOK_URL
    ALERTMANAGER_URGENT_WEBHOOK_URL
    ALERTMANAGER_SECURITY_WEBHOOK_URL
    ALERTMANAGER_HEARTBEAT_URL
  )
fi

missing=()
for var in "${REQUIRED[@]}"; do
  [[ -n "${!var:-}" ]] || missing+=("${var}")
done
((${#missing[@]} == 0)) || die "missing keys in ${SECRETS_FILE}: ${missing[*]}"

# ---------------------------------------------------------------------------
# Render snmp.yaml
# ---------------------------------------------------------------------------
SNMP_OUT_DIR="${STACK_DIR}/snmp-exporter/.rendered"
if [[ -f "${SNMP_SRC}" ]]; then
  info "rendering snmp.yaml"
  mkdir -p "${SNMP_OUT_DIR}"
  chmod 700 "${SNMP_OUT_DIR}"

  # Substitution is done with bash parameter expansion rather than envsubst or
  # sed. envsubst lives in gettext-base, which is not guaranteed on a minimal
  # server install, and sed would mangle any community string containing / & or
  # a backslash. This also touches only the four SNMP_COMMUNITY_* names, so no
  # other ${...} sequence in 14k lines of OID definitions can be affected.
  #
  # bash 5.2 enables patsub_replacement by default, which makes an unescaped '&'
  # in the replacement expand to the matched text — so a community string
  # containing '&' would silently render as the placeholder it was meant to
  # replace. Disabling it makes the replacement literal. The redirect keeps this
  # a no-op on bash < 5.2, where the option does not exist.
  shopt -u patsub_replacement 2>/dev/null || true

  # The substitution list is derived from REQUIRED rather than repeated, so
  # adding a device means editing one list instead of two that silently drift.
  # The prefix filter is what makes that safe: a REQUIRED entry that is not an
  # SNMP community has no ${...} placeholder in snmp.yaml, so substituting it
  # is a no-op. And a name in REQUIRED whose placeholder is misspelled in
  # snmp.yaml is still caught by the independent grep below.
  snmp_content="$(cat "${SNMP_SRC}")"
  for var in "${REQUIRED[@]}"; do
    [[ "${var}" == SNMP_COMMUNITY_* ]] || continue
    snmp_content="${snmp_content//\$\{${var}\}/${!var}}"
  done

  umask 077
  printf '%s\n' "${snmp_content}" > "${SNMP_OUT_DIR}/snmp.yaml"
  unset snmp_content
  chmod 600 "${SNMP_OUT_DIR}/snmp.yaml"

  # shellcheck disable=SC2016  # matching the literal text "${SNMP_COMMUNITY..."
  if grep -q '\${SNMP_COMMUNITY' "${SNMP_OUT_DIR}/snmp.yaml"; then
    die "unsubstituted placeholders remain in the rendered snmp.yaml"
  fi
fi

# ---------------------------------------------------------------------------
# Render the Alertmanager receiver URLs
#
# Alertmanager does not expand environment variables in its config. `url_file`
# is the supported mechanism, so each URL is written to a file that compose
# mounts read-only.
#
# One file per channel, driven by this list rather than three copies of the
# same four lines — the three receivers in alertmanager.yaml were three names
# for one URL until #66, and the shape that made that easy was a block written
# out once and never generalised. Adding a fourth channel is now one entry here
# plus one in REQUIRED above.
#
# The variable name is not derived from the filename (or vice versa): the
# default channel's variable predates the other two and is not
# ALERTMANAGER_DEFAULT_WEBHOOK_URL, and renaming a key in an encrypted file to
# suit a loop is a worse trade than writing the pair out.
# ---------------------------------------------------------------------------
AM_CHANNELS=(
  "ALERTMANAGER_WEBHOOK_URL:webhook_url"
  "ALERTMANAGER_URGENT_WEBHOOK_URL:urgent_url"
  "ALERTMANAGER_SECURITY_WEBHOOK_URL:security_url"
  "ALERTMANAGER_HEARTBEAT_URL:heartbeat_url"
)
AM_OUT_DIR="${STACK_DIR}/alertmanager/.rendered"
if [[ -f "${AM_CONFIG}" ]]; then
  info "rendering ${#AM_CHANNELS[@]} alertmanager receiver URL(s)"
  mkdir -p "${AM_OUT_DIR}"
  chmod 700 "${AM_OUT_DIR}"
  for channel in "${AM_CHANNELS[@]}"; do
    var="${channel%%:*}"
    file="${channel##*:}"
    # No trailing newline: Alertmanager takes the file's whole content as the
    # URL, and a newline in a URL is a delivery error rather than a warning.
    printf '%s' "${!var}" > "${AM_OUT_DIR}/${file}"
    chmod 600 "${AM_OUT_DIR}/${file}"
  done
  unset channel var file

  # Every url_file alertmanager.yaml names must be one this loop just wrote. A
  # url_file that does not exist is not a config error — Alertmanager reads it
  # at notify time, so the stack starts, amtool check-config passes, and the
  # first real alert is the thing that discovers the missing file. Adding a
  # receiver and forgetting AM_CHANNELS now fails here at deploy time instead.
  while read -r wanted; do
    [[ -f "${AM_OUT_DIR}/${wanted}" ]] \
      || die "alertmanager.yaml reads ${wanted}, which nothing in AM_CHANNELS renders"
  #
  # Anchored on `url_file:` rather than on the path fragment. A bare
  # `secrets/[a-z_]+` also matched `secrets/observability.sops.yaml` in this
  # file's own header comment, and reported the header as a missing channel.
  done < <(grep -oE 'url_file:[[:space:]]*/etc/alertmanager/secrets/[a-z_]+' \
             "${AM_CONFIG}" \
           | sed 's|.*/||' | sort -u)
fi

# ---------------------------------------------------------------------------
# Write .env for compose interpolation
#
# Only the values compose actually interpolates are written here. The SNMP
# communities go into the rendered snmp.yaml and the receiver URLs into their
# own files under alertmanager/.rendered; copying them into .env as well would
# spread the same secret across two files for no benefit.
# ---------------------------------------------------------------------------
COMPOSE_VARS=(GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD GRAFANA_RENDERER_TOKEN)
ENV_FILE="${STACK_DIR}/.env"
info "writing $(basename "${STACK_DIR}")/.env"

{
  echo "# Generated by scripts/render-config.sh — do not edit, do not commit."
  echo "# Non-sensitive defaults come from .env.example; secrets from SOPS."
  if [[ -f "${STACK_DIR}/.env.example" ]]; then
    grep -vE '^\s*#|^\s*$' "${STACK_DIR}/.env.example" || true
  fi

  # The rendered secrets above are 0600 and owned by whoever ran this script.
  # The two containers that mount them (alertmanager, snmp-exporter) must run as
  # that same UID or they cannot read their own config. Hardcoding 65534 here is
  # what left snmp-exporter crash-looping on "permission denied" for two weeks —
  # silently, because `restart: unless-stopped` retries forever and a container
  # that is always restarting looks alive.
  printf 'RENDER_UID=%s\n' "$(id -u)"
  printf 'RENDER_GID=%s\n' "$(id -g)"

  # Alloy labels every log and metric it produces with constants.hostname,
  # which inside a container is the CONTAINER ID unless compose sets one.
  # Left alone, `host` is a 12-character hex string that changes every time the
  # container is recreated — so it identifies nothing, and each redeploy mints a
  # new label value and therefore a new Loki stream. Observed: two values for
  # one machine after a single restart, and `sum by (host)` in the auth and
  # system alert rules grouping by something meaningless.
  #
  # Written here rather than hardcoded in compose.yaml so that config.alloy and
  # the compose file stay identical on every monitored host, which is the
  # property ADR-0003 leans on.
  printf 'ALLOY_HOSTNAME=%s\n' "$(hostname)"

  # Alloy holds no capabilities since #188, so root inside it is subject to file
  # permissions like anyone else — and /var/log/auth.log and /var/log/syslog are
  # syslog:adm 0640, owned by neither. Joining the group that owns them is what
  # keeps the auth and syslog file sources in config.alloy readable; without it
  # they fail and most of security.rules.yaml goes quiet, which is the kind of
  # silence #62 and #63 were both about.
  #
  # Derived from the file rather than hardcoded to adm's 4, because compose.yaml
  # and config.alloy are deployed identically to every monitored host and the
  # owning group is a property of the host's distribution, not of this
  # repository. Falls back to 4 only if the file is absent, which on a host with
  # no syslog is the case where the source has nothing to read anyway.
  printf 'LOG_READ_GID=%s\n' "$(stat -c '%g' /var/log/syslog 2>/dev/null || echo 4)"
  for var in "${COMPOSE_VARS[@]}"; do
    [[ -n "${!var:-}" ]] && printf '%s=%s\n' "${var}" "${!var}"
  done
} > "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

info "done — ${STACK} is ready to start"
