#!/usr/bin/env bash
#
# The range host's own controls, for Prometheus (#1651, ADR-0126).
#
# WHAT THIS IS FOR. `collect-pve-firewall-state.sh` reads the Proxmox firewall,
# which is one of the barriers §7's read-back checks on `gandalf`. The others
# are not Proxmox's: the netdev `ingress` table `vmbr1_host_in` that drops what
# the range bridge sends the host (§2), `vmbr0`'s IP forwarding being off (§2),
# `sshd`'s forwarding being off (§4), and the attack-VM stop timer (ADR-0125)
# being the thing that bounds `ragnarok` on VLAN 30. On a host that is now on by
# design (ADR-0125), the per-session read-back is a gap of days, so this emits
# those controls as metrics and the range rules alert on them.
#
# HOST ONLY. Every fact here is read on `gandalf` itself — `nft`, `sysctl`,
# `sshd -T`, `systemctl`, and the stop timer's own machine-readable state. None
# is read from inside a guest, so this stays the ADR-0028 class ADR-0126 allows
# across, not guest telemetry.
#
# THE DEADLINE COMES FROM THE TIMER. The effective stop deadline folds in every
# `range-extend` and `dpkg` wait, and that logic lives in `ragnarok-stop.sh`.
# Rather than copy it, this calls `homelab-ragnarok-stop deadline-epoch` and
# reads back one source of truth.
#
# Usage:
#   collect-range-state.sh              write the .prom to the textfile dir
#   collect-range-state.sh --print      write it to stdout instead
#   collect-range-state.sh --self-test  run the parser fixtures
set -euo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/range-state.prom"
HOSTNAME_LABEL="$(hostname)"
STOP_CMD="${STOP_CMD:-homelab-ragnarok-stop}"
STOP_TIMER="${STOP_TIMER:-homelab-ragnarok-stop.timer}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# 1 when a netdev ingress chain on `vmbr1` drops by default — the barrier that
# stops a rooted target reaching the host (§2, `vmbr1_host_in`). Reads the
# chain's policy from `nft list chain netdev vmbr1_host_in ingress`. An absent
# table (nft prints nothing, or an error to stderr the caller drops) is 0: no
# barrier. `policy accept`, or any chain that is not an ingress hook, is 0 too.
parse_ingress_drop() {
  awk '
    /type[[:space:]]+filter[[:space:]]+hook[[:space:]]+ingress/ { hook = 1 }
    hook && /policy[[:space:]]+drop/ { drop = 1 }
    END { print (drop ? 1 : 0) }
  '
}

# For an `sshd -T` keyword, 0 only when it reads `no`, 1 for any other value,
# and nothing when the keyword is absent. `sshd -T` lowercases its keys and
# prints one setting per line, e.g. `allowtcpforwarding no`. Only `no` disables
# forwarding: AllowTcpForwarding also takes `local` and `remote`, which both
# permit a tunnel, so anything but `no` is the fault (1-is-bad).
parse_sshd_flag() {
  awk -v key="$1" '
    $1 == key { print ($2 == "no") ? 0 : 1; found = 1; exit }
    END { if (!found) exit 0 }
  '
}

# The value for a key in `homelab-ragnarok-stop deadline-epoch` output
# (`running=1`, `deadline_epoch=<n>`, `source=...`). Nothing when the key is
# absent.
parse_kv() {
  awk -F= -v key="$1" '$1 == key { print $2; exit }'
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
now() { date +%s; }
# A dpkg deferral counts as current only this close to now: the stop timer runs
# every minute, so a wait that is still happening rewrote the mark within the
# last couple of runs. Older than this and the timer has stopped confirming it.
DEFER_FRESH=180

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" got="$2" expect="$3"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }

  # The table as §2 loads it: an ingress hook with a drop policy.
  check "a loaded vmbr1_host_in ingress chain is a barrier" \
    "$(printf '%s\n' 'chain ingress {
                type filter hook ingress device "vmbr1" priority filter; policy drop;
                counter name "dropped" drop
        }' | parse_ingress_drop)" "1"
  check "an ingress chain that accepts is not a barrier" \
    "$(printf '%s\n' 'chain ingress {
                type filter hook ingress device "vmbr1" priority filter; policy accept;
        }' | parse_ingress_drop)" "0"
  check "no table at all is not a barrier" "$(printf '' | parse_ingress_drop)" "0"
  # A drop policy on some other hook is not the ingress barrier.
  check "a drop on a non-ingress hook does not count" \
    "$(printf '%s\n' 'chain output {
                type filter hook output priority filter; policy drop;
        }' | parse_ingress_drop)" "0"

  check "x11forwarding yes is the fault" \
    "$(printf 'x11forwarding yes\nallowtcpforwarding no\n' | parse_sshd_flag x11forwarding)" "1"
  check "allowtcpforwarding no is clean" \
    "$(printf 'x11forwarding yes\nallowtcpforwarding no\n' | parse_sshd_flag allowtcpforwarding)" "0"
  # AllowTcpForwarding local and remote both permit a tunnel — only no is off.
  check "allowtcpforwarding local is the fault" \
    "$(printf 'allowtcpforwarding local\n' | parse_sshd_flag allowtcpforwarding)" "1"
  check "allowtcpforwarding remote is the fault" \
    "$(printf 'allowtcpforwarding remote\n' | parse_sshd_flag allowtcpforwarding)" "1"
  check "an absent key prints nothing" \
    "$(printf 'permitrootlogin without-password\n' | parse_sshd_flag x11forwarding)" ""
  # sshd -T prints the key once; a value that is a substring must not match.
  check "the key matches the whole field, not a prefix" \
    "$(printf 'x11forwardingtrusted yes\nx11forwarding no\n' | parse_sshd_flag x11forwarding)" "0"

  check "deadline_epoch is read from the timer's output" \
    "$(printf 'running=1\ndeadline_epoch=1800021600\nsource=extended\n' | parse_kv deadline_epoch)" "1800021600"
  check "running is read from the timer's output" \
    "$(printf 'running=0\n' | parse_kv running)" "0"
  check "an absent key is nothing" \
    "$(printf 'running=0\n' | parse_kv deadline_epoch)" ""
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v nft >/dev/null 2>&1 || die "no nft on this host — it is not the range host."

# An absent table makes nft exit non-zero; `|| true` keeps that from aborting
# the collector under `set -e`, so the 0 sample (no barrier) is still written.
ingress_drop="$({ nft list chain netdev vmbr1_host_in ingress 2>/dev/null || true; } | parse_ingress_drop)"
fwd4="$(sysctl -n net.ipv4.conf.vmbr0.forwarding 2>/dev/null || echo "")"
fwd6="$(sysctl -n net.ipv6.conf.vmbr0.forwarding 2>/dev/null || echo "")"
sshd_out="$(sshd -T 2>/dev/null || true)"
x11="$(printf '%s\n' "$sshd_out" | parse_sshd_flag x11forwarding)"
tcpf="$(printf '%s\n' "$sshd_out" | parse_sshd_flag allowtcpforwarding)"

timer_active=0
[[ "$(systemctl is-active "${STOP_TIMER}" 2>/dev/null)" == "active" ]] && timer_active=1

# The attack-VM state comes from the stop helper (one source of the deadline).
# A command that fails, or output with no `running=` line, is an unusable
# answer — an old helper without `deadline-epoch`, say — NOT a stopped VM, so
# the ragnarok metrics are left out rather than written as running=0, which
# would suppress the alerts. The runbook makes upgrading the helper a step.
stop_ok=1
stop_state="$("${STOP_CMD}" deadline-epoch 2>/dev/null)" || stop_ok=0
[[ "$stop_state" == *running=* ]] || stop_ok=0
rag_running="$(printf '%s\n' "$stop_state" | parse_kv running)"
rag_deadline="$(printf '%s\n' "$stop_state" | parse_kv deadline_epoch)"
rag_deferred="$(printf '%s\n' "$stop_state" | parse_kv deferred_epoch)"

emit() {
  printf '# HELP homelab_range_ingress_table_loaded 1 when vmbr1 drops what it sends the host (vmbr1_host_in, build-the-playground.md §2).\n'
  printf '# TYPE homelab_range_ingress_table_loaded gauge\n'
  printf 'homelab_range_ingress_table_loaded{host="%s"} %s\n' "$HOSTNAME_LABEL" "$ingress_drop"

  printf '# HELP homelab_range_forwarding IP forwarding on a bridge; 0 is the wanted state (build-the-playground.md §2).\n'
  printf '# TYPE homelab_range_forwarding gauge\n'
  is_uint "${fwd4}" && printf 'homelab_range_forwarding{host="%s",dev="vmbr0",family="ipv4"} %s\n' "$HOSTNAME_LABEL" "$fwd4"
  is_uint "${fwd6}" && printf 'homelab_range_forwarding{host="%s",dev="vmbr0",family="ipv6"} %s\n' "$HOSTNAME_LABEL" "$fwd6"

  printf '# HELP homelab_range_sshd_forwarding 1 when sshd permits a forwarding kind; 0 is the wanted state (build-the-playground.md §4).\n'
  printf '# TYPE homelab_range_sshd_forwarding gauge\n'
  [[ -n "$x11" ]] && printf 'homelab_range_sshd_forwarding{host="%s",kind="x11"} %s\n' "$HOSTNAME_LABEL" "$x11"
  [[ -n "$tcpf" ]] && printf 'homelab_range_sshd_forwarding{host="%s",kind="tcp"} %s\n' "$HOSTNAME_LABEL" "$tcpf"

  printf '# HELP homelab_ragnarok_stop_timer_active 1 when the stop timer (ADR-0125) is active.\n'
  printf '# TYPE homelab_ragnarok_stop_timer_active gauge\n'
  printf 'homelab_ragnarok_stop_timer_active{host="%s"} %s\n' "$HOSTNAME_LABEL" "$timer_active"

  # Only when the stop helper gave a usable answer. A failed or old helper
  # writes none of these, so the alerts cannot read a false "stopped"; the gap
  # is a broken helper, which the runbook's reinstall step prevents and
  # RangeStateStale catches if the whole collector stops.
  if [[ "$stop_ok" == 1 ]] && is_uint "${rag_running}"; then
    printf '# HELP homelab_ragnarok_running 1 when the attack VM (ADR-0125) is running.\n'
    printf '# TYPE homelab_ragnarok_running gauge\n'
    printf 'homelab_ragnarok_running{host="%s"} %s\n' "$HOSTNAME_LABEL" "$rag_running"

    if [[ "$rag_running" == 1 ]]; then
      # The effective stop deadline, only while the VM runs, so
      # RagnarokPastDeadline cannot fire on a box with no attack VM.
      if is_uint "${rag_deadline}"; then
        printf '# HELP homelab_ragnarok_deadline_seconds The epoch the stop timer will shut ragnarok down at (ADR-0125, from the timer itself).\n'
        printf '# TYPE homelab_ragnarok_deadline_seconds gauge\n'
        printf 'homelab_ragnarok_deadline_seconds{host="%s"} %s\n' "$HOSTNAME_LABEL" "$rag_deadline"
      fi
      # 1 when the timer most recently chose to wait, within the last few runs,
      # because dpkg's lock was held inside the VM (ADR-0125). A past-deadline
      # VM that is deferring for this reason is not a failed timer, so
      # RagnarokPastDeadline excludes it; a stale mark (the timer stopped
      # confirming) reads 0 and the alert can fire.
      deferred=0
      is_uint "${rag_deferred}" && (( $(now) - rag_deferred < DEFER_FRESH )) && deferred=1
      printf '# HELP homelab_ragnarok_stop_deferred 1 when the stop timer is currently waiting on dpkg inside ragnarok (ADR-0125).\n'
      printf '# TYPE homelab_ragnarok_stop_deferred gauge\n'
      printf 'homelab_ragnarok_stop_deferred{host="%s"} %s\n' "$HOSTNAME_LABEL" "$deferred"
    fi
  fi
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'range-state host=%s ingress=%s fwd4=%s fwd6=%s x11=%s tcp=%s ragnarok=%s timer=%s\n' \
  "$HOSTNAME_LABEL" "$ingress_drop" "${fwd4:-?}" "${fwd6:-?}" "${x11:-?}" "${tcpf:-?}" "$rag_running" "$timer_active"
