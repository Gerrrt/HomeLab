#!/usr/bin/env python3
"""Find Loki rules that are blind to a host whose logs would have matched.

The failure this exists for is #261: five authentication rules that parsed,
loaded and matched nothing on two of four monitored hosts. `promtool`'s Loki
equivalent cannot see it — scripts/check_loki_rules.sh boots the pinned image
against a throwaway config with no data and asks the ruler whether the rules
parse, which is the right question for CI and a different question from this
one. So this runs against the LIVE Loki, on the monitoring host, and `make
validate` does not run it (#327).

The expectation is derived, not tabulated
-----------------------------------------
#327 called the expected set "the hard part", and it is: not every rule should
see every host — `useradd` will never match on `morpheus`, which is FreeBSD,
and the DHCP rules only ever see `morpheus` — so the obvious design is a
per-rule table of which hosts should report. A table like that drifts, and a
drifting table is exactly the class of defect this check exists to catch.

There is no table here. Two questions per rule, in this order:

  REACH       do the rule's own stream selectors, unioned across its `or`
              branches, reach every host that ships host logs at all? This is
              #261's own first measurement, and it is the load-bearing one: it
              holds whether or not anything has matched recently.

  SUBJECT     for a host the rule cannot reach, do lines matching what the rule
              is LOOKING FOR exist on that host anyway? This grades the gap —
              a rule blind to a host that is producing exactly the lines it
              hunts is a live hole; one blind to a host with nothing to see is
              latent.

"What the rule is looking for" is its POSITIVE line filters (`|~`, `|=`) with
its negative ones (`!=`, `!~`) dropped, and the distinction matters. The
negatives are the rule's policy — SshLoginFromUnexpectedSubnet excludes
`10.0.50.` and `10.0.99.` because a login from those is not interesting — while
the positives are its subject. Coverage asks whether the rule can SEE a host's
relevant lines, not whether it would fire on them today. Keeping the negatives
would have made this check pass over #261: with them, that rule matches nothing
anywhere, and "matches nothing" is indistinguishable from "matches nothing
here".

Verified against the rules as they stood BEFORE #261 was fixed, and after:

  before   selectors reach oracle, prometheus       -> FAIL, blind to Saruman
           subject lines on Saruman/journal 2,          and morpheus, which are
           morpheus/syslog 46                           producing 48 lines it
                                                        cannot see
  after    authlog OR journal OR syslog+app         -> PASS, all four hosts
           reach all four

The candidate selector, and why it is what it is
------------------------------------------------
    {log_type=~".+", log_type!="docker"}

Every source in alloy/config.alloy stamps a `log_type` — journal, authlog,
varlog, syslog — and alloy/docker.alloy stamps `log_type="docker"` on container
logs. So this reads "every host log source Alloy defines, and no container
logs". It is derived from how the estate is labelled rather than from a list
kept here, which is the same argument as the paragraph above.

It is NOT `{host=~".+"}`, and the difference is not cosmetic. #327 names the
trap: Loki's ruler logs its own query text at info level, so a selector that
reaches container logs matches the string of its own line filter. Measured here
over 7 days, for SudoFailure's pattern alone:

    {host=~".+"}                            43,913 lines
    {log_type=~".+", log_type!="docker"}         2 lines

30,365 of the difference is `log_type="docker"`, `service_name="loki"` — every
one of them the ruler or the query path quoting a rule back at itself. A check
counting those would report perfect coverage for a rule that sees nothing real.

The remaining 11,721 are why the selector requires `log_type` to be PRESENT
rather than only excluding docker. They are container logs from before a
labelling change, carrying `service_name="loki"` and no `log_type` at all, so
`log_type!="docker"` matches them — `!=` matches a stream where the label is
absent. They appear only in windows long enough to reach back past that change:
at 1h and 24h every matching stream carries `log_type="docker"`. Requiring the
label excludes them structurally rather than by knowing about them.

The cost of requiring it, stated plainly: a genuine host log arriving with no
`log_type` is invisible here. That is an Alloy misconfiguration rather than a
rule defect, and it is a different check from this one.

What is skipped, and named
--------------------------
Rules that do not aggregate `by (host)` — the firewall, DHCP and IDS groups, and
the `absent_over_time` watchdogs. They are scoped by `app` to a single device,
so "which hosts should report" is not a question they have. They are listed in
the output rather than passed over, because a check that silently examines four
of sixteen rules is worse than one that says so.

Usage: scripts/check_loki_coverage.py [--window 7d] [--url http://...] [STACK]
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

try:
    import yaml
except ModuleNotFoundError:
    import subprocess
    print("installing PyYAML", file=sys.stderr)
    if subprocess.run(
        [sys.executable, "-m", "pip", "install", "--quiet",
         "--disable-pip-version-check", "pyyaml"],
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

# See the module docstring. Changing this is changing what the check believes a
# host log is, so it is one constant with the reasoning above it rather than a
# string built somewhere in the query.
CANDIDATE_SELECTOR = '{log_type=~".+", log_type!="docker"}'

# A rule is host-scoped if it aggregates by host. That is the marker every
# host-scoped rule in this repository uses, and a rule that meant to be
# host-scoped without it could not label an alert with the host it fired for.
BY_HOST = re.compile(r"\bby\s*\(\s*host\b")


def split_fragments(expr: str) -> list[tuple[str, str]]:
    """Every count_over_time(...) in an expr, as (stream selector, pipeline).

    Scanning is string-aware because LogQL line filters are full regexes and
    routinely contain the very characters being balanced: the DHCP rules carry
    `[0-9a-f:]{17}` inside backticks, so a naive brace or bracket count reads
    the selector as ending in the middle of a regex. Backtick strings have no
    escape sequences in LogQL; double-quoted ones do.
    """
    fragments: list[tuple[str, str]] = []
    for match in re.finditer(r"count_over_time\s*\(", expr):
        body, depth, i = [], 1, match.end()
        quote = ""
        while i < len(expr) and depth:
            ch = expr[i]
            if quote:
                if quote == '"' and ch == "\\":
                    body.append(expr[i:i + 2]); i += 2; continue
                if ch == quote:
                    quote = ""
            elif ch in "`\"":
                quote = ch
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if not depth:
                    break
            body.append(ch)
            i += 1
        fragment = "".join(body)

        selector, pipeline = _split_selector(fragment)
        if selector:
            fragments.append((selector, pipeline))
    return fragments


def _split_selector(fragment: str) -> tuple[str, str]:
    """(stream selector, pipeline) for one count_over_time body.

    The pipeline is everything between the selector and the range — the `[5m]`
    is dropped here because the caller substitutes its own window, which is the
    whole point: a rule's 5-minute range answers "is this happening now", and
    coverage is a question about days.
    """
    start = fragment.find("{")
    if start < 0:
        return "", ""
    depth, quote, i = 0, "", start
    while i < len(fragment):
        ch = fragment[i]
        if quote:
            if quote == '"' and ch == "\\":
                i += 2; continue
            if ch == quote:
                quote = ""
        elif ch in "`\"":
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if not depth:
                break
        i += 1
    selector = fragment[start:i + 1]

    rest = fragment[i + 1:]
    # The range is the last bracketed group outside a string. Found by scanning
    # rather than by rpartition, for the same reason as above: `[0-9]{1,3}` in
    # a regex would otherwise be read as the range.
    quote, last_open = "", -1
    for j, ch in enumerate(rest):
        if quote:
            if quote == '"' and ch == "\\":
                continue
            if ch == quote:
                quote = ""
        elif ch in "`\"":
            quote = ch
        elif ch == "[":
            last_open = j
    pipeline = rest[:last_open] if last_open >= 0 else rest
    return selector, " ".join(pipeline.split())


def positive_filters(pipeline: str) -> str:
    """The rule's pipeline with its negative line filters dropped.

    `!=` and `!~` are the rule's policy, `|~` and `|=` are its subject. See the
    docstring: keeping the negatives makes a rule that currently matches
    nothing anywhere indistinguishable from one that is blind to a host, which
    is precisely the #261 case this has to be able to fail on.

    Split string-aware, because a filter's own regex can contain a `!`.
    """
    kept, quote, token = [], "", []
    i = 0
    while i < len(pipeline):
        ch = pipeline[i]
        if quote:
            token.append(ch)
            if quote == '"' and ch == "\\":
                token.append(pipeline[i + 1]); i += 2; continue
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch in "`\"":
            quote = ch
            token.append(ch)
            i += 1
            continue
        # A filter starts at |~ |= != !~ outside a string.
        if pipeline[i:i + 2] in ("|~", "|=", "!=", "!~"):
            if token:
                kept.append("".join(token))
            token = [pipeline[i:i + 2]]
            i += 2
            continue
        token.append(ch)
        i += 1
    if token:
        kept.append("".join(token))
    return " ".join(
        part.strip() for part in kept
        if part.strip() and not part.lstrip().startswith(("!=", "!~"))
    )


def query(url: str, logql: str) -> list[dict]:
    endpoint = f"{url.rstrip('/')}/loki/api/v1/query?" + urllib.parse.urlencode(
        {"query": logql}
    )
    try:
        with urllib.request.urlopen(endpoint, timeout=180) as response:
            payload = json.load(response)
    except urllib.error.URLError as exc:
        sys.exit(f"cannot reach Loki at {url}: {exc}")
    if payload.get("status") != "success":
        sys.exit(f"Loki rejected a query: {str(payload)[:300]}\n  {logql}")
    return payload["data"]["result"]


def hosts_with_logs(url: str, window: str) -> dict[str, int]:
    """Every host shipping host logs in the window — the denominator.

    Series without a `host` label are dropped rather than counted as a host:
    there are a handful, they are not a machine, and letting one through would
    make every rule fail against a host that does not exist.
    """
    found: dict[str, int] = {}
    logql = f"sum by (host) (count_over_time({CANDIDATE_SELECTOR} [{window}]))"
    for series in query(url, logql):
        host = series["metric"].get("host")
        if host:
            found[host] = int(float(series["value"][1]))
    return found


def selector_reach(
    url: str, fragments: list[tuple[str, str]], window: str
) -> dict[str, int]:
    """Hosts the rule's stream selectors reach, line filters removed.

    The filters are dropped on purpose. This is the question "can the rule see
    this host at all", which has an answer on a quiet week; "did the rule match
    something" does not.
    """
    found: dict[str, int] = {}
    for selector, _pipeline in fragments:
        logql = f"sum by (host) (count_over_time({selector} [{window}]))"
        for series in query(url, logql):
            host = series["metric"].get("host")
            if host:
                found[host] = found.get(host, 0) + int(float(series["value"][1]))
    return found


def subject_lines(
    url: str, fragments: list[tuple[str, str]], window: str
) -> dict[str, dict[str, int]]:
    """Hosts carrying lines the rule is looking for, under any host log source.

    The rule's stream selector is replaced and its positive filters kept, which
    is the whole trick: the filters are what the rule is looking FOR, the
    selector is only where it happens to be looking.
    """
    found: dict[str, dict[str, int]] = {}
    seen: set[str] = set()
    for _selector, pipeline in fragments:
        filters = positive_filters(pipeline)
        if filters in seen:
            # The `or` branches of a rule repeat one set of filters across
            # several selectors, so without this the same query runs three
            # times and the counts treble.
            continue
        seen.add(filters)
        logql = (
            f"sum by (host, log_type) "
            f"(count_over_time({CANDIDATE_SELECTOR} {filters} [{window}]))"
        )
        for series in query(url, logql):
            metric = series["metric"]
            host, log_type = metric.get("host"), metric.get("log_type", "?")
            if not host:
                continue
            by_type = found.setdefault(host, {})
            by_type[log_type] = (
                by_type.get(log_type, 0) + int(float(series["value"][1]))
            )
    return found


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("stack", nargs="?", default="observability")
    ap.add_argument("--url", default="http://127.0.0.1:3100", help="live Loki")
    ap.add_argument(
        "--window", default="7d",
        help="how far back to look (default 7d). Long enough that a quiet host "
             "is not mistaken for an unreachable one, short enough to stay "
             "inside the current labelling — see the docstring.",
    )
    args = ap.parse_args()

    rules_dir = REPO / "stacks" / args.stack / "loki" / "rules"
    files = sorted(rules_dir.glob("*.rules.yaml"))
    if not files:
        print(f"{args.stack}: no Loki rules — nothing to check")
        return 0

    print(f"{BLUE}--{RESET} asking {args.url} about the last {args.window}")
    estate = hosts_with_logs(args.url, args.window)
    if not estate:
        sys.exit(
            f"no host produced any log in {args.window} — either Loki is empty "
            f"or {CANDIDATE_SELECTOR} no longer describes how logs are "
            f"labelled. Either way this check cannot say anything, and saying "
            f"nothing is not the same as passing."
        )
    print(f"{BLUE}--{RESET} hosts shipping logs: "
          f"{', '.join(f'{h} ({n})' for h, n in sorted(estate.items()))}")

    checked = 0
    skipped: list[str] = []
    latent: list[str] = []
    live: list[str] = []

    for path in files:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        for group in document.get("groups") or []:
            for rule in group.get("rules") or []:
                name = rule.get("alert") or rule.get("record") or "<unnamed>"
                expr = rule.get("expr", "")

                if not BY_HOST.search(expr):
                    skipped.append(name)
                    continue
                fragments = split_fragments(expr)
                if not fragments:
                    skipped.append(name)
                    continue

                checked += 1
                reach = selector_reach(args.url, fragments, args.window)
                blind = sorted(set(estate) - set(reach))
                if not blind:
                    print(f"{GREEN}  PASS{RESET} {name}: reaches all "
                          f"{len(estate)} hosts")
                    continue

                # Only now is the second query worth making: it exists to grade
                # a gap, and there is no gap to grade unless the selectors
                # already missed a host.
                subject = subject_lines(args.url, fragments, args.window)
                for host in blind:
                    where = subject.get(host)
                    if where:
                        total = sum(where.values())
                        detail = ", ".join(
                            f"{lt} {n}" for lt, n in sorted(where.items())
                        )
                        live.append(f"{name}/{host}")
                        print(f"{RED}  FAIL{RESET} {name}: cannot see {host}, "
                              f"which has {total} line(s) it is looking for "
                              f"({detail})")
                    else:
                        latent.append(f"{name}/{host}")
                        print(f"{YELLOW}  WARN{RESET} {name}: cannot see {host} "
                              f"at all, though nothing there matches it today")

    if skipped:
        # Named, not counted away. A check that silently examined eight of
        # sixteen rules would be worse than one that says which eight.
        print(
            f"{YELLOW}  NOTE{RESET} not host-scoped, so not checked "
            f"({len(skipped)}): {', '.join(skipped)}"
        )

    if live:
        sys.stdout.flush()
        print(
            f"\n{len(live)} rule/host pair(s) where the lines exist and the "
            f"rule cannot see them: {', '.join(live)}",
            file=sys.stderr,
        )
        return 1

    # The counts are the point. "OK" over a rule set nothing matched would be
    # the same green line as "OK" over one every host exercised, and the
    # difference between them is the whole value of the run.
    print(
        f"\nLoki coverage OK — {checked} host-scoped rule(s) over "
        f"{args.window} against {len(estate)} host(s); no rule is blind to a "
        f"host that is producing lines it hunts. "
        f"{len(latent)} latent gap(s) warned, {len(skipped)} rule(s) not "
        f"host-scoped."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
