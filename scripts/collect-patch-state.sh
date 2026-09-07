#!/usr/bin/env bash
#
# How far behind this host's packages are, as metrics.
#
# THE ASYMMETRY #152 IS ABOUT. Every container image here carries a tag and a
# sha256 digest, CI enforces it, `make pin-digests` re-resolves it and Dependabot
# opens a PR per bump. The kernel underneath is patched when somebody remembers.
# docs/security.md names "a vulnerability in pfSense itself" as an accepted,
# undefended threat — a reasonable position to hold deliberately, and a much
# weaker one when nobody knows how far behind the host is.
#
# WHY THIS RATHER THAN PATCHMON. #152 proposed it and then priced it honestly:
# "the point of the issue is the gap, not the tool. A four-host estate probably
# wants the exporter, not another web UI." This is the cheapest thing that
# closes the gap on the hosts it can reach:
#
#   * no new service, so ADR-0004 is untouched
#   * no new image, so nothing else to pin, scan or bump
#   * NO ROOT. /usr/lib/update-notifier/apt-check is readable and runnable by
#     any user, /var/run/reboot-required is a world-readable flag file, and the
#     textfile directory is already owned by the user the timers run as. Every
#     other option here wanted privilege this estate's job table does not have
#     (#339, #351).
#
# WHAT IT COVERS, as of #360. This script now runs on agent hosts too, installed
# by scripts/install-agent-collectors.sh — it is shipped unchanged and needs no
# per-host variant, because everything it reads is in the same place on every
# apt system. `prometheus` and `oracle` are covered today.
#
# WHAT IT STILL DOES NOT COVER. `morpheus` is FreeBSD and has no apt at all —
# `pkg version -vRL=` is the equivalent and nothing here speaks it. That is the
# gap that matters most, since docs/security.md names a pfSense vulnerability as
# an accepted, undefended threat.
#
# `Saruman` is now covered by the apt-get fallback above rather than blocked.
# #360 guessed it would need `update-notifier-common` installed; the truth is
# worse and simpler — Proxmox VE 9 is Debian 13, where that package does not
# exist at all. It is reachable only from the user's Mac, not from the
# monitoring host, so installing there is a hand-run of
# scripts/install-agent-collectors.sh and not something this repository can do.
#
# The limit is written into the metrics rather than left for a reader to infer:
# a host with no data produces no series at all, and `PatchStateStopped` alerts
# when a host that WAS reporting stops — which is the difference between a host
# with nothing to report and a host whose collector died.
#
# Usage: scripts/collect-patch-state.sh [--print]
#        --print writes to stdout instead of the textfile directory.
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

# NOT patch-state.prom, and the collision is worth naming because it cost this
# collector every sample it ever produced. scripts/run-scheduled.sh writes its
# homelab_job_* metrics to "${TEXTFILE_DIR}/${JOB}.prom", and the job is called
# `patch-state`. So the wrapper ran this script, this script wrote the apt
# metrics, and the wrapper then wrote its own outcome over the top of them —
# every run, silently, with both halves reporting success. `make patch-state`
# printed the right numbers, `homelab_job_last_exit_code` was 0, and
# homelab_apt_upgrades_pending did not exist in Prometheus at all.
#
# The filename must therefore not match any job name in install-timers.sh's
# JOBS table. run-scheduled.sh now refuses to overwrite a .prom it did not
# write, so a future collector hits an error instead of this silence.
PROM="${TEXTFILE_DIR}/apt-patch-state.prom"
HOSTNAME_LABEL="$(hostname)"

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# HOW THE COUNTS ARE OBTAINED, and why there are two ways.
#
# apt-check is the authority where it exists: it is update-notifier's own small
# Python program, it already knows how to separate a security update from an
# ordinary one, and it is what every Ubuntu host here has. It writes
# "updates;security" to STDERR, which is not a mistake on its part — it is how
# update-notifier has always reported. Reading stdout instead yields nothing at
# all, silently, which is exactly the shape of failure this repository keeps
# recording.
#
# IT DOES NOT EXIST ON MODERN DEBIAN. `Saruman` is Proxmox VE 9, which is Debian
# 13, where update-notifier-common is gone entirely:
#
#     Package update-notifier-common is not available ...
#     However the following packages replace it: apt-config-auto-update
#
# and apt-config-auto-update ships an apt.conf.d snippet, not apt-check. So this
# is not a missing package to install, it is a host class the collector could not
# cover — which #360 predicted and left open.
#
# THE FALLBACK reads `apt-get -s upgrade`, whose Inst lines name the origin of
# the candidate version:
#
#     Inst libssl3 [3.0.11] (3.0.13 Debian-Security:13/stable-security [amd64])
#
# Counting those is not as good as apt-check and the difference is stated rather
# than glossed: apt-check knows about phased updates and this does not, so on a
# host with a phased rollout in flight the two can disagree by a package or two.
# The security half is matched ONLY inside the parenthesised origin, not anywhere
# on the line, because a package literally named `security-misc` would otherwise
# count itself.
#
# Which method produced the numbers is published as a metric rather than left to
# be inferred, so a host whose counts come from the weaker path says so.
APT_CHECK=/usr/lib/update-notifier/apt-check

# Total and security counts from `apt-get -s upgrade` output on stdin.
# Separated out so --self-test can drive it with fixtures: there is no way to
# make a fully-patched host produce a pending security update on demand, and an
# untested parser for a format this fiddly is how a wrong number gets reported
# confidently.
count_from_apt_get() {
  awk '
    /^Inst / {
      total++
      if (match($0, /\([^)]*\)/)) {
        origin = substr($0, RSTART, RLENGTH)
        if (origin ~ /[Ss]ecurity/) security++
      }
    }
    END { printf "%d %d\n", total+0, security+0 }
  '
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" expect="$2" got
    got="$(printf '%s\n' "$3" | count_from_apt_get)"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s -> %s\n' "$name" "$got"
    else
      printf '\033[0;31m  FAIL\033[0m %s -> %s, expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  check "nothing pending" "0 0" "Reading package lists...
Building dependency tree..."
  check "one ordinary update" "1 0" \
"Inst libfoo [1.0-1] (1.0-2 Debian:13/stable [amd64])"
  check "one security update" "1 1" \
"Inst libssl3 [3.0.11-1] (3.0.13-1 Debian-Security:13/stable-security [amd64])"
  check "mixed, Debian" "3 1" \
"Inst libfoo [1.0-1] (1.0-2 Debian:13/stable [amd64])
Inst libssl3 [3.0.11-1] (3.0.13-1 Debian-Security:13/stable-security [amd64])
Inst libbar [2.0] (2.1 Debian:13/stable [amd64])"
  check "mixed, Ubuntu origins" "2 1" \
"Inst tzdata [2024a-0ubuntu1] (2024b-0ubuntu0.24.04 Ubuntu:24.04/noble-updates [all])
Inst openssl [3.0.13-0ubuntu3] (3.0.13-0ubuntu3.4 Ubuntu:24.04/noble-security [amd64])"
  # The reason the match is scoped to the parentheses. `security-misc` is a real
  # package; a bare grep for "security" on the line counts it as a security
  # update, which is wrong in the direction that matters least loudly.
  check "package named security-misc is not a security update" "1 0" \
"Inst security-misc [3:24.0] (3:24.1 Debian:13/stable [amd64])"
  # And it IS one when the origin says so, so the previous case is not passing
  # by being blind to the package entirely.
  check "security-misc from a security pocket still counts" "1 1" \
"Inst security-misc [3:24.0] (3:24.1 Debian-Security:13/stable-security [amd64])"
  check "upgrade held back is not counted" "1 0" \
"Inst libfoo [1.0-1] (1.0-2 Debian:13/stable [amd64])
The following packages have been kept back:
  libheld"
  exit $fail
fi

if [[ -x "${APT_CHECK}" ]]; then
  METHOD=apt-check
  raw="$("${APT_CHECK}" 2>&1 >/dev/null)" || die "${APT_CHECK} failed"
  [[ "${raw}" =~ ^([0-9]+)\;([0-9]+)$ ]] \
    || die "${APT_CHECK} returned ${raw@Q}, which is not the expected 'updates;security' form"
  pending="${BASH_REMATCH[1]}"
  security="${BASH_REMATCH[2]}"
else
  METHOD=apt-get
  command -v apt-get >/dev/null 2>&1 || die "neither ${APT_CHECK} nor apt-get on this host —
it is not an apt system, and this collector covers apt hosts only. See the header."
  counts="$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | count_from_apt_get)" \
    || die "apt-get -s upgrade failed"
  read -r pending security <<<"${counts}"
  [[ "$pending" =~ ^[0-9]+$ && "$security" =~ ^[0-9]+$ ]] \
    || die "could not parse apt-get output into counts, got ${counts@Q}"
fi

# The flag file the kernel and libc post-install hooks drop. Its presence is the
# only reliable "this host is running something older than what is installed"
# signal on Ubuntu — the running kernel in node_uname_info cannot be compared
# against the installed one, because node_exporter does not report the latter.
reboot_required=0
[[ -f /var/run/reboot-required ]] && reboot_required=1

# How many packages want the reboot, for the description. Absent when no reboot
# is pending, which is why it is counted separately rather than assumed.
reboot_pkgs=0
[[ -f /var/run/reboot-required.pkgs ]] \
  && reboot_pkgs="$(wc -l < /var/run/reboot-required.pkgs | tr -d ' ')"

emit() {
  cat <<EOF
# HELP homelab_apt_upgrades_pending Packages with an available upgrade.
# TYPE homelab_apt_upgrades_pending gauge
homelab_apt_upgrades_pending{host="${HOSTNAME_LABEL}"} ${pending}
# HELP homelab_apt_security_upgrades_pending Of those, the ones from a security pocket.
# TYPE homelab_apt_security_upgrades_pending gauge
homelab_apt_security_upgrades_pending{host="${HOSTNAME_LABEL}"} ${security}
# HELP homelab_reboot_required 1 when a package post-install asked for a reboot.
# TYPE homelab_reboot_required gauge
homelab_reboot_required{host="${HOSTNAME_LABEL}"} ${reboot_required}
# HELP homelab_reboot_required_packages Packages named in /var/run/reboot-required.pkgs.
# TYPE homelab_reboot_required_packages gauge
homelab_reboot_required_packages{host="${HOSTNAME_LABEL}"} ${reboot_pkgs}
# HELP homelab_apt_check_method Which counting method produced the numbers above.
# TYPE homelab_apt_check_method gauge
homelab_apt_check_method{host="${HOSTNAME_LABEL}",method="${METHOD}"} 1
EOF
}

if ((PRINT_ONLY)); then
  emit
  exit 0
fi

[[ -d "${TEXTFILE_DIR}" ]] \
  || die "no ${TEXTFILE_DIR} — run 'sudo ./scripts/install-timers.sh --install' first"

# Written into the textfile directory and renamed, never composed in place: the
# collector reads whatever is there when it reads, and a half-written file parses
# as a truncated one rather than failing. Same reasoning and the same directory
# as scripts/run-scheduled.sh, and the temporary file has to live HERE so the
# rename does not cross a filesystem boundary.
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"

printf 'patch-state host=%s pending=%s security=%s reboot_required=%s\n' \
  "${HOSTNAME_LABEL}" "${pending}" "${security}" "${reboot_required}"
