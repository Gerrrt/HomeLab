# ADR-0070: Let guest disk capacity cross, read through the hypervisor

**Status:** Accepted · 2026-10

## Context

On 2026-10-01 `odin`'s 30 GB root reached **98%, with 622 MB free**, on
superseded Docker images, and nothing would have said so
([#778](https://github.com/Gerrrt/HomeLab/issues/778); the changelog entry for
that day). A full root on `odin` stops the Wazuh manager and the indexer. The
SOC goes blind, and the guest built to notice that is the one that went quiet.

[#775](https://github.com/Gerrrt/HomeLab/issues/775) gave the lab Prometheus
`HostDiskWillFillIn24h` and `HostDiskCritical` for the guests that push to it.
They show in the lab's Grafana and page nobody, because the lab has no
Alertmanager ([ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md))
and cannot reach the estate's
([ADR-0007](0007-defensive-estate-and-offensive-range.md)). A filling SOC disk
is therefore noticed only by someone already looking at the lab, which nobody
does.

[ADR-0028](0028-let-guest-liveness-cross-but-not-guest-telemetry.md) let a
guest's run state cross, read from `qm` on the hypervisor, and drew the line in
a table. "Any metric produced inside it" is on the side that does not cross. A
guest's filesystem usage, read through its qemu-guest-agent, is produced inside
it. So this cannot be done under ADR-0028 as written, and pretending otherwise
would leave the line meaning less than it says.

## Decision

**A guest's filesystem capacity, meaning size and bytes used per filesystem, may
cross. It is read on the hypervisor, through the guest agent, by
`qm guest cmd <vmid> get-fsinfo`. Everything else about what a guest is doing
still stays in the lab.**

ADR-0028's table, extended:

| Crosses | Does not |
| --- | --- |
| That a guest exists, its VMID and name | Any other metric produced inside it |
| Whether it is running | Any log line it writes |
| How many guests the hypervisor has | What services it runs, and their health |
| **How full each of its filesystems is, and its mountpoint as a label** | **What is on them: files, paths below a mountpoint, which process wrote what** |
| **Whether its agent answered** | |

There are three reasons it belongs on the left.

- **It is capacity, not activity.** The disk is storage the hypervisor
  allocated, and how much of it is used is the same class of fact as how full
  the thin pool under it is, which the estate already collects
  ([#538](https://github.com/Gerrrt/HomeLab/issues/538)). It says nothing about
  what the guest is doing, only that it is running out of room to do it.
- **Nothing new is opened.** The question travels over the virtio serial
  channel between QEMU and the guest, the one `qm guest exec` already uses. The
  answer leaves through `Saruman`'s existing pass to `10.0.99.20`
  ([#88](https://github.com/Gerrrt/HomeLab/issues/88)). There is no firewall
  pass, route or listener, and the cost is one row in the collectors table,
  exactly as ADR-0028 priced its own.
- **The alternatives open what this does not.** A lab Alertmanager reverses
  ADR-0020, and it needs a notification channel and its credentials living on
  VLAN 30, the segment built to hold attackers. Pointing the lab Prometheus at
  the estate's Alertmanager opens the VLAN 30 → 99 path ADR-0007 exists to
  refuse, and `stacks/lab/prometheus/prometheus.yaml`'s header already argues
  against it. Both were rejected.

**The agent's answer is hostile input.** This is the real difference from
ADR-0028. `qm list` is the hypervisor's own config; `get-fsinfo` is whatever the
guest's agent says, and a compromised guest controls that.
`scripts/collect-guest-disk-state.sh` therefore:

- parses it in python and never lets a byte reach a shell
- requires every count to be a non-negative integer, with used no more than size
- cuts mountpoint and fstype labels to a charset whitelist and a length
- keeps at most 32 filesystems per guest, so no guest can inflate the estate's
  cardinality

What a lying guest can still do is lie **about its own disk**: page falsely, or
hide its own fill. This ADR accepts that. A guest that is compromised enough to
forge its agent's replies has bigger news than its disk, and the SOC watching it
is the control for that, not this.

## Consequences

- **A filling guest disk pages through the estate's normal route.**
  `GuestDiskCritical` (below 10% free for 15 minutes) and
  `GuestDiskWillFillIn24h` are both `severity: critical`, so they go to
  `urgent` and ntfy.sh. The forecast is critical where the estate's
  `HostDiskWillFillIn24h` is a warning, for `ThinPoolWillFillIn24h`'s kind of
  reason: a host on VLAN 99 is one someone is looking at, and a lab guest is
  not.

- **It covers every running VM on `Saruman` with no list to keep.** That
  includes `fenrir`, built 2026-09-30, and any guest created later, provided it
  runs an agent.

- **A guest without a working agent is invisible here, and says so.**
  `--agent enabled=1` installs nothing; `alexander` ran without one until
  2026-09-20. `homelab_guest_agent_up` records each running guest's answer.
  `GuestAgentSilent` warns when an agent that answered within the last day has
  not for an hour, so a guest that never had one stays quiet rather than
  alerting forever. `odin`'s agent has hung under load before; each guest is
  asked under a timeout, so one hung agent does not lose the others.

- **The lab's own copies of the disk rules stay.** They are still the view in
  the lab's Grafana, with the guest's own `node_exporter` detail. They are no
  longer the only copy and still page nobody.

- **ADR-0028 is amended, not superseded.** Its decision about run state stands
  unchanged. This ADR widens what crosses by one named fact, and the note on
  ADR-0028 says so. "Lab telemetry stays in the lab" in ADR-0007 is narrowed the
  same way, and gets the same note.

- **The next request to let something cross should meet this bar or explain
  why not.** It must be read on the hypervisor, open nothing new, and be
  treated as hostile if the guest wrote it. "It would be useful in the estate"
  is not the bar. Service health inside a guest, the other half of
  [#257](https://github.com/Gerrrt/HomeLab/issues/257), is still on the right of
  the table.
