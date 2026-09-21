#!/usr/bin/env python3
"""Alertmanager's silences as metrics, one series each, so a silence is watched rather than remembered (#575).

WHAT THIS EXISTS FOR. On 2026-09-20 Alertmanager held two active silences,
both ending 2026-10-08. One stood over a finding whose issue had been closed
by accident; the other had no issue behind it at all until one was filed that
day. Both were found by a person reading the silence list during a triage
pass — the same mechanism that found #531's original problem and #76 before
it. Three times is a pattern, and the estate's answer to a pattern is to watch
the control, not to remember harder.

WHAT NOTHING ELSE CAN SEE. `alertmanager_silences` on Alertmanager's own
/metrics is a count per state. It cannot say which alert a silence covers,
when it ends, or who owns it — and those three are the whole question. The
answer is in `GET /api/v2/silences`, which nothing here read until now.

WHAT IT WRITES. Two gauges per live (active or pending) silence:

    homelab_silence_expires_timestamp_seconds{alert, issue, id}   endsAt
    homelab_silence_starts_timestamp_seconds{alert, issue, id}    startsAt

  alert   the value of the silence's `alertname` matcher, verbatim whether
          it is an equality or a regex; omitted when there is no such
          matcher. Named `alert` and NOT `alertname`, because Prometheus
          sets `alertname` on every alert to the rule's own name, and a
          series label of that name would be overwritten in the
          notification — the one fact the page exists to carry.
  issue   the number from a comment that BEGINS with `#NNN`; omitted
          otherwise. Anchored at the start on purpose: both silences above
          cited an issue somewhere in their prose, and it was the wrong
          one. A lenient first-match would have attributed them to closed
          issues and hidden the finding. The convention is written in
          docs/observability.md, Silences.
  id      the silence UUID, so two silences on the same alert under the same
          issue stay distinct series, and because it is the handle every
          runbook here deletes by.

Expired silences are NOT emitted. The decision #575 asked for, made rather
than assumed: Alertmanager keeps an expired silence for its default 120 h and
Prometheus keeps this series' history for 30 days, so a page that returns can
be matched to the silence that ended with
`last_over_time(homelab_silence_expires_timestamp_seconds[7d])` — no second
window is needed, and emitting expired silences would make
SilenceExpiresSoon count backwards from every lapsed one.

Prometheus drops a label whose value is empty, so `{issue=""}` in a rule
matches series that LACK the label. The collector omits empty labels rather
than writing `issue=""`, so the file says what Prometheus will store.

ON FAILURE the file is left as it was. A silence deleted while Alertmanager is
unreachable therefore looks alive until the next successful run, and
ScheduledJobFailed says why; that is preferred to an empty file, which would
read as "no silences" — the one state this collector must never fake.

Usage: scripts/collect_silences.py [--print] [--self-test]
       --print      write to stdout instead of the textfile directory
       --self-test  run the embedded fixtures and exit non-zero on any failure

Environment:
  ALERTMANAGER_URL   default http://127.0.0.1:9093 — loopback only (ADR-0012)
  TEXTFILE_DIR       default /var/lib/node_exporter/textfile_collector
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request

RED = "\033[0;31m"
GREEN = "\033[0;32m"
OFF = "\033[0m"

# Not silence-state.prom, the job's name: run-scheduled.sh writes "${JOB}.prom"
# and would overwrite this, which is what happened to the apt collector (#360).
FILENAME = "alertmanager-silences.prom"
LIVE_STATES = {"active", "pending"}
ISSUE = re.compile(r"^\s*#(\d+)\b")

EXPIRES = "homelab_silence_expires_timestamp_seconds"
STARTS = "homelab_silence_starts_timestamp_seconds"
HELP = {
    EXPIRES: "Unix time this active or pending Alertmanager silence ends. "
    "issue is the number a comment starting with #NNN names; absent when it "
    "names none.",
    STARTS: "Unix time this active or pending Alertmanager silence began, "
    "or will begin.",
}


def escape(value: str) -> str:
    """Escape a label value for the Prometheus text exposition format."""
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def parse_time(text: str) -> int:
    """Alertmanager's RFC 3339 timestamps to Unix seconds.

    strfmt.DateTime marshals as 2006-01-02T15:04:05.000Z, and the API may
    carry more than six fractional digits; fromisoformat before Python 3.11
    accepts neither the Z nor more than six, so both are normalised first.
    """
    text = text.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    match = re.match(r"^(.*?)(\.\d+)?([+-]\d\d:\d\d)$", text)
    if match:
        base, fraction, zone = match.groups()
        if fraction:
            fraction = fraction[:7]  # "." plus at most six digits
        text = f"{base}{fraction or ''}{zone}"
    return int(dt.datetime.fromisoformat(text).timestamp())


def issue_of(comment: str | None) -> str:
    found = ISSUE.match(comment or "")
    return found.group(1) if found else ""


def alert_of(matchers: list[dict]) -> str:
    for matcher in matchers:
        if matcher.get("name") == "alertname":
            return str(matcher.get("value", ""))
    return ""


def labels_of(silence: dict) -> str:
    pairs = [
        ("alert", alert_of(silence.get("matchers", []))),
        ("issue", issue_of(silence.get("comment"))),
        ("id", str(silence.get("id", ""))),
    ]
    return ",".join(f'{k}="{escape(v)}"' for k, v in pairs if v != "")


def render(silences: list[dict]) -> str:
    """The .prom text for every live silence, HELP and TYPE lines always."""
    live = sorted(
        (s for s in silences if s.get("status", {}).get("state") in LIVE_STATES),
        key=lambda s: str(s.get("id", "")),
    )
    lines: list[str] = []
    for metric, field in ((EXPIRES, "endsAt"), (STARTS, "startsAt")):
        lines.append(f"# HELP {metric} {HELP[metric]}")
        lines.append(f"# TYPE {metric} gauge")
        for silence in live:
            lines.append(f"{metric}{{{labels_of(silence)}}} {parse_time(silence[field])}")
    return "\n".join(lines) + "\n"


def fetch(alertmanager: str) -> list[dict]:
    url = f"{alertmanager.rstrip('/')}/api/v2/silences"
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            payload = json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise SystemExit(
            f"{RED}error:{OFF} cannot read silences from {url}: {exc}\n"
            f"       the previous file, if any, is left in place"
        ) from exc
    if not isinstance(payload, list):
        raise SystemExit(f"{RED}error:{OFF} {url} did not return a list")
    return payload


def write(text: str, textfile_dir: str) -> str:
    if not os.path.isdir(textfile_dir):
        raise SystemExit(f"{RED}error:{OFF} no textfile directory at {textfile_dir}")
    path = os.path.join(textfile_dir, FILENAME)
    # Same directory so the rename is atomic, and a suffix AFTER .prom so the
    # collector never parses a half-written file. 0644 explicitly: Alloy reads
    # the directory as uid 0 with cap_drop ALL, so a 0600 file is invisible.
    tmp = f"{path}.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise SystemExit(f"{RED}error:{OFF} could not write {path}: {exc}") from exc
    return path


# --- fixtures ---------------------------------------------------------------

def _silence(**overrides: object) -> dict:
    base: dict = {
        "id": "01cb81d7-5e19-4e6d-b386-f5c8c843032b",
        "status": {"state": "active"},
        "matchers": [
            {"name": "alertname", "value": "HostBatteryHealthLow", "isRegex": False, "isEqual": True},
            {"name": "instance", "value": "oracle", "isRegex": False, "isEqual": True},
        ],
        "startsAt": "2026-09-17T23:11:03.000Z",
        "endsAt": "2026-10-08T04:34:31.000Z",
        "createdBy": "claude-code (#454)",
        "comment": "#531 owns this. Known finding from #454, measured 2026-09-12.",
    }
    base.update(overrides)
    return base


def self_test() -> int:
    failed = 0

    def check(name: str, expected: object, got: object) -> None:
        nonlocal failed
        if got == expected:
            print(f"{GREEN}  PASS{OFF} {name}")
        else:
            print(f"{RED}  FAIL{OFF} {name}\n       got      {got!r}\n       expected {expected!r}")
            failed = 1

    # 1. The convention: the comment begins with the owning issue.
    check("issue parsed from a comment that starts with #NNN", "531",
          issue_of("#531 owns this. Known finding from #454."))
    # 2. THE TRAP. Both live silences on 2026-09-20 cited an issue in their
    #    prose, and it was a closed one that did not own the expiry. A parser
    #    that took the first #NNN anywhere would have called them owned.
    check("an issue cited mid-comment is not an owner", "",
          issue_of("Known finding from #454, measured 2026-09-12 and unchanged."))
    # 3. Leading whitespace is tolerated; a pasted comment often has it.
    check("leading whitespace before #NNN is fine", "7", issue_of("  #7 x"))
    # 4. A number that runs into letters is not an issue reference.
    check("#12abc is not an issue", "", issue_of("#12abc fits nothing"))
    # 5. An expired silence is not emitted at all.
    check("an expired silence is omitted", 0,
          render([_silence(status={"state": "expired"})]).count("{"))
    # 6. A pending silence is emitted; the age guard in the rule is what keeps
    #    it quiet, not this collector.
    check("a pending silence is emitted", 2,
          render([_silence(status={"state": "pending"})]).count("{"))
    # 7. A regex matcher's value carries backslashes and may carry quotes;
    #    both must survive the exposition format verbatim.
    regex = _silence(matchers=[{"name": "alertname", "value": 'Ilo\\w+|Ilo"Write"',
                                "isRegex": True, "isEqual": True}])
    check("regex matcher value is escaped", 'alert="Ilo\\\\w+|Ilo\\"Write\\"",issue="531"',
          labels_of(regex).rsplit(",", 1)[0])
    # 8. No alertname matcher: no alert label, rather than alert="".
    check("no alertname matcher yields no alert label", 'issue="531",id="01cb81d7-5e19-4e6d-b386-f5c8c843032b"',
          labels_of(_silence(matchers=[{"name": "instance", "value": "oracle",
                                        "isRegex": False, "isEqual": True}])))
    # 9. No issue: no issue label, so {issue=""} in the rule matches its absence.
    check("no owning issue yields no issue label", 'alert="HostBatteryHealthLow",id="01cb81d7-5e19-4e6d-b386-f5c8c843032b"',
          labels_of(_silence(comment="Known finding from #454.")))
    # 10. Alertmanager's timestamp shape, with and without excess precision.
    check("strfmt.DateTime parses to Unix seconds", 1791434071,
          parse_time("2026-10-08T04:34:31.000Z"))
    check("nine fractional digits are tolerated", 1791434071,
          parse_time("2026-10-08T04:34:31.123456789Z"))
    # 11. Zero live silences still produce a fresh file with HELP and TYPE, so
    #     "no silences" is a stated fact rather than a missing one.
    check("zero silences still render HELP and TYPE", 4,
          render([_silence(status={"state": "expired"})]).count("# "))
    # 12. The whole line, once, exactly as Prometheus will read it.
    check("a live silence renders both gauges",
          'homelab_silence_expires_timestamp_seconds{alert="HostBatteryHealthLow",issue="531",'
          'id="01cb81d7-5e19-4e6d-b386-f5c8c843032b"} 1791434071\n'
          'homelab_silence_starts_timestamp_seconds{alert="HostBatteryHealthLow",issue="531",'
          'id="01cb81d7-5e19-4e6d-b386-f5c8c843032b"} 1789686663',
          "\n".join(line for line in render([_silence()]).splitlines() if not line.startswith("#")))
    return failed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--print", action="store_true", dest="print_only",
                    help="write to stdout instead of the textfile directory")
    ap.add_argument("--self-test", action="store_true",
                    help="run the embedded fixtures")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    alertmanager = os.environ.get("ALERTMANAGER_URL", "http://127.0.0.1:9093")
    silences = fetch(alertmanager)
    text = render(silences)
    if args.print_only:
        sys.stdout.write(text)
        return 0
    path = write(text, os.environ.get("TEXTFILE_DIR", "/var/lib/node_exporter/textfile_collector"))
    states = [s.get("status", {}).get("state") for s in silences]
    print(f"silence-state active={states.count('active')} pending={states.count('pending')} "
          f"expired={states.count('expired')} file={path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
