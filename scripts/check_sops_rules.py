#!/usr/bin/env python3
"""Assert every creation_rule in .sops.yaml matches the file it was written for.

Why this exists
---------------
ADR-0020 gave `stacks/lab` its own creation_rule and its own age recipient,
above the catch-all, because that catch-all matches ALL of secrets/ — so a
recipient added to it can decrypt the estate's SNMP communities and Grafana
admin password. A lab host holding the estate's credentials inverts the trust
direction ADR-0007 exists to protect.

The rule shipped as:

    path_regex: secrets/lab\\..*\\.sops\\.ya?ml$

which cannot match `secrets/lab.sops.yaml`. After `secrets/lab\\.` consumes the
only dot before `sops`, `\\.sops\\.` has no second dot left to match; it would
have matched `secrets/lab.something.sops.yaml` and nothing else. So the rule
matched NOTHING, sops fell through to the catch-all, and `make secrets-init
STACK=lab` on the guest encrypted the lab's secrets to the ESTATE's key —
doing precisely what the rule was added to prevent, and reporting success.

Nothing caught it. sops does not warn about a rule that matches no file: it
just uses the next one. The separation existed in the file, was reviewed, was
merged, and was not real. It surfaced days later on the lab guest as sops'
"no identity matched any of the recipients", which names the symptom and not
the cause.

What this asserts
-----------------
1. Every stack's secrets file resolves to some rule — otherwise sops refuses to
   encrypt it at all, which is loud but worth naming here rather than at deploy
   time on a machine you had to walk to.

2. **Every rule matches at least one real path.** This is the one that would
   have caught the bug. A creation_rule matching nothing is either a typo or
   dead, and both are indistinguishable from working until the day the
   fall-through matters.

3. Which rule each path resolves to is printed, so the separation ADR-0020
   decided is visible in CI output rather than inferred from two regexes.

The paths are derived, not listed: the stacks come from scripts/stacks.sh, the
one definition of what a stack is, and the firewall backup path is the shape
scripts/backup-firewall.sh actually writes. A hand-kept list here would be the
fourth copy of something and would rot the same way.

Usage: scripts/check_sops_rules.py
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - CI installs it
    print("PyYAML is required: python3 -m pip install pyyaml", file=sys.stderr)
    raise SystemExit(1)

REPO = pathlib.Path(__file__).resolve().parent.parent
POLICY = REPO / ".sops.yaml"


def stacks() -> list[str]:
    listed = subprocess.run(
        [str(REPO / "scripts/stacks.sh")],
        capture_output=True, text=True, check=True,
    )
    return listed.stdout.split()


def main() -> int:
    if not POLICY.exists():
        print(f"no {POLICY.name}", file=sys.stderr)
        return 1

    policy = yaml.safe_load(POLICY.read_text(encoding="utf-8")) or {}
    rules = policy.get("creation_rules") or []
    if not rules:
        print(f"{POLICY.name} declares no creation_rules", file=sys.stderr)
        return 1

    patterns: list[tuple[str, re.Pattern[str]]] = []
    problems: list[str] = []
    for rule in rules:
        raw = rule.get("path_regex")
        if not raw:
            problems.append("a creation_rule has no path_regex")
            continue
        try:
            patterns.append((raw, re.compile(raw)))
        except re.error as exc:
            problems.append(f"path_regex {raw!r} does not compile — {exc}")

    # The paths sops is actually asked to encrypt. Stack secrets files, plus one
    # firewall export: the stamp is arbitrary, so any well-formed name stands in
    # for the whole class.
    paths = [f"secrets/{stack}.sops.yaml" for stack in stacks()]
    paths.append("backups/firewall/config-20260101T000000Z.sops.yaml")

    matched_by: dict[str, str] = {}
    used: set[str] = set()
    for path in paths:
        hit = next((raw for raw, pat in patterns if pat.search(path)), None)
        if hit is None:
            problems.append(
                f"{path} matches no creation_rule in {POLICY.name} — sops will "
                f"refuse to encrypt it"
            )
            continue
        matched_by[path] = hit
        used.add(hit)

    # The assertion that would have caught the lab rule.
    for raw, _pat in patterns:
        if raw not in used:
            problems.append(
                f"creation_rule {raw!r} matches none of the files this "
                f"repository encrypts — sops does not warn about a dead rule, "
                f"it silently uses the next one, so the recipient separation "
                f"this rule was added for is not in effect (ADR-0020)"
            )

    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(f"{POLICY.name} OK — {len(patterns)} creation_rule(s), each matching:")
    for path, raw in matched_by.items():
        print(f"  {path} -> {raw}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
