#!/usr/bin/env python3
"""PyYAML for the scripts under scripts/, from one place and only ever pinned.

Eight scripts carried their own copy of a bootstrap that ran
`pip install pyyaml` when the import failed: no version, no hash (#848). Two of
them run from `make up`, so a production deploy could install whatever PyPI
served that minute onto a monitoring host. On Ubuntu 24.04 and later the
install could not even succeed, because the system interpreter is marked
externally managed (PEP 668), so the fallback was unpinned where it worked and
dead where it mattered.

The order is now:

  1. `import yaml` works — use it. On a host that is the distribution's
     python3-yaml, which apt keeps patched; in a venv it is whatever the venv
     installed from requirements.txt.
  2. On a CI runner (GITHUB_ACTIONS=true), install scripts/requirements.txt
     with --require-hashes into a directory under RUNNER_TEMP and import from
     there. --target is the form pip does not refuse under PEP 668, and it
     touches nothing outside the runner's scratch space.
  3. Anywhere else, stop and say `apt install python3-yaml`. A host is never
     the place to fetch a package at run time.

Usage, from Python:

    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    from _deps import require_yaml  # noqa: E402
    yaml = require_yaml()

From shell, where the import happens in a child python3:

    pydeps="$(python3 scripts/_deps.py --pythonpath)" || exit 1
    [[ -n "${pydeps}" ]] && export PYTHONPATH="${pydeps}${PYTHONPATH:+:${PYTHONPATH}}"

--pythonpath prints the directory it installed into, or nothing when yaml was
already importable.
"""
from __future__ import annotations

import importlib
import os
import pathlib
import subprocess
import sys
from types import ModuleType

REQUIREMENTS = pathlib.Path(__file__).resolve().parent / "requirements.txt"
HOST_HINT = (
    "PyYAML is required: sudo apt install python3-yaml "
    "(or, in a venv, pip install --require-hashes -r scripts/requirements.txt)"
)


def _target() -> pathlib.Path:
    return pathlib.Path(os.environ.get("RUNNER_TEMP") or "/tmp") / "homelab-pydeps"


def _ensure() -> str:
    """Make `import yaml` work; return the directory added to sys.path, or ''."""
    try:
        import yaml  # noqa: F401
        return ""
    except ModuleNotFoundError:
        pass
    if os.environ.get("GITHUB_ACTIONS") != "true":
        sys.exit(HOST_HINT)
    target = _target()
    # The CI job runs several of these scripts, and the first one installed it.
    if (target / "yaml" / "__init__.py").is_file():
        sys.path.insert(0, str(target))
        return str(target)
    print(f"installing pinned PyYAML from {REQUIREMENTS.name}", file=sys.stderr)
    if subprocess.run(
        [sys.executable, "-m", "pip", "install", "--quiet",
         "--disable-pip-version-check", "--require-hashes", "--no-deps",
         "--target", str(target), "-r", str(REQUIREMENTS)],
        check=False,
    ).returncode:
        sys.exit(f"could not install the pinned PyYAML from {REQUIREMENTS}")
    sys.path.insert(0, str(target))
    importlib.invalidate_caches()
    return str(target)


def require_yaml() -> ModuleType:
    _ensure()
    return importlib.import_module("yaml")


if __name__ == "__main__":
    if sys.argv[1:] != ["--pythonpath"]:
        sys.exit("usage: _deps.py --pythonpath")
    print(_ensure())
