# .github — what GitHub does with this repository

<!-- Not README.md: GitHub shows a README in .github/ in place of the root one. -->

[![CI](https://img.shields.io/github/actions/workflow/status/Gerrrt/HomeLab/ci.yml?branch=main&style=plastic&logo=githubactions&logoColor=white&label=CI)](https://github.com/Gerrrt/HomeLab/actions/workflows/ci.yml)
[![Digest drift](https://img.shields.io/github/actions/workflow/status/Gerrrt/HomeLab/digests.yml?branch=main&style=plastic&logo=githubactions&logoColor=white&label=Digest%20drift)](https://github.com/Gerrrt/HomeLab/actions/workflows/digests.yml)
[![Dependabot](https://img.shields.io/badge/Dependabot-enabled-025E8C?style=plastic&logo=dependabot&logoColor=white)](dependabot.yml)
[![merge](https://img.shields.io/badge/merge-squash%20only-30363d?style=plastic)](rulesets/main.json)

What GitHub does with this repository: the workflows that test every change,
the ruleset that decides what may reach `main`, and the bot that keeps the
pinned images moving. All of it is configuration as code, held to the same
standard as the rest, and linted by `actionlint` and `zizmor` in
[`scripts/lint.sh`](../scripts/lint.sh).

## Workflows

| Workflow | Runs on | Jobs |
| --- | --- | --- |
| [`ci.yml`](workflows/ci.yml) — **CI** | pushes to `main`, every pull request, by hand | **Lint**: [`scripts/lint.sh`](../scripts/lint.sh). **Validate configs**: the checks [`scripts/validate.sh`](../scripts/validate.sh) runs for `make validate`, as individual steps calling the same scripts rather than the wrapper. **Boot hardened services**: starts Home Assistant, ntfy, linkding, Stirling-PDF and Actual under their real hardening and waits for each to be healthy. **Secret scan**: gitleaks over the whole history |
| [`close-keywords.yml`](workflows/close-keywords.yml) — **Close keywords** | every pull request | **No close keyword in prose**: fails a title, body or commit whose `Closes #N` would close an issue the sentence says stays open ([`check_close_keywords.py`](../scripts/check_close_keywords.py)) |
| [`digests.yml`](workflows/digests.yml) — **Digest drift** | Mondays 07:00 UTC, by hand | **Pinned digests still match the registry**: catches a tag moved under a pin. **Pinned tool versions are current**: says when the Packer plugin or a Galaxy collection has a newer release, the pins Dependabot cannot read. **The ruleset on main matches `rulesets/main.json`**: catches a ruleset edited in the UI |

Every workflow pins its actions by commit SHA, with the version in a comment
for Dependabot. Each starts from `contents: read` and checks out with
`persist-credentials: false`. Images come from the stacks' `compose.yaml`
through [`scripts/image-for.sh`](../scripts/image-for.sh), never from a tag
written in the workflow.

A green run locally is weaker than a green run here: `make validate` skips
what the machine it runs on cannot do, and says how many it skipped.

## The ruleset on `main`

[`rulesets/main.json`](rulesets/main.json) is the source of truth for the
branch rules, and `make check-ruleset` and `make apply-ruleset` compare it with,
or push it to, the live ruleset. The weekly *Digest drift* run catches a
difference made in the UI.

- **No deletion and no force-push** of `main`.
- **Changes arrive by pull request, squash-merged.** No approving review is
  required, because this is a one-maintainer repository, but every review
  thread must be resolved.
- **Five checks must pass:** *Lint*, *Validate configs*, *Boot hardened
  services*, *Secret scan* and *No close keyword in prose*. Since
  [#862](https://github.com/Gerrrt/HomeLab/pull/862), auto-merge waits for
  them. Since [#876](https://github.com/Gerrrt/HomeLab/pull/876), a branch
  need not be up to date with `main` first.
- [`scripts/converge.sh`](../scripts/converge.sh) reads the same check runs
  before it deploys a commit, so a merge that went red never deploys.

## Dependabot

[`dependabot.yml`](dependabot.yml) watches:

- **Every stack's `compose.yaml`, weekly**, one entry per directory under
  `stacks/`. Each bump changes a tag and its digest together, and
  [`scripts/check_docs.py`](../scripts/check_docs.py) bans image versions in
  prose, so `compose.yaml` stays the only place a version is written.
- **`ansible/`'s and `scripts/`'s Python pins, monthly.** `scripts/` holds
  PyYAML, hash-pinned, and yamllint.
- **The OpenTofu provider in `tofu/`, monthly.**
- **The workflows' actions, weekly.**

`stacks/soc` and `stacks/scratch` share one entry, so a Wazuh release is one PR
to both: scratch mounts soc's config, and
[`scripts/check_image_pins.py`](../scripts/check_image_pins.py) fails an image
that runs another stack's config on a different pin. Alloy, which four stacks
run on observability's `config.alloy`, still arrives as one PR per stack, so
put the bump to all four on one PR. The Packer plugin and the Galaxy
collections have no Dependabot ecosystem; `digests.yml` reports them weekly.

A red Dependabot PR is usually a stale base rather than a bad bump. Ask
Dependabot to rebase it before reading the failure.

## Templates

- [`ISSUE_TEMPLATE/bug.yml`](ISSUE_TEMPLATE/bug.yml): something is broken —
  a service, dashboard, alert or metric.
- [`ISSUE_TEMPLATE/change.yml`](ISSUE_TEMPLATE/change.yml): a planned change —
  a new device, a new service, or a change to the network.
- [`pull_request_template.md`](pull_request_template.md): what changed, why,
  its blast radius on hosts and VLANs, and what was actually run to verify it.

Close an issue from a pull request only with a keyword that opens its own
sentence. Use `Refs #N` for anything that should stay open — the *Close
keywords* check enforces it.
