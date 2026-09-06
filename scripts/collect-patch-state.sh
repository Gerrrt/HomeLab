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
# WHAT IT DOES NOT COVER, and this is most of the estate. `morpheus` is FreeBSD
# and has no apt; `Saruman` is Proxmox and would need this shipped to it;
# `oracle` is Ubuntu and would need the same. Only the host it runs on is
# covered, which today is the monitoring host alone. That is a real limit and it
# is written into the metrics themselves rather than left for a reader to infer:
# a host with no data produces no series, and the alert rules are written so
# that absence is visible rather than quiet.
#
# Usage: scripts/collect-patch-state.sh [--print]
#        --print writes to stdout instead of the textfile directory.
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/patch-state.prom"
HOSTNAME_LABEL="$(hostname)"

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# apt-check writes "updates;security_updates" to STDERR, which is not a mistake
# on its part — it is how update-notifier has always reported. Reading stdout
# instead yields nothing at all, silently, which is exactly the shape of failure
# this repository keeps recording.
APT_CHECK=/usr/lib/update-notifier/apt-check
if [[ ! -x "${APT_CHECK}" ]]; then
  die "no ${APT_CHECK} on this host — it is not an apt system, or update-notifier
is not installed. This collector covers apt hosts only; see the header."
fi

raw="$("${APT_CHECK}" 2>&1 >/dev/null)" || die "${APT_CHECK} failed"
[[ "${raw}" =~ ^([0-9]+)\;([0-9]+)$ ]] \
  || die "${APT_CHECK} returned ${raw@Q}, which is not the expected 'updates;security' form"
pending="${BASH_REMATCH[1]}"
security="${BASH_REMATCH[2]}"

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
