# ADR-0068: Mirror the lab bridge to Zeek with tc, not Open vSwitch

**Status:** Accepted · 2026-09

> [!NOTE]
> The TLS metadata this ADR names (SNI, certificate subjects and issuers, and
> whether a chain validates) gained fingerprints on 2026-10-04. `fenrir`'s
> `ssl.log` has carried a JA4 and JA4S per handshake since then, and `conn.log`,
> `http.log`, `ja4ssh.log` and `ja4d.log` carry the rest of JA4+
> ([#776](https://github.com/Gerrrt/HomeLab/issues/776)). They come from
> FoxIO's scripts, vendored into the stack rather than built into an image, as
> [ADR-0069](0069-vendor-the-ja4-scripts-into-the-sensor-stack-rather-than-build-an-image.md)
> decides. [`stacks/sensor/README.md`](../../stacks/sensor/README.md) has the
> query that reads them. The text below is left as written, per ADR-0001.

## Context

Suricata runs on `morpheus` ([ADR-0006](0006-detect-at-the-chokepoint.md))
because the firewall is the one device that sees IoT and guest. That is also why
it cannot see what ADR-0029's domain was built to exercise. LLMNR and NBT-NS
poisoning, NTLM relay, Kerberoasting and ARP spoofing are all layer 2 or
intra-segment, and none of them crosses the router.
[ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
made the same argument to put `ifrit` beside its targets.
[#437](https://github.com/Gerrrt/HomeLab/issues/437) applies it to detection. It
asks for Zeek on a mirror of `Saruman`'s lab bridge, the bridge the six domain
guests share, so that their east-west traffic is observed at all.

Zeek is a protocol logger, not a second Suricata. Its value here is that it
reads TLS metadata without decrypting: SNI, certificate subjects and issuers,
and whether a chain validates. That is the ground `docs/security.md`'s
"plaintext only" limit gives up.

The issue was filed saying the mirror needs Open vSwitch, and that converting
`vmbr0` is "the awkward part". Converting is awkward. The premise is wrong.

What `Saruman` has, read on the host on 2026-09-30:

- `vmbr0` is a plain Linux bridge on `eno1`, carrying the hypervisor's own
  `10.0.30.110`.
- Nine guest taps are on it, all `firewall=0`, none rate-limited.
- `tc` from iproute2 6.15 is installed. Open vSwitch is not.

A Linux bridge port is an ordinary netdev, and so is every tap. A `clsact` qdisc
with a `matchall` filter and a `mirred egress mirror` action copies whatever
enters a netdev to another netdev. That is port mirroring, and the kernel has
had it since before Open vSwitch was packaged.

## Decision

**Mirror with `tc` on the existing Linux bridge. `vmbr0` is not converted.**

- **What is mirrored.**
  - The **ingress** of every `vmbr0` port except the sensor's own. Every frame
    enters the bridge through exactly one port, whether a guest tap or `eno1`,
    so each frame is copied once.
  - The **egress** of the `vmbr0` device itself: what the hypervisor
    originates, which enters through no port.

  Each filter sits at `pref 437`, so it can be found and replaced without
  touching anything else on the port.
- **Where the copies go.** The sensor is a guest of its own, `fenrir` (VMID 190,
  `10.0.30.90`, 4 vCPU / 8 GB and a data disk).
  - `net0` is on `vmbr0` like every other guest. It carries the sensor's own
    traffic.
  - `net1` is alone on a new bridge, `vmbr1`. It has no ports, no address and no
    VLAN awareness: the same shape ADR-0014 already accepts on `ifrit`. The
    mirror's copies are the only thing it receives, and it can reach nothing.
- **What keeps it there.** `scripts/zeek-mirror.sh`, run every minute by
  `homelab-zeek-mirror.timer` on the hypervisor.
  - It checks each port for a mirror to `tap190i1` **by name** and replaces
    anything else. It leaves a port that is already right untouched.
  - When the sensor is down it removes the filters.
  - The minute is not about reboots. A guest restart recreates its tap without
    the filter. A sensor restart recreates `tap190i1` with a new ifindex, and
    every filter keeps the old one. `tc` shows those filters as
    `Egress Mirror to device *` and they mirror nothing, with no error
    anywhere. That was reproduced in a network namespace while this was
    written.
- **What says it is there.** A separate, read-only collector,
  `scripts/collect-zeek-mirror-state.sh`, publishes `homelab_zeek_mirror_active`
  in the exporter-less pattern the other agent collectors use.
  - It reads 1 only when all four of these hold:
    - VM 190 is running;
    - its capture tap is up;
    - every expected port mirrors to that tap by name;
    - the tap's packet counter moved since the last run.
  - `ZeekMirrorInactive` fires on 0 after ten minutes, and `ZeekMirrorStateStale`
    fires when the file stops being rewritten. Both are in the estate's
    `host.rules.yaml` with promtool tests.
  - The unit that builds the mirror never reports on it. That separation is
    what makes #437's reboot proof mean something: disable the ensurer, reboot,
    and the gauge must fall to zero on its own.
- **Where Zeek's logs go.** They go to the lab's Loki on `alexander`, through
  the sensor's own Alloy (`stacks/sensor`), and never to `10.0.99.20`
  ([ADR-0007](0007-defensive-estate-and-offensive-range.md)). The gauge crosses
  under [ADR-0028](0028-let-guest-liveness-cross-but-not-guest-telemetry.md) as
  hypervisor state: guest run state, host interfaces and host qdiscs. It rides
  the hypervisor agent's existing pass (ADR-0007's #88 note). Nothing Zeek
  produced crosses.

### Rejected

- **Convert `vmbr0` to Open vSwitch**, as #437 was filed. The host IP would
  move onto an OVSIntPort, which is a cutover of the management plane that
  ADR-0014's host firewall guards. It would be done from a console, because
  nothing on the segment could reach the host mid-change. It would also put a
  bridge that speaks 802.1Q natively under the one segment built to hold an
  attacker, where ADR-0007 and ADR-0014 name "a VLAN-aware bridge" as a thing
  that reopens them. And it would add a package and a daemon to the
  hypervisor. What it buys over `tc` is a mirror that persists in OVSDB. But
  its output port is a tap that is destroyed on every sensor restart, so it
  would need re-asserting on a timer all the same.
- **A SPAN from `neo` or the CRS326.** ADR-0006 keeps switch mirroring disabled,
  and [ADR-0041](0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md)
  repeats that for the new switch. It would also see only what crosses the
  uplink. Guest-to-guest traffic on `vmbr0` never leaves the host.
- **Hub mode**, with `ageing 0` on `vmbr0`. It floods every frame to every port,
  including every domain guest. That is a gift to the attack VM, and it is
  still no mirror.
- **Zeek on `odin`.** `odin`'s 16 GB are sized for Wazuh's stated minimums
  ([ADR-0030](0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)),
  and a capture NIC shared with the SIEM's own traffic is a sensor that watches
  its own work.

## Consequences

- **A minute of blindness after any guest restarts**, and after the sensor does.
  `ZeekMirrorInactive` waits ten minutes so that one reading inside that minute
  does not page.
- **The gauge proves the mirror, not Zeek.** A running `fenrir` whose Zeek has
  crashed has a working mirror and reads 1. ADR-0028 is why: whether a process
  inside a guest is healthy is guest telemetry, and it stays in the lab. There
  it shows as the `job="zeek"` streams going flat in the lab's Grafana, and the
  lab has no Alertmanager to page on that
  ([ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)).
  This is the same limit `homelab_guest_running` states for `alexander`.
- **The hypervisor's own management traffic is mirrored too**, because it
  enters on `eno1`. Zeek therefore logs connection metadata for SSH and `8006`
  sessions from Hicks. That stays on the lab segment and in the lab's Loki, and
  none of it is decrypted.
- **`vmbr1` carries no tags and bridges nothing.** It is not a second segment,
  and does not reopen ADR-0014. A change that gave it a port or an address
  would.
- **Segmentation offload reaches Zeek as oversized frames.** The mirror copies
  what a guest's kernel handed its NIC, so `stacks/sensor` raises Zeek's snaplen
  to 65535.
- **`tc` state is invisible to Proxmox.** It does not appear in the GUI or in
  `/etc/network/interfaces`. The timer, the collector and
  [`build-the-sensor-guest.md`](../runbooks/build-the-sensor-guest.md) are its
  documentation.
- **Reopened by:**
  - a guest that needs a Proxmox rate limit (`rate=` puts an `ingress` qdisc on
    its tap, which `clsact` cannot coexist with);
  - a second NIC on `Saruman`, or domain guests moved off `vmbr0` (ADR-0039);
  - a need for Zeek's own health to page, which is a lab Alertmanager decision
    and not this one;
  - `vmbr0` becoming VLAN-aware for any other reason, after which Open vSwitch
    costs nothing extra.
