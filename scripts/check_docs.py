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

Seven assertions, each comparing prose against something machine-readable:

  1. Counted claims        rules, unit-test coverage, dashboards, panels,
                           Alloy agents
  2. SNMP targets          snmp.yaml <-> docs/network.md
  3. Host and stack table  docs/architecture.md <-> docs/network.md, stacks/
  4. Ports table           docs/architecture.md <-> compose.yaml
  5. Compute table         docs/hardware.md <-> docs/network.md, and
                           neither pinning a point release
  6. Image versions        no version pins in prose; compose.yaml owns them
  7. ADR numbering         one ADR per number, and each file's H1 agrees with
                           the number in its filename

Only present-tense documents are checked. `docs/roadmap.md` and `docs/adr/`
record what was true when the work landed — `roadmap.md` still says "(34 rules)"
in a Done entry, and that is correct as written. Failing on those would need an
ignore list, and this repository has already learned where that leads: the
`.gitleaksignore` deleted in the history purge "was an acknowledgement, not a
fix, and it existed because a CI job that is permanently red for a known reason
gets ignored". So the scope is a fixed list of files rather than a suppression
mechanism that grows.

A count is matched whether it is written in digits or spelled out. The first
version of this check only looked for the phrasings someone happened to think
of, which left "13 LogQL rules" in README.md unguarded next to a checked "13
log-based", and left "five dashboards" in docs/images/README.md unguarded in a
file that was not in scope at all. Both were correct, and both would have gone
stale silently — the exact failure #72 is about, surviving inside its own fix.

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
    "docs/images/README.md",
    "docs/network.md",
    "docs/observability.md",
    "docs/security.md",
    "stacks/observability/README.md",
    *sorted(
        str(p.relative_to(REPO)) for p in (REPO / "docs/runbooks").glob("*.md")
    ),
)

# Prose spells small numbers out, and a spelled count goes stale exactly as
# readily as a digit: "five dashboards" and "across six files" were both
# unguarded while the digits beside them were checked. Twenty is comfortably
# above any count here — the cap keeps the alternation short, it is not a
# claim about the ceiling. Longest-first so "seven" cannot match inside
# "seventeen" and leave the rest of the pattern to fail.
#
# The word branch is case-insensitive because prose capitalises a number that
# starts a sentence, and a capital is not a different claim. It was matching
# lowercase only, so "There are five dashboards" was guarded while "Five
# dashboards are provisioned" two files away was not — and both were stale
# together (#81). `number()` already lowercased, so only the pattern was wrong.
#
# The cost of widening it: a heading like "Two dashboards are not captured" is a
# claim about a subset, and this reads it as a claim about the total and fails.
# That is the right way round — a false positive is a reword, a false negative is
# a document that lies. Phrase a subset so it does not put a bare count in front
# of the noun.
NUMBER_WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
}
COUNT = r"\b(\d+|(?i:" + "|".join(sorted(NUMBER_WORDS, key=len, reverse=True)) + r"))"


def number(token: str) -> int:
    """A counted claim, written either as digits or as a word."""
    return int(token) if token.isdigit() else NUMBER_WORDS[token.lower()]


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


# A host-and-stack row for something that does not exist yet. See the block
# above check_host_stack_table() for what it does there; count_alloy_agents()
# below reads it too, because a row describing an undeployed host describes an
# undeployed agent.
#
# Matched against the RAW cell, never strip_md()'s output: that helper removes
# every `*`, which takes the emphasis with it and leaves the marker unfindable.
NOT_BUILT = re.compile(r"\*\*not built yet\*\*", re.I)


# ---------------------------------------------------------------------------
# Facts, computed from the configs
# ---------------------------------------------------------------------------
def count_alerts(paths) -> int:
    return sum(
        len(re.findall(r"^\s*-\s*alert:", p.read_text(encoding="utf-8"), re.M))
        for p in paths
    )


def tested_alertnames(paths) -> set[str]:
    """Every alert named by a promtool unit test.

    `alertname:` appears twice per case — once selecting the rule, once inside
    exp_labels — so this is a set, not a count. A case asserting
    `exp_alerts: []` still counts the rule as covered: it was fed an input and
    its silence was asserted, which is the half of the pairing #63 was missing.

    This counts what the tests NAME, not what they prove. A test file naming a
    rule that no longer exists would inflate it — but `promtool test rules`
    fails on that first, so the two checks bracket each other.
    """
    names: set[str] = set()
    for path in paths:
        names.update(
            re.findall(
                r"^\s*alertname:\s*(\S+)", path.read_text(encoding="utf-8"), re.M
            )
        )
    return names


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


def count_alloy_agents() -> int:
    """Hosts the architecture table says run an Alloy agent.

    The agents are not in this repository — deploy-agent.sh puts them on
    hosts, and nothing here lists the hosts — so the Host and stack mapping
    is the machine-readable side. A row whose Contents cell names Alloy is an
    agent; "two Alloy agents" in hardware.md was unguarded and stale for as
    long as it took to deploy a third (#88).

    A row marked NOT_BUILT is not counted, because an agent on a host that does
    not exist is not an agent. `stacks/lab` declares one for `alexander`, and it
    collects nothing until that guest is racked (#262). The exclusion is not a
    convenience: dropping the marker on the commit that builds the host pushes
    this count to four and fails hardware.md's "three Alloy agents" in the same
    run, which is exactly when that sentence should be forced to change.
    """
    tables = tables_under(
        ARCH_MD.read_text(encoding="utf-8"),
        re.compile(r"^##\s+Host and stack mapping"),
    )
    if not tables:
        return 0
    return sum(
        1 for row in tables[0][1:]
        if len(row) > 3
        and "alloy" in strip_md(row[3]).lower()
        and not NOT_BUILT.search(row[3])
    )


def facts() -> dict:
    prom_rules = sorted((STACK / "prometheus/rules").glob("*.rules.yaml"))
    loki_rules = sorted((STACK / "loki/rules").glob("*.rules.yaml"))
    dashboards = sorted((STACK / "grafana/dashboards").glob("*.json"))
    prom = count_alerts(prom_rules)
    loki = count_alerts(loki_rules)
    tested = tested_alertnames(
        sorted((STACK / "prometheus/tests").glob("*.test.yaml"))
    )
    return {
        "prometheus_rules": prom,
        "loki_rules": loki,
        "total_rules": prom + loki,
        "dashboards": len(dashboards),
        "panels": count_panels(dashboards),
        "prometheus_rule_files": len(prom_rules),
        "tested_rules": len(tested),
        "untested_rules": prom - len(tested),
        "alloy_agents": count_alloy_agents(),
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
        (rf"{COUNT}\s+alert rules", {f["prometheus_rules"], f["total_rules"]},
         "alert rules"),
        (rf"{COUNT}\s+rules in total", {f["total_rules"]}, "total rules"),
        (rf"{COUNT}\s+rules loaded", {f["prometheus_rules"]}, "rules loaded"),
        (rf"{COUNT}\s+rules across", {f["prometheus_rules"]}, "Prometheus rules"),
        (rf"{COUNT}\s+metric-based", {f["prometheus_rules"]}, "metric-based rules"),
        (rf"{COUNT}\s+log-based", {f["loki_rules"]}, "log-based rules"),
        # README says "13 LogQL rules" where observability.md says "log-based".
        # Same number, different prose; the first phrasing matched nothing.
        (rf"{COUNT}\s+LogQL rules", {f["loki_rules"]}, "LogQL rules"),
        (rf"{COUNT}\s+(?:provisioned\s+)?dashboards", {f["dashboards"]},
         "dashboards"),
        (rf"{COUNT}\s+panels", {f["panels"]}, "panels"),
        # "39 rules across six files" states two counts. The first was checked
        # and the second was not, so splitting a rule file could not fail here.
        (rf"rules across\s+{COUNT}\s+files", {f["prometheus_rule_files"]},
         "Prometheus rule files"),
        # How many rules have a unit test, and how many do not. Both were
        # unguarded and both were already stale: the sentence read "Coverage is
        # six rules of 39 ... ContainerHighMemory and Watchdog" while
        # blackbox.test.yaml had covered three more for weeks. This is the
        # figure most likely to drift, because it moves whenever a test lands.
        (rf"[Cc]overage is\s+{COUNT}\s+rules", {f["tested_rules"]},
         "unit-tested rules"),
        (rf"[Oo]ther\s+{COUNT}\s+are still validated", {f["untested_rules"]},
         "rules without a unit test"),
        # "Coverage is fifteen rules of 45" states two counts and only the
        # first was checked, so the denominator could go stale on its own —
        # the same shape as "39 rules across six files" above, and it did go
        # stale the same way the moment a rule was added (#81).
        (rf"rules of\s+{COUNT}\s+so far", {f["prometheus_rules"]},
         "rules in the coverage denominator"),
        # Where the agents run is documented, not deployed from here, so the
        # architecture table is the source and hardware.md's sentence is the
        # claim. See count_alloy_agents.
        (rf"{COUNT}\s+Alloy agents", {f["alloy_agents"]}, "Alloy agents"),
    )
    problems = []
    for rel in PROSE:
        path = REPO / rel
        if not path.exists():
            continue
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for pattern, expected, label in claims:
                for match in re.finditer(pattern, line):
                    if number(match.group(1)) not in expected:
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
# A stack directory can legitimately exist before the host that runs it does.
# `stacks/lab` was committed complete — compose file, configs, rules, unit
# tests — while the guest that will run it, `alexander`, was still an issue
# (#262, #264). ADR-0004 puts the host-to-stack mapping in this document, so the
# row has to exist; but docs/network.md is the inventory of what is actually on
# the wire, and writing an unbuilt guest into it would be the precise kind of
# false claim this file exists to catch. It would also mean inventing a MAC, a
# device and an OS for a machine whose distribution is explicitly undecided.
#
# So the row is marked, and the marker INVERTS the check rather than switching
# it off. A normal row's host must APPEAR in network.md; a row marked "not built
# yet" must be ABSENT from it. That is what makes the marker self-clearing —
# rack the host, add its network.md row, and this fails saying the marker is
# stale, instead of quietly tolerating a row that claims both things at once.
# The address is still required and still checked for collisions, so a plan is
# held to the same standard as a deployment.
#
# The marker itself is defined next to strip_md(), because count_alloy_agents()
# reads it too.


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
        planned = bool(len(row) > 3 and NOT_BUILT.search(row[3]))

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

        if planned:
            # The VLAN must be one network.md actually describes, or a typo'd
            # segment would make every assertion below vacuously true.
            if not rows_for_vlan:
                problems.append(
                    f"docs/architecture.md plans {host} on VLAN {vlan}, which "
                    f"docs/network.md has no table for"
                )
            if hit:
                problems.append(
                    f"docs/architecture.md still marks {host} 'not built yet', "
                    f"and docs/network.md now lists it at {ip} on VLAN {vlan} — "
                    f"it has been built, so drop the marker"
                )
            # An unbuilt host planned onto an address something else already
            # holds is a real conflict, and the cheapest possible moment to
            # find it is before anyone racks it.
            clash = [
                r for r in rows_for_vlan
                if ip in strip_md(r[1]) and strip_md(r[0]).lower() != host.lower()
            ]
            if clash:
                problems.append(
                    f"docs/architecture.md plans {host} at {ip}, which "
                    f"docs/network.md already gives to "
                    f"{strip_md(clash[0][0])} on VLAN {vlan}"
                )
        elif not hit:
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
    """('ubuntu', '24.04') from 'Ubuntu Server 24.04 LTS'.

    The two documents word the same OS differently on purpose — network.md
    says 'Ubuntu 24.04 LTS' where hardware.md says 'Ubuntu Server 24.04 LTS',
    and 'FreeBSD 15.0' where the other says 'FreeBSD 15.0 (pfSense)'. Comparing
    the family and the version rather than the string is what keeps this an
    agreement check instead of a house-style check.
    """
    plain = strip_md(text)
    family = re.match(r"([A-Za-z]+)", plain)
    version = re.search(r"(\d+(?:\.\d+)*)", plain)
    return (
        family.group(1).lower() if family else "",
        version.group(1) if version else "",
    )


# A third component is a point release — 24.04.3, 9.2.11 — and a point release
# changes when the host takes an update, which is not an edit to this
# repository. Both laptops were recorded as 24.04.3 while running 24.04.4, and
# the two documents agreed with each other throughout, so the assertion below
# could not see it: it compares the copies, and both copies were stale.
#
# So the tables record the release line, which changes only on a decision to
# rebuild, and the running version stays where it is already collected —
# `node_os_info{pretty_name="Ubuntu 24.04.4 LTS"}` on every Linux host, from
# the same Alloy agents that produce everything else here.
#
# An assertion rather than a house rule in prose, because the rule is invisible
# to whoever adds the next host, and reading it off the existing rows is
# exactly what nobody does.
POINT_RELEASE = re.compile(r"\d+(?:\.\d+){2,}")


def point_release_problem(doc: str, host: str, cell: str) -> str | None:
    if not POINT_RELEASE.search(cell):
        return None
    return (
        f"{doc} gives {host} the OS {cell!r} — that column records the release "
        f"line, not the point release, which goes stale the next time the host "
        f"takes an update. node_os_info carries the running one"
    )


def check_compute_table() -> list[str]:
    tables = tables_under(
        HARDWARE_MD.read_text(encoding="utf-8"), re.compile(r"^##\s+Compute")
    )
    if not tables:
        return ["docs/hardware.md has no 'Compute' table"]

    sections = network_sections(NETWORK_MD.read_text(encoding="utf-8"))
    hosts: dict[str, tuple[str, str]] = {}
    # `hosts` keeps the first row per host, because the cross-document
    # comparison below needs one OS per host and every table agrees today.
    # `pinned` must not: `morpheus` has a row in all seven segment tables, so a
    # point release written into the sixth would be invisible to a check that
    # only ever reads the first. Every row is scanned; identical (host, cell)
    # pairs collapse so one mistake is reported once rather than seven times.
    pinned: set[tuple[str, str]] = set()
    for rows in sections.values():
        for row in rows[1:]:
            if len(row) >= 5:
                host, cell = strip_md(row[0]).lower(), strip_md(row[4])
                hosts.setdefault(host, os_key(row[4]))
                if POINT_RELEASE.search(cell):
                    pinned.add((host, cell))

    problems = []
    for host, cell in sorted(pinned):
        problem = point_release_problem("docs/network.md", host, cell)
        if problem:
            problems.append(problem)

    for row in tables[0][1:]:
        host = strip_md(row[0])
        want = os_key(row[5])
        have = hosts.get(host.lower())
        problem = point_release_problem("docs/hardware.md", host, strip_md(row[5]))
        if problem:
            problems.append(problem)
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
def check_adr_numbers() -> list[str]:
    """One ADR per number, and the H1 inside each file agreeing with its name.

    Two branches opened in the same afternoon both took 0017 — #96 for `ifrit`
    and #97 for the switch — and git merged them without a murmur, because the
    filenames differ and nothing downstream reads the number. The result is a
    repository where "ADR-0017" in prose has two referents, which is the one
    thing an ADR number exists to prevent. Nothing here caught it: every other
    assertion in this file compares prose against a config, and an ADR number
    is prose all the way down.

    The H1 check is the same failure one step later: renumbering a file is a
    `git mv` plus an edit, and the edit is the half that gets forgotten.
    """
    problems: list[str] = []
    adr_dir = REPO / "docs" / "adr"

    by_number: dict[str, list[str]] = {}
    for path in sorted(adr_dir.glob("[0-9][0-9][0-9][0-9]-*.md")):
        num = path.name[:4]
        by_number.setdefault(num, []).append(path.name)

        heading = ""
        for line in path.read_text().splitlines():
            if line.startswith("# "):
                heading = line
                break
        if not heading:
            problems.append(f"{path.name} has no H1 heading")
        elif not heading.startswith(f"# ADR-{num}:"):
            problems.append(
                f"{path.name} is numbered {num} but its heading reads "
                f"{heading[2:].split(':')[0]!r}"
            )

    for num, names in sorted(by_number.items()):
        if len(names) > 1:
            problems.append(
                f"ADR-{num} is claimed by {len(names)} files: {', '.join(names)} "
                f"— renumber the one that landed second"
            )

    return problems


def main() -> int:
    f = facts()
    checks = (
        ("counted claims", lambda: check_counts(f)),
        ("SNMP targets against docs/network.md", check_snmp_targets),
        ("host and stack mapping", check_host_stack_table),
        ("ports table against compose.yaml", check_ports),
        ("compute table against docs/network.md", check_compute_table),
        ("image versions in prose (compose.yaml owns them)", check_image_versions),
        ("ADR numbering", check_adr_numbers),
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
