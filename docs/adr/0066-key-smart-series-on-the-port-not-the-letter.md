# ADR-0066: Key SMART series on the port a drive is cabled to, not the letter it was given

**Status:** Accepted · 2026-09 · supersedes the `device` key of
[ADR-0046](0046-record-a-known-static-smart-count-as-a-baseline-not-a-silence.md)'s
decision; the rest of it stands

## Context

ADR-0046 keyed the SMART baseline on `host` and `device`, and accepted in its
consequences that *"a device letter can move"*, with the fix being *"one
edit"*. On `smaug` that happened more often than an edit can keep up with
([#745](https://github.com/Gerrrt/HomeLab/issues/745)). After the pool moved
to the chipset's AHCI ports on 2026-09-29
([ADR-0052](0052-cable-smaugs-pool-to-the-chipset-and-take-the-megaraid-out.md)),
the boot SSD read `sdc` after the disk swap and `sdb` after the memory
install, a boot that changed no disk. `SmartDriveBadSectors` paged on the
drive's recorded four sectors that day. It paged again on 2026-09-30, and
clearing it took a hand rewrite on `smaug` and a re-render on the monitoring
host. Each page was the loud failure ADR-0046 chose. It was not a finding.

The letter broke a second rule nobody had named.
`SmartDriveBadSectorsGrowing` subtracts each series from itself a week
earlier, matching on every label. Keyed on `host` and letter, a drive with 4
coming up on the letter an Exos with 0 held a week before reads as growth of
4. It has not fired only because no reboot has lined up that way yet.

The issue weighed three keys. Serials stay out: the collector never emits
one, by decision.

- **`host` + `model`.** The S3520's model is unique on `smaug`. The Exos pair
  share one, so two baselines on one model would collide.
- **The by-path name**, e.g. `pci-0000:00:17.0-ata-6`. It is the port, not
  the drive. It survives a reboot and changes only when a cable moves.
- **Keep `device` and relabel in the collector.** That is the same as the
  by-path option, but hides the key inside `device`, where every alert prints
  it.

## Decision

The collector puts a `slot` label on every per-device series. `slot` is the
drive's `/dev/disk/by-path` name. Where udev offers two spellings (systemd 253
added `ata-N.0` beside `ata-N`), the shortest wins, then the first in sort
order. Behind a Smart Array, `slot` is the logical drive's path plus
`:cciss,N`, the controller's index for the bay. Where there is no by-path name
at all (the SSH mode, or a host without udev), `slot` is the device label.
`device` stays as the human-readable name every alert prints.

The baseline table in `scripts/render-smart-baselines.sh` is keyed on `host`
and `slot`. `SmartDriveBadSectors` joins `on(host, slot)`.

**A series with no `slot` uses its `device`.** A collector installed before
this change emits no `slot`, and `oracle`'s is a copy installed once. The
rule selects those series with `{slot=""}`, and `label_replace` gives them
their device as the slot. Their baseline rows name the device, as `oracle`'s
does. So the rule is right on every host whatever order the collectors are
updated in. The cost is that the coalescing expression is written twice in
the rule.

## Consequences

- **A reboot that reorders the letters does not page.** `host.test.yaml`
  proves it with the S3520 moving from `sdc` to `sdb` against one row, and
  proves that a row still naming a letter falls back to `> 0` and pages. The
  failure mode ADR-0046 chose is kept.
- **Moving a cable pages, and that is correct.** A drive on a new port is a
  hardware change, and the row is updated in the commit that records the
  change.
- **`SmartDriveBadSectorsGrowing` stops reading a moved letter as growth.**
  A moved letter is a new series with no week-old point, so for seven days
  that drive says nothing rather than something wrong. The same applies to
  the other rules that subtract across a day or a week.
- **`SmartDriveUnsafeShutdownsGrowing` will fire on `smaug`'s planned
  reboots.** The S3520 counts a clean shutdown as unsafe
  ([`hardware.md`](../hardware.md)). The rule stayed quiet on 2026-09-29 only
  because the letter moved between the two readings. The rule was already
  wrong for this drive, and the letter was hiding it. That belongs to
  [#574](https://github.com/Gerrrt/HomeLab/issues/574), not to this record.
  *(2026-10-01: answered under
  [#746](https://github.com/Gerrrt/HomeLab/issues/746). `smaug` counts its own
  clean stops from a SHUTDOWN init script, and the rule subtracts them, so a
  planned reboot nets to zero.)* *(2026-10-03: and then withdrawn. A clean
  stop does not tick the S3520; the 2026-09-29 tick was the unplug for the
  memory install. The rule is "any tick pages" again, and the clean count
  only explains a page.)*
- **Every per-device SMART series gains a label.** That starts a new series in
  Prometheus. Nothing in Grafana reads `homelab_smart_*`, and every rule
  keys on `host`, `device` or now `slot`, so nothing downstream breaks.
- **`oracle`'s row changes when its collector does.** When
  `install-agent-collectors.sh` next installs a copy there, `--print` shows
  its slot, and the row changes to it in the same commit. Otherwise `oracle`
  pages on its recorded 32, loudly, as above.
- **[#744](https://github.com/Gerrrt/HomeLab/issues/744)'s vdev textfile has
  the same letter problem**, and this is the key to reuse there.
