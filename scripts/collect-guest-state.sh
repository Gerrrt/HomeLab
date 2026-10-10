#!/usr/bin/env bash
#
# Whether the hypervisor's guests are running (#257).
#
# THE GAP. `Saruman`'s own agent has reported into the estate's stack since
# 2026-09-02 (#88, #240), so the hypervisor is visible on VLAN 99. Its guests are
# not, and by ADR-0007 their telemetry never will be. `alexander` — which has run
# `stacks/lab/` since 2026-09-05 — produces no series here at all; verified
# 2026-09-07, `{instance=~".*alexander.*"}` is empty.
#
# So if the guest dies, the estate sees a healthy DL360 and nothing else.
# RemoteWriteJobStale is the net for a host that goes quiet, and it keys on jobs
# that ARRIVE here, which is exactly why it can never cover something that stays
# in the lab. #257 puts it plainly: "the lab is being built to go quiet."
#
# WHY THIS IS NOT THE TELEMETRY ADR-0007 KEEPS IN THE LAB, which is the whole
# question and is answered in ADR-0028 rather than assumed here. What this emits
# is a property of the HYPERVISOR — how many guests it is running and which —
# read from `qm`/`pct` on the host that already reports to VLAN 99. It carries
# nothing about what a guest is doing: no metric it produces, no log it writes,
# no service it runs. "VM 100 exists and is running" is the same class of fact as
# "this host has 4 CPUs", which the estate already collects from this host.
#
# WHAT IT THEREFORE DOES NOT ANSWER, and this matters more than what it does.
# A guest that is powered on with a dead lab stack inside it looks identical to
# a healthy one. This closes "the guest died" and leaves "the lab stack died"
# open — ADR-0028 records that, and names the firewall pass a real heartbeat
# would need.
#
# DISPOSABLE GUESTS (#438, ADR-0071). Two more hypervisor facts per guest, read
# from `qm config` / `pct config`: whether it carries the Proxmox tag
# `disposable`, and when it was created (`meta: ...,ctime=<epoch>`, which PVE
# writes on create). Together they let the estate notice a throwaway guest that
# has outlived its investigation — DisposableGuestOutlived — without a table
# in this repository of which guests are meant to exist, the shape ADR-0028
# rejected. The tag is set where the guest is made, so the mark and the thing
# marked cannot drift apart. A guest whose config cannot be read loses these
# two series and keeps its run state: they are additions, and the run-state
# guarantees below do not depend on them.
#
# TEMPLATES (#885). A third fact from the same config: `template: 1`, which
# `qm template` writes when it converts a guest. A template can never run, so
# HypervisorGuestStopped reading `stopped` for one is noise — on 2026-10-04 it
# fired for the Packer templates 901 and 911 and was pending for 912. The rule
# excludes `homelab_guest_template == 1`, read here from the guest itself rather
# than inferred from a VMID range, which would break the first time a template
# was made outside 9xx.
#
# ON-DEMAND GUESTS (ADR-0079). A fourth fact, from the same tags line: the
# Proxmox tag `on-demand`, for a guest that is meant to be off between
# sessions — `carbuncle` and `siren`, the domain's two endpoints, which ADR-0029
# starts per session and which fired HypervisorGuestStopped for 51 hours a week.
# Like `disposable`, it is set on the guest (`qm set <vmid> --tags '<existing>;on-demand'`), so the
# mark cannot drift from the guest it marks, and nothing here lists them.
#
# GUESTS STILL BEING MADE. A fifth fact: `lock: clone` or `lock: create` in the
# config. Proxmox writes the new guest's config, locked, before a full clone
# copies its disks or a restore writes them, so for that whole task the
# hypervisor shows a stopped guest that nobody has had a chance to tag yet —
# packer-smoke.sh's VMID 999 went pending on HypervisorGuestStopped that way.
# The clone API takes no tags, so tagging cannot close it atomically; the lock
# can, and it covers tofu's clones and restores as well. Other locks (backup,
# migrate, snapshot) are on guests that already exist and stay visible.
#
# `qm config` and not /etc/pve/qemu-server/<vmid>.conf, although reading the
# file would be faster: the file also carries every snapshot's section, each
# with its own `meta:` and `tags:`, and `qm config` prints the current config
# alone. The cost, measured on Saruman 2026-10-01: about 1.4 s of perl per
# guest, 14.5 s for ten — well inside the unit's 120 s, every ten minutes.
#
# BACKED-UP GUESTS (#921 follow-up). Two more facts, so that a guest golem
# must hold cannot fall out of the backup job unnoticed. On 2026-10-10 the
# domain's six had: tofu destroys with the provider's default purge, and a
# purged destroy removes the VMID from every backup job, so the #448 rebuild
# and a `-replace` each dropped guests from `golem-nightly` with every
# indicator green.
#   - homelab_guest_backup_expected: the Proxmox tag `backup`, set where the
#     guest is made (tofu/guests.tf, or `qm set` for a hand-built guest), so
#     the mark cannot drift from the guest, as with `on-demand`.
#   - homelab_guest_backup_selected: 1 when an ENABLED vzdump job in
#     /etc/pve/jobs.cfg selects the guest, by `vmid`, by `all` less its
#     `exclude`, or by `pool` (members from /etc/pve/user.cfg). Absent for
#     every guest when jobs.cfg exists but cannot be read, never a 0 that
#     would claim "not selected" without knowing. A missing jobs.cfg is a
#     host with no jobs, so every guest is 0.
# GuestNotInBackupJob reads the two together.
#
# NO ROOT NEEDED for the guest reading; the unit runs as root because the
# textfile directory on an agent host is root-owned, the same incidental reason
# as the other agent collectors. /etc/pve/jobs.cfg and user.cfg are
# root:www-data 0640, so the backup selection does need it.
#
# Usage: scripts/collect-guest-state.sh [--print]
#        scripts/collect-guest-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/guest-state.prom"
JOBS_CFG="${JOBS_CFG:-/etc/pve/jobs.cfg}"
USER_CFG="${USER_CFG:-/etc/pve/user.cfg}"
HOSTNAME_LABEL="$(hostname)"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

STDERR_FILE="$(mktemp)"
trap 'rm -f "${STDERR_FILE}"' EXIT

# `qm list` and `pct list` print a header and then fixed columns:
#
#       VMID NAME          STATUS     MEM(MB)  BOOTDISK(GB) PID
#        100 alexander     running    4096            32.00 1234
#
# Parsed by shape rather than by column position, for the reason the gateway
# collector learned: a row without a PID, or a name containing a space, shifts
# every position-based field. VMID is the leading integer, STATUS is the field
# that IS a status, and NAME is what sits between them.
parse_guest_list() {
  local kind="$1"
  awk -v kind="$kind" '
    $1 == "VMID" { next }
    $1 !~ /^[0-9]+$/ { next }
    {
      vmid = $1; status = ""; status_at = 0
      for (i = 2; i <= NF; i++) {
        if ($i == "running" || $i == "stopped" || $i == "paused" || $i == "suspended") {
          status = $i; status_at = i; break
        }
      }
      if (status == "") next
      name = ""
      for (i = 2; i < status_at; i++) name = name (name == "" ? "" : " ") $i
      if (name == "") name = "vmid-" vmid
      printf "%s %s %s %s\n", kind, vmid, name, status
    }
  '
}

# `qm config <vmid>` / `pct config <vmid>` print `key: value` lines:
#
#       meta: creation-qemu=9.2.0,ctime=1759300000
#       name: diabolos
#       tags: disposable;lab
#
# Prints "<disposable> <ctime> <template> <on_demand> <creating> <backup>": 1
# or 0, the epoch or `-` when there is no ctime (a guest created before PVE
# recorded one, or a container), 1 or 0 for `template: 1`, 1 or 0 for the tag
# `on-demand`, 1 or 0 for `lock: clone` or `lock: create`, and 1 or 0 for the
# tag `backup`. PVE stores tags `;`-separated, but accepts `,` and
# spaces on input, so all three split.
parse_guest_config() {
  awk '
    $1 == "tags:" {
      n = split(substr($0, index($0, ":") + 1), t, /[;, ]+/)
      for (i = 1; i <= n; i++) {
        if (t[i] == "disposable") disposable = 1
        if (t[i] == "on-demand") on_demand = 1
        if (t[i] == "backup") backup = 1
      }
    }
    $1 == "meta:" {
      n = split($2, m, ",")
      for (i = 1; i <= n; i++) if (m[i] ~ /^ctime=[0-9]+$/) ctime = substr(m[i], 7)
    }
    $1 == "template:" && $2 == "1" { template = 1 }
    $1 == "lock:" && ($2 == "clone" || $2 == "create") { creating = 1 }
    END { printf "%d %s %d %d %d %d\n", disposable, (ctime == "" ? "-" : ctime), template, on_demand, creating, backup }
  '
}

# /etc/pve/jobs.cfg holds every job as a `<type>: <id>` header and indented
# `key value` lines:
#
#       vzdump: golem-nightly
#               enabled 1
#               storage golem
#               vmid 150,151,160
#
# Prints what each ENABLED vzdump job selects, one per line: `vmid <n>`,
# `all <exclude,list|->` or `pool <name>`. `enabled` defaults to 1 when the
# line is absent. Other job types (replication, realm-sync) are skipped.
parse_backup_jobs() {
  awk '
    function flush() {
      if (type == "vzdump" && enabled != "0") {
        if (all == "1") printf "all %s\n", (exclude == "" ? "-" : exclude)
        else if (pool != "") printf "pool %s\n", pool
        else { n = split(vmid, ids, ","); for (i = 1; i <= n; i++) if (ids[i] ~ /^[0-9]+$/) printf "vmid %s\n", ids[i] }
      }
      type = ""; enabled = ""; all = ""; exclude = ""; pool = ""; vmid = ""
    }
    # A type may carry a hyphen or a digit (`realm-sync:`). Without them such
    # a header is read as a key line, and its fields fold into the job above.
    /^[a-z][a-z0-9-]*: / { flush(); type = substr($1, 1, length($1) - 1); next }
    /^[ \t]+[a-z-]+/ {
      k = $1; v = $2
      if (k == "enabled") enabled = v
      else if (k == "all") all = v
      else if (k == "exclude") exclude = v
      else if (k == "pool") pool = v
      else if (k == "vmid") vmid = v
    }
    END { flush() }
  '
}

# Expands parse_backup_jobs' lines into the selected VMIDs, one per line.
# `$1` is every guest's VMID, space-separated, for `all`; user.cfg on stdin's
# second half is not used: pool members come from USER_CFG directly. A pool
# line in user.cfg is `pool:<name>:<comment>:<vmid,vmid,...>:<storage...>`.
expand_backup_selection() {
  local all_vmids="$1" user_cfg="$2" kind arg v
  while read -r kind arg; do
    case "$kind" in
      vmid) printf '%s\n' "$arg" ;;
      all)
        for v in $all_vmids; do
          [[ ",${arg}," == *",${v},"* ]] || printf '%s\n' "$v"
        done
        ;;
      pool)
        printf '%s\n' "$user_cfg" | awk -F: -v p="$arg" '$1 == "pool" && $2 == p { n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] ~ /^[0-9]+$/) print m[i] }'
        ;;
    esac
  done
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() {
    local name="$1" kind="$2" expect="$3" got
    got="$(printf '%s\n' "$4" | parse_guest_list "$kind" | tr '\n' ';')"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  check "the documented qm list shape" qemu "qemu 100 alexander running;" \
"      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
       100 alexander            running    4096              32.00 1234"
  # A stopped guest has no PID, so the row is one column shorter. Position-based
  # parsing reads BOOTDISK as the PID and, worse, still finds a plausible status.
  check "stopped guest has no PID column" qemu "qemu 101 winsrv stopped;" \
"      VMID NAME       STATUS     MEM(MB)    BOOTDISK(GB) PID
       101 winsrv     stopped    8192              64.00"
  check "a name containing a space" qemu "qemu 102 dc one running;" \
"       102 dc one    running    8192              64.00 999"
  check "mixed states" qemu "qemu 100 alexander running;qemu 101 winsrv stopped;" \
"      VMID NAME       STATUS     MEM(MB)    BOOTDISK(GB) PID
       100 alexander  running    4096              32.00 1234
       101 winsrv     stopped    8192              64.00"
  check "containers are labelled lxc" lxc "lxc 200 wazuh running;" \
"      VMID  STATUS     LOCK         NAME
       200 wazuh      running"
  check "header alone yields nothing" qemu "" \
"      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  check "empty input yields nothing" qemu "" ""

  check_config() {
    local name="$1" expect="$2" got
    got="$(printf '%s\n' "$3" | parse_guest_config)"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  check_config "a disposable guest with a ctime" "1 1759300000 0 0 0 0" \
"boot: order=scsi0
meta: creation-qemu=9.2.0,ctime=1759300000
name: diabolos
tags: disposable"
  check_config "the tag among others, any separator" "1 1759300000 0 0 0 0" \
"meta: creation-qemu=9.2.0,ctime=1759300000
tags: lab,soc;disposable other"
  # A substring is not the tag: `not-disposable` must not count.
  check_config "a tag that merely contains the word" "0 1759300000 0 0 0 0" \
"meta: creation-qemu=9.2.0,ctime=1759300000
tags: not-disposable"
  check_config "no tags line" "0 1759300000 0 0 0 0" \
"meta: creation-qemu=9.2.0,ctime=1759300000
name: alexander"
  check_config "no meta line — created before PVE recorded one" "1 - 0 0 0 0" \
"name: diabolos
tags: disposable"
  check_config "a meta line without ctime" "0 - 0 0 0 0" \
"meta: creation-qemu=9.2.0"
  check_config "empty config" "0 - 0 0 0 0" ""
  check_config "a template" "0 1759300000 1 0 0 0" \
"meta: creation-qemu=9.2.0,ctime=1759300000
name: tpl-ubuntu-2604
template: 1"
  # Only the value 1 is a template; a stray `template: 0` is not.
  check_config "template set to 0" "0 1759300000 0 0 0 0" \
"meta: creation-qemu=9.2.0,ctime=1759300000
template: 0"
  check_config "a disposable template" "1 - 1 0 0 0" \
"tags: disposable
template: 1"
  check_config "an on-demand endpoint" "0 1759300000 0 1 0 0" \
"meta: creation-qemu=9.2.0,ctime=1759300000
name: carbuncle
tags: lab;on-demand"
  # A substring is not the tag here either.
  check_config "a tag that merely contains on-demand" "0 - 0 0 0 0" \
"tags: not-on-demand"
  # A full clone in progress: config written and locked, disks still copying.
  check_config "a clone in progress" "0 1759600000 0 0 1 0" \
"lock: clone
meta: creation-qemu=9.2.0,ctime=1759600000
name: smoke-911"
  check_config "a restore in progress" "0 - 0 0 1 0" \
"lock: create"
  # A backup lock is on a guest that already exists: not "being made".
  check_config "a backup lock is not creation" "0 - 0 0 0 0" \
"lock: backup"
  check_config "a guest golem must hold" "0 1759300000 0 0 0 1" \
"meta: creation-qemu=9.2.0,ctime=1759300000
tags: backup;lab-domain"
  check_config "a tag that merely contains backup" "0 - 0 0 0 0" \
"tags: no-backup"

  check_jobs() {
    local name="$1" expect="$2" got
    got="$(printf '%s\n' "$3" | parse_backup_jobs | expand_backup_selection "$4" "$5" | sort -n | tr '\n' ' ')"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$name" "$got" "$expect"
      fail=1
    fi
  }
  check_jobs "the job as Saruman has it, by vmid" "150 160 162 " \
"vzdump: golem-nightly
    comment ADR-0053%3A the domain and odin to golem; PBS prunes (#485)
    schedule 21:00
    enabled 1
    mode snapshot
    storage golem
    vmid 150,160,162" "150 160 162 170" ""
  check_jobs "a disabled job selects nothing" "" \
"vzdump: golem-nightly
    enabled 0
    vmid 150,160" "150 160" ""
  check_jobs "no enabled line means enabled" "160 " \
"vzdump: nightly
    storage golem
    vmid 160" "160" ""
  check_jobs "all, less its exclude" "150 162 " \
"vzdump: everything
    all 1
    exclude 160,170
    storage golem" "150 160 162 170" ""
  check_jobs "a pool, from user.cfg" "150 151 " \
"vzdump: domain
    pool lab-domain
    storage golem" "150 151 162" \
"user:root@pam:1:0:::::
pool:lab-domain:Managed by tofu/:150,151::
pool:analyst:Managed by tofu/:162::"
  check_jobs "other job types are not backups" "" \
"realm-sync: ad
    enabled 1
replication: 162-0
    vmid 162" "162" ""
  # The order matters: a realm-sync AFTER the backup job, whose `enabled 0`
  # must close its own section and not disable the job above it.
  check_jobs "a hyphenated section after the job is its own section" "160 " \
"vzdump: golem-nightly
    vmid 160
realm-sync: ad
    enabled 0
    scope users" "160" ""
  check_jobs "two jobs, both counted" "160 162 " \
"vzdump: a
    vmid 160

vzdump: b
    vmid 162" "160 162" ""
  check_jobs "no jobs at all" "" "" "160" ""
  # Proxmox writes the keys tab-indented; the samples above use spaces only
  # because this file is indented with spaces (.editorconfig).
  check_jobs "tab-indented, as Proxmox writes it" "160 " \
"$(printf 'vzdump: nightly\n\tenabled 1\n\tvmid 160')" "160" ""
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v qm >/dev/null 2>&1 \
  || die "no qm on this host — it is not a Proxmox VE node.
This collector covers PVE hypervisors only; see the header."

# ZERO GUESTS AND A BROKEN `qm` MUST NOT LOOK THE SAME, and in the first version
# of this they did. It ran on Saruman, `qm list` produced nothing, and the
# collector reported homelab_guests_total=0 — a hypervisor that runs `alexander`
# saying it runs nothing, with every indicator green. That is the exact silence
# this collector exists to break, built into the collector.
#
# So the command's success is checked, and its HEADER is checked. `qm list`
# always prints a VMID header, even with no guests; output without one is a
# failure however it exited.
qm_raw="$(qm list 2>"${STDERR_FILE}")"
qm_rc=$?
if ((qm_rc != 0)); then
  detail="$(tr -d '\r' < "${STDERR_FILE}" | grep -v '^$' | tail -2 | paste -sd'; ' -)"
  die "qm list failed (exit ${qm_rc})${detail:+ — ${detail}}
Guest state cannot be read, which is NOT the same as this hypervisor having no
guests — reporting zero here would hide a dead guest behind a green metric."
fi
if ! printf '%s\n' "$qm_raw" | grep -qE '^\s*VMID'; then
  die "qm list produced no VMID header, so its output was not understood:
${qm_raw:-<empty>}
Refusing to report a guest count from output this does not recognise."
fi

rows="$(printf '%s\n' "$qm_raw" | parse_guest_list qemu)"
if command -v pct >/dev/null 2>&1; then
  # Containers are optional: a PVE node with none still exits 0 with a header,
  # and a pct that fails is not a reason to lose the VM half.
  pct_raw="$(pct list 2>/dev/null)"
  if printf '%s\n' "$pct_raw" | grep -qE '^\s*VMID'; then
    rows="${rows}
$(printf '%s\n' "$pct_raw" | parse_guest_list lxc)"
  fi
fi
rows="$(printf '%s\n' "$rows" | grep -v '^$' || true)"

# The config facts, per guest, keyed "<kind> <vmid>". A config
# that cannot be read leaves no entry, and emit() then writes nothing extra for
# that guest — never a 0, which would claim "not disposable" without knowing.
#
# BUT THAT ABSENCE MUST NOT BE SILENT. With the two series gone,
# DisposableGuestOutlived has nothing to match, while the run state — and so
# GuestStateStopped — stays green: the lifecycle check would vanish with every
# indicator healthy, the exact shape the header of this file exists to refuse.
# So every guest also gets homelab_guest_config_readable, 1 or 0, and
# GuestConfigUnreadable reads it.
declare -A guest_config=()
if [[ -n "$rows" ]]; then
  while read -r kind vmid _rest; do
    [[ -n "$kind" ]] || continue
    case "$kind" in qemu) cmd=qm ;; lxc) cmd=pct ;; *) continue ;; esac
    if cfg="$("$cmd" config "$vmid" 2>/dev/null)"; then
      guest_config["$kind $vmid"]="$(printf '%s\n' "$cfg" | parse_guest_config)"
    fi
  done <<<"$rows"
fi

# The backup selection, as a set of VMIDs. BACKUP_KNOWN=0 when jobs.cfg exists
# and cannot be read, so no homelab_guest_backup_selected is written at all.
declare -A backup_selected=()
BACKUP_KNOWN=1
if [[ -e "$JOBS_CFG" ]]; then
  if jobs_raw="$(cat "$JOBS_CFG" 2>/dev/null)"; then
    user_raw="$(cat "$USER_CFG" 2>/dev/null || true)"
    all_vmids="$(printf '%s\n' "$rows" | awk 'NF {print $2}' | tr '\n' ' ')"
    while read -r v; do
      [[ -n "$v" ]] && backup_selected["$v"]=1
    done < <(printf '%s\n' "$jobs_raw" | parse_backup_jobs | expand_backup_selection "$all_vmids" "$user_raw")
  else
    BACKUP_KNOWN=0
    printf 'guest-state: %s is unreadable; homelab_guest_backup_selected not written\n' "$JOBS_CFG" >&2
  fi
fi

emit_config_facts() {
  local which="$1" metric="$2" kind vmid name _status facts value f_disposable f_ctime f_template f_on_demand f_creating f_backup
  [[ -n "$rows" ]] || return 0
  while read -r kind vmid name _status; do
    [[ -n "$kind" ]] || continue
    facts="${guest_config["$kind $vmid"]:-}"
    if [[ "$which" == backup_selected ]]; then
      ((BACKUP_KNOWN)) || continue
      printf '%s{host="%s",guest="%s",vmid="%s",type="%s"} %s\n' \
        "$metric" "$HOSTNAME_LABEL" "$name" "$vmid" "$kind" "${backup_selected["$vmid"]:-0}"
      continue
    fi
    if [[ "$which" == readable ]]; then
      printf '%s{host="%s",guest="%s",vmid="%s",type="%s"} %s\n' \
        "$metric" "$HOSTNAME_LABEL" "$name" "$vmid" "$kind" "$([[ -n "$facts" ]] && echo 1 || echo 0)"
      continue
    fi
    [[ -n "$facts" ]] || continue
    read -r f_disposable f_ctime f_template f_on_demand f_creating f_backup <<<"$facts"
    case "$which" in
      disposable) value="$f_disposable" ;;
      ctime) value="$f_ctime" ;;
      template) value="$f_template" ;;
      on_demand) value="$f_on_demand" ;;
      creating) value="$f_creating" ;;
      backup_expected) value="$f_backup" ;;
    esac
    [[ "$value" == "-" ]] && continue
    printf '%s{host="%s",guest="%s",vmid="%s",type="%s"} %s\n' \
      "$metric" "$HOSTNAME_LABEL" "$name" "$vmid" "$kind" "$value"
  done <<<"$rows"
}

# Zero guests IS a legitimate answer — but only now that it can be told apart
# from a failure, which is what the checks above buy. The marker is emitted
# either way so absence means the collector stopped, not that the host is idle.
emit() {
  printf '# HELP homelab_guest_running 1 when this hypervisor guest is running.\n'
  printf '# TYPE homelab_guest_running gauge\n'
  if [[ -n "$rows" ]]; then
    while read -r kind vmid name status; do
      [[ -n "$kind" ]] || continue
      printf 'homelab_guest_running{host="%s",guest="%s",vmid="%s",type="%s"} %s\n' \
        "$HOSTNAME_LABEL" "$name" "$vmid" "$kind" \
        "$([[ "$status" == running ]] && echo 1 || echo 0)"
    done <<<"$rows"
  fi
  # One loop per metric, not one per guest: the exposition format wants every
  # sample of a metric contiguous under its own HELP and TYPE, and node_exporter
  # rejects the whole file when they interleave.
  printf '# HELP homelab_guest_disposable 1 when this guest carries the Proxmox tag disposable (ADR-0071).\n'
  printf '# TYPE homelab_guest_disposable gauge\n'
  emit_config_facts disposable homelab_guest_disposable
  printf '# HELP homelab_guest_created_timestamp_seconds When this guest was created, from the ctime in its config.\n'
  printf '# TYPE homelab_guest_created_timestamp_seconds gauge\n'
  emit_config_facts ctime homelab_guest_created_timestamp_seconds
  printf '# HELP homelab_guest_template 1 when this guest is a template (template: 1 in its config), which never runs (#885).\n'
  printf '# TYPE homelab_guest_template gauge\n'
  emit_config_facts template homelab_guest_template
  printf '# HELP homelab_guest_on_demand 1 when this guest carries the Proxmox tag on-demand: off between sessions by design (ADR-0079).\n'
  printf '# TYPE homelab_guest_on_demand gauge\n'
  emit_config_facts on_demand homelab_guest_on_demand
  printf '# HELP homelab_guest_creating 1 while this guest'"'"'s config is locked for clone or create: still being made.\n'
  printf '# TYPE homelab_guest_creating gauge\n'
  emit_config_facts creating homelab_guest_creating
  printf '# HELP homelab_guest_backup_expected 1 when this guest carries the Proxmox tag backup: golem must hold it (ADR-0053).\n'
  printf '# TYPE homelab_guest_backup_expected gauge\n'
  emit_config_facts backup_expected homelab_guest_backup_expected
  printf '# HELP homelab_guest_backup_selected 1 when an enabled vzdump job on this hypervisor selects this guest.\n'
  printf '# TYPE homelab_guest_backup_selected gauge\n'
  emit_config_facts backup_selected homelab_guest_backup_selected
  printf '# HELP homelab_guest_config_readable 1 when this guest'"'"'s config was read, so the config series above can be trusted.\n'
  printf '# TYPE homelab_guest_config_readable gauge\n'
  emit_config_facts readable homelab_guest_config_readable
  printf '# HELP homelab_guests_total Guests this hypervisor knows about, running or not.\n'
  printf '# TYPE homelab_guests_total gauge\n'
  printf 'homelab_guests_total{host="%s"} %s\n' \
    "$HOSTNAME_LABEL" "$(printf '%s\n' "$rows" | grep -c . || true)"
}

if ((PRINT_ONLY)); then emit; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'guest-state host=%s guests=%s running=%s\n' "$HOSTNAME_LABEL" \
  "$(printf '%s\n' "$rows" | grep -c . || true)" \
  "$(printf '%s\n' "$rows" | grep -c ' running$' || true)"
