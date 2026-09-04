#!/usr/bin/env python3
"""Check the OS versions the documents claim against the ones the hosts report.

`check_docs.py` already asserts that `hardware.md` and `network.md` agree with
each other about every host's OS. That assertion passed for a full pfSense
release while both documents said `FreeBSD 15` and `morpheus` ran FreeBSD 16,
because it compares the two copies and both copies were stale together. Its own
`POINT_RELEASE` comment describes the same failure one round earlier, with the
two laptops recorded as 24.04.3 while running 24.04.4.

So this is the other half, and it is deliberately NOT in `check_docs.py`: that
script compares documents to files in the repository and runs in CI, where
there is no route to the stack. This one asks the running system and can only
run where Prometheus is reachable — the monitoring host. It fails on the fact
rather than on the two copies agreeing.

Sources, one per host, all already collected:

  * `morpheus`   sysDescr over SNMP. pfSense sets it explicitly rather than
                 taking bsnmpd's default, so it carries both versions:
                 "pfSense morpheus.matrix.elysium 2.9.0-RELEASE FreeBSD
                 16.0-CURRENT amd64". This is the host that needed it — it runs
                 no node_exporter, being the FreeBSD appliance that cannot run
                 Alloy, so until #292 its OS version had no live counterpart at
                 all.
  * everything   `node_os_info`, from the Alloy agents that produce the rest of
    else         this stack's host metrics.

Comparison is on family and release line, never the full string, because that
is the convention `check_docs.py` enforces in the tables: they record `FreeBSD
16.0`, the box reports `16.0-CURRENT`, and both mean the same release. A point
release in a table is rejected by `check_docs.py` and is not this script's
business.

Usage:
  scripts/check_versions.py                     check every host it can
  scripts/check_versions.py --prometheus URL    default http://localhost:9090
  scripts/check_versions.py --list              show what each source reports
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))

from check_docs import (  # noqa: E402
    HARDWARE_MD,
    NETWORK_MD,
    network_sections,
    os_key,
    strip_md,
    tables_under,
)

GREEN, RED, YELLOW, BLUE, BOLD, OFF = (
    "\033[0;32m",
    "\033[0;31m",
    "\033[0;33m",
    "\033[0;34m",
    "\033[1m",
    "\033[0m",
)


def release_line(key: tuple[str, str]) -> tuple[str, str]:
    """('ubuntu', '24.04.4') -> ('ubuntu', '24.04').

    The tables record the release line and `check_docs.py` rejects a point
    release in them, but the hosts report point releases: `node_os_info` says
    "Ubuntu 24.04.4 LTS" where the documents correctly say "Ubuntu 24.04 LTS".
    Comparing the full strings would fail on every Linux host the day after any
    of them took an update, which is the opposite of useful — the check would
    be noise, and noise is what gets a check switched off.
    """
    family, version = key
    return family, ".".join(version.split(".")[:2])


def pass_(msg: str) -> None:
    print(f"{GREEN}  PASS{OFF} {msg}")


def fail(msg: str) -> None:
    print(f"{RED}  FAIL{OFF} {msg}")


def skip(msg: str) -> None:
    print(f"{YELLOW}  SKIP{OFF} {msg}")


def info(msg: str) -> None:
    print(f"{BLUE}--{OFF} {msg}")


# `Saruman` is the one host with a live counterpart that cannot be compared.
# node_os_info reports "Debian GNU/Linux 13 (trixie)" because that is what
# Proxmox VE 9 is built on, and the documents record the product rather than its
# base — correctly, since "Debian 13" would not tell a reader what the box is.
# node_uname_info's "7.0.14-12-pve" confirms Proxmox but carries the kernel
# version, not the PVE one. Reading `pveversion` would settle it and nothing
# scrapes it today, so this is a named gap rather than a silent one: skipped
# with a reason, not quietly passed.
NO_COMPARABLE_SOURCE = {
    "saruman": "node_os_info reports the Debian underneath Proxmox VE; "
    "the PVE version is not scraped",
}


def query(prom: str, expr: str) -> list[dict]:
    url = f"{prom.rstrip('/')}/api/v1/query?" + urllib.parse.urlencode(
        {"query": expr}
    )
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            payload = json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise SystemExit(
            f"{RED}error:{OFF} cannot reach Prometheus at {prom}: {exc}\n"
            f"       this check reads the running system; it only works where "
            f"the stack is."
        ) from exc
    if payload.get("status") != "success":
        raise SystemExit(f"{RED}error:{OFF} query failed: {expr}")
    return payload["data"]["result"]


def running_versions(prom: str) -> dict[str, tuple[str, str]]:
    """host -> (os string as reported, source name)."""
    found: dict[str, tuple[str, str]] = {}

    for series in query(prom, "node_os_info"):
        metric = series["metric"]
        host = metric.get("instance", "")
        pretty = metric.get("pretty_name", "")
        if host and pretty:
            found[host.lower()] = (pretty, "node_os_info")

    # sysDescr is one string holding two versions. The FreeBSD half is what the
    # OS columns record; the pfSense half is checked separately below, against
    # the runbook rather than the tables.
    for series in query(prom, "sysDescr"):
        metric = series["metric"]
        host = metric.get("device") or metric.get("instance", "")
        descr = metric.get("sysDescr", "")
        match = re.search(r"(FreeBSD\s+\S+)", descr)
        if host and match:
            found[host.lower()] = (match.group(1), "sysDescr")

    return found


def documented_versions() -> dict[str, list[tuple[str, str]]]:
    """host -> [(document, cell)], every row that states an OS.

    Keyed on the Compute table in `hardware.md`, which is the list of hosts this
    estate runs rather than every device that holds a lease. `network.md` also
    names eeros, televisions and phones; none of them reports an OS, none is
    expected to, and listing twenty-five SKIP lines for them would bury the one
    line that matters. A managed host that stops reporting still shows up,
    because it stays in the Compute table.
    """
    out: dict[str, list[tuple[str, str]]] = {}

    tables = tables_under(
        HARDWARE_MD.read_text(encoding="utf-8"), re.compile(r"^##\s+Compute")
    )
    if not tables:
        raise SystemExit(f"{RED}error:{OFF} docs/hardware.md has no Compute table")
    for row in tables[0][1:]:
        if len(row) >= 6:
            out.setdefault(strip_md(row[0]).lower(), []).append(
                ("docs/hardware.md", strip_md(row[5]))
            )
    managed = set(out)

    # Every row, not the first per host: `morpheus` appears in all seven segment
    # tables, and a version edited into only the sixth must not be invisible.
    seen: set[tuple[str, str]] = set()
    for rows in network_sections(NETWORK_MD.read_text(encoding="utf-8")).values():
        for row in rows[1:]:
            if len(row) >= 5:
                host, cell = strip_md(row[0]).lower(), strip_md(row[4])
                if host not in managed:
                    continue
                if cell and cell != "—" and (host, cell) not in seen:
                    seen.add((host, cell))
                    out.setdefault(host, []).append(("docs/network.md", cell))

    return out


# The Suricata runbook carries the only prose claim about what pfSense version
# the box is on right now — "`morpheus` now runs 2.9.0-RELEASE". It was written
# by the change that fixed the drift this script exists to catch, so it is
# exactly the kind of line that goes stale next.
RUNBOOK = "docs/runbooks/enable-suricata.md"
RUNBOOK_CLAIM = re.compile(r"`morpheus`\s+now\s+runs\s+([0-9][^\s,]*)")

# The claim is about one box, so the series is selected by device rather than by
# being the first that parses. sysDescr is NOT morpheus-only: the ilo module
# walks it too, and `shiva` answers "Integrated Lights-Out 4 2.82 Feb 06 2023" —
# which sorts first in the query result today and is skipped only because 2.82
# has two components rather than three. An iLO firmware numbered 2.82.1, or any
# future device in a module that walks sysDescr, would otherwise have this
# comparing the runbook's pfSense claim against the wrong machine, and reporting
# it under morpheus's name.
PFSENSE_DEVICE = "morpheus"
PFSENSE_VERSION = re.compile(r"\b(\d+\.\d+\.\d+-\S+)")


def check_runbook_pfsense_version(prom: str, failures: list[str]) -> None:
    descr = None
    for entry in query(prom, "sysDescr"):
        metric = entry["metric"]
        device = (metric.get("device") or metric.get("instance") or "").lower()
        if device == PFSENSE_DEVICE:
            descr = metric.get("sysDescr", "")
            break

    if descr is None:
        skip(f"pfSense version — nothing reports sysDescr for {PFSENSE_DEVICE}")
        return

    match = PFSENSE_VERSION.search(descr)
    if match is None:
        fail(
            f"pfSense version — {PFSENSE_DEVICE} reports sysDescr {descr!r}, "
            f"which carries no version this can read"
        )
        failures.append(f"sysDescr:{PFSENSE_DEVICE}")
        return
    running = match.group(1)

    path = HARDWARE_MD.parent.parent / RUNBOOK
    claim = RUNBOOK_CLAIM.search(path.read_text(encoding="utf-8"))
    if claim is None:
        skip(f"pfSense version — {RUNBOOK} makes no claim about it")
        return

    if claim.group(1) == running:
        pass_(f"{RUNBOOK} says morpheus runs {running}; it does")
    else:
        fail(
            f"{RUNBOOK} says morpheus runs {claim.group(1)}; sysDescr says {running}"
        )
        failures.append(RUNBOOK)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prometheus", default="http://localhost:9090")
    parser.add_argument(
        "--list", action="store_true", help="print what each source reports"
    )
    args = parser.parse_args()

    running = running_versions(args.prometheus)

    if args.list:
        info("what the hosts report")
        for host, (value, source) in sorted(running.items()):
            print(f"  {host:<12} {value:<34} ({source})")
        return 0

    documented = documented_versions()
    failures: list[str] = []

    print(f"\n{BOLD}OS versions, documents against the running hosts{OFF}")
    for host in sorted(documented):
        if host in NO_COMPARABLE_SOURCE:
            skip(f"{host} — {NO_COMPARABLE_SOURCE[host]}")
            continue
        if host not in running:
            skip(f"{host} — nothing reports an OS for it")
            continue

        value, source = running[host]
        want = release_line(os_key(value))
        for document, cell in documented[host]:
            if release_line(os_key(cell)) == want:
                pass_(f"{document} says {host} runs {cell!r}; {source} agrees")
            else:
                fail(
                    f"{document} says {host} runs {cell!r}; {source} reports "
                    f"{value!r}"
                )
                failures.append(f"{document}:{host}")

    print(f"\n{BOLD}The one version claim in prose{OFF}")
    check_runbook_pfsense_version(args.prometheus, failures)

    print()
    sys.stdout.flush()
    if failures:
        print(
            f"{RED}{len(failures)} document(s) disagree with the running "
            f"system{OFF}",
            file=sys.stderr,
        )
        return 1
    print(f"{GREEN}versions OK — every documented OS matches the host{OFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
