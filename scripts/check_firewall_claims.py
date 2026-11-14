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
names rules by `descr` only and the firewall's addresses by the segment they
sit on, never by number.

WHAT IT ASSERTS. Two questions, per interface.

1. `wholesale`, per address family: which other segments can be reached
   through this interface's catch-all `pass ... to any`, because no
   full-segment block sits above it? That set is what "default deny" means here
   operationally, and it is what all three wrong claims above got wrong.

2. `firewall` (ADR-0117): which of the firewall's OWN addresses does a host on
   this segment reach on ssh, http and https? The 2026-11-13 audit found every
   segment reaching the admin UI and sshd on the WAN address, under rules
   named *Block HTTPS to pfSense*: each block named only its own interface's
   address, and the catch-all's `to any` carried everything else. Question 1
   could not see that, because the WAN address is in no segment. This one
   evaluates the ruleset for each address the firewall holds, in order, first
   `quick` match wins, so a named pass above the block and a block that names
   one address of several both show up as what they are.

`docs/firewall-claims.yaml` declares both answers; this script derives them from
the running firewall and diffs the two.

WHAT COUNTS AS A COVERING BLOCK for question 1, deliberately narrowly: a `quick`
block, of the same address family, from the interface's own network macro to
the whole target macro, with no proto or port. Hicks' `Block SSH to pfSense` is
a block above the catch-all and does NOT count, because it closes a port rather
than a segment. Reading it as one would report Hicks as safer than it is, which
is the direction that matters.

HOW QUESTION 2 IS EVALUATED. The source is "a host on this segment": a rule
from `any` or from the interface's own network macro applies to it, and a rule
from a single host or a narrower table does not. So a host-scoped pass — Winterfell's
`prometheus` to `10.0.99.1:22` — is not a path for the segment, and the claims
file lists it in prose rather than in the derived set. Every unknown is
resolved toward "reachable": an unrecognised port name or table counts as
matching for a pass and not matching for a block, so a parser gap reads as an
open path and fails, never as a closed one that passes. A rule this parser
cannot read at all stops the run.

WHAT IT DOES NOT ASSERT. Not the other pass rules — which hosts and ports are
excepted between segments is `network.md`'s enumerated list, it changes far
more often, and every entry is a rule body. Not reachability: this reads the
ruleset, it does not send packets. A rule can be present and the segment still
unreachable for other reasons, and a daemon that does not listen is not
reached however the rules read.

Usage: scripts/check_firewall_claims.py [--derive] [--claims PATH]
       scripts/check_firewall_claims.py --self-test
       --derive prints the live posture as YAML, for updating the claims file.

Environment: FW_HOST (default 10.0.99.1), FW_USER (default root) — the same
pair scripts/backup-firewall.sh uses.
"""

from __future__ import annotations

import argparse
import ipaddress
import os
import pathlib
import re
import socket
import subprocess
import sys
from dataclasses import dataclass

REPO = pathlib.Path(__file__).resolve().parent.parent
CLAIMS = REPO / "docs" / "firewall-claims.yaml"

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
RESET = "\033[0m"

FAMILIES = ("inet", "inet6")

# The management ports question 2 asks about, by the names pfctl prints.
MANAGEMENT = {"ssh": 22, "http": 80, "https": 443}

# pfctl prints labels and a ridentifier after the rule body. Stripping them
# first lets every pattern below anchor on `$`, which is what makes "no proto,
# no port" checkable by matching rather than by trying to prove an absence.
NOISE = re.compile(r'\s*(label\s+"[^"]*"|ridentifier\s+\d+)')

# The interface's own network, taken from its catch-all rather than guessed.
# Nothing here hardcodes which macro belongs to which VLAN: OPT1..OPT6 are
# assigned in the order pfSense's interfaces were created, and a table of them
# in this repository would be one more hand-maintained fact that can go stale.
CATCH_ALL = re.compile(r"^pass\s+in\s+quick\s+on\s+(\S+)\s+(inet6?)\s+from\s+<(\w+)__NETWORK>\s+to\s+any\b")
FULL_BLOCK = re.compile(
    r"^block\s+drop\s+in(?:\s+log)?\s+quick\s+on\s+(\S+)\s+(inet6?)"
    r"\s+from\s+<(\w+)__NETWORK>\s+to\s+<(\w+)__NETWORK>\s*$"
)

# One pf address, as pfctl prints it: any, a table, an interface in parens, a
# brace list, or an address with an optional prefix — each optionally negated.
ADDR = r"(?:!\s*)?(?:any|no-route|self|\{[^}]*\}|<[^>]+>|\([^)]+\)|[0-9A-Fa-f:.]+(?:/\d+)?)"
PORT = r"(?:[!<>]=?\s*\S+|=\s*\S+|\{[^}]*\}|\S+\s*(?:<>|><)\s*\S+|\S+)"
RULE = re.compile(
    r"^(?P<action>pass|block)\b(?:\s+(?:drop|return-rst(?:\([^)]*\))?|return-icmp6?(?:\([^)]*\))?|return))?"
    r"(?:\s+(?P<dir>in|out))?"
    r"(?:\s+log(?:\s*\([^)]*\))?)?"
    r"(?P<quick>\s+quick)?"
    r"(?:\s+on\s+(?P<neg>!\s*)?(?P<iface>[^\s(]+))?"
    r"(?:\s+(?:route-to|reply-to|dup-to)\s+\([^)]*\))?"
    r"(?:\s+(?P<af>inet6?))?"
    r"(?:\s+proto\s+(?P<proto>\{[^}]*\}|\S+))?"
    r"\s+(?:(?P<all>all)\b|from\s+(?P<src>" + ADDR + r")(?:\s+port\s+(?P<sport>" + PORT + r"))?"
    r"\s+to\s+(?P<dst>" + ADDR + r")(?:\s+port\s+(?P<dport>" + PORT + r"))?)"
)

# What the firewall answers on, read off `ifconfig`. Loopback and pf's own
# pseudo-interfaces hold no address a segment can be routed to.
SKIP_IFACES = re.compile(r"^(lo|pflog|pfsync|enc)\d*$")

# The ranges the estate addresses itself from (RFC 1918 and ULA). An address the
# firewall holds outside them is its WAN side.
INTERNAL = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7")]


@dataclass(frozen=True)
class Rule:
    action: str  # pass | block
    direction: str | None  # in | out | None (both)
    quick: bool
    iface: str | None
    iface_negated: bool
    family: str | None
    proto: str | None
    src: str
    sport: str | None
    dst: str
    dport: str | None
    text: str


@dataclass(frozen=True)
class Address:
    iface: str
    ip: ipaddress.IPv4Address | ipaddress.IPv6Address
    net: ipaddress.IPv4Network | ipaddress.IPv6Network


def ssh(script: str) -> str:
    """Run a POSIX sh script on the firewall and return its stdout.

    The script goes on stdin to `sh -s` rather than on the command line,
    because root's login shell on pfSense is not sh and the table loop below
    is sh syntax."""
    host = os.environ.get("FW_HOST", "10.0.99.1")
    user = os.environ.get("FW_USER", "root")
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", f"{user}@{host}", "sh -s"],
        input=script,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        sys.exit(
            f"cannot read the firewall at {user}@{host}: "
            f"{detail[-1] if detail else 'ssh failed'}\n"
            f"This is a deploy-time check and needs a key that reaches the "
            f"firewall; it cannot run in CI, for the reason in the header."
        )
    return result.stdout


def clean(lines: list[str]) -> list[str]:
    return [NOISE.sub("", line).strip() for line in lines]


def fetch() -> tuple[list[str], str, dict[str, list[str]]]:
    """The running ruleset in order, `ifconfig`, and every table a rule names.

    Order is the whole point — `quick` means first match wins, so a block below
    the catch-all blocks nothing. Table contents stay in memory: the WAN
    network is in one of them, and nothing here prints an address it read."""
    marker = "@@HOMELAB-IFCONFIG@@"
    out = ssh(f"pfctl -a '*' -sr\necho '{marker}'\nifconfig\n")
    if marker not in out:
        sys.exit("the firewall's answer has no ifconfig section — stopping rather than passing")
    rules_text, ifconfig = out.split(marker, 1)
    rules = clean(rules_text.splitlines())
    names = sorted({t for line in rules for t in re.findall(r"<(\w+)>", line)})
    tables: dict[str, list[str]] = {}
    if names:
        # A rule can name a table pf has not created (an empty alias, a VPN
        # that is not configured); `-T show` fails on it, and that is an empty
        # table, not a failed read.
        script = "".join(f"echo '@@T {n}'; pfctl -t '{n}' -T show 2>/dev/null || :\n" for n in names)
        current = None
        for line in ssh(script).splitlines():
            if line.startswith("@@T "):
                current = line[4:].strip()
                tables[current] = []
            elif current is not None and line.strip():
                tables[current].append(line.strip())
    return rules, ifconfig, tables


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
                if b and b.group(1) == iface and b.group(2) == family and b.group(3) == macro:
                    blocked.add(b.group(4))
            wholesale[family] = sorted(every - blocked - {macro})
        posture[iface] = {"macro": macro, "wholesale": wholesale}
    return posture


# --- Question 2: the firewall's own addresses ---------------------------------


def parse_ifconfig(text: str) -> list[Address]:
    addresses: list[Address] = []
    iface = None
    for line in text.splitlines():
        head = re.match(r"^(\S+?):\s+flags=", line)
        if head:
            iface = head.group(1)
            continue
        if iface is None or SKIP_IFACES.match(iface):
            continue
        v4 = re.match(r"^\s+inet\s+(\S+)\s+netmask\s+(0x[0-9a-fA-F]+)", line)
        if v4:
            ip = ipaddress.ip_address(v4.group(1))
            net = ipaddress.ip_network(f"{ip}/{int(v4.group(2), 16).bit_count()}", strict=False)
            addresses.append(Address(iface, ip, net))
            continue
        v6 = re.match(r"^\s+inet6\s+([0-9A-Fa-f:]+)(?:%\S+)?\s+prefixlen\s+(\d+)", line)
        if v6:
            ip = ipaddress.ip_address(v6.group(1))
            net = ipaddress.ip_network(f"{ip}/{v6.group(2)}", strict=False)
            addresses.append(Address(iface, ip, net))
    return addresses


def parse_rules(lines: list[str]) -> tuple[list[Rule], list[str]]:
    """Every pass and block rule, and the ones this parser could not read.

    `match`, `anchor`, `ether` and the rest are not decisions and are skipped.
    An outbound rule is kept unparsed-tolerant: it never decides inbound."""
    rules: list[Rule] = []
    unreadable: list[str] = []
    for line in lines:
        if not re.match(r"^(pass|block)\b", line):
            continue
        m = RULE.match(line)
        if not m:
            if not re.match(r"^(pass|block)\b(?:\s+\S+)*?\s+out\b", line):
                unreadable.append(line)
            continue
        g = m.groupdict()
        rules.append(
            Rule(
                action=g["action"],
                direction=g["dir"],
                quick=bool(g["quick"]),
                iface=g["iface"],
                iface_negated=bool(g["neg"]),
                family=g["af"],
                proto=g["proto"],
                src="any" if g["all"] else g["src"].strip(),
                sport=g["sport"],
                dst="any" if g["all"] else g["dst"].strip(),
                dport=g["dport"],
                text=line,
            )
        )
    return rules, unreadable


def port_number(name: str) -> int | None:
    name = name.strip()
    if name.isdigit():
        return int(name)
    if name in MANAGEMENT:
        return MANAGEMENT[name]
    try:
        return socket.getservbyname(name, "tcp")
    except OSError:
        return None


def port_matches(spec: str | None, port: int, lenient: bool) -> bool:
    """Does `port` fall in a pfctl port spec? `lenient` answers the unknowns."""
    if spec is None:
        return True
    spec = spec.strip()
    if spec.startswith("{"):
        return any(port_matches(p, port, lenient) for p in spec.strip("{} ").replace(",", " ").split())
    m = re.match(r"^(!=|<=|>=|=|<|>)\s*(\S+)$", spec)
    if m:
        n = port_number(m.group(2))
        if n is None:
            return lenient
        return {
            "=": port == n,
            "!=": port != n,
            "<": port < n,
            "<=": port <= n,
            ">": port > n,
            ">=": port >= n,
        }[m.group(1)]
    m = re.match(r"^(\S+?)\s*(:|><|<>)\s*(\S+)$", spec)
    if m:
        lo, hi = port_number(m.group(1)), port_number(m.group(3))
        if lo is None or hi is None:
            return lenient
        return {":": lo <= port <= hi, "><": lo < port < hi, "<>": port < lo or port > hi}[m.group(2)]
    n = port_number(spec)
    return lenient if n is None else port == n


def carries_tcp(proto: str | None) -> bool:
    if proto is None:
        return True
    return "tcp" in proto.strip("{} ").replace(",", " ").split()


def table_networks(entries: list[str]) -> list:
    nets = []
    for entry in entries:
        if entry.startswith("!"):
            continue  # a negated entry excludes; ignoring it errs toward matching
        try:
            nets.append(ipaddress.ip_network(entry.split()[0], strict=False))
        except ValueError:
            continue
    return nets


def contains(nets: list, target) -> bool:
    if isinstance(target, (ipaddress.IPv4Network, ipaddress.IPv6Network)):
        return any(n.version == target.version and target.subnet_of(n) for n in nets)
    return any(n.version == target.version and target in n for n in nets)


def split_negation(spec: str) -> tuple[bool, str]:
    if spec.startswith("!"):
        return True, spec[1:].strip()
    return False, spec


def source_matches(spec: str, own_macro: str, own_nets: list, tables: dict, lenient: bool) -> bool:
    """Does a rule's source take in "a host on this segment"?

    Only `any`, the segment's own network macro, or something that contains the
    whole of the segment's network does. A host or a narrower table is a
    host-scoped exception, not a path for the segment."""
    negated, spec = split_negation(spec)

    def inner() -> bool:
        if spec in ("any", "all"):
            return True
        if spec.startswith("{"):
            return any(
                source_matches(s, own_macro, own_nets, tables, lenient)
                for s in spec.strip("{} ").replace(",", " ").split()
            )
        if spec.startswith("<"):
            name = spec.strip("<>")
            if name == f"{own_macro}__NETWORK":
                return True
            if name not in tables:
                return lenient
            nets = table_networks(tables[name])
            return any(contains(nets, own) for own in own_nets)
        if spec.startswith("(") or spec in ("self", "no-route"):
            return False  # the firewall's own address, never a segment host
        try:
            net = ipaddress.ip_network(spec, strict=False)
        except ValueError:
            return lenient
        return any(contains([net], own) for own in own_nets)

    return (not inner()) if negated else inner()


def destination_matches(spec: str, target: Address, addresses: list[Address], tables: dict, lenient: bool) -> bool:
    negated, spec = split_negation(spec)

    def inner() -> bool:
        if spec in ("any", "all", "(self)", "self"):
            return True
        if spec == "no-route":
            return False
        if spec.startswith("{"):
            return any(
                destination_matches(s, target, addresses, tables, lenient)
                for s in spec.strip("{} ").replace(",", " ").split()
            )
        if spec.startswith("("):
            name, _, modifier = spec.strip("()").partition(":")
            held = [a for a in addresses if a.iface == name]
            if not held:
                return lenient
            if modifier in ("network",):
                return any(target.ip in a.net for a in held)
            return any(target.ip == a.ip for a in held)
        if spec.startswith("<"):
            name = spec.strip("<>")
            if name not in tables:
                return lenient
            return contains(table_networks(tables[name]), target.ip)
        try:
            net = ipaddress.ip_network(spec, strict=False)
        except ValueError:
            return lenient
        return target.ip in net

    return (not inner()) if negated else inner()


def reaches(
    rules: list[Rule],
    iface: str,
    own_macro: str,
    own_nets: list,
    target: Address,
    port: int,
    addresses: list[Address],
    tables: dict,
) -> bool:
    """pf's own evaluation, for one segment host, one firewall address, one port.

    First matching `quick` rule decides; otherwise the last matching non-quick
    rule does; otherwise pf passes. Unknowns resolve toward the rule's action
    being taken for a pass and skipped for a block — toward "reachable"."""
    family = "inet" if target.ip.version == 4 else "inet6"
    last: str | None = None
    for r in rules:
        if r.direction == "out":
            continue
        if r.iface is not None and (r.iface == iface) == r.iface_negated:
            continue
        if r.family is not None and r.family != family:
            continue
        if not carries_tcp(r.proto):
            continue
        lenient = r.action == "pass"
        # A source-port condition narrows a block to less than "this segment",
        # so it never covers; on a pass, client ports are ephemeral, so it counts.
        if r.sport is not None and not lenient:
            continue
        if not source_matches(r.src, own_macro, own_nets, tables, lenient):
            continue
        if not destination_matches(r.dst, target, addresses, tables, lenient):
            continue
        if not port_matches(r.dport, port, lenient):
            continue
        if r.quick:
            return r.action == "pass"
        last = r.action
    return last != "block"


def address_name(a: Address, segments: dict[str, str]) -> str:
    """The firewall's address, named by where it sits and never by number."""
    if a.ip.is_link_local:
        return "link-local"
    if a.iface in segments:
        return segments[a.iface]
    # Not ipaddress's is_private, which counts the documentation and CGNAT
    # ranges as private: anything outside the estate's own ranges is the WAN.
    if not any(a.ip in n for n in INTERNAL):
        return "WAN"
    return a.iface


def derive_firewall(
    rules: list[Rule],
    posture: dict[str, dict],
    addresses: list[Address],
    tables: dict,
    segments: dict[str, str],
) -> dict[str, dict[str, list[str]]]:
    """Per interface: which of the firewall's addresses a host there reaches,
    per management port, as names. A link-local address is only reachable from
    its own link, so each interface is asked about its own and no other."""
    out: dict[str, dict[str, list[str]]] = {}
    for iface, spec in posture.items():
        own_nets = [a.net for a in addresses if a.iface == iface and not a.ip.is_link_local]
        targets = [a for a in addresses if not a.ip.is_link_local or a.iface == iface]
        out[iface] = {
            name: sorted(
                {
                    address_name(t, segments)
                    for t in targets
                    if reaches(rules, iface, spec["macro"], own_nets, t, port, addresses, tables)
                }
            )
            for name, port in MANAGEMENT.items()
        }
    return out


# --- The claims file ----------------------------------------------------------


def load_yaml():
    # PyYAML from the one pinned bootstrap, scripts/_deps.py (#848). Imported
    # here rather than at the top so --self-test needs nothing beyond python3.
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    from _deps import require_yaml

    return require_yaml()


def load_claims(path: pathlib.Path) -> dict:
    yaml = load_yaml()
    if not path.is_file():
        sys.exit(f"no claims file at {path} — run with --derive to write one")
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(data.get("interfaces"), dict) or not data["interfaces"]:
        sys.exit(f"{path} declares no interfaces")
    return data


def compare(declared: dict, posture: dict, firewall: dict, claims_name: str) -> tuple[list[str], bool]:
    """Print a line per assertion; return the failures, and whether any of them
    is a segment that gained a path to the firewall itself."""
    failures: list[str] = []
    opened = False

    def name(iface: str) -> str:
        return (declared.get(iface) or {}).get("segment", iface)

    # An interface nobody declared is the shape of "a VLAN was added and no
    # document mentions it", which is worth failing on rather than skipping.
    for iface in sorted(set(posture) - set(declared)):
        failures.append(f"{iface} is on the firewall and not in {claims_name}")
        print(f"{RED}  FAIL{RESET} {iface}: on the firewall, undeclared here")
    for iface in sorted(set(declared) - set(posture)):
        failures.append(f"{iface} is declared here and has no catch-all on the firewall")
        print(
            f"{RED}  FAIL{RESET} {iface} ({name(iface)}): declared here, but the firewall has no catch-all pass for it"
        )

    for iface in sorted(set(posture) & set(declared)):
        live = posture[iface]["wholesale"]
        want = (declared[iface] or {}).get("wholesale") or {}
        for family in FAMILIES:
            got = live[family]
            expected = want.get(family) or []
            if sorted(expected) == got:
                shape = ", ".join(name_for(declared, posture, m) for m in got) or "nothing"
                print(f"{GREEN}  PASS{RESET} {iface} ({name(iface)}) {family}: catch-all reaches {shape}")
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

        want_fw = (declared[iface] or {}).get("firewall")
        if want_fw is None:
            msg = f"{iface} ({name(iface)}): no `firewall` declared — re-derive the claims file"
            failures.append(msg)
            print(f"{RED}  FAIL{RESET} {msg}")
            continue
        for port in MANAGEMENT:
            got = firewall[iface][port]
            expected = sorted(want_fw.get(port) or [])
            if expected == got:
                shape = ", ".join(got) or "none of its addresses"
                print(f"{GREEN}  PASS{RESET} {iface} ({name(iface)}) {port}: reaches the firewall on {shape}")
                continue
            detail = []
            gained = sorted(set(got) - set(expected))
            closed = sorted(set(expected) - set(got))
            if gained:
                opened = True
                detail.append(f"now reaches the firewall on {port} at {plural(gained)}, which is not declared")
            if closed:
                detail.append(f"no longer reaches the firewall on {port} at {plural(closed)}")
            msg = f"{iface} ({name(iface)}): " + "; ".join(detail)
            failures.append(msg)
            print(f"{RED}  FAIL{RESET} {msg}")
    return failures, opened


def plural(names: list[str]) -> str:
    return f"its {names[0]} address" if len(names) == 1 else f"its {', '.join(names)} addresses"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--claims", type=pathlib.Path, default=CLAIMS)
    ap.add_argument(
        "--derive",
        action="store_true",
        help="print the live posture as YAML instead of checking it",
    )
    ap.add_argument("--self-test", action="store_true", help="run the fixtures and exit")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    lines, ifconfig, tables = fetch()
    posture = derive(lines)
    if not posture:
        sys.exit(
            "no interface catch-all rules matched at all. Either every interface "
            "was rewritten, or pfctl's output format changed and this parser is "
            "reporting silence as success — which is the failure it exists to "
            "prevent. Stopping rather than passing."
        )
    rules, unreadable = parse_rules(lines)
    if unreadable:
        # Rule bodies are not printed, because a WAN rule's body carries the
        # address. The position in `pfctl -a '*' -sr` is enough to find it.
        sys.exit(
            f"{len(unreadable)} inbound rule(s) this parser cannot read, so what reaches "
            f"the firewall's own addresses cannot be answered. Stopping rather than "
            f"passing. Lines of `pfctl -a '*' -sr`: " + ", ".join(str(lines.index(u) + 1) for u in unreadable)
        )
    addresses = parse_ifconfig(ifconfig)
    if not addresses:
        sys.exit("ifconfig showed the firewall holding no address — stopping rather than passing")

    yaml = load_yaml()
    known = {}
    if args.claims.is_file():
        known = (yaml.safe_load(args.claims.read_text(encoding="utf-8")) or {}).get("interfaces", {})
    segments = {iface: spec["segment"] for iface, spec in known.items() if (spec or {}).get("segment")}
    firewall = derive_firewall(rules, posture, addresses, tables, segments)

    if args.derive:
        # Segment names are the one thing the firewall cannot tell us — pf knows
        # OPT4, not "ImaginationLAN" — so they are carried over from the existing
        # claims file where it has them and left blank where it does not.
        out = {
            iface: {
                "segment": (known.get(iface) or {}).get("segment", "CHANGE ME"),
                "wholesale": {f: v["wholesale"][f] for f in FAMILIES},
                "firewall": firewall[iface],
            }
            for iface, v in posture.items()
        }
        print(yaml.safe_dump({"interfaces": out}, sort_keys=True, default_flow_style=False))
        return 0

    claims = load_claims(args.claims)
    failures, opened = compare(claims["interfaces"], posture, firewall, args.claims.name)

    if failures:
        sys.stdout.flush()
        if opened:
            # The one direction where the file is probably not the stale half.
            # A segment reaching the firewall's own admin UI or sshd is a rule
            # that names too little, the defect ADR-0117 closed; re-deriving
            # would write the hole into the claims file and call it policy.
            print(
                "\nA segment reaches the firewall itself on a management port the claims "
                "file does not grant. Treat that as a rule to fix before a claim to "
                "re-derive: see docs/runbooks/close-the-firewall-to-its-segments.md.",
                file=sys.stderr,
            )
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
        f"{(len(FAMILIES) + len(MANAGEMENT)) * len(posture)} posture assertion(s) against the live ruleset"
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


# --- Fixtures -----------------------------------------------------------------
#
# Synthetic, in the shape pfctl and ifconfig print. The WAN is 192.0.2.10, from
# the documentation range, so no fixture is a real rule body. Each case is the
# smallest ruleset that shows one way a block can close less than its name says.

FIXTURE_IFCONFIG = """\
em0: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
\tinet 192.0.2.10 netmask 0xfffffe00 broadcast 192.0.3.255
\tinet6 fe80::1%em0 prefixlen 64 scopeid 0x1
\tinet6 2001:db8::10 prefixlen 128
igc0.99: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
\tinet 10.0.99.1 netmask 0xffffff00 broadcast 10.0.99.255
\tinet6 fe80::2%igc0.99 prefixlen 64 scopeid 0x5
igc0.50: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
\tinet 10.0.50.1 netmask 0xffffff00 broadcast 10.0.50.255
\tinet6 fe80::2%igc0.50 prefixlen 64 scopeid 0x6
igc0.30: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
\tinet 10.0.30.1 netmask 0xffffff00 broadcast 10.0.30.255
\tinet6 fe80::2%igc0.30 prefixlen 64 scopeid 0x7
lo0: flags=1008049<UP,LOOPBACK,RUNNING,MULTICAST,LOWER_UP> metric 0 mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
"""

FIXTURE_TABLES = {
    "OPT1__NETWORK": ["10.0.99.0/24"],
    "OPT2__NETWORK": ["10.0.50.0/24"],
    "OPT4__NETWORK": ["10.0.30.0/24"],
    "sshguard": [],
}

DEFAULT_DENY = [
    "block drop in log inet all",
    "block drop in log inet6 all",
    "block drop in log quick proto tcp from <sshguard> to (self) port = ssh",
    "pass out inet all flags S/SA keep state allow-opts",
]

CATCH_ALL_99 = "pass in quick on igc0.99 inet from <OPT1__NETWORK> to any flags S/SA keep state"
CATCH_ALL_50 = "pass in quick on igc0.50 inet from <OPT2__NETWORK> to any flags S/SA keep state"
CATCH_ALL_30 = [
    "pass in quick on igc0.30 inet from <OPT4__NETWORK> to any flags S/SA keep state",
    "pass in quick on igc0.30 inet6 from <OPT4__NETWORK> to any flags S/SA keep state",
]
SEGMENTS = {"igc0.99": "Winterfell", "igc0.50": "Hicks", "igc0.30": "ImaginationLAN"}


def _blocks(iface: str, dst: str, fam: str = "inet") -> list[str]:
    return [
        f"block drop in quick on {iface} {fam} proto tcp from any to {dst} port = {p} flags S/SA"
        for p in ("ssh", "https", "http")
    ]


FIXTURES: list[tuple[str, list[str], str, dict[str, list[str]]]] = [
    (
        "a block naming its own address leaves the WAN address open (the 2026-11-13 finding)",
        [
            "block drop in quick on igc0.99 inet proto tcp from <OPT1__NETWORK> to 10.0.99.1 port = https flags S/SA",
            "block drop in quick on igc0.99 inet proto tcp from <OPT1__NETWORK> to 10.0.99.1 port = http flags S/SA",
            "block drop in quick on igc0.99 inet from <OPT1__NETWORK> to <OPT2__NETWORK>",
            "block drop in quick on igc0.99 inet from <OPT1__NETWORK> to <OPT4__NETWORK>",
            CATCH_ALL_99,
        ],
        "igc0.99",
        {"ssh": ["WAN", "Winterfell"], "http": ["WAN"], "https": ["WAN"]},
    ),
    (
        "blocks to (self) close every address, and a host-scoped pass above them is not the segment's",
        [
            "pass in quick on igc0.99 inet proto tcp from 10.0.99.20 to 10.0.99.1 port = ssh flags S/SA keep state",
            *_blocks("igc0.99", "(self)"),
            CATCH_ALL_99,
        ],
        "igc0.99",
        {"ssh": [], "http": [], "https": []},
    ),
    (
        "a named pass above the (self) blocks is the one way in",
        [
            "pass in quick on igc0.50 inet proto tcp from <OPT2__NETWORK> to <OPT1__NETWORK> port = ssh flags S/SA keep state",
            "pass in quick on igc0.50 inet proto tcp from <OPT2__NETWORK> to 10.0.99.1 port = https flags S/SA keep state",
            *_blocks("igc0.50", "(self)"),
            "pass in quick on igc0.50 inet proto tcp from <OPT2__NETWORK> to <OPT4__NETWORK> flags S/SA keep state",
            "block drop in log quick on igc0.50 inet from <OPT2__NETWORK> to <OPT1__NETWORK>",
            CATCH_ALL_50,
        ],
        "igc0.50",
        {"ssh": ["Winterfell"], "http": [], "https": ["Winterfell"]},
    ),
    (
        "a segment-wide pass above the blocks opens that segment's gateway too",
        [
            "pass in quick on igc0.50 inet proto tcp from <OPT2__NETWORK> to 10.0.99.1 port = https flags S/SA keep state",
            "pass in quick on igc0.50 inet proto tcp from <OPT2__NETWORK> to <OPT4__NETWORK> flags S/SA keep state",
            *_blocks("igc0.50", "(self)"),
            "block drop in log quick on igc0.50 inet from <OPT2__NETWORK> to <OPT1__NETWORK>",
            CATCH_ALL_50,
        ],
        "igc0.50",
        {"ssh": ["ImaginationLAN"], "http": ["ImaginationLAN"], "https": ["ImaginationLAN", "Winterfell"]},
    ),
    (
        "an IPv4-only block leaves the IPv6 catch-all reaching the WAN and its own link-local",
        [
            *_blocks("igc0.30", "(self)"),
            "block drop in quick on igc0.30 inet from <OPT4__NETWORK> to <OPT1__NETWORK>",
            "block drop in quick on igc0.30 inet from <OPT4__NETWORK> to <OPT2__NETWORK>",
            *CATCH_ALL_30,
        ],
        "igc0.30",
        {"ssh": ["WAN", "link-local"], "http": ["WAN", "link-local"], "https": ["WAN", "link-local"]},
    ),
    (
        "IPv4+IPv6 blocks to (self) close both families",
        [
            *_blocks("igc0.30", "(self)"),
            *_blocks("igc0.30", "(self)", "inet6"),
            "block drop in quick on igc0.30 inet from <OPT4__NETWORK> to <OPT1__NETWORK>",
            "block drop in quick on igc0.30 inet from <OPT4__NETWORK> to <OPT2__NETWORK>",
            *CATCH_ALL_30,
        ],
        "igc0.30",
        {"ssh": [], "http": [], "https": []},
    ),
    (
        "a pass to a port range does not open ssh, and an interface pass (anti-lockout) opens its own address",
        [
            "pass in quick on igc0.99 proto tcp from any to (igc0.99) port = https flags S/SA keep state",
            "pass in quick on igc0.99 inet proto tcp from <OPT1__NETWORK> to 10.0.99.1 port 2220:2229 flags S/SA keep state",
            *_blocks("igc0.99", "(self)"),
            CATCH_ALL_99,
        ],
        "igc0.99",
        {"ssh": [], "http": [], "https": ["Winterfell", "link-local"]},
    ),
    (
        "a block with a source-port condition covers nothing, and an unknown port name on a block covers nothing",
        [
            "block drop in quick on igc0.99 inet proto tcp from any port = 0 to (self) port = ssh",
            "block drop in quick on igc0.99 inet proto tcp from any to (self) port = no-such-service",
            "block drop in quick on igc0.99 inet proto tcp from any to (self) port = https",
            "block drop in quick on igc0.99 inet proto tcp from any to (self) port = http",
            CATCH_ALL_99,
        ],
        "igc0.99",
        {"ssh": ["Hicks", "ImaginationLAN", "WAN", "Winterfell"], "http": [], "https": []},
    ),
]


def self_test() -> int:
    failed = 0
    addresses = parse_ifconfig(FIXTURE_IFCONFIG)
    held = sorted(f"{a.iface} {a.ip}" for a in addresses)
    want_held = sorted(
        [
            "em0 192.0.2.10",
            "em0 fe80::1",
            "em0 2001:db8::10",
            "igc0.99 10.0.99.1",
            "igc0.99 fe80::2",
            "igc0.50 10.0.50.1",
            "igc0.50 fe80::2",
            "igc0.30 10.0.30.1",
            "igc0.30 fe80::2",
        ]
    )
    if held == want_held:
        print(f"{GREEN}  PASS{RESET} ifconfig: every address but loopback, with its interface")
    else:
        failed += 1
        print(f"{RED}  FAIL{RESET} ifconfig: got {held}")

    for title, body, iface, want in FIXTURES:
        lines = DEFAULT_DENY + body
        rules, unreadable = parse_rules(lines)
        posture = derive(lines)
        if unreadable or iface not in posture:
            failed += 1
            print(f"{RED}  FAIL{RESET} {title}: unreadable {unreadable}, posture {sorted(posture)}")
            continue
        got = derive_firewall(rules, {iface: posture[iface]}, addresses, FIXTURE_TABLES, SEGMENTS)[iface]
        if got == want:
            print(f"{GREEN}  PASS{RESET} {title}")
        else:
            failed += 1
            print(f"{RED}  FAIL{RESET} {title}: got {got}, want {want}")

    _, unreadable = parse_rules(["pass in quick on igc0.99 inet proto tcp frum any to any"])
    if unreadable:
        print(f"{GREEN}  PASS{RESET} a rule the parser cannot read is reported, not skipped")
    else:
        failed += 1
        print(f"{RED}  FAIL{RESET} an unreadable rule was skipped silently")

    wholesale = derive(
        [
            "block drop in log quick on igc0.50 inet from <OPT2__NETWORK> to <OPT1__NETWORK>",
            "block drop in quick on igc0.50 inet proto tcp from <OPT2__NETWORK> to 10.0.50.1 port = ssh",
            CATCH_ALL_50,
            CATCH_ALL_99,
        ]
    )
    if wholesale["igc0.50"]["wholesale"] == {"inet": [], "inet6": []} and wholesale["igc0.99"]["wholesale"] == {
        "inet": ["OPT2"],
        "inet6": [],
    }:
        print(f"{GREEN}  PASS{RESET} wholesale: a full-segment block covers, a port block does not count")
    else:
        failed += 1
        print(f"{RED}  FAIL{RESET} wholesale: got {wholesale}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
