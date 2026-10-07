#!/usr/bin/env python3
"""Assert every creation_rule in .sops.yaml matches the file it was written for.

Why this exists
---------------
ADR-0020 gave `stacks/lab` its own creation_rule and its own age recipient,
above the catch-all, because that catch-all matches ALL of secrets/ — so a
recipient added to it can decrypt the estate's SNMP communities and Grafana
admin password. A lab host holding the estate's credentials inverts the trust
direction ADR-0007 exists to protect.

The rule shipped as:

    path_regex: secrets/lab\\..*\\.sops\\.ya?ml$

which cannot match `secrets/lab.sops.yaml`. After `secrets/lab\\.` consumes the
only dot before `sops`, `\\.sops\\.` has no second dot left to match; it would
have matched `secrets/lab.something.sops.yaml` and nothing else. So the rule
matched NOTHING, sops fell through to the catch-all, and `make secrets-init
STACK=lab` on the guest encrypted the lab's secrets to the ESTATE's key —
doing precisely what the rule was added to prevent, and reporting success.

Nothing caught it. sops does not warn about a rule that matches no file: it
just uses the next one. The separation existed in the file, was reviewed, was
merged, and was not real. It surfaced days later on the lab guest as sops'
"no identity matched any of the recipients", which names the symptom and not
the cause.

What this asserts
-----------------
1. Every stack's secrets file resolves to some rule — otherwise sops refuses to
   encrypt it at all, which is loud but worth naming here rather than at deploy
   time on a machine you had to walk to.

2. **Every rule matches at least one real path.** This is the one that would
   have caught the bug. A creation_rule matching nothing is either a typo or
   dead, and both are indistinguishable from working until the day the
   fall-through matters.

3. Which rule each path resolves to is printed, so the separation ADR-0020
   decided is visible in CI output rather than inferred from two regexes.

4. **The household's recipients stay out of every rule** (ADR-0073). The keys
   that open the household's copy live in stacks/sensitive/household.recipients,
   not in a sops rule, because a key in the sensitive rule would also open the
   tier's passwords. Nothing would stop a later `make secrets-add-recipient`
   with the holder's key from collapsing that, so this fails on it: a
   `household` key in any rule is an error. And the `technical-second` key there
   must be the one the catch-all rule actually carries, so the file cannot
   advertise a fallback that ADR-0024's proof never touches. A key in the
   combined role, `household-and-technical-second` (one person in both, which
   ADR-0073 allows), IS the technical second: it is held to the catch-all like
   one, and is not a plain household key.

5. **A file's recipients are its rule's** (#835). .sops.yaml is policy and the
   `sops:` block in each committed file is fact; they differ for as long as
   somebody added a key and forgot `sops updatekeys`, which is the window
   ADR-0024 calls a recovery path that does not exist.

6. **A stack whose key guards data has two recipients** (#835, ADR-0024).
   `secrets/sensitive.sops.yaml` was born with one on 2026-09-28, after #294
   had closed, and its volume backups were encrypted to the same one key for
   days while the tier held the household's vault. Nothing noticed, because
   SecretsKeyBackupUnproven checks the recipients that exist, not how many.
   Which stacks need two is a list, below, with the reason for each.

The paths are derived, not listed: the stacks come from scripts/stacks.sh, the
one definition of what a stack is, and the firewall backup path is the shape
scripts/backup-firewall.sh actually writes. A hand-kept list here would be the
fourth copy of something and would rot the same way.

Usage: scripts/check_sops_rules.py
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - CI installs it
    print("PyYAML is required: python3 -m pip install pyyaml", file=sys.stderr)
    raise SystemExit(1) from None

REPO = pathlib.Path(__file__).resolve().parent.parent
POLICY = REPO / ".sops.yaml"

# The secrets files whose key, if lost, loses DATA rather than a credential
# that can be made again (#835). Each is read from the committed file's own
# `sops:` block, not from .sops.yaml, for key-recipients.sh's reason.
#
# soc and lab are NOT here, deliberately. Their keys open only passwords and
# tokens that a rebuild regenerates, and neither stack's backups are encrypted
# to them: losing odin's or alexander's key costs an evening, not a vault. The
# lab's second key is #671's question, on its own terms.
SECOND_RECIPIENT_REQUIRED = {
    "secrets/observability.sops.yaml": "the estate's key also encrypts its volume backups (backup-volumes.sh)",
    "secrets/sensitive.sops.yaml": "trinity's key also encrypts the tier's volume backups, Vaultwarden's "
    "among them (backup-volumes.sh STACK=sensitive)",
    "secrets/tofu.sops.yaml": "the state passphrase: without it the encrypted OpenTofu state is unreadable (ADR-0076)",
}


def stacks() -> list[str]:
    listed = subprocess.run(
        [str(REPO / "scripts/stacks.sh")],
        capture_output=True,
        text=True,
        check=True,
    )
    return listed.stdout.split()


def rule_keys(rule: dict) -> set[str]:
    return {k.strip() for k in str(rule.get("age") or "").split(",") if k.strip()}


def file_recipients(path: pathlib.Path) -> set[str]:
    """The age recipients a committed sops file is encrypted to right now."""
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return {
        str(entry.get("recipient", "")).strip()
        for entry in ((doc.get("sops") or {}).get("age") or [])
        if entry.get("recipient")
    }


def check_recipients(
    files: dict[str, set[str]],
    rule_for: dict[str, set[str]],
    rule_of: dict[str, str] | None = None,
) -> list[str]:
    """Checks 5 and 6: each file matches its rule, and the data-guarding ones
    have two recipients. Pure, so --self-test can hand it fixtures.

    `rule_of` maps each file to its rule's path_regex, so the repair advice can
    name every file that shares the rule. `make secrets-add-recipient` re-keys
    ONE file (secrets/<STACK>.sops.yaml). On a rule of its own that is the whole
    job; on the catch-all it leaves the rule's other files out of sync, and this
    check would fail on them next. Without `rule_of` every rule is treated as
    unshared, which is what the fixtures before it assumed."""
    rule_of = rule_of or {}
    problems: list[str] = []
    for path, have in sorted(files.items()):
        siblings = sorted(
            p for p in files if p != path and rule_of.get(p) is not None and rule_of.get(p) == rule_of.get(path)
        )
        sharing = [path, *siblings]
        rekey = " ".join(f"`sops updatekeys {p}`" for p in sharing)
        want = rule_for.get(path)
        if want is not None and not any(k.startswith("REPLACE_WITH_") for k in want) and have != want:
            missing = ", ".join(sorted(want - have)) or "none"
            extra = ", ".join(sorted(have - want)) or "none"
            # Not `make secrets-add-recipient`: that ADDS a key to the rule. Here
            # the rule and the file already disagree, so the repair is to decide
            # which is right and make the other agree — and a key passed to it
            # that the rule already lists would be written into it twice.
            problems.append(
                f"{path} is encrypted to recipients its rule does not list, or "
                f"not to ones it does (rule only: {missing}; file only: "
                f"{extra}). Decide which side is right and fix .sops.yaml if it "
                f"is the rule that is wrong, then, on a host that holds one of "
                f"the file's current keys, run {rekey}"
            )
        reason = SECOND_RECIPIENT_REQUIRED.get(path)
        if reason and len(have) < 2:
            if siblings:
                how = (
                    f"Add the technical second's public key to that rule in "
                    f".sops.yaml, then re-key every file the rule matches, on a "
                    f"host that holds a current key: {rekey}. Not `make "
                    f"secrets-add-recipient` — it re-keys only one of them"
                )
            else:
                how = (
                    f"Add the technical second: `make secrets-add-recipient "
                    f"STACK={pathlib.Path(path).name.split('.')[0]} "
                    f"PUBKEY=age1...` on the host that holds the current key"
                )
            problems.append(
                f"{path} opens with {len(have)} key — {reason}, so losing that key loses data (ADR-0024). {how}"
            )
    return problems


def self_test() -> int:
    one, two, three = "age1one", "age1two", "age1three"
    cases = [
        (
            "one recipient on a data-guarding file fails",
            {"secrets/sensitive.sops.yaml": {one}},
            {"secrets/sensitive.sops.yaml": {one}},
            1,
        ),
        (
            "two recipients, matching the rule, passes",
            {"secrets/sensitive.sops.yaml": {one, two}},
            {"secrets/sensitive.sops.yaml": {one, two}},
            0,
        ),
        (
            "one recipient on a regenerable-credentials file passes",
            {"secrets/soc.sops.yaml": {one}},
            {"secrets/soc.sops.yaml": {one}},
            0,
        ),
        (
            "a rule edited without updatekeys fails, even with two in the file",
            {"secrets/sensitive.sops.yaml": {one, two}},
            {"secrets/sensitive.sops.yaml": {one, two, three}},
            1,
        ),
        (
            "a file re-keyed to a recipient the rule lacks fails",
            {"secrets/soc.sops.yaml": {one, two}},
            {"secrets/soc.sops.yaml": {one}},
            1,
        ),
        (
            "a rule still holding its placeholder is not compared",
            {"secrets/sensor.sops.yaml": {one}},
            {"secrets/sensor.sops.yaml": {"REPLACE_WITH_SENSOR_AGE_PUBLIC_KEY"}},
            0,
        ),
    ]
    failed = 0
    for name, files, rules, want in cases:
        got = len(check_recipients(files, rules))
        ok = got == want
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} {name}" + ("" if ok else f" (got {got} problem(s), expected {want})"))

    # The advice, not just the verdict (#866 review): a file on a shared rule
    # must be told to re-key every file the rule matches, and never pointed at
    # secrets-add-recipient, which re-keys one; a file on its own rule may be.
    catch_all = "(secrets/.*|backups/firewall/.*)"
    shared = check_recipients(
        {"secrets/observability.sops.yaml": {one}, "secrets/wiki.sops.yaml": {one}},
        {"secrets/observability.sops.yaml": {one}, "secrets/wiki.sops.yaml": {one}},
        {"secrets/observability.sops.yaml": catch_all, "secrets/wiki.sops.yaml": catch_all},
    )
    alone = check_recipients(
        {"secrets/sensitive.sops.yaml": {one}},
        {"secrets/sensitive.sops.yaml": {one}},
        {"secrets/sensitive.sops.yaml": "secrets/sensitive"},
    )
    drift = check_recipients(
        {"secrets/sensitive.sops.yaml": {one, two}},
        {"secrets/sensitive.sops.yaml": {one, two, three}},
    )
    advice = [
        (
            "a shared rule's file is told to re-key its sibling too",
            len(shared) == 1 and "sops updatekeys secrets/wiki.sops.yaml" in shared[0],
        ),
        (
            "a shared rule's file is not pointed at secrets-add-recipient",
            len(shared) == 1
            and "Not `make secrets-add-recipient`" in shared[0]
            and "`make secrets-add-recipient STACK" not in shared[0],
        ),
        (
            "a file on its own rule may use secrets-add-recipient",
            len(alone) == 1 and "make secrets-add-recipient STACK=sensitive" in alone[0],
        ),
        (
            "rule/file drift is repaired by updatekeys, not secrets-add-recipient",
            len(drift) == 1
            and "sops updatekeys secrets/sensitive.sops.yaml" in drift[0]
            and "secrets-add-recipient" not in drift[0],
        ),
    ]
    for name, ok in advice:
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} {name}")
    return 1 if failed else 0


def check_household(rules: list[dict], matched_by: dict[str, str]) -> list[str]:
    """ADR-0073: household keys in no rule; the technical second in the catch-all."""
    listed = subprocess.run(
        [str(REPO / "scripts/household-recipients.sh"), "--roles"],
        capture_output=True,
        text=True,
        check=False,
    )
    if listed.returncode != 0:
        return [f"stacks/sensitive/household.recipients: {listed.stderr.strip()}"]

    problems: list[str] = []
    catch_all = matched_by.get("secrets/observability.sops.yaml")
    catch_all_keys = next((rule_keys(r) for r in rules if r.get("path_regex") == catch_all), set())
    for line in listed.stdout.splitlines():
        role, key = line.split(" ", 1)
        if role == "household":  # the combined role is the technical second, below
            for rule in rules:
                if key in rule_keys(rule):
                    problems.append(
                        f"household key {key} is a recipient of creation_rule "
                        f"{rule.get('path_regex')!r} — it would open that rule's "
                        f"secrets, which is what ADR-0073 keeps it out of. Take it "
                        f"out of {POLICY.name} and run `sops updatekeys`"
                    )
        elif role in ("technical-second", "household-and-technical-second") and key not in catch_all_keys:
            problems.append(
                f"{role} key {key} in stacks/sensitive/household.recipients "
                f"is not a recipient of the catch-all rule — ADR-0024's proof covers "
                f"that rule's keys, so this one is a fallback nothing has proved"
            )
    return problems


def main() -> int:
    if not POLICY.exists():
        print(f"no {POLICY.name}", file=sys.stderr)
        return 1

    policy = yaml.safe_load(POLICY.read_text(encoding="utf-8")) or {}
    rules = policy.get("creation_rules") or []
    if not rules:
        print(f"{POLICY.name} declares no creation_rules", file=sys.stderr)
        return 1

    patterns: list[tuple[str, re.Pattern[str]]] = []
    problems: list[str] = []
    for rule in rules:
        raw = rule.get("path_regex")
        if not raw:
            problems.append("a creation_rule has no path_regex")
            continue
        try:
            patterns.append((raw, re.compile(raw)))
        except re.error as exc:
            problems.append(f"path_regex {raw!r} does not compile — {exc}")

    # The paths sops is actually asked to encrypt. Stack secrets files, plus one
    # firewall export: the stamp is arbitrary, so any well-formed name stands in
    # for the whole class.
    paths = [f"secrets/{stack}.sops.yaml" for stack in stacks()]
    paths.append("backups/firewall/config-20260101T000000Z.sops.yaml")

    matched_by: dict[str, str] = {}
    used: set[str] = set()
    for path in paths:
        hit = next((raw for raw, pat in patterns if pat.search(path)), None)
        if hit is None:
            problems.append(f"{path} matches no creation_rule in {POLICY.name} — sops will refuse to encrypt it")
            continue
        matched_by[path] = hit
        used.add(hit)

    # The assertion that would have caught the lab rule.
    for raw, _pat in patterns:
        if raw not in used:
            problems.append(
                f"creation_rule {raw!r} matches none of the files this "
                f"repository encrypts — sops does not warn about a dead rule, "
                f"it silently uses the next one, so the recipient separation "
                f"this rule was added for is not in effect (ADR-0020)"
            )

    problems.extend(check_household(rules, matched_by))

    # Checks 5 and 6, over every committed secrets file, tofu's included.
    files: dict[str, set[str]] = {}
    rule_for: dict[str, set[str]] = {}
    rule_of: dict[str, str] = {}
    for path in sorted((REPO / "secrets").glob("*.sops.yaml")):
        rel = path.relative_to(REPO).as_posix()
        files[rel] = file_recipients(path)
        hit = next((raw for raw, pat in patterns if pat.search(rel)), None)
        rule = next((r for r in rules if r.get("path_regex") == hit), None)
        if rule is not None:
            rule_for[rel] = rule_keys(rule)
            rule_of[rel] = hit
    problems.extend(check_recipients(files, rule_for, rule_of))

    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(f"{POLICY.name} OK — {len(patterns)} creation_rule(s), each matching:")
    for path, raw in matched_by.items():
        print(f"  {path} -> {raw}")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        raise SystemExit(self_test())
    raise SystemExit(main())
