# ADR-0094: Vendor the Wazuh cert tool and mint the SOC's CA offline

**Status:** Accepted · 2026-10

## Context

The SOC's indexer, manager and dashboard trust each other through an mTLS CA of
their own, which [ADR-0030](0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)
leaves to Wazuh's `wazuh-certs-generator` image. The `certs` profile in
`stacks/soc` (and its copy in `stacks/scratch`) runs it by hand, before `odin`'s
first start and to reissue.

Triaging that image's CVEs ([#1008](https://github.com/Gerrrt/HomeLab/issues/1008))
meant reading what a run does. The image's `/entrypoint.sh`:

1. downloads `wazuh-certs-tool.sh` from
   `https://packages.wazuh.com/<major.minor>/` with `curl -fsL`, with **no
   checksum and no signature**;
2. if that fails for any reason, **silently** downloads it from
   `https://packages-dev.wazuh.com/<major.minor>/` instead, a bucket that
   answered 200 on 2026-10-10;
3. `source`s the result **as root**, with the certificate directory mounted
   read-write, and the tool generates the CA's private key there.

The file at that URL changes in place. On 2026-10-10 it was last modified
2026-09-23, so whatever was served on the day generated the CA. That is a
larger exposure than any of the image's 239 CVE rows. A pre-verification TLS
bug during the fetch gives an attacker code in the generator, but so does
anyone who can change what that path serves, with no bug needed. Patching
OpenSSL wouldn't close it.

## Decision

**Vendor the tool, pin it by sha256, and mint with no network.**

- `stacks/soc/wazuh/certs-tool/` holds `wazuh-certs-tool.sh` byte for byte, the
  GPLv2 `LICENSE` it requires, a `NOTICE` saying this repository's MIT licence
  doesn't extend to it, and `VENDORED` (URL, sha256, Last-Modified, date).
  `scripts/vendor-wazuh-certs-tool.sh <major.minor>` writes all but `NOTICE`,
  from the production bucket only.
- `scripts/wazuh-certs-mint.sh` replaces the image's entrypoint. It refuses
  unless the tool's sha256 is the one `VENDORED` records. It then does what
  the image's entrypoint does after its download, step for step: the same
  twelve files, modes and owners.
- The service runs with `network_mode: none`. There is no download, so there is
  no fallback, and nothing in the run can reach a network.
- `vendor-wazuh-certs-tool.sh --check` compares the file with `VENDORED`
  offline, in `validate.sh`. `--upstream` reports whether Wazuh's copy has moved
  since, and gates nothing.

**Why not pin a hash and keep downloading.** That is a smaller diff, but it
pins a mutable URL. The next upstream edit makes every mint refuse. That lands
on the day certificates need reissuing, when the old bytes may no longer be
served, and the only way forward is to trust new bytes under time pressure. It
also keeps the TLS fetch, and the CVE rows on that path, in the run. Vendoring
moves the trust decision into a PR that shows the diff, which is where
[ADR-0069](0069-vendor-the-ja4-scripts-into-the-sensor-stack-rather-than-build-an-image.md)
and [ADR-0080](0080-record-the-lab-domain-with-sysmon-and-capture-on-demand-with-pktmon.md)
already put it for JA4 and Sysmon.

**Why not issue these certificates with `scripts/gen-certs.sh`.** ADR-0030's
reasons stand: the tool already issues the client certificates and the uid
layout these three images expect, and teaching the estate CA's script to would
be new code for a solved job. This changes how the tool runs, not which tool.

## Consequences

- A mint is reproducible. The same vendored bytes produced the same twelve
  files, modes and owners as the image's own entrypoint on 2026-10-11, and
  every leaf verifies against the new CA.
- **The vendored tool is the one thing Dependabot can't keep in step** with the
  `wazuh/*` major.minor. A move to 4.15 runs
  `scripts/vendor-wazuh-certs-tool.sh 4.15` in the same PR, and that diff, new
  code that mints the CA, is what the PR is for. `CERT_TOOL_VERSION` is gone
  from both compose files, because nothing downloads.
- The repository now carries a GPLv2 file. It is unmodified, licensed as its
  header says, and excluded from editorconfig-checker so it stays byte for byte
  (a whitespace fix would refuse every mint).
- Wazuh 5.0 drops the image and moves issuance to a host-side tool. That move
  replaces this, and the same rule should apply to whatever 5.0 runs: pinned
  bytes, no network.
