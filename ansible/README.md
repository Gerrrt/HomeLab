# ansible

This directory configures the lab domain's six guests from `phoenix`
([ADR-0075]). The *why* is in [`build-the-lab-domain.md`][runbook] and
ADR-0029. This page covers what is here and how to run it.

```bash
cd ansible
set -a; . ~/.config/proxmox/phoenix.env; set +a
ansible-playbook lab-domain.yml --check --diff   # what would change (existing domain only)
ansible-playbook lab-domain.yml                  # apply
ansible-playbook verify.yml                      # read-only proof
```

Run it from this directory, because `ansible.cfg` is read from the current
directory. Installing Ansible and the collections on `phoenix`, the two
secrets, and the one-time step that lets the hand-built six be reached are
covered in the runbook's [*Run it from `phoenix`*][run] section.

## What is here

- `inventory/hosts.yaml`: the six guests, at their final addresses.
  - Groups: `dc_primary`, `dc_replica`, `dcs`, `members`, `endpoints`, and
    `servers` (the four evaluation-licensed guests).
  - `lab_role` matches the `role` label in the lab Prometheus.
- `inventory/group_vars/all.yaml`: ADR-0029's values, plus how a guest is
  reached:
  - SSH as Administrator, with `phoenix`'s key and PowerShell as the shell.
  - The pinned `windows_exporter` version and its sha256.
- `lab-domain.yml`: the playbook, one play per stage, in the runbook's order.
- `verify.yml`: read-only. It runs the runbook's §9 checks, and asserts that
  each item on the "Do not harden this domain" list is still shipped.
- `roles/`, in order:
  - `base`: name, DC static addresses, resolvers, and the build password
    rotated.
  - `dc_forest`: forest, forwarder, no root hints, and the clock. It asserts
    the clock is right before anything joins.
  - `dc_replica`: the second DC, left on NT5DS.
  - `dc_resolvers`: each DC resolves through its partner, then loopback.
  - `member`: joins.
  - `exporter`: `windows_exporter`, plus the 9182 rule admitting `alexander`.
  - `licence_clock`: the evaluation gauge, on the four servers.
  - `dns_forwarder`: shared by both DC roles.
  - `domain_role`: whether a guest is a DC already, imported by `base` and
    `dc_replica` in their own plays.
- `requirements.txt`, `requirements-lint.txt` and `requirements.yml`: exact
  pins for `ansible-core`, `ansible-lint` and the three collections.

## Tags

| Tag | Stage | Runbook |
| --- | --- | --- |
| `base` | Name, address, resolver, password | §2 |
| `forest` | `bahamut`: forest, forwarder, clock | §3 |
| `replica` | `leviathan`, then both DCs' resolvers | §4 |
| `join` | The four members join | §5, first sentence |
| `exporter` | `windows_exporter` and its firewall rule | §7 |
| `licence` | The evaluation gauge | §7 |

[#449](https://github.com/Gerrrt/HomeLab/issues/449) adds the tiers, users and
deliberate weaknesses as further tags in this same playbook.

## Rules this tree keeps

- **Nothing here hardens anything.** No role touches LLMNR, NetBIOS over
  TCP/IP, IPv6, WPAD or the DNS `GlobalQueryBlockList`, and `verify.yml` fails
  if any of them has changed. Do not add a hardening role, from a collection
  or by reflex. It deletes the exercises the segment exists for.
- **The lab domain, and only the lab domain.** No host outside
  `ad.matrix.elysium` goes in the inventory. Compose stacks converge on their
  own timer (ADR-0021), and `phoenix` never pushes to them (ADR-0043).
- **Secrets come from `phoenix.env`.** The two variables are
  `LAB_ADMIN_PASSWORD` and `LAB_DSRM_PASSWORD`. Every task that uses one is
  `no_log`.
- **A second run changes nothing.** Every task compares before it acts. A
  task that reports `changed` on a guest already in the right state is a bug
  in that task.
- **CI proves it parses, `phoenix` proves it configures.**
  `scripts/lint.sh` runs `ansible-lint`, which includes the syntax check. CI
  has no route to VLAN 30.

[ADR-0075]: ../docs/adr/0075-configure-the-lab-domain-with-ansible-from-phoenix.md
[runbook]: ../docs/runbooks/build-the-lab-domain.md
[run]: ../docs/runbooks/build-the-lab-domain.md#run-it-from-phoenix
