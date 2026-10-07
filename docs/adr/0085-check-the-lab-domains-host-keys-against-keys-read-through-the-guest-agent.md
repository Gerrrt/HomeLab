# ADR-0085: Check the lab domain's host keys against keys read through the guest agent

**Status:** Accepted · 2026-10 · amends decision 2 of
[ADR-0077](0077-configure-the-lab-domain-with-ansible-from-phoenix.md) (host
keys are now checked)

> [!NOTE]
> **Renumbered to 0085 on 2026-10-07.** This landed as ADR-0082 in
> [#931](https://github.com/Gerrrt/HomeLab/pull/931), and
> [#962](https://github.com/Gerrrt/HomeLab/pull/962) took the same number
> **twenty-six seconds earlier** (13:48:33Z against 13:48:59Z) for
> [ADR-0082](0082-serve-the-wiki-over-tls-and-deploy-it-from-a-verified-checkout.md).
> Two files claimed one number on `main` until this commit.
> `check_adr_numbers()` in [`check_docs.py`](../../scripts/check_docs.py)
> caught it, and its rule, that the one that landed second renumbers, chose
> this file. 0083 and 0084 were already claimed by open PRs, so it took
> 0085. The decision is untouched. Text that predates the renumber,
> including #931's own commits and description, calls it 0082.

## Context

ADR-0077 decision 2 made OpenSSH the way `phoenix`'s Ansible reaches the lab
domain's six guests, and left host keys unchecked:

> Host keys are not pinned (`host_key_checking = false`). Every rebuild replaces
> them, and a rebuild is the normal case here.

The premise is right: each clone generates its own keys when `SetupComplete.cmd`
first starts `sshd`, so a key pinned once is wrong after the next rebuild.
But the conclusion does not weigh what crosses those connections. Ansible sends
`LAB_ADMIN_PASSWORD` (the domain's Administrator) and `LAB_DSRM_PASSWORD` over
them. The segment is VLAN 30, built to hold attackers, and
[`security.md`](../security.md) already counts ARP spoofing on it. A guest that
answered for `10.0.30.50` would be handed the domain. The 2026-10-03 repository
review found this ([#846](https://github.com/Gerrrt/HomeLab/issues/846)).

Trust on first use does not help here, because every rebuild is a first use.
What helps is a second channel that does not cross the segment. The guest
agent is one. Proxmox reads a file from inside the guest over virtio-serial,
and `phoenix` asks Proxmox over the API's verified TLS (ADR-0074). Reading
`C:\ProgramData\ssh\ssh_host_ed25519_key.pub` this way gave all six keys on
2026-10-06. An SSH session from `phoenix` accepted each one, and a key with one
character changed was refused with `REMOTE HOST IDENTIFICATION HAS CHANGED`.

## Decision

**Host keys are checked, against a file written from the guests' own keys.**

- **`scripts/lab-known-hosts.sh` writes `ansible/.known_hosts`.** For each host
  in the inventory, it finds the guest of that name through the API and reads
  its ed25519 public key with `agent/file-read`. It replaces the file only
  when all six reads succeed. The file is gitignored: it is public, but it
  goes stale at the next rebuild.
- **Ansible uses that file and no other.** `host_key_checking = true`, and
  `group_vars/all.yaml` passes `UserKnownHostsFile` (that file),
  `GlobalKnownHostsFile=/dev/null` and `StrictHostKeyChecking=yes`. A key the
  file does not hold is refused. It is never added.
- **The script runs after `tofu apply` creates or replaces any of the six,**
  before the first playbook. Forgetting it fails closed: Ansible refuses the
  rebuilt guest.
- **The read is its own grant.** `PhoenixHostKeys` holds
  `VM.GuestAgent.FileRead` and nothing else. It is granted on the
  `lab-domain` pool, not added to `PhoenixBuilder`. `PhoenixBuilder` is granted
  on `/vms`, where FileRead would let `phoenix` read any file on any guest
  on `Saruman`, the SOC's included. On the six it adds nothing: `phoenix`
  already holds their Administrator password.

The rest of ADR-0077 decision 2 stands. Of its reasons for rejecting WinRM,
the first changes form but not conclusion. The Windows build's WinRM is no
longer HTTP Basic open to the segment: it is HTTPS on 5986 with a certificate
the build makes, admitting `phoenix` alone, and `SetupComplete.cmd` still
removes it from every clone (#846). That protects one build's password for
one build. It does not give six long-lived guests a certificate anything could
verify, which is ADR-0077's second reason, and that reason stands.

## Consequences

- **A rebuild has one more step**, and the step depends on the guest agent.
  Windows agents sometimes time out on a file read (leviathan, one read in
  three on 2026-10-06), so the script tries each guest three times. A guest
  whose agent is down cannot be pinned, and so cannot be configured, until
  the agent answers. That is the right way round.
- **The check covers the network, not the hypervisor.** The keys are only as
  trustworthy as `Saruman`, its API certificate and the guest's own agent.
  An attacker on the hypervisor already owns the guests, so that adds
  nothing.
- **A Linux guest added later (#421) needs its own key path.** The script reads
  the Windows path only. It refuses a guest where that file is not an
  ed25519 key; it does not guess.
- **Other SSH from `phoenix` to the lab is unchanged.** `packer-smoke.sh` still
  skips checking against its throwaway clone, which no password crosses.
- **ADR-0077 carries a note pointing here.** Its text is left as written, per
  ADR-0001.
