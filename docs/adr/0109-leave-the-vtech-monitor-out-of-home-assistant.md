# ADR-0109: Leave the VTech monitor out of Home Assistant

**Status:** Accepted · 2026-11 · supersedes
[ADR-0102](0102-bridge-the-vtech-monitor-into-home-assistant-from-a-pi-on-skids.md)

## Context

[ADR-0102](0102-bridge-the-vtech-monitor-into-home-assistant-from-a-pi-on-skids.md)
decided to bring the VTech RM7764HD baby monitor into Home Assistant through
[JonGilmore/vtech-baby-pro-bridge](https://github.com/JonGilmore/vtech-baby-pro-bridge),
run on a Raspberry Pi, `heimdall`, on Skids. Its gate was a used phone: bought
for the purpose, rooted, used for one afternoon to capture the camera's TUTK
license key, UID and channel password by kernel uprobe, and wiped. The Pi was
not to be ordered until that capture worked.
[#1248](https://github.com/Gerrrt/HomeLab/issues/1248) carried the work.
Nothing was bought.

On 2026-11-10 the operator ruled out the gate itself. No device is bought
solely to make this work. A phone bought for one afternoon is exactly that,
so the purchase ADR-0102 rests on will not be made.

The question was whether the bridge can be reached any other way. It cannot,
on what is known today:

- **The rooted phone is not optional in either project.** Both the original
  and [rinosaur681's variant](https://github.com/rinosaur681/vtech-baby-pro-bridge)
  need it twice: for the uprobe capture, since DexGuard defeats Frida and
  Xposed, and for the bionic root filesystem the bridge's chroot is built
  from. Neither project documents another path.
- **Android in a container on an arm64 host** (redroid), probed by the
  host's kernel, would in principle do both jobs on the Pi itself. Neither
  project has tried it. The app's DexGuard may refuse to run there, and the
  Pi would still be a purchase made only for this camera. `trinity` is x86 and
  cannot run the ARM libraries natively, so it cannot stand in.
- **No household phone may be rooted.** ADR-0102 point 5 said so, and this
  ADR does not change it.

## Decision

**The VTech monitor stays out of Home Assistant. Nothing joins Skids for
it, no rows open into Skids for it, and nothing is bought for it.**

1. **ADR-0102 is superseded in full.** `heimdall`, its reservation at
   `10.0.20.30`, its three rows from Winterfell, its four secrets and both
   purchases are withdrawn. None of them was ever created.
2. **The monitor is used as it is today**, through its parent unit and the
   *MyVTech Baby Pro* app. `monitor-01` and `monitor-02` stay in
   `network.md` as Skids appliances.
   [ADR-0035](0035-scope-the-99-to-20-rule-to-the-hue-bridge.md)'s table
   already says the monitors are not integrated, and that stays true.
3. **Skids keeps no general-purpose computer.** Every device on it remains
   an appliance running its vendor's firmware.
4. **#1248 closes with this finding.**

## Alternatives considered

- **Buy the phone after all.** That is ADR-0102 itself, and the operator has
  ruled it out.
- **Buy the Pi and try redroid on it.** This removes the phone, but the Pi
  is still bought only for this, and the extraction is unproven on a
  platform DexGuard may detect. If it fails, the Pi was bought for nothing.
  Declined.
- **[Kasoo/vtech_baby](https://github.com/Kasoo/vtech_baby).** It needs no
  root, but it is tested only on the RM5754HD's older app generation. It
  would also put Home Assistant on Skids, which ADR-0102 already declined.
  Declined again, for the same reasons.
- **Replace the monitor with an RTSP camera.** This is still a hardware and
  privacy decision in its own right, and it reopens
  [ADR-0032](0032-decline-frigate-while-the-cameras-are-ring.md). Nobody has
  asked for it. Declined.

## Consequences

- **Home Assistant cannot see the VTech monitor.** This one camera is an
  exception to the household's rule that Home Assistant is where everything
  is seen. It is accepted rather than worked around.
- **ADR-0102's risks never arrive.** There is no unreviewed native bridge
  holding the camera's credentials, no RTSP in the clear across Skids, and
  no Debian host on the segment to patch.
- **Two purchases leave *Everything still to buy*.** `network.md` and
  `security.md` drop the reservation and the three planned rows.
- **Reopened by:** VTech or Home Assistant shipping a supported local path;
  a community integration that works on this app generation without root; a
  phone the household already owns, has retired and may root, which removes
  the one-off purchase; or the household replacing the monitor, which
  reopens ADR-0032's question instead.
