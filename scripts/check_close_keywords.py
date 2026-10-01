#!/usr/bin/env python3
"""Fail a pull request whose close keywords sit in prose that says the issue stays open (#672).

WHAT THIS EXISTS FOR. GitHub closes an issue on merge for close, closes,
closed, fix, fixes, fixed, resolve, resolves or resolved followed by an issue
reference, ANYWHERE in a PR body or in a commit message that lands on main:
mid-sentence, after a colon, across a soft line break, inside a sentence that
says the opposite. This repository writes `Refs #N` on purpose for work that
closes on a physical act or a deploy, and its prose has tripped the matcher
anyway. The phrases that did it, each of which closed the issue it named:

    "would close <182> by accident"                            #319
    "filed rather than fixed: <251>"                           #252
    "Partly closes <359>"                                      #382
    "the measurement is what closes <418>"                     #521
    "What closes <531> is still the fit"                       #545
    "Closes nothing yet. Refs <571> ... closes <571> with"     #652
    "Neither issue closes: <92> closes when the rehearsal"     #664
    "Refs <776>. ... the PR that closes <776>."                #780

(Issue numbers in angle brackets, so this docstring does not trip the check
it documents if it is ever pasted into a commit.) Three of those issues sat
closed for days to weeks with the work undone, found only by a full pass on
2026-09-26. Checking `closingIssuesReferences` by hand after opening the PR was
the mitigation, and #780 is what it was worth.

THE CONVENTION THIS ENFORCES. An intended close is a sentence of its own that
BEGINS with the keyword — `Closes #N.`, `Closes #N. Refs #M.`, a bullet
`- Closes #N`, or `Closes #N, closes #M.` Everything else is prose, and fails:

  1. Sentence start. The keyword is not the first word of its sentence.
     Every phrase above fails this one. A soft line break is NOT a sentence
     boundary, because commit bodies wrap at 72 columns and "the PR that" /
     "closes <776>" on two lines is one sentence to GitHub.
  2. Negation. The keyword's sentence says not, nothing, none, never, cannot,
     n't, or stays/remains/kept open.
  3. Refs conflict. An issue the merge will close is also named in a `Refs`
     list — in the same body, or a commit closes what the body only Refs.
     That is #780 exactly, and #652, #521 and #664 as well.

What it reads. For `--pr N`, one GraphQL query: the title, the body,
`closingIssuesReferences` (what GitHub itself says the merge will close, which
includes an issue linked by hand in the sidebar) and every commit message,
because a merge or rebase lands those on main and a squash body usually
carries them. The issues the merge will close are written to the job summary
whether the check passes or not, so the list is visible before merge.

What it does not do. A sidebar link with no keyword is reported in the
summary, not failed: it is deliberate by construction. A sidebar link added
AFTER the last run is not seen at all — linking emits no pull_request event,
so nothing re-runs this — and that gap is stated, not closed: re-run the job
before merging if the sidebar changed. Code spans and fences
are NOT exempt — a quoted keyword in a commit body has closed an issue here
before — so prose ABOUT the matcher names the issue without the `#`.

Usage: scripts/check_close_keywords.py --pr N          a pull request, via `gh api graphql`
       scripts/check_close_keywords.py --text FILE|-   a draft body or commit message
       scripts/check_close_keywords.py --self-test     run the embedded fixtures

Environment:
  GITHUB_REPOSITORY     owner/name, default Gerrrt/HomeLab
  GITHUB_STEP_SUMMARY   where the summary goes; stdout when unset
  GITHUB_ACTIONS        when "true", failures are also ::error:: annotations
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

RED = "\033[0;31m"
GREEN = "\033[0;32m"
OFF = "\033[0m"

WORKFLOW = ".github/workflows/close-keywords.yml"

# GitHub's keyword list, a colon optional, any whitespace including a newline,
# then `#N`, `owner/repo#N` or the issue URL. `\s*` rather than `\s+` errs
# towards matching: a false alarm costs a rewrite, a miss costs an issue.
KEYWORD = re.compile(
    r"\b(?P<kw>close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s*"
    r"(?:(?P<repo>[\w.-]+/[\w.-]+)?#(?P<num>\d+)"
    r"|https?://github\.com/(?P<urepo>[\w.-]+/[\w.-]+)/issues/(?P<unum>\d+))(?!\w)",
    re.IGNORECASE,
)
# `Refs #1, #2 and #3`, `Refs: #1`, `Ref #1`.
REFS = re.compile(r"\bRefs?\b\s*:?\s*((?:#\d+(?:\s*(?:,|and|&)\s*)?)+)", re.IGNORECASE)
NEGATION = re.compile(
    r"\b(?:not|nothing|none|never|cannot)\b|n't\b|\b(?:stays?|remains?|kept|keeps?)\s+open\b",
    re.IGNORECASE,
)
# A line that opens a block: list item, heading, table row, fence. A
# blockquote opens one only on its first line; `>` on the next is a
# continuation, or a wrapped quote would hide a mid-sentence keyword.
BLOCK_START = re.compile(r"^\s*(?:[-*+]\s|\d+[.)]\s|#{1,6}\s|\||```|~~~)")
QUOTE = re.compile(r"^\s*>")
# A line that a following line cannot continue: heading, table row, fence.
BLOCK_WHOLE = re.compile(r"^\s*(?:#{1,6}\s|\||```|~~~)")
# Not `;`: it joins clauses, and "This is not done; closes #5 later." is one
# sentence with a negation in it.
SENTENCE_END = re.compile(r"[.!?][\"')\]*_`]*\s+|\|")
ABBREVIATIONS = ("e.g", "i.e", "etc", "vs", "cf")
# What may precede the keyword in its sentence and still leave it first: list
# and quote markers, emphasis, a checkbox, and other keyword clauses.
LEAD_NOISE = re.compile(r"\d+[.)]|\[[ xX]\]|\band\b|[\s>#|*_`\"'()\[\],;&+-]")


def repo_name() -> str:
    return os.environ.get("GITHUB_REPOSITORY", "Gerrrt/HomeLab")


def ref_of(m: re.Match) -> str:
    """`#N` for this repository, `owner/name#N` for any other."""
    repo = m.group("repo") or m.group("urepo")
    num = m.group("num") or m.group("unum")
    if repo is None or repo.lower() == repo_name().lower():
        return f"#{num}"
    return f"{repo}#{num}"


def node_ref(node: dict) -> str:
    """A closingIssuesReferences node in ref_of's shape, so a cross-repository
    close is not mistaken for this repository's issue of the same number."""
    repo = node["repository"]["nameWithOwner"]
    if repo.lower() == repo_name().lower():
        return f"#{node['number']}"
    return f"{repo}#{node['number']}"


def ref_key(ref: str) -> tuple[str, int]:
    """Sort this repository's issues first, numerically: #9 before #10."""
    repo, _, num = ref.rpartition("#")
    return repo, int(num)


def boundaries(text: str) -> list[int]:
    """Offsets where a sentence starts. A soft line break is not one."""
    starts = {0}
    offset = 0
    prev = ""
    for line in text.splitlines(keepends=True):
        if offset and (not prev.strip() or BLOCK_START.match(line) or BLOCK_WHOLE.match(prev)
                       or (QUOTE.match(line) and not QUOTE.match(prev))):
            starts.add(offset)
        prev = line
        offset += len(line)
    for m in SENTENCE_END.finditer(text):
        before = text[:m.start()].rsplit(None, 1)[-1].lower() if text[:m.start()].strip() else ""
        if text[m.start()] == "." and before.endswith(ABBREVIATIONS):
            continue
        starts.add(m.end())
    return sorted(starts)


def refs_of(text: str) -> set[str]:
    return {f"#{n}" for m in REFS.finditer(text) for n in re.findall(r"#(\d+)", m.group(1))}


def closes_of(text: str) -> set[str]:
    return {ref_of(m) for m in KEYWORD.finditer(text)}


def lint(text: str, where: str, closing: set[str] | None = None,
         refs: set[str] | None = None) -> list[str]:
    """Every finding in one text. `closing` defaults to the text's own keyword
    matches; `refs` is extra Refs from elsewhere (a commit is held to its PR body)."""
    findings = []
    starts = boundaries(text)
    for m in KEYWORD.finditer(text):
        s = max(b for b in starts if b <= m.start())
        e = next((b for b in starts if b > m.start()), len(text))
        sentence = " ".join(text[s:e].split())
        lead = LEAD_NOISE.sub("", KEYWORD.sub("", text[s:m.start()]))
        phrase = " ".join(m.group(0).split())
        if lead:
            findings.append(f'{where}: "{phrase}" is not the first word of its sentence: "{sentence}"')
        elif NEGATION.search(sentence):
            findings.append(f'{where}: "{phrase}" sits in a sentence that says otherwise: "{sentence}"')
    closing = closes_of(text) if closing is None else closing
    for ref in sorted(closing & (refs_of(text) | (refs or set())), key=ref_key):
        findings.append(f"{where}: {ref} is named with Refs and will still be closed by this merge")
    return findings


# ---------------------------------------------------------------------------

QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      title
      body
      closingIssuesReferences(first: 100) {
        pageInfo { hasNextPage }
        nodes { number title repository { nameWithOwner } }
      }
      commits(first: 100) {
        pageInfo { hasNextPage }
        nodes { commit { oid message } }
      }
    }
  }
}
"""


def fetch(number: int) -> dict:
    owner, name = repo_name().split("/", 1)
    out = subprocess.run(
        ["gh", "api", "graphql", "-f", f"query={QUERY}", "-F", f"owner={owner}",
         "-F", f"name={name}", "-F", f"number={number}"],
        check=True, capture_output=True, text=True).stdout
    pr = json.loads(out)["data"]["repository"]["pullRequest"]
    # The loud direction: a commit or a closing issue this did not read is one
    # it cannot vouch for.
    for field in ("commits", "closingIssuesReferences"):
        if pr[field]["pageInfo"]["hasNextPage"]:
            raise SystemExit(f"PR #{number}: more than 100 {field}; this reads only the first page")
    return pr


def check_pr(pr: dict) -> tuple[list[str], list[str]]:
    """(findings, summary lines) for one pull request as GraphQL returned it."""
    body = pr.get("body") or ""
    closing = {node_ref(i): i["title"] for i in pr["closingIssuesReferences"]["nodes"]}
    body_refs = refs_of(body)
    findings = lint(pr["title"], "title")
    findings += lint(body, "body", closing=set(closing))
    commit_closes: dict[str, list[str]] = {}
    for node in pr["commits"]["nodes"]:
        oid, message = node["commit"]["oid"][:7], node["commit"]["message"]
        findings += lint(message, f"commit {oid}", refs=body_refs)
        for ref in closes_of(message):
            commit_closes.setdefault(ref, []).append(oid)

    in_body = closes_of(body)
    summary = []
    for ref in sorted(set(closing) | set(commit_closes), key=ref_key):
        where = []
        if ref in closing:
            where.append("PR body" if ref in in_body else "linked by hand, no keyword in the body")
        if ref in commit_closes:
            where.append("commit " + ", ".join(commit_closes[ref]))
        summary.append(f"| {ref} | {closing.get(ref, '')} | {'; '.join(where)} |")
    return findings, summary


HINT = ("An intended close is a sentence of its own that begins with the keyword: "
        "`Closes #N.` Anything else names the issue without a keyword, or with `Refs`.")


def report(findings: list[str], summary: list[str] | None) -> int:
    """Print, and append to the job summary. `summary` is None for --text,
    which has no GitHub-side list of what the merge will close."""
    closes = []
    if summary is not None:
        closes = ["## Issues this merge will close", ""]
        if summary:
            closes += ["| Issue | Title | Closed by |", "| --- | --- | --- |", *summary]
        else:
            closes.append("This merge closes no issues.")
        closes.append("")
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        prose = ["## Close keywords in prose", "", *(f"- {f}" for f in findings), "", HINT, ""]
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("\n".join(closes + (prose if findings else [])) + "\n")
    print("\n".join(closes), end="")
    for f in findings:
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::error title=Close keyword in prose::{f}")
        print(f"{RED}  FAIL{OFF} {f}")
    if findings:
        print(f"\n{HINT}")
    else:
        print(f"{GREEN}  PASS{OFF} no close keyword sits in prose")
    return 1 if findings else 0


# ---------------------------------------------------------------------------

def _issue(number: int, title: str, repo: str | None = None) -> dict:
    """A closingIssuesReferences node as GraphQL returns it."""
    return {"number": number, "title": title, "repository": {"nameWithOwner": repo or repo_name()}}


def self_test() -> int:
    failed = 0

    def check(name: str, expected: object, got: object) -> None:
        nonlocal failed
        if got == expected:
            print(f"{GREEN}  PASS{OFF} {name}")
        else:
            print(f"{RED}  FAIL{OFF} {name}\n       got      {got!r}\n       expected {expected!r}")
            failed = 1

    def fails(text: str) -> bool:
        return bool(lint(text, "t"))

    # 1-8. Every phrase that has closed an issue here by accident, verbatim.
    accidents = {
        "#319": "Doing it here would close #182 by accident with #189's narrower framing.",
        "#252": "- A new gap, filed rather than fixed: #251 — the wiki is not in this repository",
        "#382": "Partly closes #359 — it makes the defect self-reporting.",
        "#521": "`Refs #418`, `Refs #148` — no close keywords. The measurement is what closes #418.",
        "#545": "No rule changes. What closes #531 is still the fit, and the silence deleted.",
        "#652": "Closes nothing yet. Refs #571, whose \"done when\" is met once the swap happens "
                "(§6 now closes #571 with #558).",
        "#664": "Refs #92, #599. Neither issue closes: #92 closes when the rehearsal runs.",
        "#780": "Refs #776. This is the decision only. The vendoring follows in the PR that closes #776.",
    }
    for pr, text in accidents.items():
        check(f"{pr}'s phrase fails", True, fails(text))
    # 9. Refs and a close of the same issue: the #780 shape, named as such.
    check("Refs plus a close of the same issue is a Refs conflict", True,
          any("named with Refs" in f for f in lint(accidents["#780"], "t")))
    # 10. A Refs conflict against GitHub's own list, with no keyword in sight:
    #     the issue was linked by hand and also cited with Refs.
    check("a hand-linked issue also named with Refs fails", True,
          bool(lint("Refs #5.", "t", closing={"#5"})))
    # 11. The intended close that would have had to be rewritten (#758).
    check("\"That closes #251.\" fails", True, fails("Left: the volume. That closes #251."))
    # 12. A soft line break is not a sentence boundary — a wrapped commit body.
    check("a keyword after a soft line break is mid-sentence", True,
          fails("The vendoring follows in the PR that\ncloses #776."))
    # 13. The negation rule on its own, for a keyword that does open its sentence.
    check("a sentence-initial close that says not fails", True,
          fails("Closes #5 only once deployed, not before."))
    check("stays open fails", True, fails("Fixes #5 but the issue stays open."))
    # 14. The other reference shapes GitHub honours.
    check("an issue URL is matched", True,
          fails("This resolves https://github.com/Gerrrt/HomeLab/issues/9 eventually."))
    check("owner/repo#N is matched", {"other/repo#3"},
          closes_of("Fixes other/repo#3."))
    check("this repository's own owner/name#N is #N", {"#3"}, closes_of("Fixes Gerrrt/HomeLab#3."))
    check("#12abc is not a reference", set(), closes_of("closes #12abc"))
    # 15-21. What must pass: the convention, as merged PRs here write it.
    check("Closes #N. then prose passes", False,
          fails("Closes #148. The issue's 2026-09-19 correction asked for the weaker case."))
    check("two close sentences pass", False, fails("Closes #558. Closes #571."))
    check("Closes then Refs passes", False, fails("Closes #531. Refs #519."))
    check("a bullet that is a close passes", False, fails("## Why\n\n- Closes #5\n- Refs #6"))
    check("a close right under a heading passes", False, fails("## Why\nCloses #5."))
    check("a negation in the NEXT sentence passes", False, fails("Closes #5. Not deployed yet."))
    check("a chained close passes", False, fails("Closes #1, closes #2 and fixes #3."))
    check("a close after a trailer-style blank line passes", False,
          fails("feat: a thing\n\nCloses #7.\n\nCo-Authored-By: someone"))
    check("a wrapped blockquote is one sentence", True,
          fails("> This is not done and\n> closes #5."))
    check("a blockquote that is a close passes", False, fails("Intro.\n\n> Closes #5."))
    check("a semicolon does not end a sentence", True, fails("This is not done; closes #5 later."))
    check("e.g. is not a sentence end", True, fails("A keyword, e.g. closes #5, in prose."))
    check("no keyword at all passes", False, fails("Refs #92. This PR resolves none of them."))
    # 22. A commit that closes what the PR body only Refs: merge or rebase lands it.
    pr = {"title": "docs: x", "body": "Refs #5.", "closingIssuesReferences": {"nodes": []},
          "commits": {"nodes": [{"commit": {"oid": "a" * 40, "message": "docs: x\n\nCloses #5."}}]}}
    check("a commit closing what the body Refs fails", True,
          any("named with Refs" in f for f in check_pr(pr)[0]))
    check("the summary lists the commit's close", ["| #5 |  | commit aaaaaaa |"], check_pr(pr)[1])
    pr = {"title": "feat: x (#9)", "body": "Closes #9.",
          "closingIssuesReferences": {"nodes": [_issue(9, "A thing"), _issue(4, "B")]},
          "commits": {"nodes": []}}
    check("a clean PR has no findings, and a hand link is reported", ([], [
        "| #4 | B | linked by hand, no keyword in the body |", "| #9 | A thing | PR body |"]), check_pr(pr))

    # A cross-repository close keeps its repository: it neither shows as this
    # repository's #3 nor conflicts with a local Refs #3.
    pr = {"title": "x", "body": "Fixes other/repo#3.\n\nRefs #3.",
          "closingIssuesReferences": {"nodes": [_issue(3, "Theirs", "other/repo")]},
          "commits": {"nodes": []}}
    check("a cross-repository close is not this repository's issue", ([], [
        "| other/repo#3 | Theirs | PR body |"]), check_pr(pr))

    # That the caller calls this — the shape scripts/self-tests.sh asserts of
    # ci.yml. Deleting the workflow, or its --pr step, fails here rather than
    # quietly leaving the check unrun.
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    try:
        with open(os.path.join(root, WORKFLOW), encoding="utf-8") as fh:
            workflow = fh.read()
    except OSError:
        workflow = ""
    check(f"{WORKFLOW} runs this check with --pr", True,
          bool(re.search(r"^\s*run:\s*python3 scripts/check_close_keywords\.py --pr ", workflow, re.M)))
    return failed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--pr", type=int, help="check a pull request")
    mode.add_argument("--text", help="check a file, or - for stdin")
    mode.add_argument("--self-test", action="store_true", help="run the embedded fixtures")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.text is not None:
        text = sys.stdin.read() if args.text == "-" else open(args.text, encoding="utf-8").read()
        return report(lint(text, args.text), None)
    return report(*check_pr(fetch(args.pr)))


if __name__ == "__main__":
    sys.exit(main())
