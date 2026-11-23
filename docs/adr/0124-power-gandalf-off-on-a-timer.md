# ADR-0124: Power `gandalf` off on a timer

**Status:** Accepted · 2026-11 · amends
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)

## Context

[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) gives
the range no monitoring, because the host is "off by design between
sessions". Every rule watching it would then be "permanently firing or
permanently silenced". Its Consequences name what that costs: "Nothing knows
whether `ifrit` is powered", and the useful statement, "this host is on when
it should be off", has no rule shape. So the box being off rests on a person
remembering. [`build-the-playground.md`](../runbooks/build-the-playground.md)
§7 says so: "Nothing is watching, so the discipline is yours."

Two audits have found it left on:

- **2026-11-13.** The host had been up since 2026-11-07, and the attack VM
  `ragnarok` stayed running overnight with a lease on VLAN 30.
- **2026-11-22.** Nothing had changed for nine more days. The task log shows
  `ragnarok` running from 2026-11-12 to 2026-11-22, and the host was up from
  2026-11-07 to 2026-11-22. The range disk's power-on hours rose by 224 in
  nine days.

Three things the design leans on assume the box is off most of the time:

- **ADR-0017's "no monitoring".** It holds only while the box is off.
- **§7's per-session read-back.** It is how the host firewall is checked,
  because no collector reaches `gandalf`. A fortnight of uptime is a
  fortnight unchecked.
- **ADR-0014's exposure.** The attack VM shares VLAN 30 with the estate. It
  is bounded by how long the attack VM is on, and nobody was bounding that.

Three ways to stop relying on memory:

1. **A collector and an "on too long" alert.** Give `gandalf` the
   `pve-firewall-state` collector `Saruman` has, plus its uptime, and alert
   when it has been up past a threshold. It would watch the firewall too. It
   also overturns ADR-0017's "no monitoring" rather than amending it. It
   needs an agent on the range host and a way for its metrics to reach
   `prometheus` across the boundary ADR-0014 counts. And it reports the fault
   rather than ending it: someone still has to act on the alert.
2. **A timer on the host that powers it off.** The host enforces the rule on
   itself. Nothing crosses the boundary, nothing is added to the estate's
   monitoring, and the fault ends whether or not anyone is paying attention.
3. **Both.** The timer ends the fault, and the collector watches the
   firewall while the box is on. Most coverage, and still all of option 1's
   cost.

## Decision

**`gandalf` powers itself off a fixed time after boot, or after the last
extension a session asks for.** Option 2. ADR-0017's "no monitoring" stands.
What changes is that "off between sessions" no longer depends on anyone.

- **The deadline is six hours after boot by default.** A session is an
  afternoon. The 2026-11-22 session, which ran a full upgrade, a reboot and an
  audit, fitted inside three hours.
- **A session can replace it.** A command on the host, `range-extend H`, sets
  the deadline H hours from now, whatever the default or an earlier extension
  had set. H is 1 to 12, so a typo or a "just leave it" cannot turn the timer
  off by the back door. The deadline lives under `/run`, which a reboot
  clears, so every boot starts again from the six-hour default.
- **It warns before it acts.** `wall` reaches every shell on the host 30
  minutes and 5 minutes before the deadline, which is enough to extend from
  the session already open.
- **It never powers off in the middle of a package install.** While `dpkg`'s
  lock is held, it waits and checks again on its next run.
- **The power-off is the ordinary one.** `systemctl poweroff` runs Proxmox's
  own guest shutdown, which stops every guest and forces any that ignore ACPI,
  as Mr-Robot does. Reverting the targets to `clean` stays §7's step at the
  start of the next session, which already reverts before any work.
- **A systemd timer runs the check every five minutes.** The script and its
  two units are in the repository, and §7 installs them. §7's read-back
  checks that the timer is enabled and active, so a disabled timer is caught
  at the next power-on, as a disabled firewall is.

Built under [#1647](https://github.com/Gerrrt/HomeLab/issues/1647).

## Consequences

- **A forgotten session ends by itself.** The bound is the deadline: six
  hours after boot, or up to twelve hours after the last `range-extend`. It
  is late by up to one five-minute timer period, and by as long as `dpkg`
  holds its lock past the deadline, which is unbounded if `dpkg` hangs. The
  attack VM's time on VLAN 30, and the time the host firewall goes
  unchecked, are bounded that way. Before this they were bounded by nothing.
- **Nothing still watches the host firewall while the box is on.** This
  decision bounds the window and leaves the check to §7. If a window without
  a firewall check stops being acceptable, option 1 is still open, and it
  would supersede ADR-0017's "no monitoring".
- **A long session has to extend.** Missing the warning costs the session,
  not the range. The guests stop and the targets revert at the next start.
  That is the price of a backstop that does not wait for someone to notice.
- **A disabled or broken timer puts the range back on discipline.** The
  read-back catches it only at the next power-on. That is the same exposure
  the firewall has today, and it is accepted for the same reason.
- **Powering on stays manual, as before.** The timer only turns the box off.
- **This decision is reopened** if the range starts needing to run unattended
  for longer than an extension allows. That would mean something on it is
  worth keeping on, and by ADR-0017's own rule it is then estate, on the
  wrong machine.
