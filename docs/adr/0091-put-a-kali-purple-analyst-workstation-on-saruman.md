# ADR-0091: Put a Kali Purple analyst workstation on Saruman

**Status:** Accepted · 2026-10

## Context

The lab has a SOC, but no seat for an analyst to sit at. Wazuh and
Velociraptor run on `odin` ([ADR-0030](0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)),
Zeek on `fenrir` reads a mirror of the lab bridge
([ADR-0068](0068-mirror-the-lab-bridge-to-zeek-with-tc-not-open-vswitch.md)),
and Suricata runs on `morpheus`. #449's weaknesses all raise alerts (rules
100100–100105). Working one of those alerts means a browser, CyberChef,
Wireshark against a capture, and somewhere to keep the notes, and none of the
lab's guests is that place. [#921](https://github.com/Gerrrt/HomeLab/issues/921)
asks for one.

Kali Purple is the obvious distribution for it, and it brings a problem. It
bundles a whole SOC: Elastic as the SIEM, Zeek, Suricata, and response
tooling. Every one of those already runs here.

There is also a second job. The dotfiles system has two role layers on top of
its OS layers. `dotfiles-Offense` belongs on `ifrit`'s Kali (#790), and
`dotfiles-Defense` has had no home.
[ADR-0090](0090-test-the-dotfiles-os-layers-on-on-demand-saruman-guests.md)
names `garuda` as that home. Defense installs no packages itself: it stacks
on an OS layer (`dotfiles-Debian`, which supports Kali rolling) and needs
Docker for its own detection lab, `siemup`.

What `Saruman` had on 2026-10-06: 54.5 GiB of RAM free.

## Decision

**1. A guest on `Saruman`, named `garuda`, at `10.0.30.62`, VMID 162.**

- **Why `Saruman`.** [ADR-0007](0007-defensive-estate-and-offensive-range.md)
  splits the lab as "`Saruman` defends, `ifrit` attacks", and a defender's
  machine belongs on the defended side, beside `odin`.
- **Why not `ifrit`.** The range is built so that its targets have no route
  ([ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)),
  and defensive tooling inside the attack range would blur that split.
- **Why .62.** It sits in `odin`'s decade, next to the SOC it works from, as
  `diabolos` holds .61. Every `.x0` is taken.

**2. Kali Purple without its SOC.** The SIEM and the sensors are not installed,
or are disabled where a metapackage pulls them in. A second SIEM would split
the telemetry, and the RAM, between two half-fed systems. `garuda` adds four
things:

- **An analyst desktop:** CyberChef, Wireshark, and the tools for working an
  alert Wazuh raised.
- **The `dotfiles-Defense` layer**, on `dotfiles-Debian`. Its `siemup`
  detection lab is the one container stack allowed beyond the collector, and
  only on demand: up for an exercise and down after it.
- **Vulnerability scanning of the lab** (OpenVAS/GVM). This is a later phase,
  covered below.
- **The purple half of an exercise:** attack from `ifrit`, then watch and
  respond from here.

**3. Not a domain member.** `garuda` stands beside `ad.matrix.elysium`, as
`odin` and `eden` do, decided on #921 on 2026-10-06:

- **The domain is the target.** #449 gives it weaknesses on purpose, and
  exercises aim to take it over. A domain-joined workstation falls with it,
  case notes and scan results included.
- **The domain is reverted,** and a member's secure channel does not survive
  that.
- **Nothing here needs membership.** An authenticated scan takes a domain
  credential, and LDAP answers a non-member.

**4. Always on.** `garuda` is not tagged `on-demand`, unlike #920's dotfiles VMs,
and it boots with the host. That has four consequences:

- `HypervisorGuestStopped` finds it stopped
  ([ADR-0079](0079-tag-on-demand-guests-and-leave-them-out-of-the-stopped-guest-alert.md)).
- Its 8 GiB counts against `Saruman` all the time.
- Its own Alloy ships to `alexander` like every other lab guest's
  ([ADR-0028](0028-let-guest-liveness-cross-but-not-guest-telemetry.md)).
- It is backed up, because its case notes are not in git.

**5. Template 910, not 902.** `garuda` is a full clone of `tpl-kali-saruman`,
VMID 910. That is the same `packer/kali.pkr.hcl` and preseed as 902, built
on `Saruman` from the pinned 2026.2 installer on `smaug-iso`
([ADR-0074](0074-build-the-lab-templates-with-packer-from-phoenix.md)). 902
stays `ifrit`'s: a template belongs to the node it was built on, and the attack
VM's template should not be the defender's. The guest itself is declared in
`tofu/guests.tf`, in a pool of its own, `analyst`
([ADR-0076](0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md)).

**6. Phased.** This decision builds the workstation. Two things #921 asks for
come later, each with its own change:

- **Enrolling `garuda` in Wazuh and Velociraptor.** No Linux guest is enrolled
  in either today. The agents, `soc_agents` and `odin`'s package caddy are
  Windows-only, and that caddy answers `.50`–`.55` alone. A Linux enrolment is
  a decision of its own.
- **OpenVAS.** It needs its scope written down (VLAN 30 only, nothing outside
  it), and its scans will trip Suricata, Zeek and Wazuh. That is a useful
  detection test, but each scan needs an Alertmanager silence owned by #921,
  deleted when the scan ends ([`observability.md`](../observability.md),
  Silences).

TheHive waits until it earns its keep.

## Consequences

- **A Kali guest now runs on the defended host.** It holds no offensive role:
  no range NIC, and no `dotfiles-Offense`. ADR-0017's "a Kali VM" on `ifrit` is
  unchanged.
- **Another template to build and keep.** 910 shares 902's file and preseed,
  so a preseed fix is one change for both. The ISOs are not shared: 910 names
  the 2026.2 file on `smaug-iso`, and 902's is chosen on `ifrit`, which cannot
  mount that share. A Kali build needs
  `phoenix`'s port 8800 open for its length, as Debian's does.
- **Another agent on the lab's ingest proxy.** `INGEST_TOKEN_GARUDA` is added to
  `stacks/lab` at build time, in the same change as `garuda`'s own age key,
  as `eden`'s was.
- **Defense's `siemup` is a standing temptation.** A detection lab left up
  would quietly be the second SIEM this decision refuses. The runbook's
  verification counts the containers.
- **8 GiB, continuously.** The headroom of 2026-10-06 covers it. The next
  always-on guest on `Saruman` should recount.
