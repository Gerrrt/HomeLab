#!/usr/bin/env bash
#
# Whether the wiki's drift check ran, and what it found, as metrics.
#
# WHAT IT WATCHES. Gerrrt/Lemmiwinks/.claude/tools/drift-check reads twenty-odd
# of the wiki's machine-checkable claims — rule counts, services, probes, jobs,
# guests, OS releases, resolver names, SMART, age recipients, this repository's
# runbook and ADR counts — against Prometheus, Loki, the resolver, GitHub and
# oracle's own disk, and files a "Drift check:" issue on the wiki when a page
# and the machine disagree (Lemmiwinks #282). It runs on oracle, as the user who
# holds the wiki checkout and the GitHub credential, and until #470 it ran from
# that user's crontab with no metric: a job that stops looks exactly like a job
# with nothing to report — #400's shape, and #360's.
#
# WHAT THIS DOES. It is the checker's wrapper on the agent side, the way
# run-scheduled.sh is a job's wrapper on the monitoring host: run it, record
# when, record how it exited, record the four claim counts from its summary
# line, write them where the agent already reads. DriftCheckStopped in
# host.rules.yaml fires when the timestamp goes stale.
#
# WHY THE CHECKER STAYS IN THE WIKI'S REPOSITORY. Its claims are the wiki's
# sentences and its output is a wiki issue; it moves with the pages. This
# repository watches that it runs, and nothing more. It is read off origin/main
# rather than the working tree because that checkout is shared by concurrent
# sessions that switch its branch (the wiki's CLAUDE.md says why).
#
# TWO USERS, AND WHY. The unit runs this as root, for the same one reason
# patch-state's does: the textfile directory on an agent host is root-owned.
# The checker itself must NOT run as root — it needs the wiki checkout, the gh
# login and the git identity of the person who maintains the wiki — so it is
# handed to that user with runuser -l, which gives it their login environment
# rather than root's. The user and the checkout are per-host facts; oracle is
# the only host this collector suits, and the unit says so.
#
# Usage: scripts/collect-drift-check.sh [--print]
#        --print writes to stdout instead of the textfile directory.
#
# Environment:
#   DRIFT_CHECK_USER   default atropos                                 who runs the checker
#   DRIFT_CHECK_REPO   default /home/${DRIFT_CHECK_USER}/code/Gerrrt/Lemmiwinks
#   TEXTFILE_DIR       default /var/lib/node_exporter/textfile_collector
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
USER_NAME="${DRIFT_CHECK_USER:-atropos}"
REPO="${DRIFT_CHECK_REPO:-/home/${USER_NAME}/code/Gerrrt/Lemmiwinks}"
CHECKER=.claude/tools/drift-check

# Not drift-check.prom's job name: run-scheduled.sh refuses to overwrite a .prom
# it did not write, and this one is never wrapped by it — but the rule stands
# (see collect-patch-state.sh: the wrapper overwrote a collector's file for a
# month and nobody noticed).
PROM="${TEXTFILE_DIR}/wiki-drift-check.prom"
HOSTNAME_LABEL="$(hostname)"

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

id -u "${USER_NAME}" >/dev/null 2>&1 || die "no such user ${USER_NAME} — set DRIFT_CHECK_USER"
[[ -d "${REPO}/.git" || -f "${REPO}/.git" ]] || die "no wiki checkout at ${REPO} — set DRIFT_CHECK_REPO"

# RUN THE CHECKER, as its user, from origin/main. Its stdout is the report and
# its last line is the summary this parses; both go to the journal too, so a
# drift is readable in Loki under this unit without opening the wiki's issue.
#
# runuser -l rather than -u: -u keeps root's environment, so HOME=/root and gh
# finds no login. -l gives the user their own, which is where the credential
# and the git identity are. The cd is inside the -c because -l starts in the
# user's home.
if [[ "$(id -u)" == "$(id -u "${USER_NAME}")" ]]; then
  run() { bash -c "$1"; }
else
  [[ "$(id -u)" == 0 ]] || die "must run as root or as ${USER_NAME}"
  run() { runuser -l "${USER_NAME}" -c "$1"; }
fi

started="$(date -u +%s)"
report="$(run "cd '${REPO}' && git fetch -q origin && git show origin/main:${CHECKER} | LEMMI_ROOT='${REPO}' bash -s -- --file-issue" 2>&1)"
rc=$?
printf '%s\n' "${report}"

# "2026-09-14T04:41:23Z: 26 claims — 26 pass, 0 drift, 0 missing anchor, 0 unreadable"
summary="$(printf '%s\n' "${report}" | grep -E '^[0-9T:Z-]+: [0-9]+ claims — ' | tail -1)"
claims=""; pass=""; drift=""; missing=""; unread=""
if [[ -n "${summary}" ]]; then
  claims="$(sed -E 's/^.*: ([0-9]+) claims.*/\1/' <<<"${summary}")"
  pass="$(sed -E 's/^.* — ([0-9]+) pass.*/\1/' <<<"${summary}")"
  drift="$(sed -E 's/^.*, ([0-9]+) drift.*/\1/' <<<"${summary}")"
  missing="$(sed -E 's/^.*, ([0-9]+) missing anchor.*/\1/' <<<"${summary}")"
  unread="$(sed -E 's/^.*, ([0-9]+) unreadable.*/\1/' <<<"${summary}")"
fi
# A run that produced no summary — the checker did not start, or died — is
# recorded as such: exit code as observed, counts absent. Absent counts and a
# fresh timestamp is what "it ran and said nothing" looks like, which is worse
# than a stale timestamp and is left visible rather than smoothed to zero.

emit() {
  printf '# HELP homelab_drift_check_last_run_timestamp_seconds Unix time the wiki drift check last ran on this host, whatever it found.\n'
  printf '# TYPE homelab_drift_check_last_run_timestamp_seconds gauge\n'
  printf 'homelab_drift_check_last_run_timestamp_seconds{host="%s"} %s\n' "${HOSTNAME_LABEL}" "${started}"
  printf '# HELP homelab_drift_check_last_exit_code Exit status of the last run. 0 every claim passed, 1 drift or a missing anchor, 2 a claim could not be read.\n'
  printf '# TYPE homelab_drift_check_last_exit_code gauge\n'
  printf 'homelab_drift_check_last_exit_code{host="%s"} %s\n' "${HOSTNAME_LABEL}" "${rc}"
  if [[ -n "${claims}" ]]; then
    printf '# HELP homelab_drift_check_claims Claims by outcome on the last run. pass + drift + missing + unread is every claim the checker knows.\n'
    printf '# TYPE homelab_drift_check_claims gauge\n'
    printf 'homelab_drift_check_claims{host="%s",result="pass"} %s\n' "${HOSTNAME_LABEL}" "${pass}"
    printf 'homelab_drift_check_claims{host="%s",result="drift"} %s\n' "${HOSTNAME_LABEL}" "${drift}"
    printf 'homelab_drift_check_claims{host="%s",result="missing"} %s\n' "${HOSTNAME_LABEL}" "${missing}"
    printf 'homelab_drift_check_claims{host="%s",result="unread"} %s\n' "${HOSTNAME_LABEL}" "${unread}"
  fi
}

if ((PRINT_ONLY)); then
  emit
  exit "${rc}"
fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no textfile directory at ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"

printf 'drift-check host=%s exit=%s claims=%s pass=%s drift=%s missing=%s unread=%s\n' \
  "${HOSTNAME_LABEL}" "${rc}" "${claims:--}" "${pass:--}" "${drift:--}" "${missing:--}" "${unread:--}"
exit "${rc}"
