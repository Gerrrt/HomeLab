# ADR-0092: Enrol garuda in odin's SOC with Debian packages staged on odin

**Status:** Accepted · 2026-10

## Context

[ADR-0091](0091-put-a-kali-purple-analyst-workstation-on-saruman.md) built
`garuda`, the analyst workstation, and left one thing for later. In its words:
"No Linux guest is enrolled in either today. … A Linux enrolment is a decision
of its own." [#921](https://github.com/Gerrrt/HomeLab/issues/921)'s comment of
2026-10-06 asks for it: the SOC should watch its own analyst's machine.

Everything that enrols the six domain guests is Windows-only:

- **`ansible/roles/soc_agents`** installs the vendor's Wazuh MSI and a
  Velociraptor MSI with `win_*` modules. Its inventory is the six and nothing
  else (ADR-0077 decision 1): a Linux guest is configured by its runbook.
- **`odin`'s Caddy serves the two MSIs on `8448`** to `.50`–`.55` alone. The
  Velociraptor MSI carries the client config: the server URL, its CA and the
  enrolment nonce. That is why it is served by address and not from SYSVOL
  (#864).
- **The Velociraptor server built a Windows MSI and a Linux RPM on first
  start**, but no Debian package.
- **`WazuhAgentsNotConnected` expects an agent only for a guest whose
  `windows_exporter` answers.** A Linux agent could drop away unnoticed.

`odin` runs Wazuh manager 4.14.8 and Velociraptor server 0.77.3. The six run
agent 4.14.7 and client 0.77.2.

## Decision

**1. garuda installs two Debian packages from `odin`'s `8448`.** The Caddyfile
adds `10.0.30.62/32` to the addresses that may fetch. Nothing else changes in
who is served.

**2. The Wazuh agent is the vendor's `.deb`, pinned.**

- **Version:** 4.14.8, the manager's. An agent may not be newer than its
  manager, and garuda starts level with it. The six keep their own pin, which
  moves when they are upgraded in step.
- **The pin** is version and sha256, in `stacks/soc/linux-agents.yaml`.
- **The hash's provenance:** it was taken from the package and agreed with the
  `SHA256` that Wazuh's apt index lists. That index is covered by
  `dists/stable/InRelease`, which carries a good signature from the Wazuh
  Signing Key (`0DCF CA55 47B1 9D2A 6099 5060 96B3 EE5F 2911 1145`).
- **Staging:** `scripts/stage-agent-msis.sh` fetches the package and refuses
  one that does not match.

**3. The Velociraptor client `.deb` is built by the server.**

- **What goes in:** its client config (`config client`), packaged with the
  server's own binary (`debian client`), so the client is 0.77.3, the server's
  version.
- **No pin:** a build is not byte-reproducible.
- **Staging** keeps a `.deb` already staged for the running server's version
  rather than rebuild it, and prints its sha256.
- **garuda's install** checks the downloaded file against that hash, read
  from `odin` over SSH rather than from the same unauthenticated HTTP origin.

**4. Enrolment is by runbook, not by `ansible/`.**

- **Where:** garuda's runbook §12 holds the steps.
- **The Wazuh enrolment password** is `odin`'s `authd.pass`, the six's
  `LAB_WAZUH_REGISTRATION_PASSWORD`. It reaches garuda on standard input only,
  never on a command line.
- **Group:** the agent enrols as `garuda`, in the `default` group. The
  Windows-only `agent.conf` block does not reach it, and the stock Linux
  collection applies.

**5. `WazuhAgentsNotConnected` expects garuda's agent while garuda is up.**

- **How:** garuda's own Alloy job, `up{job="garuda-alloy"}` with
  `instance="garuda"`, stands in for the missing `windows_exporter`, and the
  by-name join is unchanged.
- **Not every Alloy job:** `alexander`, `eden` and `fenrir` report through
  Alloy and enrol in nothing.

## Consequences

- **A Linux guest's install is a runbook step.** It is not repeatable from
  `phoenix` the way the six's is. That is ADR-0077's boundary, kept. A second
  Linux guest would follow garuda's §12 and add its own Alloy job to the rule.
- **The 8448 allowlist names one more address.** The residual
  `docs/security.md` accepts for the MSI now covers the Velociraptor `.deb`
  too: an address on this segment can be spoofed, and whoever holds the
  package can enrol a rogue client.
- **Version drift has two pins to move.** A manager bump now means the six's
  role pin and `linux-agents.yaml`. A Velociraptor server bump means
  re-staging, which builds a new `.deb`; garuda upgrades by installing it.
- **The stock rules apply to garuda.** `local_rules.xml` is all Windows
  event-channel rules; nothing here tunes Linux detections yet. Noise from an
  analyst's own tools, such as Wireshark capturing or Docker starting
  `siemup`, is expected, and is tuned if it becomes a problem.
- **OpenVAS, #921's phase 3, scans from the machine the SOC now watches.** Its
  scans will show in garuda's own agent too, which is the detection test
  ADR-0091 wants.
