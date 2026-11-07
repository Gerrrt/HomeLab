#!/usr/bin/env bash
#
# Whether a few named lab services are healthy, read through the hypervisor
# (#858, ADR-0088).
#
# THE GAP. The lab's Prometheus on `alexander` sends no alerts (ADR-0020), and
# ADR-0028 let a guest's run state cross to the estate but not the health of
# what runs inside it. So a guest powered on with a crashed service looked
# exactly like a healthy one: a dead lab Prometheus, a Zeek whose event loop has
# stopped while the mirror still delivers, a Wazuh manager whose listener is
# down. The SOC could be blind while looking monitored.
#
# WHAT THIS READS, AND FROM WHERE. One fixed command per service, run on the
# hypervisor with `qm guest exec`, which asks the guest's qemu-guest-agent over
# the virtio serial channel the hypervisor already owns. No network path is
# involved, and the answer leaves through the hypervisor's existing pass to
# VLAN 99 (#88), as collect-guest-disk-state.sh's does. The command asks Docker
# for the container's state and its own healthcheck's verdict, so the real test
# is the one compose.yaml already wrote: stats.log freshness for Zeek,
# `wazuh-remoted is running` for the manager, /-/healthy for Prometheus.
#
# ONE BIT CROSSES PER SERVICE. A service is healthy when Docker answers exactly
# `running healthy`, and not healthy for anything else: exited, unhealthy,
# starting, no healthcheck, no such container, docker not answering. ADR-0088
# records why that one bit may cross when ADR-0028 kept "what services it runs,
# and their health" in the lab: the list is fixed here, in the repository, and
# nothing about what the service is doing comes with it.
#
# THE ANSWER IS HOSTILE INPUT. VLAN 30 holds attackers, and a compromised guest
# controls what its agent says. So qm's JSON is parsed in python and never by a
# shell, its size is capped before it is read, and the only thing taken from the
# guest's output is whether it equals one fixed string. What a lying guest CAN
# do is lie about its own services, and ADR-0088 accepts that.
#
# THE COMMAND IS FIXED. `qm guest exec` runs as root inside the guest. Root on
# the hypervisor could always do that; this is the first scheduled use of it,
# so the argv is built only from the SERVICES table below and nothing a guest
# said is ever part of it.
#
# ONE HUNG AGENT MUST NOT LOSE THE OTHERS. Each exec runs under `timeout`. A
# service whose agent does not answer gets homelab_guest_service_checked 0 and
# no healthy series, and the run carries on to the next.
#
# ROOT IS NEEDED: `qm guest exec` talks to the guest's agent socket.
#
# Usage: scripts/collect-guest-service-state.sh [--print]
#        scripts/collect-guest-service-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/guest-service-state.prom"
HOSTNAME_LABEL="$(hostname)"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-20}"
# A real answer is under 100 bytes of JSON. Anything near this is not Docker
# saying two words, and is treated as an agent that did not answer.
MAX_BYTES="${MAX_BYTES:-65536}"

# guest container — the services whose health crosses (ADR-0088). A guest is
# matched by its name in `qm list`. Adding a row here widens what crosses, so it
# is a change to ADR-0088's table as well.
SERVICES=(
  "alexander lab-prometheus"
  "fenrir sensor-zeek"
  "odin soc-wazuh-manager"
  "odin soc-velociraptor"
)

# What Docker is asked. `{{if .State.Health}}` keeps a container with no
# healthcheck from erroring: it answers `running ` and is not healthy, because a
# service in this table without a healthcheck is a mistake to report.
INSPECT_FORMAT='{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}'

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

# The SERVICES rows whose guest is running, as `vmid guest container`, from the
# running VMs on stdin.
services_to_ask() {
  local vmid name row guest container
  while read -r vmid name; do
    for row in "${SERVICES[@]}"; do
      read -r guest container <<<"$row"
      [[ "$name" == "$guest" ]] && printf '%s %s %s\n' "$vmid" "$guest" "$container"
    done
  done
}

# render MANIFEST — the exposition, from a manifest of one tab-separated line per
# service asked: vmid, guest, container, the exit status of `qm guest exec`, and
# the path its stdout was saved to.
render() {
  HOST_LABEL="$HOSTNAME_LABEL" MAX_BYTES="$MAX_BYTES" python3 - "$1" <<'PY'
import json, os, re, sys

host = os.environ["HOST_LABEL"]
MAX_BYTES = int(os.environ["MAX_BYTES"])
LABEL_OK = re.compile(r"[^A-Za-z0-9._:@+-]")


def clean(value, limit: int) -> str:
    return LABEL_OK.sub("_", str(value))[:limit]


checked, healthy = [], []
guests = set()
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 5:
            continue
        vmid, guest, container, rc, path = parts
        if not vmid.isdigit():
            continue
        guests.add(vmid)
        labels = (f'host="{host}",guest="{clean(guest, 64)}",vmid="{vmid}",'
                  f'service="{clean(container, 64)}"')
        doc = None
        # Nothing one guest sends may raise out of here: too big is refused
        # before it is read, and RecursionError is what json raises for a valid
        # answer nested thousands deep.
        if rc == "0":
            try:
                if os.path.getsize(path) <= MAX_BYTES:
                    with open(path, encoding="utf-8", errors="replace") as out:
                        doc = json.load(out)
            except (OSError, ValueError, RecursionError):
                doc = None
        # qm reports a command that outran --timeout as exited 0 with no
        # exitcode. Only a finished command with an integer exit is an answer.
        exitcode = doc.get("exitcode") if isinstance(doc, dict) else None
        answered = (isinstance(doc, dict) and doc.get("exited") in (1, True)
                    and isinstance(exitcode, int) and not isinstance(exitcode, bool))
        if not answered:
            checked.append(f"homelab_guest_service_checked{{{labels}}} 0")
            continue
        checked.append(f"homelab_guest_service_checked{{{labels}}} 1")
        said = doc.get("out-data")
        ok = exitcode == 0 and isinstance(said, str) and said.strip() == "running healthy"
        healthy.append(f"homelab_guest_service_healthy{{{labels}}} {1 if ok else 0}")


def family(metric, help_, samples):
    print(f"# HELP {metric} {help_}")
    print(f"# TYPE {metric} gauge")
    for s in samples:
        print(s)


family("homelab_guest_service_healthy",
       "1 when Docker in the guest said the container is running and its healthcheck passes.", healthy)
family("homelab_guest_service_checked",
       "1 when the guest agent ran the health check to completion this run.", checked)
family("homelab_guest_service_guests_queried",
       "Running VMs this hypervisor asked about a named service.",
       [f'homelab_guest_service_guests_queried{{host="{host}"}} {len(guests)}'])
PY
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  HOSTNAME_LABEL=Saruman
  pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$1"; }
  flunk() { printf '\033[0;31m  FAIL\033[0m %s\n%s\n' "$1" "$2"; fail=1; }

  # A service: write qm's answer and its manifest line. vmid, guest, container,
  # exit of `qm guest exec`, JSON.
  n=0
  svc() {
    n=$((n + 1))
    printf '%s' "$5" > "${WORK_DIR}/out.$n"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${WORK_DIR}/out.$n" >> "${WORK_DIR}/manifest"
  }
  has() {
    if grep -qxF -- "$2" <<<"$out"; then pass "$1"; else flunk "$1" "       missing  $2"; fi
  }
  lacks() {
    if grep -qF -- "$2" <<<"$out"; then flunk "$1" "       present  $2"; else pass "$1"; fi
  }
  label() { printf 'host="Saruman",guest="%s",vmid="%s",service="%s"' "$1" "$2" "$3"; }

  # The shape `qm guest exec` printed for docker inspect on a healthy container.
  svc 140 alexander lab-prometheus 0 '{"exitcode":0,"exited":1,"out-data":"running healthy\n"}'
  # Stopped: what `docker stop sensor-zeek` leaves.
  svc 190 fenrir sensor-zeek 0 '{"exitcode":0,"exited":1,"out-data":"exited unhealthy\n"}'
  # Running, and its healthcheck failing: remoted down inside a live container.
  svc 160 odin soc-wazuh-manager 0 '{"exitcode":0,"exited":1,"out-data":"running unhealthy\n"}'
  # No such container: docker inspect exits 1, with the message on stderr.
  svc 160 odin soc-velociraptor 0 '{"exitcode":1,"exited":1,"err-data":"Error: No such object: soc-velociraptor\n"}'
  out="$(render "${WORK_DIR}/manifest")"

  has "running and healthy is 1" "homelab_guest_service_healthy{$(label alexander 140 lab-prometheus)} 1"
  has "and it was checked" "homelab_guest_service_checked{$(label alexander 140 lab-prometheus)} 1"
  has "an exited container is 0" "homelab_guest_service_healthy{$(label fenrir 190 sensor-zeek)} 0"
  has "a running, unhealthy container is 0" "homelab_guest_service_healthy{$(label odin 160 soc-wazuh-manager)} 0"
  has "a missing container is 0" "homelab_guest_service_healthy{$(label odin 160 soc-velociraptor)} 0"
  has "and a missing container was still checked" "homelab_guest_service_checked{$(label odin 160 soc-velociraptor)} 1"
  has "two services on one guest count it once" 'homelab_guest_service_guests_queried{host="Saruman"} 3'

  : > "${WORK_DIR}/manifest"
  # Starting: inside its start_period, not yet healthy.
  svc 140 alexander lab-prometheus 0 '{"exitcode":0,"exited":1,"out-data":"running starting\n"}'
  # No healthcheck at all: `running ` and nothing after it.
  svc 141 nohc svc-a 0 '{"exitcode":0,"exited":1,"out-data":"running \n"}'
  # A guest that adds to the right answer is not giving it.
  svc 142 chatty svc-b 0 '{"exitcode":0,"exited":1,"out-data":"running healthy\nrunning healthy\n"}'
  # The right words with a non-zero exit are not trusted.
  svc 143 liar svc-c 0 '{"exitcode":3,"exited":1,"out-data":"running healthy\n"}'
  # An agent that is not running: qm guest exec fails.
  svc 144 noagent svc-d 255 ''
  # An exec that outran --timeout: exited 0, a pid, no exitcode.
  svc 145 slow svc-e 0 '{"exited":0,"pid":4242}'
  # An answer that is not JSON.
  svc 146 garbage svc-f 0 'QEMU guest agent is not running'
  # Exit codes that are not integers.
  svc 147 strexit svc-g 0 '{"exitcode":"0","exited":1,"out-data":"running healthy\n"}'
  svc 148 boolexit svc-h 0 '{"exitcode":false,"exited":1,"out-data":"running healthy\n"}'
  # out-data that is not a string.
  svc 149 listout svc-i 0 '{"exitcode":0,"exited":1,"out-data":["running healthy"]}'
  # Valid JSON nested past python's recursion limit.
  svc 150 deep svc-j 0 "$(printf '%0.s[' $(seq 1 100000))$(printf '%0.s]' $(seq 1 100000))"
  # A name built to escape its label. Real names come from the table, so this
  # guards render() rather than describing a guest that could be asked.
  svc 151 'evil"} 1 x{a="' svc-k 0 '{"exitcode":0,"exited":1,"out-data":"running healthy\n"}'
  out="$(render "${WORK_DIR}/manifest")"

  has "starting is not healthy" "homelab_guest_service_healthy{$(label alexander 140 lab-prometheus)} 0"
  has "no healthcheck is not healthy" "homelab_guest_service_healthy{$(label nohc 141 svc-a)} 0"
  has "more than the answer is not the answer" "homelab_guest_service_healthy{$(label chatty 142 svc-b)} 0"
  has "the right words with a failing exit are 0" "homelab_guest_service_healthy{$(label liar 143 svc-c)} 0"
  has "a failed qm guest exec is unchecked" "homelab_guest_service_checked{$(label noagent 144 svc-d)} 0"
  lacks "and has no healthy series at all" "homelab_guest_service_healthy{$(label noagent 144 svc-d)}"
  has "an exec that outran its timeout is unchecked" "homelab_guest_service_checked{$(label slow 145 svc-e)} 0"
  lacks "and has no healthy series" "homelab_guest_service_healthy{$(label slow 145 svc-e)}"
  has "an answer that is not JSON is unchecked" "homelab_guest_service_checked{$(label garbage 146 svc-f)} 0"
  has "a string exit code is unchecked" "homelab_guest_service_checked{$(label strexit 147 svc-g)} 0"
  has "a boolean exit code is unchecked" "homelab_guest_service_checked{$(label boolexit 148 svc-h)} 0"
  has "out-data that is not a string is 0" "homelab_guest_service_healthy{$(label listout 149 svc-i)} 0"
  has "an answer nested past the recursion limit is unchecked" "homelab_guest_service_checked{$(label deep 150 svc-j)} 0"
  has "a hostile guest name is cleaned into one label" "homelab_guest_service_healthy{$(label 'evil___1_x_a__' 151 svc-k)} 1"
  lacks "and does not escape it" 'x{a='

  # An answer over the cap is refused whole, though it is the right answer.
  : > "${WORK_DIR}/manifest"
  svc 140 alexander lab-prometheus 0 '{"exitcode":0,"exited":1,"out-data":"running healthy\n"}'
  out="$(MAX_BYTES=20 render "${WORK_DIR}/manifest")"
  has "an answer over the byte cap is unchecked" "homelab_guest_service_checked{$(label alexander 140 lab-prometheus)} 0"
  lacks "and is not called healthy" "homelab_guest_service_healthy{$(label alexander 140 lab-prometheus)}"

  : > "${WORK_DIR}/manifest"
  out="$(render "${WORK_DIR}/manifest")"
  has "no running guests is zero, not silence" 'homelab_guest_service_guests_queried{host="Saruman"} 0'

  got="$(printf '%s\n' "  VMID NAME        STATUS     MEM(MB)    BOOTDISK(GB) PID
       140 alexander   running    16384             64.00 1234
       150 bahamut     running    4096              64.00 2345
       160 odin        running    16384             48.00 5678
       190 fenrir      stopped    8192              32.00 0" | parse_running_vms | services_to_ask | tr '\n' ';')"
  want="140 alexander lab-prometheus;160 odin soc-wazuh-manager;160 odin soc-velociraptor;"
  if [[ "$got" == "$want" ]]; then pass "only running guests in the table are asked, every service they hold"
  else flunk "only running guests in the table are asked, every service they hold" "       got $got"; fi
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
Guest services cannot be read, and nothing is written, so GuestServiceStateStale says so."
fi
printf '%s\n' "$qm_raw" | grep -qE '^\s*VMID' \
  || die "qm list produced no VMID header, so its output was not understood."

: > "${WORK_DIR}/manifest"
n=0
while read -r vmid guest container; do
  [[ -n "$vmid" ]] || continue
  n=$((n + 1))
  # --timeout bounds the command inside the guest; `timeout` bounds qm itself,
  # whose agent may never answer at all. Capped as it is written, one byte past
  # the cap kept so render() can tell a truncated answer and refuse it.
  timeout -k 5 "$((AGENT_TIMEOUT + 5))" \
    qm guest exec "$vmid" --timeout "${AGENT_TIMEOUT}" -- \
      docker inspect --format "${INSPECT_FORMAT}" "${container}" 2>/dev/null \
    | head -c "$((MAX_BYTES + 1))" > "${WORK_DIR}/out.$n"
  rc=${PIPESTATUS[0]}
  printf '%s\t%s\t%s\t%s\t%s\n' "$vmid" "$guest" "$container" "$rc" "${WORK_DIR}/out.$n" >> "${WORK_DIR}/manifest"
done < <(printf '%s\n' "$qm_raw" | parse_running_vms | services_to_ask)

out="$(render "${WORK_DIR}/manifest")" || die "could not render the guests' answers."

if ((PRINT_ONLY)); then printf '%s\n' "$out"; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
printf '%s\n' "$out" > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'guest-service-state host=%s services=%s healthy=%s unchecked=%s\n' "$HOSTNAME_LABEL" "$n" \
  "$(grep -c '^homelab_guest_service_healthy{.*} 1$' <<<"$out" || true)" \
  "$(grep -c '^homelab_guest_service_checked{.*} 0$' <<<"$out" || true)"
