#!/usr/bin/env python3
"""Turn scripts/scan-images.sh's reports into a job summary and issues (#852).

WHAT THIS IS FOR. scan-images.sh leaves one trivy JSON per pinned image. This
reads them and does two things with them:

  * the summary: one row per pinned image, clean ones included, so a run
    shows it scanned everything, not only that it found something;
  * the issues: one open issue per image REPOSITORY with fixable HIGH or
    CRITICAL findings, labelled `security` and its stacks' labels.

ONE ISSUE PER REPOSITORY, NOT PER TAG. The identity is `vaultwarden/server`,
whatever tag is pinned, and lives in a hidden marker in the body. The fix for a
finding is nearly always a bump, and a bump changes the tag: keyed on the
tag, every Dependabot merge would close one issue and open its twin. Keyed on
the repository, the issue survives the bump and closes when a scan finds the
new digest clean. postgres:18.6 (sensitive) and postgres:17.11 (wiki) are
therefore one issue with two sections — one upstream, one place to look.

WHAT EACH RUN DOES TO AN ISSUE
  fixable, no open issue        create it
  fixable, open issue           rewrite the body to this run's picture; comment
                                only when a finding appears that the last body
                                did not have, because an edit notifies nobody
  clean, open issue             comment the clean digest, close
  no longer pinned, open issue  comment, close — which is also how the issue a
                                `--extra` test image opened tidies itself away
                                on the next scheduled run
  any of its tags failed scan   leave it alone: unknown is not clean

WHAT "NEW" IS MEASURED AGAINST. Not the rendered table: an oversized body drops
rows, and trivy's IDs are not all CVEs — GHSA-, GO- and ALAS- IDs appear too.
The body carries every finding ID of the last scan in a second hidden marker, zlib-compressed and base64-encoded, and the next scan
compares against that. A body without one (edited by hand, or older) falls
back to the CVE and GHSA IDs visible in it.

LABELS. `security` plus one per stack the image is pinned in. Stack labels are
the scanner's to manage, so an edit also removes a stack label the image no
longer has — an image dropped from `sensitive` must not keep claiming it.
Every other label on the issue, priority and triage included, is left alone.
A stack label that does not exist is warned about and dropped: failing the
sync for a missing label would hide every finding behind a cosmetic problem.

Usage: scripts/cve_report.py --dir DIR                 the summary, to stdout
       scripts/cve_report.py --dir DIR --sync-issues   create/edit/close via gh
       scripts/cve_report.py --dir DIR --sync-issues --dry-run
       scripts/cve_report.py --self-test

Environment:
  GH_TOKEN              for --sync-issues; needs issues: write
  GITHUB_REPOSITORY     owner/name, default Gerrrt/HomeLab
  GITHUB_SERVER_URL, GITHUB_RUN_ID   link each issue to the run that wrote it
"""
from __future__ import annotations

import argparse
import base64
import dataclasses
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import zlib

RED = "\033[0;31m"
YELLOW = "\033[0;33m"
GREEN = "\033[0;32m"
OFF = "\033[0m"

SEVERITIES = ("CRITICAL", "HIGH")
MARKER = re.compile(r"<!-- cve-scan: (\S+) -->")
IDS_MARKER = re.compile(r"<!-- cve-scan-ids: ([A-Za-z0-9+/=]*) -->")
FINDING_ID = re.compile(r"\b(?:CVE-\d{4}-\d{4,}|GHSA(?:-[0-9a-z]{4}){3})\b")

# Stacks whose label is not their name. `test` is scan-images.sh --extra.
LABEL_FOR = {"test": "ci"}

# An issue body is capped at 65,536 characters; leave room for the frame.
BODY_LIMIT = 60_000
SUMMARY_ROWS_PER_IMAGE = 50
PACE_SECONDS = 2


@dataclasses.dataclass(frozen=True)
class Finding:
    id: str
    severity: str
    package: str
    installed: str
    fixed: str
    title: str
    url: str


@dataclasses.dataclass
class Image:
    ref: str
    stacks: list[str]
    findings: list[Finding] | None  # None: the scan failed
    error: str = ""

    @property
    def repo(self) -> str:
        return repo_of(self.ref)

    @property
    def name(self) -> str:
        """repo:tag, without the digest."""
        return self.ref.split("@", 1)[0]

    @property
    def digest(self) -> str:
        return self.ref.split("@", 1)[1] if "@" in self.ref else ""

    def count(self, severity: str) -> int:
        return sum(f.severity == severity for f in self.findings or [])


@dataclasses.dataclass
class Action:
    kind: str  # create | edit | close
    repo: str
    number: int | None = None
    title: str = ""
    body: str = ""
    labels: tuple[str, ...] = ()
    comment: str = ""
    remove_labels: tuple[str, ...] = ()


def repo_of(ref: str) -> str:
    """`ghcr.io/a/b:1@sha256:..` -> `ghcr.io/a/b`. The tag is after the last
    colon only if that colon is after the last slash: `host:5000/x` has none."""
    name = ref.split("@", 1)[0]
    head, _, last = name.rpartition("/")
    if ":" in last:
        last = last.split(":", 1)[0]
    return f"{head}/{last}" if head else last


def parse_trivy(doc: dict) -> list[Finding]:
    seen: dict[tuple[str, str, str], Finding] = {}
    for result in doc.get("Results") or []:
        for v in result.get("Vulnerabilities") or []:
            sev = v.get("Severity", "")
            fixed = v.get("FixedVersion", "")
            if sev not in SEVERITIES or not fixed:
                continue
            f = Finding(
                id=v.get("VulnerabilityID", "?"),
                severity=sev,
                package=v.get("PkgName", "?"),
                installed=v.get("InstalledVersion", ""),
                fixed=fixed,
                title=" ".join((v.get("Title") or "").split()),
                url=v.get("PrimaryURL", ""),
            )
            seen.setdefault((f.id, f.package, f.installed), f)
    return sorted(seen.values(), key=lambda f: (SEVERITIES.index(f.severity), f.package, f.id))


def load(directory: pathlib.Path) -> list[Image]:
    index = directory / "images.tsv"
    if not index.is_file():
        sys.exit(f"{RED}error:{OFF} no {index}; run scripts/scan-images.sh first")
    images = []
    for line in index.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        n, ref, stacks = line.split("\t")
        report, err = directory / f"{n}.json", directory / f"{n}.err"
        image = Image(ref=ref, stacks=stacks.split(","), findings=None)
        if report.is_file():
            image.findings = parse_trivy(json.loads(report.read_text(encoding="utf-8")))
        else:
            lines = err.read_text(encoding="utf-8").strip().splitlines() if err.is_file() else []
            image.error = lines[-1] if lines else "no report written"
        images.append(image)
    return images


def status(image: Image) -> str:
    if image.findings is None:
        return "scan error"
    return "fixable" if image.findings else "clean"


def cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def findings_table(findings: list[Finding], limit: int | None = None) -> list[str]:
    rows = ["| Severity | ID | Package | Installed | Fixed in |", "|---|---|---|---|---|"]
    shown = findings if limit is None else findings[:limit]
    for f in shown:
        ident = f"[{f.id}]({f.url})" if f.url else f.id
        rows.append(f"| {f.severity} | {ident} | {cell(f.package)} | {cell(f.installed)} | {cell(f.fixed)} |")
    if limit is not None and len(findings) > limit:
        rows.append(f"\n…and {len(findings) - limit} more.")
    return rows


def summary(images: list[Image]) -> str:
    ordered = sorted(images, key=lambda i: (i.repo, i.name))
    fixable = [i for i in ordered if status(i) == "fixable"]
    errors = [i for i in ordered if status(i) == "scan error"]
    out = [
        "## Fixable HIGH and CRITICAL CVEs in pinned images",
        "",
        (f"{len(images)} image(s) scanned: {len(fixable)} with fixable findings, "
         f"{len(errors)} scan error(s), {len(images) - len(fixable) - len(errors)} clean."),
        "",
        "| Image | Stacks | Critical | High | Status |",
        "|---|---|---:|---:|---|",
    ]
    for i in ordered:
        st = status(i)
        crit = "–" if i.findings is None else str(i.count("CRITICAL"))
        high = "–" if i.findings is None else str(i.count("HIGH"))
        mark = {"fixable": "⚠️ fixable", "scan error": "❌ scan error", "clean": "✅ clean"}[st]
        out.append(f"| `{i.name}` | {', '.join(i.stacks)} | {crit} | {high} | {mark} |")
    for i in errors:
        out += ["", f"### ❌ `{i.name}`", "", "```", i.error, "```"]
    for i in fixable:
        out += ["", "<details>", (f"<summary><code>{i.name}</code>: {i.count('CRITICAL')} critical, "
                                  f"{i.count('HIGH')} high</summary>"), ""]
        out += findings_table(i.findings or [], SUMMARY_ROWS_PER_IMAGE)
        out += ["", "</details>"]
    return "\n".join(out) + "\n"


def run_url() -> str:
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    run = os.environ.get("GITHUB_RUN_ID")
    return f"{server}/{repo_name()}/actions/runs/{run}" if run else ""


def repo_name() -> str:
    return os.environ.get("GITHUB_REPOSITORY", "Gerrrt/HomeLab")


def issue_title(repo: str, images: list[Image]) -> str:
    crit = sum(i.count("CRITICAL") for i in images)
    high = sum(i.count("HIGH") for i in images)
    return f"Fixable CVEs in {repo} ({crit} critical, {high} high)"


def encode_ids(ids: set[str]) -> str:
    raw = "\n".join(sorted(ids)).encode("utf-8")
    return f"<!-- cve-scan-ids: {base64.b64encode(zlib.compress(raw, 9)).decode('ascii')} -->"


def previous_ids(body: str) -> set[str]:
    """The finding IDs the last scan recorded in this body. See the docstring."""
    m = IDS_MARKER.search(body)
    if m:
        try:
            raw = zlib.decompress(base64.b64decode(m.group(1), validate=True)).decode("utf-8")
            return set(filter(None, raw.split("\n")))
        except (ValueError, zlib.error, UnicodeDecodeError):
            pass
    return set(FINDING_ID.findall(body))


def issue_body(repo: str, images: list[Image], url: str) -> str:
    ids = {f.id for i in images for f in i.findings or []}
    head = [
        f"<!-- cve-scan: {repo} -->",
        encode_ids(ids),
        ("The weekly CVE scan found fixable HIGH or CRITICAL vulnerabilities in "
         f"`{repo}`. This body is rewritten by every scan, and the issue closes "
         "itself when a scan finds the pinned digest clean."),
        "",
        ("The fix is normally the Dependabot bump for this image. If upstream has "
         "not released one, the fixed versions below say what to wait for."),
    ]
    foot = ["", "---", "Written by `.github/workflows/cve-scan.yml`" + (f" in [this run]({url})." if url else ".")]
    sections = []
    for i in sorted(images, key=lambda i: i.name):
        if not i.findings:
            continue
        sections.append(["", f"### `{i.name}`", "",
                         f"Stacks: {', '.join(i.stacks)}. Digest: `{i.digest}`.", ""]
                        + findings_table(i.findings))
    body = "\n".join(head + [line for s in sections for line in s] + foot)
    if len(body) <= BODY_LIMIT:
        return body
    # Too long for an issue: keep the counts, drop rows from the bottom up.
    limit = 200
    while limit > 5:
        limit //= 2
        sections = [["", f"### `{i.name}`", "", f"Stacks: {', '.join(i.stacks)}. Digest: `{i.digest}`.", ""]
                    + findings_table(i.findings, limit) for i in images if i.findings]
        body = "\n".join(head + [line for s in sections for line in s] + foot)
        if len(body) <= BODY_LIMIT:
            break
    return body


def plan(images: list[Image], existing: list[dict], known_labels: set[str],
         stack_names: set[str] | None = None) -> tuple[list[Action], list[str]]:
    """What to do to the issues, and the warnings to print. Pure, so the
    self-test can hold it to the table in the module docstring.

    `stack_names` is every stack scripts/stacks.sh lists; their labels are the
    ones an edit may remove. It defaults to the stacks the images name."""
    if stack_names is None:
        stack_names = {s for i in images for s in i.stacks}
    owned = {LABEL_FOR.get(s, s) for s in stack_names | {"test"}}
    by_repo: dict[str, list[Image]] = {}
    for i in images:
        by_repo.setdefault(i.repo, []).append(i)
    open_issues: dict[str, dict] = {}
    for issue in existing:
        m = MARKER.search(issue.get("body") or "")
        if m:
            open_issues.setdefault(m.group(1), issue)

    actions: list[Action] = []
    warnings: list[str] = []
    url = run_url()
    for repo in sorted(by_repo):
        imgs = by_repo[repo]
        issue = open_issues.get(repo)
        if any(i.findings is None for i in imgs):
            warnings.append(f"{repo}: a tag failed to scan; its issue is left as it is")
            continue
        if not any(i.findings for i in imgs):
            if issue:
                clean = ", ".join(f"`{i.ref}`" for i in imgs)
                actions.append(Action("close", repo, issue["number"],
                                      comment=f"Clean at {clean}: no fixable HIGH or CRITICAL findings."
                                      + (f" ([scan]({url}))" if url else "")))
            continue
        labels = ["security"]
        for stack in sorted({s for i in imgs for s in i.stacks}):
            label = LABEL_FOR.get(stack, stack)
            if label in known_labels:
                labels.append(label)
            else:
                warnings.append(f"{repo}: no label `{label}` for stack {stack}; skipped")
        title, body = issue_title(repo, imgs), issue_body(repo, imgs, url)
        if issue is None:
            actions.append(Action("create", repo, None, title, body, tuple(labels)))
            continue
        before = previous_ids(issue.get("body") or "")
        new = sorted({f.id for i in imgs for f in i.findings or []} - before)
        comment = ""
        if new:
            shown = ", ".join(new[:20]) + (f" and {len(new) - 20} more" if len(new) > 20 else "")
            comment = f"New since the last scan: {shown}."
        current = {label["name"] for label in issue.get("labels") or []}
        stale = tuple(sorted((current & owned) - set(labels)))
        actions.append(Action("edit", repo, issue["number"], title, body, tuple(labels), comment, stale))
    for repo, issue in sorted(open_issues.items()):
        if repo not in by_repo:
            actions.append(Action("close", repo, issue["number"],
                                  comment=f"`{repo}` is no longer pinned in any stack's compose.yaml."))
    return actions, warnings


def gh(*args: str, stdin: str | None = None) -> str:
    proc = subprocess.run(["gh", *args], input=stdin, text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        sys.exit(f"{RED}error:{OFF} gh {' '.join(args[:2])} failed: {proc.stderr.strip()}")
    return proc.stdout


def sync(images: list[Image], dry_run: bool) -> int:
    repo = repo_name()
    # Every open `security` issue, matched on the marker here rather than by
    # GitHub search: the marker is an HTML comment, and whether search indexes
    # one is not something to depend on.
    existing = json.loads(gh("issue", "list", "-R", repo, "--state", "open", "--label", "security",
                             "--limit", "1000", "--json", "number,title,body,labels"))
    known = {label["name"] for label in json.loads(gh("label", "list", "-R", repo, "--limit", "500",
                                                      "--json", "name"))}
    stacks = subprocess.run([str(pathlib.Path(__file__).with_name("stacks.sh"))],
                            capture_output=True, text=True, check=True).stdout.split()
    actions, warnings = plan(images, existing, known, set(stacks))
    for w in warnings:
        print(f"{YELLOW}warning:{OFF} {w}", file=sys.stderr)
    for a in actions:
        where = f"#{a.number}" if a.number else "new"
        print(f"{a.kind:6} {where:6} {a.repo}" + (f"  [{', '.join(a.labels)}]" if a.labels else "")
              + (f"  -[{', '.join(a.remove_labels)}]" if a.remove_labels else ""))
        if dry_run:
            continue
        # The first run opens dozens at once, and GitHub's secondary rate limit
        # is on content creation per minute, not on the token's hourly budget.
        time.sleep(PACE_SECONDS)
        if a.kind == "create":
            label_args = [arg for label in a.labels for arg in ("--label", label)]
            gh("issue", "create", "-R", repo, "--title", a.title, "--body-file", "-", *label_args, stdin=a.body)
        elif a.kind == "edit":
            remove = ["--remove-label", ",".join(a.remove_labels)] if a.remove_labels else []
            gh("issue", "edit", str(a.number), "-R", repo, "--title", a.title, "--body-file", "-",
               "--add-label", ",".join(a.labels), *remove, stdin=a.body)
            if a.comment:
                gh("issue", "comment", str(a.number), "-R", repo, "--body-file", "-", stdin=a.comment)
        elif a.kind == "close":
            gh("issue", "close", str(a.number), "-R", repo, "--comment", a.comment)
    if not actions:
        print(f"{GREEN}no issue changes{OFF}")
    return 0


def self_test() -> int:
    failures = []

    def check(name: str, cond: bool) -> None:
        print(f"{GREEN}PASS{OFF} {name}" if cond else f"{RED}FAIL{OFF} {name}")
        if not cond:
            failures.append(name)

    for ref, want in [
        ("caddy:2.11.4@sha256:ab", "caddy"),
        ("ghcr.io/immich-app/immich-server:v3.2.4@sha256:ab", "ghcr.io/immich-app/immich-server"),
        ("registry:5000/foo", "registry:5000/foo"),
        ("registry:5000/foo:1@sha256:ab", "registry:5000/foo"),
        ("lscr.io/linuxserver/speedtest-tracker:1.15.0", "lscr.io/linuxserver/speedtest-tracker"),
    ]:
        check(f"repo_of({ref})", repo_of(ref) == want)

    doc = {"Results": [
        {"Vulnerabilities": [
            {"VulnerabilityID": "CVE-2026-0001", "Severity": "CRITICAL", "PkgName": "openssl",
             "InstalledVersion": "3.0.1", "FixedVersion": "3.0.2"},
            {"VulnerabilityID": "CVE-2026-0002", "Severity": "HIGH", "PkgName": "zlib",
             "InstalledVersion": "1.2", "FixedVersion": "1.3"},
            {"VulnerabilityID": "CVE-2026-0003", "Severity": "HIGH", "PkgName": "glibc",
             "InstalledVersion": "2.3", "FixedVersion": ""},
            {"VulnerabilityID": "CVE-2026-0004", "Severity": "MEDIUM", "PkgName": "bash",
             "InstalledVersion": "5", "FixedVersion": "5.1"},
        ]},
        # The same finding in a second target is one finding.
        {"Vulnerabilities": [
            {"VulnerabilityID": "CVE-2026-0001", "Severity": "CRITICAL", "PkgName": "openssl",
             "InstalledVersion": "3.0.1", "FixedVersion": "3.0.2"},
        ]},
        {"Vulnerabilities": None},
    ]}
    parsed = parse_trivy(doc)
    check("parse: unfixed and MEDIUM dropped, duplicates merged", [f.id for f in parsed] == ["CVE-2026-0001", "CVE-2026-0002"])
    check("parse: CRITICAL sorts first", parsed[0].severity == "CRITICAL")

    vuln = parse_trivy(doc)
    labels = {"security", "sensitive", "wiki", "ci", "observability"}
    images = [
        Image("postgres:18.6@sha256:aa", ["sensitive"], vuln),
        Image("postgres:17.11@sha256:bb", ["wiki"], []),
        Image("caddy:2.11.4@sha256:cc", ["lab", "observability"], []),
        Image("vaultwarden/server:1@sha256:dd", ["sensitive"], None, "timeout"),
        Image("python:3.6-slim@sha256:ee", ["test"], vuln),
    ]
    existing = [
        {"number": 10, "body": "<!-- cve-scan: postgres -->\nCVE-2026-0001"},
        {"number": 11, "body": "<!-- cve-scan: caddy -->"},
        {"number": 12, "body": "<!-- cve-scan: vaultwarden/server -->"},
        {"number": 13, "body": "<!-- cve-scan: gone/image -->"},
        {"number": 14, "body": "an unrelated security issue"},
    ]
    actions, warnings = plan(images, existing, labels)
    by = {a.repo: a for a in actions}
    check("postgres: one issue for two tags, edited", by["postgres"].kind == "edit" and by["postgres"].number == 10)
    check("postgres: comment names only the new finding", by["postgres"].comment == "New since the last scan: CVE-2026-0002.")
    check("postgres: labelled by the stack with findings and the clean one",
          by["postgres"].labels == ("security", "sensitive", "wiki"))
    check("postgres: body carries the marker", "<!-- cve-scan: postgres -->" in by["postgres"].body)
    check("postgres: only the fixable tag gets a section",
          "postgres:18.6" in by["postgres"].body and "postgres:17.11" not in by["postgres"].body)
    check("caddy: clean closes", by["caddy"].kind == "close" and by["caddy"].number == 11)
    check("vaultwarden: scan error leaves the issue alone", "vaultwarden/server" not in by)
    check("vaultwarden: and says so", any("vaultwarden/server" in w for w in warnings))
    check("gone/image: no longer pinned closes", by["gone/image"].kind == "close" and by["gone/image"].number == 13)
    check("python: --extra creates, labelled ci", by["python"].kind == "create" and by["python"].labels == ("security", "ci"))
    check("unrelated issue untouched", all(a.number != 14 for a in actions))
    check("title counts", by["python"].title == "Fixable CVEs in python (1 critical, 1 high)")

    actions, warnings = plan([Image("zeek/zeek:9@sha256:ff", ["sensor"], vuln)], [], labels)
    check("missing label is dropped, not fatal", actions[0].labels == ("security",))
    check("missing label is warned", any("`sensor`" in w for w in warnings))

    actions, _ = plan([Image("postgres:18.6@sha256:aa", ["sensitive"], vuln)],
                      [{"number": 10, "body": "<!-- cve-scan: postgres -->\nCVE-2026-0001 CVE-2026-0002"}], labels)
    check("no new finding, no comment", actions[0].comment == "")

    many = [Finding(f"CVE-2026-{n:05}", "HIGH", "pkg" * 30, "1" * 40, "2" * 40, "", "https://x/" + "y" * 60)
            for n in range(2000)]
    body = issue_body("big", [Image("big:1@sha256:aa", ["lab"], many)], "")
    check("an oversized body is cut under the issue limit", len(body) <= BODY_LIMIT and "more." in body)
    check("the cut body still records every finding ID", previous_ids(body) == {f.id for f in many})
    actions, _ = plan([Image("big:1@sha256:aa", ["lab"], many)],
                      [{"number": 20, "body": body}], labels | {"lab"})
    check("an unchanged oversized report announces nothing new", actions[0].comment == "")

    go = [Finding("GO-2026-1234", "HIGH", "stdlib", "1.22.0", "1.22.5", "", ""),
          Finding("ALAS2023-2026-999", "HIGH", "curl", "8.1", "8.2", "", "")]
    gobody = issue_body("go", [Image("go:1@sha256:aa", ["lab"], go)], "")
    actions, _ = plan([Image("go:1@sha256:aa", ["lab"], go)], [{"number": 21, "body": gobody}], labels | {"lab"})
    check("non-CVE IDs round-trip: unchanged report, no comment", actions[0].comment == "")
    actions, _ = plan([Image("go:1@sha256:aa", ["lab"], [*go, Finding("GO-2026-9999", "HIGH", "x", "1", "2", "", "")])],
                      [{"number": 21, "body": gobody}], labels | {"lab"})
    check("a new non-CVE ID is announced", actions[0].comment == "New since the last scan: GO-2026-9999.")
    check("a corrupt ID marker falls back to the visible IDs",
          previous_ids("<!-- cve-scan-ids: !!! --> CVE-2026-0001") == {"CVE-2026-0001"})

    moved = {"number": 22, "body": "<!-- cve-scan: postgres -->",
             "labels": [{"name": "security"}, {"name": "sensitive"}, {"name": "priority/critical"}]}
    actions, _ = plan([Image("postgres:17.11@sha256:bb", ["wiki"], vuln)], [moved], labels,
                      {"sensitive", "wiki", "lab"})
    check("a stack the image left loses its label", actions[0].remove_labels == ("sensitive",))
    check("and the image's current stack is added", actions[0].labels == ("security", "wiki"))
    check("labels the scanner does not own are kept", "priority/critical" not in actions[0].remove_labels)

    text = summary(images)
    check("summary lists every image, clean ones too", all(f"`{i.name}`" in text for i in images))
    check("summary shows the scan error", "timeout" in text)

    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--dir", type=pathlib.Path, help="scan-images.sh --out directory")
    ap.add_argument("--sync-issues", action="store_true", help="create, edit and close issues via gh")
    ap.add_argument("--dry-run", action="store_true", help="with --sync-issues: print, change nothing")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.dir is None:
        ap.error("--dir is required")
    images = load(args.dir)
    if args.sync_issues:
        return sync(images, args.dry_run)
    sys.stdout.write(summary(images))
    return 0


if __name__ == "__main__":
    sys.exit(main())
