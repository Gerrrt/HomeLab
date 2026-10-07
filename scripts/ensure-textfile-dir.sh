#!/usr/bin/env bash
#
# Make sure /var/lib/node_exporter/textfile_collector exists on this host, for a
# stack whose Alloy reads it. Run by `make up` before the stack starts.
#
# WHY. Every Alloy that mounts the host's / at /rootfs runs node_exporter's
# textfile collector against /rootfs/var/lib/node_exporter/textfile_collector
# (stacks/observability/alloy/config.alloy). While that directory is missing,
# node_textfile_scrape_error sits at 1 and Alloy logs level=error once a
# minute. Worse, scripts/install-agent-collectors.sh refuses a host without it,
# so no collector can be installed there.
#
# Two things created it: scripts/deploy-agent.sh, for the hosts whose Alloy it
# deploys, and a manual step in build-the-sensor-guest.md for fenrir. Nothing
# created it for a stack that runs its own Alloy, so alexander (lab), odin (soc)
# and eden (bloodhound) all came up without it. That was found on 2026-10-07,
# while #850's prune job was installed on fenrir, which was missing it too.
#
# HOW. The same way deploy-agent.sh does it: one mkdir in a throwaway container
# from the pinned Alloy image, with /var/lib bound in. Running as a member of
# the docker group is already root on the host, so this needs no sudo, and the
# image is the one the stack is about to run, so nothing extra is pulled. A
# directory that already exists is left alone, without starting a container.
#
# A stack whose compose.yaml does not mount /rootfs has no textfile collector,
# and this is a no-op for it.
#
# Usage: scripts/ensure-textfile-dir.sh STACK
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:?usage: $0 STACK}"
COMPOSE_FILE="${REPO_ROOT}/stacks/${STACK}/compose.yaml"
DIR=/var/lib/node_exporter/textfile_collector

[[ -f "$COMPOSE_FILE" ]] || { echo "error: no ${COMPOSE_FILE}" >&2; exit 1; }

if ! grep -q ':/rootfs' "$COMPOSE_FILE"; then
  exit 0
fi

if [[ -d "$DIR" ]]; then
  exit 0
fi

IMAGE="$("${REPO_ROOT}/scripts/image-for.sh" alloy)"
docker run --rm -v /var/lib:/hostvarlib --entrypoint sh "$IMAGE" \
  -c 'mkdir -p /hostvarlib/node_exporter/textfile_collector && chmod 0755 /hostvarlib/node_exporter /hostvarlib/node_exporter/textfile_collector'

# Assert the result rather than trusting the exit status: the point is that
# Alloy can read the directory, not that a container said it made it.
[[ -d "$DIR" ]] || { echo "error: ${DIR} still missing after creating it" >&2; exit 1; }
echo "created ${DIR} (stack ${STACK} reads it through /rootfs)"
