#!/usr/bin/env bash
#
# Whether `fenrir` is still the appliance its runbook leaves (#1577).
#
# THE GAP. build-the-sensor-guest.md §0 decides that `fenrir` holds the sensor
# stack, the agent collectors, the repository checkout and the stack's age key,
# and nothing else. The audit of 2026-11-13 found it had been a workstation for
# weeks: dotfiles, a gh login, an AI CLI with MCP servers reaching the internet,
# sshd taking passwords, 18 keys authorized. Nobody noticed until somebody
# looked, and docs/security.md's row said so: "Nothing re-checks this". This
# is the re-check.
#
# WHAT IT READS. Each check is one fact the runbook sets, compared with what the
# runbook leaves, and published as 1 (as the runbook leaves it) or 0. A check
# whose input cannot be read is 0, never 1: a collector that passes when
# `sshd -T` errored is the silent shape this repository keeps recording. The
# journal line says which checks failed, and the metrics say only that they did.
#
# NOTHING READ LEAVES THE GUEST AS A VALUE. No key, fingerprint, path, port,
# package or group name is a label. The lab's Prometheus sees `check="<name>"`
# and 0 or 1, so a failing check says where to look and not what was found.
#
# WHAT IT CANNOT CATCH, stated so nobody reads more into a row of 1s. The row
# in docs/security.md is about someone who takes the sensor. Whoever has root on
# `fenrir` can stop this timer, edit this script, or write 1s to the file
# themselves. Reading the same facts from `Saruman` through `qm guest exec`
# (ADR-0088's path) only moves the trust to the guest agent, which the same
# root controls. So this catches drift by accident: the workstation tooling the
# audit found, a key added for a quick job, a snap that came with an upgrade.
# That is the drift that has actually happened here.
#
# WHO SEES IT. The lab's Prometheus pages no one (ADR-0020). ApplianceCheckFailed
# shows in /alerts and Grafana and nowhere else. Letting one bit of it cross to
# the estate, as ADR-0088 lets a named service's health cross, would need an ADR
# of its own, and #1577 did not take that decision.
#
# THE ALLOWLISTS. Everything but the keys is the runbook's own outcome and is
# written below, so a change to the runbook is a change here in the same PR. The
# keys are not: which machines administer the guest is kept on the guest, in
# KEYS_FILE, one SHA256 fingerprint per line, written by the runbook's §4 step.
# A missing or empty KEYS_FILE fails the keys check.
#
# Usage: scripts/collect-appliance-state.sh [--print | --self-test]
#        --print      writes to stdout instead of the textfile directory
#        --self-test  runs the parsers against fixtures
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
# Not a job name in install-timers.sh's JOBS table: collect-patch-state.sh's
# header has the reason.
PROM="${TEXTFILE_DIR}/appliance-state.prom"
HOSTNAME_LABEL="$(hostname)"

USER_NAME=atreus
KEYS_FILE=/etc/homelab/appliance-key-fingerprints
# Twice the checkout as it was on 2026-11-18 (183 MB) and some. The audit found
# 4.8 GB; a checkout that grows past this is worth a look anyway.
HOME_MAX_MB=512

# The groups cloud-init gives the first user, less `lxd` (#1576), plus `docker`
# (§4). Every group here is one the user may be in, not one it must be in.
ALLOWED_GROUPS="atreus adm cdrom sudo dip plugdev users docker"
# The two that snapd needs to exist at all. `hwctl` came with 26.04 and was
# removed (#1576); any other snap is one somebody installed.
ALLOWED_SNAPS="core24 snapd"
# Ubuntu's own deb822 file, curtin's copy of it, and Docker's (§4). apt reads
# only *.list and *.sources, so curtin's .orig is a file and not a source.
ALLOWED_APT_SOURCES="docker.list ubuntu.sources ubuntu.sources.curtin.orig"
# What those files may point at, trailing slash dropped. A filename says
# nothing about its contents: a third-party repository added inside
# ubuntu.sources would pass a filename check (review on #1580).
ALLOWED_APT_URIS="http://us.archive.ubuntu.com/ubuntu http://archive.ubuntu.com/ubuntu"
ALLOWED_APT_URIS+=" http://security.ubuntu.com/ubuntu https://download.docker.com/linux/ubuntu"
# /etc/systemd/user as 26.04 ships it, measured on fenrir 2026-11-19: the
# distribution's enabled user units, which start in any login session. A unit
# put here, or in ~/.config or ~/.local/share/systemd/user, runs in every
# session without linger (review on #1580).
ALLOWED_ETC_USER_UNITS="graphical-session-pre.target.wants
graphical-session-pre.target.wants/xdg-user-dirs.service sockets.target.wants
sockets.target.wants/dirmngr.socket sockets.target.wants/gpg-agent-browser.socket
sockets.target.wants/gpg-agent-extra.socket sockets.target.wants/gpg-agent.socket
sockets.target.wants/gpg-agent-ssh.socket sockets.target.wants/keyboxd.socket
sockets.target.wants/pk-debconf-helper.socket sockets.target.wants/snapd.session-agent.socket
sockets.target.wants/ssh-agent.socket timers.target.wants
timers.target.wants/launchpadlib-cache-clean.timer"
# subset_ok splits on spaces; awk -v refuses a newline (listeners_ok says so).
ALLOWED_ETC_USER_UNITS="${ALLOWED_ETC_USER_UNITS//$'\n'/ }"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- The parsers. Each reads its input on stdin (or from a path argument) and
# returns 0 when the fact is as the runbook leaves it. They take no other input,
# so --self-test can drive every one of them.

# `sshd -T`: the four settings §3's drop-in sets, and the one user it allows.
# sshd -T lowercases keywords and prints each once, so an exact line match is
# safe. allowusers is matched exactly: a second user on the line is drift.
sshd_ok() {
  awk -v user="${USER_NAME}" '
    $1 == "permitrootlogin"              { seen++; if ($2 != "no") bad = 1 }
    $1 == "passwordauthentication"       { seen++; if ($2 != "no") bad = 1 }
    $1 == "kbdinteractiveauthentication" { seen++; if ($2 != "no") bad = 1 }
    $1 == "x11forwarding"                { seen++; if ($2 != "no") bad = 1 }
    $1 == "allowusers"                   { seen++; if (NF != 2 || $2 != user) bad = 1 }
    END { exit (seen == 5 && !bad) ? 0 : 1 }
  '
}

# `ssh-keygen -lf authorized_keys` on stdin, the allowed fingerprints in $1.
# Every key present must be allowed. No key at all also fails: the guest is
# administered over SSH, so an empty file means the read went wrong.
keys_ok() {
  local allow="$1"
  [[ -s "${allow}" ]] || return 1
  awk 'NR == FNR { if ($1 ~ /^SHA256:/) ok[$1] = 1; next }
       { n++; if (!($2 in ok)) bad = 1 }
       END { exit (n > 0 && !bad) ? 0 : 1 }' "${allow}" -
}

# Words on stdin, every one in the allowed list $1. For `id -nG`, `snap list`'s
# names and the apt sources directory.
subset_ok() {
  local allowed="$1"
  awk -v allowed="${allowed}" '
    BEGIN { n = split(allowed, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    { for (i = 1; i <= NF; i++) if (!($i in ok)) bad = 1 }
    END { exit bad ? 1 : 0 }
  '
}

# Whether file $1 has no line matching $2. Absent is a pass. A path that is
# there but is not a readable regular file is a fail, and so is any grep status
# but 1 (no match): grep's 2 is a read error, and a read error proves nothing
# (review on #1580, which found `! grep ... 2>/dev/null` passing on one).
no_line_ok() {
  local file="$1" pattern="$2" rc=0
  [[ -e "${file}" || -L "${file}" ]] || return 0
  [[ -f "${file}" && -r "${file}" ]] || return 1
  grep -qE "${pattern}" "${file}" || rc=$?
  ((rc == 1))
}

# A key line in authorized_keys: anything but a comment or a blank, indented
# or not. sshd skips leading whitespace, so an indented key is a key.
KEY_LINE='^[[:space:]]*[^#[:space:]]'
# An active source line in a one-line-style file, indented or not.
DEB_LINE='^[[:space:]]*deb(-src)?[[:space:]]'

# Active apt source lines on stdin, from .list files and deb822 .sources alike:
# every URI must be one ALLOWED_APT_URIS names. A `deb [opts] URI suite` line
# carries it after the bracketed options; a deb822 stanza in `URIs:`, which may
# list several. No URI at all fails: this guest installs from at least two.
apt_uris_ok() {
  awk -v allowed="${ALLOWED_APT_URIS}" '
    BEGIN { n = split(allowed, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    function check(u) { sub(/\/+$/, "", u); seen++; if (!(u in ok)) bad = 1 }
    /^[[:space:]]*#/ { next }
    $1 == "deb" || $1 == "deb-src" {
      i = 2
      if ($i ~ /^\[/) { while ($i !~ /\]$/ && i < NF) i++; i++ }
      check($i)
    }
    tolower($1) == "uris:" { for (i = 2; i <= NF; i++) check($i) }
    END { exit (seen && !bad) ? 0 : 1 }
  '
}

# `getent passwd` on stdin. The only account that can log in, among the ones a
# person would have (UID 1000 up, short of nobody's 65534), is USER_NAME, and
# its shell is /bin/bash. A second login account is how a workstation starts.
users_ok() {
  awk -F: -v user="${USER_NAME}" '
    $3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {
      if ($1 != user) bad = 1; else { found = 1; if ($7 != "/bin/bash") bad = 1 }
    }
    END { exit (found && !bad) ? 0 : 1 }
  '
}

# `ss -H -lntu` on stdin: what listens in the host's network namespace. The
# sensor's containers have their own, except Zeek (network_mode: host), which
# opens no socket.
#
# Measured on fenrir 2026-11-18:
#   tcp 0.0.0.0:22  [::]:22             sshd
#   tcp 127.0.0.1:12345                 the sensor's Alloy, published to loopback
#   tcp+udp 127.0.0.53%lo:53 127.0.0.54:53   systemd-resolved
#   udp 127.0.0.1:323 [::1]:323         chronyd's command socket
#
# EXACT PAIRS, loopback included. Allowing any loopback port would be quieter,
# and would miss what the audit actually found: tools that listen on localhost
# only, as an AI CLI's MCP servers and a dev server do. A routine change that
# trips this (chrony moving its command socket, say) costs one line here in a
# PR; a miss costs weeks, as it did. Columns are
# `Netid State Recv-Q Send-Q Local:Port Peer:Port`, so $1 is tcp/udp and $5 the
# local address. No listener at all fails too: sshd is always one, so empty
# output means `ss` did not run. One line: awk -v refuses a newline in a value
# (BSD awk errors, and an error here would read as a failed check, not a bug).
ALLOWED_LISTENERS="tcp/0.0.0.0:22 tcp/[::]:22 tcp/127.0.0.1:12345 tcp/127.0.0.53%lo:53 tcp/127.0.0.54:53"
ALLOWED_LISTENERS+=" udp/127.0.0.53%lo:53 udp/127.0.0.54:53 udp/127.0.0.1:323 udp/[::1]:323"
listeners_ok() {
  awk -v allowed="${ALLOWED_LISTENERS}" '
    BEGIN { n = split(allowed, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    NF >= 5 { seen++; if (!(($1 "/" $5) in ok)) bad = 1 }
    END { exit (seen && !bad) ? 0 : 1 }
  '
}

# --- --self-test

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  expect() {
    local name="$1" want="$2" rc
    shift 2
    "$@" && rc=0 || rc=1
    if [[ "${rc}" == "${want}" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "${name}"
    else
      printf '\033[0;31m  FAIL\033[0m %s: returned %s, expected %s\n' "${name}" "${rc}" "${want}"
      fail=1
    fi
  }
  # shellcheck disable=SC2329 # called through expect "$@"
  feed() { local input="$1"; shift; printf '%s\n' "${input}" | "$@"; }

  SSHD_GOOD="port 22
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
x11forwarding no
allowusers atreus"
  expect "sshd: the runbook's settings pass" 0 feed "${SSHD_GOOD}" sshd_ok
  expect "sshd: passwords back on fails" 1 feed "${SSHD_GOOD/passwordauthentication no/passwordauthentication yes}" sshd_ok
  expect "sshd: root by key fails" 1 feed "${SSHD_GOOD/permitrootlogin no/permitrootlogin prohibit-password}" sshd_ok
  expect "sshd: a second allowed user fails" 1 feed "${SSHD_GOOD/allowusers atreus/allowusers atreus ubuntu}" sshd_ok
  # The drop-in gone entirely: sshd prints no allowusers line at all. Five
  # settings must be seen, so a line that is missing is not a line that passed.
  expect "sshd: no allowusers line fails" 1 feed "$(printf '%s\n' "${SSHD_GOOD}" | grep -v allowusers)" sshd_ok
  expect "sshd: empty output (sshd -T failed) fails" 1 feed "" sshd_ok

  printf 'SHA256:aaa\nSHA256:bbb\n' > "${tmp}/allow"
  : > "${tmp}/empty"
  expect "keys: two allowed keys pass" 0 feed "256 SHA256:aaa hicks (ED25519)
256 SHA256:bbb phoenix (ED25519)" keys_ok "${tmp}/allow"
  expect "keys: one extra key fails" 1 feed "256 SHA256:aaa hicks (ED25519)
256 SHA256:ccc imported (ED25519)" keys_ok "${tmp}/allow"
  expect "keys: no keys at all fails" 1 feed "" keys_ok "${tmp}/allow"
  expect "keys: an empty allowlist fails" 1 feed "256 SHA256:aaa hicks (ED25519)" keys_ok "${tmp}/empty"
  expect "keys: a missing allowlist fails" 1 feed "256 SHA256:aaa hicks (ED25519)" keys_ok "${tmp}/absent"

  expect "groups: the runbook's pass" 0 feed "atreus adm cdrom sudo dip plugdev users docker" subset_ok "${ALLOWED_GROUPS}"
  expect "groups: lxd back fails" 1 feed "atreus adm sudo users lxd docker" subset_ok "${ALLOWED_GROUPS}"
  expect "snaps: core24 and snapd pass" 0 feed "core24
snapd" subset_ok "${ALLOWED_SNAPS}"
  expect "snaps: hwctl back fails" 1 feed "core24
hwctl
snapd" subset_ok "${ALLOWED_SNAPS}"
  expect "apt: the measured sources pass" 0 feed "docker.list
ubuntu.sources
ubuntu.sources.curtin.orig" subset_ok "${ALLOWED_APT_SOURCES}"
  expect "apt: 1Password's source fails" 1 feed "1password.list
docker.list
ubuntu.sources" subset_ok "${ALLOWED_APT_SOURCES}"

  # root's keys, through no_line_ok (review on #1580).
  printf '# no keys here\n\n' > "${tmp}/root_comments"
  printf '  ssh-ed25519 AAAA indented\n' > "${tmp}/root_indented"
  mkdir "${tmp}/root_dir"
  expect "root keys: no file passes" 0 no_line_ok "${tmp}/root_absent" "${KEY_LINE}"
  expect "root keys: comments and blanks pass" 0 no_line_ok "${tmp}/root_comments" "${KEY_LINE}"
  expect "root keys: an indented key fails" 1 no_line_ok "${tmp}/root_indented" "${KEY_LINE}"
  # A directory where the file should be: grep exits 2 on it, and a read error
  # is not "no key".
  expect "root keys: a path that is not a regular file fails" 1 no_line_ok "${tmp}/root_dir" "${KEY_LINE}"

  # What fenrir's two source files held on 2026-11-19, concatenated as c_apt does.
  APT_GOOD="deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu resolute stable
Types: deb
URIs: http://us.archive.ubuntu.com/ubuntu/
Suites: resolute resolute-updates resolute-backports
Components: main restricted universe multiverse

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: resolute-security"
  expect "apt: the measured origins pass" 0 feed "${APT_GOOD}" apt_uris_ok
  expect "apt: a third-party origin inside ubuntu.sources fails" 1 feed "${APT_GOOD}

Types: deb
URIs: https://downloads.1password.com/linux/debian/amd64
Suites: stable" apt_uris_ok
  expect "apt: a second URI on an allowed URIs: line fails" 1 feed "${APT_GOOD/URIs: http:\/\/security.ubuntu.com\/ubuntu\//URIs: http://security.ubuntu.com/ubuntu/ https://repo.charm.sh/apt/}" apt_uris_ok
  expect "apt: a .list line without options fails for its origin" 1 feed "${APT_GOOD}
deb https://cli.github.com/packages stable main" apt_uris_ok
  expect "apt: a commented-out origin passes" 0 feed "${APT_GOOD}
# deb https://cli.github.com/packages stable main" apt_uris_ok
  expect "apt: no source at all fails" 1 feed "" apt_uris_ok

  ETC_USER_GOOD="$(printf '%s\n' "${ALLOWED_ETC_USER_UNITS}" | tr ' ' '\n')"
  expect "user units: /etc/systemd/user as 26.04 ships it passes" 0 feed "${ETC_USER_GOOD}" subset_ok "${ALLOWED_ETC_USER_UNITS}"
  expect "user units: a unit enabled in /etc/systemd/user fails" 1 feed "${ETC_USER_GOOD}
default.target.wants/mcp-server.service" subset_ok "${ALLOWED_ETC_USER_UNITS}"
  expect "user units: a unit dropped in /etc/systemd/user fails" 1 feed "${ETC_USER_GOOD}
mcp-server.service" subset_ok "${ALLOWED_ETC_USER_UNITS}"

  PASSWD_GOOD="root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
atreus:x:1000:1000:atreus:/home/atreus:/bin/bash"
  expect "users: atreus alone passes" 0 feed "${PASSWD_GOOD}" users_ok
  expect "users: atreus on zsh fails" 1 feed "${PASSWD_GOOD/\/home\/atreus:\/bin\/bash//home/atreus:/usr/bin/zsh}" users_ok
  expect "users: a second login account fails" 1 feed "${PASSWD_GOOD}
dev:x:1001:1001::/home/dev:/bin/bash" users_ok
  expect "users: a second account with no shell passes" 0 feed "${PASSWD_GOOD}
svc:x:1001:1001::/nonexistent:/usr/sbin/nologin" users_ok
  expect "users: atreus missing fails" 1 feed "root:x:0:0:root:/root:/bin/bash" users_ok

  SS_GOOD="tcp   LISTEN 0 4096       0.0.0.0:22    0.0.0.0:*
tcp   LISTEN 0 4096     127.0.0.1:12345 0.0.0.0:*
tcp   LISTEN 0 4096 127.0.0.53%lo:53    0.0.0.0:*
tcp   LISTEN 0 4096    127.0.0.54:53    0.0.0.0:*
tcp   LISTEN 0 4096          [::]:22       [::]:*
udp   UNCONN 0 0        127.0.0.1:323   0.0.0.0:*
udp   UNCONN 0 0    127.0.0.53%lo:53    0.0.0.0:*
udp   UNCONN 0 0       127.0.0.54:53    0.0.0.0:*
udp   UNCONN 0 0            [::1]:323      [::]:*"
  expect "listeners: what was measured on fenrir passes" 0 feed "${SS_GOOD}" listeners_ok
  expect "listeners: a new service on every address fails" 1 feed "${SS_GOOD}
tcp   LISTEN 0 4096       0.0.0.0:8080  0.0.0.0:*" listeners_ok
  expect "listeners: sshd on a second port fails" 1 feed "${SS_GOOD}
tcp   LISTEN 0 128           [::]:2222     [::]:*" listeners_ok
  expect "listeners: empty output (ss failed) fails" 1 feed "" listeners_ok
  # The case the exact pairs exist for: a tool bound to localhost only.
  expect "listeners: a new loopback-only service fails" 1 feed "${SS_GOOD}
tcp   LISTEN 0 511      127.0.0.1:3000  0.0.0.0:*" listeners_ok
  # And the same port as an allowed one, on the other protocol, is not allowed.
  expect "listeners: chrony's port over tcp fails" 1 feed "${SS_GOOD}
tcp   LISTEN 0 128      127.0.0.1:323   0.0.0.0:*" listeners_ok

  exit "${fail}"
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1
((EUID == 0)) || die "run as root: sshd -T and root's own keys need it"

# --- The checks, in the order the runbook applies them.

declare -A result=()
order=()
record() {
  local name="$1"
  shift
  order+=("${name}")
  if "$@"; then result[${name}]=1; else result[${name}]=0; fi
}

home="$(getent passwd "${USER_NAME}" | cut -d: -f6)"

# Each check's command is in a function so `record` runs it whole, pipes
# included, and a failure anywhere in it is a 0.
c_sshd()     { sshd -T 2>/dev/null | sshd_ok; }
c_keys()     { [[ -r "${home}/.ssh/authorized_keys" ]] \
                 && ssh-keygen -lf "${home}/.ssh/authorized_keys" 2>/dev/null | keys_ok "${KEYS_FILE}"; }
# root has no key at all: no file, or a readable file with no key line in it.
c_root_keys() { no_line_ok /root/.ssh/authorized_keys "${KEY_LINE}"; }
# The distribution's sudoers.d holds a README and nothing else (#1574).
c_sudoers()  { [[ "$(find /etc/sudoers.d -mindepth 1 -printf '%f\n' 2>/dev/null)" == README ]]; }
c_users()    { getent passwd | users_ok; }
# The database, not this process's groups: `id -nG` with no user argument
# reports the groups a process started with, and a session that began before a
# `gpasswd -d` still lists the group it left.
c_groups()   { id -nG "${USER_NAME}" 2>/dev/null | subset_ok "${ALLOWED_GROUPS}"; }
# No user units beyond the distribution's, in any of the three places systemd
# loads them from, and no lingering, so nothing of the user's runs logged out.
# The two in $HOME must be empty or absent; /etc/systemd/user must hold only
# what 26.04 ships.
empty_or_absent() { [[ ! -e "$1" ]] || { [[ -d "$1" && -r "$1" ]] \
                      && [[ -z "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]]; }; }
c_user_units() { empty_or_absent "${home}/.config/systemd/user" \
                   && empty_or_absent "${home}/.local/share/systemd/user" \
                   && [[ ! -e "/var/lib/systemd/linger/${USER_NAME}" ]] \
                   && { [[ ! -e /etc/systemd/user ]] \
                        || { local etc; etc="$(find /etc/systemd/user -mindepth 1 -printf '%P\n')" \
                             && printf '%s\n' "${etc}" | subset_ok "${ALLOWED_ETC_USER_UNITS}"; }; }; }
c_snaps()    { local s; s="$(snap list 2>/dev/null | awk 'NR > 1 { print $1 }')" && [[ -n "${s}" ]] \
                 && printf '%s\n' "${s}" | subset_ok "${ALLOWED_SNAPS}"; }
# Two halves. The files in sources.list.d are the ones the runbook leaves, and
# every URI apt would read, from sources.list and each *.list and *.sources, is
# an allowed one. sources.list itself carries no active line on 26.04.
c_apt()      { no_line_ok /etc/apt/sources.list "${DEB_LINE}" \
                 && find /etc/apt/sources.list.d -mindepth 1 -printf '%f\n' 2>/dev/null \
                    | subset_ok "${ALLOWED_APT_SOURCES}" \
                 && { local f files=(); for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
                        [[ -e "${f}" ]] || continue
                        [[ -f "${f}" && -r "${f}" ]] || return 1
                        files+=("${f}")
                      done
                      ((${#files[@]})) && cat "${files[@]}" | apt_uris_ok; }; }
c_listeners() { ss -H -lntu 2>/dev/null | listeners_ok; }
c_home()     { local mb; mb="$(du -sm "${home}" 2>/dev/null | cut -f1)" \
                 && [[ "${mb}" =~ ^[0-9]+$ ]] && ((mb <= HOME_MAX_MB)); }

if [[ -z "${home}" ]]; then
  # No such user: every check about it fails, and the line below says why.
  printf 'appliance-state: no user %s on this host\n' "${USER_NAME}" >&2
  home=/nonexistent
fi

record sshd        c_sshd
record keys        c_keys
record root_keys   c_root_keys
record sudoers     c_sudoers
record users       c_users
record groups      c_groups
record user_units  c_user_units
record snaps       c_snaps
record apt_sources c_apt
record listeners   c_listeners
record home_size   c_home

failed=()
for name in "${order[@]}"; do ((result[${name}])) || failed+=("${name}"); done

emit() {
  printf '# HELP homelab_appliance_check 1 when this fact is as build-the-sensor-guest.md leaves it, 0 when not or unreadable.\n'
  printf '# TYPE homelab_appliance_check gauge\n'
  for name in "${order[@]}"; do
    printf 'homelab_appliance_check{host="%s",check="%s"} %s\n' "${HOSTNAME_LABEL}" "${name}" "${result[${name}]}"
  done
}

if ((PRINT_ONLY)); then
  emit
  exit 0
fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}: make up STACK=sensor creates it"

# Written beside the target and renamed: collect-patch-state.sh has the reason.
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"

if ((${#failed[@]})); then
  printf 'appliance-state host=%s FAILED: %s\n' "${HOSTNAME_LABEL}" "${failed[*]}"
else
  printf 'appliance-state host=%s all %d checks pass\n' "${HOSTNAME_LABEL}" "${#order[@]}"
fi
