#!/usr/bin/env bash
#
# Every leaf of every ZFS pool on this host, and its state, as metrics (#744).
#
# THE FAULT THE POOL STATE CANNOT SEE. On 2026-09-19 the Exos `ZVTBSDL3`
# FAULTED with 3 read and 99 write errors, and `zpool status` printed
#
#     state: ONLINE
#     erebor                                    ONLINE
#       mirror-0                                ONLINE
#         <partuuid>                            ONLINE
#         <partuuid>                            FAULTED   3  99  0  too many errors
#
# The kstat behind node_zfs_zpool_state is the POOL's state and read online
# too, so ZpoolNotOnline could not see a mirror running on one disk, and once
# the exporter came back nothing in the estate fired (#558). This writes the
# level below: one series per leaf, with the state `zpool status` gives it and
# its read, write and checksum error counters. ZpoolVdevNotOnline and
# ZpoolVdevErrors in host.rules.yaml read them.
#
# WHERE IT RUNS: where SMART does (ADR-0047). A root cron job in TrueNAS's own
# UI, this script on the pool beside collect-smart-state.sh, a .prom in the
# directory media-node-exporter bind-mounts at /textfile. Nothing new reaches
# smaug and nothing on CasaBonita initiates anything. build-the-nas.md §6.8 is
# the procedure. The difference is the cadence: every five minutes, not daily,
# because #558's fault would have gone a day unpaged at SMART's 08:30.
#
# THE SOURCE IS `zpool status -j`, NOT THE TEXT. OpenZFS 2.3 added JSON output
# and TrueNAS 25.10 ships 2.3. The text form is columns under an indented tree,
# where a leaf's depth is its whitespace and a reason like "too many errors"
# is free text after the counters; a parser for that is how a wrong state gets
# reported confidently. `--json-int` makes the counters and GUIDs integers:
# without it they are human-scaled strings, "1.2K", and this refuses those
# rather than guess at them. The nested form, not `--json-flat-vdevs`, because
# the tree is what says which vdevs are leaves.
#
# LEAVES ARE NAMED BY PARTUUID AND KEYED BY GUID, NEVER BY LETTER. On
# 2026-09-29 a textfile written under the old drive letters made
# SmartDriveBadSectors fire on a healthy disk (#745, ADR-0066). Every series
# here carries `guid`, ZFS's own identity for the vdev, which no reboot, cable
# or controller changes. `vdev` is the name a person acts on: the partuuid,
# which is what `zpool status` prints for erebor's leaves because TrueNAS
# builds pools on /dev/disk/by-partuuid. boot-pool is built on a kernel name,
# `sdc3`, so that path is resolved to its partuuid through
# /dev/disk/by-partuuid. Where nothing resolves — the device is gone, which is
# exactly when the series matters — `vdev` falls back to the name ZFS prints,
# and `guid` is still the key.
#
# WHAT IS A LEAF. A vdev with no children: a disk, a file, a draid spare.
# Mirrors, raidz and replacing/spare groups are interior and their state is
# derived from their leaves, so emitting them would page twice for one disk.
# Log, special, dedup and cache leaves are included. Hot spares are NOT: a
# spare's state is AVAIL or INUSE, which says nothing about redundancy, and a
# spare in use shows up again as a leaf inside the data tree, in its real
# state. smaug has no spares, no log and no cache today.
#
# OFFLINE IS EMITTED LIKE ANY OTHER STATE. The rule decides what pages; the
# collector reports what zpool says. replace-the-nas-disk.md step 4 offlines a
# leaf on purpose, the pool reads DEGRADED, and ZpoolNotOnline already pages;
# ZpoolVdevNotOnline stands down for any pool that is not ONLINE, so it fires
# only for what the pool-level rule cannot see. That is why the pool's state
# is emitted here too, from the same read.
#
# NO ROOT FOR THE READ, ROOT FOR THE WRITE. `zpool status` answers an
# unprivileged user on Linux. The cron job runs as root because
# /mnt/erebor/apps/textfile is root-owned 0755 — collect-truenas-version.sh's
# reason.
#
# Usage: scripts/collect-zpool-state.sh [--print] [--host NAME]
#        scripts/collect-zpool-state.sh --self-test
#
#   --host NAME   the `host` label; defaults to `hostname`. On smaug pass
#                 `--host smaug`, as the SMART job does, so the label matches
#                 the scrape's instance.
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
BY_PARTUUID_DIR="${BY_PARTUUID_DIR:-/dev/disk/by-partuuid}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The renderer. JSON in by PATH and not argv, for collect-smart-state.sh's
# reason: TrueNAS's console shell traces what it spawns and kills a child
# handed a large argument (#483, `sudo: process NNNN unexpected status 0x57f`).
render() {
  HOST_LABEL="$HOST_LABEL" BY_PARTUUID_DIR="$BY_PARTUUID_DIR" python3 - "$1" <<'PY'
import json, os, sys

host = os.environ["HOST_LABEL"]
by_partuuid = os.environ["BY_PARTUUID_DIR"]

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = json.load(fh)
except json.JSONDecodeError as exc:
    sys.exit(f"zpool status -j returned something that is not JSON: {exc}")
except OSError as exc:
    sys.exit(f"could not read the zpool status JSON: {exc}")

pools = doc.get("pools") or {}
if not pools:
    sys.exit("zpool status -j listed no pools")

# kernel name -> partuuid, from the symlinks udev keeps. Read once.
partuuid_of: dict[str, str] = {}
try:
    for entry in sorted(os.listdir(by_partuuid)):
        target = os.readlink(os.path.join(by_partuuid, entry))
        partuuid_of.setdefault(os.path.basename(target), entry)
except OSError:
    pass


def count(value, what: str) -> int:
    # --json-int gives ints. A digit string is the same number. Anything else
    # is a scaled "1.2K" from a run without --json-int, and a guessed counter
    # is worse than none.
    if isinstance(value, bool):
        sys.exit(f"{what}: unexpected {value!r}")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    sys.exit(f"{what}: {value!r} is not an integer — was --json-int dropped?")


def esc(value) -> str:
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def name_of(v: dict, fallback: str) -> str:
    path = v.get("path") or v.get("was") or ""
    if path.startswith("/dev/disk/by-partuuid/"):
        return os.path.basename(path)
    if path and os.path.basename(path) in partuuid_of:
        return partuuid_of[os.path.basename(path)]
    return v.get("name") or fallback


rows: dict[str, list[str]] = {}
HELP = {
    "homelab_zpool_state": "1 for the state zpool status gives the pool.",
    "homelab_zpool_vdev_state": "1 for the state zpool status gives this leaf vdev.",
    "homelab_zpool_vdev_errors": "Read, write or checksum errors on this leaf since import or the last zpool clear.",
    "homelab_zpool_vdev_leaves": "Leaf vdevs this collector read in the pool.",
}


def add(metric: str, labels: dict, value) -> None:
    rows.setdefault(metric, [f"# HELP {metric} {HELP[metric]}", f"# TYPE {metric} gauge"])
    lab = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items() if v != "")
    rows[metric].append(f"{metric}{{{lab}}} {value}")


INTERIOR_ONLY = {"root", "hole", "indirect", "missing"}


def leaves(vdevs: dict):
    for key, v in (vdevs or {}).items():
        children = v.get("vdevs")
        if children:
            yield from leaves(children)
        elif (v.get("vdev_type") or "") not in INTERIOR_ONLY:
            yield key, v


for pool_key, pool in sorted(pools.items()):
    pool_name = pool.get("name") or pool_key
    state = (pool.get("state") or "").lower()
    if not state:
        sys.exit(f"pool {pool_name}: no state in zpool status -j")
    add("homelab_zpool_state", {"host": host, "pool": pool_name, "state": state}, 1)

    # The data tree, then the allocation classes and the cache. Spares are
    # left out on purpose; see the header.
    found = []
    for section in ("vdevs", "dedup", "special", "logs", "l2cache"):
        found.extend(leaves(pool.get(section) or {}))

    seen: set[str] = set()
    for key, v in found:
        guid = v.get("guid")
        if guid is None:
            sys.exit(f"pool {pool_name}: leaf {key} has no guid")
        guid = str(count(guid, f"pool {pool_name} leaf {key} guid"))
        if guid in seen:
            continue
        seen.add(guid)
        leaf_state = (v.get("state") or "").lower()
        if not leaf_state:
            sys.exit(f"pool {pool_name}: leaf {key} has no state")
        base = {"host": host, "pool": pool_name, "vdev": name_of(v, key), "guid": guid}
        add("homelab_zpool_vdev_state",
            {**base, "state": leaf_state, "aux": v.get("aux") or ""}, 1)
        for kind in ("read", "write", "checksum"):
            add("homelab_zpool_vdev_errors", {**base, "kind": kind},
                count(v.get(f"{kind}_errors", 0), f"pool {pool_name} leaf {key} {kind}_errors"))

    if not seen:
        sys.exit(f"pool {pool_name}: zpool status -j listed no leaf vdevs")
    add("homelab_zpool_vdev_leaves", {"host": host, "pool": pool_name}, len(seen))

for metric in sorted(rows):
    print("\n".join(rows[metric]))
PY
}

# ---------------------------------------------------------------------------
# Self-test. Each fixture is the shape OpenZFS 2.3's zpool_main.c emits for
# `zpool status -j --json-int` (vdev_stats_nvlist and fill_vdev_info), with
# smaug's own names and GUIDs where they were read — from TrueNAS's pool.query
# on 2026-10-01, which reports the same tree.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  HOST_LABEL="fixture"
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' EXIT
  BY_PARTUUID_DIR="${work}/by-partuuid"
  mkdir -p "${BY_PARTUUID_DIR}"
  # boot-pool's partition, as udev links it.
  ln -s ../../sdc3 "${BY_PARTUUID_DIR}/1f0e7a52-3c11-4d6b-9a0e-6d2b8c4a7e10"

  out=""
  check() {
    local name="$1" expect="$2" pattern="$3" got
    got="$(printf '%s\n' "$out" | grep -cE -- "$pattern")"
    if [[ "$got" == "$expect" ]]; then
      printf '\033[0;32m  PASS\033[0m %s\n' "$name"
    else
      printf '\033[0;31m  FAIL\033[0m %s -> %s line(s) matching %s, expected %s\n' \
        "$name" "$got" "$pattern" "$expect"
      fail=1
    fi
  }
  run() { printf '%s' "$1" > "${work}/status.json"; out="$(render "${work}/status.json" 2>&1)"; }

  A=52dfceb0-0c58-476b-be76-ec30184c3781
  B=9362abc8-9bc8-4045-9095-f50f03f230c6
  leaf() { # name guid state read write cksum [extra json]
    printf '"%s":{"name":"%s","vdev_type":"disk","guid":%s,"path":"/dev/disk/by-partuuid/%s","class":"normal","state":"%s","read_errors":%s,"write_errors":%s,"checksum_errors":%s,"slow_ios":0%s}' \
      "$1" "$1" "$2" "$1" "$3" "$4" "$5" "$6" "${7:-}"
  }
  erebor() { # pool-state mirror-state leafA leafB
    printf '"erebor":{"name":"erebor","state":"%s","pool_guid":11722764120310643516,"vdevs":{"erebor":{"name":"erebor","vdev_type":"root","guid":11722764120310643516,"class":"normal","state":"%s","read_errors":0,"write_errors":0,"checksum_errors":0,"vdevs":{"mirror-0":{"name":"mirror-0","vdev_type":"mirror","guid":881002618685977402,"class":"normal","state":"%s","read_errors":0,"write_errors":0,"checksum_errors":0,"vdevs":{%s,%s}}}}},"error_count":0}' \
      "$1" "$1" "$2" "$3" "$4"
  }
  boot='"boot-pool":{"name":"boot-pool","state":"ONLINE","vdevs":{"boot-pool":{"name":"boot-pool","vdev_type":"root","guid":4242,"state":"ONLINE","read_errors":0,"write_errors":0,"checksum_errors":0,"vdevs":{"sdc3":{"name":"sdc3","vdev_type":"disk","guid":777,"path":"/dev/sdc3","class":"normal","state":"ONLINE","read_errors":0,"write_errors":0,"checksum_errors":0}}}}}'
  hdr='{"output_version":{"command":"zpool status","vers_major":0,"vers_minor":1},"pools":{'

  # 1. smaug today: both pools healthy. Two leaves under erebor's mirror,
  #    named by the partuuid zpool prints; boot-pool's one leaf, built on a
  #    kernel name, resolved to its partuuid.
  run "${hdr}$(erebor ONLINE ONLINE "$(leaf $A 5271037958598492964 ONLINE 0 0 0)" "$(leaf $B 1964916359723921467 ONLINE 0 0 0)"),${boot}}}"
  check "healthy: erebor's two leaves, and no interior vdev" \
    1 '^homelab_zpool_vdev_leaves\{host="fixture",pool="erebor"\} 2$'
  check "healthy: a leaf is keyed by guid and named by partuuid" \
    1 "^homelab_zpool_vdev_state\\{host=\"fixture\",pool=\"erebor\",vdev=\"${A}\",guid=\"5271037958598492964\",state=\"online\"\\} 1$"
  check "healthy: the mirror and the root are not leaves" 0 'vdev="(mirror-0|erebor)"'
  check "healthy: boot-pool's sdc3 is named by its partuuid, not its letter" \
    1 '^homelab_zpool_vdev_state\{host="fixture",pool="boot-pool",vdev="1f0e7a52-3c11-4d6b-9a0e-6d2b8c4a7e10",guid="777",state="online"\} 1$'
  check "healthy: three counters per leaf, all zero" \
    9 '^homelab_zpool_vdev_errors\{.*\} 0$'
  check "healthy: both pools online" 2 '^homelab_zpool_state\{host="fixture",pool="(erebor|boot-pool)",state="online"\} 1$'

  # 2. 2026-09-19 20:55 PDT: the pool and the mirror still ONLINE, one leaf
  #    FAULTED with 3 read and 99 write errors. The reading #744 exists for.
  run "${hdr}$(erebor ONLINE ONLINE "$(leaf $A 5271037958598492964 ONLINE 0 0 0)" "$(leaf $B 1964916359723921467 FAULTED 3 99 0 ',"aux":"too many errors"')")}}"
  check "2026-09-19: the pool still reads online" \
    1 '^homelab_zpool_state\{host="fixture",pool="erebor",state="online"\} 1$'
  check "2026-09-19: the faulted leaf, with zpool's reason" \
    1 "^homelab_zpool_vdev_state\\{host=\"fixture\",pool=\"erebor\",vdev=\"${B}\",guid=\"1964916359723921467\",state=\"faulted\",aux=\"too many errors\"\\} 1$"
  check "2026-09-19: its 99 write errors" \
    1 "^homelab_zpool_vdev_errors\\{host=\"fixture\",pool=\"erebor\",vdev=\"${B}\",guid=\"1964916359723921467\",kind=\"write\"\\} 99$"
  check "2026-09-19: its 3 read errors" 1 'kind="read"\} 3$'

  # 3. replace-the-nas-disk.md step 4: the leaf offlined on purpose. The pool
  #    reads DEGRADED, which is what lets the rule stand down for it.
  run "${hdr}$(erebor DEGRADED DEGRADED "$(leaf $A 5271037958598492964 ONLINE 0 0 0)" "$(leaf $B 1964916359723921467 OFFLINE 0 0 0)")}}"
  check "offlined: the leaf reads offline" 1 'state="offline"\} 1$'
  check "offlined: the pool reads degraded" \
    1 '^homelab_zpool_state\{host="fixture",pool="erebor",state="degraded"\} 1$'

  # 4. A pulled cable: the device is not present, so ZFS gives `was` and no
  #    `path`, and no partuuid link resolves. The name ZFS prints survives
  #    as the label, the guid as the key.
  gone='"'"$B"'":{"name":"'"$B"'","vdev_type":"disk","guid":1964916359723921467,"not_present":1,"was":"/dev/disk/by-partuuid/'"$B"'","class":"normal","state":"UNAVAIL","read_errors":0,"write_errors":0,"checksum_errors":0}'
  run "${hdr}$(erebor ONLINE ONLINE "$(leaf $A 5271037958598492964 ONLINE 0 0 0)" "$gone")}}"
  check "pulled cable: unavail, named from \`was\`" \
    1 "^homelab_zpool_vdev_state\\{host=\"fixture\",pool=\"erebor\",vdev=\"${B}\",guid=\"1964916359723921467\",state=\"unavail\"\\} 1$"

  # 5. A log and a cache device are leaves; a hot spare is not.
  extra=',"logs":{"slog":{"name":"slog","vdev_type":"disk","guid":31,"path":"/dev/disk/by-partuuid/slog","class":"logs","state":"ONLINE","read_errors":0,"write_errors":0,"checksum_errors":0}},"l2cache":{"l2":{"name":"l2","vdev_type":"disk","guid":32,"path":"/dev/disk/by-partuuid/l2","class":"l2cache","state":"ONLINE","read_errors":0,"write_errors":0,"checksum_errors":0}},"spares":{"sp":{"name":"sp","vdev_type":"disk","guid":33,"path":"/dev/disk/by-partuuid/sp","class":"spare","state":"AVAIL"}}'
  e="$(erebor ONLINE ONLINE "$(leaf $A 5271037958598492964 ONLINE 0 0 0)" "$(leaf $B 1964916359723921467 ONLINE 0 0 0)")"
  run "${hdr}${e%\}}${extra}}}}"
  check "classes: log and cache counted, the spare not" \
    1 '^homelab_zpool_vdev_leaves\{host="fixture",pool="erebor"\} 4$'
  check "classes: no series for the spare" 0 'vdev="sp"'

  # 6. Counters as digit strings (a run without --json-int that happened to
  #    be small) are the same numbers; a scaled "1.2K" is refused.
  run "${hdr}$(erebor ONLINE ONLINE "$(leaf $A '"5271037958598492964"' ONLINE '"0"' '"0"' '"2"')" "$(leaf $B 1964916359723921467 ONLINE 0 0 0)")}}"
  check "strings: a digit string counts" 1 'kind="checksum"\} 2$'
  if run "${hdr}$(erebor ONLINE ONLINE "$(leaf $A 5271037958598492964 ONLINE '"1.2K"' 0 0)" "$(leaf $B 1964916359723921467 ONLINE 0 0 0)")}}"; then
    printf '\033[0;31m  FAIL\033[0m a scaled counter rendered, expected a refusal\n'; fail=1
  else
    check "strings: a scaled counter is refused, naming the flag" 1 'json-int'
  fi

  # 7. No pools at all is a failure, not an empty healthy file.
  if run "${hdr}}}"; then
    printf '\033[0;31m  FAIL\033[0m no pools rendered, expected a refusal\n'; fail=1
  else
    check "no pools: refused" 1 'listed no pools'
  fi

  exit $fail
fi

PRINT_ONLY=0
HOST_LABEL=""
while (($#)); do
  case "$1" in
    --print) PRINT_ONLY=1; shift ;;
    --host)  HOST_LABEL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^set -/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;/^set -/d'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
: "${HOST_LABEL:=$(hostname)}"
[[ ${HOST_LABEL} =~ ^[A-Za-z0-9._-]+$ ]] || die "--host must be a plain name, got '${HOST_LABEL}'"

command -v zpool >/dev/null 2>&1 \
  || die "no zpool on PATH. Under cron, set PATH=/usr/sbin:/usr/bin:/sbin:/bin."

json="$(mktemp)"
errf="$(mktemp)"
trap 'rm -f "${json}" "${errf}"' EXIT

# A failed read writes nothing, so the last file goes stale and
# ZpoolVdevStateStale says so — rather than a file that looks healthy.
zpool status -j --json-int > "${json}" 2> "${errf}" \
  || die "zpool status -j --json-int failed: $(tr -d '\r' < "${errf}" | grep -v '^$' | tail -2 | paste -sd'; ' -)
OpenZFS before 2.3 has no JSON output; this needs TrueNAS 25.04 or later."

if ((PRINT_ONLY)); then render "${json}"; exit $?; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
PROM="${TEXTFILE_DIR}/zpool-state-${HOST_LABEL}.prom"
tmp="${PROM}.$$"
render "${json}" > "${tmp}" || { rm -f "${tmp}"; die "could not render ${tmp}"; }
[[ -s "${tmp}" ]] || { rm -f "${tmp}"; die "rendered no metrics for ${HOST_LABEL}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"

# Quiet on success apart from one line, which the cron job hides.
printf 'zpool-state host=%s leaves=%s not-online=%s -> %s\n' "${HOST_LABEL}" \
  "$(grep -c '^homelab_zpool_vdev_state{' "${PROM}")" \
  "$(grep '^homelab_zpool_vdev_state{' "${PROM}" | grep -vc 'state="online"')" "${PROM##*/}"
