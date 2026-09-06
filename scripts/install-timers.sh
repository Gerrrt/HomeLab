#!/usr/bin/env bash
#
# The schedule: what runs, how often, and how stale each proof may get (#77).
#
# WHY THE TABLE IS HERE AND NOT IN THE ALERT RULES
#
# JOBS below is the only place a cadence or a threshold is written down.
# --install writes it out as homelab_job_max_age_seconds, one sample per job,
# into the same textfile directory run-scheduled.sh writes outcomes to. The
# alert rules then JOIN against that series instead of naming jobs themselves,
# which is what lets prometheus/rules/backup.rules.yaml cover six jobs in five
# rules and cover a seventh with no edit at all.
#
# It is also what replaces absent(). "Declared but never ran" is
# `max_age unless on(homelab_job) last_success` — a statement about the table,
# not about a hardcoded list of names that would silently stop growing.
#
# WHY --require-all EXISTS
#
# A local run may honestly skip a check it cannot reach. CI may not: a check
# skipped there is one nobody will ever run. Same contract, same flag name and
# the same reasoning as scripts/lint.sh, which is where this came from.
#
# Two skips deliberately survive it, and both are the same shape: a check that
# only means anything on the deployment host. `systemd-analyze verify` resolves
# ExecStart= against the real filesystem, so from a runner or a worktree every
# unit reports a missing wrapper; and the installed-timer check asks systemd
# what is enabled, which off that host is correctly nothing. Escalating either
# would fail CI for being CI. Both go through skip_offhost() and every other
# skip goes through skip().
#
# WHY --check EXISTS AND WHAT IT ASSERTS
#
# The table and the .timer files are two copies of the same schedule, and this
# repository has been bitten before by two copies of one fact (#68, the amtool
# route assertions). --check derives each timer's real period from
# `systemd-analyze calendar` and asserts the declared max_age is at least twice
# it, so a cadence changed in one place and not the other fails `make validate`
# rather than quietly alerting every week.
#
# There is a THIRD copy, and it is the one that actually bit: what systemd has
# enabled. `check-versions` sat in the table with a correct unit file from #292
# and was never installed, so it simply never ran and no alert could say so —
# max_age is written by --install, so the rule for "declared but never ran" had
# no series to fire on either. Check 6 compares the table against
# `systemctl is-enabled` on the deployment host (#339).
#
# It also asserts that every ExecStart= goes through run-scheduled.sh. That is
# what guarantees a scheduled job records its outcome — and it is the mitigation
# for a real gap: scripts/check_image_pins.py scans the Makefile, scripts/*.sh,
# the workflows and Markdown fences, but NOT systemd units, so an
# `ExecStart=/usr/bin/docker run alpine ...` would sail past every check in this
# repository. Extending that checker is the wrong fix, because its parser is
# bash-shaped and a unit file is not bash. Forbidding units from invoking
# anything but the wrapper closes the same hole from the other side.
#
# Known limit, stated rather than engineered away: a unit could still reach
# docker THROUGH the wrapper by naming a make target that does. Every such
# target already resolves its image via scripts/image-for.sh, which
# check_image_pins.py does enforce.
#
# Usage:
#   scripts/install-timers.sh --check [--skips-file <path>]   assert the schedule is coherent (offline, no privilege)
#   scripts/install-timers.sh --check --require-all           the same, with a skip counted as a failure (CI)
#   scripts/install-timers.sh --install [--no-run]            install and enable the timers (needs root)
#   scripts/install-timers.sh --uninstall                     stop, disable and remove them (needs root)
#   scripts/install-timers.sh --list                          print the table

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="${REPO_ROOT}/systemd"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

# The path the committed units carry. --install refuses to run anywhere else,
# because the units hardcode absolute paths and installing from a throwaway
# checkout would point every timer at a directory that gets deleted.
DEPLOY_ROOT="/home/robo/code/Gerrrt/HomeLab"

# ---------------------------------------------------------------------------
# The schedule
# ---------------------------------------------------------------------------
#
# max_age is how stale a job's last success may get before it is a finding. It
# is roughly twice the period in every case, never once: a threshold equal to
# the period fires on every run that slips past its jitter window, whereas twice
# tolerates one missed run and not two. That is the smallest window that
# distinguishes unlucky from broken.
#
# verify-key-backup has no unit, and that is not an oversight. It needs a human
# to mount removable media — verify-key-backup.sh refuses the live key by
# device:inode precisely so that a copy is what gets tested — so a timer for it
# would be a lie. Its row exists so the threshold is still declared and
# SecretsKeyBackupUnproven can still nag. The one thing that proves the secrets
# are recoverable now has a deadline even though it has no schedule.
#
# The threshold is still declared once here, but since ADR-0024 it is applied
# once PER RECIPIENT rather than once per job: scripts/key-recipients.sh emits a
# series for each key the secrets are encrypted to, and the alert joins against
# this row for all of them. Adding a recipient therefore adds a deadline without
# touching this table, which is the same property every other rule in
# backup.rules.yaml has and the reason none of them name a job.
#
# converge is the only hourly row, and the only one whose threshold is three
# times its period rather than two. It shares the `backups` lock with the two
# backup jobs, so a run that collides with the weekly archive can legitimately
# spend its whole 900s lock wait and then be an hour late; twice the period
# would alert on that, and being late for a reason is not the finding.
#
#     job                unit prefix                max_age  make target
JOBS=(
  "converge          homelab-converge             10800  converge"
  "backup-volumes    homelab-backup-volumes     1209600  backup"
  "verify-backups    homelab-verify-backups      259200  backup"
  "backup-firewall   homelab-backup-firewall     259200  backup-firewall"
  "snmp-verify       homelab-snmp-verify        1209600  snmp-verify"
  "check-versions    homelab-check-versions     1209600  check-versions"
  "dashboards-drift  homelab-dashboards-drift    172800  dashboards-export"
  "loki-coverage     homelab-loki-coverage       172800  check-loki-coverage"
  "patch-state       homelab-patch-state         172800  patch-state"
  "verify-key-backup -                          7776000  secrets-verify-backup"
)

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mwarning:\033[0m %s\n' "$*" >&2; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }

FAILED=0
pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() {
  printf '\033[0;33m  SKIP\033[0m %s\n' "$*"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "$*" >> "${SKIPS_FILE}"
  # Under --require-all a skip is a failure, because a check skipped in CI is
  # one nobody will ever run. Same contract as scripts/lint.sh.
  ((REQUIRE_ALL)) && { printf '\033[0;31m  FAIL\033[0m %s (skipped under --require-all)\n' "$*"; FAILED=1; }
  return 0
}
# A skip that is CORRECT everywhere except the deployment host, and so must not
# become a failure under --require-all.
#
# There are two, both checks that can only mean something on the deployment
# host. systemd-analyze verify resolves ExecStart against the real filesystem,
# so from a CI runner or a worktree every unit reports a missing wrapper. And
# check 6 asks systemd which timers are enabled, which anywhere but that host is
# correctly none — a CI runner failing because it has not installed the
# monitoring host's timers would be nonsense. Escalating either would make CI
# fail for being CI. Every other skip here means a tool was unreachable, which
# in CI is a check nobody runs.
skip_offhost() {
  printf '\033[0;33m  SKIP\033[0m %s\n' "$*"
  [[ -n "${SKIPS_FILE}" ]] && printf '%s\n' "$*" >> "${SKIPS_FILE}"
  return 0
}

usage() { sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=""
SKIPS_FILE=""
RUN_ONCE=1
REQUIRE_ALL=0
while (($#)); do
  case "$1" in
    --check)      MODE=check ;;
    --install)    MODE=install ;;
    --uninstall)  MODE=uninstall ;;
    --list)       MODE=list ;;
    --no-run)     RUN_ONCE=0 ;;
    --skips-file) SKIPS_FILE="${2:-}"; shift ;;
    --require-all) REQUIRE_ALL=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done
[[ -n "${MODE}" ]] || { usage >&2; die "pick a mode"; }

# Fields of one JOBS row, by name, so callers never index into the string.
job_name()   { awk '{print $1}' <<<"$1"; }
job_unit()   { awk '{print $2}' <<<"$1"; }
job_maxage() { awk '{print $3}' <<<"$1"; }
job_target() { awk '{print $4}' <<<"$1"; }

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
if [[ "${MODE}" == list ]]; then
  printf '%-18s %-26s %10s  %s\n' job unit max_age target
  for row in "${JOBS[@]}"; do
    printf '%-18s %-26s %10s  %s\n' \
      "$(job_name "${row}")" "$(job_unit "${row}")" "$(job_maxage "${row}")" "$(job_target "${row}")"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
if [[ "${MODE}" == check ]]; then
  # 1. Every unit named in the table exists, as a pair.
  for row in "${JOBS[@]}"; do
    unit="$(job_unit "${row}")"
    [[ "${unit}" == "-" ]] && continue
    for kind in service timer; do
      [[ -f "${UNIT_DIR}/${unit}.${kind}" ]] \
        || fail "${unit}.${kind} is named in the table but missing from systemd/"
    done
  done

  # 2. Every unit file on disk is named in the table. Catches the reverse
  #    drift: a unit added to systemd/ with no threshold declared for it would
  #    run on a timer with nothing watching whether it stopped.
  for f in "${UNIT_DIR}"/*.service "${UNIT_DIR}"/*.timer; do
    [[ -e "${f}" ]] || continue
    base="$(basename "${f}")"; base="${base%.*}"
    grep -qE "(^| )${base}( |$)" <<<"${JOBS[*]}" \
      || fail "$(basename "${f}") is not in the JOBS table in $(basename "${BASH_SOURCE[0]}")"
  done

  # 3. Every ExecStart goes through the wrapper, names its job correctly, and
  #    calls a make target that exists.
  for row in "${JOBS[@]}"; do
    unit="$(job_unit "${row}")"; name="$(job_name "${row}")"; target="$(job_target "${row}")"
    if [[ "${unit}" != "-" ]]; then
      svc="${UNIT_DIR}/${unit}.service"
      [[ -f "${svc}" ]] || continue
      exec_line="$(grep -m1 '^ExecStart=' "${svc}" || true)"
      [[ "${exec_line}" == "ExecStart=${DEPLOY_ROOT}/scripts/run-scheduled.sh "* ]] \
        || fail "${unit}.service ExecStart does not start with ${DEPLOY_ROOT}/scripts/run-scheduled.sh"
      [[ "${exec_line}" == *"--job ${name} "* ]] \
        || fail "${unit}.service does not pass --job ${name}"
      grep -q "^WorkingDirectory=${DEPLOY_ROOT}\$" "${svc}" \
        || fail "${unit}.service WorkingDirectory is not ${DEPLOY_ROOT}"
    fi
    grep -qE "^${target}:" "${REPO_ROOT}/Makefile" \
      || fail "${name} names make target '${target}', which is not in the Makefile"
  done

  # 4. The declared threshold is at least twice the timer's real period.
  #
  #    Derived from the calendar expression rather than from a second copy of
  #    the cadence: the two consecutive elapses systemd itself computes ARE the
  #    period, so a schedule edited in the .timer and not here cannot pass.
  if command -v systemd-analyze >/dev/null 2>&1; then
    for row in "${JOBS[@]}"; do
      unit="$(job_unit "${row}")"; name="$(job_name "${row}")"; maxage="$(job_maxage "${row}")"
      if [[ "${unit}" == "-" ]]; then
        pass "${name}: no timer, ${maxage}s deadline declared for the human"
        continue
      fi
      timer="${UNIT_DIR}/${unit}.timer"
      [[ -f "${timer}" ]] || continue
      cal="$(grep -m1 '^OnCalendar=' "${timer}" | cut -d= -f2-)"
      readarray -t elapses < <(
        systemd-analyze calendar --iterations=2 "${cal}" 2>/dev/null \
          | sed -n 's/^ *\(Next elapse\|Iteration #2\): *//p'
      )
      if ((${#elapses[@]} < 2)); then
        skip "${name}: could not derive a period from '${cal}'"
        continue
      fi
      first="$(date -d "${elapses[0]}" +%s 2>/dev/null || true)"
      second="$(date -d "${elapses[1]}" +%s 2>/dev/null || true)"
      if [[ -z "${first}" || -z "${second}" ]]; then
        skip "${name}: could not parse the elapse times for '${cal}'"
        continue
      fi
      period=$((second - first))
      if ((maxage >= 2 * period)); then
        pass "${name}: ${cal} every ${period}s, alerts at ${maxage}s"
      else
        fail "${name}: max_age ${maxage}s is less than twice the ${period}s period of '${cal}' — one late run would alert"
      fi
    done
  else
    skip "systemd-analyze not installed — cadence vs threshold unchecked"
  fi

  # 5. Unit syntax. systemd-analyze verify resolves ExecStart against the real
  #    filesystem, so it only means anything from the deployment checkout; from
  #    a worktree or a CI runner every unit would report a missing wrapper.
  if ! command -v systemd-analyze >/dev/null 2>&1; then
    skip "systemd-analyze not installed — unit syntax unchecked"
  elif [[ "${REPO_ROOT}" != "${DEPLOY_ROOT}" ]]; then
    skip_offhost "not the deployment checkout — unit syntax unchecked (ExecStart would not resolve)"
  elif systemd-analyze verify "${UNIT_DIR}"/*.service "${UNIT_DIR}"/*.timer 2>&1; then
    pass "systemd-analyze verify"
  else
    fail "systemd-analyze verify"
  fi

  # 6. That every declared timer is actually ENABLED on this host.
  #
  #    Checks 1-5 compare the table against the .timer FILES, which is two
  #    copies of one fact. This is the third copy, and it is the one nobody was
  #    comparing: what systemd actually has. `check-versions` sat in the table
  #    with a correct unit file from #292 until 2026-09-06 and was never
  #    installed, so the weekly documented-versions check had simply never run
  #    (#339).
  #
  #    Nothing else could see that state. ScheduledJobNeverRan is exactly the
  #    rule for "declared but never ran" —
  #
  #      homelab_job_max_age_seconds
  #        unless on(homelab_job) homelab_job_last_success_timestamp_seconds
  #
  #    — and it cannot fire here, because max_age is written by --install. A job
  #    added to the table and never installed has NEITHER series, both sides of
  #    the `unless` are empty, and there is nothing to alert on. The alerting is
  #    keyed on the installed state while the table is what a pull request
  #    reviews, so a row merges green and the job does not exist.
  #
  #    Read-only: `systemctl is-enabled` queries and changes nothing, so this
  #    stays safe inside `make validate`. It can only mean something on the
  #    deployment checkout — anywhere else the units are not installed and are
  #    not supposed to be — so elsewhere it goes through skip_offhost() for the
  #    same reason check 5 does. On the monitoring host it turns "somebody
  #    forgot to run install-timers" from invisible into a failed validate,
  #    which is where that failure belongs.
  if ! command -v systemctl >/dev/null 2>&1; then
    skip "systemctl not found — installed timers unchecked"
  elif [[ "${REPO_ROOT}" != "${DEPLOY_ROOT}" ]]; then
    skip_offhost "not the deployment checkout — installed timers unchecked (they are not installed here, and should not be)"
  else
    missing=()
    for row in "${JOBS[@]}"; do
      unit="$(job_unit "${row}")"
      # verify-key-backup has no unit: it is a deadline declared for a human,
      # and the table says so with a "-". Nothing to install, nothing to check.
      [[ "${unit}" == "-" ]] && continue
      state="$(systemctl is-enabled "${unit}.timer" 2>/dev/null || true)"
      case "${state}" in
        enabled | enabled-runtime | static | indirect | generated) ;;
        *) missing+=("$(job_name "${row}") (${unit}.timer: ${state:-not installed})") ;;
      esac
    done
    if ((${#missing[@]} == 0)); then
      pass "every declared timer is enabled on this host"
    else
      fail "declared in the table but not enabled here: ${missing[*]}"
      printf '        These jobs do not run and nothing alerts on them — max_age is\n'
      printf '        written by --install, so ScheduledJobNeverRan has no series to\n'
      printf '        fire on either. Fix with: sudo %s --install\n' "$0"
    fi
  fi

  # 7. That CI calls this at all.
  #
  #    Everything above ran in scripts/validate.sh and in no CI job, so it
  #    guarded a `make validate` a contributor might not run and guarded the
  #    pull request not at all. That is the #68 asymmetry, and #68 is the reason
  #    this check knows to look for two copies of one fact — it simply had a
  #    third copy nobody was comparing.
  #
  #    scripts/lint.sh asserts its own caller for the same reason and in the
  #    same direction: the check names the job that must run it, so deleting
  #    the step fails the check rather than silently narrowing coverage.
  WORKFLOW=".github/workflows/ci.yml"
  if [[ ! -f "${WORKFLOW}" ]]; then
    fail "no ${WORKFLOW} — nothing is running this in CI"
  elif grep -qE '^[[:space:]]*run:[[:space:]]*\./scripts/install-timers\.sh --check --require-all[[:space:]]*$' "${WORKFLOW}"; then
    pass "ci.yml runs this check too"
  else
    fail "${WORKFLOW} does not run './scripts/install-timers.sh --check --require-all'"
    printf '        Without it the schedule is guarded by make validate only,\n'
    printf '        which is the asymmetry #68 was about.\n'
  fi

  ((FAILED)) && exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# install / uninstall
# ---------------------------------------------------------------------------
[[ "$(id -u)" == 0 ]] || die "--${MODE} needs root: sudo $0 --${MODE}"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found — this host does not run systemd"

if [[ "${MODE}" == uninstall ]]; then
  for row in "${JOBS[@]}"; do
    unit="$(job_unit "${row}")"
    [[ "${unit}" == "-" ]] && continue
    systemctl disable --now "${unit}.timer" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${unit}.timer" "${SYSTEMD_DIR}/${unit}.service"
    info "removed ${unit}"
  done
  systemctl daemon-reload
  # The .prom files are deliberately left in place. Removing them would make
  # every job look like it had never run rather than like it had stopped being
  # scheduled, and those are different things.
  green "timers removed — ${TEXTFILE_DIR} left alone on purpose"
  exit 0
fi

# The units carry absolute paths. Installing from this session's worktree, or
# from any clone that is not the deployment checkout, would point every timer at
# a directory that disappears — and the failure would look like the jobs simply
# never running, which is the exact condition this whole change exists to make
# visible.
[[ "${REPO_ROOT}" == "${DEPLOY_ROOT}" ]] \
  || die "refusing to install from ${REPO_ROOT}
The committed units hardcode ${DEPLOY_ROOT}. Install from that checkout."

RUN_USER="$(sed -n 's/^User=//p' "${UNIT_DIR}/homelab-backup-volumes.service" | head -1)"
[[ -n "${RUN_USER}" ]] || die "no User= in homelab-backup-volumes.service"
id "${RUN_USER}" >/dev/null 2>&1 || die "user ${RUN_USER} does not exist on this host"

# 0755 and 0644, not 0700. Alloy reads this directory as root with cap_drop:
# [ALL], so it has no DAC_OVERRIDE and obeys the mode like anyone else. The
# contents are four numeric gauges per job — timestamps and exit codes, nothing
# secret — and the write bit stays with ${RUN_USER} alone.
install -d -m 0755 -o "${RUN_USER}" -g "$(id -gn "${RUN_USER}")" "${TEXTFILE_DIR}"
info "textfile directory: ${TEXTFILE_DIR}"

for row in "${JOBS[@]}"; do
  unit="$(job_unit "${row}")"
  [[ "${unit}" == "-" ]] && continue
  install -m 0644 "${UNIT_DIR}/${unit}.service" "${SYSTEMD_DIR}/${unit}.service"
  install -m 0644 "${UNIT_DIR}/${unit}.timer"   "${SYSTEMD_DIR}/${unit}.timer"
done
systemctl daemon-reload

# The declaration file: what the schedule PROMISES, written from the table
# above. Every alert rule joins against this, so a job missing from here is a
# job nothing is watching.
tmp="${TEXTFILE_DIR}/homelab-jobs.prom.$$"
{
  printf '# HELP homelab_job_max_age_seconds How stale this job'"'"'s last success may get before it is a finding.\n'
  printf '# TYPE homelab_job_max_age_seconds gauge\n'
  for row in "${JOBS[@]}"; do
    printf 'homelab_job_max_age_seconds{homelab_job="%s"} %s\n' \
      "$(job_name "${row}")" "$(job_maxage "${row}")"
  done
} > "${tmp}"
chmod 0644 "${tmp}"
chown "${RUN_USER}:$(id -gn "${RUN_USER}")" "${tmp}"
mv -f "${tmp}" "${TEXTFILE_DIR}/homelab-jobs.prom"
info "declared $(( ${#JOBS[@]} )) job thresholds in ${TEXTFILE_DIR}/homelab-jobs.prom"

for row in "${JOBS[@]}"; do
  unit="$(job_unit "${row}")"
  [[ "${unit}" == "-" ]] && continue
  systemctl enable --now "${unit}.timer"
done

# Run each job once so the timers do not spend their first night looking like
# jobs that have never run — and so the plumbing is proven now rather than
# at 03:30. backup-volumes is excluded: it quiesces the monitoring stack, and
# that is not something to do as a side effect of an install.
if ((RUN_ONCE)); then
  for row in "${JOBS[@]}"; do
    unit="$(job_unit "${row}")"; name="$(job_name "${row}")"
    [[ "${unit}" == "-" || "${name}" == "backup-volumes" ]] && continue
    info "priming ${name}"
    systemctl start "${unit}.service" || warn "${name} failed on its first run — journalctl -u ${unit}.service"
  done
fi

printf '\n'
green "installed — systemctl list-timers 'homelab-*'"
info "backup-volumes was NOT primed: it stops the stack. Run it when you can watch:"
info "  sudo systemctl start homelab-backup-volumes.service"
info "verify-key-backup has no timer and never will — docs/runbooks/back-up-the-age-key.md"
