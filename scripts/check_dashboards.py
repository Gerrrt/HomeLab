#!/usr/bin/env python3
"""Validate provisioned Grafana dashboards.

Grafana silently accepts a dashboard that references a datasource UID which
does not exist — the panels simply render empty, which looks like "no data"
rather than "misconfigured". This checks the things Grafana will not:

  * the JSON parses;
  * every datasource UID resolves to one declared in provisioning;
  * every dashboard UID is unique across the folder;
  * panels fit the 24-column grid and do not overlap;
  * every panel has at least one target.

Additionally, every PromQL expression is emitted to stdout in Prometheus
recording-rule form when --emit-promql is passed, so promtool can parse them.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DASHBOARDS = REPO / "stacks/observability/grafana/dashboards"
DATASOURCES = REPO / "stacks/observability/grafana/provisioning/datasources/datasources.yaml"

# UIDs Grafana provides itself.
BUILTIN_UIDS = {"-- Grafana --", "-- Mixed --", "-- Dashboard --", "grafana"}


def declared_datasource_uids() -> set[str]:
    """Read provisioned UIDs without requiring PyYAML."""
    uids = set()
    if not DATASOURCES.exists():
        return uids
    for line in DATASOURCES.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("uid:"):
            uids.add(stripped.split(":", 1)[1].strip())
    return uids


def walk_datasource_uids(node, found: set[str]) -> None:
    if isinstance(node, dict):
        if set(node) <= {"type", "uid"} and "uid" in node:
            found.add(node["uid"])
        for value in node.values():
            walk_datasource_uids(value, found)
    elif isinstance(node, list):
        for value in node:
            walk_datasource_uids(value, found)


def overlaps(a: dict, b: dict) -> bool:
    return not (
        a["x"] + a["w"] <= b["x"]
        or b["x"] + b["w"] <= a["x"]
        or a["y"] + a["h"] <= b["y"]
        or b["y"] + b["h"] <= a["y"]
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit-promql", action="store_true",
                        help="print dashboard PromQL as a rules file for promtool")
    args = parser.parse_args()

    known = declared_datasource_uids() | BUILTIN_UIDS
    problems: list[str] = []
    seen_dashboard_uids: dict[str, str] = {}
    promql: list[str] = []

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

        panels = dash.get("panels", [])
        for i, panel in enumerate(panels):
            title = panel.get("title") or f"<untitled #{i}>"
            grid = panel.get("gridPos")
            if not grid:
                problems.append(f"{name}: panel '{title}' has no gridPos")
                continue
            if grid["x"] + grid["w"] > 24:
                problems.append(
                    f"{name}: panel '{title}' overflows the 24-column grid "
                    f"(x={grid['x']} w={grid['w']})"
                )
            if panel.get("type") not in ("row", "text") and not panel.get("targets"):
                problems.append(f"{name}: panel '{title}' has no targets")

            for other in panels[i + 1:]:
                og = other.get("gridPos")
                if og and overlaps(grid, og):
                    problems.append(
                        f"{name}: panels '{title}' and "
                        f"'{other.get('title')}' overlap"
                    )

            for target in panel.get("targets", []):
                expr = target.get("expr")
                ds_uid = (target.get("datasource") or {}).get("uid")
                if expr and ds_uid != "loki":
                    promql.append(expr)

    if args.emit_promql:
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

    for problem in problems:
        print(f"  {problem}", file=sys.stderr)

    if problems:
        print(f"\n{len(problems)} problem(s) in {len(files)} dashboard(s)", file=sys.stderr)
        return 1

    print(
        f"{len(files)} dashboards OK "
        f"({sum(len(json.loads(p.read_text())['panels']) for p in files)} panels, "
        f"{len(promql)} PromQL expressions)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
