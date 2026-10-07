#!/usr/bin/env bash
#
# When the management certificates expire, as metrics (#857, ADR-0084).
#
# WHAT NOTHING WAS WATCHING. Four consoles serve certificates that no probe
# reads: the pfSense GUI on morpheus, the iLO on shiva, Saruman's Proxmox UI on
# :8006 and the TrueNAS UI on smaug. Each is reachable from Hicks and nowhere
# else, which is deliberate, so the blackbox exporter on the monitoring host
# cannot see any of them — the iLO and pfSense probes are written out and
# disabled in targets/blackbox.yaml for exactly that reason. The first sign of
# an expiry would be a browser warning on the day someone needs the console.
#
# WHY IT RUNS INSIDE EACH SEGMENT. ADR-0084: opening four management ports to
# the monitoring host is four segmentation decisions made for a date that
# changes once a year. Instead this runs where the endpoint already is —
#
#     pfsense-ui   on the monitoring host, over the ssh to morpheus that
#                  `make gateway-state` already makes, against 127.0.0.1:443
#     pve-ui       on Saruman, against 127.0.0.1:8006
#     ilo-ui       on Saruman, against 10.0.30.10:443 — same VLAN, no pf rule
#     truenas-ui   on smaug, from the ADR-0047 root cron
#
# and nothing new is opened between segments.
#
# IT READS THE HANDSHAKE, NOT A FILE. The same principle as the blackbox expiry
# rules: what matters is the leaf the endpoint actually serves. A file on disk
# can be renewed while the daemon still holds the old one, and on pfSense the
# file route goes near config.xml, which has printed a private key into a
# transcript before (changelog, 2026-09-28). openssl s_client does not verify
# by default, which is what is wanted here: a self-signed or expired leaf must
# still report its date.
#
# OLD TLS. iLO 4 may not complete a handshake at OpenSSL 3's default security
# level. A failed read is retried once at SECLEVEL=0. That weakens nothing:
# nothing is sent and nothing read is trusted except a date.
#
# THE PROBE SCRIPT IS POSIX sh and runs wherever the endpoint is — locally, or
# on morpheus over ssh, where the login shell is not bash and `date` is not GNU.
# It prints one line per probe and the date arithmetic happens here, on Linux.
#
# "Could not read" is kept apart from "expiring". A probe that fails writes
# homelab_cert_checked 0 and no expiry sample, the homelab_ddns_record_checked
# pattern: a console that is briefly down must not look like a certificate that
# expired, and a reader that has quietly stopped working must not look like
# good news.
#
# Usage: scripts/collect-cert-expiry.sh [--ssh USER@HOST] [--host NAME] [--print]
#                                       --probe ENDPOINT=HOST=ADDR:PORT [...]
#        scripts/collect-cert-expiry.sh --self-test
#
#   --probe    endpoint name, the host label the series carries (`-` for this
#              host's hostname), and the address to handshake with
#   --host     names the output file, cert-expiry-<NAME>.prom; defaults to
#              this host's hostname
#   --ssh      run the probes on that host instead of here
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PRINT_ONLY=0
SSH_TARGET=""
FILE_HOST=""
PROBES=()

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Everything in a probe ends up interpolated into a script another host runs,
# so each part is checked for shape before it gets there.
valid_probe() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]*=([A-Za-z0-9][A-Za-z0-9._-]*|-)=[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}$ ]]
}

# The script that does the handshakes. Takes "ENDPOINT ADDR:PORT" pairs and
# prints "ENDPOINT notAfter=<date>" or "ENDPOINT -".
probe_script() {
  cat <<'EOF'
read_end() {
  timeout 20 openssl s_client -connect "$1" $2 </dev/null 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null
}
EOF
  local pair endpoint addr
  # shellcheck disable=SC2016  # $e and $(...) belong to the generated script
  for pair in "$@"; do
    endpoint="${pair%% *}"; addr="${pair#* }"
    printf 'e=$(read_end %s "") ; [ -n "$e" ] || e=$(read_end %s "-cipher DEFAULT@SECLEVEL=0")\n' "$addr" "$addr"
    printf 'printf "%%s %%s\\n" %s "${e:--}"\n' "$endpoint"
  done
}

# "notAfter=Apr 16 16:37:44 2027 GMT" -> epoch seconds, or nothing.
to_epoch() {
  local s="${1#notAfter=}"
  [[ -n "$s" && "$s" != "$1" ]] || return 0
  date -u -d "$s" +%s 2>/dev/null || true
}

# Results ("ENDPOINT HOSTLABEL EPOCH-or-empty" per line) -> exposition format.
render() {
  local lines="$1" endpoint hostlabel epoch
  printf '# HELP homelab_cert_expiry_timestamp_seconds When the certificate this endpoint serves expires (notAfter).\n'
  printf '# TYPE homelab_cert_expiry_timestamp_seconds gauge\n'
  while read -r endpoint hostlabel epoch; do
    [[ -n "$endpoint" && -n "$epoch" ]] || continue
    printf 'homelab_cert_expiry_timestamp_seconds{endpoint="%s",host="%s"} %s\n' "$endpoint" "$hostlabel" "$epoch"
  done <<<"$lines"
  printf '# HELP homelab_cert_checked 1 when the endpoint completed a handshake and its certificate was read.\n'
  printf '# TYPE homelab_cert_checked gauge\n'
  while read -r endpoint hostlabel epoch; do
    [[ -n "$endpoint" ]] || continue
    printf 'homelab_cert_checked{endpoint="%s",host="%s"} %s\n' "$endpoint" "$hostlabel" "$([[ -n "$epoch" ]] && echo 1 || echo 0)"
  done <<<"$lines"
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  ok()  { printf '\033[0;32m  PASS\033[0m %s\n' "$1"; }
  bad() { printf '\033[0;31m  FAIL\033[0m %s\n' "$1"; fail=1; }
  same() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1"; printf '       got      %s\n       expected %s\n' "$2" "$3"; fi; }

  # morpheus's leaf as read on 2026-10-07.
  same "openssl's date to epoch" "$(to_epoch 'notAfter=Apr 16 16:37:44 2027 GMT')" 1807893464
  same "a single-digit day"      "$(to_epoch 'notAfter=Jan  2 03:04:05 2030 GMT')" 1893553445
  same "a failed read is empty"  "$(to_epoch '-')" ""
  same "garbage is empty"        "$(to_epoch 'notAfter=whenever')" ""

  out="$(render $'pve-ui Saruman 1807893464\nilo-ui shiva ')"
  same "a read endpoint has both series" \
    "$(grep -c 'endpoint="pve-ui"' <<<"$out")" 2
  same "an unread endpoint has no expiry sample" \
    "$(grep -c '^homelab_cert_expiry_timestamp_seconds{endpoint="ilo-ui"' <<<"$out")" 0
  same "an unread endpoint is checked 0" \
    "$(grep '^homelab_cert_checked{endpoint="ilo-ui"' <<<"$out")" 'homelab_cert_checked{endpoint="ilo-ui",host="shiva"} 0'

  for p in 'pfsense-ui=morpheus=127.0.0.1:443' 'pve-ui=-=127.0.0.1:8006' 'ilo-ui=shiva=10.0.30.10:443'; do
    if valid_probe "$p"; then ok "accepts $p"; else bad "accepts $p"; fi
  done
  # shellcheck disable=SC2016  # the $(id) is the injection being refused
  for p in 'x=y=1.2.3.4' 'pve-ui=-=127.0.0.1:8006;reboot' 'a=$(id)=h:1' 'UI=h=h:1' 'a=h=h:1 2'; do
    if valid_probe "$p"; then bad "rejects ${p}"; else ok "rejects ${p}"; fi
  done

  if probe_script "pfsense-ui 127.0.0.1:443" "ilo-ui 10.0.30.10:443" | sh -n 2>/dev/null; then
    ok "the probe script parses as sh"
  else
    bad "the probe script does not parse as sh"
  fi
  exit $fail
fi

while (($#)); do
  case "$1" in
    --print) PRINT_ONLY=1; shift ;;
    --ssh)   SSH_TARGET="${2:-}"; shift 2 ;;
    --host)  FILE_HOST="${2:-}"; shift 2 ;;
    --probe) PROBES+=("${2:-}"); shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
((${#PROBES[@]})) || die "at least one --probe ENDPOINT=HOST=ADDR:PORT is required"
[[ -n "$FILE_HOST" ]] || FILE_HOST="$(hostname)"
[[ "$FILE_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--host ${FILE_HOST@Q} is not a host name"

pairs=(); labels=()
for p in "${PROBES[@]}"; do
  valid_probe "$p" || die "--probe ${p@Q} is not ENDPOINT=HOST=ADDR:PORT"
  endpoint="${p%%=*}"; rest="${p#*=}"; hostlabel="${rest%%=*}"; addr="${rest#*=}"
  [[ "$hostlabel" == - ]] && hostlabel="$(hostname)"
  pairs+=("${endpoint} ${addr}"); labels+=("${endpoint} ${hostlabel}")
done

STDERR_FILE="$(mktemp)"; trap 'rm -f "${STDERR_FILE}"' EXIT
if [[ -n "$SSH_TARGET" ]]; then
  raw="$(probe_script "${pairs[@]}" \
    | ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" 'sh -s' 2>"${STDERR_FILE}")"
else
  raw="$(probe_script "${pairs[@]}" | sh -s 2>"${STDERR_FILE}")"
fi
# No line at all means the probes never ran — ssh failed, or there is no
# openssl. That is the job failing, not every certificate being unreadable, so
# it exits non-zero and leaves the previous file for the staleness rules.
if [[ -z "$raw" ]]; then
  detail="$(tr -d '\r' < "${STDERR_FILE}" | grep -v '^$' | tail -2 | paste -sd'; ' -)"
  die "the probes did not run${SSH_TARGET:+ on ${SSH_TARGET}}${detail:+ — ${detail}}"
fi

results=""
for l in "${labels[@]}"; do
  endpoint="${l%% *}"; hostlabel="${l#* }"
  line="$(grep -m1 "^${endpoint} " <<<"$raw")"
  epoch="$(to_epoch "${line#* }")"
  results+="${endpoint} ${hostlabel} ${epoch}"$'\n'
done

if ((PRINT_ONLY)); then render "$results"; exit 0; fi

PROM="${TEXTFILE_DIR}/cert-expiry-${FILE_HOST}.prom"
[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
render "$results" > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
while read -r endpoint _ epoch; do
  [[ -n "$endpoint" ]] || continue
  if [[ -n "$epoch" ]]; then
    printf 'cert-expiry %s expires %s\n' "$endpoint" "$(date -u -d "@${epoch}" +%F)"
  else
    printf 'cert-expiry %s could not be read\n' "$endpoint"
  fi
done <<<"$results"
