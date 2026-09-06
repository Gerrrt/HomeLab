#!/usr/bin/env python3
"""Check that the healthchecks a deployed stack declares actually pass.

This is a DEPLOY-TIME check. It asks a running Docker daemon what each
container's health status is, so it means nothing in CI — there is no stack up
there to ask — and `make validate` does not run it. `make up` does, as its last
step, which is the only place the question can be answered.

Why it is separate from check_compose_health.py
-----------------------------------------------
That script answers "can this healthcheck ever run", statically and then by
exec'ing each healthcheck's binary inside its pinned image (#79, #204). It runs
in CI and gates pull requests. What it cannot answer is whether the URL that
binary probes returns anything: `wget --spider http://localhost:9116/-/healthy`
is a perfectly runnable command whether or not the path exists.

That gap is #205, and it is not hypothetical. snmp_exporter v0.30.1 serves no
`/health` — it returns 404 — so a probe pointed at `/health` instead of
`/-/healthy` failed on every run, and the container sat permanently unhealthy
while working perfectly. Nothing surfaced it: nothing `depends_on` snmp-exporter
so nothing blocked, Docker does not restart on unhealthy, there is no alert on
container health status, and the only symptom was a word in `make ps` that had
always been there.

So the two scripts have deliberately different failure modes and deliberately
different homes. Folding this one into the CI checker would produce a check that
either always skips or always fails, which is the argument #327 makes about the
Loki equivalent, one level up.

What it asserts
---------------
For every service the stack's compose.yaml declares a healthcheck on:

  * a container for it is running;
  * that container reports a health status at all — a running container with
    none, where compose declares one, is a container that predates the
    healthcheck and has not been recreated since;
  * that status reaches `healthy` before the deadline below.

`unhealthy` fails immediately and prints the last probe output, which is where
the 404 body, the connection refusal or the TLS error actually appears.

The deadline is derived, not chosen
-----------------------------------
Per service, from that service's own healthcheck:

    start_period + retries x (interval + timeout)

which is the point by which Docker itself would have stopped calling it
`starting` and called it `unhealthy`. A container still `starting` past that has
had every post-start-period probe fail, so waiting longer only delays the same
verdict. Nothing here is a round number somebody picked, which matters because a
margin picked by hand is the thing that gets raised each time it trips.

What it does NOT cover, and says so
-----------------------------------
A service that declares no healthcheck cannot fail this check, because there is
nothing to fail. loki and alloy are both in that position today. They are
listed in the output rather than passed over silently: the count of what this
check could not speak for is part of what the check reports, or a stack that
quietly lost a healthcheck would show as a cleaner run rather than a thinner
one.

Services behind a compose profile are skipped. `renderer`, `archiver`,
`gitleaks`, `actionlint` and `editorconfig-checker` are not part of a deploy —
`make up` neither starts nor pulls them — so their absence is correct rather
than a fault.

Usage: scripts/check_container_health.py [STACK]      (default: observability)
       scripts/check_container_health.py --no-wait    (snapshot, do not poll)
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

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

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
RESET = "\033[0m"

# Docker's own defaults, applied when a healthcheck omits the field. They are
# restated here because the deadline is computed from them and a wrong default
# would make the deadline wrong in the safe-looking direction — too long, so the
# check waits rather than fails. Source: the Compose spec and the Docker
# Engine API's HealthConfig.
DEFAULT_INTERVAL = 30.0
DEFAULT_TIMEOUT = 30.0
DEFAULT_RETRIES = 3
DEFAULT_START_PERIOD = 0.0

# How often to re-ask the daemon while a container is still `starting`. Short
# enough that `make up` is not padded by it, long enough not to spin.
POLL_SECONDS = 2.0

_DURATION = re.compile(r"(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)")
_UNITS = {
    "ns": 1e-9, "us": 1e-6, "µs": 1e-6, "ms": 1e-3,
    "s": 1.0, "m": 60.0, "h": 3600.0,
}


def parse_duration(value: object, default: float) -> float:
    """Parse a Go duration string as compose writes it ("30s", "1m30s").

    A plain number is nanoseconds, which is how the Compose spec says an
    integer in one of these fields is read. Getting that backwards would turn
    `interval: 30` into a 30-second wait rather than the 30 nanoseconds it
    actually means, so it is spelled out rather than assumed.
    """
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return float(value) * 1e-9
    text = str(value).strip()
    matches = _DURATION.findall(text)
    if not matches or "".join(n + u for n, u in matches) != text:
        raise ValueError(f"cannot parse duration {value!r}")
    return sum(float(n) * _UNITS[u] for n, u in matches)


def compose_healthchecks(
    stack: str,
) -> tuple[str, dict[str, float], list[str], list[str]]:
    """Split a stack's services into checked, unchecked and profile-only.

    Returns (compose project name, deadline per service, services declaring no
    healthcheck, services behind a profile).

    The project name is read from the file's `name:` rather than assumed to be
    the directory name. Both stacks set it and both currently agree, but the
    daemon is queried by that label — so a stack that set a different `name:`
    would make this script find no containers and say the stack is not up,
    which is the wrong answer given confidently. Falling back to the directory
    is what compose itself does when `name:` is absent.
    """
    path = REPO / "stacks" / stack / "compose.yaml"
    if not path.is_file():
        sys.exit(f"no compose.yaml for stack {stack!r} at {path}")
    compose = yaml.safe_load(path.read_text(encoding="utf-8"))
    project = compose.get("name") or stack

    deadlines: dict[str, float] = {}
    unchecked: list[str] = []
    profiled: list[str] = []
    for name, service in (compose.get("services") or {}).items():
        if service.get("profiles"):
            profiled.append(name)
            continue
        health = service.get("healthcheck") or {}
        # `disable: true` and `test: ["NONE"]` are the two ways compose says a
        # service deliberately has no healthcheck. Both mean the same thing here.
        if not health or health.get("disable") or health.get("test") == ["NONE"]:
            unchecked.append(name)
            continue
        deadlines[name] = (
            parse_duration(health.get("start_period"), DEFAULT_START_PERIOD)
            + int(health.get("retries", DEFAULT_RETRIES))
            * (
                parse_duration(health.get("interval"), DEFAULT_INTERVAL)
                + parse_duration(health.get("timeout"), DEFAULT_TIMEOUT)
            )
        )
    return project, deadlines, unchecked, profiled


def inspect(project: str) -> dict[str, dict]:
    """Ask the daemon about every container in this compose project.

    Keyed by compose service name, taken from the label rather than from the
    container name — `container_name:` is set here today, but a project that
    stopped setting it would otherwise silently inspect nothing and pass.
    """
    ids = subprocess.run(
        ["docker", "ps", "--all", "--quiet",
         "--filter", f"label=com.docker.compose.project={project}"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    if not ids:
        return {}
    raw = subprocess.run(
        ["docker", "inspect", *ids], capture_output=True, text=True, check=True,
    ).stdout
    found: dict[str, dict] = {}
    for container in json.loads(raw):
        service = container["Config"]["Labels"].get("com.docker.compose.service")
        if service:
            found[service] = container
    return found


def status_of(container: dict) -> tuple[str, str]:
    """(state, health) for one container; health is "none" when it reports none."""
    state = container["State"]
    health = state.get("Health") or {}
    return state.get("Status", "?"), health.get("Status", "none")


def last_probe_output(container: dict) -> str:
    log = ((container["State"].get("Health") or {}).get("Log") or [])
    if not log:
        return ""
    entry = log[-1]
    out = (entry.get("Output") or "").strip()
    code = entry.get("ExitCode")
    return f"exit {code}: {out}" if out else f"exit {code}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("stack", nargs="?", default="observability")
    ap.add_argument(
        "--no-wait", action="store_true",
        help="report the current status without polling; for asking about a "
             "stack that has been up for a while rather than one just deployed",
    )
    args = ap.parse_args()

    project, deadlines, unchecked, profiled = compose_healthchecks(args.stack)
    if not deadlines:
        print(f"{args.stack}: no service declares a healthcheck — nothing to assert")
        return 0

    try:
        containers = inspect(project)
    except FileNotFoundError:
        sys.exit(
            "docker is not on PATH — this is a deploy-time check and needs a daemon"
        )
    except subprocess.CalledProcessError as exc:
        sys.exit(f"docker inspect failed: {(exc.stderr or '').strip()}")

    if not containers:
        sys.exit(
            f"no containers for compose project {project!r} — the stack is not "
            f"up, so there is nothing to assert. Run `make up` first."
        )

    started = time.monotonic()
    pending = set(deadlines)
    results: dict[str, tuple[bool, str]] = {}

    while pending:
        elapsed = time.monotonic() - started
        for service in sorted(pending):
            container = containers.get(service)
            if container is None:
                results[service] = (
                    False,
                    "declared in compose, no container — it never started",
                )
                continue
            state, health = status_of(container)
            if state != "running":
                results[service] = (False, f"container is {state}, not running")
            elif health == "healthy":
                results[service] = (True, "healthy")
            elif health == "unhealthy":
                # The interesting one, and the reason this check exists. The
                # probe output is where a 404, a refused connection or a TLS
                # failure actually says which it was.
                detail = last_probe_output(container)
                results[service] = (
                    False, f"unhealthy — {detail}" if detail else "unhealthy"
                )
            elif health == "none":
                results[service] = (
                    False,
                    "running with no health status, but compose declares a "
                    "healthcheck — this container predates it and has not been "
                    "recreated since",
                )
            elif elapsed >= deadlines[service]:
                # In practice the `unhealthy` branch above is the one that
                # fires: Docker flips a failing container at roughly
                # start_period + retries x interval, which is always at or
                # before this deadline because of the timeout term. So this is
                # the case where the daemon has not reached a verdict at all —
                # a probe that hangs, a wedged daemon — and its job is to stop
                # this script waiting forever rather than to diagnose a 404.
                results[service] = (
                    False,
                    f"still starting after {deadlines[service]:.0f}s "
                    f"(start_period + retries x (interval + timeout)) — Docker "
                    f"has not reached a verdict, so the probe is not returning",
                )
            else:
                continue  # still legitimately starting
        pending -= set(results)
        if not pending:
            break
        if args.no_wait:
            for service in sorted(pending):
                results[service] = (False, "still starting (--no-wait, not waited for)")
            break
        time.sleep(POLL_SECONDS)
        containers = inspect(project)

    failures = {s: why for s, (good, why) in results.items() if not good}
    for service in sorted(results):
        good, why = results[service]
        mark = f"{GREEN}  PASS{RESET}" if good else f"{RED}  FAIL{RESET}"
        # Every per-service line goes to stdout, failures included. Splitting
        # them across two streams interleaved the report — the summary appeared
        # above the last PASS line — and a report whose order depends on the
        # buffering is not a report. Only the closing count goes to stderr.
        print(f"{mark} {service}: {why}")

    if unchecked:
        # Named rather than counted silently. A stack that lost a healthcheck
        # would otherwise show up as a cleaner run instead of a thinner one.
        print(
            f"{YELLOW}  NOTE{RESET} not covered — declares no healthcheck: "
            f"{', '.join(sorted(unchecked))}"
        )

    if failures:
        sys.stdout.flush()
        print(
            f"\n{len(failures)} of {len(results)} service(s) with a healthcheck "
            f"are not healthy in stack {args.stack!r}",
            file=sys.stderr,
        )
        return 1

    print(
        f"container health OK — {len(results)} of "
        f"{len(results) + len(unchecked)} service(s) in {args.stack!r} declare a "
        f"healthcheck and all of them pass "
        f"({len(unchecked)} declare none, {len(profiled)} behind a profile)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
