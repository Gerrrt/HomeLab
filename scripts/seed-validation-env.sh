#!/usr/bin/env bash
#
# Write a throwaway .env that satisfies compose.yaml's ${VAR:?} guards.
#
# The guards exist so a missing secret fails loudly at deploy time rather than
# starting a stack with defaults. Validation still has to get past them, so both
# CI and scripts/validate.sh need an .env holding values that are never
# deployed. That list used to be written out twice — once in
# .github/workflows/ci.yml and once in scripts/validate.sh — and it drifted the
# first time it changed: the commit adding the RENDER_UID/RENDER_GID guards
# updated only validate.sh, so it passed locally and failed in CI.
#
# Nothing written here is a secret and nothing here is ever deployed. The values
# only need to exist.
#
# Usage: scripts/seed-validation-env.sh <output-path> [stack]   (default: observability)
#
# The caller owns the output path and its cleanup: CI writes the gitignored
# stacks/<stack>/.env, validate.sh writes an mktemp file it removes on exit.
# Keeping lifetime out here is what lets one script serve both.
#
# The stack argument matters because the guard list below is derived from that
# stack's compose.yaml. Seeding `lab` from `observability`'s guards would prove
# nothing about the file being validated — and a guard added to one stack and
# not the other would pass here and fail in compose, which is the drift this
# script was written to stop (#263).

set -euo pipefail

OUT="${1:?usage: seed-validation-env.sh <output-path> [stack]}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${REPO_ROOT}/stacks/${2:-observability}"
[[ -f "${STACK}/compose.yaml" ]] || {
  printf 'no such stack: %s\n' "${STACK}" >&2
  exit 1
}

# A stack may legitimately have no .env.example — every tunable in its
# compose.yaml can carry a default. The guards below are what must be satisfied,
# and they are read from compose.yaml, not from here.
: > "${OUT}"
[[ -f "${STACK}/.env.example" ]] && cat "${STACK}/.env.example" > "${OUT}"
{
  echo "GRAFANA_ADMIN_PASSWORD=validation-only"
  echo "GRAFANA_RENDERER_TOKEN=validation-only"
  # speedtest-tracker refuses an APP_KEY that is not base64 of 32 bytes, so
  # the placeholder has that shape; it is all zeroes and encrypts nothing.
  echo "SPEEDTEST_APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  # Distinct from each other, because the ingest proxy's map refuses a
  # duplicate key at start and a boot of it should get past that.
  echo "INGEST_TOKEN_ORACLE=validation-only-oracle"
  echo "INGEST_TOKEN_TRINITY=validation-only-trinity"
  echo "INGEST_TOKEN_SARUMAN=validation-only-saruman"
  echo "INGEST_TOKEN_READER=validation-only-reader"
  echo "INGEST_TOKEN_ODIN=validation-only-odin"
  echo "INGEST_TOKEN_PHOENIX=validation-only-phoenix"
  echo "INGEST_TOKEN_FENRIR=validation-only-fenrir"
  echo "INGEST_TOKEN_GOLEM=validation-only-golem"
  echo "INGEST_TOKEN_EDEN=validation-only-eden"
  echo "INGEST_TOKEN=validation-only-client"
  echo "HOMEPAGE_PROMETHEUS_TOKEN=validation-only"
  echo "HA_PROMETHEUS_AUTHORIZATION=Bearer validation-only"
  echo "STEPCA_PASSWORD=validation-only"
  echo "ADGUARD_ADMIN_PASSWORD_HASH=validation-only"
  echo "IMMICH_DB_PASSWORD=validation-only"
  echo "PAPERLESS_SECRET_KEY=validation-only"
  echo "PAPERLESS_DBPASS=validation-only"
  echo "PAPERLESS_ADMIN_PASSWORD=validation-only"
  echo "STIRLING_ADMIN_PASSWORD=validation-only"
  echo "VAULTWARDEN_ADMIN_TOKEN=validation-only"
  echo "LINKDING_SUPERUSER_PASSWORD=validation-only"
  echo "HOMEPAGE_IMMICH_API_KEY=validation-only"
  echo "HOMEPAGE_PAPERLESS_TOKEN=validation-only"
  # ntfy validates these at start and exits on a malformed one, so a boot of
  # it (check_hardened_boot.sh) needs them well-formed: a real bcrypt hash —
  # of the string "validation-only", from the pinned image's `ntfy user
  # hash` — with every `$` doubled for compose, as render-config.sh writes
  # them, a token of the `tk_` + 29 shape, and three distinct topics.
  # shellcheck disable=SC2016  # the $$ are for compose, not the shell
  echo 'NTFY_ALERTMANAGER_PASSWORD_HASH=$$2a$$10$$3egG3fvpHgBzCUcV7m7xE.1aiIfVdTQxRjW0kYzefkJ8YPnyiaYWq'
  # shellcheck disable=SC2016
  echo 'NTFY_PHONE_PASSWORD_HASH=$$2a$$10$$3egG3fvpHgBzCUcV7m7xE.1aiIfVdTQxRjW0kYzefkJ8YPnyiaYWq'
  echo "NTFY_ALERTMANAGER_TOKEN=tk_validationonlyvalidationonly0"
  echo "NTFY_TOPIC_ALERTS=validation-alerts"
  echo "NTFY_TOPIC_URGENT=validation-urgent"
  echo "NTFY_TOPIC_SECURITY=validation-security"
  echo "MINIFLUX_DBPASS=validation-only"
  echo "MINIFLUX_ADMIN_PASSWORD=validation-only"
  echo "INDEXER_PASSWORD=validation-only"
  echo "DASHBOARD_PASSWORD=validation-only"
  echo "API_PASSWORD=validation-only"
  echo "VELOCIRAPTOR_INITIAL_ADMIN_PASSWORD=validation-only"
  echo "BLOODHOUND_DB_PASSWORD=validation-only"
  echo "BLOODHOUND_ADMIN_PASSWORD=Validation-only-1!"
  echo "BLOODHOUND_JWT_SIGNING_KEY=validation-only"
  # RENDER_UID/GID are written to .env by render-config.sh from the deploying
  # user, so they are host-specific and deliberately absent from .env.example.
  echo "RENDER_UID=65534"
  echo "RENDER_GID=65534"
  # Likewise host-specific: render-config.sh reads it off /var/log/syslog.
  echo "LOG_READ_GID=4"
} >> "${OUT}"

# Sharing this script stops the two callers drifting from each other. This check
# stops both of them drifting from compose.yaml: a newly added ${VAR:?} guard
# fails here, naming the variable, instead of surfacing later as an opaque
# compose interpolation error in whichever caller runs first.
#
# The guard list comes from scripts/compose-guards.sh, which reads the parsed
# YAML: this grepped the raw file, so a comment in compose.yaml that mentioned
# the guard syntax was read as a guard and demanded a value for a variable that
# does not exist (#107).
#
# Command substitution and not `while read < <(...)`: a process substitution's
# exit status is not the loop's, so a failure over there would arrive here as an
# empty guard list and this check would pass by finding nothing to check.
if ! GUARDS="$("${REPO_ROOT}/scripts/compose-guards.sh" "${STACK}/compose.yaml")"; then
  printf 'could not read the guards from %s — see above\n' \
    "${STACK}/compose.yaml" >&2
  exit 1
fi

missing=()
while read -r var; do
  [[ -n "${var}" ]] || continue
  grep -qE "^${var}=" "${OUT}" || missing+=("${var}")
done <<< "${GUARDS}"

if ((${#missing[@]})); then
  printf 'compose.yaml guards %s, which the validation .env does not set.\n' \
    "${missing[*]}" >&2
  printf 'Add a throwaway value for it to %s\n' "${BASH_SOURCE[0]}" >&2
  exit 1
fi
