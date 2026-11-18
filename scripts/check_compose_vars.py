#!/usr/bin/env python3
"""Every guarded SOPS value is one render-config.sh writes into .env.

Usage:
  scripts/check_compose_vars.py               check the repository
  scripts/check_compose_vars.py --self-test   fixtures

Why this exists
---------------
A value a stack reads from SOPS reaches compose through three copies of one
fact, and the comment above COMPOSE_VARS in scripts/render-config.sh says so:

  - the `${NAME:?}` guard in stacks/<stack>/compose.yaml, which makes a
    missing value fail loudly at `make up`;
  - the COMPOSE_VARS array in scripts/render-config.sh, the names it copies
    out of the decrypted SOPS file into the stack's .env;
  - scripts/seed-validation-env.sh, the throwaway .env that lets validation
    get past the guard.

On 2026-11-18 #1563 added WALL_HA_TOKEN to secrets/sensitive.sops.yaml and
#1566 added its guard to stacks/sensitive/compose.yaml and its stand-in to
seed-validation-env.sh. Nobody added it to COMPOSE_VARS. CI passed, because CI
validates against the seed's stand-ins and never runs render-config.sh, and
`make up STACK=sensitive` on trinity then died with "required variable
WALL_HA_TOKEN is missing a value". #1570 added the line. Nothing checked the
copies against each other; this does.

What this asserts
-----------------
1. A guarded name that is a key in some secrets/*.sops.yaml is in
   COMPOSE_VARS. This is the one that would have caught #1566.
2. A name seed-validation-env.sh stands in for that is a SOPS key is in
   COMPOSE_VARS: the same bug, seen from the third copy.
3. A guarded name that is a SOPS key has a stand-in in seed-validation-env.sh.
   That script checks this per stack when it runs; here it is checked for
   every stack at once.
4. Every COMPOSE_VARS entry is a key in some SOPS file. One that is not
   names nothing render can ever write, which is a typo or a leftover.

A guard on a name that is not a SOPS key (RENDER_UID, a bind address in
.env.example) is not this check's business: render-config.sh writes those
another way, or the operator does.

No secret is read. A SOPS file keeps its top-level key names in plaintext
(`NAME: ENC[...]`); only the names are taken, never the line's value.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

# PyYAML from the one pinned bootstrap, scripts/_deps.py (#848).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _deps import require_yaml

yaml = require_yaml()

REPO = Path(__file__).resolve().parent.parent

NAME = r"[A-Za-z_][A-Za-z0-9_]*"
# The same pattern scripts/compose-guards.sh walks the parsed YAML with, so a
# comment that mentions the guard syntax is not read as a guard (#107).
GUARD = re.compile(r"\$\{(" + NAME + r"):\?")
SOPS_KEY = re.compile(r"^(" + NAME + r"):", re.MULTILINE)
COMPOSE_VARS = re.compile(r"^COMPOSE_VARS=\((.*?)^\)", re.MULTILINE | re.DOTALL)
SEED = re.compile(r"""^\s*echo\s+['"](""" + NAME + r")=", re.MULTILINE)


class SourceError(Exception):
    """A source could not be read, which must fail rather than pass empty."""


def compose_guards(root: Path) -> dict[str, set[str]]:
    """Guarded name -> the compose files that guard it."""
    found: dict[str, set[str]] = {}

    def walk(node: object, rel: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                walk(key, rel)
                walk(value, rel)
        elif isinstance(node, list):
            for item in node:
                walk(item, rel)
        elif isinstance(node, str):
            for name in GUARD.findall(node):
                found.setdefault(name, set()).add(rel)

    files = sorted(root.glob("stacks/*/compose.yaml"))
    if not files:
        raise SourceError("no stacks/*/compose.yaml found")
    for path in files:
        walk(yaml.safe_load(path.read_text(encoding="utf-8")), path.relative_to(root).as_posix())
    return found


def sops_keys(root: Path) -> dict[str, set[str]]:
    """Top-level key name -> the SOPS files that hold it. Names only."""
    found: dict[str, set[str]] = {}
    files = sorted(root.glob("secrets/*.sops.yaml"))
    if not files:
        raise SourceError("no secrets/*.sops.yaml found")
    for path in files:
        for name in SOPS_KEY.findall(path.read_text(encoding="utf-8")):
            if name != "sops":
                found.setdefault(name, set()).add(path.relative_to(root).as_posix())
    return found


def compose_vars(root: Path) -> set[str]:
    text = (root / "scripts/render-config.sh").read_text(encoding="utf-8")
    match = COMPOSE_VARS.search(text)
    if not match:
        raise SourceError("scripts/render-config.sh: no COMPOSE_VARS=( ... ) array found")
    names: set[str] = set()
    for line in match.group(1).splitlines():
        line = line.split("#", 1)[0]
        names.update(line.split())
    if not names:
        raise SourceError("scripts/render-config.sh: COMPOSE_VARS is empty")
    return names


def seed_names(root: Path) -> set[str]:
    text = (root / "scripts/seed-validation-env.sh").read_text(encoding="utf-8")
    names = set(SEED.findall(text))
    if not names:
        raise SourceError("scripts/seed-validation-env.sh: no `echo NAME=` lines found")
    return names


def where(files: set[str]) -> str:
    return ", ".join(sorted(files))


def check(root: Path) -> tuple[list[str], str]:
    """Problems found, and a one-line summary for a clean run."""
    try:
        guards = compose_guards(root)
        keys = sops_keys(root)
        listed = compose_vars(root)
        seeded = seed_names(root)
    except (OSError, SourceError, yaml.YAMLError) as err:
        return [f"could not read a source: {err}"], ""

    problems = []
    for name in sorted((guards.keys() & keys.keys()) - listed):
        problems.append(
            f"{where(guards[name])} guards {name}, a key in {where(keys[name])}, but "
            f"COMPOSE_VARS in scripts/render-config.sh does not list it: render would "
            f"not write it and `make up` would fail on the unset variable. Add it there."
        )
    for name in sorted((seeded & keys.keys()) - guards.keys() - listed):
        problems.append(
            f"scripts/seed-validation-env.sh stands in for {name}, a key in "
            f"{where(keys[name])}, but COMPOSE_VARS in scripts/render-config.sh does "
            f"not list it. Add it there, or drop the stand-in if nothing reads it."
        )
    for name in sorted((guards.keys() & keys.keys()) - seeded):
        problems.append(
            f"{where(guards[name])} guards {name}, a key in {where(keys[name])}, but "
            f"scripts/seed-validation-env.sh has no stand-in for it. Add one there."
        )
    for name in sorted(listed - keys.keys()):
        problems.append(
            f"COMPOSE_VARS in scripts/render-config.sh lists {name}, which is a key in "
            f"no secrets/*.sops.yaml, so render can never write it. Fix or remove it."
        )

    covered = len(guards.keys() & keys.keys())
    summary = (
        f"COMPOSE_VARS OK — all {covered} guarded SOPS values are rendered and seeded "
        f"({len(listed)} listed, {len(keys)} SOPS keys, {len(guards)} guards)"
    )
    return problems, summary


def self_test() -> int:
    render = "COMPOSE_VARS=(\n  {names}\n)\n"
    seed = "{{\n{lines}}} >> out\n"

    def tree(
        root: Path,
        *,
        guards: list[str],
        keys: list[str],
        listed: list[str] | None,
        seeded: list[str],
        compose_extra: str = "",
    ) -> None:
        for d in ("stacks/a", "secrets", "scripts"):
            (root / d).mkdir(parents=True, exist_ok=True)
        env = "".join(f"      {g}: ${{{g}:?set it}}\n" for g in guards)
        (root / "stacks/a/compose.yaml").write_text(
            "services:\n  x:\n    image: x\n" + compose_extra + ("    environment:\n" + env if env else "")
        )
        (root / "secrets/a.sops.yaml").write_text(
            "".join(f"{k}: ENC[AES256_GCM,data:xx,type:str]\n" for k in keys) + "sops:\n  version: 3\n"
        )
        (root / "scripts/render-config.sh").write_text(
            render.format(names="\n  ".join(listed)) if listed is not None else "echo no list\n"
        )
        (root / "scripts/seed-validation-env.sh").write_text(
            seed.format(lines="".join(f'  echo "{s}=validation-only"\n' for s in seeded))
        )

    cases = [
        (
            "a consistent tree passes",
            {"guards": ["TOKEN"], "keys": ["TOKEN"], "listed": ["TOKEN"], "seeded": ["TOKEN"]},
            0,
        ),
        (
            "the WALL_HA_TOKEN shape (guarded, in SOPS, seeded, not listed) fails",
            {
                "guards": ["TOKEN", "WALL_HA_TOKEN"],
                "keys": ["TOKEN", "WALL_HA_TOKEN"],
                "listed": ["TOKEN"],
                "seeded": ["TOKEN", "WALL_HA_TOKEN"],
            },
            1,
        ),
        (
            "a seeded SOPS key that is not listed fails even unguarded",
            {"guards": [], "keys": ["TOKEN", "OTHER"], "listed": ["TOKEN"], "seeded": ["OTHER"]},
            1,
        ),
        (
            "a guarded SOPS key with no stand-in fails",
            {"guards": ["TOKEN"], "keys": ["TOKEN"], "listed": ["TOKEN"], "seeded": ["SOMETHING"]},
            1,
        ),
        (
            "a listed name in no SOPS file fails",
            {"guards": ["TOKEN"], "keys": ["TOKEN"], "listed": ["TOKEN", "TYPO"], "seeded": ["TOKEN"]},
            1,
        ),
        (
            "a guard on a non-SOPS name (RENDER_UID) is ignored",
            {
                "guards": ["TOKEN", "RENDER_UID"],
                "keys": ["TOKEN"],
                "listed": ["TOKEN"],
                "seeded": ["TOKEN", "RENDER_UID"],
            },
            0,
        ),
        (
            "the `sops:` metadata key is not a value",
            {"guards": ["TOKEN"], "keys": ["TOKEN"], "listed": ["TOKEN", "sops"], "seeded": ["TOKEN"]},
            1,
        ),
        (
            "a guard in a YAML comment is not a guard",
            {
                "guards": ["TOKEN"],
                "keys": ["TOKEN", "WALL_HA_TOKEN"],
                "listed": ["TOKEN", "WALL_HA_TOKEN"],
                "seeded": ["TOKEN"],
                "compose_extra": "    # ${WALL_HA_TOKEN:?} would be read by a grep\n",
            },
            0,
        ),
        (
            "a missing COMPOSE_VARS array fails rather than passing empty",
            {"guards": ["TOKEN"], "keys": ["TOKEN"], "listed": None, "seeded": ["TOKEN"]},
            1,
        ),
        ("an empty COMPOSE_VARS array fails", {"guards": [], "keys": ["TOKEN"], "listed": [], "seeded": ["TOKEN"]}, 1),
        (
            "a seed script with no stand-ins fails rather than passing empty",
            {"guards": ["TOKEN"], "keys": ["TOKEN"], "listed": ["TOKEN"], "seeded": []},
            1,
        ),
    ]
    failed = 0
    for desc, spec, want in cases:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tree(root, **spec)
            problems, _ = check(root)
        got = 1 if problems else 0
        if got == want:
            print(f"\033[0;32m  PASS\033[0m {desc}")
        else:
            print(f"\033[0;31m  FAIL\033[0m {desc} (got {got}, want {want}): {problems}")
            failed = 1
    return failed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--self-test", action="store_true", help="run the fixtures")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    problems, summary = check(REPO)
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    if problems:
        return 1
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
