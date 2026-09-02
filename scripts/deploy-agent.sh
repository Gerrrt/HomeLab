#!/usr/bin/env bash
#
# Deploy, or redeploy, the Alloy agent on a monitored host.
#
#   ./scripts/deploy-agent.sh [--runtime docker|native] [--monitoring-host IP]
#                             [--no-verify] <user@host>
#
# One command, two runtimes, same result: the agent on the target runs the
# Alloy version compose.yaml pins, with the hardening compose.yaml applies, on
# the agent config this checkout holds. Run it again after a config change or
# an image bump and the host converges. It is safe to run from macOS — the
# local half is ssh, tar, cksum and curl, and every host-side step runs in one
# bash heredoc on the Linux target.
#
# Why this exists
# ---------------
# `oracle` was deployed on 2026-08-30 by hand from the runbook, and on
# 2026-09-01 it was found running:
#
#   - grafana/alloy:v1.18.1, while compose.yaml pinned v1.19.2 — the runbook
#     said "keep the tag in step" and nothing did;
#   - --privileged, no cap_drop, no cgroupns, no group_add — the shape #188
#     removed from compose.yaml a day after the host was deployed, and the
#     runbook still described;
#   - a config from the day it was copied, missing the self-scrape block (#81)
#     and the textfile collector (#77) — so `oracle-alloy` never existed in
#     Prometheus and nobody noticed, because nothing compared the two files;
#   - no volume for /var/lib/alloy/data, so every `docker rm` discarded the
#     WAL and the positions file;
#   - and a verification step in the runbook — `docker logs ... | grep -c
#     level=error` — that could never fail, because Alloy logs to stderr and
#     the pipe only carried stdout.
#
# Every one of those is a copy of compose.yaml drifting from compose.yaml. The
# fix is to not copy: the image comes from scripts/image-for.sh, the flags
# below are compose.yaml's `alloy` service written out as `docker run`, and
# the config is whatever stacks/observability/alloy/ holds right now.
#
# Two runtimes
# ------------
# docker  The compose service as `docker run`. Config in a named volume
#         (alloy-config) rather than a root-owned bind mount, so an account in
#         the docker group needs no sudo, and so that "edit the file and forget
#         to restart" cannot happen: the container is always recreated, and the
#         running config is the shipped config by construction.
# native  The .deb from the Alloy GitHub release matching the compose tag, for
#         a host that should not run Docker — Saruman is a Proxmox hypervisor,
#         whose own firewall ADR-0014 relies on and whose iptables Docker would
#         rewrite. No apt repository, deliberately: a repository installs
#         whatever is newest, and the version would then live in two places.
#         A Dependabot bump reaches a native host the same way it reaches a
#         Docker host — by running this again.
#
# What ships where
# ----------------
# config.alloy always; docker.alloy only to the docker runtime; syslog.alloy
# never — it is the listener morpheus sends to, and it belongs on the
# monitoring host alone. The header of alloy/config.alloy has the reasoning.
#
# What it does not do
# -------------------
# Firewall rules. A host outside VLAN 99 needs a pass to 10.0.99.20 on 9090
# and 3100 before its pushes get anywhere; the runbook says where that rule
# goes and what it must sit above. This script will tell you the pushes are
# failing, which is the most it can know.
#
# Verification is the part the runbook got wrong, so it is the part this
# script is strict about: the process must stay up for ten consecutive
# seconds, and then a full sixty-second window of its log must contain zero
# level=error lines — read from stderr, where they actually are. The first
# minute after a fresh deploy is *expected* to be noisy (Loki rejects every
# container log line older than its retention window), so the gate waits for
# the noise to stop rather than for it to never start.

set -euo pipefail

info()  { printf '\033[0;34m→\033[0m %s\n' "$*" >&2; }
pass()  { printf '\033[0;32m✓\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[0;33m!\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[0;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-1}"
}

RUNTIME=""
MON="10.0.99.20"
VERIFY=1
TARGET=""

while (($#)); do
  case "$1" in
    --runtime)          RUNTIME="${2:-}"; shift 2 ;;
    --monitoring-host)  MON="${2:-}"; shift 2 ;;
    --no-verify)        VERIFY=0; shift ;;
    -h|--help)          usage 0 ;;
    -*)                 die "unknown flag: $1" ;;
    *)                  [[ -z "$TARGET" ]] || die "one target only (got '$TARGET' and '$1')"
                        TARGET="$1"; shift ;;
  esac
done
[[ -n "$TARGET" ]] || usage
case "$RUNTIME" in ""|docker|native) ;; *) die "--runtime must be docker or native, not '$RUNTIME'" ;; esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOY_DIR="${REPO_ROOT}/stacks/observability/alloy"
[[ -f "${ALLOY_DIR}/config.alloy" ]] || die "no config.alloy under ${ALLOY_DIR}"

# The one place a version lives is compose.yaml; both runtimes read it from
# there. `--tag-only` strips the digest for the .deb URL; the docker runtime
# keeps it, so a remote host runs exactly the bytes the monitoring host does.
IMAGE="$("${REPO_ROOT}/scripts/image-for.sh" alloy)"
tag="$("${REPO_ROOT}/scripts/image-for.sh" --tag-only alloy)"
VERSION="${tag##*:v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not read a version out of '${tag}'"

LOKI_URL="http://${MON}:3100/loki/api/v1/push"
PROMETHEUS_REMOTE_WRITE_URL="http://${MON}:9090/api/v1/write"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET")

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
info "connecting to ${TARGET}"
HOST="$("${SSH[@]}" hostname 2>/dev/null)" \
  || die "cannot reach ${TARGET} (BatchMode: the key must already be authorised)"
[[ -n "$HOST" ]] || die "${TARGET} returned an empty hostname"

if [[ -z "$RUNTIME" ]]; then
  RUNTIME="$("${SSH[@]}" 'command -v docker >/dev/null 2>&1 && echo docker || echo native')"
  info "runtime not given; ${HOST} has $([[ $RUNTIME == docker ]] && echo "a Docker socket" || echo "no docker binary") → ${RUNTIME}"
fi

# Which files this host gets. Never syslog.alloy — see the header.
FILES=(config.alloy)
[[ "$RUNTIME" == docker ]] && FILES+=(docker.alloy)

pass "target ${HOST} · runtime ${RUNTIME} · alloy ${VERSION} · files ${FILES[*]}"

# ---------------------------------------------------------------------------
# Stage the config on the host and prove it arrived intact
# ---------------------------------------------------------------------------
STAGE="$("${SSH[@]}" 'mktemp -d /tmp/alloy-deploy.XXXXXX')"
[[ "$STAGE" == /tmp/alloy-deploy.* ]] || die "unexpected stage directory '${STAGE}'"
cleanup() { "${SSH[@]}" "rm -rf '${STAGE}'" >/dev/null 2>&1 || true; }
trap cleanup EXIT

tar -C "$ALLOY_DIR" -cf - "${FILES[@]}" | "${SSH[@]}" "tar -C '${STAGE}' -xf -"

# A truncated config does not fail loudly — Alloy starts and collects less —
# so the copy is checked, not assumed. cksum is POSIX and prints the same on
# macOS and Linux; sha256sum is not on macOS and shasum is not on a minimal
# Debian, so neither is used.
for f in "${FILES[@]}"; do
  local_sum="$(cksum < "${ALLOY_DIR}/${f}")"
  remote_sum="$("${SSH[@]}" "cksum < '${STAGE}/${f}'")"
  [[ "$local_sum" == "$remote_sum" ]] || die "${f} differs after copy (local ${local_sum}, remote ${remote_sum})"
done
pass "staged ${FILES[*]} in ${STAGE}"

# ---------------------------------------------------------------------------
# Everything host-side, in one shell on the host
# ---------------------------------------------------------------------------
# The variables are expanded HERE, on purpose, and passed as an environment
# prefix rather than as positional arguments: scripts/check_image_pins.py reads
# this heredoc as shell and requires every `docker run`/`docker pull` in it to
# name $IMAGE, which it traces to image-for.sh above. Rename it and the check
# fails, which is the check working.
# shellcheck disable=SC2029
"${SSH[@]}" "IMAGE='${IMAGE}' VERSION='${VERSION}' STAGE='${STAGE}' RUNTIME='${RUNTIME}' LOKI_URL='${LOKI_URL}' PROMETHEUS_REMOTE_WRITE_URL='${PROMETHEUS_REMOTE_WRITE_URL}' bash -s" <<'REMOTE'
set -euo pipefail
info() { printf '\033[0;34m→\033[0m %s\n' "$*" >&2; }
pass() { printf '\033[0;32m✓\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Stay up for ten consecutive seconds. A process about to die on a bad config
# is briefly alive, so one sample proves nothing — the same rule
# reload-config.sh applies on the monitoring host.
require_stable() {  # $1 = command that exits 0 while the agent is running
  local stable=0 deadline=$((SECONDS + 60))
  while ((stable < 10)); do
    if eval "$1"; then stable=$((stable + 1)); else stable=0; fi
    ((SECONDS < deadline)) || die "agent did not stay up for ten seconds — its config does not load; see the log above"
    sleep 1
  done
}

# Then a full minute with no level=error. The window slides: a fresh deploy
# floods "timestamp too old" for the first minute or so while it catches up on
# old container logs, and that is expected; what must happen is that it stops.
#
# Two signatures are not counted, and the list is meant to stay this short:
#
#   rootDiskErr   cAdvisor walking /var/lib/docker/overlay2 to size each
#                 container's writable layer, which root without
#                 DAC_READ_SEARCH cannot do. A cost of #188 that was never
#                 written down: the monitoring host logs it ~80 times in six
#                 hours and has since the capability drop. It is partial —
#                 container_fs_usage_bytes still exists for every container —
#                 and the one container_fs_* series a dashboard charts is the
#                 blkio write counter, which does not come from that walk. So
#                 it is noise, and noise every few minutes would make this
#                 gate flaky rather than strict.
#   udev          node_exporter's diskstats collector looking for
#                 /run/udev/data, which is not mounted into the container.
#                 Logged once at startup, and inside the first window.
#
# Anything else is a failure, and it is printed, so a new benign line becomes a
# deliberate addition here rather than a silent one.
KNOWN_NOISE='rootDiskErr|disabling udev device properties'
require_quiet() {  # $1 = command printing the last 60s of the agent's log
  local deadline=$((SECONDS + 240)) errors
  info "waiting for a 60s window with no level=error (up to 4 min; the first minute is expected to be noisy)"
  sleep 60
  while :; do
    errors="$(eval "$1" | grep 'level=error' | grep -Evc "$KNOWN_NOISE" || true)"
    if [[ "$errors" == 0 ]]; then pass "no errors in the last 60s"; return; fi
    if ((SECONDS >= deadline)); then
      eval "$1" | grep 'level=error' | grep -Ev "$KNOWN_NOISE" | tail -5 >&2
      die "${errors} level=error line(s) in the last 60s after four minutes — not calling this done"
    fi
    sleep 10
  done
}

HOSTNAME_LABEL="$(hostname)"

case "$RUNTIME" in
docker)
  command -v docker >/dev/null 2>&1 || die "no docker on this host; use --runtime native"
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon as $(id -un) — is the account in the docker group?"

  info "pulling ${IMAGE}"
  docker pull "$IMAGE" >/dev/null

  # Two group IDs, both derived rather than written down, for the reasons
  # compose.yaml gives beside group_add: the group that owns the syslog files
  # is a property of the host's distribution, and the image's own alloy group
  # (473 today) is a property of the pinned image.
  LOG_GID="$(stat -c %g /var/log/syslog 2>/dev/null || echo 4)"
  ALLOY_GID="$(docker run --rm --entrypoint sh "$IMAGE" -c 'stat -c %g /var/lib/alloy')"
  [[ "$ALLOY_GID" =~ ^[0-9]+$ ]] || die "could not read the alloy group out of the image (got '${ALLOY_GID}')"

  # The config lives in a named volume, populated from the stage by the image
  # that is about to run it — no second image, nothing unpinned, no sudo. Stale
  # files are removed first so a host that stops being a Docker host does not
  # keep loading docker.alloy.
  docker volume create alloy-config >/dev/null
  docker volume create alloy-data >/dev/null
  docker run --rm -v alloy-config:/dst -v "${STAGE}:/src:ro" --entrypoint sh "$IMAGE" \
    -c 'rm -f /dst/*.alloy && cp /src/*.alloy /dst/ && chmod 0644 /dst/*.alloy'

  # node_exporter reads this on every scrape and logs level=error while it is
  # missing — which would hold the gate below shut forever. Same privilege
  # class as the volume step above: docker-group membership is root on the host
  # already, and this is one mkdir.
  docker run --rm -v /var/lib:/hostvarlib --entrypoint sh "$IMAGE" \
    -c 'mkdir -p /hostvarlib/node_exporter/textfile_collector && chmod 0755 /hostvarlib/node_exporter /hostvarlib/node_exporter/textfile_collector'

  info "recreating container alloy (log gid ${LOG_GID}, alloy gid ${ALLOY_GID}, host label ${HOSTNAME_LABEL})"
  docker rm -f alloy >/dev/null 2>&1 || true

  # compose.yaml's `alloy` service, flag for flag. Read that file's comments
  # before changing anything here; each line below has a measured reason there.
  # No --hostname: ALLOY_HOSTNAME does the labelling, and a container hostname
  # registers a DNS name (config.alloy header). No /var/lib/docker/containers:
  # nothing reads it (#188). 1514/udp is not published: syslog.alloy is not
  # shipped, so there is nothing listening.
  docker run -d --name alloy \
    --restart unless-stopped \
    --init \
    --pids-limit 1024 \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --cgroupns host \
    --group-add "$LOG_GID" \
    --group-add "$ALLOY_GID" \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    -e ALLOY_HOSTNAME="$HOSTNAME_LABEL" \
    -e LOKI_URL \
    -e PROMETHEUS_REMOTE_WRITE_URL \
    -v alloy-config:/etc/alloy:ro \
    -v alloy-data:/var/lib/alloy/data \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v /var/log:/var/log:ro \
    -v /:/rootfs:ro \
    -p 127.0.0.1:12345:12345 \
    "$IMAGE" run \
      --server.http.listen-addr=0.0.0.0:12345 \
      --storage.path=/var/lib/alloy/data \
      /etc/alloy >/dev/null

  require_stable "[[ \$(docker inspect -f '{{.State.Running}}' alloy 2>/dev/null) == true ]]"
  pass "alloy running: $(docker inspect -f '{{.Config.Image}} privileged={{.HostConfig.Privileged}} cgroupns={{.HostConfig.CgroupnsMode}} caps={{.HostConfig.CapDrop}}' alloy)"
  # 2>&1 is the whole point: Alloy logs to stderr, and without it this count
  # is always zero — see the header.
  require_quiet "docker logs --since 60s alloy 2>&1"
  ;;

native)
  SUDO=""
  if [[ "$(id -u)" != 0 ]]; then
    sudo -n true 2>/dev/null || die "not root and no passwordless sudo for $(id -un)"
    SUDO="sudo -n"
  fi
  command -v systemctl >/dev/null 2>&1 || die "no systemd on this host; the native runtime needs the packaged unit"
  command -v dpkg >/dev/null 2>&1 || die "not a Debian-family host; the native runtime installs a .deb"

  installed="$(dpkg-query -W -f='${Version}' alloy 2>/dev/null || true)"
  if [[ "$installed" == "${VERSION}-1" ]]; then
    pass "alloy ${VERSION} already installed"
  else
    arch="$(dpkg --print-architecture)"
    url="https://github.com/grafana/alloy/releases/download/v${VERSION}/alloy-${VERSION}-1.${arch}.deb"
    info "installing alloy ${VERSION} (${installed:-not installed}) from ${url}"
    curl -fsSL --retry 3 -o "${STAGE}/alloy.deb" "$url" \
      || die "download failed — check the release page for the asset name; nothing was changed"
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -q "${STAGE}/alloy.deb" >/dev/null
    pass "installed $(dpkg-query -W -f='alloy ${Version}' alloy)"
  fi

  # Only the files this host was sent. A stale docker.alloy left behind would
  # be loaded — a directory is one config — and log errors every interval.
  $SUDO install -d -m 0755 /etc/alloy /var/lib/node_exporter/textfile_collector
  $SUDO find /etc/alloy -maxdepth 1 -name '*.alloy' -delete
  $SUDO install -m 0644 -o root -g root "${STAGE}"/*.alloy /etc/alloy/

  # The unit reads this as its EnvironmentFile, so every line reaches the
  # process — CONFIG_FILE and CUSTOM_ARGS are the package's own, the rest are
  # what config.alloy reads from the environment. CONFIG_FILE is the DIRECTORY.
  # The debug UI stays on loopback, as it does everywhere else (ADR-0012).
  # ALLOY_ROOTFS=/ because there is no bind mount; the process reads the host.
  $SUDO tee /etc/default/alloy >/dev/null <<DEFAULTS
## Written by scripts/deploy-agent.sh from the HomeLab repository. Edits here
## are overwritten on the next deploy; change the repository instead.
CONFIG_FILE="/etc/alloy"
CUSTOM_ARGS="--server.http.listen-addr=127.0.0.1:12345"
RESTART_ON_UPGRADE=true
ALLOY_HOSTNAME="${HOSTNAME_LABEL}"
LOKI_URL="${LOKI_URL}"
PROMETHEUS_REMOTE_WRITE_URL="${PROMETHEUS_REMOTE_WRITE_URL}"
ALLOY_ROOTFS="/"
DEFAULTS

  # The journal is root:systemd-journal 0640 and /var/log/*.log is root:adm;
  # the package's user is in neither. Same idea as group_add in compose.yaml,
  # and applied before the restart because groups are read at process start.
  $SUDO usermod -aG systemd-journal,adm alloy

  for f in /etc/alloy/*.alloy; do
    $SUDO alloy fmt --test "$f" >/dev/null || die "${f} does not parse — not restarting the agent on it"
  done

  info "restarting alloy.service (host label ${HOSTNAME_LABEL})"
  $SUDO systemctl enable alloy >/dev/null 2>&1
  $SUDO systemctl restart alloy

  require_stable "systemctl is-active --quiet alloy"
  pass "alloy.service active as $(systemctl show -p User --value alloy 2>/dev/null || echo '?')"
  require_quiet "journalctl -u alloy --since '60 seconds ago' --no-pager -o cat"

  info "listening sockets (expect 12345 on loopback only, and no 1514):"
  ss -ltnup 2>/dev/null | grep -E ':(12345|1514)\b' >&2 || true
  ;;
esac
REMOTE

# ---------------------------------------------------------------------------
# Did it arrive? Asked of the monitoring host, not the agent.
# ---------------------------------------------------------------------------
promql="up{instance=\"${HOST}\"}"
logql="{host=\"${HOST}\"}"
expected=2
[[ "$RUNTIME" == docker ]] && expected=3   # + integrations/cadvisor

if ((VERIFY)); then
  if curl -fsS --max-time 5 "http://${MON}:9090/-/ready" >/dev/null 2>&1; then
    info "waiting for ${HOST} to appear in Prometheus and Loki at ${MON} (up to 3 min)"
    deadline=$((SECONDS + 180)); jobs=0; in_loki=0
    while ((SECONDS < deadline)); do
      jobs="$(curl -fsS --max-time 10 "http://${MON}:9090/api/v1/query" --data-urlencode "query=${promql}" 2>/dev/null \
              | grep -o '"job":"[^"]*"' | sort -u | wc -l | tr -d ' ')"
      if curl -fsS --max-time 10 "http://${MON}:3100/loki/api/v1/label/host/values" 2>/dev/null | grep -q "\"${HOST}\""; then
        in_loki=1
      fi
      ((jobs >= expected && in_loki)) && break
      sleep 10
    done
    if ((jobs >= expected)); then
      pass "Prometheus has ${jobs} job(s) for instance=\"${HOST}\""
    else
      warn "Prometheus has ${jobs} job(s) for instance=\"${HOST}\" (expected ${expected}) — if this host is on another VLAN, is the pass to ${MON}:9090 in place?"
    fi
    if ((in_loki)); then
      pass "Loki has host=\"${HOST}\""
    else
      warn "Loki does not list host=\"${HOST}\" yet — is the pass to ${MON}:3100 in place?"
    fi
  else
    warn "${MON}:9090 is not reachable from here; skipping the arrival check"
  fi
fi

printf '\n\033[0;32mdeployed\033[0m — alloy %s on %s (%s)\n' "$VERSION" "$HOST" "$RUNTIME" >&2
printf 'Check by hand:\n  PromQL  %s\n  LogQL   %s\n' "$promql" "$logql" >&2
