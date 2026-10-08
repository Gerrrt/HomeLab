#!/usr/bin/env bash
#
# The Wazuh manager's own working numbers, for the lab's Prometheus (#1038).
#
# THE GAP. The lab Prometheus had the indexer's metrics (opensearch.alloy) and
# nothing from the manager. A manager whose agents have quietly disconnected,
# or whose analysis queue is full and dropping events, looks healthy from the
# indexer: it is simply written to less. GuestServiceUnhealthy (#858) on the
# estate says whether wazuh-remoted is running at all. This says how well the
# manager is doing its job, in the lab, for whoever is already looking. It
# pages no one (ADR-0020).
#
# WHAT THIS READS, from inside soc-wazuh-manager by `docker exec`:
#   /var/ossec/var/run/wazuh-analysisd.state   queue usage per queue (a 0..1
#       fraction, elements / (size - 1), queue_op.c), events received and
#       dropped. Rewritten every 5 s (analysisd.state_interval).
#   /var/ossec/var/run/wazuh-remoted.state     its queue, TCP sessions,
#       discarded messages. Also every 5 s.
#   /var/ossec/bin/agent_control -l -j         every agent and its status:
#       Active, Disconnected, Never connected, Pending or Unknown
#       (read-agents.c). Agent 000, the manager itself, is not counted.
#       Written twice: a count per status (homelab_wazuh_agents), and one
#       series per agent, homelab_wazuh_agent_active{agent="<name>"} 1 or 0,
#       which WazuhAgentsNotConnected joins to each guest's windows_exporter
#       by name.
# Keys and formats read from the 4.14.8 source the stack pins.
#
# BOTH STATE FILES SAY "THIS FILE WILL BE DEPRECATED IN FUTURE VERSIONS". So
# each source reports whether it was read, as homelab_wazuh_manager_source_ok,
# and WazuhManagerStateUnreadable fires on a 0. An upgrade that removes a file
# is a loud alert, not a quiet absence of series.
#
# No credentials: the files and the command need only `docker exec`, which root
# on odin already has. No new container, image or API user.
#
# Usage: scripts/collect-wazuh-manager-state.sh [--print]
#        scripts/collect-wazuh-manager-state.sh --self-test
set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/wazuh-manager-state.prom"
CONTAINER="${CONTAINER:-soc-wazuh-manager}"
EXEC_TIMEOUT="${EXEC_TIMEOUT:-20}"
# The real answers are a few KB. Anything near this is not them.
MAX_BYTES="${MAX_BYTES:-1048576}"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# render DIR — the exposition, from DIR/{analysisd,remoted,agents}.{out,rc}.
render() {
  MAX_BYTES="$MAX_BYTES" python3 - "$1" <<'PY'
import json, os, re, sys

d = sys.argv[1]
MAX = int(os.environ["MAX_BYTES"])
LINE = re.compile(r"^([a-z_]+)='([^']*)'$")
STATUS = {"Active": "active", "Disconnected": "disconnected", "Never connected": "never_connected",
          "Pending": "pending", "Unknown": "unknown"}


def read(name):
    """The command's output, or None when it failed, was too big, or is absent."""
    try:
        with open(f"{d}/{name}.rc") as fh:
            if fh.read().strip() != "0":
                return None
        if os.path.getsize(f"{d}/{name}.out") > MAX:
            return None
        with open(f"{d}/{name}.out", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except (OSError, ValueError):
        return None


def state(text):
    out = {}
    for line in (text or "").splitlines():
        m = LINE.match(line.strip())
        if m:
            out[m[1]] = m[2]
    return out


def num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if f == f and abs(f) != float("inf") else None


def count(v):
    """A non-negative number, or None. 0 is a count, not a missing value."""
    f = num(v)
    return f if f is not None and f >= 0 else None


ok, lines = {}, []

a = state(read("analysisd"))
# Readable means the values this reads are numbers in range, not merely that
# the keys exist: a file of 'nan's is as unreadable as no file.
event_usage = num(a.get("event_queue_usage"))
ok["analysisd"] = int(
    event_usage is not None and 0 <= event_usage <= 1
    and all(count(a.get(k)) is not None for k in ("events_received", "events_dropped"))
)
if ok["analysisd"]:
    for key, value in sorted(a.items()):
        if key.endswith("_queue_usage"):
            v = num(value)
            if v is not None and 0 <= v <= 1:  # -1 is "no such queue"
                q = key[: -len("_queue_usage")]
                lines.append(f'homelab_wazuh_analysisd_queue_usage_ratio{{queue="{q}"}} {v}')
    for key, metric in (("events_received", "received"), ("events_dropped", "dropped")):
        v = num(a.get(key))
        if v is not None and v >= 0:
            lines.append(f"homelab_wazuh_analysisd_events_{metric}_total {int(v)}")

r = state(read("remoted"))
used, size = num(r.get("queue_size")), num(r.get("total_queue_size"))
ok["remoted"] = int(used is not None and used >= 0 and size is not None and size > 0)
if ok["remoted"]:
    lines.append(f"homelab_wazuh_remoted_queue_usage_ratio {used / size}")
    for key, metric in (("tcp_sessions", "homelab_wazuh_remoted_tcp_sessions"),
                        ("discarded_count", "homelab_wazuh_remoted_discarded_total")):
        v = num(r.get(key))
        if v is not None and v >= 0:
            lines.append(f"{metric} {int(v)}")

counts = dict.fromkeys(STATUS.values(), 0)
try:
    doc = json.loads(read("agents") or "")
    agents = doc["data"] if isinstance(doc, dict) and doc.get("error") == 0 else None
except (ValueError, RecursionError):
    agents = None
ok["agents"] = int(isinstance(agents, list))
if ok["agents"]:
    per_agent = {}
    for agent in agents:
        if not isinstance(agent, dict) or agent.get("id") == "000":
            continue
        # The manager's own row says "Active/Local"; an agent's never does.
        status = STATUS.get(str(agent.get("status", "")), "unknown")
        counts[status] += 1
        # One series per agent, so WazuhAgentsNotConnected can join each
        # running guest to its own agent by name rather than compare two
        # counts, where any other Active agent would fill a missing guest's
        # place. The name is the guest's hostname, which is what its
        # windows_exporter's `instance` label is too: lowercased, and kept to
        # characters a label value needs no escaping for. A name that comes
        # out empty is left out rather than guessed.
        name = re.sub(r"[^a-z0-9_.-]", "", str(agent.get("name", "")).lower())
        if name:
            per_agent[name] = max(per_agent.get(name, 0), int(status == "active"))
    for status, n in counts.items():
        lines.append(f'homelab_wazuh_agents{{status="{status}"}} {n}')
    for name, active in sorted(per_agent.items()):
        lines.append(f'homelab_wazuh_agent_active{{agent="{name}"}} {active}')

for source in ("analysisd", "remoted", "agents"):
    lines.append(f'homelab_wazuh_manager_source_ok{{source="{source}"}} {ok[source]}')

print("# Wazuh manager state, by scripts/collect-wazuh-manager-state.sh (#1038).")
for line in lines:
    print(line)
PY
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  pass() { printf '\033[0;32m  PASS\033[0m %s\n' "$1"; }
  flunk() { printf '\033[0;31m  FAIL\033[0m %s\n%s\n' "$1" "$2"; fail=1; }
  has() { if grep -qxF -- "$2" <<<"$out"; then pass "$1"; else flunk "$1" "       missing  $2"; fi; }
  lacks() { if grep -qF -- "$2" <<<"$out"; then flunk "$1" "       present  $2"; else pass "$1"; fi; }
  put() { printf '%s' "$3" > "${WORK_DIR}/$1.out"; printf '%s' "$2" > "${WORK_DIR}/$1.rc"; }

  # The shapes state.c at 4.14.8 writes, trimmed to the keys read here plus a
  # comment line and a key that is not.
  put analysisd 0 "# State file for wazuh-analysisd
# THIS FILE WILL BE DEPRECATED IN FUTURE VERSIONS

# Events received
events_received='48211'

# Events dropped
events_dropped='0'

# Event queue
event_queue_usage='0.12'
event_queue_size='16384'
alerts_queue_usage='0.97'
syscheck_queue_usage='-1.00'
firewall_written='3'
"
  put remoted 0 "# State file for wazuh-remoted
queue_size='2048'
total_queue_size='131072'
tcp_sessions='6'
discarded_count='12'
"
  put agents 0 '{"error":0,"data":[{"id":"000","name":"odin","ip":"127.0.0.1","status":"Active/Local"},{"id":"001","name":"bahamut","ip":"any","status":"Active"},{"id":"002","name":"leviathan","ip":"any","status":"Disconnected"},{"id":"003","name":"titan","ip":"any","status":"Never connected"},{"id":"004","name":"ramuh","ip":"any","status":"Active"},{"id":"005","name":"x","ip":"any","status":"something new"}]}'
  out="$(render "${WORK_DIR}")"

  has "the event queue, as a 0..1 ratio" 'homelab_wazuh_analysisd_queue_usage_ratio{queue="event"} 0.12'
  has "the alerts queue near full" 'homelab_wazuh_analysisd_queue_usage_ratio{queue="alerts"} 0.97'
  lacks "a -1, no such queue, is not a ratio" 'queue="syscheck"'
  has "events received is a counter" 'homelab_wazuh_analysisd_events_received_total 48211'
  has "events dropped is a counter" 'homelab_wazuh_analysisd_events_dropped_total 0'
  has "remoted's queue as used over total" 'homelab_wazuh_remoted_queue_usage_ratio 0.015625'
  has "remoted's TCP sessions" 'homelab_wazuh_remoted_tcp_sessions 6'
  has "remoted's discarded messages" 'homelab_wazuh_remoted_discarded_total 12'
  has "active agents, not counting the manager" 'homelab_wazuh_agents{status="active"} 2'
  has "disconnected agents" 'homelab_wazuh_agents{status="disconnected"} 1'
  has "never-connected agents" 'homelab_wazuh_agents{status="never_connected"} 1'
  has "a status this does not know is unknown" 'homelab_wazuh_agents{status="unknown"} 1'
  has "an empty status is reported as zero" 'homelab_wazuh_agents{status="pending"} 0'
  has "each agent by name: an active one is 1" 'homelab_wazuh_agent_active{agent="bahamut"} 1'
  has "a disconnected one is 0" 'homelab_wazuh_agent_active{agent="leviathan"} 0'
  has "a never-connected one is 0" 'homelab_wazuh_agent_active{agent="titan"} 0'
  lacks "the manager's own row has no per-agent series" 'agent="odin"'
  for s in analysisd remoted agents; do has "${s} read" "homelab_wazuh_manager_source_ok{source=\"${s}\"} 1"; done

  # A future version without the state files, and an agent_control that failed.
  put analysisd 1 ""
  put remoted 0 "cat: /var/ossec/var/run/wazuh-remoted.state: No such file or directory"
  put agents 0 '{"error":1,"message":"Unable to read agents"}'
  out="$(render "${WORK_DIR}")"
  has "a failed read is a 0, not silence" 'homelab_wazuh_manager_source_ok{source="analysisd"} 0'
  has "output that is not a state file is a 0" 'homelab_wazuh_manager_source_ok{source="remoted"} 0'
  has "agent_control reporting an error is a 0" 'homelab_wazuh_manager_source_ok{source="agents"} 0'
  lacks "and no numbers are made up" 'homelab_wazuh_agents{'
  lacks "and no agent is made up either" 'homelab_wazuh_agent_active{'
  lacks "or ratios" '_ratio'

  # Garbage and oversize.
  put agents 0 'not json'
  put analysisd 0 "event_queue_usage='nan'
events_received='10'
events_dropped='0'"
  put remoted 0 "queue_size='12'
total_queue_size='0'"
  out="$(render "${WORK_DIR}")"
  has "agent_control output that is not JSON is a 0" 'homelab_wazuh_manager_source_ok{source="agents"} 0'
  lacks "a NaN usage is not reported" 'queue="event"'
  has "and a NaN event queue makes analysisd unreadable" 'homelab_wazuh_manager_source_ok{source="analysisd"} 0'
  has "a zero total queue size makes remoted unreadable" 'homelab_wazuh_manager_source_ok{source="remoted"} 0'
  put analysisd 0 "event_queue_usage='0.10'
events_received='10'"
  out="$(render "${WORK_DIR}")"
  has "a missing events_dropped makes analysisd unreadable" 'homelab_wazuh_manager_source_ok{source="analysisd"} 0'
  put analysisd 0 "event_queue_usage='0.50'
events_received='1'
events_dropped='0'"
  out="$(MAX_BYTES=5 render "${WORK_DIR}")"
  has "an answer over the byte cap is a 0" 'homelab_wazuh_manager_source_ok{source="analysisd"} 0'
  exit $fail
fi

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

command -v docker >/dev/null 2>&1 || die "no docker on this host."
command -v python3 >/dev/null 2>&1 || die "no python3 to parse the manager's answers."

# A manager that is not running writes nothing: GuestServiceUnhealthy on the
# estate and InstanceDown-shaped rules already say so, and every source here
# would be a false 0 for a known reason. WazuhManagerStateStale says the file
# stopped moving.
[[ "$(docker inspect --format '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" == "true" ]] \
  || die "${CONTAINER} is not running; nothing written."

grab() {
  timeout -k 5 "${EXEC_TIMEOUT}" docker exec "${CONTAINER}" "${@:2}" 2>/dev/null \
    | head -c "$((MAX_BYTES + 1))" > "${WORK_DIR}/$1.out"
  printf '%s' "${PIPESTATUS[0]}" > "${WORK_DIR}/$1.rc"
}
grab analysisd cat /var/ossec/var/run/wazuh-analysisd.state
grab remoted cat /var/ossec/var/run/wazuh-remoted.state
grab agents /var/ossec/bin/agent_control -l -j

out="$(render "${WORK_DIR}")" || die "could not render the manager's answers."
if ((PRINT_ONLY)); then printf '%s\n' "$out"; exit 0; fi

[[ -d "${TEXTFILE_DIR}" ]] || die "no ${TEXTFILE_DIR}"
tmp="${PROM}.$$"
printf '%s\n' "$out" > "${tmp}" || { rm -f "${tmp}"; die "could not write ${tmp}"; }
chmod 0644 "${tmp}"
mv -f "${tmp}" "${PROM}"
printf 'wazuh-manager-state %s\n' "$(grep -o 'source="[a-z]*"} [01]' <<<"$out" | tr '\n' ' ')"
