#!/usr/bin/env bash
#
# Run a maintenance job on a schedule and record whether it worked.
#
# WHY THIS EXISTS
#
# Five commands in this repository were things someone had to remember:
# `make backup`, `make backup-firewall`, `make secrets-verify-backup`,
# `make check-digests` and `make snmp-verify`. Nothing ran any of them, and
# `backups/` did not exist on the host, so the first had never been run at all
# (#77).
#
# A timer alone does not fix that. A timer that stops firing is silent, and
# silence is exactly what a healthy week looks like — the same reasoning
# watchdog.rules.yaml applies to the notification path. So the requirement is
# not "run the job", it is "make NOT having run the job observable". This
# wrapper is the half that turns a run into a fact Prometheus can see; the
# alerts in prometheus/rules/backup.rules.yaml are the half that reads it.
#
# WHY A TEXTFILE AND NOT A PUSH
#
# There is no Pushgateway here and adding one would be a service to pin, back up
# and secure for four numbers. Alloy's prometheus.exporter.unix already runs on
# this host and already bind-mounts / at /rootfs:ro, so a file on disk is
# scraped with no new service and no new port.
#
# It also has the property a push does not: the file persists. A pushed sample
# goes stale and disappears, whereas `time() - <a timestamp on disk>` keeps
# climbing across a Prometheus restart AND across the stack being stopped by one
# of the very jobs being measured. ups.rules.yaml's UpsBatteryUnproven records
# the same reasoning for the same reason.
#
# WHY THE LABEL IS homelab_job AND NOT job
#
# config.alloy's `discovery.relabel "metrics"` sets `job` on every target from
# that exporter, and prometheus.scrape defaults to honor_labels: false — so a
# `job` label in this file would be renamed to `exported_job` and the target's
# value would win. Every alert keyed on it would then match nothing, silently,
# which is the failure shape #63 was about. Do not rename this back.
#
# Usage:
#   scripts/run-scheduled.sh --job <name> [--lock <name>] [--lock-wait <secs>] -- <cmd> [args...]
#
# Environment:
#   TEXTFILE_DIR   where the .prom files go
#                  (default /var/lib/node_exporter/textfile_collector)

set -euo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
LOCK_DIR="${HOMELAB_LOCK_DIR:-/run/lock}"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mwarning:\033[0m %s\n' "$*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
JOB=""
LOCK=""
LOCK_WAIT=900

while (($#)); do
  case "$1" in
    --job)       JOB="${2:-}"; shift 2 ;;
    --lock)      LOCK="${2:-}"; shift 2 ;;
    --lock-wait) LOCK_WAIT="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "${JOB}" ]] || { usage >&2; die "--job is required"; }
(($#)) || { usage >&2; die "no command after --"; }

# The job name becomes a filename AND a Prometheus label value. An unvalidated
# one is an injection into the metric namespace, and a name with a slash in it
# would write outside TEXTFILE_DIR entirely.
[[ "${JOB}" =~ ^[a-z][a-z0-9-]{0,30}$ ]] \
  || die "job name '${JOB}' must match ^[a-z][a-z0-9-]{0,30}\$"

[[ "${LOCK_WAIT}" =~ ^[0-9]+$ ]] || die "--lock-wait must be a whole number of seconds"

LOCK="${LOCK:-${JOB}}"
[[ "${LOCK}" =~ ^[a-z][a-z0-9-]{0,30}$ ]] \
  || die "lock name '${LOCK}' must match ^[a-z][a-z0-9-]{0,30}\$"

PROM="${TEXTFILE_DIR}/${JOB}.prom"

# ---------------------------------------------------------------------------
# Where the outcome goes
# ---------------------------------------------------------------------------
#
# The two failure modes are deliberately not treated alike.
#
# Directory exists but is not writable: die. That is a real misconfiguration on
# the monitoring host, and a wrapper that runs the job while unable to record
# the outcome reproduces exactly the failure #77 is about — the job appears to
# be covered and its absence is undetectable.
#
# Directory does not exist: warn and run anyway. That is a human running
# `make secrets-verify-backup` from a workstation rather than the monitoring
# host, and breaking the target for them would be worse than a missing metric.
RECORD=1
if [[ ! -d "${TEXTFILE_DIR}" ]]; then
  RECORD=0
  warn "no textfile directory at ${TEXTFILE_DIR} — running ${JOB} without recording the outcome"
  warn "on the monitoring host this means the timers were never installed: make install-timers"
elif [[ ! -w "${TEXTFILE_DIR}" ]]; then
  die "${TEXTFILE_DIR} is not writable by $(id -un).
The job would run and its outcome would go unrecorded, which is the failure
this wrapper exists to prevent. Fix the directory, then re-run:
  sudo install -d -m 0755 -o $(id -un) -g $(id -gn) ${TEXTFILE_DIR}"
fi

# ---------------------------------------------------------------------------
# The previous success, read before anything can overwrite it
# ---------------------------------------------------------------------------
#
# A failed run rewrites the whole file — last_run, last_exit_code and duration
# all need updating precisely when the job failed — so the previous success
# timestamp has to be carried forward by hand. Leaving the file untouched
# instead would keep the timestamp but lose the failure.
#
# 0 when there is no prior file. time() - 0 is about 1.8 billion seconds, which
# exceeds every threshold, so "never succeeded" and "has not succeeded lately"
# are the same alert. That is honest, and it is one rule instead of two.
prior_success=0
if [[ -r "${PROM}" ]]; then
  candidate="$(awk '
    $1 ~ /^homelab_job_last_success_timestamp_seconds\{/ { value = $NF }
    END { if (value != "") print value }
  ' "${PROM}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+$ ]] && prior_success="${candidate}"
fi

# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------
#
# One heredoc for all four metrics, so the HELP and TYPE lines are
# byte-identical in every job's file. node_exporter merges the whole directory
# into a single exposition, and the same metric name appearing with two
# different HELP strings is the kind of thing that turns into a scrape error for
# every file at once.
recorded=0
record() {
  local rc="$1" ended started_ts success tmp
  ((recorded)) && return 0
  recorded=1
  ((RECORD)) || return 0

  ended="$(date +%s)"
  started_ts="${STARTED:-${ended}}"
  if ((rc == 0)); then success="${ended}"; else success="${prior_success}"; fi

  # Written to a temp in the SAME directory, then renamed.
  #
  # rename(2) is atomic within a filesystem: a scrape sees either the whole old
  # file or the whole new one. Truncating the target in place — `cp`, or a plain
  # `>` redirect — exposes a window where the collector reads a half-written
  # file.
  #
  # Measured against the pinned Alloy image rather than assumed: a truncated
  # file raises node_textfile_scrape_error to 1 and loses THAT FILE's metrics,
  # while the rest of the directory is parsed and served normally. So the blast
  # radius of a non-atomic write is one job, not all of them — but it is exactly
  # the job whose staleness alert would then fire for a run that succeeded.
  #
  # The temp must not itself end in .prom, or the collector parses it too, and
  # it must not live in /tmp, or the rename crosses a filesystem boundary and
  # silently degrades to copy-then-unlink.
  # Never write over a .prom this wrapper did not write. `patch-state` is both a
  # job name here AND, until it was renamed, the filename
  # scripts/collect-patch-state.sh chose for its own metrics — so the wrapper
  # ran the collector, the collector wrote its samples, and this block put the
  # outcome metrics over the top of them. Every run, silently: the job exited 0,
  # `make patch-state` printed the right numbers, and the apt series never
  # existed in Prometheus (#360).
  #
  # The marker is this wrapper's own first metric name. A file without it was
  # written by something else, and clobbering it would destroy data that has
  # nowhere else to live. Failing loudly instead costs one job's outcome
  # metrics, which surfaces as ScheduledJobStale rather than as nothing at all.
  if [[ -f "${PROM}" ]] \
     && ! grep -q '^homelab_job_last_run_timestamp_seconds' "${PROM}"; then
    die "${PROM} was not written by this wrapper — it holds metrics from
something else, and writing the outcome of '${JOB}' would destroy them.
A job must not share a name with a collector's output file. Rename one of them;
see the header of scripts/collect-patch-state.sh for the instance this caught."
  fi

  tmp="${TEXTFILE_DIR}/${JOB}.prom.$$"
  cat > "${tmp}" <<EOF
# HELP homelab_job_last_run_timestamp_seconds Unix time this job last finished, whatever the outcome.
# TYPE homelab_job_last_run_timestamp_seconds gauge
homelab_job_last_run_timestamp_seconds{homelab_job="${JOB}"} ${ended}
# HELP homelab_job_last_success_timestamp_seconds Unix time this job last exited 0. A failed run carries the previous value forward unchanged.
# TYPE homelab_job_last_success_timestamp_seconds gauge
homelab_job_last_success_timestamp_seconds{homelab_job="${JOB}"} ${success}
# HELP homelab_job_last_exit_code Exit status of the last run. 0 is success.
# TYPE homelab_job_last_exit_code gauge
homelab_job_last_exit_code{homelab_job="${JOB}"} ${rc}
# HELP homelab_job_duration_seconds Wall-clock seconds the last run took.
# TYPE homelab_job_duration_seconds gauge
homelab_job_duration_seconds{homelab_job="${JOB}"} $((ended - started_ts))
EOF

  # Explicit, not inherited from umask. Alloy runs as uid 0 with cap_drop: ALL,
  # so it has no DAC_OVERRIDE and obeys the mode like anyone else — compose.yaml
  # measured exactly that. A 0600 .prom is invisible to the collector and the
  # metric silently never appears.
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${PROM}"

  # One structured line for the journal, which Alloy already ships to Loki with
  # a `unit` label. Findable with LogQL without parsing the wrapped tool's
  # output, which has no format contract at all.
  printf 'homelab-job job=%s exit=%s duration=%ss success=%s\n' \
    "${JOB}" "${rc}" "$((ended - started_ts))" "${success}"
}

# A TimeoutStartSec= expiry sends SIGTERM, and systemd's default KillMode sends
# it to every process in the cgroup — so the wrapped command dies, bash runs the
# trap, and the outcome is still recorded. SIGKILL cannot be trapped and leaves
# no file update; that case is what ScheduledJobStale and the journal are for.
trap 'record 143; exit 143' TERM
trap 'record 130; exit 130' INT
trap 'record "${RC:-1}"' EXIT

# ---------------------------------------------------------------------------
# Lock, then run
# ---------------------------------------------------------------------------
#
# -w rather than -n: a verify run that collides with a slow backup should QUEUE,
# not report failure. Fifteen minutes is the default ceiling, and a job that
# could not get its lock inside that is a genuine finding rather than noise, so
# it is recorded as EX_TEMPFAIL (75) instead of being swallowed.
#
# This does NOT duplicate backup-volumes.sh's own flock. That one is taken only
# on its main path — the case block handling --verify-only, --list, --inventory
# and --prune returns before reaching it — so today a `--verify-only --all` run
# and a real backup can overlap, and the backup's prune can delete a set the
# verifier is mid-read on. Sharing a lock NAME between those two jobs is what
# actually closes that. Different file and different fd from the inner lock, so
# the two nest without deadlocking.
#
# Note also that `After=` and `Conflicts=` between the units would NOT do this.
# Timers do not queue their units into a common transaction, so ordering
# directives between two independently triggered units have no effect at all.
[[ -d "${LOCK_DIR}" ]] || die "no lock directory at ${LOCK_DIR}"
LOCK_FILE="${LOCK_DIR}/homelab-${LOCK}.lock"

exec 9>"${LOCK_FILE}" || die "cannot open ${LOCK_FILE}"
if ! flock -w "${LOCK_WAIT}" 9; then
  # Exits 75 rather than going through die(), which exits 1. The distinction is
  # the point: 1 is "the job ran and failed", 75 is "the job never started".
  # systemd records it, and the EXIT trap records the same number in the metric.
  RC=75
  printf '\033[0;31merror:\033[0m another job holding the '"'"'%s'"'"' lock did not finish within %ss\n' \
    "${LOCK}" "${LOCK_WAIT}" >&2
  exit 75
fi

info "${JOB}: $*"
STARTED="$(date +%s)"
RC=0
"$@" || RC=$?

record "${RC}"
exit "${RC}"
