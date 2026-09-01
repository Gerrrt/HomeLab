#!/usr/bin/env python3
"""Validate provisioned Grafana dashboards.

Grafana silently accepts a dashboard that references a datasource UID which
does not exist — the panels simply render empty, which looks like "no data"
rather than "misconfigured". This checks the things Grafana will not:

  * the JSON parses;
  * every datasource UID resolves to one declared in provisioning;
  * every dashboard UID is unique across the folder;
  * panels fit the 24-column grid and do not overlap;
  * every panel that queries data has at least one target;
  * every query target names a datasource that resolves, so the query language
    is known rather than guessed.

Panels nested inside a collapsed row are walked too. Collapsing a row in the UI
moves its panels from the top level into the row's own `panels` array, so a
checker that reads only the top level stops seeing them — see #78.

Additionally, panel expressions are emitted to stdout as a rules file so a
real parser can be pointed at them: --emit-promql writes Prometheus
recording-rule form for promtool, and --emit-logql writes Loki alerting-rule
form for scripts/check_loki_rules.sh. A query language nobody parses is one
where a typo renders an empty panel instead of raising an error, and "no data"
is indistinguishable from "this is broken" — which is the whole argument for
the PromQL check and applies unchanged to LogQL.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DASHBOARDS = REPO / "stacks/observability/grafana/dashboards"
DATASOURCES = REPO / "stacks/observability/grafana/provisioning/datasources/datasources.yaml"

# UIDs Grafana provides itself.
BUILTIN_UIDS = {"-- Grafana --", "-- Mixed --", "-- Dashboard --", "grafana"}

# Panel types that legitimately carry no targets.
#
# row and text render no data at all. alertlist is different and worth naming:
# it does read from a datasource, but not through a query — it pulls alerts from
# the Alertmanager datasource named in its own options, so a targets array would
# be meaningless. Requiring one here would have forced a fake target onto every
# alert panel, which is exactly the kind of thing that teaches people to work
# around this script rather than trust it.
TARGETLESS_PANEL_TYPES = {"row", "text", "alertlist"}

# Entries in datasources.yaml start at `- name:`; the keys that belong to one
# sit at the indent two columns to the right of the dash.
ENTRY_START = re.compile(r"^(\s*)- name:")
ENTRY_KEY = re.compile(r"^(\s*)([A-Za-z]\w*):\s*(.*)$")


def declared_datasources() -> dict[str, str]:
    """Map provisioned uid -> type, without requiring PyYAML.

    Only keys at the entry's own indent are read. Anything deeper belongs to a
    nested block — `jsonData:`, or the `derivedFields` list whose entries carry
    a `datasourceUid` — and reading those would put values in this map that are
    not datasource declarations at all.
    """
    declared: dict[str, str] = {}
    if not DATASOURCES.exists():
        return declared

    entry: dict[str, str] = {}
    key_indent = -1

    def flush() -> None:
        if "uid" in entry:
            declared[entry["uid"]] = entry.get("type", "")

    for line in DATASOURCES.read_text(encoding="utf-8").splitlines():
        start = ENTRY_START.match(line)
        if start:
            flush()
            entry = {}
            # `- name:` — the dash and its space put the key two columns right.
            key_indent = len(start.group(1)) + 2
            continue
        key = ENTRY_KEY.match(line)
        if key and len(key.group(1)) == key_indent:
            entry[key.group(2)] = key.group(3).strip()
    flush()
    return declared


def walk_datasource_uids(node, found: set[str]) -> None:
    if isinstance(node, dict):
        if set(node) <= {"type", "uid"} and "uid" in node:
            found.add(node["uid"])
        for value in node.values():
            walk_datasource_uids(value, found)
    elif isinstance(node, list):
        for value in node:
            walk_datasource_uids(value, found)


def panel_groups(panels, prefix: str = ""):
    """Yield each list of sibling panels, with the row path that locates it.

    Siblings are yielded as a group rather than one flat stream because overlap
    is only meaningful between panels that share a coordinate space. A collapsed
    row's children keep the gridPos they had when the row was expanded, so
    comparing them against the top-level panels would report overlaps that
    nobody can see and that expanding the row would resolve.
    """
    panels = panels or []
    yield prefix, panels
    for panel in panels:
        nested = panel.get("panels")
        if nested:
            title = panel.get("title") or "<untitled row>"
            yield from panel_groups(nested, f"{prefix}{title} → ")


def datasource_uid(node) -> str | None:
    """The uid a panel or target names, if it names one by uid at all."""
    datasource = (node or {}).get("datasource")
    if isinstance(datasource, dict):
        return datasource.get("uid")
    return None


def overlaps(a: dict, b: dict) -> bool:
    return not (
        a["x"] + a["w"] <= b["x"]
        or b["x"] + b["w"] <= a["x"]
        or a["y"] + a["h"] <= b["y"]
        or b["y"] + b["h"] <= a["y"]
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    emit = parser.add_mutually_exclusive_group()
    emit.add_argument("--emit-promql", action="store_true",
                      help="print dashboard PromQL as a rules file for promtool")
    emit.add_argument("--emit-logql", action="store_true",
                      help="print dashboard LogQL as a rules file for Loki's ruler")
    args = parser.parse_args()

    declared = declared_datasources()
    known = set(declared) | BUILTIN_UIDS
    problems: list[str] = []
    seen_dashboard_uids: dict[str, str] = {}
    promql: list[str] = []
    logql: list[str] = []
    panel_count = 0

    files = sorted(DASHBOARDS.glob("*.json"))
    if not files:
        print(f"no dashboards found in {DASHBOARDS}", file=sys.stderr)
        return 1

    for path in files:
        name = path.name
        try:
            dash = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            problems.append(f"{name}: invalid JSON — {exc}")
            continue

        uid = dash.get("uid")
        if not uid:
            problems.append(f"{name}: missing top-level 'uid'")
        elif uid in seen_dashboard_uids:
            problems.append(f"{name}: uid '{uid}' already used by {seen_dashboard_uids[uid]}")
        else:
            seen_dashboard_uids[uid] = name

        if not dash.get("title"):
            problems.append(f"{name}: missing 'title'")

        found: set[str] = set()
        walk_datasource_uids(dash, found)
        for unknown in sorted(found - known):
            problems.append(
                f"{name}: datasource uid '{unknown}' is not provisioned — "
                f"panels using it will render empty"
            )

        for prefix, panels in panel_groups(dash.get("panels")):
            panel_count += len(panels)
            for i, panel in enumerate(panels):
                title = f"{prefix}{panel.get('title') or f'<untitled #{i}>'}"
                grid = panel.get("gridPos")
                if not grid:
                    problems.append(f"{name}: panel '{title}' has no gridPos")
                    continue
                if not {"x", "y", "w", "h"} <= set(grid):
                    problems.append(
                        f"{name}: panel '{title}' has an incomplete gridPos "
                        f"({', '.join(sorted(grid))})"
                    )
                    continue
                if grid["x"] + grid["w"] > 24:
                    problems.append(
                        f"{name}: panel '{title}' overflows the 24-column grid "
                        f"(x={grid['x']} w={grid['w']})"
                    )
                if panel.get("type") not in TARGETLESS_PANEL_TYPES and not panel.get("targets"):
                    problems.append(f"{name}: panel '{title}' has no targets")

                for other in panels[i + 1:]:
                    og = other.get("gridPos")
                    if og and {"x", "y", "w", "h"} <= set(og) and overlaps(grid, og):
                        problems.append(
                            f"{name}: panels '{title}' and "
                            f"'{prefix}{other.get('title')}' overlap"
                        )

                # Which query language an expression is written in is decided by
                # the datasource it runs against, and a target that names none
                # of its own inherits the panel's. Deciding by elimination —
                # "not loki, therefore PromQL" — sent any target without a uid
                # to promtool as PromQL and failed it with a parse error that
                # named neither the panel nor the real problem (#78).
                for target in panel.get("targets", []):
                    expr = target.get("expr")
                    if not expr:
                        continue
                    ds_uid = datasource_uid(target) or datasource_uid(panel)
                    if ds_uid is None:
                        problems.append(
                            f"{name}: panel '{title}' has a target with an expression "
                            f"but no datasource on the target or the panel — "
                            f"the query language cannot be determined"
                        )
                    elif declared.get(ds_uid) == "prometheus":
                        promql.append(expr)
                    elif declared.get(ds_uid) == "loki":
                        # A logs panel's query is a bare stream selector, and
                        # the ruler only accepts expressions that return
                        # samples. Wrapping it is not a weaker check: the
                        # selector and its pipeline are what a typo lands in,
                        # and they are parsed either way. Panel type decides
                        # rather than a guess at the expression's shape,
                        # because Grafana already enforces the split — a Logs
                        # panel renders streams, everything else needs a
                        # number.
                        if panel.get("type") == "logs":
                            expr = f"count_over_time({expr} [5m])"
                        logql.append(expr)

    for problem in problems:
        print(f"  {problem}", file=sys.stderr)

    if problems:
        print(f"\n{len(problems)} problem(s) in {len(files)} dashboard(s)", file=sys.stderr)
        return 1

    if args.emit_promql:
        # Emission is gated on the datasource map resolving, so a run that finds
        # no PromQL at all is a broken classifier rather than a dashboard folder
        # with no metrics in it. Saying so here keeps promtool from being handed
        # an empty rules file and reporting success over it.
        if not promql:
            print("no PromQL expressions found — refusing to emit an empty "
                  "rules file", file=sys.stderr)
            return 1
        print("groups:")
        print("  - name: dashboard-expressions")
        print("    rules:")
        for i, expr in enumerate(promql):
            # Block scalar keeps multi-line expressions and quoting intact.
            print(f"      - record: dashboard:expr{i}")
            print("        expr: |")
            for line in expr.splitlines():
                print(f"          {line}")
        return 0

    if args.emit_logql:
        # Same reasoning as the PromQL guard above: an empty rules file is a
        # broken classifier, not a folder with no log panels in it.
        if not logql:
            print("no LogQL expressions found — refusing to emit an empty "
                  "rules file", file=sys.stderr)
            return 1
        print("groups:")
        print("  - name: dashboard-expressions")
        print("    rules:")
        for i, expr in enumerate(logql):
            # Alerting rules rather than recording rules: Loki's ruler only
            # writes recording-rule output to a remote_write target, and there
            # is none in the throwaway config check_loki_rules.sh builds. An
            # alert expression needs no comparison operator — FirewallLogsStopped
            # is a bare absent_over_time() and evaluates fine.
            print(f"      - alert: DashboardExpr{i}")
            print("        expr: |")
            for line in expr.splitlines():
                print(f"          {line}")
        return 0

    print(
        f"{len(files)} dashboards OK "
        f"({panel_count} panels, {len(promql)} PromQL "
        f"and {len(logql)} LogQL expressions)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
