#!/usr/bin/env python3
"""Fold dashboards fetched from a Grafana API back over the committed JSON.

This is the half of `make dashboards-export` that has no credentials and no
network in it. It is handed a directory of API responses — one `<uid>.json` per
dashboard, as returned by `GET /api/dashboards/uid/<uid>` — and either writes
them over `grafana/dashboards/` or, with --check, reports how they differ.

Two callers share it, which is the whole reason it is a separate file:
scripts/export-dashboards.sh points it at the live stack's Grafana, and
scripts/check_dashboard_roundtrip.sh points it at a throwaway Grafana booted
from the pinned image. One canonical form, one set of edge cases. Two
implementations would eventually disagree, and the way that failure presents is
CI passing over a round trip the real export does differently.

WHY A NAIVE WRITE-BACK IS UNUSABLE

Grafana does not hand back what it was given. Three transformations sit between
the file and the API response, and all three were measured against this stack
(Grafana 13.0.2) rather than assumed:

  * Keys come back sorted alphabetically at every level, because Grafana
    marshals a `map[string]interface{}`. The committed files put `uid`, `title`
    and `description` first and a panel's `type` and `title` first. Writing the
    API's order back would reorder every key in all seven files — thousands of
    lines saying nothing. So the committed order is preserved (see reorder()).

  * `&` arrives as `\u0026`, because Go's encoding/json HTML-escapes it. A
    byte comparison against the API response is therefore impossible;
    everything here goes through json.loads and is re-serialised.

  * The committed files disagree with each other about non-ASCII — three
    escape their em dashes and four do not, and observability-stack.json does
    both. CANONICAL below settles it as literal UTF-8, matching .editorconfig.

WHAT IS DROPPED AND WHAT IS KEPT

VOLATILE fields are Grafana's bookkeeping and are never written. PRESERVED
fields are session state: Grafana persists whatever the browser happened to be
showing at save time, so taking them from the API would let an export silently
change the default time range or the default variable selection for everyone.
They are read back out of the committed file instead. To change one, edit the
file — that is the one thing the UI round trip deliberately cannot do.
"""
from __future__ import annotations

import argparse
import copy
import difflib
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DASHBOARDS = REPO / "stacks/observability/grafana/dashboards"

# Grafana's own bookkeeping. `id` and `version` are row identity and the
# optimistic-concurrency counter in Grafana's database; `iteration` is a
# millisecond timestamp the frontend stamps on a save. None of the three
# describe the dashboard, and all three change on every save — committing them
# would put a guaranteed diff in front of every real one.
VOLATILE_TOP = ("id", "version", "iteration")

# Panels get an `id` assigned when Grafana first saves a dashboard. Not one of
# the seven committed dashboards carries one, which is the evidence that they
# are not needed: Grafana has been serving these for the life of the repository
# and assigns ids at load. Keeping them would add one churning line per panel —
# and they renumber when a panel is deleted, so the churn is not even confined
# to the panel that changed.
VOLATILE_PANEL = ("id",)

# Session state. See the module docstring.
#
# `time` is the time picker's position, `templating.list[].current` is the
# variable selection, and `templating.list[].options` is the last-fetched option
# list for a query variable — which every committed dashboard holds as `[]`,
# correctly, because Grafana re-queries it on load. Exporting Grafana's copy of
# that would bake one host's list of instances into the file.
PRESERVED_TOP = ("time",)
PRESERVED_VARIABLE = ("current", "options")

# indent=2 matches .editorconfig; ensure_ascii=False keeps em dashes readable
# in a diff and undoes Grafana's `\u0026`. sort_keys is deliberately absent:
# order is decided by reorder() against the committed file.
CANONICAL = dict(indent=2, ensure_ascii=False)

# Keys that identify "the same item" across two versions of a list, in
# preference order. Without this, lists are paired by index, and moving a panel
# would inherit the key order of whatever panel used to sit at that position —
# correct output, but a diff that touches panels nobody edited.
IDENTITY_KEYS = ("name", "title", "refId", "uid", "id")


def die(message: str) -> None:
    print(f"\033[0;31merror:\033[0m {message}", file=sys.stderr)
    raise SystemExit(1)


def identity(item):
    """A stable handle for one item of a list, or None if it has none."""
    if not isinstance(item, dict):
        return None
    for key in IDENTITY_KEYS:
        value = item.get(key)
        if isinstance(value, (str, int)):
            return (key, value)
    return None


def reorder(new, old):
    """`new`, with its keys in `old`'s order wherever the two overlap.

    Keys `old` does not have are appended in sorted order, so a field Grafana
    added lands somewhere deterministic rather than wherever the API happened
    to put it. Lists are walked pairwise: by identity where the items carry one,
    by position otherwise.

    This is idempotent after a single pass. A reordered panel list pairs by
    title on the first export and by title again on the next, so a second export
    with no edits in between produces no diff — which is what makes --check a
    meaningful assertion rather than a coin toss.
    """
    if isinstance(new, dict):
        if not isinstance(old, dict):
            return {key: reorder(new[key], None) for key in sorted(new)}
        ordered = {}
        for key in old:
            if key in new:
                ordered[key] = reorder(new[key], old[key])
        for key in sorted(set(new) - set(old)):
            ordered[key] = reorder(new[key], None)
        return ordered

    if isinstance(new, list):
        if not isinstance(old, list):
            return [reorder(item, None) for item in new]
        by_identity = {}
        for item in old:
            handle = identity(item)
            # First wins. Two panels can share a title, and pairing both new
            # ones against the first old one only decides key order, which is
            # cosmetic — picking arbitrarily would not be.
            if handle is not None and handle not in by_identity:
                by_identity[handle] = item
        result = []
        for i, item in enumerate(new):
            handle = identity(item)
            if handle is not None and handle in by_identity:
                result.append(reorder(item, by_identity[handle]))
            elif i < len(old):
                result.append(reorder(item, old[i]))
            else:
                result.append(reorder(item, None))
        return result

    return new


def strip_panel_ids(panels) -> None:
    """Drop VOLATILE_PANEL from every panel, including inside collapsed rows.

    A collapsed row moves its children out of the top level and into its own
    `panels` array, which is how #78 got past a checker that read only the top
    level. The same shape would leave a row's panels carrying ids here.
    """
    for panel in panels or []:
        for key in VOLATILE_PANEL:
            panel.pop(key, None)
        strip_panel_ids(panel.get("panels"))


def preserve_session_state(new: dict, old: dict) -> None:
    """Copy PRESERVED fields from the committed dashboard over the API's."""
    for key in PRESERVED_TOP:
        if key in old:
            new[key] = old[key]
        else:
            new.pop(key, None)

    committed = {
        variable.get("name"): variable
        for variable in old.get("templating", {}).get("list", [])
        if variable.get("name")
    }
    for variable in new.get("templating", {}).get("list", []):
        was = committed.get(variable.get("name"))
        if was is None:
            # A variable added in the UI has no committed session state to
            # restore. Leave Grafana's — but empty the option cache, which is
            # a snapshot of one query against one host and never belongs in git.
            if "options" in variable:
                variable["options"] = []
            continue
        for key in PRESERVED_VARIABLE:
            if key in was:
                variable[key] = was[key]
            else:
                variable.pop(key, None)


def canonicalise(fetched: dict, committed: dict) -> str:
    """The text that belongs in the file, given what Grafana returned."""
    dashboard = copy.deepcopy(fetched)  # never mutate the caller's copy
    for key in VOLATILE_TOP:
        dashboard.pop(key, None)
    strip_panel_ids(dashboard.get("panels"))
    preserve_session_state(dashboard, committed)
    return json.dumps(reorder(dashboard, committed), **CANONICAL) + "\n"


def load_fetched(path: pathlib.Path) -> dict:
    """The dashboard out of an API response, whether or not it is wrapped.

    `GET /api/dashboards/uid/<uid>` answers `{"meta": …, "dashboard": …}`. The
    unwrapped form is accepted too so a hand-saved JSON Model can be fed
    straight in, which is the one thing the old manual loop produced.
    """
    body = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(body, dict) and isinstance(body.get("dashboard"), dict):
        return body["dashboard"]
    if not isinstance(body, dict):
        die(f"{path.name}: not a JSON object")
    return body


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetched", required=True, type=pathlib.Path,
                        help="directory of <uid>.json API responses")
    parser.add_argument("--check", action="store_true",
                        help="report differences and write nothing")
    parser.add_argument("--dashboards", type=pathlib.Path, default=DASHBOARDS,
                        help="the committed dashboard directory")
    args = parser.parse_args()

    if not args.fetched.is_dir():
        die(f"no such directory: {args.fetched}")

    committed_files = sorted(args.dashboards.glob("*.json"))
    if not committed_files:
        die(f"no dashboards in {args.dashboards}")

    # uid -> path, so a fetched file can be matched to the file it belongs over.
    # The uid is the contract; the filename is not, and has never had to match.
    by_uid: dict[str, pathlib.Path] = {}
    for path in committed_files:
        try:
            dashboard = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            die(f"{path.name}: invalid JSON — {exc}")
        uid = dashboard.get("uid")
        if not uid:
            die(f"{path.name}: no top-level 'uid' — cannot match it to an export")
        if uid in by_uid:
            die(f"{path.name}: uid '{uid}' already used by {by_uid[uid].name}")
        by_uid[uid] = path

    changed: list[str] = []
    unchanged = 0

    for uid, path in sorted(by_uid.items(), key=lambda item: item[1].name):
        source = args.fetched / f"{uid}.json"
        if not source.exists():
            # Not a warning. A uid that is committed but was not fetched means
            # the export covered less than the folder, and writing the rest
            # while staying silent about it is how a dashboard gets left behind.
            die(f"{path.name}: nothing fetched for uid '{uid}' ({source} is missing)")

        committed = json.loads(path.read_text(encoding="utf-8"))
        wanted = canonicalise(load_fetched(source), committed)
        current = path.read_text(encoding="utf-8")

        if wanted == current:
            unchanged += 1
            continue

        changed.append(path.name)
        if args.check:
            diff = difflib.unified_diff(
                current.splitlines(keepends=True),
                wanted.splitlines(keepends=True),
                fromfile=f"a/{path.name}", tofile=f"b/{path.name}",
            )
            sys.stdout.writelines(diff)
        else:
            path.write_text(wanted, encoding="utf-8")
            print(f"\033[0;32m  wrote\033[0m {path.name}")

    # A dashboard created in the UI has no file to be written over, and it is
    # exactly the thing an operator would expect this command to have captured.
    # Reported by uid because that is all that is known about it here.
    orphans = sorted(
        p.stem for p in args.fetched.glob("*.json") if p.stem not in by_uid
    )
    for uid in orphans:
        print(
            f"\033[0;33mwarning:\033[0m Grafana has a dashboard with uid '{uid}' "
            f"and nothing in {args.dashboards.name}/ claims it — a dashboard "
            f"created in the UI is not provisioned and will not survive a "
            f"rebuild. Save it to a file by hand to adopt it.",
            file=sys.stderr,
        )

    if args.check:
        if changed:
            print(
                f"\n{len(changed)} dashboard(s) differ from what Grafana holds: "
                f"{', '.join(changed)}",
                file=sys.stderr,
            )
            print("Run 'make dashboards-export' to fold them in.", file=sys.stderr)
            return 1
        print(f"{unchanged} dashboard(s) round-trip unchanged")
        return 0

    if changed:
        print(f"\n{len(changed)} dashboard(s) updated, {unchanged} unchanged")
    else:
        print(f"{unchanged} dashboard(s) already match Grafana — nothing to write")
    return 0


if __name__ == "__main__":
    sys.exit(main())
