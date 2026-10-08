#!/usr/bin/env bash
#
# The last step of a Windows build, run on phoenix (shell-local): wait for the
# guest to power itself off, which is sysprep saying it has generalised.
#
# sysprep.ps1 starts sysprep as a scheduled task with /shutdown and returns at
# once, because generalising uninstalls the network adapter and kills any
# WinRM session waiting on it (2026-10-02). From here nothing can reach the
# guest, but the Proxmox API can still see whether it is running. Once it is
# stopped, the builder converts it to a template.
#
# If it never stops, sysprep failed or hung. The image is half-generalised and
# must not be booted to look at, because booting spends the generalisation.
# Read its log from the disk instead, as build-the-lab-templates.md §4 says.
#
# TWO DIFFERENT FAILURES, TOLD APART. "Still running at the deadline" is
# sysprep's. "The API cannot be read" is phoenix's or the token's, and is
# reported as that after a few polls in a row, not blamed on sysprep 45
# minutes later. Every request has its own timeout and the loop runs to a
# clock, so neither case can hang.
#
# Environment: PROXMOX_URL, PROXMOX_TOKEN_ID, NODE and VMID from windows.pkr.hcl,
# and PROXMOX_TOKEN_SECRET inherited from packer's own environment (phoenix.env,
# exported), never passed by windows.pkr.hcl, which would put it on argv. TLS
# is verified, as packer-smoke.sh does, with PROXMOX_CA_FILE for a host whose
# trust store lacks the cluster CA.
set -euo pipefail

die() { printf '\nwait-for-sysprep: %s\n' "$*" >&2; exit 1; }

for v in PROXMOX_URL PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET NODE VMID; do
  [[ -n "${!v:-}" ]] || die "${v} is unset (PROXMOX_TOKEN_SECRET comes from packer's environment: set -a; . ~/.config/proxmox/phoenix.env; set +a)"
done
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required (apt install jq)"

WAIT_SECONDS=2700          # 45 minutes for sysprep to finish
POLL_SECONDS=15
MAX_API_FAILURES=8         # two minutes of polls in a row that read nothing

CURL_TLS=()
[[ -n "${PROXMOX_CA_FILE:-}" ]] && CURL_TLS=(--cacert "${PROXMOX_CA_FILE}")

# Prints the VM's status, or fails with the reason on stderr. A status that is
# not a word (an error page, an empty body) is a failed read, not a state.
# The token is curl config on stdin, not -H, so it is never in this poll's argv
# for ps on phoenix to show, 180 times a build (#846).
status() {
  local body s
  body="$(printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "${PROXMOX_TOKEN_ID}" "${PROXMOX_TOKEN_SECRET}" \
    | curl -K - -fsS --connect-timeout 10 --max-time 30 "${CURL_TLS[@]}" \
    "${PROXMOX_URL}/nodes/${NODE}/qemu/${VMID}/status/current" 2>&1)" \
    || { printf '%s' "${body}"; return 1; }
  s="$(jq -r '.data.status // empty' <<<"${body}" 2>/dev/null)" || true
  [[ "${s}" =~ ^[a-z]+$ ]] || { printf 'unexpected response: %.200s' "${body}"; return 1; }
  printf '%s' "${s}"
}

# Whole lines, once a minute. Packer shows a shell-local script's output a
# line at a time, so the dots this printed on one line stayed invisible until
# the end: the 911 build sat silent through sysprep (2026-10-03).
start=${SECONDS}
deadline=$((SECONDS + WAIT_SECONDS))
next_report=$((SECONDS + 60))
failures=0
s=""
printf 'waiting for VM %s to power off after sysprep (up to %d minutes)\n' "${VMID}" $((WAIT_SECONDS / 60))
while ((SECONDS < deadline)); do
  if out="$(status)"; then
    failures=0
    s="${out}"
    if [[ "${s}" == stopped ]]; then
      printf 'VM %s is stopped after %dm%02ds: sysprep finished\n' "${VMID}" \
        $(((SECONDS - start) / 60)) $(((SECONDS - start) % 60))
      exit 0
    fi
  else
    failures=$((failures + 1))
    ((failures < MAX_API_FAILURES)) \
      || die "the Proxmox API could not be read ${failures} times in a row, so whether sysprep finished is unknown, not failed. Last error: ${out}"
  fi
  if ((SECONDS >= next_report)); then
    printf '  still %s after %dm\n' "${s:-unreadable}" $(((SECONDS - start) / 60))
    next_report=$((SECONDS + 60))
  fi
  sleep "${POLL_SECONDS}"
done
printf 'VM %s is still %s after %d minutes. Sysprep failed or hung.\n' \
  "${VMID}" "${s:-unknown}" $((WAIT_SECONDS / 60)) >&2
printf 'Do not boot it. Read C:\\Windows\\System32\\Sysprep\\Panther\\setupact.log and setuperr.log from its disk.\n' >&2
exit 1
