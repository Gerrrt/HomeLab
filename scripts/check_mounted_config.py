#!/usr/bin/env python3
"""Check that each container is running the config the repository says it is.

THE FAILURE THIS EXISTS FOR (#355). On 2026-09-06, `make converge` reported
success, `make up` reported success, `reload-config.sh` reported `reloaded
prometheus`, and `check_container_health.py` reported prometheus healthy.
Prometheus was running the previous config: the `blackbox-latency` job added by
#166 did not exist inside the container, and its three targets never appeared.

    grep -c blackbox-latency  .../prometheus.yaml            2
    docker exec prometheus grep -c ... /etc/prometheus/...   0

compose.yaml bind-mounts four config files INDIVIDUALLY, and a single-file bind
mount is pinned to the inode. `git merge` and `git checkout` write a temporary
file and rename it over the target, so the file gets a new inode and the
container keeps pointing at the old one. `/-/reload` then returns 200 having
faithfully re-read the pre-merge content.

`scripts/reload-config.sh` already knows this shape — it records that
render-config.sh truncates with `>` to keep the inode, and that
write-temp-then-mv "would leave the mount pointing at the old inode". That
covers the files this repository WRITES. It never covered the files git
REWRITES, which is every committed config.

WHY IT IS NOT RARE. `docker compose up -d` recreates a container only when its
service definition changes, so a config-only commit recreates nothing and the
stale mount survives the deploy. That is the normal case for most changes here.
It went unnoticed until #166 only because the deploys before it happened to
change compose.yaml as well (#187, #330, #186), which recreated everything.

WHY NOTHING ELSE CATCHES IT. Each existing check answers its own question
correctly: reload-config.sh asserts the reload was ACCEPTED, and it was;
check_container_health.py asserts the container is HEALTHY, and it was, serving
the old config perfectly; `make validate` asserts the REPOSITORY is coherent,
and it is. None of them asks whether what is running is what the repository
says.

CONTENT, NOT INODE. Comparing inodes would detect this particular mechanism and
is what #355 first proposed. Comparing the bytes is strictly better: it is the
question actually worth asking, it catches divergence from any cause, and it
works on containers with no shell. `loki` is exactly that — its image is
distroless and holds only /usr/bin/loki, so `docker exec ... stat` is impossible
and /proc/<pid>/root is permission-denied for the operator. `docker cp` needs
neither.

WHAT IT DOES NOT COVER, deliberately: files this repository renders rather than
commits. alertmanager/.rendered is a DIRECTORY mount, so a replaced file inside
it is visible to the container immediately, and its contents are secrets that
must not be read back out and compared here. check_alert_channels.py --live
covers that side from inside the container instead.

Usage: scripts/check_mounted_config.py [--fix] [STACK]
       --fix force-recreates the services whose config has gone stale.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import tempfile

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
BLUE = "\033[0;34m"
RESET = "\033[0m"


def single_file_mounts(stack: str) -> list[tuple[str, pathlib.Path | None, str]]:
    """(service, host path, container path) for every single-FILE bind mount.

    Directory mounts are excluded and do not need to be here: a file replaced
    inside a mounted directory is visible to the container at once, which is why
    prometheus/targets/ picked up blackbox-latency.yaml through the same merge
    that stranded prometheus.yaml.
    """
    stack_dir = REPO / "stacks" / stack
    compose = yaml.safe_load((stack_dir / "compose.yaml").read_text(encoding="utf-8"))
    found: list[tuple[str, pathlib.Path, str]] = []
    for service, spec in (compose.get("services") or {}).items():
        if spec.get("profiles"):
            continue
        for volume in spec.get("volumes", []) or []:
            if not isinstance(volume, str) or not volume.startswith((".", "/")):
                continue
            parts = volume.split(":")
            if len(parts) < 2:
                continue
            source, target = parts[0], parts[1]
            host = (stack_dir / source).resolve()
            if host.is_file():
                found.append((service, host, target))
            elif not host.exists() and not host.is_dir():
                # A declared mount whose source does not exist is not a skip.
                # Docker CREATES a directory at a missing bind-mount source, so
                # the container silently gets a directory where its config
                # should be — which is the #69 failure, and reporting nothing
                # here would be the same silence in a new place. Returned with
                # host=None so the caller can say so.
                found.append((service, None, target))
    return found


def container_copy(service: str, target: str) -> bytes | None:
    """What the container has at that path, or None if it cannot be read.

    `docker cp` rather than `docker exec cat`, because loki's image is
    distroless and has no shell at all.
    """
    with tempfile.NamedTemporaryFile() as tmp:
        result = subprocess.run(
            ["docker", "cp", f"{service}:{target}", tmp.name],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            return None
        return pathlib.Path(tmp.name).read_bytes()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("stack", nargs="?", default="observability")
    ap.add_argument(
        "--fix", action="store_true",
        help="force-recreate the services whose mounted config has gone stale",
    )
    args = ap.parse_args()

    mounts = single_file_mounts(args.stack)
    if not mounts:
        print(f"{args.stack}: no single-file bind mounts — nothing can go stale this way")
        return 0

    running = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True,
    )
    if running.returncode != 0:
        sys.exit("docker is not available — this is a deploy-time check")
    alive = set(running.stdout.split())

    stale: list[str] = []
    checked = 0
    for service, host, target in mounts:
        if service not in alive:
            print(f"{YELLOW}  SKIP{RESET} {service} is not running")
            continue
        if host is None:
            # Certificates are gitignored, so from a worktree this is expected
            # and says only that the check must be run where the stack runs.
            # From the deployment checkout it means a mount source has gone
            # missing, which Docker papers over with an empty directory.
            print(
                f"{YELLOW}  SKIP{RESET} {service}: no host file for {target} — "
                f"gitignored, or missing from this checkout"
            )
            continue
        inside = container_copy(service, target)
        if inside is None:
            print(f"{RED}  FAIL{RESET} {service}: cannot read {target} from the container")
            stale.append(service)
            continue
        checked += 1
        if inside == host.read_bytes():
            print(f"{GREEN}  PASS{RESET} {service}: {host.name} matches what is mounted")
        else:
            print(
                f"{RED}  FAIL{RESET} {service}: {host.name} on disk differs from what "
                f"the container has at {target}"
            )
            stale.append(service)

    if not stale:
        print(
            f"\nmounted config OK — {checked} single-file mount(s) in "
            f"{args.stack!r} match the repository"
        )
        return 0

    if not args.fix:
        sys.stdout.flush()
        print(
            f"\n{len(stale)} container(s) running a config the repository does not "
            f"have: {', '.join(sorted(set(stale)))}\n"
            f"A single-file bind mount is pinned to the inode, and git replaces it. "
            f"The reload returned 200 on the old bytes. Fix with:\n"
            f"  docker compose -f stacks/{args.stack}/compose.yaml up -d "
            f"--force-recreate {' '.join(sorted(set(stale)))}",
            file=sys.stderr,
        )
        return 1

    # --fix, which is what `make up` uses. Recreating is the only thing that
    # rebinds the mount — a reload cannot, because the reload is not what is
    # broken.
    print(f"\n{BLUE}--{RESET} recreating: {', '.join(sorted(set(stale)))}")
    result = subprocess.run(
        ["docker", "compose", "-f", str(REPO / "stacks" / args.stack / "compose.yaml"),
         "up", "-d", "--force-recreate", *sorted(set(stale))],
        capture_output=False,
    )
    if result.returncode != 0:
        print("\nrecreate failed", file=sys.stderr)
        return 1

    # And then assert it worked, rather than assuming. A recreate that silently
    # rebound nothing would otherwise leave this reporting success for the exact
    # failure it exists to catch.
    still: list[str] = []
    for service, host, target in mounts:
        if host is None or service not in set(stale):
            continue
        inside = container_copy(service, target)
        if inside != host.read_bytes():
            still.append(service)
    if still:
        print(
            f"\nstill stale after recreate: {', '.join(still)}", file=sys.stderr
        )
        return 1
    print(f"{GREEN}  PASS{RESET} recreated, and the config now matches")
    return 0


if __name__ == "__main__":
    sys.exit(main())
