#!/usr/bin/env bash
#
# Prove Stirling-PDF's PDF engine works, not just its status endpoint (#143).
# Run by scripts/check_hardened_boot.sh after a healthy, hardened boot, with
# the container id as $1.
#
# WHY THE HEALTHCHECK IS NOT ENOUGH. /api/v1/info/status answers from the JVM
# alone. The tools that matter load pdfium through jpdfium, which unpacks its
# shared libraries into /tmp/stirling-pdf at first use. With /tmp mounted
# noexec (Docker's default for a tmpfs) the container went healthy on
# 2026-09-29 and every pdfium tool, merge first, answered 500 with
# "failed to map segment from shared object". compose.yaml's DIFFERENCE 13
# mounts /tmp exec for that reason. This script is what notices if an image
# bump or an edit breaks that again.
#
# WHAT IT DOES, inside the container, with the tools the image ships:
#   1. logs in as the admin the environment seeded, which also proves the
#      SOPS-shaped login works;
#   2. makes a one-page PDF with gs;
#   3. merges it with itself through /api/v1/general/merge-pdfs and expects
#      a 200 and a PDF back;
#   4. checks the container log has no UnsatisfiedLinkError.
# Nothing leaves the container, and the network is internal during the boot.
set -euo pipefail

cid="${1:?usage: smoke.sh <container id>}"

docker exec -i "${cid}" bash -s <<'IN_CONTAINER'
set -euo pipefail
work="$(mktemp -d /tmp/smoke.XXXXXX)"
trap 'rm -rf "${work}"' EXIT
cd "${work}"

body="$(printf '{"username":"%s","password":"%s"}' \
  "${SECURITY_INITIALLOGIN_USERNAME}" "${SECURITY_INITIALLOGIN_PASSWORD}")"
token="$(curl -fsS --max-time 30 -H 'Content-Type: application/json' -d "${body}" \
  http://localhost:8080/api/v1/auth/login \
  | sed -nE 's/.*"access_token":"([^"]+)".*/\1/p')"
[[ -n "${token}" ]] || { echo "smoke: login as ${SECURITY_INITIALLOGIN_USERNAME} returned no token" >&2; exit 1; }

printf '/Helvetica findfont 24 scalefont setfont 72 700 moveto (smoke) show showpage\n' > page.ps
gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -sOutputFile=page.pdf page.ps

code="$(curl -sS --max-time 120 -o merged.pdf -w '%{http_code}' \
  -H "Authorization: Bearer ${token}" \
  -F fileInput=@page.pdf -F fileInput=@page.pdf \
  http://localhost:8080/api/v1/general/merge-pdfs)"
if [[ "${code}" != 200 ]]; then
  echo "smoke: merge-pdfs answered ${code}: $(head -c 300 merged.pdf)" >&2
  exit 1
fi
[[ "$(head -c 5 merged.pdf)" == "%PDF-" ]] || { echo "smoke: merge-pdfs returned 200 but not a PDF" >&2; exit 1; }
echo "smoke: logged in, merged two pages through pdfium ($(wc -c < merged.pdf) bytes)"
IN_CONTAINER

if docker logs "${cid}" 2>&1 | grep -q 'UnsatisfiedLinkError'; then
  echo "smoke: the log has an UnsatisfiedLinkError, so a native library failed to load" >&2
  exit 1
fi
