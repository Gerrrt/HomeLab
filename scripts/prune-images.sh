#!/usr/bin/env bash
#
# Remove Docker images no container uses, on an agent host (odin, alexander,
# oracle, trinity). Installed as /usr/local/bin/homelab-prune-images by
# scripts/install-agent-collectors.sh and run weekly by
# systemd/agent/homelab-prune-images.timer.
#
# WHY. Nothing removed superseded images on the agent hosts. Every Dependabot
# bump pulls a new digest and leaves the old one behind, and on 2026-10-01
# odin's 30 GB root was at 98%, 7.8 GB of it images no container referenced.
# The monitoring host has had the same job since 2026-09-29, as `make
# prune-images` (systemd/homelab-prune-images.service). It cannot be reused
# here, because an agent host has no Makefile and often no checkout at the path
# that unit names.
#
# SAFE BY CONSTRUCTION. `docker image prune -a` removes only images no
# container references, running or stopped. An image a stack still needs but
# is not running, such as a profile-only one like soc's certs generator, is
# removed too, and `docker compose up` pulls it again when it is next wanted.
# Every image in this repository is pinned by digest, so what comes back is
# byte for byte what left.
#
# The before and after are printed so the journal records what each run
# reclaimed, the same as the monitoring host's.
#
# Since #1027 this is the backstop, not the main path. `make up` removes the
# images its own deploy superseded as soon as the stack is healthy
# (scripts/prune_superseded_images.py), because a week was too long: a Wazuh
# re-pin on a Tuesday left odin's root at 99%, short of the room the next pull
# needs. This still catches anything that path does not, such as a stack
# that was removed outright.

set -euo pipefail

images() { docker system df --format '{{.Type}}: {{.Size}} ({{.Reclaimable}} reclaimable)' | grep '^Images'; }

images
docker image prune -a -f | tail -1
images
