#!/usr/bin/env bash
#
# SMART health for the disks the iLO cannot see, as metrics.
#
# WHAT #151 ALREADY COVERED, so this does not do it again. `Saruman`'s two SAS
# drives sit behind an HPE Smart Array and the `ilo` SNMP module already walks
# `cpqDaPhyDrvSmartStatus` — SMART's own predictive verdict, per drive, needing
# no collection at all. `IloDrivePredictiveFailure` and `IloDriveSmartUnreadable`
# are armed on it. That is the RAID 1 mirror #151 was most worried about, and it
# is done. This is the rest: #351.
#
# AND ONE THING THE iLO TURNED OUT NOT TO COVER (#529). The two SM863a SSDs on
# the same controller report every iLO wear column blank, and the controller
# says `SSD Smart Trip Wearout: Not Supported`. So on a host with a Smart Array
# this reads the drives through the logical drive with `-d cciss,N` — the SSDs
# only, leaving the spindles to the iLO. See discover_local().
#
# THE THREE OPTIONS #351 WEIGHED, and why this is the third.
#
#   Scrutiny            a service with its own datastore and UI — exactly what
#                       ADR-0004 argues against adding.
#   smartctl_exporter   a container needing raw device access, in a stack where
#                       every service now runs cap_drop: [ALL], non-root where
#                       the image allows, and read_only (#187, #330, #186). It
#                       would be the one container reversing all three, to read
#                       a value the host reads for free.
#   textfile collector  this. No new service, no new image, no new container
#                       privilege — the same path homelab_job_* already arrives
#                       by, so the plumbing is proven.
#
# TWO COLLECTION MODES, AND ONE UNIT EACH. The estate has two shapes of host and
# they need OPPOSITE privileges, which is why there are two timers rather than
# one job doing both.
#
#   local     Linux hosts running Alloy with a textfile directory: `prometheus`
#             and `oracle`. Disks are enumerated from /sys and smartctl is run
#             against each. NEEDS ROOT: smartctl issues ATA and NVMe
#             pass-through ioctls and no group membership substitutes.
#             homelab-smart-state.service, User=root.
#
#   --ssh     `morpheus`, which is FreeBSD, has no node_exporter, no textfile
#             directory and no Alloy, and whose metrics otherwise arrive over
#             SNMP. #351 assumed it would need "a fourth path" and it does not:
#             smartctl 7.5 is ALREADY INSTALLED there (pfSense ships it for its
#             own SMART status page) and the monitoring host already has a key
#             that reaches it, which is how backup-firewall.sh gets there.
#             NEEDS THE OPERATOR KEY, NOT ROOT: that key is robo's, and root has
#             none. homelab-smart-state-remote.service, User=robo.
#
#             The cost, stated: those series carry instance="prometheus", because
#             that is the Alloy that scraped them. Every alert here keys on
#             `host`, which is correct, but a query grouping by `instance` will
#             attribute morpheus's disk to the monitoring host. That is the price
#             of the host having no agent, and it is cheaper than putting one on
#             the firewall.
#
#   cron      `smaug`, TrueNAS, which runs no Alloy and may not push at all
#             (ADR-0016): Prometheus scrapes its node_exporter, a container that
#             is uid 65534, read-only and cap-dropped, so SMART is not free off
#             the back of it. ADR-0047 runs THIS SCRIPT, unmodified, from a copy
#             on the pool as a root cron job in TrueNAS's own UI, and the
#             container serves the file over the scrape that already exists.
#             Not a systemd timer: the root is immutable and install-agent-
#             collectors.sh cannot land there. The command line it runs is
#
#               PATH=/usr/sbin:/usr/bin:/sbin:/bin \
#               TEXTFILE_DIR=/mnt/erebor/apps/textfile \
#               timeout 600 /bin/bash /mnt/erebor/apps/stack/collect-smart-state.sh --host smaug
#
#             and each piece is there for a reason: cron's default PATH has no
#             /usr/sbin, which is where smartctl lives; TEXTFILE_DIR is the
#             directory the container bind-mounts; `timeout` because a faulted
#             disk answers each command in sixty-second I/O timeouts and this
#             script has none of its own; `--host` because the label has to
#             match the `instance` targets/node.yaml gives the scrape. Those
#             series carry instance="smaug" — the right host, for once, because
#             the scrape is the host's own. build-the-nas.md §6.4 is the
#             procedure.
#
# WHY TWO UNITS AND NOT ONE THAT SWITCHES USER. One job tried to do both and
# failed twice, each time in the gap between "works by hand as robo" and "works
# as the unit". As root it could not read robo's key
# ("Permission denied (publickey)"); dropping to robo with runuser then hit
# NoNewPrivileges ("cannot set user id: Operation not permitted"), and removing
# that flag would have traded a real hardening directive for a workaround —
# with `runuser -u` not resetting HOME waiting behind it. Two units need none of
# that: each runs as the user it needs and neither changes identity. The failure
# mode that remains is a unit failing to do its own job, which is legible.
#
# NOT A SUDOERS RULE either, for the local half. A NOPASSWD entry for smartctl
# is a NOPASSWD entry for `smartctl --set` and `-t select` too, which can write
# to the drive. A root unit that gives back everything it does not need
# (ProtectSystem=strict, one ReadWritePaths, every kernel toggle) is easier to
# reason about than argument matching in sudoers.
#
# NO SERIAL NUMBERS. smartctl reports one per disk and it is deliberately not
# emitted. It identifies hardware, it is unique per drive, and `device` plus
# `model` is enough to act on. docs/security.md's rule about what is published
# is the same instinct.
#
# Usage: scripts/collect-smart-state.sh [--print]
#        scripts/collect-smart-state.sh --ssh USER@HOST --host NAME
#                                       --device TYPE:/dev/NODE [...]
#        scripts/collect-smart-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/smart-state.prom"

PRINT_ONLY=0
SELF_TEST=0
SSH_TARGET=""
HOST_LABEL=""
DEVICES=()

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# stderr from smartctl and ssh is captured rather than discarded, so a failure
# reports WHY. See the warning path below for the run that made this necessary.
STDERR_FILE="$(mktemp)"
trap 'rm -f "${STDERR_FILE}"' EXIT

while (($#)); do
  case "$1" in
    --print)  PRINT_ONLY=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    --ssh)    SSH_TARGET="${2:-}"; shift 2 ;;
    --host)   HOST_LABEL="${2:-}"; shift 2 ;;
    --device) DEVICES+=("${2:-}"); shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,$p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;/^set -/q' ; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

[[ -n "$SSH_TARGET" && -z "$HOST_LABEL" ]] && die "--ssh needs --host NAME for the label"
[[ -n "$SSH_TARGET" && ${#DEVICES[@]} -eq 0 ]] && die "--ssh needs at least one --device TYPE:/dev/NODE

FreeBSD does not enumerate disks the way /sys does, and guessing wrong is how
this reports nothing and calls it success. On morpheus the answer is
  --device nvme:/dev/nvme0"

: "${HOST_LABEL:=$(hostname)}"

# ---------------------------------------------------------------------------
# Collect: one smartctl --json per device, gathered into a JSON array.
# Parsing happens locally in every mode, so the remote host needs nothing but
# smartctl and sh — the same contract backup-firewall.sh holds itself to.
# ---------------------------------------------------------------------------
run_smartctl() {
  local devtype="$1" node="$2"
  if [[ -n "$SSH_TARGET" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
      "smartctl --json -x -d ${devtype} ${node}" 2>"${STDERR_FILE}"
  else
    smartctl --json -x -d "${devtype}" "${node}" 2>"${STDERR_FILE}"
  fi
}

# Local devices, one TYPE:/dev/NODE per line.
#
# Real block devices only: no loop, no ram, no device-mapper, no optical.
# /sys rather than lsblk output parsing, because a model name with a space in
# it turns a column split into a wrong answer.
#
# A DISK BEHIND AN HPE SMART ARRAY IS NOT A DISK (#529). On Saruman /dev/sda and
# /dev/sdb are logical drives the P440ar builds out of the bays, and `-d auto`
# on one reads "HP LOGICAL VOLUME" and no SMART at all. The drives are reached
# through the logical drive instead, one `-d cciss,N` per controller index. The
# indexes are PROBED rather than listed: which bay is which N is the
# controller's answer, and #529 was explicit that it be found, not assumed.
# Sixteen covers every bay the DL360 Gen9 can hold; an empty index answers with
# no model and the renderer drops it.
#
# The driver, not the vendor string, is what marks a host as a Smart Array:
# `hpsa` is the name the kernel gives the only driver that takes cciss
# pass-through here. SYSFS is overridable for the self-test.
SYSFS="${SYSFS:-/sys}"
CCISS_INDEXES="${CCISS_INDEXES:-16}"
discover_local() {
  local dev name scsi host driver
  local -A hpsa_done=()
  for dev in "${SYSFS}"/block/*; do
    name="$(basename "$dev")"
    case "$name" in loop*|ram*|dm-*|sr*|fd*|zram*) continue ;; esac
    [[ -e "${dev}/device" ]] || continue
    # device -> .../0:1:0:0, whose first field is the SCSI host number.
    scsi="$(basename "$(readlink "${dev}/device")")"
    host="${scsi%%:*}"
    driver=""
    [[ "$host" =~ ^[0-9]+$ ]] \
      && driver="$(cat "${SYSFS}/class/scsi_host/host${host}/proc_name" 2>/dev/null)"
    if [[ "$driver" == "hpsa" ]]; then
      # One logical drive is enough to reach every physical drive on that
      # controller; probing through each would read every drive twice.
      [[ -n "${hpsa_done[$host]:-}" ]] && continue
      hpsa_done[$host]=1
      local n
      for ((n = 0; n < CCISS_INDEXES; n++)); do
        printf 'cciss,%s:/dev/%s\n' "$n" "$name"
      done
      continue
    fi
    printf 'auto:/dev/%s\n' "$name"
  done
}

emit() {
  # THE JSON GOES THROUGH A FILE AND NOT argv, and that is not a style
  # preference. Measured on smaug 2026-09-21 (#483): TrueNAS's console shell
  # runs under sudo with ptrace-based subcommand interception, and handing it
  # ~150 KB of `smartctl --json -x` on a command line makes that tracer report
  #   sudo: process NNNN unexpected status 0x57f
  # and SIGKILL python3 before it reads a byte, while `python3 - "hello"` with
  # the same heredoc on the same shell is fine — so it is the SIZE of the
  # argument and not the heredoc. A path is a few bytes and survives anywhere.
  # It also keeps a host's SMART JSON out of `ps`, which argv would not.
  local payload_file rc
  payload_file="$(mktemp)"
  printf '%s' "$payload" > "$payload_file"
  HOST_LABEL="$HOST_LABEL" python3 - "$payload_file" <<'PY'
import json, os, sys

host = os.environ["HOST_LABEL"]
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        docs = json.load(fh)
except json.JSONDecodeError as exc:
    sys.exit(f"smartctl returned something that is not JSON: {exc}")
except OSError as exc:
    sys.exit(f"could not read the collected SMART JSON: {exc}")

rows: dict[str, list[str]] = {}
seen_series: set[tuple[str, str]] = set()

def add(metric: str, help_: str, labels: dict, value) -> None:
    if value is None:
        return
    lab = ",".join(f'{k}="{v}"' for k, v in labels.items())
    # ONE SERIES PER METRIC AND LABEL SET, FIRST VALUE WINS.
    #
    # MEASURED 2026-09-21 on the pinned prom/node-exporter image, because the
    # comment this replaces asserted the opposite and was wrong. A repeated
    # series does NOT make node_exporter reject the file and does NOT raise
    # node_textfile_scrape_error: it keeps the first line, drops the rest, and
    # says nothing — tested with the values agreeing and disagreeing, same
    # result both times.
    #
    # Which is exactly why the choice is made here. The drive that forces it is
    # smaug's Intel DC S3520: smartctl's drive database names BOTH attribute
    # 174 and attribute 192 Unsafe_Shutdown_Count, read at the console on
    # 2026-09-21, both 519 (#483). Today they agree, so the duplicate is
    # harmless and would have stayed invisible. On a drive where they disagree
    # the exporter picks one with nothing written down about which, and a
    # number this collector cannot account for is worse than one it declines to
    # guess at. The wear branch below is the same shape from the other side:
    # two attribute spellings, one metric.
    #
    # Guarded here rather than per metric, because a per-metric flag only
    # protects the metrics someone remembered to think about.
    if (metric, lab) in seen_series:
        return
    seen_series.add((metric, lab))
    rows.setdefault(metric, [f"# HELP {metric} {help_}", f"# TYPE {metric} gauge"])
    rows[metric].append(f"{metric}{{{lab}}} {value}")

seen = 0
for d in docs:
    node = (d.get("device") or {}).get("name")
    if not node:
        continue
    # A drive read through a Smart Array (#529). Every `-d cciss,N` reading
    # carries the SAME device name — the logical volume it was reached through
    # — so the shell tags each with its own label, or the one-series guard in
    # add() would keep the first drive and silently drop the rest.
    #
    # Two kinds of reading are dropped here rather than counted. An index with
    # no drive behind it still answers in JSON, with no model. And a spinning
    # disk is the iLO's: `cpqDaPhyDrvSmartStatus` already watches it and
    # IloDrivePredictiveFailure is armed, so reading it here too would page
    # twice for one disk. What is left is what the iLO cannot report — the
    # SSDs' wear, blank in every cpqDaPhyDrv endurance column.
    if "homelab_label" in d:
        if not d.get("model_name") or d.get("rotation_rate") != 0:
            continue
        node = d["homelab_label"]
    seen += 1
    # model, not serial. See the header.
    base = {"host": host, "device": node, "model": (d.get("model_name") or "unknown").strip()}
    plain = {"host": host, "device": node}

    status = d.get("smart_status") or {}
    if "passed" in status:
        add("homelab_smart_healthy",
            "1 when the drive's own overall SMART self-assessment passes.",
            base, 1 if status["passed"] else 0)

    temp = (d.get("temperature") or {}).get("current")
    add("homelab_smart_temperature_celsius", "Current drive temperature.", plain, temp)

    hours = (d.get("power_on_time") or {}).get("hours")
    add("homelab_smart_power_on_hours", "Hours the drive has been powered on.", plain, hours)

    nvme = d.get("nvme_smart_health_information_log") or {}
    if nvme:
        add("homelab_smart_percentage_used",
            "Vendor estimate of endurance consumed, percent. 100 means the rated life is used.",
            plain, nvme.get("percentage_used"))
        add("homelab_smart_available_spare_percent",
            "Remaining spare capacity, percent.", plain, nvme.get("available_spare"))
        add("homelab_smart_available_spare_threshold_percent",
            "The drive's own spare threshold; below it the drive reports a critical warning.",
            plain, nvme.get("available_spare_threshold"))
        add("homelab_smart_media_errors_total",
            "Unrecovered data integrity errors the drive has recorded.",
            plain, nvme.get("media_errors"))
        add("homelab_smart_unsafe_shutdowns_total",
            "Power lost without a clean shutdown notification.",
            plain, nvme.get("unsafe_shutdowns"))
        # The drive's OWN thermal verdict rather than a threshold chosen here.
        # morpheus idles at 62C with an operational limit of 100C, so any fixed
        # number would be wrong for some drive in the estate; these counters are
        # the manufacturer saying it went too hot, in seconds.
        add("homelab_smart_warning_temp_seconds",
            "Seconds spent above the drive's own warning temperature.",
            plain, nvme.get("warning_temp_time"))
        add("homelab_smart_critical_temp_seconds",
            "Seconds spent above the drive's own critical temperature.",
            plain, nvme.get("critical_comp_time"))
        add("homelab_smart_critical_warning",
            "The NVMe critical warning bitfield. Non-zero is the drive raising a flag.",
            plain, nvme.get("critical_warning"))

    # ATA. Named attributes rather than raw IDs, since the id-to-meaning map is
    # vendor-specific and smartctl has already done that work.
    #
    # Two spellings below map to homelab_smart_percentage_used, and a drive
    # reporting both would render it twice; add() above holds every metric to
    # one series per device and takes the first, so there is no flag here.
    for attr in ((d.get("ata_smart_attributes") or {}).get("table") or []):
        name = (attr.get("name") or "").lower()
        raw = (attr.get("raw") or {}).get("value")
        if name == "reallocated_sector_ct":
            add("homelab_smart_reallocated_sectors",
                "Sectors the drive has remapped. Any growth is the disk failing.",
                plain, raw)
        elif name == "current_pending_sector":
            add("homelab_smart_pending_sectors",
                "Sectors the drive cannot read and has not yet remapped.", plain, raw)
        elif name == "offline_uncorrectable":
            add("homelab_smart_uncorrectable_sectors",
                "Sectors that failed to read and could not be recovered.", plain, raw)
        elif name in ("percent_lifetime_remain", "ssd_life_left"):
            # Reported as REMAINING; inverted so it means the same thing as the
            # NVMe metric of the same name rather than the opposite.
            if raw is not None:
                add("homelab_smart_percentage_used",
                    "Vendor estimate of endurance consumed, percent. 100 means the rated life is used.",
                    plain, 100 - int(raw))
        elif name == "media_wearout_indicator":
            # Intel's spelling (attribute 233, the DC S3520 in smaug). The
            # NORMALISED value is the one that means something — it starts at
            # 100 and falls — and the raw column is not defined for it, unlike
            # the two spellings above. Same inversion, same metric, so
            # SmartDriveWearHigh reads this drive too (#483).
            value = attr.get("value")
            if value is not None:
                add("homelab_smart_percentage_used",
                    "Vendor estimate of endurance consumed, percent. 100 means the rated life is used.",
                    plain, 100 - int(value))
        elif name == "wear_leveling_count":
            # Samsung's spelling (attribute 177, the SM863a pair in Saruman,
            # #529). As with Intel's 233 the NORMALISED value is the life
            # left, starting at 100; the raw column is an average erase count
            # and would read as thousands of percent. Same inversion, same
            # metric, so SmartDriveWearHigh covers these drives with no rule of
            # their own.
            #
            # CONFIRMED on Saruman, 2026-09-23: the first `--print` through the
            # P440ar gave both SM863a a wear series from 177 — 6 % used on
            # cciss,2 and 4 % on cciss,3 — so the attribute does reach the
            # host through the controller.
            value = attr.get("value")
            if value is not None:
                add("homelab_smart_percentage_used",
                    "Vendor estimate of endurance consumed, percent. 100 means the rated life is used.",
                    plain, 100 - int(value))
        elif name == "unsafe_shutdown_count":
            # Intel attributes 174 and 192, BOTH of which smartctl names
            # Unsafe_Shutdown_Count on this drive — the ATA twin of the NVMe
            # counter above. add() takes the first and drops the second; see
            # the duplicate note there, which this drive is the reason for.
            # smaug's boot disk arrived with 509 (hardware.md) and read 519 on
            # 2026-09-21, and #574 asks how often that keeps happening.
            add("homelab_smart_unsafe_shutdowns_total",
                "Power lost without a clean shutdown notification.", plain, raw)

if not seen:
    # smartctl puts its own reason in the JSON rather than only on stderr, and
    # the reason is usually "Permission denied" — it needs root for the raw
    # device. Reporting "no devices" without it sends the reader to look at the
    # disk instead of at who ran the command.
    notes = [
        m.get("string", "")
        for d in docs
        for m in ((d.get("smartctl") or {}).get("messages") or [])
        if m.get("string")
    ]
    sys.exit(
        "smartctl returned JSON with no devices in it"
        + (": " + "; ".join(notes) if notes else "")
    )

# A marker, so a host that stops collecting is distinguishable from a host with
# healthy disks. Same reasoning as PatchStateStopped: every other metric here is
# a number that looks fine when it is absent.
add("homelab_smart_devices", "Devices this collector read on this host.",
    {"host": host}, seen)

for metric in sorted(rows):
    print("\n".join(rows[metric]))
PY
  rc=$?
  rm -f "$payload_file"
  return $rc
}

# ---------------------------------------------------------------------------
# Self-test. The renderer above is the part of this collector that can be wrong
# quietly, and it cannot be exercised by running it: a drive reports what it
# reports, and no host here can be asked to produce a pending sector or a
# second wear attribute on demand. The siblings settled this shape already —
# collect-patch-state.sh, collect-pkg-state.sh and collect-pve-version.sh each
# carry fixtures and `make validate` runs them.
#
# Every fixture below is a reading that actually happened, and the first one is
# why this section exists at all (#483): smaug's boot SSD reports attribute 174
# and attribute 192, both named Unsafe_Shutdown_Count, and the first draft of
# the 174 mapping had no duplicate guard, so it rendered the series twice. That
# was found by reading the drive at the console rather than by any test here —
# which is the argument for these fixtures, not against them.
# ---------------------------------------------------------------------------
if ((SELF_TEST)); then
  fail=0
  HOST_LABEL="fixture"
  out=""

  check() {
    local name="$1" expect="$2" pattern="$3" got
    got="$(printf '%s\n' "$out" | grep -cE -- "$pattern")"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s -> %s line(s) matching %s, expected %s\n' \
        "$name" "$got" "${pattern}" "$expect"
      fail=1
    fi
  }

  # 1. smaug's Intel DC S3520, read at the console 2026-09-21. Two attributes
  #    named Unsafe_Shutdown_Count, and Intel's wearout counter, which reports
  #    REMAINING life in its normalised column and 0 in its raw one — so the
  #    raw column would render a brand-new drive as 100 % consumed.
  payload='[{"device":{"name":"/dev/sdc"},"model_name":"INTEL SSDSC2BB240G7","smart_status":{"passed":true},"temperature":{"current":24},"power_on_time":{"hours":13301},"ata_smart_attributes":{"table":[{"id":5,"name":"Reallocated_Sector_Ct","value":99,"raw":{"value":4}},{"id":174,"name":"Unsafe_Shutdown_Count","value":100,"raw":{"value":519}},{"id":192,"name":"Unsafe_Shutdown_Count","value":100,"raw":{"value":519}},{"id":197,"name":"Current_Pending_Sector","value":100,"raw":{"value":0}},{"id":233,"name":"Media_Wearout_Indicator","value":88,"raw":{"value":0}}]}}]'
  out="$(emit)"
  check "S3520: Unsafe_Shutdown_Count 174 and 192 render ONCE" \
    1 '^homelab_smart_unsafe_shutdowns_total\{host="fixture",device="/dev/sdc"\} 519$'
  check "S3520: wearout reads the normalised column, not the raw one" \
    1 '^homelab_smart_percentage_used\{host="fixture",device="/dev/sdc"\} 12$'
  check "S3520: its four reallocated sectors" \
    1 '^homelab_smart_reallocated_sectors\{host="fixture",device="/dev/sdc"\} 4$'
  check "S3520: one device seen" 1 '^homelab_smart_devices\{host="fixture"\} 1$'

  # 2. smaug's faulted Exos, the same evening. Overall assessment still PASSED,
  #    which is the whole reason SmartDriveBadSectors does not read healthy.
  payload='[{"device":{"name":"/dev/sdb"},"model_name":"ST18000NM003D-3DL103","smart_status":{"passed":true},"power_on_time":{"hours":54},"ata_smart_attributes":{"table":[{"id":5,"name":"Reallocated_Sector_Ct","value":100,"raw":{"value":0}},{"id":197,"name":"Current_Pending_Sector","value":96,"raw":{"value":850}},{"id":198,"name":"Offline_Uncorrectable","value":96,"raw":{"value":850}}]}}]'
  out="$(emit)"
  check "faulted Exos: 850 pending" \
    1 '^homelab_smart_pending_sectors\{host="fixture",device="/dev/sdb"\} 850$'
  check "faulted Exos: 850 uncorrectable" \
    1 '^homelab_smart_uncorrectable_sectors\{host="fixture",device="/dev/sdb"\} 850$'
  check "faulted Exos: the drive still calls itself healthy" \
    1 '^homelab_smart_healthy\{.*device="/dev/sdb".*\} 1$'

  # 3. Two wear spellings on one drive. No drive here reports both today; the
  #    guard is what makes that safe to be wrong about.
  payload='[{"device":{"name":"/dev/sdd"},"model_name":"TWO SPELLINGS","smart_status":{"passed":true},"ata_smart_attributes":{"table":[{"id":231,"name":"SSD_Life_Left","value":97,"raw":{"value":97}},{"id":233,"name":"Media_Wearout_Indicator","value":90,"raw":{"value":0}}]}}]'
  out="$(emit)"
  check "two wear spellings render ONE series" \
    1 '^homelab_smart_percentage_used\{host="fixture",device="/dev/sdd"\}'

  # 4. morpheus's NVMe, the other vocabulary entirely.
  payload='[{"device":{"name":"/dev/nvme0"},"model_name":"NVME DRIVE","smart_status":{"passed":true},"temperature":{"current":62},"nvme_smart_health_information_log":{"percentage_used":3,"available_spare":100,"available_spare_threshold":10,"media_errors":0,"unsafe_shutdowns":41,"critical_warning":0}}]'
  out="$(emit)"
  check "NVMe: media errors, which ATA never reports" \
    1 '^homelab_smart_media_errors_total\{host="fixture",device="/dev/nvme0"\} 0$'
  check "NVMe: percentage_used is used DIRECTLY, not inverted" \
    1 '^homelab_smart_percentage_used\{host="fixture",device="/dev/nvme0"\} 3$'
  check "NVMe: the spare threshold the drive sets for itself" \
    1 '^homelab_smart_available_spare_threshold_percent\{.*\} 10$'

  # 5. Two drives at once, because the marker counts devices and a rendering
  #    that dropped one would still look like a healthy host.
  payload='[{"device":{"name":"/dev/sda"},"model_name":"ST18000NM003D-3DL103","smart_status":{"passed":true},"ata_smart_attributes":{"table":[{"id":5,"name":"Reallocated_Sector_Ct","value":100,"raw":{"value":0}}]}},{"device":{"name":"/dev/sdc"},"model_name":"INTEL SSDSC2BB240G7","smart_status":{"passed":true},"ata_smart_attributes":{"table":[{"id":5,"name":"Reallocated_Sector_Ct","value":99,"raw":{"value":4}}]}}]'
  out="$(emit)"
  check "two drives: both counted" 1 '^homelab_smart_devices\{host="fixture"\} 2$'
  check "two drives: both reallocated series, distinct" \
    2 '^homelab_smart_reallocated_sectors\{host="fixture",device="/dev/sd(a|c)"\} [04]$'

  # 6a. Saruman through its P440ar (#529). Four readings through one logical
  #     drive: the two SM863a SSDs, a SAS spindle the iLO already watches, and
  #     an empty index. The SSDs must come out as two series, not one, and
  #     nothing else may be counted. The wear figures are the first `--print`
  #     on Saruman, 2026-09-23: 6 % and 4 % used, so normalised 94 and 96. The
  #     raw erase counts were not read and are illustrative.
  payload='[{"homelab_label":"/dev/sda:cciss,2","device":{"name":"/dev/sda"},"model_name":"SAMSUNG MZ7KM960HMJP-00005","rotation_rate":0,"smart_status":{"passed":true},"ata_smart_attributes":{"table":[{"id":5,"name":"Reallocated_Sector_Ct","value":100,"raw":{"value":0}},{"id":177,"name":"Wear_Leveling_Count","value":94,"raw":{"value":112}}]}},{"homelab_label":"/dev/sda:cciss,3","device":{"name":"/dev/sda"},"model_name":"SAMSUNG MZ7KM960HMJP-00005","rotation_rate":0,"smart_status":{"passed":true},"ata_smart_attributes":{"table":[{"id":177,"name":"Wear_Leveling_Count","value":96,"raw":{"value":790}}]}},{"homelab_label":"/dev/sda:cciss,0","device":{"name":"/dev/sda"},"model_name":"EG0600FBVFP","rotation_rate":10000,"smart_status":{"passed":true}},{"homelab_label":"/dev/sda:cciss,7","device":{"name":"/dev/sda"},"smartctl":{"messages":[{"string":"No such device"}]}}]'
  out="$(emit)"
  check "Smart Array: each SSD is its own series" \
    2 '^homelab_smart_healthy\{host="fixture",device="/dev/sda:cciss,[23]",'
  check "Smart Array: Wear_Leveling_Count reads the normalised column" \
    1 '^homelab_smart_percentage_used\{host="fixture",device="/dev/sda:cciss,2"\} 6$'
  check "Smart Array: the second SSD's wear is its own" \
    1 '^homelab_smart_percentage_used\{host="fixture",device="/dev/sda:cciss,3"\} 4$'
  check "Smart Array: the spindle and the empty index are not counted" \
    1 '^homelab_smart_devices\{host="fixture"\} 2$'
  check "Smart Array: nothing for the spindle, which the iLO watches" \
    0 'cciss,0'

  # 6b. Discovery, against a made-up /sys. sda and sdb are logical drives on
  #     an hpsa host, sdc is an ordinary disk on AHCI. The controller is probed
  #     once, through its first logical drive, and sdc is read as itself.
  fake_sys="$(mktemp -d)"
  mkdir -p "${fake_sys}/devices/h0/0:1:0:0" "${fake_sys}/devices/h0/0:1:0:1" \
    "${fake_sys}/devices/h1/1:0:0:0" "${fake_sys}/class/scsi_host/host0" \
    "${fake_sys}/class/scsi_host/host1" "${fake_sys}/block/sda" \
    "${fake_sys}/block/sdb" "${fake_sys}/block/sdc" "${fake_sys}/block/loop0"
  ln -s "${fake_sys}/devices/h0/0:1:0:0" "${fake_sys}/block/sda/device"
  ln -s "${fake_sys}/devices/h0/0:1:0:1" "${fake_sys}/block/sdb/device"
  ln -s "${fake_sys}/devices/h1/1:0:0:0" "${fake_sys}/block/sdc/device"
  echo hpsa > "${fake_sys}/class/scsi_host/host0/proc_name"
  echo ahci > "${fake_sys}/class/scsi_host/host1/proc_name"
  out="$(SYSFS="${fake_sys}" CCISS_INDEXES=2 discover_local)"
  rm -rf "${fake_sys}"
  check "discovery: the Smart Array is probed by index" 2 '^cciss,[01]:/dev/sda$'
  check "discovery: its second logical drive is not probed again" 0 'sdb'
  check "discovery: an ordinary disk is read as itself" 1 '^auto:/dev/sdc$'
  check "discovery: a loop device is not a disk" 0 'loop0'

  # 6. smartctl answering with no device in the JSON. The exit has to carry
  #    smartctl's own reason, which is usually a permission problem rather than
  #    a disk problem — the run that made that necessary is in the header.
  payload='[{"smartctl":{"messages":[{"string":"Permission denied"}]}}]'
  if out="$(emit 2>&1)"; then
    printf '\033[0;31m  FAIL\033[0m no readable device -> exit 0, expected non-zero\n'
    fail=1
  else
    check "no readable device: smartctl's own reason survives" 1 'Permission denied'
  fi

  exit $fail
fi

if [[ -z "$SSH_TARGET" ]]; then
  command -v smartctl >/dev/null 2>&1 \
    || die "smartctl is not installed on this host.
  sudo apt install smartmontools
This collector reads it; it does not bundle it (#351)."

  mapfile -t DEVICES < <(discover_local)
  ((${#DEVICES[@]})) || die "no physical block devices found under /sys/block"
fi

payload="["
first=1
for spec in "${DEVICES[@]}"; do
  devtype="${spec%%:*}"
  node="${spec#*:}"
  [[ "$devtype" == "$spec" ]] && die "--device wants TYPE:/dev/NODE, got ${spec@Q}"
  out="$(run_smartctl "$devtype" "$node")"
  # smartctl exits non-zero for conditions that are not failures to read — bit 2
  # is "some SMART command failed", bit 6 is "errors in the log" — so the exit
  # code is deliberately not the gate. Valid JSON with a device in it is.
  #
  # But the REASON there is no output has to survive. The first scheduled run of
  # this job logged "no output for /dev/nvme0" and nothing else, because stderr
  # went to /dev/null — so a plain SSH permission failure looked like a disk
  # that would not answer, and the actual message ("Permission denied
  # (publickey)") existed nowhere. Anything a check hides is a check that sends
  # you to the wrong place.
  if [[ -z "$out" ]]; then
    detail="$(tr -d '\r' < "${STDERR_FILE}" | grep -v '^$' | tail -2 | paste -sd'; ' -)"
    printf 'warning: no output for %s%s\n' \
      "$node" "${detail:+ — ${detail}}" >&2
    continue
  fi
  # A drive behind a Smart Array is tagged with its own label, so the renderer
  # can tell it apart from the other drives reached through the same logical
  # drive, and knows to keep only the SSDs. smartctl's JSON always opens with
  # `{`, so the tag goes straight after it.
  if [[ "$devtype" == cciss,* ]]; then
    [[ "$out" == \{* ]] || continue
    out="{\"homelab_label\":\"${node}:${devtype}\",${out#\{}"
  fi
  ((first)) || payload+=","
  payload+="$out"
  first=0
done
payload+="]"

[[ "$payload" == "[]" ]] && die "no device produced readable SMART output"

# ---------------------------------------------------------------------------
# Render. Python because the JSON shape differs between NVMe and ATA and a
# shell parser for that is how a wrong number gets reported confidently.
# ---------------------------------------------------------------------------
if ((PRINT_ONLY)); then
  emit
  exit 0
fi

[[ -d "${TEXTFILE_DIR}" ]] \
  || die "no ${TEXTFILE_DIR} — run 'sudo ./scripts/install-timers.sh --install' first"

# Per-host file, so the SSH mode does not overwrite the local mode's output.
# And NOT named after any job in install-timers.sh's JOBS table: run-scheduled.sh
# writes "${JOB}.prom" and would clobber this, which is exactly what happened to
# the patch-state collector (#360).
PROM="${TEXTFILE_DIR}/smart-state-${HOST_LABEL}.prom"

tmp="${PROM}.$$"
emit > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
[[ -s "${tmp}" ]] || { rm -f "${tmp}"; die "rendered no metrics for ${HOST_LABEL}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"

printf 'smart-state host=%s devices=%s -> %s\n' \
  "${HOST_LABEL}" "$(grep -c '^homelab_smart_healthy{' "${PROM}")" "${PROM##*/}"
