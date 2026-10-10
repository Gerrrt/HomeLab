#!/usr/bin/env bash
#
# Prove the Docker socket proxies allow what Alloy needs and nothing that
# copies files out of a container (Tecnativa/docker-socket-proxy#182).
#
# Every Alloy in the estate reaches the Docker API through
# tecnativa/docker-socket-proxy with CONTAINERS=1. In the image's own template
# that flag allows the whole /containers prefix, which includes four GETs that
# POST=0 does not stop: archive (any file, from any container), export (a whole
# filesystem as a tar), top and changes. The daemon serves them as root. On
# 2026-10-10 all four answered 200 through the estate's proxy on prometheus.
# stacks/observability/docker-socket-proxy/haproxy.cfg narrows CONTAINERS=1 to
# the three paths the clients send. Its header has the measurement.
#
# This boots the pinned proxy image on that file, with the estate's
# environment read from stacks/observability/compose.yaml and the real socket
# behind it, read-only. It makes every request from inside the proxy
# container to its own listener, so no second image and no network are needed,
# and then asserts on two things:
#
#   allowed  the paths docker.alloy's three components use answer 200. A
#            too-narrow rule fails here and not as an agent that stays healthy
#            while collecting nothing, which is how a missing NETWORKS showed
#            itself (#193).
#   refused  archive, export, top, changes, stats and attach, plus the `..`
#            and encoded-slash spellings of archive, get a 403 FROM THE PROXY.
#            The proxy's own log must show each one denied with no backend
#            (`<NOSRV>`). A 403 or a 404 from the daemon would mean the request
#            got through.
#
# And it checks drift: it rebuilds upstream's template from this file by
# undoing the two marked differences, and requires the result to equal the
# template in the pinned image byte for byte. A Dependabot bump that changes
# upstream's rules therefore fails here, rather than being silently replaced by
# a copy of the old ones.
#
# The container the requests name is the proxy itself, so nothing else on the
# daemon is read. The probes discard every body. The daemon's answers for the
# allowed paths are metadata about the scratch proxy, and the refused ones
# never reach the daemon at all.
#
# Usage: scripts/check_socket_proxy.sh [--skips-file PATH] [--cfg PATH]
#   --cfg  test a different HAProxy config. Pass the image's own template,
#          rendered, to see this fail on the unfixed proxy.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${REPO_ROOT}/stacks/observability/docker-socket-proxy/haproxy.cfg"
COMPOSE="${REPO_ROOT}/stacks/observability/compose.yaml"
SKIPS_FILE=""
FAILED=0

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }

while (($#)); do
  case "$1" in
    --skips-file) SKIPS_FILE="${2:?--skips-file needs a path}"; shift ;;
    --cfg) CFG="${2:?--cfg needs a path}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
[[ -f "${CFG}" ]] || die "no such file: ${CFG}"

# Same contract as check_syslog_senders.sh: no docker is a recorded skip,
# never a pass (#68).
if ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
  msg="no docker daemon — socket proxy allowlist not exercised"
  printf '\033[0;33m  SKIP\033[0m %s\n' "${msg}"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "${msg}" >> "${SKIPS_FILE}"
  exit 0
fi

IMAGE="$("${REPO_ROOT}/scripts/image-for.sh" docker-socket-proxy)"
TAG="sockproxycheck-$$"
WORK="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329  # reached through the EXIT trap
cleanup() {
  docker rm -f "${TAG}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

pydeps="$(python3 "${REPO_ROOT}/scripts/_deps.py" --pythonpath)" \
  || die "PyYAML is required: sudo apt install python3-yaml"
[[ -n "${pydeps}" ]] && export PYTHONPATH="${pydeps}${PYTHONPATH:+:${PYTHONPATH}}"

# ---------------------------------------------------------------------------
info "drift: this config is upstream's template plus the two marked changes"
# ---------------------------------------------------------------------------
docker run --rm --entrypoint cat "${IMAGE}" /usr/local/etc/haproxy/haproxy.cfg.template \
  > "${WORK}/upstream.template" || die "could not read the template out of ${IMAGE}"

python3 - "${CFG}" "${WORK}/rebuilt.template" <<'REBUILD' || fail "could not rebuild upstream's template from ${CFG##*/}"
import sys
src, dst = sys.argv[1:]
lines = open(src, encoding="utf-8").read().splitlines(keepends=True)
# 1. The header: everything before the first section.
try:
    lines = lines[lines.index("global\n"):]
except ValueError:
    sys.exit("no `global` section")
out, inside, blocks = [], False, 0
for line in lines:
    if line.strip().startswith("# BEGIN homelab"):
        inside, blocks = True, blocks + 1
        # 2. The block stands where upstream's one prefix rule stood.
        out.append("    http-request allow if { path,url_dec -m reg -i ^(/v[\\d\\.]+)?/containers } { env(CONTAINERS) -m bool }\n")
        continue
    if line.strip() == "# END homelab":
        inside = False
        continue
    if inside:
        continue
    # 3. The resolved bind line, back to the placeholder the entrypoint fills.
    out.append("    bind ${BIND_CONFIG}\n" if line == "    bind [::]:2375 v4v6\n" else line)
if blocks != 1 or inside:
    sys.exit(f"expected exactly one closed `# BEGIN homelab` block, found {blocks}")
open(dst, "w", encoding="utf-8").writelines(out)
REBUILD
if [[ -f "${WORK}/rebuilt.template" ]] && cmp -s "${WORK}/upstream.template" "${WORK}/rebuilt.template"; then
  pass "upstream's template in ${IMAGE##*/} is unchanged under ours"
elif [[ -f "${WORK}/rebuilt.template" ]]; then
  fail "upstream's template differs from the one ${CFG##*/} was written against:"
  diff -u "${WORK}/rebuilt.template" "${WORK}/upstream.template" | sed 's/^/        /' || true
  printf '        Re-derive the file from the new template, keeping the homelab block, and re-measure.\n'
fi

# ---------------------------------------------------------------------------
info "boot the pinned proxy on ${CFG#"${REPO_ROOT}"/}"
# ---------------------------------------------------------------------------
# The estate's environment, flag for flag, from compose.yaml rather than a
# copy here.
python3 - "${COMPOSE}" > "${WORK}/env" <<'ENV'
import sys, yaml
svc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["services"]["docker-socket-proxy"]
for key, value in (svc.get("environment") or {}).items():
    print(f"{key}={value}")
ENV
mkdir -p "${WORK}/cfg"
cp "${CFG}" "${WORK}/cfg/haproxy.cfg"
chmod -R a+rX "${WORK}/cfg"

# homelab.logs=off keeps production Alloy, if it runs on this daemon, from
# ingesting this container's request log.
docker run -d --name "${TAG}" --label homelab.logs=off \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --env-file "${WORK}/env" \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v "${WORK}/cfg:/usr/local/etc/socket-proxy:ro" \
  "${IMAGE}" haproxy -f /usr/local/etc/socket-proxy/haproxy.cfg >/dev/null

up=0
for ((i = 0; i < 30; i++)); do
  if docker exec "${TAG}" wget -q -O /dev/null -T 2 http://127.0.0.1:2375/version 2>/dev/null; then
    up=1
    break
  fi
  sleep 1
done
if ((up == 0)); then
  docker logs --tail 20 "${TAG}" 2>&1 | sed 's/^/        /'
  die "the scratch proxy never answered /version"
fi
ID="$(docker inspect -f '{{.Id}}' "${TAG}")"

# One request from inside the container. Prints the status: busybox wget
# exits 0 on a 2xx and names the code in its error otherwise.
status() { # path
  local out
  if out="$(docker exec "${TAG}" wget -q -O /dev/null -T 5 "http://127.0.0.1:2375$1" 2>&1)"; then
    echo 200
  else
    grep -oE '[0-9]{3}' <<<"${out}" | head -1 || echo "none"
  fi
}

# ---------------------------------------------------------------------------
info "allowed: what docker.alloy's components send"
# ---------------------------------------------------------------------------
ALLOWED=(
  "/version"
  "/v1.56/version"
  "/_ping"
  "/info"
  "/networks"
  "/images/json"
  "/containers/json"
  "/containers/json?all=1"
  "/v1.56/containers/json"
  "/containers/${ID}/json"
  "/v1.56/containers/${ID}/json"
  "/containers/${TAG}/json"
  "/containers/${ID}/logs?stdout=1&stderr=1&tail=1"
  "/v1.56/containers/${ID}/logs?stdout=1&tail=1&timestamps=1"
)
for path in "${ALLOWED[@]}"; do
  got="$(status "${path}")"
  shown="${path//${ID}/<id>}"
  if [[ "${got}" == 200 ]]; then pass "GET ${shown} -> 200"; else fail "GET ${shown} -> ${got}, expected 200"; fi
done

# ---------------------------------------------------------------------------
info "refused: everything else under /containers, by the proxy"
# ---------------------------------------------------------------------------
REFUSED=(
  "/containers/${ID}/archive?path=/etc/hostname"
  "/v1.56/containers/${ID}/archive?path=/etc/hostname"
  "/containers/${ID}/export"
  "/containers/${ID}/top"
  "/containers/${ID}/changes"
  "/containers/${ID}/stats?stream=false"
  "/containers/${ID}/attach/ws"
  "/containers/${ID}/json/../archive?path=/etc/hostname"
  "/containers/${ID}/logs/../archive?path=/etc/hostname"
  "/containers/${ID}%2Farchive?path=/etc/hostname"
  "/containers/${ID}%252Farchive?path=/etc/hostname"
  "/containers/${ID}/json%2F..%2Farchive?path=/etc/hostname"
  "/containers"
  "/containers/"
)
for path in "${REFUSED[@]}"; do
  got="$(status "${path}")"
  shown="${path//${ID}/<id>}"
  if [[ "${got}" == 403 ]]; then pass "GET ${shown} -> 403"; else fail "GET ${shown} -> ${got}, expected 403"; fi
done

# The 403s above must be the proxy's: each request in its log, denied with no
# backend. A request the proxy passed on carries `dockerbackend/dockersocket`.
LOG="$(docker logs "${TAG}" 2>&1)"
passed_on="$(grep -F 'dockerbackend/dockersocket' <<<"${LOG}" \
  | grep -E '"GET [^ ]*/containers/[^ ]+/(archive|export|top|changes|stats|attach)' || true)"
denied="$(grep -cF '<NOSRV>' <<<"${LOG}" || true)"
if [[ -n "${passed_on}" ]]; then
  fail "the proxy passed a refused path on to the daemon:"
  sed "s/${ID}/<id>/g; s/^/        /" <<<"${passed_on}"
elif ((denied >= ${#REFUSED[@]})); then
  pass "every refusal is the proxy's own: ${denied} denied with no backend, none passed on"
else
  fail "the proxy's log shows ${denied} request(s) denied with no backend, fewer than the ${#REFUSED[@]} refused"
fi

# POST stays shut whatever the path.
if out="$(docker exec "${TAG}" wget -q -O /dev/null -T 5 --post-data '' "http://127.0.0.1:2375/containers/create" 2>&1)"; then
  fail "POST /containers/create was allowed"
elif grep -q 403 <<<"${out}"; then
  pass "POST /containers/create -> 403"
else
  fail "POST /containers/create -> $(grep -oE '[0-9]{3}' <<<"${out}" | head -1 || echo none), expected 403"
fi

if ((FAILED)); then
  printf '\033[0;31mFAIL\033[0m the socket proxy config does not hold\n'
  exit 1
fi
printf '\033[0;32mOK\033[0m %d allowed, %d refused by the proxy, and upstream'"'"'s template unchanged\n' \
  "${#ALLOWED[@]}" "$((${#REFUSED[@]} + 1))"
