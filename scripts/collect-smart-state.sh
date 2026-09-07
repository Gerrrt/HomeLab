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
# TWO COLLECTION MODES, because the estate has two shapes of host.
#
#   local     Linux hosts running Alloy with a textfile directory: `prometheus`
#             and `oracle`. Disks are enumerated from /sys, and smartctl is run
#             against each. NEEDS ROOT — see below.
#
#   --ssh     `morpheus`, which is FreeBSD, has no node_exporter, no textfile
#             directory and no Alloy, and whose metrics otherwise arrive over
#             SNMP. #351 assumed it would need "a fourth path" and it does not:
#             smartctl 7.5 is ALREADY INSTALLED there (pfSense ships it for its
#             own SMART status page) and root SSH from the monitoring host
#             already works, which is how backup-firewall.sh reaches it. So the
#             monitoring host reads it over SSH and writes the result into its
#             own textfile directory under host="morpheus".
#
#             The cost, stated: those series carry instance="prometheus", because
#             that is the Alloy that scraped them. Every alert here keys on
#             `host`, which is correct, but a query grouping by `instance` will
#             attribute morpheus's disk to the monitoring host. That is the price
#             of the host having no agent, and it is cheaper than putting one on
#             the firewall.
#
# WHY ROOT, AND ONLY FOR THE LOCAL MODE. smartctl issues ATA/NVMe pass-through
# ioctls and needs raw device access; no amount of group membership substitutes.
# Every timer in install-timers.sh's JOBS table runs as User=robo, so this is the
# first unit here that does not — which is why #351 called it a provisioning
# change rather than a config change. The unit runs as root and gives back
# everything it can (ProtectSystem=strict, a single ReadWritePath, no network),
# rather than a sudoers rule: a NOPASSWD entry for smartctl is a NOPASSWD entry
# for `smartctl --set` and `-t select` too, which can write to the drive.
#
# NO SERIAL NUMBERS. smartctl reports one per disk and it is deliberately not
# emitted. It identifies hardware, it is unique per drive, and `device` plus
# `model` is enough to act on. docs/security.md's rule about what is published
# is the same instinct.
#
# Usage: scripts/collect-smart-state.sh [--print]
#        scripts/collect-smart-state.sh --ssh USER@HOST --host NAME
#                                       --device TYPE:/dev/NODE [...]
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/smart-state.prom"

PRINT_ONLY=0
SSH_TARGET=""
HOST_LABEL=""
DEVICES=()

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --print)  PRINT_ONLY=1; shift ;;
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
      "smartctl --json -x -d ${devtype} ${node}" 2>/dev/null
  else
    smartctl --json -x -d "${devtype}" "${node}" 2>/dev/null
  fi
}

if [[ -z "$SSH_TARGET" ]]; then
  command -v smartctl >/dev/null 2>&1 \
    || die "smartctl is not installed on this host.
  sudo apt install smartmontools
This collector reads it; it does not bundle it (#351)."

  # Real block devices only: no loop, no ram, no device-mapper, no optical.
  # /sys rather than lsblk output parsing, because a model name with a space in
  # it turns a column split into a wrong answer.
  for dev in /sys/block/*; do
    name="$(basename "$dev")"
    case "$name" in loop*|ram*|dm-*|sr*|fd*|zram*) continue ;; esac
    [[ -e "${dev}/device" ]] || continue
    DEVICES+=("auto:/dev/${name}")
  done
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
  [[ -n "$out" ]] || { printf 'warning: no output for %s\n' "$node" >&2; continue; }
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
emit() {
  HOST_LABEL="$HOST_LABEL" python3 - "$payload" <<'PY'
import json, os, sys

host = os.environ["HOST_LABEL"]
try:
    docs = json.loads(sys.argv[1])
except json.JSONDecodeError as exc:
    sys.exit(f"smartctl returned something that is not JSON: {exc}")

rows: dict[str, list[str]] = {}

def add(metric: str, help_: str, labels: dict, value) -> None:
    if value is None:
        return
    lab = ",".join(f'{k}="{v}"' for k, v in labels.items())
    rows.setdefault(metric, [f"# HELP {metric} {help_}", f"# TYPE {metric} gauge"])
    rows[metric].append(f"{metric}{{{lab}}} {value}")

seen = 0
for d in docs:
    node = (d.get("device") or {}).get("name")
    if not node:
        continue
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

if not seen:
    sys.exit("smartctl returned JSON with no devices in it")

# A marker, so a host that stops collecting is distinguishable from a host with
# healthy disks. Same reasoning as PatchStateStopped: every other metric here is
# a number that looks fine when it is absent.
add("homelab_smart_devices", "Devices this collector read on this host.",
    {"host": host}, seen)

for metric in sorted(rows):
    print("\n".join(rows[metric]))
PY
}

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
