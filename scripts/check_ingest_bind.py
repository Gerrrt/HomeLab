#!/usr/bin/env python3
"""INGEST_BIND_ADDR is one specific address in every stack that publishes on it.

Usage:
  scripts/check_ingest_bind.py               check every stack
  scripts/check_ingest_bind.py --self-test   fixtures

The ingest proxies publish on INGEST_BIND_ADDR: the estate's on `prometheus`,
the lab's on `alexander`. Each must answer on the address its agents dial and
nowhere else.

Until 2026-11-12 Docker enforced that by accident. The proxy published plain
9090 and 3100 beside the stores' own 127.0.0.1:9090 and :3100, and a wildcard
covers loopback, so `INGEST_BIND_ADDR=0.0.0.0` failed at `make up` with a port
clash. #1430 closed the lab's plain ports. A wildcard there would now bind
without error and publish the proxy on every address the host has. This makes
the rule explicit instead of leaving it to a clash.

`make up` renders .env from the committed .env.example (scripts/render-config.sh),
so the committed files are what a host deploys. For each stack whose
compose.yaml names INGEST_BIND_ADDR, this fails when:

  - a reference has no default, so the value would come from .env alone;
  - a default, or the .env.example value, is not one specific IPv4 address:
    a wildcard (0.0.0.0, ::), loopback, multicast, a name, or empty;
  - compose.yaml carries two different defaults;
  - .env.example does not set it, or sets it to an address other than
    compose.yaml's default.

Not covered: a value exported in the deploying shell, which compose prefers
to .env. Nothing in this repository exports one.
"""

from __future__ import annotations

import argparse
import ipaddress
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REF = re.compile(r"\$\{INGEST_BIND_ADDR(?P<op>:?[-?+])?(?P<default>[^}]*)\}")
ENV_LINE = re.compile(r"^\s*INGEST_BIND_ADDR\s*=\s*(?P<value>.*?)\s*$")


def why_not_specific(value: str) -> str | None:
    """None for one specific unicast IPv4 address, else what is wrong with it."""
    value = value.strip().strip("'\"")
    if not value:
        return "is empty"
    try:
        addr = ipaddress.ip_address(value.strip("[]"))
    except ValueError:
        return f"{value!r} is not an IP address"
    if addr.is_unspecified:
        return f"{value} is a wildcard: it publishes on every address the host has"
    if addr.version != 4:
        return f"{value} is not IPv4; every agent dials the host's IPv4 address"
    if addr.is_loopback:
        return f"{value} is loopback: no agent could reach it"
    if addr.is_multicast or addr.is_reserved or addr == ipaddress.ip_address("255.255.255.255"):
        return f"{value} is not a unicast host address"
    return None


def check_stack(stack: str, compose: str, env_example: str | None) -> list[str]:
    problems: list[str] = []
    defaults: set[str] = set()
    refs = list(REF.finditer(compose))
    if not refs:
        return problems
    for m in refs:
        if m.group("op") != ":-":
            problems.append(f"stacks/{stack}/compose.yaml: {m.group(0)} gives no default with ':-'")
            continue
        default = m.group("default")
        why = why_not_specific(default)
        if why:
            problems.append(f"stacks/{stack}/compose.yaml: the default in {m.group(0)} {why}")
        defaults.add(default)
    if len(defaults) > 1:
        problems.append(
            f"stacks/{stack}/compose.yaml: INGEST_BIND_ADDR has {len(defaults)} defaults: {sorted(defaults)}"
        )

    if env_example is None:
        problems.append(f"stacks/{stack}/.env.example: missing, so INGEST_BIND_ADDR is unset in the rendered .env")
        return problems
    values = [m.group("value") for line in env_example.splitlines() if (m := ENV_LINE.match(line))]
    if not values:
        problems.append(f"stacks/{stack}/.env.example: does not set INGEST_BIND_ADDR")
    elif len(values) > 1:
        problems.append(f"stacks/{stack}/.env.example: sets INGEST_BIND_ADDR {len(values)} times")
    else:
        value = values[0].strip("'\"")
        why = why_not_specific(value)
        if why:
            problems.append(f"stacks/{stack}/.env.example: INGEST_BIND_ADDR {why}")
        elif len(defaults) == 1 and value not in defaults:
            problems.append(
                f"stacks/{stack}/.env.example: INGEST_BIND_ADDR={value} but compose.yaml's default is "
                f"{next(iter(defaults))}; one of them names the wrong host"
            )
    return problems


def check_repo(root: Path) -> tuple[list[str], int]:
    problems: list[str] = []
    checked = 0
    for compose_path in sorted(root.glob("stacks/*/compose.yaml")):
        stack = compose_path.parent.name
        compose = compose_path.read_text(encoding="utf-8")
        if "INGEST_BIND_ADDR" not in compose:
            continue
        env_path = compose_path.parent / ".env.example"
        env = env_path.read_text(encoding="utf-8") if env_path.is_file() else None
        problems += check_stack(stack, compose, env)
        checked += 1
    return problems, checked


def self_test() -> int:
    good_compose = (
        'ports:\n  - "${INGEST_BIND_ADDR:-10.0.30.40}:${A:-9443}:9443"\n'
        '  - "${INGEST_BIND_ADDR:-10.0.30.40}:${B:-13100}:13100"\n'
    )
    good_env = "# the proxy\nINGEST_BIND_ADDR=10.0.30.40\n"
    cases = [
        ("a specific address in both files passes", good_compose, good_env, 0),
        ("a stack that never names it is ignored", "ports: []\n", None, 0),
        ("a quoted .env.example value passes", good_compose, 'INGEST_BIND_ADDR="10.0.30.40"\n', 0),
        ("0.0.0.0 in .env.example fails", good_compose, "INGEST_BIND_ADDR=0.0.0.0\n", 1),
        (
            "0.0.0.0 as compose's default fails",
            good_compose.replace("10.0.30.40", "0.0.0.0"),
            "INGEST_BIND_ADDR=0.0.0.0\n",
            1,
        ),
        ("the IPv6 wildcard fails", good_compose, "INGEST_BIND_ADDR=::\n", 1),
        ("a bracketed IPv6 wildcard fails", good_compose, "INGEST_BIND_ADDR=[::]\n", 1),
        ("loopback fails", good_compose, "INGEST_BIND_ADDR=127.0.0.1\n", 1),
        ("an empty value fails", good_compose, "INGEST_BIND_ADDR=\n", 1),
        ("a name fails", good_compose, "INGEST_BIND_ADDR=alexander\n", 1),
        ("a missing .env.example fails", good_compose, None, 1),
        ("an .env.example that does not set it fails", good_compose, "OTHER=1\n", 1),
        ("setting it twice fails", good_compose, good_env + "INGEST_BIND_ADDR=10.0.30.40\n", 1),
        ("an .env.example naming another host fails", good_compose, "INGEST_BIND_ADDR=10.0.99.20\n", 1),
        ("a reference with no default fails", '- "${INGEST_BIND_ADDR}:9443:9443"\n', good_env, 1),
        ("a ':?' reference fails", '- "${INGEST_BIND_ADDR:?set it}:9443:9443"\n', good_env, 1),
        (
            "two different defaults fail",
            good_compose.replace("10.0.30.40}:${B", "10.0.30.41}:${B"),
            good_env,
            1,
        ),
    ]
    failed = 0
    for desc, compose, env, want in cases:
        got = 1 if check_stack("lab", compose, env) else 0
        if got == want:
            print(f"\033[0;32m  PASS\033[0m {desc}")
        else:
            print(f"\033[0;31m  FAIL\033[0m {desc} (got {got}, want {want})")
            failed = 1
    return failed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--self-test", action="store_true", help="run the fixtures")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    problems, checked = check_repo(REPO)
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    if problems:
        return 1
    if not checked:
        print("  no stack names INGEST_BIND_ADDR; this check has nothing to protect", file=sys.stderr)
        return 1
    print(f"INGEST_BIND_ADDR OK — one specific address in each of {checked} stacks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
