#!/usr/bin/env bash
#
# Count a host's clean power-offs, as a metric, so a drive that counts every
# power-off can still tell a planned one from a cut (#746).
#
# WHY THIS EXISTS. SmartDriveUnsafeShutdownsGrowing was written on the premise
# that a clean shutdown does not move a drive's unsafe-shutdown counter (#574,
# ADR-0049). smaug's boot SSD, an Intel DC S3520, disproved it on 2026-09-29:
# 522 before a clean TrueNAS *System → Shut Down*, 523 after. One clean stop,
# plus one. The rule could not tell maintenance from a power cut, which is the
# one distinction it exists to make.
#
# WHAT IT DOES. Runs as a TrueNAS SHUTDOWN init script, so it runs on every
# stop that goes through the init system. A pulled plug, a crash, or a mains
# cut that outlasts the pack never runs it. It asks systemd where the stop is
# headed and counts it in one of three places:
#
#   poweroff.target, halt.target   homelab_clean_shutdowns_total — the UI's
#                                  Shut Down, and the UPS service's halt on LB
#                                  (ADR-0049). The drive loses power.
#   reboot.target, kexec.target,   homelab_clean_restarts_total — the UI's
#   soft-reboot.target             Restart. The drive never loses power.
#   anything else                  homelab_clean_stops_unclassified_total
#
# The rule subtracts only the first from the day's unsafe shutdowns. What is
# left is a power-off nobody planned.
#
# A RESTART FORGIVES NOTHING (2026-10-02). The first version counted every stop.
# The first live reading disproved it: after a UI Restart, the clean count went
# to 1 and the S3520 stayed at 523, because a warm reboot never takes the
# drive's power away. A restart counted as clean would cancel a real cut on
# the same day, and nothing would page. Restarts are still counted, separately,
# so the classification can be seen working.
#
# UNKNOWN LEANS LOUD. If systemd shows neither kind of target — the job list
# unreadable, or a shutdown path this was not written for — the stop is not
# counted as clean. A planned power-off then pages once, which is noise. The
# other way round, an unknown stop forgiving a cut, would be silence.
#
# A FACT IN A FILE, NOT A SILENCE. #572 / ADR-0046 argued that a silence is the
# wrong place to record a fact: it matches labels, not values, it expires, and
# it lives outside git. Telling Alertmanager "this reboot was planned" would be
# that again, and would depend on somebody remembering. The host records it
# itself, on the way down, every time.
#
# THE COUNT LIVES IN THE FILE IT IS SERVED FROM. There is no other state: the
# previous values are read back out of the .prom, so the file on the pool is
# the whole of it. A missing or unreadable file starts again from zero. If
# Prometheus still holds the old count N in its day-long window, the clean
# delta reads at most 1 - N, which is negative. The rule clamps that to zero,
# so a reset forgives nothing that day: the stop that reset it pages, with the
# drive's real count. The failure leans LOUD, once, and never hides a cut.
#
# FAST, BECAUSE IT IS ON THE WAY DOWN. TrueNAS gives a SHUTDOWN script a timeout
# (10s is what build-the-nas.md §6.4 sets) and the pool is still imported when
# it runs. Temp file, mv, sync: the same atomic write collect-smart-state.sh
# uses, plus the sync, because the next thing that happens is the power going.
#
# The command line TrueNAS runs is
#
#   TEXTFILE_DIR=/mnt/erebor/apps/textfile \
#   /bin/bash /mnt/erebor/apps/stack/mark-clean-shutdown.sh --host smaug
#
# `--host` because the label has to match the `host` collect-smart-state.sh
# writes; the rule joins on it. HOMELAB_STOP_KIND=poweroff|reboot overrides the
# systemd lookup; it exists for the self-test, not for a real run.
#
# Usage: scripts/mark-clean-shutdown.sh --host NAME
#        scripts/mark-clean-shutdown.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
HOST_LABEL=""
SELF_TEST=0

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --host)
      [[ $# -ge 2 && -n "$2" ]] || die "--host needs a NAME"
      HOST_LABEL="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Where the stop is headed, from `systemctl list-jobs` on stdin. A restart
# wins if both appear, because a restart forgives nothing and that is the
# direction to be wrong in.
classify() {
  local jobs reboot=0 poweroff=0
  jobs="$(cat)"
  grep -qE '(^|[[:space:]])(reboot|kexec|soft-reboot)\.target([[:space:]]|$)' <<<"$jobs" && reboot=1
  grep -qE '(^|[[:space:]])(poweroff|halt)\.target([[:space:]]|$)' <<<"$jobs" && poweroff=1
  if ((reboot)); then echo reboot
  elif ((poweroff)); then echo poweroff
  else echo unknown
  fi
}

stop_kind() {
  case "${HOMELAB_STOP_KIND:-}" in
    poweroff|reboot|unknown) echo "$HOMELAB_STOP_KIND"; return ;;
  esac
  systemctl list-jobs --no-legend --no-pager 2>/dev/null | classify
}

# A previous count, read back out of the file. Anything that is not a plain
# non-negative integer on the expected line is treated as no count at all.
previous() {
  local file="$1" metric="$2" host="$3" v
  [[ -r "$file" ]] || { echo 0; return; }
  v="$(awk -v want="${metric}{host=\"${host}\"}" \
    '$1 == want { print $2; exit }' "$file" 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

render() {
  local host="$1" poweroffs="$2" restarts="$3" unknown="$4" now="$5"
  cat <<EOF
# HELP homelab_clean_shutdowns_total Clean stops of this host that powered it off (#746).
# TYPE homelab_clean_shutdowns_total counter
homelab_clean_shutdowns_total{host="${host}"} ${poweroffs}
# HELP homelab_clean_restarts_total Clean stops that restarted without powering off. Not subtracted (#746).
# TYPE homelab_clean_restarts_total counter
homelab_clean_restarts_total{host="${host}"} ${restarts}
# HELP homelab_clean_stops_unclassified_total Clean stops systemd did not say were either. Not subtracted (#746).
# TYPE homelab_clean_stops_unclassified_total counter
homelab_clean_stops_unclassified_total{host="${host}"} ${unknown}
# HELP homelab_clean_shutdown_timestamp_seconds When the last clean stop of any kind began.
# TYPE homelab_clean_shutdown_timestamp_seconds gauge
homelab_clean_shutdown_timestamp_seconds{host="${host}"} ${now}
EOF
}

mark() {
  local dir="$1" host="$2" now="$3" kind="$4" prom tmp p r u
  prom="${dir}/clean-shutdowns-${host}.prom"
  p="$(previous "$prom" homelab_clean_shutdowns_total "$host")"
  r="$(previous "$prom" homelab_clean_restarts_total "$host")"
  u="$(previous "$prom" homelab_clean_stops_unclassified_total "$host")"
  case "$kind" in
    poweroff) p=$((p + 1)) ;;
    reboot)   r=$((r + 1)) ;;
    *)        u=$((u + 1)) ;;
  esac
  tmp="${prom}.$$"
  render "$host" "$p" "$r" "$u" "$now" > "$tmp" || { rm -f "$tmp"; die "could not write ${tmp}"; }
  chmod 0644 "$tmp" || { rm -f "$tmp"; die "could not chmod ${tmp}"; }
  mv -f "$tmp" "$prom" || { rm -f "$tmp"; die "could not replace ${prom}"; }
  sync "$prom" 2>/dev/null || sync
}

if ((SELF_TEST)); then
  fail=0
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  file="${dir}/clean-shutdowns-fixture.prom"

  check() {
    local name="$1" expect="$2" pattern="$3" got
    got="$(grep -cE -- "$pattern" "$file" 2>/dev/null)"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s -> %s line(s) matching %s, expected %s\n' \
        "$name" "$got" "$pattern" "$expect"
      fail=1
    fi
  }

  is() {
    local name="$1" expect="$2" got="$3"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s -> %s, expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }

  # 1. Classification, from `systemctl list-jobs --no-legend` as systemd 252
  #    prints it mid-shutdown: JOB UNIT TYPE STATE. The poweroff and reboot
  #    lines are the shape of the real thing; the services around them are
  #    illustrative.
  is "Shut Down: poweroff.target is a power-off" poweroff "$(classify <<'EOF'
1203 poweroff.target           start waiting
1205 systemd-poweroff.service  start waiting
1210 middlewared.service       stop  running
EOF
)"
  is "UPS halt: halt.target is a power-off" poweroff "$(classify <<'EOF'
1311 halt.target               start waiting
EOF
)"
  is "Restart: reboot.target is a restart" reboot "$(classify <<'EOF'
1102 reboot.target             start waiting
1104 systemd-reboot.service    start waiting
EOF
)"
  is "kexec is a restart" reboot "$(classify <<<'1400 kexec.target start waiting')"
  is "both appear: the restart wins, because it forgives nothing" reboot \
    "$(classify <<<$'1 poweroff.target start waiting\n2 reboot.target start waiting')"
  is "an empty job list is unknown" unknown "$(classify </dev/null)"
  is "a unit that only contains the word is not it" unknown \
    "$(classify <<<'1 not-a-reboot.target.wants start waiting')"

  # 2. The first power-off after install: no file yet, so the count is one.
  mark "$dir" fixture 1790000000 poweroff
  check "first power-off on a missing file counts one" \
    1 '^homelab_clean_shutdowns_total\{host="fixture"\} 1$'
  check "first power-off is stamped" \
    1 '^homelab_clean_shutdown_timestamp_seconds\{host="fixture"\} 1790000000$'
  check "and no restart was counted" \
    1 '^homelab_clean_restarts_total\{host="fixture"\} 0$'

  # 3. A restart: the power-off count stays put. This is the 2026-10-02 fix.
  mark "$dir" fixture 1790003600 reboot
  check "a restart does NOT count as a clean power-off" \
    1 '^homelab_clean_shutdowns_total\{host="fixture"\} 1$'
  check "a restart is counted as a restart" \
    1 '^homelab_clean_restarts_total\{host="fixture"\} 1$'
  check "the stamp is the latest stop of any kind" \
    1 '^homelab_clean_shutdown_timestamp_seconds\{host="fixture"\} 1790003600$'

  # 4. An unknown stop: neither counter the rule cares about moves.
  mark "$dir" fixture 1790005400 unknown
  check "an unknown stop does NOT count as a clean power-off" \
    1 '^homelab_clean_shutdowns_total\{host="fixture"\} 1$'
  check "an unknown stop is counted as unclassified" \
    1 '^homelab_clean_stops_unclassified_total\{host="fixture"\} 1$'

  # 5. A second power-off reads the first back and adds one.
  mark "$dir" fixture 1790007200 poweroff
  check "second power-off increments" \
    1 '^homelab_clean_shutdowns_total\{host="fixture"\} 2$'
  check "the other counters survive the rewrite" \
    2 '^homelab_clean_(restarts|stops_unclassified)_total\{host="fixture"\} 1$'
  check "exactly one series per metric, never appended" \
    4 '^homelab_clean_'

  # 6. The override exists for this test; a junk value falls through to
  #    systemd rather than being trusted.
  is "HOMELAB_STOP_KIND=poweroff is honoured" poweroff "$(HOMELAB_STOP_KIND=poweroff stop_kind)"
  is "HOMELAB_STOP_KIND=junk is not" 1 \
    "$(HOMELAB_STOP_KIND=junk stop_kind | grep -cxE 'poweroff|reboot|unknown')"

  # 7. A corrupt file starts again from zero rather than failing the shutdown.
  printf 'homelab_clean_shutdowns_total{host="fixture"} banana\n' > "$file"
  mark "$dir" fixture 1790010800 poweroff
  check "a garbled count restarts at one" \
    1 '^homelab_clean_shutdowns_total\{host="fixture"\} 1$'

  # 8. A count written for a different host is not this host's count.
  printf 'homelab_clean_shutdowns_total{host="other"} 40\n' > "$file"
  mark "$dir" fixture 1790014400 poweroff
  check "another host's count is not read" \
    1 '^homelab_clean_shutdowns_total\{host="fixture"\} 1$'

  # 9. `--host` with no NAME must fail, not spin: `shift 2` on one argument
  #    fails without consuming it, and without `set -e` the loop never ends.
  if timeout 5 bash "$0" --host >/dev/null 2>&1; then
    printf '\033[0;31m  FAIL\033[0m --host with no NAME succeeded\n'; fail=1
  elif (( $? == 124 )); then
    printf '\033[0;31m  FAIL\033[0m --host with no NAME hung\n'; fail=1
  else
    printf '\033[0;32m  PASS\033[0m --host with no NAME fails fast\n'
  fi

  # 10. A replace that fails must fail the run, not report a count it never
  #     wrote. `mv` is shadowed by a function that fails, in a subshell, since
  #     root on the pool ignores the permissions a real refusal would need.
  if ( mv() { return 1; }; mark "$dir" fixture 1790018000 poweroff ) 2>/dev/null; then
    printf '\033[0;31m  FAIL\033[0m a failed replace reported success\n'; fail=1
  else
    printf '\033[0;32m  PASS\033[0m a failed replace fails the run\n'
  fi

  # 11. No temp file left behind for the textfile collector to choke on.
  if compgen -G "${file}.*" >/dev/null; then
    printf '\033[0;31m  FAIL\033[0m a temp file was left in the textfile directory\n'
    fail=1
  else
    printf '\033[0;32m  PASS\033[0m no temp file left behind\n'
  fi

  exit "$fail"
fi

[[ -n "$HOST_LABEL" ]] || die "--host NAME is required: the rule joins on it"
[[ -d "$TEXTFILE_DIR" ]] || die "no ${TEXTFILE_DIR}"

kind="$(stop_kind)"
mark "$TEXTFILE_DIR" "$HOST_LABEL" "$(date +%s)" "$kind"
prom="${TEXTFILE_DIR}/clean-shutdowns-${HOST_LABEL}.prom"
printf 'clean-stop host=%s kind=%s power-offs=%s restarts=%s unclassified=%s\n' \
  "$HOST_LABEL" "$kind" \
  "$(previous "$prom" homelab_clean_shutdowns_total "$HOST_LABEL")" \
  "$(previous "$prom" homelab_clean_restarts_total "$HOST_LABEL")" \
  "$(previous "$prom" homelab_clean_stops_unclassified_total "$HOST_LABEL")"
