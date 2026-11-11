#!/usr/bin/env bash
#
# Run a check that may SKIP, and fail if it did.
#
# Usage: scripts/require-no-skip.sh <check> [args...]
#   e.g. scripts/require-no-skip.sh ./scripts/check_syslog_senders.sh
#
# The docker-backed checks (check_loki_rules.sh, test_loki_rules.py,
# check_syslog_senders.sh, check_socket_proxy.sh, check_gosu_skip.sh,
# check_caddyfile.sh, check_glance_config.sh, check_dashboard_roundtrip.sh)
# print SKIP and exit 0 when they cannot reach docker or their binary. That is
# right for a local run, where validate.sh counts the skips through
# --skips-file. CI called them bare, so a runner that lost its daemon, or an
# image pull that never happened, went green with nothing checked. A skip in CI
# is a check nobody runs, the reason lint.sh and self-tests.sh take
# --require-all there.
#
# This appends --skips-file to the check's own arguments, runs it, and exits 1
# if it skipped anything, after printing what. The check's own exit status wins
# when it is not 0.
#
#   scripts/require-no-skip.sh --self-test   fixtures, against a fake check
set -uo pipefail

if [[ "${1:-}" == "--self-test" ]]; then
  T="$(mktemp -d)"
  trap 'rm -rf "${T}"' EXIT
  fail=0
  ok()  { printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
  bad() { printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; fail=1; }
  # The fake check exits FAKE_RC and, if FAKE_SKIP is set, writes it to the
  # skips file it was handed, as the real checks do.
  cat > "${T}/check" <<'FAKE'
#!/usr/bin/env bash
while (($#)); do
  [[ "$1" == "--skips-file" ]] && { [[ -n "${FAKE_SKIP:-}" ]] && printf '%s\n' "${FAKE_SKIP}" >> "$2"; shift; }
  shift
done
exit "${FAKE_RC:-0}"
FAKE
  chmod +x "${T}/check"
  case_() {  # expected-rc rc skip-text description
    local rc=0
    FAKE_RC="$2" FAKE_SKIP="$3" "${BASH_SOURCE[0]}" "${T}/check" --stack x >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" == "$1" ]]; then ok "$4"; else bad "$4 (exit ${rc}, want $1)"; fi
  }
  case_ 0 0 ""                  "a check that ran and passed passes"
  case_ 1 0 "no docker daemon"  "a check that skipped and exited 0 fails"
  case_ 1 1 ""                  "a check that failed fails"
  case_ 3 3 "no docker daemon"  "a check's own failing status wins over a skip"
  rc=0; "${BASH_SOURCE[0]}" >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" == 2 ]]; then ok "no check named is a usage error"; else bad "no check named (exit ${rc}, want 2)"; fi
  rc=0; TMPDIR="${T}/missing" "${BASH_SOURCE[0]}" "${T}/check" >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" == 1 ]]; then ok "no skips file to hand the check fails, not passes"; else bad "no skips file (exit ${rc}, want 1)"; fi
  exit "${fail}"
fi

(($#)) || { printf 'usage: %s <check> [args...] | --self-test\n' "$0" >&2; exit 2; }

skips="$(mktemp)" || { printf 'could not create a skips file; nothing was checked\n' >&2; exit 1; }
trap 'rm -f "${skips}"' EXIT

rc=0
"$@" --skips-file "${skips}" || rc=$?
((rc)) && exit "${rc}"

if [[ -s "${skips}" ]]; then
  while IFS= read -r line; do
    printf '\033[0;31m  FAIL\033[0m skipped, which proves nothing: %s\n' "${line}"
  done < "${skips}"
  printf '%s skipped instead of running. In CI that is a failure.\n' "$1" >&2
  exit 1
fi
