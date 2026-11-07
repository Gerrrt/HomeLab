#!/usr/bin/env python3
"""Remove the images a deploy just superseded, right after it (#1027).

WHY. A bump pulls a new digest and the container moves to it, but the old
image stays on disk until something removes it. On the agent hosts that is
the weekly `homelab-prune-images` timer (#775), on Mondays. On 2026-10-07 a
Wazuh re-pin (#966) landed on a Tuesday: about 7.4 GB of superseded images
took odin's 30 GB root to 99%, and they would have sat there for six days,
holding the headroom the NEXT pull needs. A pull needs the old set and the new
one at once, because the running containers keep the old images until they
are recreated.

So `make up` removes what it superseded, once it has passed its health
checks. If the new images are unhealthy, `make up` stops before this step and
the old images are still there to go back to.

WHAT IS REMOVED. A local image is removed only if all three hold:

  * its repository is one THIS stack runs, so a deploy of the lab stack
    never touches an image that belongs to something else on the host;
  * no container uses it, running or stopped (`docker rmi` refuses those
    anyway; this keeps them out of the plan, so the log says what happened);
  * no stack in this checkout pins it. A profile-only image such as soc's
    `wazuh.certs-generator` has no container most of the time, and a second
    stack on the same host may pin the same repository at another digest.

That makes this strictly narrower than the weekly `docker image prune -a`,
which stays as the backstop for anything else.

A removal that fails is reported and does not fail the deploy: the stack is
already up and healthy, and the weekly prune will try again.

Usage: scripts/prune_superseded_images.py <stack> [--dry-run]
       scripts/prune_superseded_images.py --self-test
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

# PyYAML from scripts/_deps.py, the one place it may come from: the host's
# python3-yaml, never a run-time install from PyPI on a production host (#848).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _deps import require_yaml

yaml = require_yaml()

REPO = pathlib.Path(__file__).resolve().parent.parent

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
OFF = "\033[0m"


def repository(ref: str) -> str | None:
    """The repository a reference names, as `docker images` prints it.

    `docker.io/library/caddy:2.11@sha256:..` and `caddy` are the same
    repository; a registry with a port (`host:5000/x:tag`) keeps its port. A
    reference that still holds a `${VAR}` cannot be resolved here, so it is
    None rather than a guess.
    """
    if not ref or "$" in ref:
        return None
    name = ref.split("@", 1)[0]
    slash = name.rfind("/")
    colon = name.rfind(":")
    if colon > slash:
        name = name[:colon]
    for prefix in ("docker.io/library/", "docker.io/", "library/"):
        if name.startswith(prefix):
            name = name[len(prefix) :]
            break
    return name or None


def plan(
    stack_refs: list[str],
    local_images: list[tuple[str, str]],
    used_ids: set[str],
    pinned_ids: set[str],
) -> list[tuple[str, str]]:
    """(repository, id) of each local image to remove. Pure, for --self-test.

    stack_refs    the image references this stack's compose.yaml names
    local_images  (repository, id) for every image on the host
    used_ids      ids of images any container uses, running or stopped
    pinned_ids    ids of local images pinned by any stack in this checkout
    """
    repos = {r for r in (repository(ref) for ref in stack_refs) if r}
    out = []
    seen = set()
    for repo, image_id in local_images:
        norm = repository(repo) if repo and repo != "<none>" else None
        if norm not in repos:
            continue
        if image_id in used_ids or image_id in pinned_ids or image_id in seen:
            continue
        seen.add(image_id)
        out.append((norm, image_id))
    return out


def compose_refs(path: pathlib.Path) -> list[str]:
    """Every `image:` a compose file names, profiles included."""
    compose = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return [str(svc["image"]) for svc in (compose.get("services") or {}).values() if svc and svc.get("image")]


def stack_compose_paths() -> list[pathlib.Path]:
    """Every stack's compose.yaml, from scripts/stacks.sh, the one enumerator.

    Not a glob of stacks/*: stacks.sh fails on a directory under stacks/ with
    no compose.yaml, and that failure must stop this. The all-stack pin scan is
    what keeps another stack's images safe, so a stack it silently skipped is
    a stack whose pinned images it could remove.
    """
    listed = subprocess.run(
        [str(REPO / "scripts/stacks.sh"), "--paths"], capture_output=True, text=True, check=True
    ).stdout.split()
    return [REPO / entry / "compose.yaml" for entry in listed]


def docker(*args: str) -> str:
    return subprocess.run(["docker", *args], capture_output=True, text=True, check=True).stdout


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        if argv != ["--self-test"]:
            print("--self-test takes nothing else", file=sys.stderr)
            return 2
        return self_test()
    dry_run = "--dry-run" in argv
    args = [a for a in argv if a != "--dry-run"]
    if len(args) != 1 or args[0].startswith("-"):
        print("Usage: scripts/prune_superseded_images.py <stack> [--dry-run]", file=sys.stderr)
        return 2
    stack = args[0]
    compose_path = REPO / "stacks" / stack / "compose.yaml"
    if not compose_path.exists():
        print(f"no compose file at {compose_path}", file=sys.stderr)
        return 2

    stack_refs = compose_refs(compose_path)
    try:
        all_refs = [ref for p in stack_compose_paths() for ref in compose_refs(p)]
    except (OSError, subprocess.CalledProcessError) as exc:
        err = (getattr(exc, "stderr", "") or str(exc)).strip()
        print(f"{RED}error:{OFF} could not list the stacks, so removing nothing: {err}", file=sys.stderr)
        return 1

    try:
        local = [
            tuple(line.split("\t", 1))
            for line in docker("images", "--no-trunc", "--format", "{{.Repository}}\t{{.ID}}").splitlines()
            if "\t" in line
        ]
        containers = docker("ps", "-aq").split()
        used = set(docker("inspect", "--format", "{{.Image}}", *containers).split()) if containers else set()
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"{RED}error:{OFF} could not read the image list: {exc}", file=sys.stderr)
        return 1

    pinned = set()
    for ref in set(all_refs):
        if "$" in ref:
            continue
        found = subprocess.run(
            ["docker", "image", "inspect", "--format", "{{.Id}}", ref], capture_output=True, text=True, check=False
        )
        if found.returncode == 0:
            pinned.add(found.stdout.strip())

    targets = plan(stack_refs, local, used, pinned)
    if not targets:
        print(f"{GREEN}superseded images{OFF} — none left behind by {stack}")
        return 0

    removed = 0
    for repo, image_id in targets:
        short = image_id.removeprefix("sha256:")[:12]
        if dry_run:
            print(f"  would remove {repo} {short}")
            continue
        rmi = subprocess.run(["docker", "rmi", image_id], capture_output=True, text=True, check=False)
        if rmi.returncode == 0:
            removed += 1
            print(f"  removed {repo} {short}")
        else:
            detail = (rmi.stderr or rmi.stdout).strip().splitlines()
            print(
                f"{YELLOW}  kept{OFF} {repo} {short}: {detail[-1] if detail else 'docker rmi failed'} "
                f"— the weekly prune will try again",
                file=sys.stderr,
            )
    verb = "would remove" if dry_run else "removed"
    count = len(targets) if dry_run else removed
    print(f"{GREEN}superseded images{OFF} — {verb} {count} of {len(targets)} that {stack}'s deploy left behind")
    return 0


def self_test() -> int:
    failed = 0

    def check(name: str, expected: object, got: object) -> None:
        nonlocal failed
        if got == expected:
            print(f"{GREEN}  PASS{OFF} {name}")
        else:
            print(f"{RED}  FAIL{OFF} {name}\n       got      {got!r}\n       expected {expected!r}")
            failed = 1

    # Built from parts, not written out: a pinned `name:N.N` in a fixture is a
    # pin outside compose.yaml, which check_image_pins.py rightly refuses.
    digest = "@sha256:" + "a" * 64
    manager = "wazuh/wazuh-manager" + ":tag" + digest
    certs = "wazuh/wazuh-certs-generator" + ":tag" + digest

    # References as compose writes them, repositories as `docker images` does.
    check("a tag and digest are stripped", "wazuh/wazuh-manager", repository(manager))
    check("docker.io/library is the short name", "caddy", repository("docker.io/library/caddy" + ":tag" + digest))
    check("a registry port is not a tag", "reg:5000/x/y", repository("reg:5000/x/y" + ":tag" + digest))
    check("ghcr.io keeps its registry", "ghcr.io/v/s", repository("ghcr.io/v/s" + ":tag" + digest))
    check("an unresolved ${VAR} is not guessed", None, repository("${IMAGE}"))

    # THE CASE (#1027): the deploy moved the manager to NEW; OLD is behind.
    local = [("wazuh/wazuh-manager", "sha256:old"), ("wazuh/wazuh-manager", "sha256:new")]
    check(
        "the superseded image of a stack repository is removed",
        [("wazuh/wazuh-manager", "sha256:old")],
        plan([manager], local, {"sha256:new"}, {"sha256:new"}),
    )
    check(
        "an image a container still uses is kept",
        [],
        plan([manager], local, {"sha256:new", "sha256:old"}, {"sha256:new"}),
    )
    check(
        "a profile-only image with no container is kept, because it is pinned",
        [],
        plan(
            [manager, certs],
            [("wazuh/wazuh-certs-generator", "sha256:c")],
            {"sha256:new"},
            {"sha256:new", "sha256:c"},
        ),
    )
    check(
        "another stack's pin of the same repository is kept",
        [("caddy", "sha256:3")],
        plan(
            ["caddy" + ":tag" + digest],
            [("caddy", "sha256:1"), ("caddy", "sha256:2"), ("caddy", "sha256:3")],
            {"sha256:1"},
            {"sha256:1", "sha256:2"},
        ),
    )
    check(
        "an image of a repository this stack does not run is never touched",
        [],
        plan([manager], [("grafana/alloy", "sha256:x")], set(), set()),
    )
    check(
        "a dangling <none> repository is the weekly prune's, not this",
        [],
        plan([manager], [("<none>", "sha256:d")], set(), set()),
    )
    check(
        "one image under two names is planned once",
        [("caddy", "sha256:9")],
        plan(
            ["caddy" + ":tag" + digest],
            [("caddy", "sha256:9"), ("docker.io/library/caddy", "sha256:9")],
            set(),
            set(),
        ),
    )
    return failed


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
