#!/usr/bin/env python3
"""Report the pins no Dependabot ecosystem reads, when upstream has moved on.

Dependabot bumps compose images, pip requirements, GitHub Actions and, since
#848, the OpenTofu provider. Two pins are left that it has no ecosystem for:

  * the Packer plugin in packer/versions.pkr.hcl (ADR-0074);
  * the ansible-galaxy collections in ansible/requirements.yml (ADR-0077).

Both are exact on purpose, and a bump stays a deliberate edit: microsoft.ad's
promotion modules reboot domain controllers, and a template build on a plugin
nobody read the changelog of is the failure ADR-0074 exists to prevent. What
was missing is anything that SAYS a bump exists. Without it the pins only rot.

So this compares each pin with upstream's newest release and exits 1 when any
is behind. It runs weekly from .github/workflows/digests.yml, where the failing
run is the notification, the same contract as scripts/pin-digests.sh. A fetch
error also exits 1; both want a human, and neither runs on a host timer where
an outage would read as drift.

Stdlib only, apart from the shared PyYAML bootstrap: it runs on a bare runner.

Usage: scripts/check_tool_versions.py
       scripts/check_tool_versions.py --self-test
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _deps import require_yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
PACKER = REPO / "packer" / "versions.pkr.hcl"
GALAXY = REPO / "ansible" / "requirements.yml"

# `source = "github.com/hashicorp/proxmox"` then `version = "= 1.2.4"`, inside
# one block of required_plugins. The plugin's repository is the source's last
# segment with packer-plugin- in front, which is Packer's own naming rule.
PLUGIN = re.compile(
    r'source\s*=\s*"github\.com/(?P<owner>[\w.-]+)/(?P<name>[\w.-]+)"\s*'
    r'version\s*=\s*"=\s*(?P<version>[0-9][\w.-]*)"'
)


def version_key(v: str) -> tuple[int, ...]:
    return tuple(int(p) for p in re.findall(r"\d+", v.lstrip("v")))


def packer_pins(text: str) -> list[tuple[str, str, str]]:
    """(display name, owner/repo, pinned version) per exactly-pinned plugin."""
    return [
        (f"packer plugin {m['owner']}/{m['name']}", f"{m['owner']}/packer-plugin-{m['name']}", m["version"])
        for m in PLUGIN.finditer(text)
    ]


def galaxy_pins(doc: dict) -> list[tuple[str, str]]:
    """(namespace.name, pinned version) per collection."""
    return [(c["name"], str(c["version"])) for c in (doc or {}).get("collections") or []]


def fetch(url: str) -> dict:
    headers = {"Accept": "application/json", "User-Agent": "homelab-check-tool-versions"}
    token = os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
        return json.load(r)


def latest_github(repo: str) -> str:
    # /releases/latest skips drafts and pre-releases by definition.
    return fetch(f"https://api.github.com/repos/{repo}/releases/latest")["tag_name"].lstrip("v")


def latest_galaxy(fqcn: str) -> str:
    ns, name = fqcn.split(".", 1)
    url = f"https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/collections/index/{ns}/{name}/"
    return fetch(url)["highest_version"]["version"]


def main() -> int:
    yaml = require_yaml()
    checks = [
        (label, pinned, lambda r=repo: latest_github(r))
        for label, repo, pinned in packer_pins(PACKER.read_text(encoding="utf-8"))
    ]
    checks += [
        (f"galaxy collection {fqcn}", pinned, lambda f=fqcn: latest_galaxy(f))
        for fqcn, pinned in galaxy_pins(yaml.safe_load(GALAXY.read_text(encoding="utf-8")))
    ]
    if not checks:
        print(
            "no pins found in packer/versions.pkr.hcl or ansible/requirements.yml — this check has stopped checking",
            file=sys.stderr,
        )
        return 1

    behind = errors = 0
    for label, pinned, latest_of in checks:
        try:
            latest = latest_of()
        except Exception as exc:  # noqa: BLE001 - any failure is reported, not raised
            errors += 1
            print(f"  ERROR  {label} {pinned}: could not ask upstream ({exc})")
            continue
        if version_key(latest) > version_key(pinned):
            behind += 1
            print(f"  BEHIND {label}: pinned {pinned}, upstream {latest}")
        else:
            print(f"  OK     {label} {pinned}")

    if behind or errors:
        print(
            f"\n{behind} pin(s) behind upstream, {errors} error(s). A bump is a "
            f"deliberate edit: read the changelog, change the pin, and prove it "
            f"where the tool runs (phoenix).",
            file=sys.stderr,
        )
        return 1
    print(f"\n{len(checks)} pin(s) current")
    return 0


def self_test() -> int:
    hcl = """packer {
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = "= 1.2.4"
    }
    ranged = {
      source  = "github.com/example/ranged"
      version = ">= 1.0"
    }
  }
}"""
    cases = [
        (
            "the exact plugin pin is read, and its repository named",
            packer_pins(hcl),
            [("packer plugin hashicorp/proxmox", "hashicorp/packer-plugin-proxmox", "1.2.4")],
        ),
        ("the real versions.pkr.hcl yields a pin", bool(packer_pins(PACKER.read_text(encoding="utf-8"))), True),
        (
            "collections are read with their versions",
            galaxy_pins({"collections": [{"name": "microsoft.ad", "version": "1.12.1"}]}),
            [("microsoft.ad", "1.12.1")],
        ),
        ("1.10.0 is newer than 1.9.9, not older", version_key("1.10.0") > version_key("1.9.9"), True),
        ("a v prefix does not change the answer", version_key("v1.2.4") == version_key("1.2.4"), True),
    ]
    failed = 0
    for name, got, want in cases:
        ok = got == want
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} {name}" + ("" if ok else f" (got {got!r}, expected {want!r})"))
    return 1 if failed else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())
    sys.exit(main())
