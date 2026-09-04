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

Two layers, because they need different things:

  * The static layer needs python3 and nothing else. It flags a service_healthy
    dependency on a service with no healthcheck, a malformed `test:`, and a
    healthcheck on an image whose *reference* names a distroless base.
  * --probe needs a docker daemon. It execs each healthcheck's binary inside
    that service's pinned image and fails if the runtime cannot find it. That
    is the actual invariant. It replaces a hand-maintained list of known
    no-userland images, which could only ever be right about the images
    somebody had thought to check (#79).

One more thing rides on these healthchecks, so it is checked here too.
scripts/reload-config.sh classifies a failed reload by asking the service
whether it is listening — `wget --spider -q http://localhost:<port>/-/healthy`,
which is the same probe each of those services already declares here. That made
the endpoint and the ports in that script's SERVICES array a copy of what is in
this file, with nothing holding the two together, so the last section of main()
reads the array back out and requires each entry to match the healthcheck it is
standing on (#80).

That cross-check changed shape when a second stack arrived (#263, #264).
SERVICES is the union across every stack, and reload-config.sh now skips
entries the stack it is reloading does not declare — so "not defined in this
compose file" stopped being a defect on its own. It is split in two instead,
and the pair is strictly stronger than the single check it replaces:

  * per file, an entry that stack DOES declare must carry the healthcheck the
    probe stands on — unchanged, and now applied to every stack rather than
    only to the estate's;
  * across the complete set of stacks, every entry must be declared SOMEWHERE.
    That is what still catches an array naming a service nothing has, which is
    the case the old "not defined" message existed for.

The completeness half is only claimed when this script discovered the stacks
itself, which it does when given no paths. Explicit paths mean the caller chose
the scope, and no claim about the whole repository can follow from a subset.

Usage: scripts/check_compose_health.py [--probe] [compose.yaml]
       scripts/check_compose_health.py --cross-stack
"""
from __future__ import annotations

import itertools
import os
import pathlib
import re
import subprocess
import sys
import time

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

# Docker runs a CMD-SHELL test, and a string-form test, as `/bin/sh -c <string>`.
# So for both of those the binary that has to exist is the shell, not whatever
# the string happens to name first.
SHELL = "/bin/sh"

# The reference-level heuristic. It is not the authority any more — --probe is,
# and it execs the binary — but it costs nothing, needs no docker daemon, and is
# the only distroless check a `make validate` on a docker-less host gets.
#
# It was never sufficient alone: the image that caused this script to exist was
# `grafana/loki`, which matches none of these markers. That gap used to be
# papered over by a hand-maintained list of image names, which was right only
# about the images somebody had thought to check (#79). The probe closes it.
DISTROLESS_MARKERS = ("distroless", "/static", "scratch")

# The successor to that list, and the reason deleting it loses nothing. It
# asserted "grafana/loki has no userland" on trust; this asserts the same thing
# by exec'ing into the pinned image under --probe.
#
# Not an exemption list and not a heuristic: every entry is a claim compose.yaml
# makes in prose to justify a service having NO healthcheck ("No healthcheck on
# loki, deliberately"). Probing it is what stops the prose going stale. If one
# of these ever turns up present, the fix is to delete the entry and give the
# service the healthcheck it can now support.
ABSENT_BINARIES = {"loki": (SHELL, "wget")}

# Bounds a probe that blocks rather than exits. --network none already makes a
# network binary fail instantly; this covers everything else. Same env-override
# shape as BOOT_SECONDS in scripts/check_loki_rules.sh.
PROBE_TIMEOUT = int(os.environ.get("PROBE_TIMEOUT", "60"))

# `docker run` reserves 125/126/127 for its own failures, so they are
# distinguishable from the exit status of a binary that ran. The wording of the
# runtime's message drifts between runc versions; these are the shapes seen:
#   exec: "wget": executable file not found in $PATH
#   exec: "/bin/sh": stat /bin/sh: no such file or directory
NOT_FOUND = re.compile(
    r"executable file not found|no such file or directory|exec format error",
    re.I,
)
PROBE_COUNTER = itertools.count()
NUMERIC_USER = re.compile(r"\d+(:\d+)?")

# scripts/reload-config.sh reloads these services by name and port, and decides
# whether a failed reload was a refusal or a not-listening-yet by probing
# http://localhost:<port>/-/healthy. That URL is hardcoded there rather than
# carried alongside each entry, because it would be the same string four times
# and a list with four chances to disagree is worse than a constant with none —
# but it leaves the port, and the endpoint, duplicated across two files.
#
# So read the array back and check it, in the spirit of the rest of this script:
# a claim one file makes about another is asserted, not trusted. Scraping a bash
# array with a regex is what check_docs.py already does to keep prose honest
# (#73). It catches a port changing here and not there, a service being added to
# the reload list without a healthcheck to probe, and /-/healthy moving.
RELOAD_SCRIPT = REPO / "scripts/reload-config.sh"
RELOAD_SERVICES = re.compile(r"^SERVICES=\((.*?)^\)", re.M | re.S)
RELOAD_ENTRY = re.compile(r"^\s*([A-Za-z0-9_.-]+):(\d+)\s*$")
RELOAD_PROBE_PATH = "/-/healthy"


def note(message: str) -> None:
    """Progress, to stderr. A probe pass is slow enough to look hung."""
    print(f"\033[0;34m--\033[0m {message}", file=sys.stderr)


def looks_distroless(image: str) -> bool:
    """True if the image *reference* advertises a base with no userland.

    A deliberately weak guess — see DISTROLESS_MARKERS. --probe is what knows.
    """
    return any(marker in image.lower() for marker in DISTROLESS_MARKERS)


def healthcheck_binary(test: object) -> tuple[str | None, str | None]:
    """(binary that must exist, reason it cannot be determined).

    (None, None) means there is nothing to check.
    """
    if isinstance(test, str):
        return SHELL, None
    if not isinstance(test, list) or not test:
        return None, "healthcheck test is neither a string nor a non-empty list"
    if test[0] == "NONE":
        return None, None
    if test[0] == "CMD-SHELL":
        return SHELL, None
    if test[0] == "CMD":
        if len(test) > 1:
            return str(test[1]), None
        return None, "healthcheck test is [\"CMD\"] with no command after it"
    # The compose spec requires the first element to be NONE, CMD or CMD-SHELL.
    # A bare list is not a shorthand — it is a typo that `docker compose config`
    # accepts, and it walked straight past the previous version of this check.
    return None, (
        f"healthcheck test is a list starting {test[0]!r}; it must start with "
        f"CMD, CMD-SHELL or NONE, so docker cannot run it as written"
    )


def reload_entries() -> tuple[list[tuple[str, str]], list[str]]:
    """The SERVICES array from reload-config.sh, as (name, port) pairs.

    Split out of reload_probe_problems() so the completeness check across
    stacks and the per-stack healthcheck check read the identical parse. Two
    readers of one hand-rolled scraper is how they come to disagree about what
    the array says.
    """
    if not RELOAD_SCRIPT.exists():
        return [], [f"{RELOAD_SCRIPT.name} is missing; nothing reloads these services"]

    source = RELOAD_SCRIPT.read_text(encoding="utf-8")
    block = RELOAD_SERVICES.search(source)
    if not block:
        return [], [
            f"could not find the SERVICES=( ... ) array in {RELOAD_SCRIPT.name} — "
            f"it was reshaped, and this check has been reading nothing ever since"
        ]

    problems: list[str] = []
    entries: list[tuple[str, str]] = []
    for line in block.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        entry = RELOAD_ENTRY.match(line)
        if not entry:
            problems.append(
                f"{RELOAD_SCRIPT.name} SERVICES contains {line.strip()!r}, which is "
                f"not the service:port this check knows how to verify"
            )
            continue
        entries.append((entry.group(1), entry.group(2)))

    if not entries and not problems:
        problems.append(f"{RELOAD_SCRIPT.name} SERVICES is empty")
    return entries, problems


def reload_probe_problems(services: dict, compose_name: str) -> list[str]:
    """Where reload-config.sh's SERVICES array disagrees with the healthchecks.

    Scoped to the entries THIS compose file declares. An entry it does not
    declare is not a defect here: SERVICES is the union across stacks, and
    reload-config.sh skips what a stack does not define, so `stacks/lab` having
    no alertmanager is the arrangement rather than a fault. That an entry
    exists in no stack at all is still caught — by the completeness check in
    main(), which is the only place that knows it is looking at every stack.
    """
    entries, problems = reload_entries()
    if not entries:
        return problems

    for name, port in entries:
        svc = services.get(name)
        if svc is None:
            continue

        expected = f"http://localhost:{port}{RELOAD_PROBE_PATH}"
        check = (svc or {}).get("healthcheck")
        if not isinstance(check, dict) or check.get("disable"):
            problems.append(
                f"{RELOAD_SCRIPT.name} probes {expected} to tell a refused reload "
                f"from a service that is not listening yet, but {name} declares no "
                f"healthcheck here — so nothing proves that URL answers, and a "
                f"refused reload would be reported as a timeout instead"
            )
            continue

        test = check.get("test")
        urls = [
            str(part)
            for part in (test if isinstance(test, list) else [test])
            if isinstance(part, str) and part.startswith(("http://", "https://"))
        ]
        if expected not in urls:
            problems.append(
                f"{RELOAD_SCRIPT.name} probes {expected} for {name}, but its "
                f"healthcheck in {compose_name} uses {urls or ['no URL at all']} — "
                f"the port or the endpoint has drifted between the two files, and "
                f"the reload would misreport a bad config as a timeout"
            )

    return problems


def docker_unavailable() -> str | None:
    """An error message if --probe cannot run, None if it can."""
    try:
        proc = subprocess.run(
            ["docker", "info"], capture_output=True, check=False
        )
    except (FileNotFoundError, OSError):
        proc = None
    if proc is not None and proc.returncode == 0:
        return None
    return (
        "--probe needs a working docker daemon, and `docker info` failed. "
        "Drop --probe to run the static checks alone — they need python3 only, "
        "but they cannot tell you what is inside an image."
    )


def ensure_image(image: str) -> str | None:
    """Pull the image if it is not local. An error line, or None on success.

    Pulled in its own pass so a registry failure is reported as a registry
    failure. The probe itself then runs with --pull never, which makes every
    non-zero exit attributable to the binary rather than to the network.
    """
    if not subprocess.run(
        ["docker", "image", "inspect", image], capture_output=True, check=False
    ).returncode:
        return None
    note(f"pulling {image}")
    proc = subprocess.run(
        ["docker", "pull", "--quiet", image],
        capture_output=True, text=True, check=False,
    )
    if not proc.returncode:
        return None
    detail = (proc.stderr or proc.stdout or "").strip().splitlines()
    return detail[-1] if detail else f"docker pull exited {proc.returncode}"


def probe_binary(
    image: str, binary: str, user: str | None
) -> tuple[str, str]:
    """Exec `binary` inside `image`. Returns (verdict, detail).

    Verdicts: present, absent, unusable, undecidable, error.

    --entrypoint with no arguments after the image clears the image's CMD, so
    the bare binary runs. What it then does is irrelevant — busybox wget with no
    arguments prints usage and exits 1, and that is a pass. The only question is
    whether the runtime could exec it at all, which is exactly the question a
    Docker healthcheck asks.

    On the image operand: check_image_pins.py scans the Makefile, *.sh, the
    workflows and the runbooks, not *.py, so these `docker run`s are outside it.
    That is correct rather than a gap — the reference here comes straight off
    the service being validated in compose.yaml, which is a stronger guarantee
    than tracing a literal back through scripts/image-for.sh. The rule it
    enforces still binds: nothing in this file may ever name an image itself,
    not even a fallback like busybox.
    """
    name = f"compose-health-probe-{os.getpid()}-{next(PROBE_COUNTER)}"
    command = [
        "docker", "run", "--rm",
        # No network, so a probe binary that would dial something fails at once
        # instead of blocking on a connect — and so this can never touch the
        # network under test.
        "--network", "none",
        "--pull", "never",
        "--name", name,
    ]
    # Run as the uid the healthcheck would, when compose names one literally, so
    # "present but not executable by that user" is caught too. The ${RENDER_UID}
    # services are read unresolved by safe_load and get the image default.
    if user:
        command += ["--user", user]
    command += ["--entrypoint", binary, image]
    try:
        proc = subprocess.run(
            command, capture_output=True, text=True,
            stdin=subprocess.DEVNULL, timeout=PROBE_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        subprocess.run(["docker", "rm", "-f", name],
                       capture_output=True, check=False)
        # It got far enough to block, so it exists.
        return "present", f"still running after {PROBE_TIMEOUT}s"

    stderr = (proc.stderr or "").strip()
    # The first line, not the last: docker follows its own diagnostic with a
    # blank line and "Run 'docker run --help' for more information", which is
    # the least useful thing it said.
    lines = [line for line in stderr.splitlines() if line.strip()]
    first = lines[0] if lines else ""
    if proc.returncode == 125:
        # docker itself failed — a bad flag, or the image missing under
        # --pull never. Not a statement about the binary.
        return "error", first or "docker run exited 125"
    if proc.returncode == 126:
        return "unusable", first or "docker run exited 126"
    if proc.returncode == 127:
        if NOT_FOUND.search(stderr):
            return "absent", first
        # 127 can also be the binary's own exit status. Refusing to guess is
        # the point: an unverified probe must not read as a verified one.
        return "undecidable", first or "exited 127 with no message"
    return "present", ""


def bind_source_problems(compose_path: pathlib.Path, services: dict) -> list[str]:
    """A file-shaped bind source that is really a directory.

    Docker creates a bind mount's source when it does not exist, and it always
    creates a *directory*, owned by root. So a mistyped path in `volumes:`
    produces no error at all: `make up` silently makes the directory, mounts an
    empty one where a config file should be, and the service starts and reads
    nothing. That is how `loki/config.yaml` came to be an empty root-owned
    directory that survived from 2026-08-29 until #213 — nothing referenced it,
    and being empty, git could not track it either.

    It is the same silent-empty shape `docs/observability.md` warns about for
    the ruler's `<directory>/<tenant>/` path, and it deserves the same
    treatment: something has to look, because nothing fails.

    The test is "names a file, exists as a directory", which is precise enough
    to need no allowlist. Absence is deliberately NOT a problem — `.rendered/`
    and the certificates are generated before `make up` and are legitimately
    missing in a fresh clone, so requiring existence would fail a clean checkout
    for no reason. Only a directory sitting where a file belongs is reported,
    and removing one needs root, so this reports rather than repairs.
    """
    problems = []
    for name, svc in services.items():
        for volume in ((svc or {}).get("volumes") or []):
            if not isinstance(volume, str):
                continue
            source = volume.split(":")[0]
            if not source.startswith("."):
                continue
            if not pathlib.PurePath(source).suffix:
                continue
            resolved = (compose_path.parent / source).resolve()
            if resolved.is_dir():
                problems.append(
                    f"{name} mounts {source}, which names a file but is a "
                    f"directory on disk — docker creates a directory when a "
                    f"bind source is missing, so this is a mount of nothing "
                    f"(remove it: rmdir {resolved})"
                )
    return problems


def cross_stack_problems() -> list[str]:
    """Names this file asserts about, checked against every stack at once.

    Both per-file checks had to stop treating "not in this compose file" as a
    defect when a second stack arrived: reload-config.sh skips services a stack
    does not declare, and a stack need not run everything ABSENT_BINARIES
    describes. What must still be true is that each name exists SOMEWHERE — an
    entry naming a service no stack has is a scraper that has silently stopped
    matching, which is the failure this whole file was written for (#80).

    Only answerable with the complete set of stacks, which is why it is its own
    mode rather than something the per-file path could do.
    """
    try:
        listed = subprocess.run(
            [str(REPO / "scripts/stacks.sh"), "--paths"],
            capture_output=True, text=True, check=True,
        ).stdout.split()
    except (OSError, subprocess.CalledProcessError) as exc:
        err = (getattr(exc, "stderr", "") or str(exc)).strip()
        return [f"could not list stacks: {err}"]

    declared: set[str] = set()
    for entry in listed:
        compose_path = REPO / entry / "compose.yaml"
        compose = yaml.safe_load(compose_path.read_text(encoding="utf-8"))
        declared |= set(compose.get("services") or {})

    problems: list[str] = []
    entries, problems_from_parse = reload_entries()
    problems += problems_from_parse
    for name, _port in entries:
        if name not in declared:
            problems.append(
                f"{RELOAD_SCRIPT.name} reloads {name}, which no stack defines — "
                f"it was renamed or removed, and nothing has reloaded it since"
            )
    for name in ABSENT_BINARIES:
        if name not in declared:
            problems.append(
                f"ABSENT_BINARIES names {name}, which no stack defines — the "
                f"claim it stands for has gone with the service"
            )
    return problems


def main() -> int:
    argv = sys.argv[1:]
    probe = "--probe" in argv
    argv = [arg for arg in argv if arg != "--probe"]

    if "--cross-stack" in argv:
        argv = [arg for arg in argv if arg != "--cross-stack"]
        if argv:
            print("--cross-stack takes no compose file", file=sys.stderr)
            return 1
        problems = cross_stack_problems()
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        if problems:
            return 1
        print("cross-stack OK — every reloaded and claimed service exists in some stack")
        return 0
    if argv and argv[0].startswith("-"):
        print(f"unknown option {argv[0]}", file=sys.stderr)
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 1

    path = pathlib.Path(argv[0]) if argv else DEFAULT
    if not path.exists():
        print(f"no compose file at {path}", file=sys.stderr)
        return 1

    compose = yaml.safe_load(path.read_text(encoding="utf-8"))
    services = compose.get("services") or {}
    problems: list[str] = []

    problems += bind_source_problems(path, services)

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

    # The reload script's copy of these ports, checked against the originals.
    # Runs for EVERY stack now, not just the default one: it is scoped to the
    # entries this file declares, so it is meaningful against any of them. The
    # matching "no stack declares this entry at all" half is --reload-completeness
    # below, which is the only mode that looks at every stack at once.
    problems += reload_probe_problems(services, path.name)

    # Every healthcheck the compose file declares, decoded to the one binary the
    # image has to contain for it to run at all. Profiles are deliberately not
    # filtered (unlike check_docs.py's compose_services): the set to check is
    # defined by declaring a healthcheck, not by being started.
    targets: list[tuple[str, str, str, str | None]] = []
    for name, svc in services.items():
        svc = svc or {}
        check = svc.get("healthcheck")
        if not isinstance(check, dict) or check.get("disable"):
            continue

        binary, reason = healthcheck_binary(check.get("test"))
        if reason:
            problems.append(
                f"{name}: {reason} — a healthcheck docker cannot run leaves "
                f"{name} 'starting' forever"
            )
            continue
        if binary is None:
            continue

        image = str(svc.get("image", ""))
        if not image:
            problems.append(
                f"{name} declares a healthcheck but no image: — there is "
                f"nothing to run {binary!r} inside, and an image must come from "
                f"this file (see scripts/check_image_pins.py)"
            )
            continue
        if looks_distroless(image):
            problems.append(
                f"{name} has a healthcheck exec'ing {binary!r}, but {image} "
                f"names a base with no shell and no userland — the probe can "
                f"never run, so {name} stays 'starting' forever"
            )
            continue

        user = str(svc.get("user", ""))
        targets.append(
            (name, image, binary, user if NUMERIC_USER.fullmatch(user) else None)
        )

    # The inverse: binaries compose.yaml claims are absent, which is why the
    # service in question has no healthcheck at all. Checked in both directions
    # so the claim cannot rot — an unknown service name catches a rename, and a
    # service that has since gained a healthcheck catches the contradiction.
    claims: list[tuple[str, str, str, str | None]] = []
    for name, binaries in ABSENT_BINARIES.items():
        svc = services.get(name)
        if svc is None:
            # Not a defect for THIS file. ABSENT_BINARIES is a claim about
            # images across the repository, and a stack is allowed not to run
            # the service it names — `loki` happens to be in both stacks today,
            # but nothing says the next one must be. The rename-or-removal
            # catch this message existed for now lives in --cross-stack, which
            # is the only mode that can tell "absent from this stack" from
            # "absent from every stack".
            continue
        svc = svc or {}
        if svc.get("healthcheck"):
            problems.append(
                f"{name} declares a healthcheck, but ABSENT_BINARIES still says "
                f"its image cannot run {' or '.join(binaries)} — one of the two is "
                f"wrong, and the healthcheck is the half that hangs the stack"
            )
            continue
        image = str(svc.get("image", ""))
        if not image:
            problems.append(f"ABSENT_BINARIES names {name}, which has no image:")
            continue
        user = str(svc.get("user", ""))
        user = user if NUMERIC_USER.fullmatch(user) else None
        claims += [(name, image, binary, user) for binary in binaries]

    probed = 0
    images: set[str] = set()
    elapsed = 0.0
    if probe:
        unavailable = docker_unavailable()
        if unavailable:
            print(unavailable, file=sys.stderr)
            return 1

        started = time.monotonic()
        images = {image for _, image, _, _ in targets + claims}
        pulled: dict[str, str | None] = {}
        for image in sorted(images):
            pulled[image] = ensure_image(image)

        for name, image, binary, user in targets:
            failure = pulled[image]
            if failure:
                problems.append(
                    f"could not pull {image} to probe {name}'s healthcheck: "
                    f"{failure}"
                )
                continue
            verdict, detail = probe_binary(image, binary, user)
            probed += 1
            if verdict == "present":
                note(f"{name}: {binary} present in {image}")
            elif verdict == "absent":
                problems.append(
                    f"{name} has a healthcheck exec'ing {binary!r}, but it is "
                    f"not in {image} — the runtime said {detail!r}. The probe "
                    f"can never run, so {name} would sit 'starting' forever and "
                    f"anything waiting on it via service_healthy would hang"
                )
            elif verdict == "unusable":
                problems.append(
                    f"{name}'s healthcheck binary {binary!r} is in {image} but "
                    f"cannot be executed as {user or 'the image default user'} "
                    f"— {detail} — which fails exactly as an absent one does"
                )
            else:
                problems.append(
                    f"could not tell whether {binary!r} exists in {image} for "
                    f"{name} ({detail}) — unverified, which is the state this "
                    f"probe exists to eliminate"
                )

        for name, image, binary, user in claims:
            failure = pulled[image]
            if failure:
                problems.append(
                    f"could not pull {image} to check {name} still has no "
                    f"{binary}: {failure}"
                )
                continue
            verdict, detail = probe_binary(image, binary, user)
            probed += 1
            if verdict == "absent":
                note(f"{name}: {binary} absent from {image}, as compose.yaml says")
            elif verdict in ("present", "unusable"):
                problems.append(
                    f"{image} contains {binary!r}, which {path.name} says it "
                    f"does not — that claim is why {name} has no healthcheck, "
                    f"and why the services behind it wait with service_started. "
                    f"Either the image changed base or the comment is wrong: "
                    f"give {name} a healthcheck and drop it from ABSENT_BINARIES"
                )
            else:
                problems.append(
                    f"could not tell whether {binary!r} exists in {image} for "
                    f"{name} ({detail}) — unverified, which is the state this "
                    f"probe exists to eliminate"
                )
        elapsed = time.monotonic() - started

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
    summary = (
        f"{path.name} OK — {checks} healthcheck(s), "
        f"{healthy_deps} service_healthy dependency/dependencies, all satisfiable"
    )
    summary += f"; {RELOAD_SCRIPT.name} probes agree with them"
    if probe:
        # The count is the point. A probe loop that silently stopped matching
        # anything would otherwise print this same green line having done
        # nothing at all.
        summary += (
            f"; {probed} binary/binaries exec'd inside {len(images)} pinned "
            f"image(s) in {elapsed:.0f}s"
        )
    else:
        summary += (
            " (images NOT probed — pass --probe to exec each healthcheck binary "
            "inside its image)"
        )
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
