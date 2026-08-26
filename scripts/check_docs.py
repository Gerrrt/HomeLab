#!/usr/bin/env python3
"""Assert the documents still agree with the configs they describe.

Documentation drift is this repository's most frequently-recurring defect, and
unlike the others it has never had a check. `oracle` was recorded as an
i5-1235U with 32 GB when it is a dual-core A6-9200 with 4 GB, and ADR-0008 notes
that wrong entry was load-bearing in planning. `shiva` was described as the
hypervisor for several revisions when it is the iLO. `roadmap.md` says of itself
that it "has already been wrong about the switch answering SNMP and about the
history purge". Alert-rule and panel counts went stale in eight places (#72),
one of them a verification step inside a deploy runbook.

Every other class of defect here was answered by moving truth somewhere CI can
check it. This does that for `docs/`, following the pattern
`scripts/snmp-targets.sh --check` already established for the SNMP inventory:

    The device list must live in exactly one place. It is currently spread
    across five ... and --check asserts the other copies still agree.

Six assertions, each comparing prose against something machine-readable:

  1. Counted claims        rules, dashboards and panels quoted in prose
  2. SNMP targets          snmp.yaml <-> docs/network.md
  3. Host and stack table  docs/architecture.md <-> docs/network.md, stacks/
  4. Ports table           docs/architecture.md <-> compose.yaml
  5. Compute table         docs/hardware.md <-> docs/network.md
  6. Image versions        no version pins in prose; compose.yaml owns them

Only present-tense documents are checked. `docs/roadmap.md` and `docs/adr/`
record what was true when the work landed — `roadmap.md` still says "(34 rules)"
in a Done entry, and that is correct as written. Failing on those would need an
ignore list, and this repository has already learned where that leads: the
`.gitleaksignore` deleted in the history purge "was an acknowledgement, not a
fix, and it existed because a CI job that is permanently red for a known reason
gets ignored". So the scope is a fixed list of files rather than a suppression
mechanism that grows.

Usage: scripts/check_docs.py
"""
from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys

try:
    import yaml
except ModuleNotFoundError:
    print("installing PyYAML", file=sys.stderr)
    if subprocess.run(
        [sys.executable, "-m", "pip", "install", "--quiet",
         "--disable-pip-version-check", "pyyaml"],
        check=False,
    ).returncode:
        sys.exit("PyYAML is required and could not be installed")
    import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
STACK = REPO / "stacks/observability"
COMPOSE = STACK / "compose.yaml"
NETWORK_MD = REPO / "docs/network.md"
ARCH_MD = REPO / "docs/architecture.md"
HARDWARE_MD = REPO / "docs/hardware.md"

# Present-tense documents. See the module docstring for why roadmap.md and
# adr/ are deliberately absent — they are records, not claims about now.
PROSE = (
    "README.md",
    "SECURITY.md",
    "docs/architecture.md",
    "docs/hardware.md",
    "docs/network.md",
    "docs/observability.md",
    "docs/security.md",
    "stacks/observability/README.md",
    *sorted(
        str(p.relative_to(REPO)) for p in (REPO / "docs/runbooks").glob("*.md")
    ),
)


# ---------------------------------------------------------------------------
# Markdown helpers
# ---------------------------------------------------------------------------
def cells(line: str) -> list[str]:
    """Split one markdown table row into stripped cells."""
    return [c.strip() for c in line.strip().strip("|").split("|")]


def is_separator(line: str) -> bool:
    return bool(re.fullmatch(r"\|[\s:|-]+\|", line.strip()))


def tables_under(text: str, heading: re.Pattern[str]) -> list[list[list[str]]]:
    """Every markdown table in the section introduced by `heading`.

    A section runs to the next heading of the same or higher level, so a
    table belonging to a later section is never attributed to this one.
    """
    out: list[list[list[str]]] = []
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if heading.match(line):
            start = i
            break
    if start is None:
        return out

    level = len(lines[start]) - len(lines[start].lstrip("#"))
    rows: list[list[str]] = []
    for line in lines[start + 1:]:
        if line.startswith("#"):
            depth = len(line) - len(line.lstrip("#"))
            if depth <= level:
                break
        if line.lstrip().startswith("|"):
            if not is_separator(line):
                rows.append(cells(line))
        elif rows:
            out.append(rows)
            rows = []
    if rows:
        out.append(rows)
    return out


def strip_md(cell: str) -> str:
    """Reduce a table cell to its plain text: no backticks, links or emphasis."""
    cell = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", cell)     # links
    cell = re.sub(r"\[\^[^\]]*\]", "", cell)                  # footnote refs
    cell = cell.replace("`", "").replace("*", "").replace("**", "")
    return cell.strip()


# ---------------------------------------------------------------------------
# Facts, computed from the configs
# ---------------------------------------------------------------------------
def count_alerts(paths) -> int:
    return sum(
        len(re.findall(r"^\s*-\s*alert:", p.read_text(encoding="utf-8"), re.M))
        for p in paths
    )


def count_panels(paths) -> int:
    """Every panel object, rows included.

    Rows are counted because the numbers already in the documents count them:
    84 with rows, 73 without. Pinning the definition here is what makes the
    figure reproducible rather than a number somebody once arrived at.
    """
    total = 0

    def walk(panels) -> None:
        nonlocal total
        for panel in panels or []:
            total += 1
            walk(panel.get("panels"))

    for path in paths:
        walk(json.loads(path.read_text(encoding="utf-8")).get("panels"))
    return total


def compose_services() -> dict:
    """Services that `make up` actually starts.

    Profile-gated services are excluded: `renderer` sits behind the `capture`
    profile precisely so the running stack stays six services, and counting it
    would make this check disagree with a document that is correct.
    """
    doc = yaml.safe_load(COMPOSE.read_text(encoding="utf-8"))
    return {
        name: svc or {}
        for name, svc in (doc.get("services") or {}).items()
        if not (svc or {}).get("profiles")
    }


def facts() -> dict:
    prom_rules = sorted((STACK / "prometheus/rules").glob("*.rules.yaml"))
    loki_rules = sorted((STACK / "loki/rules").glob("*.rules.yaml"))
    dashboards = sorted((STACK / "grafana/dashboards").glob("*.json"))
    prom = count_alerts(prom_rules)
    loki = count_alerts(loki_rules)
    return {
        "prometheus_rules": prom,
        "loki_rules": loki,
        "total_rules": prom + loki,
        "dashboards": len(dashboards),
        "panels": count_panels(dashboards),
    }


# ---------------------------------------------------------------------------
# 1. Counted claims
# ---------------------------------------------------------------------------
def check_counts(f: dict) -> list[str]:
    # "N alert rules" is genuinely ambiguous in this repository: README uses it
    # for the total, security.md for the Prometheus half. Both readings are
    # legitimate prose, so both are accepted — the check still catches a number
    # that is neither, which is what stale looks like.
    claims = (
        (r"(\d+)\s+alert rules", {f["prometheus_rules"], f["total_rules"]},
         "alert rules"),
        (r"(\d+)\s+rules in total", {f["total_rules"]}, "total rules"),
        (r"(\d+)\s+rules loaded", {f["prometheus_rules"]}, "rules loaded"),
        (r"(\d+)\s+rules across", {f["prometheus_rules"]}, "Prometheus rules"),
        (r"(\d+)\s+metric-based", {f["prometheus_rules"]}, "metric-based rules"),
        (r"(\d+)\s+log-based", {f["loki_rules"]}, "log-based rules"),
        (r"(\d+)\s+(?:provisioned\s+)?dashboards", {f["dashboards"]}, "dashboards"),
        (r"(\d+)\s+panels", {f["panels"]}, "panels"),
    )
    problems = []
    for rel in PROSE:
        path = REPO / rel
        if not path.exists():
            continue
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for pattern, expected, label in claims:
                for match in re.finditer(pattern, line):
                    if int(match.group(1)) not in expected:
                        want = " or ".join(str(v) for v in sorted(expected))
                        problems.append(
                            f"{rel}:{n} claims {match.group(1)} {label}; "
                            f"the repository has {want}"
                        )
    return problems


# ---------------------------------------------------------------------------
# 2. SNMP targets against the network inventory
# ---------------------------------------------------------------------------
def network_sections(text: str) -> dict[str, list[list[str]]]:
    """Host rows keyed by VLAN id, plus 'wan' and 'lan'."""
    out: dict[str, list[list[str]]] = {}
    for heading in re.finditer(r"^##\s+(.+)$", text, re.M):
        title = heading.group(1)
        vlan_match = re.search(r"VLAN\s+(\d+)", title)
        if vlan_match:
            key = vlan_match.group(1)
        elif title.strip().upper() in ("WAN", "LAN"):
            key = title.strip().lower()
        else:
            continue
        found = tables_under(text, re.compile(re.escape(heading.group(0))))
        if found:
            out[key] = found[0]
    return out


def check_snmp_targets() -> list[str]:
    targets_file = STACK / "prometheus/targets/snmp.yaml"
    targets = yaml.safe_load(targets_file.read_text(encoding="utf-8")) or []
    sections = network_sections(NETWORK_MD.read_text(encoding="utf-8"))
    problems = []

    for entry in targets:
        labels = entry.get("labels") or {}
        device = labels.get("device", "")
        vlan = str(labels.get("vlan", ""))
        ips = entry.get("targets") or []
        rows = sections.get(vlan)
        if rows is None:
            problems.append(
                f"snmp.yaml polls {device} with vlan label {vlan!r}, and "
                f"docs/network.md has no section for it"
            )
            continue
        for ip in ips:
            hit = [
                r for r in rows
                if strip_md(r[0]).lower() == device.lower() and ip in strip_md(r[1])
            ]
            if not hit:
                problems.append(
                    f"snmp.yaml polls {device} at {ip} on VLAN {vlan}, and "
                    f"docs/network.md does not list that host at that address "
                    f"in the VLAN {vlan} table"
                )
    return problems


# ---------------------------------------------------------------------------
# 3. Host and stack mapping
# ---------------------------------------------------------------------------
def check_host_stack_table() -> list[str]:
    text = ARCH_MD.read_text(encoding="utf-8")
    tables = tables_under(text, re.compile(r"^##\s+Host and stack mapping"))
    if not tables:
        return ["docs/architecture.md has no 'Host and stack mapping' table"]

    rows = tables[0][1:]
    sections = network_sections(NETWORK_MD.read_text(encoding="utf-8"))
    problems = []
    named_stacks: set[str] = set()

    for row in rows:
        host_cell = strip_md(row[0])
        host = host_cell.split("(")[0].strip()
        ip_match = re.search(r"(\d+\.\d+\.\d+\.\d+)", host_cell)
        vlan_match = re.search(r"(\d+)", strip_md(row[1]))
        named_stacks.update(re.findall(r"stacks/([a-z0-9-]+)", row[2]))

        if not (ip_match and vlan_match):
            problems.append(
                f"docs/architecture.md host row {host_cell!r} has no address or "
                f"no VLAN, so it cannot be checked against docs/network.md"
            )
            continue

        ip, vlan = ip_match.group(1), vlan_match.group(1)
        rows_for_vlan = sections.get(vlan, [])
        hit = [
            r for r in rows_for_vlan
            if strip_md(r[0]).lower() == host.lower() and ip in strip_md(r[1])
        ]
        if not hit:
            problems.append(
                f"docs/architecture.md places {host} at {ip} on VLAN {vlan}; "
                f"docs/network.md does not list it there"
            )

    on_disk = {
        p.name for p in (REPO / "stacks").iterdir()
        if p.is_dir() and not p.name.startswith(".")
    }
    for missing in sorted(on_disk - named_stacks):
        problems.append(
            f"stacks/{missing}/ exists and no row of the host and stack mapping "
            f"in docs/architecture.md names it — ADR-0004 puts that mapping in "
            f"documentation, which only works if it is complete"
        )
    return problems


# ---------------------------------------------------------------------------
# 4. Ports
# ---------------------------------------------------------------------------
def published_ports(services: dict) -> dict[str, list[tuple[str, str]]]:
    """service -> [(bind, container port)] for anything bound to the host."""
    out: dict[str, list[tuple[str, str]]] = {}
    for name, svc in services.items():
        for spec in svc.get("ports") or []:
            parts = str(spec).split(":")
            if len(parts) < 2:
                continue  # "9116" — exposed to the compose network only
            bind = parts[0]
            container = parts[-1]
            bind = "127.0.0.1" if bind == "127.0.0.1" else "${BIND_ADDR}"
            out.setdefault(name, []).append((bind, container))
    return out


def check_ports() -> list[str]:
    text = ARCH_MD.read_text(encoding="utf-8")
    tables = tables_under(text, re.compile(r"^##\s+Ports\s*$"))
    if not tables:
        return ["docs/architecture.md has no 'Ports' table"]

    services = compose_services()
    published = published_ports(services)
    problems = []
    documented: set[tuple[str, str]] = set()

    for row in tables[0][1:]:
        service = strip_md(row[0]).lower().split()[0]
        port = strip_md(row[1])
        bind = strip_md(row[2])
        internal_only = "compose network" in bind.lower()

        if service not in services:
            problems.append(
                f"docs/architecture.md documents a port for {service!r}, which "
                f"is not a service in compose.yaml"
            )
            continue

        if internal_only:
            if service in published:
                problems.append(
                    f"docs/architecture.md says {service} is never published to "
                    f"a host interface; compose.yaml publishes it"
                )
            continue

        want_bind = "127.0.0.1" if "127.0.0.1" in bind else "${BIND_ADDR}"
        actual = published.get(service, [])
        match = [a for a in actual if a[1] == port]
        if not match:
            problems.append(
                f"docs/architecture.md says {service} publishes {port}; "
                f"compose.yaml publishes "
                f"{', '.join(p for _, p in actual) or 'nothing'}"
            )
            continue
        if match[0][0] != want_bind:
            problems.append(
                f"docs/architecture.md says {service}:{port} binds to {bind}; "
                f"compose.yaml binds it to {match[0][0]}"
            )
        documented.add((service, port))

    for service, entries in published.items():
        for _, port in entries:
            if (service, port) not in documented:
                problems.append(
                    f"compose.yaml publishes {service}:{port} and the ports "
                    f"table in docs/architecture.md does not mention it"
                )
    return problems


# ---------------------------------------------------------------------------
# 5. Compute table
# ---------------------------------------------------------------------------
def os_key(text: str) -> tuple[str, str]:
    """('ubuntu', '24.04.3') from 'Ubuntu Server 24.04.3'.

    The two documents word the same OS differently on purpose — network.md
    says 'Ubuntu 24.04.3' where hardware.md says 'Ubuntu Server 24.04.3', and
    'FreeBSD 15.0' where the other says 'FreeBSD 15.0 (pfSense)'. Comparing the
    family and the version rather than the string is what keeps this an
    agreement check instead of a house-style check.
    """
    plain = strip_md(text)
    family = re.match(r"([A-Za-z]+)", plain)
    version = re.search(r"(\d+(?:\.\d+)*)", plain)
    return (
        family.group(1).lower() if family else "",
        version.group(1) if version else "",
    )


def check_compute_table() -> list[str]:
    tables = tables_under(
        HARDWARE_MD.read_text(encoding="utf-8"), re.compile(r"^##\s+Compute")
    )
    if not tables:
        return ["docs/hardware.md has no 'Compute' table"]

    sections = network_sections(NETWORK_MD.read_text(encoding="utf-8"))
    hosts: dict[str, tuple[str, str]] = {}
    for rows in sections.values():
        for row in rows[1:]:
            if len(row) >= 5:
                hosts.setdefault(strip_md(row[0]).lower(), os_key(row[4]))

    problems = []
    for row in tables[0][1:]:
        host = strip_md(row[0])
        want = os_key(row[5])
        have = hosts.get(host.lower())
        if have is None:
            problems.append(
                f"docs/hardware.md lists {host}, which appears nowhere in "
                f"docs/network.md"
            )
        elif have != want:
            problems.append(
                f"docs/hardware.md says {host} runs {strip_md(row[5])!r}; "
                f"docs/network.md says {have[0]} {have[1]}"
            )
    return problems


# ---------------------------------------------------------------------------
# 6. Image versions must not appear in prose at all
# ---------------------------------------------------------------------------
def check_image_versions() -> list[str]:
    """compose.yaml is the only place an image version may appear.

    An earlier version of this check asserted that a version quoted in prose
    *matched* compose.yaml. That keeps the documents honest but keeps the
    duplication, and the duplication is the actual defect: Dependabot edits
    only compose.yaml, so a version written anywhere else is stale from the
    next bump onward. All six in the stack README went stale exactly that way
    (#73), and matching them would have made every Dependabot PR red until
    someone hand-edited a table.

    ci.yml already refuses duplicated pins in shell, YAML and the Makefile —
    "hardcoded copies went stale silently" — but its grep does not cover
    Markdown, which is how the six survived. This is that rule, extended to
    prose.
    """
    pinned = set()
    doc = yaml.safe_load(COMPOSE.read_text(encoding="utf-8"))
    for svc in (doc.get("services") or {}).values():
        image = str((svc or {}).get("image", ""))
        if image:
            pinned.add(image.partition("@")[0].rpartition(":")[0])

    # Only inline code spans, and only a repository compose.yaml actually
    # pins. An OS version in a hardware table is not an image pin, and neither
    # is a registry path mentioned without a tag — naming the image is fine,
    # naming its version is what goes stale.
    span = re.compile(r"`([a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*):([^`\s]+)`")
    problems = []
    for rel in PROSE:
        path = REPO / rel
        if not path.exists():
            continue
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for match in span.finditer(line):
                repository = match.group(1)
                if repository in pinned:
                    problems.append(
                        f"{rel}:{n} pins {repository}:{match.group(2)}; only "
                        f"compose.yaml may carry a version — drop the tag and "
                        f"write `{repository}`"
                    )
    return problems


# ---------------------------------------------------------------------------
def main() -> int:
    f = facts()
    checks = (
        ("counted claims", lambda: check_counts(f)),
        ("SNMP targets against docs/network.md", check_snmp_targets),
        ("host and stack mapping", check_host_stack_table),
        ("ports table against compose.yaml", check_ports),
        ("compute table against docs/network.md", check_compute_table),
        ("image versions in prose (compose.yaml owns them)", check_image_versions),
    )

    total = 0
    for label, check in checks:
        problems = check()
        total += len(problems)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        if problems:
            print(f"  ^ {label}\n", file=sys.stderr)

    if total:
        print(
            f"{total} disagreement(s) between the documents and the configs",
            file=sys.stderr,
        )
        return 1

    print(
        f"docs OK — {f['prometheus_rules']} Prometheus + {f['loki_rules']} Loki "
        f"rules, {f['dashboards']} dashboards, {f['panels']} panels, "
        f"{len(checks)} assertions"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
