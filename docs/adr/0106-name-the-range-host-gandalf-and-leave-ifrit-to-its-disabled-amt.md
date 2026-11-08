# ADR-0106: Name the range host `gandalf`, and leave `ifrit` to its disabled AMT

**Status:** Accepted · 2026-11 · amends the host name in
[ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
and [ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)

> [!NOTE]
> **`Saruman`'s address.** `Saruman` moved from `10.0.30.110` to
> **`10.0.30.20`** on 2026-11-07, as
> [`build-the-playground.md`](../runbooks/build-the-playground.md) §3 has it
> ([#421](https://github.com/Gerrrt/HomeLab/issues/421)). Each rule, export,
> alias and command below that names `.110` now names `.20`, and the decision
> is unchanged. The text below is left as written, per ADR-0001.

## Context

[ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
named the range host `ifrit` in 2026-09, before there was a machine.
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) sized
it, the ThinkCentre M80q was bought on 2026-10-05, and on 2026-11-07 Proxmox
VE 9 was installed on it
([#421](https://github.com/Gerrrt/HomeLab/issues/421),
[`build-the-playground.md`](../runbooks/build-the-playground.md) §1). The
operator named the node **`gandalf`** at the installer. The repository had
called it `ifrit` in about 120 lines outside the records.

This was not a typo. The operator's naming splits a server in two, and the
DL360 already shows it:

| Box | Its management plane | Its hypervisor |
| --- | --- | --- |
| HPE DL360 Gen9 | `shiva`, the iLO at `10.0.30.10` | `Saruman`, at `10.0.30.110` |
| Lenovo ThinkCentre M80q | `ifrit` | `gandalf`, at `10.0.30.30` |

On the M80q, the management plane is Intel AMT. At the same sitting it was
unconfigured at the firmware prompt and left disabled, because ADR-0014 never
accounted for a second management plane on ImaginationLAN. So the half `ifrit`
names is switched off, and the half the documents meant by `ifrit` is `gandalf`.

[ADR-0026](0026-check-the-documents-where-the-truth-is.md) already lists
`shiva` "treated as the hypervisor for several revisions when it is the iLO".
A repository that calls this hypervisor by its management plane's name would
repeat that mistake on a second machine, and this time on purpose.

**Now is the cheap moment**, for the reason
[ADR-0038](0038-name-the-nas-smaug-and-reserve-zion-for-the-box-that-does-not-exist.md)
gave for `smaug`. The node is empty: no guest, no template, no scrape target,
no age recipient, no firewall rule. Proxmox keeps the node name in
`/etc/pve/nodes/<name>`, and every guest is filed under it, so renaming the
node is cheapest before anything is filed. The Packer default that names
Kali's target node (`packer/variables.pkr.hcl`) has never been run.

## Decision

**1. The range host is `gandalf`**, Proxmox VE 9, at `10.0.30.30` on
ImaginationLAN, untagged on `neo`'s `ether20`. Every constraint of ADR-0014
and ADR-0017 applies to it unchanged: one NIC, no trunk, the portless range
bridge `vmbr1` on `172.30.30.0/24`, no route out, and off between sessions.
**Only the label moves.**

**2. `ifrit` names the M80q's Intel AMT, and no host answers to it.** AMT is
unconfigured and disabled. Nothing gets an address, a DNS name or a Kea
reservation under `ifrit`. Turning AMT on would put a management plane on the
segment that holds the attack VM, which is a new ADR rather than a setting;
if one is ever written, the name is waiting. Until then, a current-state document
that uses `ifrit` for the hypervisor is a bug, as ADR-0038 made `zion`.

**3. The records are not edited.** Per
[ADR-0001](0001-record-architecture-decisions.md), ADR text, the changelog
and the exercises keep `ifrit` as written. ADR-0007, ADR-0014, ADR-0017,
ADR-0039 and ADR-0096 decide things about the host by name and gain a note
pointing here. In every other ADR, and in the changelog before 2026-11-07,
read `ifrit` as `gandalf`. ADR filenames that contain `ifrit` keep it, because
links point at them.

**4. The pattern, which is not a rule.** On ImaginationLAN the two
hypervisors are Tolkien's wizards, and the BMC and the guests are Final
Fantasy summons. That describes what exists. ADR-0038 already found that the
estate has no naming rule, and this ADR does not make one.

## Consequences

- **The sweep.** The current-state documents, the diagrams, the runbooks,
  the Packer files, and the comments in the rule files and compose files say
  `gandalf`. The three runbooks that listed `ifrit` among the segment's
  summons (`build-the-jumpbox.md`, `build-the-lab-guest.md`,
  `build-the-soc-guest.md`) drop it from those lists.
- **`packer/variables.pkr.hcl`'s `kali_node` defaults to `gandalf`.**
  Otherwise, the first Kali build (#790) would have targeted a node that does
  not exist.
- **`build-the-playground.md` keeps its filename**, and its title names
  `gandalf`.
- **#421's title changes**, as #413's did for `smaug`. Its body is left as
  filed.
- **The cost is one more name to know.** A reader of the older ADRs meets
  `ifrit` and has to find this note. That is the same cost ADR-0038 accepted
  for `zion`, and the cost of a misnamed hypervisor is higher.
