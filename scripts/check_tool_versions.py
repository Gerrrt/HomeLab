#!/usr/bin/env python3
"""Report the pins no Dependabot ecosystem reads, when upstream has moved on.

Dependabot bumps compose images, pip requirements, GitHub Actions and, since
#848, the OpenTofu provider. Three kinds of pin are left that it has no
ecosystem for:

  * the Packer plugin in packer/versions.pkr.hcl (ADR-0074);
  * the ansible-galaxy collections in ansible/requirements.yml (ADR-0077);
  * the Alpine and Gentoo cloud images in scripts/import-cloud-template.sh
    (ADR-0090), each a file name and a SHA-256.

All are exact on purpose, and a bump stays a deliberate edit: microsoft.ad's
promotion modules reboot domain controllers, and a template build on a plugin
nobody read the changelog of is the failure ADR-0074 exists to prevent. What
was missing is anything that SAYS a bump exists. Without it the pins only rot.

So this compares each pin with upstream's newest release and exits 1 when any
is behind. Gentoo builds its image every week, so "behind" there means more
than GENTOO_GRACE older than the newest build, or no longer served: Gentoo
prunes old autobuilds after about six weeks, and a pin that 404s cannot be
rebuilt from at all, which is reported as an error. Alpine keeps its releases, so any newer point release or
image revision counts. It runs weekly from .github/workflows/digests.yml, where the failing
run is the notification, the same contract as scripts/pin-digests.sh. A fetch
error also exits 1; both want a human, and neither runs on a host timer where
an outage would read as drift.

Stdlib only, apart from the shared PyYAML bootstrap: it runs on a bare runner.

Usage: scripts/check_tool_versions.py
       scripts/check_tool_versions.py --self-test
"""

from __future__ import annotations

import datetime
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _deps import require_yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
PACKER = REPO / "packer" / "versions.pkr.hcl"
GALAXY = REPO / "ansible" / "requirements.yml"
IMPORT = REPO / "scripts" / "import-cloud-template.sh"

# `source = "github.com/hashicorp/proxmox"` then `version = "= 1.2.4"`, inside
# one block of required_plugins. The plugin's repository is the source's last
# segment with packer-plugin- in front, which is Packer's own naming rule.
PLUGIN = re.compile(
    r'source\s*=\s*"github\.com/(?P<owner>[\w.-]+)/(?P<name>[\w.-]+)"\s*'
    r'version\s*=\s*"=\s*(?P<version>[0-9][\w.-]*)"'
)


# The `url=` line of each distro's case branch in import-cloud-template.sh.
IMAGE_URL = re.compile(r"^\s*(?P<distro>alpine|gentoo)\)\n(?:.*\n)*?\s*url=(?P<url>\S+)$", re.MULTILINE)

# alpine-3.24.2-x86_64-cloudinit-r2.qcow2: the release, then the image's own
# revision, which Alpine bumps when it rebuilds the same release.
ALPINE_IMAGE = re.compile(r"\balpine-(?P<version>\d+\.\d+\.\d+)-x86_64-cloudinit-r(?P<rev>\d+)\.qcow2\b")
ALPINE_CLOUD = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud/"

# 20261004T164559Z/di-amd64-cloudinit-20261004T164559Z.qcow2, the build's UTC
# start, in the path and the name alike.
GENTOO_IMAGE = re.compile(r"\b(?P<stamp>\d{8}T\d{6}Z)/di-amd64-cloudinit-(?P=stamp)\.qcow2\b")
GENTOO_LATEST = "https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-di-amd64-cloudinit.txt"
GENTOO_GRACE = datetime.timedelta(days=28)


def version_key(v: str) -> tuple[int, ...]:
    return tuple(int(p) for p in re.findall(r"\d+", v.lstrip("v")))


def newer(pinned: str, latest: str) -> bool:
    return version_key(latest) > version_key(pinned)


def packer_pins(text: str) -> list[tuple[str, str, str]]:
    """(display name, owner/repo, pinned version) per exactly-pinned plugin."""
    return [
        (f"packer plugin {m['owner']}/{m['name']}", f"{m['owner']}/packer-plugin-{m['name']}", m["version"])
        for m in PLUGIN.finditer(text)
    ]


def galaxy_pins(doc: dict) -> list[tuple[str, str]]:
    """(namespace.name, pinned version) per collection."""
    return [(c["name"], str(c["version"])) for c in (doc or {}).get("collections") or []]


def image_pins(text: str) -> dict[str, str]:
    """distro -> pinned URL, from import-cloud-template.sh."""
    return {m["distro"]: m["url"] for m in IMAGE_URL.finditer(text)}


def alpine_label(m: re.Match) -> str:
    return f"{m['version']}-r{m['rev']}"


def newest_alpine(listing: str) -> str:
    """The newest cloudinit image in a directory listing, as 3.24.2-r2."""
    best = max(ALPINE_IMAGE.finditer(listing), key=lambda m: version_key(alpine_label(m)), default=None)
    if best is None:
        raise ValueError("no x86_64 cloudinit image in the listing")
    return alpine_label(best)


def gentoo_stamp(text: str) -> str:
    m = GENTOO_IMAGE.search(text)
    if m is None:
        raise ValueError("no di-amd64-cloudinit build named")
    return m["stamp"]


def gentoo_behind(pinned: str, latest: str) -> bool:
    def parse(stamp: str) -> datetime.datetime:
        return datetime.datetime.strptime(stamp, "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.UTC)

    return parse(latest) - parse(pinned) > GENTOO_GRACE


def fetch_text(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "homelab-check-tool-versions"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def still_served(url: str) -> bool:
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "homelab-check-tool-versions"})
    try:
        with urllib.request.urlopen(req, timeout=30):
            return True
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return False
        raise


def image_checks(text: str) -> list[tuple[str, str, object, object]]:
    """(label, pinned, latest_of, is_behind) per pinned cloud image."""
    pins = image_pins(text)
    checks = []
    if "alpine" in pins:
        m = ALPINE_IMAGE.search(pins["alpine"])
        if m is None:
            raise ValueError(f"alpine pin is not a cloudinit image name: {pins['alpine']}")
        checks.append(
            (
                "cloud image alpine",
                alpine_label(m),
                lambda: newest_alpine(fetch_text(ALPINE_CLOUD)),
                newer,
            )
        )
    if "gentoo" in pins:
        url = pins["gentoo"]

        def gentoo_latest(url=url) -> str:
            if not still_served(url):
                raise LookupError("the pinned build is no longer served; Gentoo has pruned it")
            return gentoo_stamp(fetch_text(GENTOO_LATEST))

        checks.append(
            (
                "cloud image gentoo",
                gentoo_stamp(url),
                gentoo_latest,
                gentoo_behind,
            )
        )
    return checks


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
        (label, pinned, lambda r=repo: latest_github(r), newer)
        for label, repo, pinned in packer_pins(PACKER.read_text(encoding="utf-8"))
    ]
    checks += [
        (f"galaxy collection {fqcn}", pinned, lambda f=fqcn: latest_galaxy(f), newer)
        for fqcn, pinned in galaxy_pins(yaml.safe_load(GALAXY.read_text(encoding="utf-8")))
    ]
    images = image_checks(IMPORT.read_text(encoding="utf-8"))
    checks += images
    if not checks or len(images) != 2:
        print(
            "pins missing from packer/versions.pkr.hcl, ansible/requirements.yml or "
            "scripts/import-cloud-template.sh — this check has stopped checking",
            file=sys.stderr,
        )
        return 1

    behind = errors = 0
    for label, pinned, latest_of, is_behind in checks:
        try:
            latest = latest_of()
        except Exception as exc:  # noqa: BLE001 - any failure is reported, not raised
            errors += 1
            print(f"  ERROR  {label} {pinned}: could not ask upstream ({exc})")
            continue
        if is_behind(pinned, latest):
            behind += 1
            print(f"  BEHIND {label}: pinned {pinned}, upstream {latest}")
        else:
            print(f"  OK     {label} {pinned}")

    if behind or errors:
        print(
            f"\n{behind} pin(s) behind upstream, {errors} error(s). A bump is a "
            f"deliberate edit: read the changelog, change the pin, and prove it "
            f"where the tool runs (phoenix, or Saruman for a cloud image).",
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
        (
            "the real import script yields both image pins",
            sorted(image_pins(IMPORT.read_text(encoding="utf-8"))),
            ["alpine", "gentoo"],
        ),
        (
            "both pinned image names parse",
            [label for label, _, _, _ in image_checks(IMPORT.read_text(encoding="utf-8"))],
            ["cloud image alpine", "cloud image gentoo"],
        ),
        (
            "the newest Alpine cloudinit image is picked, not a tiny, metal or generic one",
            newest_alpine(
                'href="alpine-3.24.2-x86_64-cloudinit-r2.qcow2" href="alpine-3.24.2-x86_64-cloudinit-r10.qcow2" '
                'href="alpine-3.24.3-x86_64-tiny-r0.qcow2" href="alpine-3.24.3-x86_64-cloudinit-metal-r0.qcow2" '
                'href="generic_alpine-3.25.0-x86_64-uefi-cloudinit-r0.qcow2"'
            ),
            "3.24.2-r10",
        ),
        ("an image revision alone is a newer Alpine image", version_key("3.24.2-r3") > version_key("3.24.2-r2"), True),
        (
            "Gentoo's clearsigned latest file names its build",
            gentoo_stamp("# ts=1\n20261011T170000Z/di-amd64-cloudinit-20261011T170000Z.qcow2 1501626368\n"),
            "20261011T170000Z",
        ),
        ("one weekly Gentoo build behind is not stale", gentoo_behind("20261004T164559Z", "20261011T170000Z"), False),
        ("five weekly Gentoo builds behind is stale", gentoo_behind("20261004T164559Z", "20261108T170000Z"), True),
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
