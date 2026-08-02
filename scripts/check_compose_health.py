#!/usr/bin/env python3
"""Check that compose health dependencies can actually be satisfied.

`depends_on: <svc>: condition: service_healthy` waits for <svc> to report
healthy. If <svc> declares no healthcheck it never will, and everything
downstream hangs forever with no error — the stack simply never finishes
starting.

That happened here: Loki's image is gcr.io/distroless/static:nonroot, which
contains only /usr/bin/loki — no shell, no wget, no curl. The healthcheck
execed wget, which cannot exist, so Loki was permanently "starting" and both
Grafana and Alloy blocked on it. Nothing logged an error; `make up` just sat
there.

Also flags healthchecks that exec a binary the image is unlikely to provide,
since that is the same failure wearing a different hat.

Usage: scripts/check_compose_health.py [compose.yaml]
"""
from __future__ import annotations

import pathlib
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT = REPO / "stacks/observability/compose.yaml"

# Images with no shell and no userland. A healthcheck cannot exec anything in
# these beyond the service binary itself.
DISTROLESS_MARKERS = ("distroless", "/static", "scratch")


def main() -> int:
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    if not path.exists():
        return int(bool(print(f"no compose file at {path}", file=sys.stderr))) or 1

    compose = yaml.safe_load(path.read_text(encoding="utf-8"))
    services = compose.get("services") or {}
    problems: list[str] = []

    for name, svc in services.items():
        svc = svc or {}
        depends = svc.get("depends_on")
        if not isinstance(depends, dict):
            continue

        for target, cfg in depends.items():
            condition = cfg.get("condition") if isinstance(cfg, dict) else cfg
            if condition != "service_healthy":
                continue

            target_svc = services.get(target)
            if target_svc is None:
                problems.append(
                    f"{name} depends on {target}, which is not defined in this file"
                )
            elif not target_svc.get("healthcheck"):
                problems.append(
                    f"{name} waits for {target} to become healthy, but {target} "
                    f"declares no healthcheck — it can never report healthy, so "
                    f"{name} will hang forever"
                )

    # A healthcheck on a distroless image is equally unsatisfiable.
    for name, svc in services.items():
        svc = svc or {}
        check = svc.get("healthcheck")
        image = str(svc.get("image", ""))
        if not check or check.get("disable"):
            continue
        test = check.get("test")
        if isinstance(test, list) and test and test[0] in ("CMD", "CMD-SHELL"):
            binary = test[1] if len(test) > 1 else ""
            if any(m in image.lower() for m in DISTROLESS_MARKERS):
                problems.append(
                    f"{name} has a healthcheck exec'ing {binary!r} but its image "
                    f"looks distroless — there is no userland to run it"
                )

    for problem in problems:
        print(f"  {problem}", file=sys.stderr)

    if problems:
        print(
            f"\n{len(problems)} unsatisfiable health dependency/dependencies "
            f"in {path.name}",
            file=sys.stderr,
        )
        return 1

    healthy_deps = sum(
        1
        for svc in services.values()
        for cfg in ((svc or {}).get("depends_on") or {}).values()
        if (cfg.get("condition") if isinstance(cfg, dict) else cfg) == "service_healthy"
    )
    checks = sum(1 for svc in services.values() if (svc or {}).get("healthcheck"))
    print(
        f"{path.name} OK — {checks} healthcheck(s), "
        f"{healthy_deps} service_healthy dependency/dependencies, all satisfiable"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
