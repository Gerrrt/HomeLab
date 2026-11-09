#!/usr/bin/env python3
"""Read requarks/wiki's own advisories against the pinned Wiki.js, weekly.

WHAT THIS IS FOR. The weekly CVE scan reads the image's packages. That is a
different list from the project's own security advisories, and an advisory
that is never fixed produces neither a release nor a pin bump, so nothing
would ever prompt a reading of it. This is that reading, every Monday.

It began as the watch on ADR-0089's three triggers for leaving Wiki.js 2.x.
Trigger 3 fired on 2026-11-01 and the wiki moved to 3.x (#1339), so triggers
2 and 3, which were about the 2.x line, are gone. The advisory reading stays,
against whichever line the pin is on. A "line" is the pin's major version.

WHAT IT REPORTS, in the job summary and in one issue (`security`, `wiki`):

  * an advisory that affects the pin and HAS a fix on the pin's line: bump
    the pin. Dependabot or a person should take it;
  * an advisory that affects the pin with NO fix on its line: unfixed, with
    its age in days, and OVERDUE from day 30. Overdue is ADR-0089's old
    trigger-1 clock, kept as a prompt: an advisory nobody fixes in a month is
    a decision for a person, not a wait;
  * an advisory whose version range this cannot read: a person reads it.
    Never silently passed.

The issue is created when there is something to report, rewritten each week,
and closed by the run that finds nothing. It is keyed on a hidden marker.

THE RANGES ARE UPSTREAM'S, AND MESSY. Seen in the real list: `<2.5.314`,
`<= v2.5.314`, a bare `2.5.303`, `>=2.5.80 <2.5.151`, and `> 2.4.17` patched
in 2.4.107, which read literally flags every later version. So the order is:
  - a listed patched version on the pin's line, at or below the pin, means
    the pin carries the fix;
  - only otherwise is the range asked;
  - and a range this cannot parse is reported for a person to read, not
    guessed at.

A failure to read the advisories fails the run. A finding does not: the issue
is the notification, as in cve-scan.yml.

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
import urllib.request
from dataclasses import dataclass, field

RED = "\033[0;31m"
GREEN = "\033[0;32m"
OFF = "\033[0m"

UPSTREAM = "requarks/wiki"
COMPOSE = pathlib.Path(__file__).resolve().parent.parent / "stacks" / "wiki" / "compose.yaml"
PIN = re.compile(r"image:\s*ghcr\.io/requarks/wiki:v?(\d+\.\d+\.\d+)@sha256:")
MARKER = "<!-- wiki-watch: requarks/wiki -->"
OVERDUE_DAYS = 30  # ADR-0089's trigger-1 clock, kept as a prompt
VERSION = re.compile(r"v?(\d+)\.(\d+)\.(\d+)")
CLAUSE = re.compile(r"(<=|>=|<|>|=)?\s*v?(\d+\.\d+\.\d+)")


def ver(text: str) -> tuple[int, int, int] | None:
    m = VERSION.fullmatch(text.strip())
    return (int(m[1]), int(m[2]), int(m[3])) if m else None


def open_ended(spec: str) -> bool:
    """A range that is only lower bounds (`> 2.4.17`, `>=2.0.0`), and nothing
    else: a range with text in_range() cannot read (`> 2.4.17 || >= 3.0.0`)
    is not open-ended, it is unreadable, and goes to a person."""
    if in_range((0, 0, 0), spec) is None:
        return False
    clauses = CLAUSE.findall(spec)
    return bool(clauses) and all(op in (">", ">=") for op, _ in clauses)


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
    kind: str  # "bump", "unfixed", "overdue", "unreadable"
    detail: str = ""
    age_days: int = 0


@dataclass
class Report:
    pin: str
    findings: list[Finding] = field(default_factory=list)

    @property
    def anything(self) -> bool:
        return bool(self.findings)


def parse_time(text: str) -> dt.datetime:
    return dt.datetime.fromisoformat(text)


def assess(pin_text: str, advisories: list[dict], now: dt.datetime) -> Report:
    pin = ver(pin_text)
    if pin is None:
        raise ValueError(f"pinned version {pin_text!r} is not x.y.z")
    line = pin[0]
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
            rng = v.get("vulnerable_version_range") or ""
            # On the pin's own line, a fix at or below the pin is carried. A
            # fix on an older line in general is not: 3.x is not 2.x with
            # patches on top. The exception is a range with no upper bound,
            # `> 2.4.17` patched in 2.4.107: written before the pin's line
            # existed, its patched version is the real bound, and read
            # literally it would flag every later release forever. Only when
            # every patched version is on an older line: one on the pin's
            # line or later says the advisory was written for it.
            if any(p[0] == line and p <= pin for p in patched):
                continue
            if open_ended(rng) and patched and all(p[0] < line for p in patched):
                continue
            hit = in_range(pin, rng)
            if hit is False:
                continue
            if hit is None:
                report.findings.append(
                    Finding(**base, kind="unreadable", detail=f"range `{v.get('vulnerable_version_range')}`")
                )
                continue
            fix_here = sorted(p for p in patched if p[0] == line and p > pin)
            if fix_here:
                report.findings.append(
                    Finding(**base, kind="bump", detail="fixed in " + ".".join(map(str, fix_here[0])))
                )
            else:
                later = sorted(p for p in patched if p[0] > line)
                detail = ("fixed only in " + ".".join(map(str, later[0]))) if later else ""
                report.findings.append(
                    Finding(**base, kind="overdue" if age >= OVERDUE_DAYS else "unfixed", detail=detail)
                )
            break  # one finding per advisory
    return report


def render(report: Report, now: dt.datetime) -> str:
    line = report.pin.split(".")[0]
    out = [f"## Wiki.js: `{UPSTREAM}`'s advisories, against the pinned {report.pin}", ""]
    labels = {
        "overdue": f"**OVERDUE**: no {line}.x fix after {OVERDUE_DAYS} days, a decision for a person",
        "unfixed": f"Unfixed: no {line}.x fix yet",
        "bump": "Affects the pin, and a fix exists: bump the pin",
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
    return "\n".join(out) + "\n"


def gh(*args: str, stdin: str | None = None) -> str:
    proc = subprocess.run(["gh", *args], input=stdin, text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        sys.exit(f"{RED}error:{OFF} gh {' '.join(args[:2])} failed: {proc.stderr.strip()}")
    return proc.stdout


def fetch() -> list[dict]:
    """The published advisories, through gh and the run's token, or without a
    token if that is refused. A workflow's GITHUB_TOKEN is scoped to its own
    repository, and whether it may read another repository's advisory list is
    not something to find out on the Monday it matters. Published advisories
    of a public repository need no token at all. Both failing exits non-zero."""
    endpoint = f"repos/{UPSTREAM}/security-advisories?state=published&per_page=100"
    # One object per line from `--jq '.[]'`, which works on any gh; --slurp is
    # newer than some hosts' gh.
    proc = subprocess.run(
        ["gh", "api", "--paginate", "--jq", ".[]", endpoint], text=True, capture_output=True, check=False
    )
    if proc.returncode == 0:
        return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    print(f"gh api {endpoint} refused ({proc.stderr.strip()}); trying without a token", file=sys.stderr)
    items: list[dict] = []
    for page in range(1, 11):  # 1,000 items: an order more than the list holds
        req = urllib.request.Request(
            f"https://api.github.com/{endpoint}&page={page}",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "wiki-watch"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                batch = json.load(resp)
        except OSError as e:
            sys.exit(f"{RED}error:{OFF} {endpoint}: {e}")
        items += batch
        if len(batch) < 100:
            return items
    sys.exit(f"{RED}error:{OFF} {endpoint}: more than 1,000 items, which is not this list")


def title(report: Report) -> str:
    if any(f.kind == "overdue" for f in report.findings):
        return f"Wiki.js {report.pin}: an advisory is unfixed after {OVERDUE_DAYS} days"
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

    now = dt.datetime(2026, 11, 9, tzinfo=dt.UTC)

    def adv(ghsa, published, rng, patched):
        return {
            "ghsa_id": ghsa,
            "published_at": published,
            "severity": "high",
            "html_url": f"https://github.com/{UPSTREAM}/security/advisories/{ghsa}",
            "summary": ghsa,
            "vulnerabilities": [{"vulnerable_version_range": rng, "patched_versions": patched}],
        }

    # The 2.x history, read against a 3.x pin: none of it is about 3.x.
    history = [
        adv("GHSA-old-open", "2022-01-01T00:00:00Z", "> 2.4.17", "2.4.107"),
        adv("GHSA-fixed", "2026-09-21T07:51:15Z", "<2.5.314", "2.5.315"),
        adv("GHSA-exact", "2024-09-18T00:00:00Z", "2.5.303", "2.5.304"),
        adv("GHSA-2x-only", "2026-11-05T00:00:00Z", "<= 2.5.317", ""),
    ]
    r = assess("3.3.0", history, now)
    check("the real 2.x history affects 3.3.0 with nothing", [f.ghsa for f in r.findings], [])
    check(
        "a fix on an older line is not one the pin carries",
        [f.kind for f in assess("3.3.0", [adv("GHSA-x", "2026-11-01T00:00:00Z", "<= 3.3.0", "2.5.318")], now).findings],
        ["unfixed"],
    )
    check(
        "unless the range is open-ended, where the patched version is the bound",
        assess("3.3.0", [adv("GHSA-y", "2022-01-01T00:00:00Z", ">= 2.0.0", "2.4.107")], now).anything,
        False,
    )
    check(
        "but not when a patched version is on the pin's line: that is a bump (#1349 review)",
        [
            (f.kind, f.detail)
            for f in assess(
                "3.3.0", [adv("GHSA-z", "2026-11-01T00:00:00Z", ">= 2.0.0", "2.5.318, 3.3.1")], now
            ).findings
        ],
        [("bump", "fixed in 3.3.1")],
    )
    check(
        "and an alternative beside a lower bound is unreadable, not open-ended (#1349 review)",
        [
            f.kind
            for f in assess(
                "3.3.0", [adv("GHSA-w", "2026-11-01T00:00:00Z", "> 2.4.17 || >= 3.0.0", "2.4.107")], now
            ).findings
        ],
        ["unreadable"],
    )

    r = assess("3.3.0", [adv("GHSA-3-fixed", "2026-11-05T00:00:00Z", "< 3.1.0", "3.1.0")], now)
    check("a 3.x advisory fixed below the pin is carried", r.anything, False)
    r = assess("3.3.0", [adv("GHSA-3-in", "2026-11-05T00:00:00Z", "<= 3.3.0", "3.3.0")], now)
    check("a fix listed AT the pin is carried, range notwithstanding", r.anything, False)
    r = assess("3.3.0", [adv("GHSA-new", "2026-11-02T00:00:00Z", "<= 3.3.0", "")], now)
    check("an unfixed advisory at 7 days is unfixed", [(f.kind, f.age_days) for f in r.findings], [("unfixed", 7)])
    r = assess("3.3.0", [adv("GHSA-new", "2026-10-01T00:00:00Z", "<= 3.3.0", "")], now)
    check("at 39 days it is overdue", [f.kind for f in r.findings], ["overdue"])
    check("and the title says so", title(r), "Wiki.js 3.3.0: an advisory is unfixed after 30 days")
    r = assess("3.3.0", [adv("GHSA-4only", "2026-11-01T00:00:00Z", "<= 3.3.0", "4.0.0")], now)
    check(
        "a fix only on a later line is no fix on this one, and is named",
        [(f.kind, f.detail) for f in r.findings],
        [("unfixed", "fixed only in 4.0.0")],
    )
    r = assess("3.3.0", [adv("GHSA-bump", "2026-11-01T00:00:00Z", "<= 3.3.0", "3.3.1")], now)
    check(
        "a fix above the pin on its line is a bump",
        [(f.kind, f.detail) for f in r.findings],
        [("bump", "fixed in 3.3.1")],
    )
    check("and the title is not alarming", title(r), "Wiki.js 3.3.0: advisories to act on")
    r = assess("3.3.0", [adv("GHSA-odd", "2026-11-01T00:00:00Z", "every release", "")], now)
    check("an unreadable range is reported, not passed", [f.kind for f in r.findings], ["unreadable"])
    check("nothing at all is nothing to report", assess("3.3.0", [], now).anything, False)
    check("a 2.x pin still reads on its own line", assess("2.5.316", history[1:3], now).anything, False)

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
    report = assess(m[1], fetch(), now)
    body = render(report, now)
    print(body)
    if "--sync-issue" in argv:
        sync(report, body, "--dry-run" in argv)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
