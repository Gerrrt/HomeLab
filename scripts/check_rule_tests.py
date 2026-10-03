#!/usr/bin/env python3
"""Fail when a Prometheus alert rule has no promtool test that names it (#843).

CI already refuses a stack with rule files and no tests at all, because a rule
that cannot fire still passes `promtool check rules` (#63). That guard is per
stack. It did not notice twenty untested rules inside stacks that had tests,
and one of them, SwitchInterfaceDown, had been unable to fire since the day it
was written. Its first test found that in seconds.

So this is the same guard, per rule: every `alert:` in a stack's
prometheus/rules/ must appear as an `alertname:` in that stack's
prometheus/tests/. A rule deliberately left untested goes in ALLOWED with the
reason, where a reviewer sees it, rather than being untested by default.

Only presence is checked: that some test selects the rule. Whether the test
proves anything is still review's job; the repository's convention is a firing
case and a quiet near-miss per rule.

Usage:
  scripts/check_rule_tests.py              check every stack
  scripts/check_rule_tests.py --self-test  run the fixtures
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# (stack, alertname) -> why it has no test. Empty since #843: every alert in
# every stack has one. Add to this only with a reason a reviewer can weigh.
ALLOWED: dict[tuple[str, str], str] = {}

ALERT = re.compile(r"^\s*-\s*alert:\s*(\S+)\s*$", re.M)
TESTED = re.compile(r"^\s*alertname:\s*(\S+)\s*$", re.M)


def untested(rules_text: list[str], tests_text: list[str]) -> list[str]:
    """Alert names in the rule texts that no test text selects."""
    tested = {m for t in tests_text for m in TESTED.findall(t)}
    alerts = [m for r in rules_text for m in ALERT.findall(r)]
    return sorted({a for a in alerts if a not in tested})


def stacks() -> list[str]:
    out = subprocess.run([str(REPO / "scripts/stacks.sh")],
                         capture_output=True, text=True, check=True)
    return out.stdout.split()


def main() -> int:
    problems: list[str] = []
    checked = 0
    for stack in stacks():
        prom = REPO / "stacks" / stack / "prometheus"
        # The same globs the real commands use: Prometheus loads *.rules.yaml,
        # and CI, validate.sh and make check-rules run *.test.yaml. A helper
        # YAML beside them that promtool never runs must not count as a test.
        rules = sorted((prom / "rules").glob("*.rules.yaml"))
        if not rules:
            continue
        tests = sorted((prom / "tests").glob("*.test.yaml"))
        missing = untested([r.read_text(encoding="utf-8") for r in rules],
                           [t.read_text(encoding="utf-8") for t in tests])
        checked += len([m for r in rules for m in ALERT.findall(r.read_text(encoding="utf-8"))])
        for name in missing:
            if ALLOWED.get((stack, name), "").strip():
                continue
            problems.append(
                f"stacks/{stack}: alert {name} has no promtool test. Add a firing "
                f"case and a quiet near-miss to prometheus/tests/, or an entry in "
                f"ALLOWED in this script saying why not (#63, #843)"
            )
        for (s, name), reason in ALLOWED.items():
            if s == stack and not reason.strip():
                problems.append(f"ALLOWED names {s}/{name} with no reason: an exception needs one")
            elif s == stack and name not in missing:
                problems.append(
                    f"ALLOWED names {s}/{name}, which is tested now (or gone): "
                    f"remove the entry"
                )
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"rule tests OK — every one of {checked} alert rules is selected by a promtool test")
    return 0


def self_test() -> int:
    rules = ["groups:\n  - name: g\n    rules:\n      - alert: A\n        expr: up\n      - alert: B\n        expr: up\n"]
    cases = [
        ("a rule no test selects is reported", untested(rules, ["alertname: A\n"]), ["B"]),
        ("every rule selected is clean", untested(rules, ["alertname: A\n", "  alertname: B\n"]), []),
        ("a rule named only in a comment is not tested",
         untested(rules, ["alertname: A\n# B is tested elsewhere\n"]), ["B"]),
        ("a record: rule is not an alert", untested(["      - record: x\n        expr: up\n"], []), []),
    ]
    failed = 0
    for name, got, want in cases:
        ok = got == want
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} {name}" + ("" if ok else f" (got {got}, expected {want})"))
    return 1 if failed else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())
    sys.exit(main())
