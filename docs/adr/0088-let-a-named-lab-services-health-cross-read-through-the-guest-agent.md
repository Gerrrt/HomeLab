# ADR-0088: Let a named lab service's health cross, read through the guest agent

**Status:** Accepted · 2026-10 · widens
[ADR-0028](0028-let-guest-liveness-cross-but-not-guest-telemetry.md), as
[ADR-0070](0070-let-guest-disk-capacity-cross-read-through-the-hypervisor.md) did

## Context

ADR-0028 named its own open half in its first consequence: *"The guest died"
is now detectable and "the lab stack died" still is not.* A guest that is
powered on with a dead service inside it looks healthy from the estate, and
[#858](https://github.com/Gerrrt/HomeLab/issues/858) lists the three failures
that hide there:

- **A crashed lab Prometheus on `alexander`.** It is what would have
  evaluated the lab's rules, so nothing notices it go (`lab.rules.yaml`).
- **A Zeek on `fenrir` whose event loop has stopped while the mirror still
  delivers.** `ZeekMirrorInactive` proves the mirror, not Zeek
  (`stacks/sensor/README.md`).
- **A Wazuh manager on `odin` whose listener is down while its ports answer,**
  and Velociraptor beside it.

The SOC exists to notice an attack on the lab. When it fails quietly, the lab
is unmonitored while looking monitored. The lab's Prometheus sends no alerts
(ADR-0020), and the estate cannot ask it (ADR-0007), so the estate has to learn
this some other way.

## Decision

**Whether a short, fixed list of named lab services is healthy may cross: one
bit per service, as each container's own Docker healthcheck reports it. It is
read on the hypervisor, through the guest agent, by one fixed command.
Everything else about what a guest is doing still stays in the lab.**

ADR-0028's table, as ADR-0070 extended it, extended again:

| Crosses | Does not |
| --- | --- |
| That a guest exists, its VMID and name | Any other metric produced inside it |
| Whether it is running | Any log line it writes |
| How many guests the hypervisor has | What services it runs beyond the list below, and any detail of their health |
| How full each of its filesystems is (ADR-0070) | What is on them |
| Whether its agent answered | |
| **Whether each service in the list is `running healthy`** | **Why it is not: the healthcheck's output, the container's log, its restart count** |

The list lives in `scripts/collect-guest-service-state.sh`, and adding a row
to it is a change to this table:

| Guest | Container | What its healthcheck tests |
| --- | --- | --- |
| `alexander` | `lab-prometheus` | `/-/healthy` |
| `fenrir` | `sensor-zeek` | `stats.log` written within 11 minutes |
| `odin` | `soc-wazuh-manager` | `wazuh-remoted is running` |
| `odin` | `soc-velociraptor` | `/metrics` answers |

There are three reasons it belongs on the left.

- **It is one bit about a service the repository already names.** The
  services are not discovered: the estate learns nothing about what a guest
  runs that `stacks/` does not already say. And the bit is the verdict of a
  healthcheck written in `compose.yaml`, so what it tests was reviewed where
  the service was.
- **Nothing new is opened.** The command travels over the virtio serial
  channel `qm guest cmd` already uses for ADR-0070, and the answer leaves
  through `Saruman`'s existing pass to `10.0.99.20`. There is no firewall pass,
  route or listener.
- **The alternatives open what this does not.** #858 weighed a 99 → 30 pass so
  the monitoring host could probe `alexander`'s Prometheus, Grafana and the
  Wazuh API. That is a new path into the segment built to hold attackers, for
  a check this makes without one. A lab Alertmanager reverses ADR-0020, for
  the reasons ADR-0070 gave.

**The command runs as root inside the guest.** `qm guest exec` runs as the
guest agent does. Root on `Saruman` could always do that, and the console
gives the same, so no power is added. But this is the first *scheduled* use
of it, so the command is fixed:

```sh
docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' <container>
```

Its argv is built from the table above and nothing else. Nothing a guest has
said is ever part of the next command.

**The answer is hostile input**, as ADR-0070's is. The collector parses qm's
JSON in python and never in a shell. It caps the answer's size before reading
it. It requires a finished command with an integer exit code. And the only
thing it takes from the guest's output is whether that output equals exactly
`running healthy`. What a lying guest can still do is lie **about its own
services**: say a dead Zeek is healthy, or a healthy one is not. This ADR
accepts that, for ADR-0070's reason. A guest compromised enough to forge its
agent's replies has bigger news than its own health, and the SOC is the
control for that. When the SOC is the guest lying, this check is not the
control either, and nothing that reads the guest's own word can be.

## Consequences

- **A dead lab service reaches a phone, at warning.** `GuestServiceUnhealthy`
  fires after fifteen minutes and goes to `default`, the in-house ntfy. A
  blind SOC is serious, and it is not a 2 a.m. page for the house (#858).
- **A hung agent is unknown, not unhealthy.** The collector writes
  `homelab_guest_service_checked 0` and no health series. So
  `GuestServiceUnhealthy` cannot fire on it, and `GuestServiceUnchecked` says
  so after an hour. A stopped guest has no series at all:
  `HypervisorGuestStopped` owns it.
- **The detail stays in the lab.** Agent disconnects, the analysisd queue,
  and Zeek's byte rate per log are what an analyst wants next. They are lab
  rules on the lab's own Prometheus, visible in its Grafana and paging no one.
  #858's third option, left to [#1038](https://github.com/Gerrrt/HomeLab/issues/1038).
- **The list can go stale silently.** A container renamed in `stacks/`
  without its row here reports *missing*, which is not healthy, so it alerts.
  That is the right failure. A guest renamed in Proxmox drops out of the run
  without a sound. The second is the price of matching on the name `qm list`
  gives rather than a VMID that a rebuild changes, and it is the same blind
  spot ADR-0028 accepted for a second hypervisor.
