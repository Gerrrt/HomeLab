#!/usr/bin/env python3
"""Check what this repository claims about segmentation against the firewall.

THE GAP THIS EXISTS FOR (#363, and ADR-0026's one open consequence). Every other
fact in the documents is cross-checked against something: `check_docs.py` reads
snmp.yaml, compose.yaml and the rule files; `check_versions.py` asks Prometheus;
`check_loki_coverage.py` asks Loki. Prose about the firewall is checked against
nothing, and on 2026-09-06 alone it was wrong three times:

  * ADR-0013's "default deny does not hold for the switch LAN" went stale four
    days before anyone noticed (#344).
  * Its correction asserted the switch LAN "still reaches every segment
    outbound", false since 2026-09-02 (#229).
  * ADR-0025 said `50 -> 30` and `50 -> 99` "remain wholesale paths that no rule
    grants and no rule denies". `Block access to Winterfell` was created
    2026-09-02 03:47 UTC and `Allow Hicks access to ImaginationLAN` at 03:40,
    so by then one was denied and the other granted by name.

All three are the same mistake: a claim about `pfctl` carried forward without
being read off `pfctl`. None of them could have been caught in CI.

WHY THE RULESET CANNOT COME INTO THE REPOSITORY. `scripts/backup-firewall.sh`
and `docs/security.md` both say it: rule bodies and the WAN address are not
published, `backups/` is gitignored, and `make validate` and CI both assert
nothing under it is tracked. So this check runs where the truth is — reading the
live ruleset over SSH and comparing it against a small declaration that names
segments and nothing else. It never writes a rule body anywhere, and its output
names rules by `descr` only.

WHAT IT ASSERTS. One question, asked per interface and per address family:

    which other segments can be reached through this interface's catch-all
    `pass ... to any`, because no full-segment block sits above it?

That set is what "default deny" means here operationally, and it is what all
three wrong claims above got wrong. `docs/firewall-claims.yaml` declares the
answer; this script derives it from the running firewall and diffs the two.

WHAT COUNTS AS A COVERING BLOCK, deliberately narrowly: a `quick` block, of the
same address family, from the interface's own network macro to the whole target
macro, with no proto or port. Hicks' `Block SSH to pfSense` is a block above the
catch-all and does NOT count, because it closes a port rather than a segment.
Reading it as one would report Hicks as safer than it is, which is the direction
that matters.

WHAT IT DOES NOT ASSERT. Not the pass rules — which hosts and ports are excepted
is `network.md`'s enumerated list, it changes far more often, and every entry is
a rule body. Not reachability: this reads the ruleset, it does not send packets.
A rule can be present and the segment still unreachable for other reasons.

Usage: scripts/check_firewall_claims.py [--derive] [--claims PATH]
       --derive prints the live posture as YAML, for updating the claims file.

Environment: FW_HOST (default 10.0.99.1), FW_USER (default root) — the same
pair scripts/backup-firewall.sh uses.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys

try:
    import yaml
except ModuleNotFoundError:
    print("installing PyYAML", file=sys.stderr)
    if subprocess.run(
        [sys.executable, "-m", "pip", "install", "--quiet",
         "--disable-pip-version-check", "pyyaml"],
        check=False,
    ).returncode:
        sys.exit("PyYAML is required and could not be installed")
    import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
CLAIMS = REPO / "docs" / "firewall-claims.yaml"

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
RESET = "\033[0m"

FAMILIES = ("inet", "inet6")

# pfctl prints labels and a ridentifier after the rule body. Stripping them
# first lets every pattern below anchor on `$`, which is what makes "no proto,
# no port" checkable by matching rather than by trying to prove an absence.
NOISE = re.compile(r'\s*(label\s+"[^"]*"|ridentifier\s+\d+)')

# The interface's own network, taken from its catch-all rather than guessed.
# Nothing here hardcodes which macro belongs to which VLAN: OPT1..OPT6 are
# assigned in the order pfSense's interfaces were created, and a table of them
# in this repository would be one more hand-maintained fact that can go stale.
CATCH_ALL = re.compile(
    r"^pass\s+in\s+quick\s+on\s+(\S+)\s+(inet6?)\s+from\s+<(\w+)__NETWORK>\s+to\s+any\b"
)
FULL_BLOCK = re.compile(
    r"^block\s+drop\s+in(?:\s+log)?\s+quick\s+on\s+(\S+)\s+(inet6?)"
    r"\s+from\s+<(\w+)__NETWORK>\s+to\s+<(\w+)__NETWORK>\s*$"
)


def fetch_rules() -> list[str]:
    """The running ruleset, in order. Order is the whole point — `quick` means
    first match wins, so a block below the catch-all blocks nothing."""
    host = os.environ.get("FW_HOST", "10.0.99.1")
    user = os.environ.get("FW_USER", "root")
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         f"{user}@{host}", "pfctl -a '*' -sr"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        sys.exit(
            f"cannot read the ruleset from {user}@{host}: "
            f"{detail[-1] if detail else 'ssh failed'}\n"
            f"This is a deploy-time check and needs a key that reaches the "
            f"firewall; it cannot run in CI, for the reason in the header."
        )
    return [NOISE.sub("", line).strip() for line in result.stdout.splitlines()]


def derive(rules: list[str]) -> dict[str, dict]:
    """Per interface: its macro, and what its catch-all leaves reachable.

    Returns {iface: {"macro": str, "wholesale": {family: [macro, ...]}}}, where
    a family maps to [] both when every other segment is blocked above the
    catch-all AND when there is no catch-all at all. Those are different rulesets
    and the same posture: nothing falls through to `any`.
    """
    catch_all: dict[tuple[str, str], int] = {}
    macro_of: dict[str, str] = {}
    for i, line in enumerate(rules):
        m = CATCH_ALL.match(line)
        if not m:
            continue
        iface, family, macro = m.groups()
        catch_all.setdefault((iface, family), i)
        macro_of.setdefault(iface, macro)

    every = set(macro_of.values())
    posture: dict[str, dict] = {}
    for iface, macro in sorted(macro_of.items()):
        wholesale: dict[str, list[str]] = {}
        for family in FAMILIES:
            index = catch_all.get((iface, family))
            if index is None:
                # No catch-all for this family, so nothing falls through to it.
                wholesale[family] = []
                continue
            blocked = set()
            for line in rules[:index]:
                b = FULL_BLOCK.match(line)
                if b and b.group(1) == iface and b.group(2) == family \
                        and b.group(3) == macro:
                    blocked.add(b.group(4))
            wholesale[family] = sorted(every - blocked - {macro})
        posture[iface] = {"macro": macro, "wholesale": wholesale}
    return posture


def load_claims(path: pathlib.Path) -> dict:
    if not path.is_file():
        sys.exit(f"no claims file at {path} — run with --derive to write one")
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(data.get("interfaces"), dict) or not data["interfaces"]:
        sys.exit(f"{path} declares no interfaces")
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--claims", type=pathlib.Path, default=CLAIMS)
    ap.add_argument(
        "--derive", action="store_true",
        help="print the live posture as YAML instead of checking it",
    )
    args = ap.parse_args()

    posture = derive(fetch_rules())
    if not posture:
        sys.exit(
            "no interface catch-all rules matched at all. Either every interface "
            "was rewritten, or pfctl's output format changed and this parser is "
            "reporting silence as success — which is the failure it exists to "
            "prevent. Stopping rather than passing."
        )

    if args.derive:
        # Segment names are the one thing the firewall cannot tell us — pf knows
        # OPT4, not "ImaginationLAN" — so they are carried over from the existing
        # claims file where it has them and left blank where it does not.
        known = {}
        if args.claims.is_file():
            known = (yaml.safe_load(args.claims.read_text(encoding="utf-8")) or {}) \
                .get("interfaces", {})
        out = {
            iface: {
                "segment": (known.get(iface) or {}).get("segment", "CHANGE ME"),
                "wholesale": {f: v["wholesale"][f] for f in FAMILIES},
            }
            for iface, v in posture.items()
        }
        print(yaml.safe_dump({"interfaces": out}, sort_keys=True, default_flow_style=False))
        return 0

    claims = load_claims(args.claims)
    declared = claims["interfaces"]
    failures: list[str] = []

    def name(iface: str) -> str:
        return (declared.get(iface) or {}).get("segment", iface)

    # An interface nobody declared is the shape of "a VLAN was added and no
    # document mentions it", which is worth failing on rather than skipping.
    for iface in sorted(set(posture) - set(declared)):
        failures.append(f"{iface} is on the firewall and not in {args.claims.name}")
        print(f"{RED}  FAIL{RESET} {iface}: on the firewall, undeclared here")
    for iface in sorted(set(declared) - set(posture)):
        failures.append(f"{iface} is declared here and has no catch-all on the firewall")
        print(
            f"{RED}  FAIL{RESET} {iface} ({name(iface)}): declared here, but the "
            f"firewall has no catch-all pass for it"
        )

    for iface in sorted(set(posture) & set(declared)):
        live = posture[iface]["wholesale"]
        want = (declared[iface] or {}).get("wholesale") or {}
        for family in FAMILIES:
            got = live[family]
            expected = want.get(family) or []
            if sorted(expected) == got:
                shape = ", ".join(name_for(declared, posture, m) for m in got) or "nothing"
                print(
                    f"{GREEN}  PASS{RESET} {iface} ({name(iface)}) {family}: "
                    f"catch-all reaches {shape}"
                )
                continue
            gained = sorted(set(got) - set(expected))
            closed = sorted(set(expected) - set(got))
            detail = []
            if gained:
                detail.append(
                    "now reaches "
                    + ", ".join(name_for(declared, posture, m) for m in gained)
                    + " through its catch-all, which is not declared"
                )
            if closed:
                detail.append(
                    "no longer reaches "
                    + ", ".join(name_for(declared, posture, m) for m in closed)
                    + " — the block landed and the documents still say otherwise"
                )
            msg = f"{iface} ({name(iface)}) {family}: " + "; ".join(detail)
            failures.append(msg)
            print(f"{RED}  FAIL{RESET} {msg}")

    if failures:
        sys.stdout.flush()
        print(
            f"\n{len(failures)} claim(s) in {args.claims.name} disagree with the "
            f"running firewall.\nThe firewall is right and the file is stale — it "
            f"is the document that has to move. Re-derive with:\n"
            f"  scripts/check_firewall_claims.py --derive\n"
            f"then update the prose that cites it: docs/network.md, "
            f"docs/security.md. ADRs are immutable (ADR-0001) and get a marked "
            f"amendment or a superseding ADR, never an edit in place.",
            file=sys.stderr,
        )
        return 1

    print(
        f"\nfirewall claims OK — {len(posture)} interface(s), "
        f"{len(FAMILIES) * len(posture)} posture assertion(s) against the live ruleset"
    )
    return 0


def name_for(declared: dict, posture: dict[str, dict], macro: str) -> str:
    """A macro rendered as the segment name, when something knows it.

    Macros are the only cross-interface identity pf gives us, and `OPT4` in a
    failure message is not something an operator can act on.
    """
    for iface, spec in posture.items():
        if spec["macro"] == macro:
            return (declared.get(iface) or {}).get("segment") or macro
    return macro


if __name__ == "__main__":
    sys.exit(main())
