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
works on containers with no shell.

READ THROUGH THE CONTAINER'S MOUNT NAMESPACE, NOT `docker cp`. This used
`docker cp`, and that made the check unable to fail. For a path that is a bind
mount, the daemon resolves it to the mount's SOURCE on the host and opens it
afresh, so it reads the file git just wrote, not the inode the container is
pinned to. The check then compared the new file with itself. Measured on
2026-10-01 with a file replaced by rename under a running container: `docker
exec cat` said `old`, `docker cp` said `new`. It was found on 2026-09-30, when
this reported blackbox.yaml as matching while the blackbox exporter ran without
the module #182 had just added.

What reads the pinned inode is the container's own view: /proc/1/root/<path>,
opened from a helper that shares its PID namespace. It is not `docker exec cat`,
because `loki` is distroless and holds only /usr/bin/loki. The helper needs
CAP_SYS_PTRACE: the kernel allows /proc/<pid>/root only to the same uid or to
that capability, and the services run as their own uids. That is one capability
on a throwaway container with no network, which reads a file and exits, plus
DAC_READ_SEARCH, because root with every capability dropped cannot read a 0640
file it does not own, and Grafana's TLS key is one (`docker cp` read as the
daemon, so it never met this). DAC_READ_SEARCH lets it read, never write. The
helper is the pinned Alloy image, found through scripts/image-for.sh, because it
has `cat` and is already on every host that runs a stack.

WHAT IT DOES NOT COVER, deliberately: files this repository renders rather than
commits. alertmanager/.rendered is a DIRECTORY mount, so a replaced file inside
it is visible to the container immediately, and its contents are secrets that
must not be read back out and compared here. check_alert_channels.py --live
covers that side from inside the container instead.

Usage: scripts/check_mounted_config.py [--fix] [STACK]
       --fix force-recreates the services whose config has gone stale.
       scripts/check_mounted_config.py --self-test
       --self-test proves the reader sees a stale mount as stale, on a
       throwaway container: the case `docker cp` passed for a year.
"""

from __future__ import annotations

import argparse
import functools
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ModuleNotFoundError:
    print("installing PyYAML", file=sys.stderr)
    if subprocess.run(
        [sys.executable, "-m", "pip", "install", "--quiet", "--disable-pip-version-check", "pyyaml"],
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


def single_file_mounts(stack: str) -> list[tuple[str, str, pathlib.Path | None, str]]:
    """(service, container name, host path, container path) per single-FILE bind mount.

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
            container = spec.get("container_name") or service
            if host.is_file():
                found.append((service, container, host, target))
            elif not host.exists() and not host.is_dir():
                # A declared mount whose source does not exist is not a skip.
                # Docker CREATES a directory at a missing bind-mount source, so
                # the container silently gets a directory where its config
                # should be — which is the #69 failure, and reporting nothing
                # here would be the same silence in a new place. Returned with
                # host=None so the caller can say so.
                found.append((service, container, None, target))
    return found


@functools.cache
def helper_image() -> str:
    """The pinned image the reader runs, from compose.yaml via image-for.sh.

    Never a literal: check_compose_health.py's rule holds here too, and nothing
    in this file names an image itself.
    """
    result = subprocess.run(
        [str(REPO / "scripts" / "image-for.sh"), "alloy"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        sys.exit(f"could not resolve the helper image: {result.stderr.strip()}")
    return result.stdout.strip()


def container_copy(container: str, target: str) -> bytes | None:
    """What the container's processes see at that path, or None if unreadable.

    Through /proc/1/root in the container's PID namespace, which resolves the
    path in ITS mount namespace and so reads the inode the bind mount is pinned
    to. `docker cp` does not: see READ THROUGH THE CONTAINER'S MOUNT NAMESPACE
    in the module docstring.
    """
    result = subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--pid",
            f"container:{container}",
            "--cap-drop",
            "ALL",
            "--cap-add",
            "SYS_PTRACE",
            "--cap-add",
            "DAC_READ_SEARCH",
            "--network",
            "none",
            "--label",
            "homelab.logs=off",
            "--entrypoint",
            "cat",
            helper_image(),
            f"/proc/1/root{target}",
        ],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def self_test() -> int:
    """The failure this file exists for, reproduced, against container_copy.

    A throwaway container gets a single-file bind mount. The file is then
    replaced the way git replaces it: written to a temporary name and renamed
    over the original. The container's processes still see the old bytes, so
    container_copy must return them, and a check comparing that with the host
    must fail. Then the file is rewritten IN PLACE, keeping its inode, which a
    container does see, so container_copy must return the new bytes.

    The first case is the one `docker cp` passed: it returned the new bytes,
    so a check built on it could never fail. The container runs as a non-root
    uid with every capability dropped, as loki does, so the reader's
    capabilities are tested against the hardest target the stacks have.
    """
    if subprocess.run(["docker", "info"], capture_output=True, check=False).returncode != 0:
        print(f"{YELLOW}  SKIP{RESET} --self-test needs a docker daemon")
        return 0

    failures = 0

    def check(name: str, ok: bool) -> None:
        nonlocal failures
        print(f"{GREEN if ok else RED}  {'PASS' if ok else 'FAIL'}{RESET} {name}")
        failures += not ok

    work = pathlib.Path(tempfile.mkdtemp(prefix="mounted-config-selftest."))
    container = f"mounted-config-selftest-{os.getpid()}"
    config = work / "config.yml"
    config.write_bytes(b"old\n")
    try:
        started = subprocess.run(
            [
                "docker",
                "run",
                "-d",
                "--rm",
                "--name",
                container,
                "--user",
                "10001:10001",
                "--cap-drop",
                "ALL",
                "--read-only",
                "--security-opt",
                "no-new-privileges:true",
                "--network",
                "none",
                "--label",
                "homelab.logs=off",
                "-v",
                f"{config}:/etc/selftest/config.yml:ro",
                "--entrypoint",
                "sleep",
                helper_image(),
                "300",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if started.returncode != 0:
            print(f"{RED}  FAIL{RESET} could not start the fixture container: {started.stderr.strip()}")
            return 1

        check(
            "reads the mounted file before any change",
            container_copy(container, "/etc/selftest/config.yml") == b"old\n",
        )

        replacement = work / "config.yml.tmp"
        replacement.write_bytes(b"new\n")
        replacement.replace(config)  # rename over the target, as git does
        inside = container_copy(container, "/etc/selftest/config.yml")
        check("after a rename, reads the old inode the container is pinned to", inside == b"old\n")
        check(
            "after a rename, so the comparison with the host FAILS",
            inside is not None and inside != config.read_bytes(),
        )

        with config.open("r+b") as f:  # same inode, as render-config.sh writes
            f.truncate(0)
            f.write(b"in place\n")
        # The container's inode is still the pre-rename one, so an in-place
        # write to the NEW file must not show through. That is the point.
        check(
            "an in-place write to the new file does not reach the old inode",
            container_copy(container, "/etc/selftest/config.yml") == b"old\n",
        )
    finally:
        subprocess.run(["docker", "rm", "-f", container], capture_output=True, check=False)
        shutil.rmtree(work, ignore_errors=True)

    # And the in-place case the right way round: a fresh container on a file
    # that is then rewritten in place sees the change, so a stack whose files
    # are written that way is not reported stale for nothing.
    work = pathlib.Path(tempfile.mkdtemp(prefix="mounted-config-selftest."))
    config = work / "config.yml"
    config.write_bytes(b"before\n")
    try:
        subprocess.run(
            [
                "docker",
                "run",
                "-d",
                "--rm",
                "--name",
                container,
                "--user",
                "10001:10001",
                "--cap-drop",
                "ALL",
                "--read-only",
                "--network",
                "none",
                "--label",
                "homelab.logs=off",
                "-v",
                f"{config}:/etc/selftest/config.yml:ro",
                "--entrypoint",
                "sleep",
                helper_image(),
                "300",
            ],
            capture_output=True,
            check=True,
        )
        with config.open("r+b") as f:
            f.truncate(0)
            f.write(b"after\n")
        inside = container_copy(container, "/etc/selftest/config.yml")
        check(
            "an in-place write to the mounted inode is seen, and matches", inside == b"after\n" == config.read_bytes()
        )
    finally:
        subprocess.run(["docker", "rm", "-f", container], capture_output=True, check=False)
        shutil.rmtree(work, ignore_errors=True)

    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("stack", nargs="?", default="observability")
    ap.add_argument(
        "--fix",
        action="store_true",
        help="force-recreate the services whose mounted config has gone stale",
    )
    # One line, on purpose: scripts/self-tests.sh discovers suites by grepping
    # for `add_argument("--self-test"`, and a call split across lines is not
    # found and silently never runs.
    ap.add_argument("--self-test", action="store_true", help="prove the reader sees a stale mount as stale")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    mounts = single_file_mounts(args.stack)
    if not mounts:
        print(f"{args.stack}: no single-file bind mounts — nothing can go stale this way")
        return 0

    running = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if running.returncode != 0:
        sys.exit("docker is not available — this is a deploy-time check")
    alive = set(running.stdout.split())

    stale: list[str] = []
    checked = 0
    # `docker ps` prints container names, and a stack that sets `container_name`
    # (stacks/lab prefixes every service with `lab-`) names its containers
    # differently from its services. Matching the service name against that
    # list skipped every lab container as "not running" from the day the
    # stack landed, and reported "0 mount(s) match" as OK — the #355 guard
    # was never guarding the lab. The service name is still what compose
    # wants for --force-recreate below.
    for service, container, host, target in mounts:
        if container not in alive:
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
        try:
            host_bytes = host.read_bytes()
        except PermissionError:
            # The Wazuh cert generator chowns each leaf to the uid of the
            # container that reads it (999 for the manager's, 1000 for the
            # others) at mode 0400, so the deploy user cannot read some of
            # them from the host. They are generated once and never edited,
            # so the edit-then-reload drift this guard catches cannot reach
            # them; skip rather than crash.
            print(
                f"{YELLOW}  SKIP{RESET} {service}: {host.name} is not readable here "
                f"(generated cert, owned by the container's uid)"
            )
            continue
        inside = container_copy(container, target)
        if inside is None:
            print(f"{RED}  FAIL{RESET} {service}: cannot read {target} from the container")
            stale.append(service)
            continue
        checked += 1
        if inside == host_bytes:
            print(f"{GREEN}  PASS{RESET} {service}: {host.name} matches what is mounted")
        else:
            print(f"{RED}  FAIL{RESET} {service}: {host.name} on disk differs from what the container has at {target}")
            stale.append(service)

    if not stale:
        print(f"\nmounted config OK — {checked} single-file mount(s) in {args.stack!r} match the repository")
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
        [
            "docker",
            "compose",
            "-f",
            str(REPO / "stacks" / args.stack / "compose.yaml"),
            "up",
            "-d",
            "--force-recreate",
            *sorted(set(stale)),
        ],
        capture_output=False,
        check=False,
    )
    if result.returncode != 0:
        print("\nrecreate failed", file=sys.stderr)
        return 1

    # And then assert it worked, rather than assuming. A recreate that silently
    # rebound nothing would otherwise leave this reporting success for the exact
    # failure it exists to catch.
    still: list[str] = []
    for service, container, host, target in mounts:
        if host is None or service not in set(stale):
            continue
        inside = container_copy(container, target)
        if inside != host.read_bytes():
            still.append(service)
    if still:
        print(f"\nstill stale after recreate: {', '.join(still)}", file=sys.stderr)
        return 1
    print(f"{GREEN}  PASS{RESET} recreated, and the config now matches")
    return 0


if __name__ == "__main__":
    sys.exit(main())
