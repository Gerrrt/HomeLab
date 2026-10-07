#!/usr/bin/env python3
"""Watch ADR-0089's triggers for leaving Wiki.js 2.x, weekly, off-host.

WHAT THIS IS FOR. ADR-0089 keeps the household wiki on Wiki.js 2.x until one
of three triggers fires:

  1. a published `requarks/wiki` advisory affects the pinned version and has no
     2.x fix 30 days after publication;
  2. no 2.x release for six months;
  3. 3.0 reaches a stable release.

Nothing read the project's own advisories. The weekly CVE scan reads the
image's packages, a different list. And an advisory that is never fixed
produces neither a release nor a pin bump, so nothing would ever have
prompted a reading. This is that reading, every Monday.

WHAT IT REPORTS, in the job summary and in one issue (`security`, `wiki`):

  * an advisory that affects the pin and HAS a fix: bump the pin. Not a
    trigger: the fix exists, and Dependabot or a person should take it.
  * an advisory that affects the pin with NO 2.x fix: the trigger 1 clock,
    in days, and FIRED from day 30;
  * an advisory whose version range this cannot read: a person reads it.
    Never silently passed;
  * trigger 2 and trigger 3 when they fire.

The issue is created when there is something to report, rewritten each week,
and closed by the run that finds nothing. It is keyed on a hidden marker.

THE RANGES ARE UPSTREAM'S, AND MESSY. Seen in the real list: `<2.5.314`,
`<= v2.5.314`, a bare `2.5.303`, `>=2.5.80 <2.5.151`, and `> 2.4.17` patched
in 2.4.107, which read literally flags every later 2.x. So the order is:
  - a listed patched version at or below the pin means the pin carries the
    fix;
  - only otherwise is the range asked;
  - and a range this cannot parse is reported for a person to read, not
    guessed at.

A failure to read the advisories or the releases fails the run. A finding
does not: the issue is the notification, as in cve-scan.yml.

Usage: scripts/wiki_watch.py                    summary to stdout
       scripts/wiki_watch.py --sync-issue       also create/edit/close the issue
       scripts/wiki_watch.py --sync-issue --dry-run
       scripts/wiki_watch.py --self-test

Environment:
  GH_TOKEN              for the API reads and --sync-issue (issues: write)
  GITHUB_REPOSITORY     the repo the issue lives in (default Gerrrt/HomeLab)
  GITHUB_SERVER_URL, GITHUB_RUN_ID   link the issue to the run that wrote it
"""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass, field

RED = "\033[0;31m"
GREEN = "\033[0;32m"
OFF = "\033[0m"

UPSTREAM = "requarks/wiki"
COMPOSE = pathlib.Path(__file__).resolve().parent.parent / "stacks" / "wiki" / "compose.yaml"
PIN = re.compile(r"image:\s*ghcr\.io/requarks/wiki:v?(\d+\.\d+\.\d+)@sha256:")
MARKER = "<!-- wiki-watch: requarks/wiki -->"
CLOCK_DAYS = 30  # ADR-0089 trigger 1
STALE_DAYS = 183  # ADR-0089 trigger 2, six months
VERSION = re.compile(r"v?(\d+)\.(\d+)\.(\d+)")
STABLE_3 = re.compile(r"^v?3\.\d+\.\d+$")
TWO_X = re.compile(r"^v?2\.\d+\.\d+$")
CLAUSE = re.compile(r"(<=|>=|<|>|=)?\s*v?(\d+\.\d+\.\d+)")


def ver(text: str) -> tuple[int, int, int] | None:
    m = VERSION.fullmatch(text.strip())
    return (int(m[1]), int(m[2]), int(m[3])) if m else None


def in_range(pin: tuple[int, int, int], spec: str) -> bool | None:
    """True/False for a range this can read, None for one it cannot.

    Clauses are ANDed, separated by commas or spaces. A bare version is an exact
    match, as in the real `2.5.303`.
    """
    spec = spec.strip()
    if not spec:
        return None
    clauses = CLAUSE.findall(spec)
    # Everything in the range must be a clause: refuse a range with leftover text
    # (`all`, `*`, an `||`) rather than ignore the part that was not understood.
    if not clauses or re.sub(r"[\s,]", "", CLAUSE.sub("", spec)):
        return None
    for op, v in clauses:
        bound = ver(v)
        if bound is None:
            return None
        ok = {
            "<": pin < bound,
            "<=": pin <= bound,
            ">": pin > bound,
            ">=": pin >= bound,
            "=": pin == bound,
            "": pin == bound,
        }[op]
        if not ok:
            return False
    return True


@dataclass
class Finding:
    ghsa: str
    severity: str
    published: dt.datetime
    url: str
    summary: str
    kind: str  # "bump", "clock", "fired", "unreadable"
    detail: str = ""
    age_days: int = 0


@dataclass
class Report:
    pin: str
    findings: list[Finding] = field(default_factory=list)
    latest_2x: tuple[str, dt.datetime] | None = None
    stable_3: str | None = None
    stale: bool = False

    @property
    def anything(self) -> bool:
        return bool(self.findings or self.stale or self.stable_3)


def parse_time(text: str) -> dt.datetime:
    return dt.datetime.fromisoformat(text)


def assess(pin_text: str, advisories: list[dict], releases: list[dict], now: dt.datetime) -> Report:
    pin = ver(pin_text)
    if pin is None:
        raise ValueError(f"pinned version {pin_text!r} is not x.y.z")
    report = Report(pin=pin_text)
    for a in advisories:
        published = parse_time(a["published_at"])
        age = (now - published).days
        base = {
            "ghsa": a.get("ghsa_id", "?"),
            "severity": a.get("severity") or "unknown",
            "published": published,
            "url": a.get("html_url", ""),
            "summary": a.get("summary", ""),
            "age_days": age,
        }
        for v in a.get("vulnerabilities") or []:
            patched = [p for p in (ver(x) for x in re.split(r"[,\s]+", v.get("patched_versions") or "") if x) if p]
            if any(p <= pin for p in patched):
                continue  # the pin carries a listed fix
            hit = in_range(pin, v.get("vulnerable_version_range") or "")
            if hit is False:
                continue
            if hit is None:
                report.findings.append(
                    Finding(**base, kind="unreadable", detail=f"range `{v.get('vulnerable_version_range')}`")
                )
                continue
            fix_2x = sorted(p for p in patched if p[0] == 2 and p > pin)
            if fix_2x:
                report.findings.append(Finding(**base, kind="bump", detail="fixed in " + ".".join(map(str, fix_2x[0]))))
            else:
                report.findings.append(Finding(**base, kind="fired" if age >= CLOCK_DAYS else "clock"))
            break  # one finding per advisory
    for r in releases:
        tag = r.get("tag_name", "")
        if r.get("draft") or not r.get("published_at"):
            continue
        when = parse_time(r["published_at"])
        if TWO_X.match(tag) and (report.latest_2x is None or when > report.latest_2x[1]):
            report.latest_2x = (tag, when)
        if STABLE_3.match(tag) and not r.get("prerelease"):
            report.stable_3 = report.stable_3 or tag
    if report.latest_2x is None or (now - report.latest_2x[1]).days >= STALE_DAYS:
        report.stale = True
    return report


def render(report: Report, now: dt.datetime) -> str:
    out = [f"## Wiki.js: ADR-0089's triggers, against the pinned {report.pin}", ""]
    labels = {
        "fired": "**Trigger 1 FIRED**: no 2.x fix after 30 days",
        "clock": "Trigger 1 clock running: no 2.x fix yet",
        "bump": "Affects the pin, and a 2.x fix exists: bump the pin",
        "unreadable": "Range not understood: read it",
    }
    if report.findings:
        out += ["| Advisory | Severity | Published | Days | State |", "| --- | --- | --- | --- | --- |"]
        for f in sorted(report.findings, key=lambda f: f.published):
            state = labels[f.kind] + (f" ({f.detail})" if f.detail else "")
            out.append(
                f"| [{f.ghsa}]({f.url}) {f.summary} | {f.severity} | {f.published:%Y-%m-%d} | {f.age_days} | {state} |"
            )
    else:
        out.append(f"No published `{UPSTREAM}` advisory affects {report.pin}.")
    out.append("")
    if report.latest_2x:
        tag, when = report.latest_2x
        days = (now - when).days
        line = f"Latest 2.x release: `{tag}`, {when:%Y-%m-%d}, {days} days ago."
        out.append(line + (" **Trigger 2 FIRED**: six months without a 2.x release." if report.stale else ""))
    else:
        out.append("**Trigger 2 FIRED**: no 2.x release was found at all.")
    if report.stable_3:
        out.append(f"**Trigger 3 FIRED**: `{report.stable_3}` is a stable 3.x release.")
    out += [
        "",
        ("When a trigger fires, the move is its own issue, with a restore rehearsal (ADR-0089, Consequences)."),
    ]
    return "\n".join(out) + "\n"


def gh(*args: str, stdin: str | None = None) -> str:
    proc = subprocess.run(["gh", *args], input=stdin, text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        sys.exit(f"{RED}error:{OFF} gh {' '.join(args[:2])} failed: {proc.stderr.strip()}")
    return proc.stdout


def fetch() -> tuple[list[dict], list[dict]]:
    # One object per line from `--jq '.[]'`, which works on any gh; --slurp is
    # newer than some hosts' gh.
    def every(endpoint: str) -> list[dict]:
        out = gh("api", "--paginate", "--jq", ".[]", endpoint)
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    return (
        every(f"repos/{UPSTREAM}/security-advisories?state=published&per_page=100"),
        every(f"repos/{UPSTREAM}/releases?per_page=100"),
    )


def title(report: Report) -> str:
    fired = [f for f in report.findings if f.kind == "fired"]
    if fired or report.stale or report.stable_3:
        return "Wiki.js: an ADR-0089 trigger has fired"
    return f"Wiki.js {report.pin}: advisories to act on"


def sync(report: Report, body: str, dry_run: bool) -> None:
    repo = os.environ.get("GITHUB_REPOSITORY", "Gerrrt/HomeLab")
    run = ""
    if os.environ.get("GITHUB_RUN_ID"):
        run = f"\n\nWritten by {os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}."
    full = f"{MARKER}\n{body}{run}"
    issues = json.loads(
        gh("issue", "list", "-R", repo, "--state", "open", "--label", "wiki", "--limit", "200", "--json", "number,body")
    )
    mine = [i for i in issues if MARKER in (i.get("body") or "")]
    if report.anything:
        if mine:
            print(f"edit #{mine[0]['number']}")
            if not dry_run:
                gh(
                    "issue",
                    "edit",
                    str(mine[0]["number"]),
                    "-R",
                    repo,
                    "--title",
                    title(report),
                    "--body-file",
                    "-",
                    stdin=full,
                )
        else:
            print("create")
            if not dry_run:
                gh(
                    "issue",
                    "create",
                    "-R",
                    repo,
                    "--title",
                    title(report),
                    "--label",
                    "security",
                    "--label",
                    "wiki",
                    "--body-file",
                    "-",
                    stdin=full,
                )
    elif mine:
        print(f"close #{mine[0]['number']}")
        if not dry_run:
            gh(
                "issue",
                "close",
                str(mine[0]["number"]),
                "-R",
                repo,
                "--comment",
                "Nothing to report against the pinned version this week.",
            )


def self_test() -> int:
    fail = 0

    def check(name: str, got, want) -> None:
        nonlocal fail
        ok = got == want
        fail += not ok
        print(
            f"  {GREEN + 'PASS' if ok else RED + 'FAIL'}{OFF} {name}"
            + ("" if ok else f"\n       got {got!r}, want {want!r}")
        )

    pin = (2, 5, 316)
    # Every range shape in requarks/wiki's real list, 2026-10-07.
    check("<2.5.314 excludes a later pin", in_range(pin, "<2.5.314"), False)
    check("<= v2.5.314 reads the v", in_range((2, 5, 314), "<= v2.5.314"), True)
    check("a bare version is exact", in_range((2, 5, 303), "2.5.303"), True)
    check("a bare version is not a floor", in_range(pin, "2.5.303"), False)
    check("two clauses are ANDed", in_range((2, 5, 100), ">=2.5.80 <2.5.151"), True)
    check("and both must hold", in_range(pin, ">=2.5.80 <2.5.151"), False)
    check("a comma separates clauses too", in_range((2, 5, 100), ">= 2.5.80, < 2.5.151"), True)
    check("an open range matches, read literally", in_range(pin, "> 2.4.17"), True)
    check("text it does not understand is unreadable", in_range(pin, "all versions"), None)
    check("a wildcard is unreadable", in_range(pin, "*"), None)
    check("an empty range is unreadable", in_range(pin, ""), None)
    check("an alternative is unreadable, not half-read", in_range(pin, "<2.5.100 || >2.6.0"), None)

    now = dt.datetime(2026, 10, 7, tzinfo=dt.UTC)

    def adv(ghsa, published, rng, patched):
        return {
            "ghsa_id": ghsa,
            "published_at": published,
            "severity": "high",
            "html_url": f"https://github.com/{UPSTREAM}/security/advisories/{ghsa}",
            "summary": ghsa,
            "vulnerabilities": [{"vulnerable_version_range": rng, "patched_versions": patched}],
        }

    releases = [
        {"tag_name": "v2.5.316", "published_at": "2026-09-28T00:00:00Z", "prerelease": False},
        {"tag_name": "3.0.0-beta.628", "published_at": "2026-10-04T00:00:00Z", "prerelease": False},
    ]
    real = [
        adv("GHSA-old-open", "2022-01-01T00:00:00Z", "> 2.4.17", "2.4.107"),
        adv("GHSA-fixed", "2026-09-21T07:51:15Z", "<2.5.314", "2.5.315"),
        adv("GHSA-exact", "2024-09-18T00:00:00Z", "2.5.303", "2.5.304"),
    ]
    r = assess("2.5.316", real, releases, now)
    check("today's real list affects 2.5.316 with nothing", [f.ghsa for f in r.findings], [])
    check("the open-ended range is answered by its patched version", r.anything, False)
    check("a 3.0 beta is not trigger 3, even unmarked as prerelease", r.stable_3, None)
    check("a 2.x release nine days ago is not trigger 2", r.stale, False)

    r = assess("2.5.316", [adv("GHSA-new", "2026-09-30T00:00:00Z", "<= 2.5.316", "")], releases, now)
    check("an unfixed advisory at 7 days runs the clock", [(f.kind, f.age_days) for f in r.findings], [("clock", 7)])
    r = assess("2.5.316", [adv("GHSA-new", "2026-09-01T00:00:00Z", "<= 2.5.316", "")], releases, now)
    check("at 36 days trigger 1 has fired", [f.kind for f in r.findings], ["fired"])
    r = assess("2.5.316", [adv("GHSA-3only", "2026-08-01T00:00:00Z", "<= 2.5.316", "3.0.1")], releases, now)
    check("a fix only in 3.x is no 2.x fix", [f.kind for f in r.findings], ["fired"])
    r = assess("2.5.316", [adv("GHSA-bump", "2026-08-01T00:00:00Z", "<= 2.5.316", "2.5.317")], releases, now)
    check(
        "a 2.x fix above the pin is a bump, not a trigger",
        [(f.kind, f.detail) for f in r.findings],
        [("bump", "fixed in 2.5.317")],
    )
    r = assess("2.5.316", [adv("GHSA-odd", "2026-08-01T00:00:00Z", "every release", "")], releases, now)
    check("an unreadable range is reported, not passed", [f.kind for f in r.findings], ["unreadable"])

    old = [{"tag_name": "v2.5.316", "published_at": "2026-03-01T00:00:00Z", "prerelease": False}]
    check("220 days without a 2.x release is trigger 2", assess("2.5.316", [], old, now).stale, True)
    check("no 2.x release at all is trigger 2", assess("2.5.316", [], [], now).stale, True)
    ga = releases + [{"tag_name": "v3.0.0", "published_at": "2026-10-05T00:00:00Z", "prerelease": False}]
    check("a stable v3.0.0 is trigger 3", assess("2.5.316", [], ga, now).stable_3, "v3.0.0")
    pre = releases + [{"tag_name": "v3.0.0", "published_at": "2026-10-05T00:00:00Z", "prerelease": True}]
    check("a v3.0.0 marked prerelease is not", assess("2.5.316", [], pre, now).stable_3, None)

    text = COMPOSE.read_text() if COMPOSE.exists() else ""
    check("the pin is read from stacks/wiki/compose.yaml", bool(PIN.search(text)), True)

    print(f"{fail} failed" if fail else "all cases held")
    return 1 if fail else 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return self_test()
    m = PIN.search(COMPOSE.read_text())
    if not m:
        sys.exit(f"{RED}error:{OFF} no ghcr.io/requarks/wiki:x.y.z@sha256 pin in {COMPOSE}")
    now = dt.datetime.now(dt.UTC)
    advisories, releases = fetch()
    report = assess(m[1], advisories, releases, now)
    body = render(report, now)
    print(body)
    if "--sync-issue" in argv:
        sync(report, body, "--dry-run" in argv)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
