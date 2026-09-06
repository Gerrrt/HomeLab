#!/usr/bin/env python3
"""Check that Alertmanager can actually read the URLs it notifies through.

THE FAILURE THIS EXISTS FOR (#214). Between 03:06 and 13:32 on 2026-08-31,
Alertmanager failed 471 of 493 notification attempts — every receiver, for ten
and a half hours:

    notify retry canceled due to unrecoverable error after 1 attempts:
    read url_file: open /etc/alertmanager/secrets/urgent_url:
    no such file or directory

All four destinations read their URL from `/etc/alertmanager/secrets/`, so all
four went down together. `AlertmanagerNotificationsFailing` fired correctly at
03:16 and stayed firing until 13:46 — and could not be delivered, because the
thing it was reporting was the delivery path. `IloBatteryCondition` was firing
and undeliverable through the whole window.

Nothing else can see this. `alertmanager_config_last_reload_successful` stays 1,
because the config parses fine; it is the `url_file` TARGET that is absent, and
a missing one is not a config error. Alertmanager opens it at notify time, so
the stack starts, `amtool check-config` passes, and the first real alert is what
discovers the file is gone.

Three checks, because the question has three different homes:

  static   Every `url_file` in alertmanager.yaml is rendered by render-config.sh
           and vice versa. Pure text, no secrets, so CI runs it — which is where
           "added a receiver, forgot AM_CHANNELS" should be caught, rather than
           on the monitoring host at deploy time.

  --files  Each rendered file exists and is NON-EMPTY on this host. The existing
           assertion in render-config.sh checks existence only, and an empty file
           passes it: a SOPS key that is present but blank renders zero bytes,
           and Alertmanager POSTs to the empty string. Deploy host only.

  --live   Each file exists and is non-empty AS THE CONTAINER SEES IT. This is
           the one that would have caught #214, because there the files were
           present on the host and absent inside the container — a stale bind
           mount, a partial render into a directory the container already had
           open, or a replaced inode. Asking the host proves nothing about what
           Alertmanager can open.

WHAT THIS DELIBERATELY DOES NOT DO. It does not ask Alertmanager whether it is
healthy, and it does not send a test notification. #214 is a recursive failure —
the alert about the broken delivery path travelled the broken delivery path —
and a check that depends on the same path inherits the same blind spot. Every
assertion here reads a file, and none of them needs a notification to succeed.

The dead man's switch is the other half of the answer and is not this: it is what
notices when the whole path is down, and whether it actually works has never been
tested (#288).

Usage: scripts/check_alert_channels.py [--files] [--live] [STACK]
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
RESET = "\033[0m"

# Anchored on `url_file:` rather than on the path fragment, for the reason
# render-config.sh records: a bare `secrets/[a-z_]+` also matches
# `secrets/observability.sops.yaml` in a comment, and reports prose as a channel.
URL_FILE = re.compile(r"url_file:\s*(/etc/alertmanager/secrets/([a-z_]+))")

# The pairs render-config.sh writes, read out of that script rather than
# duplicated here. Two copies of this list is exactly the drift the check is for.
AM_CHANNEL = re.compile(r'^\s*"([A-Z_]+):([a-z_]+)"\s*$', re.M)


def failures() -> list[str]:
    return _FAILURES


_FAILURES: list[str] = []


def ok(msg: str) -> None:
    print(f"{GREEN}  PASS{RESET} {msg}")


def bad(msg: str) -> None:
    print(f"{RED}  FAIL{RESET} {msg}")
    _FAILURES.append(msg)


def skip(msg: str) -> None:
    print(f"{YELLOW}  SKIP{RESET} {msg}")


def declared(stack: str) -> tuple[set[str], set[str]]:
    """(url_files named in alertmanager.yaml, files render-config.sh writes)."""
    config = REPO / "stacks" / stack / "alertmanager" / "alertmanager.yaml"
    if not config.is_file():
        sys.exit(f"no alertmanager.yaml for stack {stack!r} at {config}")
    wanted = {m.group(2) for m in URL_FILE.finditer(config.read_text(encoding="utf-8"))}

    render = (REPO / "scripts" / "render-config.sh").read_text(encoding="utf-8")
    block = render[render.index("AM_CHANNELS=("):]
    block = block[: block.index(")")]
    rendered = {m.group(2) for m in AM_CHANNEL.finditer(block)}
    return wanted, rendered


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("stack", nargs="?", default="observability")
    ap.add_argument(
        "--files", action="store_true",
        help="also assert the rendered files exist and are non-empty on this host",
    )
    ap.add_argument(
        "--live", action="store_true",
        help="also assert the running container can see them (needs docker)",
    )
    args = ap.parse_args()

    wanted, rendered = declared(args.stack)
    if not wanted:
        sys.exit(
            "alertmanager.yaml names no url_file at all — either every receiver "
            "was rewritten to an inline url, or this parser has stopped matching. "
            "Both are worth stopping for."
        )

    # 1. Both directions. A url_file nothing renders is #214's failure waiting to
    #    happen; a rendered file nothing reads is a secret written for no reason.
    for name in sorted(wanted - rendered):
        bad(f"alertmanager.yaml reads {name}, which AM_CHANNELS does not render")
    for name in sorted(rendered - wanted):
        bad(f"AM_CHANNELS renders {name}, which no receiver reads")
    if wanted == rendered:
        ok(f"{len(wanted)} url_file(s) declared and rendered: {', '.join(sorted(wanted))}")

    out_dir = REPO / "stacks" / args.stack / "alertmanager" / ".rendered"

    # 2. On disk. Existence AND size: render-config.sh already asserts the first,
    #    and an empty file passes it while producing a POST to the empty string.
    checked_files = False
    if args.files:
        if not out_dir.is_dir():
            skip(f"{out_dir.relative_to(REPO)} does not exist — nothing rendered here")
        else:
            checked_files = True
            for name in sorted(wanted):
                path = out_dir / name
                if not path.is_file():
                    bad(f"{name} is not rendered on this host")
                elif path.stat().st_size == 0:
                    bad(f"{name} is rendered but EMPTY — Alertmanager would POST to nothing")
                else:
                    ok(f"{name} rendered, {path.stat().st_size} bytes")

    # 3. As the container sees it. The only one of the three that would have
    #    caught #214, where the files were on the host and not in the container.
    checked_live = False
    if args.live:
        container = "alertmanager"
        probe = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Status}}", container],
            capture_output=True, text=True,
        )
        if probe.returncode != 0:
            skip(f"no {container} container here — the container's view is unchecked")
        elif probe.stdout.strip() != "running":
            bad(f"{container} is {probe.stdout.strip()}, so nothing can notify")
        else:
            checked_live = True
            for name in sorted(wanted):
                # `wc -c` rather than `test -s`, so an empty file and a missing
                # one are different messages. Alertmanager treats them the same
                # way — badly — but the operator does not.
                result = subprocess.run(
                    ["docker", "exec", container, "wc", "-c",
                     f"/etc/alertmanager/secrets/{name}"],
                    capture_output=True, text=True,
                )
                if result.returncode != 0:
                    detail = (result.stderr or result.stdout).strip().splitlines()
                    bad(
                        f"{container} cannot read {name} — "
                        f"{detail[-1] if detail else 'unknown error'}"
                    )
                    continue
                size = int(result.stdout.split()[0])
                if size == 0:
                    bad(f"{container} sees {name} as empty — it would POST to nothing")
                else:
                    ok(f"{container} can read {name}, {size} bytes")

    if _FAILURES:
        sys.stdout.flush()
        print(
            f"\n{len(_FAILURES)} problem(s) with the notification path. Every "
            f"receiver reads from the same directory, so these fail together — "
            f"which is how #214 lasted ten and a half hours.",
            file=sys.stderr,
        )
        return 1

    # What was actually checked, not what was asked for. A summary that counted
    # a skipped check would be the same green line either way, which is the
    # thing this repository keeps writing checks to avoid.
    checked = ["config"] + (["files"] if checked_files else []) + (["container"] if checked_live else [])
    print(
        f"\nalert channels OK — {len(wanted)} receiver URL(s), "
        f"checked against: {', '.join(checked)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
