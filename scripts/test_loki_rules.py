#!/usr/bin/env python3
"""Behaviour tests for the Loki alerting rules: does each rule match what it should?

check_loki_rules.sh proves the LogQL parses, but not that it matches anything. A
regex that matches no line the device writes passes it, and the rule sits silent
forever. Loki has no `promtool test`, so this does the equivalent by hand (#843):

  1. boot the pinned Loki on the production config (loki_scratch_config.py);
  2. push each test's fixture lines, with timestamps, through the push API;
  3. run the rule's own `expr`, verbatim from loki/rules/, as an instant query at
     that test's evaluation instant, and compare the series that come back with
     the ones the test expects.

Each test gets its own evaluation instant, an hour apart, so one test's lines
fall outside the next one's window (the longest window here is 15m). The DHCP
rules look back 7 days, so their tests isolate by MAC address instead.

WHAT THIS DOES NOT TEST
  `for:`. An instant query is the expression, not the alert's pending period.
  The Prometheus rules' for-timing is promtool's job. Here a firing case means
  "the expression returns this series", which is the part a broken regex breaks.

  Alloy's labelling. Fixtures carry the labels Alloy attaches (app, action,
  interface, priority, ...), set by hand. That pipeline is config.alloy's
  concern; these tests start where it stops.

Tests live in stacks/<stack>/loki/tests/*.test.yaml:

  tests:
    - alert: SshBruteForceSevere          # must name a rule in loki/rules/
      name: 101 failures in five minutes fire
      streams:
        - labels: {log_type: authlog, host: oracle}
          entries:
            - before: 4m                  # this long before the evaluation instant
              count: 101                  # optional, default 1
              every: 1s                   # optional spacing, default 1s, forwards in time
              line: "Failed password for root from 203.0.113.7 port 52144 ssh2"
      expect:                             # the series the expression returns;
        - {host: oracle}                  # [] means it must return nothing

Coverage, checked before anything boots: every `severity: critical` rule has a
test. Every tested rule has at least one case that expects a series and one
that expects none. A test that can only ever expect silence passes against a
broken rule (the reasoning check_rule_tests.py applies to promtool).

Usage: test_loki_rules.py [--stack NAME] [--skips-file PATH] [--self-test]
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: python3 -m pip install pyyaml")

REPO = pathlib.Path(__file__).resolve().parent.parent
PORT = 3198
SLOT = 3600  # seconds between consecutive tests' evaluation instants
# reject_old_samples_max_age is 168h in loki-config.yaml. Stay well inside it,
# because a rejected push is a test that silently has no data.
MAX_LOOKBACK = 150 * 3600
REQUIRED_SEVERITY = "critical"

_DUR = re.compile(r"(\d+)([smhd])")
_UNIT = {"s": 1, "m": 60, "h": 3600, "d": 86400}


def parse_duration(text: str) -> int:
    """'90s', '4m', '2d', '1h30m' -> seconds. Anything else is an error."""
    text = str(text).strip()
    parts = _DUR.findall(text)
    if not parts or "".join(n + u for n, u in parts) != text:
        raise ValueError(f"not a duration: {text!r} (use s, m, h, d, e.g. 4m or 1h30m)")
    return sum(int(n) * _UNIT[u] for n, u in parts)


def expand(test: dict, eval_at: int) -> list[tuple[dict, int, str]]:
    """A test's streams as (labels, unix-seconds, line), every one at or before
    eval_at. Labels and lines are strings, because the push API takes nothing else."""
    out = []
    for stream in test.get("streams") or []:
        labels = {str(k): str(v) for k, v in (stream.get("labels") or {}).items()}
        if not labels:
            raise ValueError(f"{test['name']}: a stream needs at least one label")
        for e in stream.get("entries") or []:
            start = eval_at - parse_duration(e["before"])
            every = parse_duration(e.get("every", "1s"))
            for k in range(int(e.get("count", 1))):
                ts = start + k * every
                if ts > eval_at:
                    raise ValueError(
                        f"{test['name']}: entry {k + 1} of {e['line'][:40]!r} lands "
                        f"after the evaluation instant. Shorten count/every or raise before")
                out.append((labels, ts, str(e["line"])))
    return out


def label_sets(series: list[dict]) -> list[tuple]:
    """Order-free, comparable form of a list of label dicts."""
    return sorted(tuple(sorted((str(k), str(v)) for k, v in s.items() if k != "__name__"))
                  for s in series)


def coverage(rules: dict[str, dict], tests: list[dict]) -> list[str]:
    """Problems with WHICH rules are tested, before any of them is run."""
    problems = []
    kinds: dict[str, set[str]] = {}
    for t in tests:
        name = t.get("alert")
        if name not in rules:
            problems.append(f"test {t.get('name')!r} names {name!r}, which is no rule in loki/rules/")
            continue
        kinds.setdefault(name, set()).add("fires" if t.get("expect") else "quiet")
    for name, have in sorted(kinds.items()):
        for kind in ("fires", "quiet"):
            if kind not in have:
                problems.append(
                    f"{name} has no case where it {'returns a series' if kind == 'fires' else 'stays quiet'}. "
                    f"Each tested rule needs both, or a broken rule can still pass")
    for name, rule in sorted(rules.items()):
        if rule["severity"] == REQUIRED_SEVERITY and name not in kinds:
            problems.append(f"{name} is {REQUIRED_SEVERITY} and has no behaviour test")
    return problems


def load_rules(rules_dir: pathlib.Path) -> dict[str, dict]:
    rules = {}
    for f in sorted(rules_dir.glob("*.yaml")):
        for group in (yaml.safe_load(f.read_text(encoding="utf-8")) or {}).get("groups", []):
            for r in group.get("rules", []):
                if "alert" in r:
                    rules[r["alert"]] = {
                        "expr": r["expr"],
                        "severity": (r.get("labels") or {}).get("severity", ""),
                    }
    return rules


def load_tests(tests_dir: pathlib.Path) -> list[dict]:
    tests = []
    for f in sorted(tests_dir.glob("*.test.yaml")):
        for t in (yaml.safe_load(f.read_text(encoding="utf-8")) or {}).get("tests", []):
            t["_file"] = f.name
            tests.append(t)
    return tests


# ---------------------------------------------------------------------------
# Talking to Loki
# ---------------------------------------------------------------------------
def http(path: str, data: bytes | None = None, params: dict | None = None) -> tuple[int, str]:
    url = f"http://127.0.0.1:{PORT}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
        return 0, str(e)


def selector(labels: dict) -> str:
    return "{" + ",".join(f'{k}="{v}"' for k, v in sorted(labels.items())) + "}"


def push(entries: list[tuple[dict, int, str]]) -> None:
    """One request, each stream's lines in time order. Loki rejects an entry
    too far behind its stream's newest one, and several tests share a stream
    ({app="kea-dhcp4"} carries every DHCP test). Oldest-first per stream keeps
    every entry the newest at the moment it lands."""
    streams: dict[tuple, list] = {}
    for labels, ts, line in entries:
        streams.setdefault(tuple(sorted(labels.items())), []).append((ts, line))
    body = {"streams": [
        {"stream": dict(key), "values": [[str(ts * 10**9 + i), line]
                                         for i, (ts, line) in enumerate(sorted(vals))]}
        for key, vals in streams.items()]}
    code, text = http("/loki/api/v1/push", json.dumps(body).encode())
    if code not in (200, 204):
        raise RuntimeError(f"push refused ({code}): {text[:500]}")


def instant(query: str, at: int) -> list[dict]:
    code, text = http("/loki/api/v1/query", params={"query": query, "time": str(at)})
    if code != 200:
        raise RuntimeError(f"query refused ({code}): {text[:500]}")
    data = json.loads(text)["data"]
    if data["resultType"] != "vector":
        raise RuntimeError(f"expected a vector, got {data['resultType']}")
    return [s["metric"] for s in data["result"]]


def barrier(entries: list[tuple[dict, int, str]], now: int, log: pathlib.Path) -> None:
    """Wait until every pushed line is queryable. Without this, a quiet case
    evaluated before ingestion caught up would pass over data it never saw.

    On timeout it reports every stream, not the first short one, with each
    stream's age, plus Loki's own warnings. "0 of 3" alone did not say whether
    the push, the flush or the query lost the lines."""
    want: dict[tuple, int] = {}
    oldest: dict[tuple, int] = {}
    for labels, ts, _ in entries:
        key = tuple(sorted(labels.items()))
        want[key] = want.get(key, 0) + 1
        oldest[key] = min(oldest.get(key, ts), ts)

    def count(key: tuple) -> int:
        span = (now - oldest[key]) // 3600 + 2
        q = f"sum(count_over_time({selector(dict(key))}[{span}h]))"
        code, text = http("/loki/api/v1/query", params={"query": q, "time": str(now)})
        if code != 200:
            return -1
        res = json.loads(text)["data"]["result"]
        return int(float(res[0]["value"][1])) if res else 0

    deadline = time.time() + 60
    while True:
        got = {key: count(key) for key in want}
        if got == want:
            return
        if time.time() > deadline:
            short = [f"{selector(dict(k))} (oldest {(now - oldest[k]) / 3600:.1f}h): "
                     f"{got[k]} of {n}" for k, n in want.items() if got[k] != n]
            noise = [l for l in log.read_text(errors="replace").splitlines()
                     if re.search(r"level=(warn|error)", l)][-10:]
            raise RuntimeError(
                f"{len(short)} of {len(want)} stream(s) not fully queryable after 60s:\n        "
                + "\n        ".join(short)
                + ("\n      loki warnings:\n        " + "\n        ".join(noise) if noise else ""))
        time.sleep(2)


def boot(stack: pathlib.Path, work: pathlib.Path) -> tuple[subprocess.Popen, list[str]]:
    (work / "rules" / "fake").mkdir(parents=True)
    (work / "data").mkdir()
    cfg = subprocess.run(
        [sys.executable, str(REPO / "scripts/loki_scratch_config.py"),
         str(stack / "loki/loki-config.yaml"), str(work), "--for-tests"],
        check=True, capture_output=True, text=True).stdout
    (work / "loki.yaml").write_text(cfg)
    os.chmod(work, 0o777)
    for p in work.rglob("*"):
        os.chmod(p, 0o777)
    args = [f"-config.file={work}/loki.yaml", "-target=all", f"-server.http-listen-port={PORT}"]
    cleanup: list[str] = []
    if shutil.which("loki"):
        proc = subprocess.Popen(["loki", *args], stdout=open(work / "loki.log", "w"),
                                stderr=subprocess.STDOUT)
    else:
        # This stack's pin, not observability's: image-for.sh falls back to
        # stacks/observability/compose.yaml unless told otherwise.
        image = subprocess.run([str(REPO / "scripts/image-for.sh"), "loki"],
                               env={**os.environ, "COMPOSE_FILE": str(stack / "compose.yaml")},
                               check=True, capture_output=True, text=True).stdout.strip()
        name = f"loki-rule-tests-{os.getpid()}"
        cleanup = ["docker", "rm", "-f", name]
        proc = subprocess.Popen(
            ["docker", "run", "--rm", "--name", name, "--user", f"{os.getuid()}:{os.getgid()}",
             "-p", f"127.0.0.1:{PORT}:{PORT}", "-v", f"{work}:{work}", "-w", str(work),
             "--entrypoint", "loki", image, *args],
            stdout=open(work / "loki.log", "w"), stderr=subprocess.STDOUT)
    deadline = time.time() + 120
    while True:
        code, text = http("/ready")
        if code == 200 and text.strip() == "ready":
            return proc, cleanup
        if proc.poll() is not None or time.time() > deadline:
            tail = (work / "loki.log").read_text(errors="replace").splitlines()[-15:]
            raise RuntimeError("loki did not become ready:\n        " + "\n        ".join(tail))
        time.sleep(1)


# ---------------------------------------------------------------------------
def run(stack_name: str, skips_file: str | None) -> int:
    stack = REPO / "stacks" / stack_name
    # Before the no-rules fast path: a mistyped --stack has no loki/rules
    # either, and must not read as a stack that passed with nothing to test.
    if not (stack / "compose.yaml").is_file():
        print(f"\033[0;31m  FAIL\033[0m no such stack: {stack_name} (no {stack}/compose.yaml)",
              file=sys.stderr)
        return 1
    rules_dir, tests_dir = stack / "loki/rules", stack / "loki/tests"
    if not rules_dir.is_dir():
        print(f"\033[0;32m  PASS\033[0m {stack_name}: no Loki rules, nothing to test")
        return 0
    rules, tests = load_rules(rules_dir), load_tests(tests_dir)

    problems = coverage(rules, tests)
    base = (int(time.time()) // 60) * 60 - 300
    plan = []
    for i, t in enumerate(tests):
        at = base - i * SLOT
        try:
            entries = expand(t, at)
        except (KeyError, ValueError) as e:
            problems.append(f"{t.get('_file')}: {e}")
            continue
        if entries and base - min(ts for _, ts, _ in entries) > MAX_LOOKBACK:
            problems.append(f"{t['name']}: reaches more than {MAX_LOOKBACK // 3600}h back, "
                            f"past what Loki accepts (reject_old_samples_max_age)")
        plan.append((t, at, entries))
    if problems:
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        print(f"\033[0;31m  FAIL\033[0m {len(problems)} problem(s) in the Loki rule tests", file=sys.stderr)
        return 1

    if not shutil.which("loki") and not (
            shutil.which("docker") and subprocess.run(["docker", "info"], capture_output=True).returncode == 0):
        msg = "no loki binary and no docker daemon: Loki rule behaviour tests not run"
        print(f"\033[0;33m  SKIP\033[0m {msg}")
        if skips_file:
            with open(skips_file, "a") as f:
                f.write(msg + "\n")
        return 0

    work = pathlib.Path(tempfile.mkdtemp())
    proc, cleanup = None, []
    failed = 0
    try:
        proc, cleanup = boot(stack, work)
        everything = [e for _, _, entries in plan for e in entries]
        push(everything)
        barrier(everything, base + 60, work / "loki.log")
        for t, at, _ in plan:
            got = label_sets(instant(rules[t["alert"]]["expr"], at))
            want = label_sets(t.get("expect") or [])
            ok = got == want
            failed += not ok
            verdict = "\033[0;32mPASS\033[0m" if ok else "\033[0;31mFAIL\033[0m"
            print(f"  {verdict} {t['alert']}: {t['name']}")
            if not ok:
                print(f"        expected {[dict(s) for s in want] or 'no series'}\n"
                      f"        got      {[dict(s) for s in got] or 'no series'}")
    except RuntimeError as e:
        print(f"\033[0;31m  FAIL\033[0m {e}", file=sys.stderr)
        return 1
    finally:
        if cleanup:
            subprocess.run(cleanup, capture_output=True)
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        shutil.rmtree(work, ignore_errors=True)

    tested = sorted({t["alert"] for t, _, _ in plan})
    untested = sorted(set(rules) - set(tested))
    print(f"\033[0;{'31' if failed else '32'}m  {'FAIL' if failed else 'PASS'}\033[0m "
          f"{len(plan) - failed}/{len(plan)} Loki rule test(s) over {len(tested)} rule(s); "
          f"{len(untested)} rule(s) untested, none of them {REQUIRED_SEVERITY}")
    return 1 if failed else 0


def self_test() -> int:
    rules = {"Crit": {"expr": "x", "severity": "critical"},
             "Warn": {"expr": "x", "severity": "warning"}}
    both = [{"alert": "Crit", "name": "a", "expect": [{"h": "x"}]},
            {"alert": "Crit", "name": "b", "expect": []}]
    t = {"name": "t", "streams": [{"labels": {"a": 1},
                                   "entries": [{"before": "4m", "count": 3, "every": "10s", "line": "l"}]}]}
    cases = [
        ("durations parse, compound ones too", parse_duration("1h30m") == 5400 and parse_duration("2d") == 172800),
        ("a bare number is not a duration", _raises(lambda: parse_duration("90"))),
        ("entries expand forwards from `before`, labels as strings",
         expand(t, 1000) == [({"a": "1"}, 760, "l"), ({"a": "1"}, 770, "l"), ({"a": "1"}, 780, "l")]),
        ("an entry past the evaluation instant is refused",
         _raises(lambda: expand({**t, "streams": [{"labels": {"a": 1}, "entries": [
             {"before": "5s", "count": 10, "line": "l"}]}]}, 1000))),
        ("label sets compare without order, and ignore __name__",
         label_sets([{"b": "2", "a": "1", "__name__": "x"}]) == label_sets([{"a": "1", "b": "2"}])),
        ("a critical rule tested both ways is covered", coverage(rules, both) == []),
        ("an untested critical rule fails coverage", len(coverage(rules, [])) == 1),
        ("a tested rule with only a quiet case fails coverage", len(coverage(rules, both[1:])) == 1),
        ("a tested rule with only a firing case fails coverage", len(coverage(rules, both[:1])) == 1),
        ("an untested warning rule is allowed", not any("Warn" in p for p in coverage(rules, both))),
        ("a test naming no rule fails coverage",
         any("no rule" in p for p in coverage(rules, both + [{"alert": "Gone", "name": "g", "expect": []}]))),
    ]
    failed = 0
    for name, ok in cases:
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} {name}")
    return 1 if failed else 0


def _raises(fn) -> bool:
    try:
        fn()
    except (ValueError, KeyError):
        return True
    return False


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return self_test()
    stack, skips = "observability", None
    it = iter(argv)
    for a in it:
        if a == "--stack":
            stack = next(it)
        elif a == "--skips-file":
            skips = next(it)
        else:
            print(f"unknown argument: {a}", file=sys.stderr)
            return 2
    return run(stack, skips)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
