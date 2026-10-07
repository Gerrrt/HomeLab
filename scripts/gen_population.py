#!/usr/bin/env python3
"""Generate the lab domain's user population into ansible/population/population.yaml (#449).

Usage: scripts/gen_population.py [--count N] [--seed S] [--check] [--self-test]
       --count N    ordinary users to draw, authgen not included (default 40)
       --seed S     the draw's seed, recorded in the file's header (default 449)
       --check      exit non-zero if the committed file is not what these
                    arguments generate, and change nothing
       --self-test  run the embedded fixtures and exit non-zero on any failure

WHAT THIS IS FOR. A domain with no users teaches nothing, and ADR-0029 stops
at the architecture. This draws a population from two name lists into a file
that ansible/roles/population applies and that later analysis can read as the
domain's intended shape. The file is committed and reviewed like code (decided
on #449, 2026-10-03), so it holds no passwords: those are derived on phoenix
from LAB_POPULATION_SEED and each sAMAccountName, never written down.

WHY DETERMINISTIC. The same --seed and --count give the same file, byte for
byte, so a regenerate that changes nothing produces no diff, and the file's
header is enough to reproduce it. --self-test checks the committed file against
its own header, which is what keeps it from being edited by hand.

WHAT IT DOES NOT DO. No account here is given a weakness. The deliberate
weaknesses are #449's tags, applied on top of this population, each one
separately.
"""

from __future__ import annotations

import argparse
import random
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POP_DIR = ROOT / "ansible" / "population"
OUT = POP_DIR / "population.yaml"
GIVEN = POP_DIR / "given-names.txt"
SURNAMES = POP_DIR / "surnames.txt"

DEFAULT_COUNT = 40
DEFAULT_SEED = 449

# Departments, the share of the population each draws, and the titles its
# people hold. Each department is an OU under OU=People and a global group of
# the same name under OU=Groups.
DEPARTMENTS = [
    ("Finance", 0.15, ["Accountant", "Financial Analyst", "Payroll Specialist", "Finance Manager"]),
    ("Human Resources", 0.10, ["HR Generalist", "Recruiter", "HR Manager"]),
    ("Engineering", 0.25, ["Software Engineer", "QA Engineer", "Engineering Manager", "Product Designer"]),
    ("Sales", 0.20, ["Account Executive", "Sales Representative", "Sales Manager"]),
    ("Operations", 0.15, ["Operations Analyst", "Office Manager", "Facilities Coordinator"]),
    ("IT", 0.15, ["Service Desk Analyst", "Systems Analyst", "IT Manager"]),
]

# Groups that cut across departments, each with the chance any one person is
# in it. Ordinary groups only: nothing here is delegated anything.
CROSS_GROUPS = [
    ("Remote Workers", 0.30, "People who work from home at least part of the week"),
    ("Project Atlas", 0.20, "Members of the Atlas project"),
    ("Project Borealis", 0.15, "Members of the Borealis project"),
]

# build-the-lab-domain.md §6's user, made by hand on 2026-10-02 to break the
# wait between #414 and this issue. Folded in rather than deleted (#449's
# 2026-10-02 comment), with a fixed name because two scheduled tasks run as it.
AUTHGEN = {
    "sam": "authgen",
    "given": "Authentication",
    "surname": "Generator",
    "department": "IT",
    "title": "Authentication generator (build-the-lab-domain.md section 6)",
    "groups": ["IT"],
}

HEADER_RE = re.compile(r"^# Regenerate: scripts/gen_population\.py --count (\d+) --seed (-?\d+)$", re.MULTILINE)


def read_names(path: Path) -> list[str]:
    names = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if not re.fullmatch(r"[A-Za-z][A-Za-z'-]*", line):
            raise ValueError(f"{path.name}: {line!r} is not a plain ASCII name")
        names.append(line)
    if len(set(names)) != len(names):
        raise ValueError(f"{path.name}: duplicate names")
    return sorted(names)


def sam_for(given: str, surname: str, taken: set[str]) -> str:
    """First initial and surname, lower case, letters only, unique by suffix.

    sAMAccountName allows 20 characters; the base is cut to 18 so a two-digit
    suffix still fits.
    """
    base = re.sub(r"[^a-z]", "", (given[0] + surname).lower())[:18]
    sam, n = base, 2
    while sam in taken:
        sam, n = f"{base}{n}", n + 1
    taken.add(sam)
    return sam


def draw(count: int, seed: int, given: list[str], surnames: list[str]) -> list[dict]:
    rng = random.Random(seed)
    taken = {AUTHGEN["sam"]}
    seen_names: set[tuple[str, str]] = set()
    # Quotas, not weights per person, so a small population still has every
    # department in it: one each first, then the rest by share, rounded down,
    # with what rounding leaves going to the largest departments first. Below
    # six, the largest departments get the one each.
    by_share = sorted(range(len(DEPARTMENTS)), key=lambda i: -DEPARTMENTS[i][1])
    quotas = [0] * len(DEPARTMENTS)
    for i in by_share[:count]:
        quotas[i] = 1
    rest = count - sum(quotas)
    for i, (_, share, _) in enumerate(DEPARTMENTS):
        quotas[i] += int(rest * share)
    for i in range(count - sum(quotas)):
        quotas[by_share[i % len(by_share)]] += 1
    if len(given) * len(surnames) < count:
        raise ValueError("the name lists are too short for that count")
    users = []
    for (dept, _, titles), quota in zip(DEPARTMENTS, quotas, strict=True):
        for _ in range(quota):
            while True:
                pair = (rng.choice(given), rng.choice(surnames))
                if pair not in seen_names:
                    seen_names.add(pair)
                    break
            groups = [dept] + [g for g, p, _ in CROSS_GROUPS if rng.random() < p]
            users.append(
                {
                    "sam": sam_for(pair[0], pair[1], taken),
                    "given": pair[0],
                    "surname": pair[1],
                    "department": dept,
                    "title": rng.choice(titles),
                    "groups": groups,
                }
            )
    users.sort(key=lambda u: u["sam"])
    return [dict(AUTHGEN)] + users


def q(s: str) -> str:
    """A double-quoted YAML scalar. The inputs are ASCII names and fixed
    strings, so escaping a backslash and a quote is all it needs."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render(count: int, seed: int, users: list[dict]) -> str:
    out = [
        "---",
        "# GENERATED by scripts/gen_population.py. Do not edit by hand: --self-test",
        "# fails if this file is not what its header regenerates.",
        f"# Regenerate: scripts/gen_population.py --count {count} --seed {seed}",
        "#",
        "# The lab domain's people (#449). No passwords: roles/population derives each",
        "# one on phoenix from LAB_POPULATION_SEED and the sAMAccountName.",
        "",
        'population_ou: "People"',
        'population_groups_ou: "Groups"',
        "population_departments:",
    ]
    out += [f"  - {q(d)}" for d, _, _ in DEPARTMENTS]
    out.append("population_groups:")
    for d, _, _ in DEPARTMENTS:
        out += [f"  - name: {q(d)}", f"    description: {q('Everyone in ' + d)}"]
    for g, _, desc in CROSS_GROUPS:
        out += [f"  - name: {q(g)}", f"    description: {q(desc)}"]
    out.append("population_users:")
    for u in users:
        out += [
            f"  - sam: {q(u['sam'])}",
            f"    given: {q(u['given'])}",
            f"    surname: {q(u['surname'])}",
            f"    department: {q(u['department'])}",
            f"    title: {q(u['title'])}",
            "    groups: [" + ", ".join(q(g) for g in u["groups"]) + "]",
        ]
    return "\n".join(out) + "\n"


def generate(count: int, seed: int) -> str:
    return render(count, seed, draw(count, seed, read_names(GIVEN), read_names(SURNAMES)))


def self_test() -> int:
    failures = []

    def check(name: str, ok: bool) -> None:
        print(("PASS " if ok else "FAIL ") + name)
        if not ok:
            failures.append(name)

    given, surnames = read_names(GIVEN), read_names(SURNAMES)

    a = draw(40, 449, given, surnames)
    b = draw(40, 449, given, surnames)
    check("the same seed and count draw the same population", a == b)
    check("a different seed draws a different one", draw(40, 450, given, surnames) != a)
    check(
        "authgen is first, and is the one fixed account", a[0] == AUTHGEN and sum(u["sam"] == "authgen" for u in a) == 1
    )
    check("count ordinary users, plus authgen", len(a) == 41)
    sams = [u["sam"] for u in a]
    check("every sAMAccountName is unique", len(set(sams)) == len(sams))
    check("every sAMAccountName fits in 20 characters", all(len(s) <= 20 for s in sams))
    check("every department has someone in it", {u["department"] for u in a[1:]} == {d for d, _, _ in DEPARTMENTS})
    known = {d for d, _, _ in DEPARTMENTS} | {g for g, _, _ in CROSS_GROUPS}
    check(
        "everyone is in their own department's group, and only known groups",
        all(u["groups"][0] == u["department"] and set(u["groups"]) <= known for u in a),
    )
    small = draw(6, 1, given, surnames)
    check(
        "a population of six still has all six departments",
        {u["department"] for u in small[1:]} == {d for d, _, _ in DEPARTMENTS},
    )
    taken: set[str] = set()
    check(
        "a clashing sAMAccountName takes a suffix",
        [sam_for("John", "Smith", taken), sam_for("Jane", "Smith", taken)] == ["jsmith", "jsmith2"],
    )
    check("a long surname is cut so a suffix still fits", len(sam_for("A", "Wolfeschlegelsteinhausen", set())) == 18)
    check("rendering is stable", render(40, 449, a) == render(40, 449, b))
    neg = render(3, -1, draw(3, -1, given, surnames))
    m = HEADER_RE.search(neg)
    check("a negative seed's header reads back", bool(m) and m.group(2) == "-1")

    committed = OUT.read_text() if OUT.exists() else ""
    m = HEADER_RE.search(committed)
    check("the committed file has a Regenerate header", bool(m))
    if m:
        check(
            "the committed file is what its header regenerates", generate(int(m.group(1)), int(m.group(2))) == committed
        )

    print(f"{len(failures)} failure(s)")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--count", type=int, default=DEFAULT_COUNT)
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    ap.add_argument(
        "--check", action="store_true", help="exit non-zero if the committed file differs, and change nothing"
    )
    ap.add_argument(
        "--self-test", action="store_true", help="run the embedded fixtures and exit non-zero on any failure"
    )
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.count < 1:
        ap.error("--count must be at least 1")
    text = generate(args.count, args.seed)
    if args.check:
        if not OUT.exists() or OUT.read_text() != text:
            print(
                f"{OUT.relative_to(ROOT)} is not what --count {args.count} --seed {args.seed} generates",
                file=sys.stderr,
            )
            return 1
        return 0
    OUT.write_text(text)
    users = text.count("  - sam: ")
    print(f"wrote {OUT.relative_to(ROOT)}: {users} accounts ({args.count} drawn, plus authgen)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
