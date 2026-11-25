# ADR-0125: Keep `gandalf` on, and stop `ragnarok` on a timer

**Status:** Accepted · 2026-11 · supersedes
[ADR-0124](0124-power-gandalf-off-on-a-timer.md) and amends
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)

## Context

[ADR-0124](0124-power-gandalf-off-on-a-timer.md) answered two audits that
found `gandalf` left on for days. It had the host power itself off six hours
after boot, or at the deadline a session's last `range-extend` set. It was
installed on 2026-11-22 and never proved.

Living with it the same day showed that the host is the wrong thing to turn
off:

- **Starting a session means walking to the rack.** `gandalf`'s BIOS
  powers on only at the button (`build-the-playground.md` §1), and its AMT is
  disabled ([ADR-0106](0106-name-the-range-host-gandalf-and-leave-ifrit-to-its-disabled-amt.md)).
  A host that turns itself off makes every session start at the rack.
- **The exposure is the attack VM, not the host.** ADR-0124's own Context
  names what the left-on host cost. `ragnarok` shares VLAN 30 with the estate
  (ADR-0014), and the host firewall goes unchecked while the box is up. The
  targets are on `vmbr1`, which has no port, and since 2026-11-22 the host
  drops everything `vmbr1` passes up to it (§2, `vmbr1_host_in`). A target
  left running reaches only the other guests on that bridge.
- **The host's own hardening no longer depends on being off.** After the
  2026-11-22 audit, `gandalf` has keys-only SSH with no forwarding, no
  workstation tooling, no forwarding on `vmbr0`, and the ingress table.
  Those hold whether it is up for an hour or a month.

What a host left on still lacks is anything watching it. ADR-0017 gave it no
monitoring because it was off by design: every rule watching it would be
"permanently firing or permanently silenced". A host that stays on has a
normal state, up, and a rule shape for it.

## Decision

**`gandalf` stays on. The attack VM, `ragnarok` (VMID 130), stops itself a
fixed time after it starts, or after the last extension a session asks
for.** The mechanism is ADR-0124's, aimed at the VM.

- **The deadline is six hours after `ragnarok` starts.** It is counted from
  the QEMU process's start, not the host's boot.
- **A session can replace it.** `range-extend H` on the host sets the
  deadline H hours from now, H from 1 to 12, as before. The extension is
  stored with the running VM's process ID, so a stop and a start always
  begin again from six hours, and it is cleared when the VM stops.
- **It warns before it acts.** `wall` at 30 and 5 minutes, on the host and,
  through the guest agent, inside `ragnarok`, where the session is.
- **It never stops the VM in the middle of a package install.** Past the
  deadline it asks the guest agent whether `dpkg`'s lock is held inside the
  VM, and waits for the next run if it is. An agent that does not answer
  counts as not busy, so a hung agent cannot hold the VM up.
- **The stop is `qm shutdown` with a forced stop after three minutes.**
- **A systemd timer runs the check every minute, under one lock**, as in
  ADR-0124. The script is `scripts/ragnarok-stop.sh` and its units are in
  `systemd/range/`. §7 installs them in place of ADR-0124's, and its
  read-back checks the timer is enabled and active.
- **The targets are not on the timer.** They have no route off `vmbr1`. They
  are reverted to `clean` at the start of each session, as before.
- **Monitoring the host is needed, and is its own decision.** It is
  [#1651](https://github.com/Gerrrt/HomeLab/issues/1651). It crosses the
  boundary ADR-0014 counts, so it needs its own ADR, which would supersede
  ADR-0017's "no monitoring". Until it lands, §7's read-back is the check.

Built under [#1647](https://github.com/Gerrrt/HomeLab/issues/1647).

## Consequences

- **A forgotten session ends the attack VM, not the range.** `ragnarok`'s
  time on VLAN 30 is bounded by its deadline, about a minute late, plus any
  `dpkg` wait inside the VM. The host and any running targets stay up.
- **The host firewall goes unchecked between sessions, for as long as the
  host is up.** ADR-0124 bounded that window at six to twelve hours. This
  decision leaves it unbounded until #1651 lands. The ingress table and
  keys-only SSH sit behind the firewall, and nothing on VLAN 30 but
  `ragnarok`, Hicks and the estate can reach the host, but nothing reports
  if the firewall goes off. That is the cost this decision accepts, and the
  reason #1651 is not optional.
- **Proxmox's updates are no longer applied at each power-on.** §7 applied
  them when a session started, and the box was off between sessions.
  `unattended-upgrades` covers Debian's packages daily now that the box is up.
  Proxmox's own still need `apt full-upgrade` by hand, and #1651 is where
  pending ones become visible.
- **The range SSD runs every hour now.** On 2026-11-22 it read 49,443
  power-on hours and 8 reallocated sectors. Always on, it ages about 730
  hours a month. The range is disposable (ADR-0017), so its failure costs a
  rebuild, not data. #1651 should watch its SMART counters.
- **After a power cut it stays off.** The BIOS setting stays at *Power Off*.
  Changing it to *Power On* is a visit to the box, and with nothing yet
  watching `gandalf`, a host that comes back by itself is one nobody knows
  is up. It is reopened with #1651.
- **`range-extend` now needs `ragnarok` running.** It refuses while the VM is
  stopped, because there is no run to attach the deadline to.
- **This decision is reopened** if the targets start needing a bound of their
  own, which would mean something on `vmbr1` can reach past it.
