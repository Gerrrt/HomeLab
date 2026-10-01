#!/usr/bin/env bash
#
# How full the hypervisor's guests' filesystems are (#778, ADR-0070).
#
# THE GAP. On 2026-10-01 `odin`'s 30 GB root reached 98%, 622 MB free, on
# superseded Docker images, and nothing would have said so. A full root on odin
# stops the Wazuh manager and the indexer: the SOC goes blind. #775 gave the lab
# Prometheus HostDiskCritical and HostDiskWillFillIn24h for the guests that push
# to it, and they show in the lab's Grafana and page nobody, because the lab has
# no Alertmanager (ADR-0020) and cannot reach the estate's (ADR-0007).
#
# WHAT THIS READS, AND FROM WHERE. `qm guest cmd <vmid> get-fsinfo`, run on the
# hypervisor, which asks each running guest's qemu-guest-agent over the virtio
# serial channel the hypervisor already owns. No network path is involved: the
# answer travels the same way `qm guest exec` does, and leaves through the
# hypervisor's existing pass to VLAN 99 (#88). ADR-0070 records why a guest's
# filesystem CAPACITY may cross when ADR-0028 kept "any metric produced inside
# it" in the lab; the short version is that this is how much of the disk the
# hypervisor allocated is used, the same class of fact as the thin pools under
# it, and nothing about what the guest is doing.
#
# THE ANSWER IS HOSTILE INPUT. VLAN 30 is the segment built to hold attackers, and
# a compromised guest controls what its agent says. So the JSON is parsed in
# python, never by a shell; every byte count must be a non-negative integer with
# used <= total; mountpoints and fstypes are cut to a charset whitelist and a
# length; and a guest gets at most MAX_FS filesystems, so it cannot blow up the
# estate's cardinality. What a lying guest CAN do is lie about its own disk —
# page falsely, or hide its own fill — and ADR-0070 accepts that.
#
# ONE HUNG AGENT MUST NOT LOSE THE OTHERS. odin's agent has hung under load
# before. Each guest is asked under `timeout`, and a guest whose agent does not
# answer, is not installed, or answers nonsense gets homelab_guest_agent_up 0 and
# no filesystem series, while the run carries on to the next.
#
# ROOT IS NEEDED: `qm guest cmd` talks to the guest's QMP/agent sockets.
#
# Usage: scripts/collect-guest-disk-state.sh [--print]
#        scripts/collect-guest-disk-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/guest-disk-state.prom"
HOSTNAME_LABEL="$(hostname)"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-15}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Running VMs from `qm list`, by shape rather than column — the same parse as
# collect-guest-state.sh, copied because collectors install as single files.
# Output: vmid name, for running guests only. A stopped guest has no agent to
# ask, and HypervisorGuestStopped already says it is stopped.
parse_running_vms() {
  awk '
    $1 == "VMID" { next }
    $1 !~ /^[0-9]+$/ { next }
    {
      vmid = $1; status = ""; status_at = 0
      for (i = 2; i <= NF; i++) {
        if ($i == "running" || $i == "stopped" || $i == "paused" || $i == "suspended") {
          status = $i; status_at = i; break
        }
      }
      if (status != "running") next
      name = ""
      for (i = 2; i < status_at; i++) name = name (name == "" ? "" : " ") $i
      if (name == "") name = "vmid-" vmid
      printf "%s %s\n", vmid, name
    }
  '
}

# render MANIFEST — the exposition, from a manifest of one tab-separated line per
# guest asked: vmid, name, the exit status of `qm guest cmd`, and the path its
# stdout was saved to. The answers go through files and not argv for the reason
# collect-smart-state.sh gives, and so that no guest's bytes are ever a shell word.
render() {
  HOST_LABEL="$HOSTNAME_LABEL" python3 - "$1" <<'PY'
import json, os, re, sys

host = os.environ["HOST_LABEL"]
MAX_FS = 32
# Filesystems that are not a disk the hypervisor allocated, or that are
# read-only by construction. The agent mostly leaves these out already; this is
# for the agent that does not.
SKIP_FSTYPES = {"tmpfs", "devtmpfs", "ramfs", "overlay", "squashfs", "iso9660",
                "udf", "nsfs", "autofs", "proc", "sysfs", "cgroup", "cgroup2"}
LABEL_OK = re.compile(r"[^A-Za-z0-9/._:@+-]")


def clean(value, limit: int) -> str:
    # Windows answers C:\ — a backslash would need escaping in the exposition
    # format, and a forward slash says the same thing.
    s = str(value).replace("\\", "/")
    return LABEL_OK.sub("_", s)[:limit]


def count(v):
    # bool is an int in python; a guest saying `true` is not saying a size.
    if isinstance(v, bool) or not isinstance(v, int) or v < 0 or v >= 2**63:
        return None
    return v


agent_up, size, used = [], [], []
queried = 0
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 4:
            continue
        vmid, name, rc, path = parts
        if not vmid.isdigit():
            continue
        queried += 1
        guest = clean(name, 64)
        base = f'host="{host}",guest="{guest}",vmid="{vmid}"'
        doc = None
        if rc == "0":
            try:
                with open(path, encoding="utf-8", errors="replace") as out:
                    doc = json.load(out)
            except (OSError, ValueError):
                doc = None
        if not isinstance(doc, list):
            agent_up.append(f"homelab_guest_agent_up{{{base}}} 0")
            continue
        agent_up.append(f"homelab_guest_agent_up{{{base}}} 1")

        fs = []
        for entry in doc:
            if not isinstance(entry, dict):
                continue
            fstype = clean(entry.get("type", ""), 32)
            if not fstype or fstype in SKIP_FSTYPES:
                continue
            total, usedb = count(entry.get("total-bytes")), count(entry.get("used-bytes"))
            if total is None or usedb is None or total == 0 or usedb > total:
                continue
            mountpoint = clean(entry.get("mountpoint", ""), 128)
            if not mountpoint:
                continue
            fs.append((len(mountpoint), mountpoint, str(entry.get("name", "")), fstype, total, usedb))

        # Shortest mountpoint first, so "/" survives the cap and a bind mount
        # of a device already seen is dropped in favour of where it is really
        # mounted. One series per mountpoint, whatever cleaning made of it.
        fs.sort()
        seen_dev, seen_mp, kept = set(), set(), 0
        for _, mountpoint, dev, fstype, total, usedb in fs:
            if kept >= MAX_FS:
                break
            if (dev and dev in seen_dev) or mountpoint in seen_mp:
                continue
            if dev:
                seen_dev.add(dev)
            seen_mp.add(mountpoint)
            kept += 1
            labels = f'{base},mountpoint="{mountpoint}",fstype="{fstype}"'
            size.append(f"homelab_guest_filesystem_size_bytes{{{labels}}} {total}")
            used.append(f"homelab_guest_filesystem_used_bytes{{{labels}}} {usedb}")


def family(metric, help_, samples):
    print(f"# HELP {metric} {help_}")
    print(f"# TYPE {metric} gauge")
    for s in samples:
        print(s)


family("homelab_guest_filesystem_size_bytes",
       "Size of a guest filesystem as its guest agent reports it, excluding root-reserved blocks.", size)
family("homelab_guest_filesystem_used_bytes",
       "Bytes used on a guest filesystem as its guest agent reports it.", used)
family("homelab_guest_agent_up",
       "1 when a running guest's agent answered get-fsinfo this run.", agent_up)
family("homelab_guest_disk_guests_queried",
       "Running VMs this hypervisor asked for filesystem usage.",
       [f'homelab_guest_disk_guests_queried{{host="{host}"}} {queried}'])
PY
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  HOSTNAME_LABEL=Saruman
  pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$1"; }
  flunk() { printf '\033[0;31m  FAIL\033[0m %s\n%s\n' "$1" "$2"; fail=1; }

  # A guest: write its answer and its manifest line. Name, exit, JSON.
  n=0
  guest() {
    n=$((n + 1))
    printf '%s' "$4" > "${WORK_DIR}/out.$n"
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${WORK_DIR}/out.$n" >> "${WORK_DIR}/manifest"
  }
  has() {
    if grep -qxF -- "$2" <<<"$out"; then pass "$1"; else flunk "$1" "       missing  $2"; fi
  }
  lacks() {
    if grep -qF -- "$2" <<<"$out"; then flunk "$1" "       present  $2"; else pass "$1"; fi
  }

  # odin's shape, with the root at the numbers of 2026-10-01: 622 MB free of a
  # 30 GB root, a data disk, a bind mount of the root's device, and an overlay.
  guest 160 odin 0 '[
    {"name":"sda2","mountpoint":"/","type":"ext4","used-bytes":29378000000,"total-bytes":30000000000,
     "total-bytes-privileged":31600000000,"disk":[{"serial":"0QEMU_QEMU_HARDDISK_drive-scsi0","bus-type":"scsi","dev":"/dev/sda2"}]},
    {"name":"sdb1","mountpoint":"/srv/soc-data","type":"ext4","used-bytes":38000000000,"total-bytes":95000000000},
    {"name":"sda2","mountpoint":"/var/lib/docker/bind","type":"ext4","used-bytes":29378000000,"total-bytes":30000000000},
    {"name":"overlay","mountpoint":"/var/lib/docker/overlay2/abc/merged","type":"overlay","used-bytes":1,"total-bytes":2},
    {"name":"sda1","mountpoint":"/boot/efi","type":"vfat","used-bytes":6000000,"total-bytes":1100000000}
  ]'
  # An agent that is configured and not running.
  guest 140 alexander 255 ''
  # A guest that answered with something that is not JSON.
  guest 190 fenrir 0 'QEMU guest agent is not running'
  # A hostile guest: a mountpoint built to break out of its label, nonsense
  # sizes, and far more filesystems than any real guest has.
  hostile='[{"name":"x","mountpoint":"/a\"} 1\nevil{x=\"","type":"ext4","used-bytes":1,"total-bytes":10},
    {"name":"n","mountpoint":"/neg","type":"ext4","used-bytes":-5,"total-bytes":10},
    {"name":"f","mountpoint":"/float","type":"ext4","used-bytes":1.5,"total-bytes":10},
    {"name":"s","mountpoint":"/str","type":"ext4","used-bytes":"1","total-bytes":10},
    {"name":"o","mountpoint":"/over","type":"ext4","used-bytes":11,"total-bytes":10},
    {"name":"b","mountpoint":"/bool","type":"ext4","used-bytes":true,"total-bytes":10},
    {"name":"z","mountpoint":"/zero","type":"ext4","used-bytes":0,"total-bytes":0}'
  for i in $(seq 1 40); do
    hostile="${hostile},{\"name\":\"d$i\",\"mountpoint\":\"/srv/many/mount$(printf '%02d' "$i")\",\"type\":\"xfs\",\"used-bytes\":1,\"total-bytes\":10}"
  done
  guest 666 mallory 0 "${hostile}]"
  # Windows: a drive letter, and an agent that reports NTFS.
  guest 171 'win dc' 0 '[{"name":"\\\\?\\Volume{1}","mountpoint":"C:\\","type":"NTFS","used-bytes":20000000000,"total-bytes":63000000000}]'
  # An agent that answers, with nothing to report.
  guest 180 empty 0 '[]'

  out="$(render "${WORK_DIR}/manifest")"

  has "odin's root, at 2026-10-01's numbers" \
    'homelab_guest_filesystem_size_bytes{host="Saruman",guest="odin",vmid="160",mountpoint="/",fstype="ext4"} 30000000000'
  has "used is reported beside size" \
    'homelab_guest_filesystem_used_bytes{host="Saruman",guest="odin",vmid="160",mountpoint="/",fstype="ext4"} 29378000000'
  has "odin's data disk" \
    'homelab_guest_filesystem_size_bytes{host="Saruman",guest="odin",vmid="160",mountpoint="/srv/soc-data",fstype="ext4"} 95000000000'
  lacks "a bind mount of a device already seen is not a second disk" 'mountpoint="/var/lib/docker/bind"'
  lacks "an overlay is not a disk" 'fstype="overlay"'
  has "the EFI partition is a disk and is kept" \
    'homelab_guest_filesystem_size_bytes{host="Saruman",guest="odin",vmid="160",mountpoint="/boot/efi",fstype="vfat"} 1100000000'
  has "an agent that answered is up" 'homelab_guest_agent_up{host="Saruman",guest="odin",vmid="160"} 1'
  has "a failed qm guest cmd is agent down, not silence" 'homelab_guest_agent_up{host="Saruman",guest="alexander",vmid="140"} 0'
  lacks "and it has no filesystems" 'guest="alexander",vmid="140",mountpoint'
  has "an answer that is not JSON is agent down" 'homelab_guest_agent_up{host="Saruman",guest="fenrir",vmid="190"} 0'
  has "a hostile mountpoint is cleaned into one label" \
    'homelab_guest_filesystem_size_bytes{host="Saruman",guest="mallory",vmid="666",mountpoint="/a___1_evil_x__",fstype="ext4"} 10'
  lacks "and does not escape it" 'evil{'
  for bad in /neg /float /str /over /bool /zero; do
    lacks "a nonsense size is dropped (${bad})" "mountpoint=\"${bad}\""
  done
  got="$(grep -c '^homelab_guest_filesystem_size_bytes{.*guest="mallory"' <<<"$out")"
  if [[ "$got" == 32 ]]; then pass "a guest gets at most 32 filesystems"; else flunk "a guest gets at most 32 filesystems" "       got $got"; fi
  has "a Windows drive letter, without a backslash" \
    'homelab_guest_filesystem_size_bytes{host="Saruman",guest="win_dc",vmid="171",mountpoint="C:/",fstype="NTFS"} 63000000000'
  has "an empty answer is still an answer" 'homelab_guest_agent_up{host="Saruman",guest="empty",vmid="180"} 1'
  has "every guest asked is counted" 'homelab_guest_disk_guests_queried{host="Saruman"} 6'

  : > "${WORK_DIR}/manifest"
  out="$(render "${WORK_DIR}/manifest")"
  has "no running guests is zero, not silence" 'homelab_guest_disk_guests_queried{host="Saruman"} 0'

  got="$(printf '%s\n' "  VMID NAME        STATUS     MEM(MB)    BOOTDISK(GB) PID
       140 alexander   running    16384             64.00 1234
       150 frodo       stopped    4096              32.00 0
       160 odin        running    16384             32.00 5678" | parse_running_vms | tr '\n' ';')"
  if [[ "$got" == "140 alexander;160 odin;" ]]; then pass "only running VMs are asked"
  else flunk "only running VMs are asked" "       got $got"; fi
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v qm >/dev/null 2>&1 \
  || die "no qm on this host — it is not a Proxmox VE node."
command -v python3 >/dev/null 2>&1 || die "no python3 to parse the agents' answers."

# A BROKEN `qm list` IS NOT A HYPERVISOR WITH NO GUESTS — collect-guest-state.sh
# reported zero guests on Saruman once, and the same check is made here.
qm_raw="$(qm list 2>"${WORK_DIR}/stderr")"
qm_rc=$?
if ((qm_rc != 0)); then
  detail="$(tr -d '\r' < "${WORK_DIR}/stderr" | grep -v '^$' | tail -2 | paste -sd'; ' -)"
  die "qm list failed (exit ${qm_rc})${detail:+ — ${detail}}
Guest disks cannot be read, and nothing is written, so GuestDiskStateStale says so."
fi
printf '%s\n' "$qm_raw" | grep -qE '^\s*VMID' \
  || die "qm list produced no VMID header, so its output was not understood."

: > "${WORK_DIR}/manifest"
n=0
while read -r vmid name; do
  [[ -n "$vmid" ]] || continue
  n=$((n + 1))
  timeout -k 5 "${AGENT_TIMEOUT}" qm guest cmd "$vmid" get-fsinfo \
    > "${WORK_DIR}/out.$n" 2>/dev/null
  rc=$?
  printf '%s\t%s\t%s\t%s\n' "$vmid" "$name" "$rc" "${WORK_DIR}/out.$n" >> "${WORK_DIR}/manifest"
done < <(printf '%s\n' "$qm_raw" | parse_running_vms)

out="$(render "${WORK_DIR}/manifest")" || die "could not render the guests' answers."

if ((PRINT_ONLY)); then printf '%s\n' "$out"; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
printf '%s\n' "$out" > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'guest-disk-state host=%s guests=%s agents_up=%s filesystems=%s\n' "$HOSTNAME_LABEL" "$n" \
  "$(grep -c '^homelab_guest_agent_up{.*} 1$' <<<"$out" || true)" \
  "$(grep -c '^homelab_guest_filesystem_size_bytes{' <<<"$out" || true)"
