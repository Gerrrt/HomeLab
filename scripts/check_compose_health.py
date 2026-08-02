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
import subprocess
import sys

# PyYAML is not guaranteed on a clean runner, and this script gates CI. Install
# it rather than failing a green compose file on a missing library — the same
# thing scripts/check_loki_rules.sh does, for the same reason.
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
DEFAULT = REPO / "stacks/observability/compose.yaml"

# An image reference says nothing about its base, so a substring heuristic alone
# would not have caught the bug this script exists to prevent: the offending
# image was `grafana/loki`, which contains none of the markers below. Known
# no-userland images therefore have to be listed by name.
#
# Verified against each project's published Dockerfile:
#   grafana/loki       gcr.io/distroless/static:nonroot  — /usr/bin/loki only
# For contrast, and so nobody adds them here by pattern-matching on the vendor:
#   prom/prometheus, prom/alertmanager, prom/snmp-exporter  busybox
#   grafana/grafana-oss                                     alpine
#   grafana/alloy                                           ubuntu
# — all four can run a wget healthcheck, and do.
NO_USERLAND_IMAGES = frozenset({"grafana/loki"})

# Still worth keeping for images that name their own base. Catches anything
# pulled straight from a distroless or scratch reference.
DISTROLESS_MARKERS = ("distroless", "/static", "scratch")


def has_no_userland(image: str) -> bool:
    """True if a healthcheck could not exec anything inside this image."""
    repository = image.split("@", 1)[0]
    # Strip the tag, but only if the trailing colon is a tag separator and not
    # the port in a registry host such as registry.local:5000/grafana/loki.
    head, sep, tail = repository.rpartition(":")
    if sep and "/" not in tail:
        repository = head
    repository = repository.lower()
    # Match bare and registry-qualified forms alike, so docker.io/grafana/loki
    # and registry.local:5000/grafana/loki are recognised as the same image.
    if any(
        repository == known or repository.endswith(f"/{known}")
        for known in NO_USERLAND_IMAGES
    ):
        return True
    return any(marker in image.lower() for marker in DISTROLESS_MARKERS)


def main() -> int:
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    if not path.exists():
        print(f"no compose file at {path}", file=sys.stderr)
        return 1

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
            if has_no_userland(image):
                problems.append(
                    f"{name} has a healthcheck exec'ing {binary!r}, but {image} "
                    f"has no shell and no userland — the probe can never run, so "
                    f"{name} stays 'starting' forever"
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
