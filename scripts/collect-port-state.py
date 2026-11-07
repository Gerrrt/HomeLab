#!/usr/bin/env python3
"""Write whether each running container holds the networking it was created with.

    scripts/collect-port-state.py [--print]
    scripts/collect-port-state.py --self-test

WHY THIS EXISTS (ADR-0105)
--------------------------
On 2026-11-05 this host booted without its address and dockerd started the
observability stack anyway. alloy and ingest-proxy publish ports on
10.0.99.20; Docker could not bind them, logged "cannot assign requested
address", and started both containers with no networks and no published ports.
Both reported `Up (healthy)` for about 25 hours, because each healthcheck runs
inside the container against its own loopback, and that is exactly the part
that still worked. `docker restart` kept them that way. Only a force-recreate
fixed them.

EndpointUnreachable and InstanceDown did fire, but they say "the port does not
answer", which is also what a dead process, a bad certificate or a firewall
says. This names the actual state, which has exactly one fix.

WHAT IT COMPARES
----------------
Per running container, from `docker inspect`:

  * HostConfig.PortBindings  what the container was created to publish
  * NetworkSettings.Ports    what Docker actually published

and writes

  homelab_container_ports_missing{name, project}
      declared host bindings that are not published. 0 when all are.
  homelab_container_networks_attached{name, project}
      networks the container is attached to. 0 is the failure above; a
      container in network_mode host, none or container:* is not written,
      because 0 is right for it.

Containers labelled homelab.logs=off are skipped, as in
collect-container-state.sh: the label marks the estate's throwaways.

The job's own staleness is ScheduledJobStale's, through run-scheduled.sh.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

TEXTFILE_DIR = os.environ.get("TEXTFILE_DIR", "/var/lib/node_exporter/textfile_collector")
# Not port-state.prom, the job's name: run-scheduled.sh writes "${JOB}.prom"
# for the job's outcome and refuses to overwrite a file it did not write
# (#360), so sharing the name would fail every scheduled run.
PROM_NAME = "container-networking.prom"
SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")


def bindings(ports):
    """{(container_port, host_ip, host_port)} from a Ports or PortBindings map."""
    out = set()
    for cport, binds in (ports or {}).items():
        for b in binds or []:
            out.add((cport, b.get("HostIp", ""), b.get("HostPort", "")))
    return out


def judge(c):
    """(name, project, missing, networks) for one inspect object, or None to skip."""
    labels = (c.get("Config") or {}).get("Labels") or {}
    if labels.get("homelab.logs") == "off":
        return None
    if not (c.get("State") or {}).get("Running"):
        return None
    name = (c.get("Name") or "").lstrip("/")
    if not SAFE.match(name):
        return None
    project = labels.get("com.docker.compose.project", "")
    if project and not SAFE.match(project):
        project = ""
    host = c.get("HostConfig") or {}
    declared = bindings(host.get("PortBindings"))
    published = bindings((c.get("NetworkSettings") or {}).get("Ports"))
    # A declared HostIp of "" means every address, which Docker publishes as
    # 0.0.0.0 and ::. A declared HostPort of "" means any free port, which
    # Docker fills in. Each matches whatever Docker chose for it.
    missing = 0
    for cport, hip, hport in declared:
        ok = any(
            p[0] == cport
            and (p[1] == hip or (not hip and p[1] in ("", "0.0.0.0", "::")))
            and (p[2] == hport or not hport)
            for p in published
        )
        missing += 0 if ok else 1
    mode = host.get("NetworkMode", "")
    if mode in ("host", "none") or mode.startswith("container:"):
        networks = None
    else:
        networks = len((c.get("NetworkSettings") or {}).get("Networks") or {})
    return name, project, missing, networks


def render(containers):
    lines = [
        "# HELP homelab_container_ports_missing Host port bindings the container declares and Docker has not published.",
        "# TYPE homelab_container_ports_missing gauge",
    ]
    nets = [
        "# HELP homelab_container_networks_attached Networks a running bridge-mode container is attached to.",
        "# TYPE homelab_container_networks_attached gauge",
    ]
    for c in sorted(containers, key=lambda c: c.get("Name", "")):
        j = judge(c)
        if j is None:
            continue
        name, project, missing, networks = j
        lbl = f'name="{name}",project="{project}"'
        lines.append(f"homelab_container_ports_missing{{{lbl}}} {missing}")
        if networks is not None:
            nets.append(f"homelab_container_networks_attached{{{lbl}}} {networks}")
    return "\n".join(lines + nets) + "\n"


def inspect_all():
    ids = subprocess.run(["docker", "ps", "-q"], check=True, capture_output=True, text=True).stdout.split()
    if not ids:
        return []
    out = subprocess.run(["docker", "inspect", *ids], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def self_test():
    fail = 0

    def check(desc, got, want):
        nonlocal fail
        if got == want:
            print(f"\033[0;32m  PASS\033[0m {desc}")
        else:
            print(f"\033[0;31m  FAIL\033[0m {desc}\n       got      {got!r}\n       expected {want!r}")
            fail = 1

    def c(name, decl, pub, nets=1, mode="observability_default", running=True, logs=None):
        labels = {"com.docker.compose.project": "observability"}
        if logs:
            labels["homelab.logs"] = logs
        return {
            "Name": "/" + name,
            "State": {"Running": running},
            "Config": {"Labels": labels},
            "HostConfig": {"PortBindings": decl, "NetworkMode": mode},
            "NetworkSettings": {"Ports": pub, "Networks": {f"n{i}": {} for i in range(nets)}},
        }

    bind = {
        "3100/tcp": [{"HostIp": "10.0.99.20", "HostPort": "3100"}],
        "9090/tcp": [{"HostIp": "10.0.99.20", "HostPort": "9090"}],
    }
    # 2026-11-05 as it looked: both bindings declared, nothing published, no networks.
    check(
        "the 2026-11-05 ingest-proxy: both ports missing, no networks",
        judge(c("ingest-proxy", bind, {}, nets=0)),
        ("ingest-proxy", "observability", 2, 0),
    )
    # Docker lists exposed-but-unpublished ports as null; those are not missing.
    healthy_pub = dict(bind, **{"80/tcp": None, "443/tcp": None})
    check(
        "a healthy ingest-proxy: nothing missing, one network",
        judge(c("ingest-proxy", bind, healthy_pub)),
        ("ingest-proxy", "observability", 0, 1),
    )
    check("one of two ports missing counts one", judge(c("alloy", bind, {"3100/tcp": bind["3100/tcp"]}))[2], 1)
    check(
        "an unaddressed binding Docker published on 0.0.0.0 and :: is not missing",
        judge(
            c(
                "x",
                {"3000/tcp": [{"HostIp": "", "HostPort": "3000"}]},
                {"3000/tcp": [{"HostIp": "0.0.0.0", "HostPort": "3000"}, {"HostIp": "::", "HostPort": "3000"}]},
            )
        )[2],
        0,
    )
    check(
        "an ephemeral host port Docker filled in is not missing",
        judge(
            c(
                "x",
                {"80/tcp": [{"HostIp": "", "HostPort": ""}]},
                {"80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "32768"}]},
            )
        )[2],
        0,
    )
    check(
        "a specific address is not satisfied by a wildcard",
        judge(
            c(
                "x",
                {"80/tcp": [{"HostIp": "10.0.99.20", "HostPort": "80"}]},
                {"80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "80"}]},
            )
        )[2],
        1,
    )
    check(
        "network_mode host writes no networks series", judge(c("node-exporter", {}, {}, nets=0, mode="host"))[3], None
    )
    check("a stopped container is skipped", judge(c("x", bind, {}, running=False)), None)
    check("a homelab.logs=off throwaway is skipped", judge(c("x", bind, {}, logs="off")), None)
    check("a name that would break the label is skipped", judge(c('bad"name', {}, {})), None)
    out = render([c("ingest-proxy", bind, {}, nets=0)])
    check(
        "render writes both series for a broken container",
        [l for l in out.splitlines() if not l.startswith("#")],
        [
            'homelab_container_ports_missing{name="ingest-proxy",project="observability"} 2',
            'homelab_container_networks_attached{name="ingest-proxy",project="observability"} 0',
        ],
    )
    return fail


def main(argv):
    if "--self-test" in argv:
        return self_test()
    text = render(inspect_all())
    if "--print" in argv:
        sys.stdout.write(text)
        return 0
    if not os.path.isdir(TEXTFILE_DIR):
        print(f"error: no textfile directory at {TEXTFILE_DIR}", file=sys.stderr)
        return 1
    fd, tmp = tempfile.mkstemp(dir=TEXTFILE_DIR, prefix=".port-state.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(TEXTFILE_DIR, PROM_NAME))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
