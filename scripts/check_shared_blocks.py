#!/usr/bin/env python3
"""Every copy of a marked shared block is identical.

Usage:
  scripts/check_shared_blocks.py               check every tracked file
  scripts/check_shared_blocks.py --self-test   fixtures

Some code here is copied on purpose. The collectors install onto their hosts
as single files (scripts/install-agent-collectors.sh copies one script, not a
library beside it), so a helper two of them need is written into both. A fix
that lands in one copy and not the other is the failure that design invites:
the 2026-11-11 audit found the `qm list` parser in three collectors, already
drifted into three versions.

A copy is marked, in a shell or Python comment, by a pair of lines:

  # shared-block: <name>
  ...
  # end shared-block: <name>

Everything between the two marker lines is compared byte for byte across
every tracked file that carries the name. This fails when:

  - two copies of one name differ;
  - a name appears only once, because a block with no second copy is a
    marker that protects nothing, usually one whose sibling was deleted;
  - a marker is unbalanced or nested, or an end names a different block.

Indentation counts. A copy that has to be indented differently is a
different block and needs its own name.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
START = re.compile(r"^\s*#\s*shared-block:\s*([a-z0-9_.-]+)\s*$")
END = re.compile(r"^\s*#\s*end shared-block:\s*([a-z0-9_.-]+)\s*$")


def blocks_in(text: str, rel: str) -> tuple[dict[str, list[str]], list[str]]:
    """Each block's body by name, and any structural problems."""
    found: dict[str, list[str]] = {}
    problems: list[str] = []
    open_name: str | None = None
    open_line = 0
    body: list[str] = []
    for n, line in enumerate(text.splitlines(keepends=True), 1):
        start, end = START.match(line), END.match(line)
        if start:
            if open_name is not None:
                problems.append(f"{rel}:{n} opens {start.group(1)!r} inside {open_name!r} (opened at {open_line})")
            open_name, open_line, body = start.group(1), n, []
        elif end:
            if open_name is None:
                problems.append(f"{rel}:{n} ends {end.group(1)!r}, which is not open")
            elif end.group(1) != open_name:
                problems.append(f"{rel}:{n} ends {end.group(1)!r} but {open_name!r} is open (since {open_line})")
            elif open_name in found:
                problems.append(f"{rel}:{open_line} carries {open_name!r} twice in one file")
            else:
                found[open_name] = body
            open_name, body = None, []
        elif open_name is not None:
            body.append(line)
    if open_name is not None:
        problems.append(f"{rel}:{open_line} opens {open_name!r} and never ends it")
    return found, problems


def check(files: dict[str, str]) -> list[str]:
    problems: list[str] = []
    copies: dict[str, list[tuple[str, list[str]]]] = {}
    for rel, text in sorted(files.items()):
        if "shared-block:" not in text:
            continue
        found, structural = blocks_in(text, rel)
        problems += structural
        for name, body in found.items():
            copies.setdefault(name, []).append((rel, body))
    for name, where in sorted(copies.items()):
        if len(where) < 2:
            problems.append(f"{where[0][0]}: {name!r} has no other copy, so the marker protects nothing")
            continue
        first_rel, first = where[0]
        for rel, body in where[1:]:
            if body != first:
                problems.append(
                    f"{rel}: {name!r} differs from the copy in {first_rel}; "
                    f"a fix to one copy belongs in all {len(where)}"
                )
    return problems


def tracked_files() -> dict[str, str]:
    out = subprocess.run(
        ["git", "ls-files", "-z", "*.sh", "*.py", "*.bash"],
        cwd=REPO,
        capture_output=True,
        check=True,
    ).stdout
    files = {}
    for rel in out.decode().split("\0"):
        if not rel or rel == "scripts/check_shared_blocks.py":
            continue
        path = REPO / rel
        if path.is_file():
            # Bytes, decoded losslessly: read_text() would turn CRLF into LF
            # and errors="replace" would fold different invalid bytes into
            # one character, so two copies that differ on disk could compare
            # equal. surrogateescape keeps every byte distinct.
            files[rel] = path.read_bytes().decode("utf-8", errors="surrogateescape")
    return files


def self_test() -> int:
    def block(name: str, *lines: str, end: str | None = None) -> str:
        return f"# shared-block: {name}\n" + "".join(f"{x}\n" for x in lines) + f"# end shared-block: {end or name}\n"

    a = block("parse", "awk '{ print $1 }'")
    cases = [
        ("two identical copies pass", {"a.sh": a, "b.sh": "x=1\n" + a}, 0),
        ("three identical copies pass", {"a.sh": a, "b.sh": a, "c.sh": a}, 0),
        ("a changed copy fails", {"a.sh": a, "b.sh": block("parse", "awk '{ print $2 }'")}, 1),
        ("a re-indented copy fails", {"a.sh": a, "b.sh": block("parse", "  awk '{ print $1 }'")}, 1),
        ("a third copy that drifted fails", {"a.sh": a, "b.sh": a, "c.sh": block("parse", "true")}, 1),
        ("a block with no second copy fails", {"a.sh": a}, 1),
        ("an unended block fails", {"a.sh": a, "b.sh": "# shared-block: parse\nawk '{ print $1 }'\n"}, 1),
        (
            "an end naming another block fails",
            {"a.sh": a, "b.sh": block("parse", "awk '{ print $1 }'", end="other")},
            1,
        ),
        ("a nested block fails", {"a.sh": a, "b.sh": "# shared-block: outer\n" + a + "# end shared-block: outer\n"}, 1),
        ("a stray end fails", {"a.sh": a, "b.sh": a + "# end shared-block: parse\n"}, 1),
        ("one name twice in a file fails", {"a.sh": a + a, "b.sh": a}, 1),
        ("a file with no markers is ignored", {"a.sh": a, "b.sh": a, "c.sh": "echo hi\n"}, 0),
    ]
    failed = 0
    for desc, files, want in cases:
        got = 1 if check(files) else 0
        if got == want:
            print(f"\033[0;32m  PASS\033[0m {desc}")
        else:
            print(f"\033[0;31m  FAIL\033[0m {desc} (got {got}, want {want})")
            failed = 1

    # The real tree, through the real reader, so the git half is exercised too.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / "a.sh").write_text(a)
        (root / "b.sh").write_text(block("parse", "drifted"))
        subprocess.run(["git", "-C", str(root), "add", "a.sh", "b.sh"], check=True)
        global REPO
        saved, REPO = REPO, root
        try:
            got = 1 if check(tracked_files()) else 0
        finally:
            REPO = saved
        if got == 1:
            print("\033[0;32m  PASS\033[0m a drifted copy in a git tree is read and fails")
        else:
            print("\033[0;31m  FAIL\033[0m a drifted copy in a git tree passed")
            failed = 1

        # Byte-level differences the reader must not normalise away.
        for desc, other in (
            ("a CRLF copy of an LF block is read and fails", a.replace("\n", "\r\n").encode()),
            (
                "copies differing only in invalid UTF-8 bytes are read and fail",
                None,
            ),
        ):
            if other is None:
                first = block("parse", "x").encode().replace(b"x\n", b"\xff\n")
                other = block("parse", "x").encode().replace(b"x\n", b"\xfe\n")
                (root / "a.sh").write_bytes(first)
            else:
                (root / "a.sh").write_text(a)
            (root / "b.sh").write_bytes(other)
            saved, REPO = REPO, root
            try:
                got = 1 if check(tracked_files()) else 0
            finally:
                REPO = saved
            if got == 1:
                print(f"\033[0;32m  PASS\033[0m {desc}")
            else:
                print(f"\033[0;31m  FAIL\033[0m {desc}")
                failed = 1
    return failed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--self-test", action="store_true", help="run the fixtures")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    files = tracked_files()
    problems = check(files)
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    if problems:
        return 1
    names = sum(t.count("# end shared-block:") for t in files.values())
    print(f"shared blocks OK — {names} marked copies agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
