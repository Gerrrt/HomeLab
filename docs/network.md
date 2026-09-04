# Network

Seven VLANs behind a pfSense firewall, default-deny between segments. Each
section below lists the devices on a segment, how it is wired, and what it is
allowed to reach.

The **Rack** column is the physical patch-cable colour, and this table is the
authority for it. Colour runs down the visible spectrum as the VLAN id descends,
so the colour tells you where a segment sits in this list. It does **not** encode
trust — [ADR-0002](adr/0002-vlan-segmentation-strategy.md) ranks ImaginationLAN
above CasaBonita, which the spectrum does not. Reasoning in
[ADR-0009](adr/0009-colour-vlans-by-cable-not-by-trust.md).

> **On the data in this file.** MAC addresses are truncated to their OUI (the
> vendor half); personal devices are listed by role rather than by owner. This
> is a public repository, and a full device fingerprint of a house is an
> inventory for someone else. The rationale is in
> [`security.md`](security.md#what-this-repository-deliberately-does-not-publish).

| Segment | VLAN | Rack | Subnet | Purpose | Reaches |
| --- | --- | --- | --- | --- | --- |
| WAN | — | — | ISP-assigned | Uplink | — |
| LAN | — | — | `10.7.7.0/24` | Switch management only | Everything[^lan] |
| [Winterfell](#winterfell--vlan-99--management) | 99 | 🔴 Red | `10.0.99.0/24` | Infrastructure management | Internet |
| [Hicks](#hicks--vlan-50--trusted) | 50 | 🟠 Orange | `10.0.50.0/24` | Trusted workstations | Internet, 30, named ports on 99[^hicks] |
| [CasaBonita](#casabonita--vlan-40--media) | 40 | 🟡 Yellow | `10.0.40.0/24` | TVs and consoles | Internet |
| [ImaginationLAN](#imaginationlan--vlan-30--lab) | 30 | 🟢 Green | `10.0.30.0/24` | Hypervisor / lab | Internet |
| [Skids](#skids--vlan-20--iot) | 20 | 🔵 Blue | `10.0.20.0/24` | IoT and cameras | Internet |
| [Degens](#degens--vlan-10--guest) | 10 | 🟣 Purple | `10.0.10.0/24` | Guest Wi-Fi | Internet |

[^lan]: Not by design. That interface carries pfSense's stock *Default allow LAN
    to any* rule and no blocks, so `10.7.7.0/24` reaches every segment. It held
    one device and said "Nothing" here until
    [ADR-0013](adr/0013-segment-access-as-implemented.md) read the ruleset.

[^hicks]: Hicks is the only segment with a path into management, and since
    2026-09-02 that path is a list of destinations rather than the segment: ten
    passes sit above a logged *Block access to Winterfell* and everything else
    from 50 to 99 is dropped. They are enumerated in the Hicks notes below.
    ImaginationLAN is not blocked, so the catch-all under those rules still
    grants that segment entire —
    [#228](https://github.com/Gerrrt/HomeLab/issues/228) owns that half.
    [ADR-0013](adr/0013-segment-access-as-implemented.md) read the ruleset on
    2026-09-01, the day before the narrowing landed, and describes the wider
    state; it is left as written, per
    [ADR-0001](adr/0001-record-architecture-decisions.md).

Hostnames are thematic rather than functional — `morpheus` is the firewall,
`mjolnir` the UPS, `Saruman` the hypervisor. The Role column is the source of
truth for what a box actually does.

---

## WAN

| Hostname | IP | MAC (OUI) | Device | OS | Location | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | *(ISP-assigned)* | `80:e8:2c:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 15.0 | Rack U5 | pfSense |

### Notes

- Cat6 from the ISP gateway[^modem] to the WAN interface of the ProDesk[^ProDesk].
- The gateway runs in bridge mode; its own Wi-Fi radio stays operational but is
  unused. All wireless is handled by eero units on tagged VLANs.

[^modem]: [Xfinity Gateway (XB7)](https://www.xfinity.com/support/articles/broadband-gateways-userguides)
[^ProDesk]: [HP ProDesk 600 G4 Mini](https://www.microcenter.com/product/692358/)

---

## LAN

| Hostname | IP | MAC (OUI) | Device | OS | Location | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | `10.7.7.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 15.0 | Rack U5 | Firewall |
| neo | `10.7.7.2` | `1c:2a:a3:xx:xx:xx` | MokerLink 26-port managed | — | Rack U9 | Switch |

### Notes

- Cat6 from the ProDesk's add-on NIC[^adapter] to port 1 of the switch (trunk).
- This interface exists solely to reach the switch's[^MokerLink] management UI,
  which will not bind to a tagged interface.
- **`neo.matrix.elysium` resolves to `10.7.7.2`**, so the switch is reached by
  name like everything else — [ADR-0018](adr/0018-name-the-switch-and-leave-its-ui-on-plain-http.md).
  The address stays written down beside it on purpose: the name depends on
  Unbound on `morpheus`, and this is the device you open when `morpheus` is the
  suspect.
- **The UI is plain HTTP and cannot be anything else.** No TLS listener, no
  certificate import — checked against the live switch on 2026-09-04, and the
  third firmware limit on this device after #84 and #85. Admin credentials cross
  the wire in clear, over a path that runs through `neo` itself. ADR-0018 has the
  reasoning and the rejected alternatives.
- DHCP disabled.

> [!CAUTION]
> Do not re-enable DHCP on this interface. It races the DHCP servers on every
> tagged interface and takes the whole house offline.

[^adapter]: [USB NIC adapter](https://a.co/d/dJ4BD2N)
[^MokerLink]: [MokerLink 26-port managed switch](https://a.co/d/gaJvCKV)

---

## Winterfell — VLAN 99 — Management

🔴 **Red** on the rack.

Infrastructure. The only segment that can administer other segments, and the
only one Hicks is permitted to reach for management — on the named ports
listed under [Hicks](#hicks--vlan-50--trusted), and nothing else.

| Hostname | IP | MAC (OUI) | Device | OS | Location | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | `10.0.99.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 15.0 | Rack U5 | Firewall |
| mjolnir | `10.0.99.10` | `28:29:86:xx:xx:xx` | APC Smart-UPS[^UPS] | — | Rack U1–U2 | UPS |
| prometheus | `10.0.99.20` | `00:05:1b:xx:xx:xx` | Apple MacBook Pro (2012)[^MacBookPro] | Ubuntu 24.04 LTS | Shelf | **Observability stack** |
| oracle | `10.0.99.30` | `58:8a:5a:xx:xx:xx` | Dell Inspiron 15-3565[^Dell] | Ubuntu 24.04 LTS | Shelf | **Wiki**, and the off-host jobs |

### Notes

- `prometheus` runs the whole monitoring stack from
  [`stacks/observability`](../stacks/observability) — a 2012 MacBook Pro with
  Ubuntu Server on it, which is exactly the sort of hardware a homelab should be
  built from.
- Port 3 of the main switch feeds an 8-port unmanaged switch[^tp-linkswitch]
  that `prometheus` and `oracle` hang off.
- pfSense's admin UI is reachable on this interface from Hicks only, by a
  named pass to `10.0.99.1:443`. Winterfell itself is blocked from it: the 99
  interface drops HTTP and HTTPS to `10.0.99.1` above its egress rule.
- DHCP enabled, with static reservations for everything listed.
- `oracle` runs the Lemmiwinks wiki and its Postgres — it has since 2025-11-12,
  and [ADR-0011](adr/0011-keep-the-wiki-internal.md) depends on it — and holds
  the off-host copy of the firewall export that `make backup-firewall` pushes
  to it, as ciphertext with no key. Its role is the estate's small off-host
  jobs: [ADR-0015](adr/0015-give-oracle-the-off-host-jobs.md). Its NIC
  supports 10/100 only, so that link runs at 100 Mb/s — measured 2026-09-03 —
  and no cable will lift it. `prometheus` links at a gigabit through the same
  switch.

[^UPS]: [APC Smart-UPS](https://www.apc.com/us/en/product-range/61913-smart-ups/)
[^tp-linkswitch]: [TP-Link 8-port gigabit switch](https://www.tp-link.com/us/business-networking/unmanaged-switch/)
[^MacBookPro]: [Apple MacBook Pro (2012)](https://support.apple.com/en-us/111958)
[^Dell]: [Dell Inspiron 15](https://www.dell.com/support/home/en-us/product-support/product/inspiron-15-3520-laptop)

---

## Hicks — VLAN 50 — Trusted

🟠 **Orange** on the rack.

Personal and work machines. The only segment with a path into management.

| Hostname | IP | MAC (OUI) | Device | OS | Zone | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | `10.0.50.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 15.0 | Rack U5 | Firewall |
| desktop-01 | `10.0.50.20` | `04:42:1a:xx:xx:xx` | ASUS ROG Strix X570-E[^Desktop1] | Windows 11 | Upper floor | Desktop |
| desktop-02 | `10.0.50.90` | `04:42:1a:xx:xx:xx` | ASUS ROG Crosshair VIII[^Desktop2] | Windows 11 | Lower floor | Desktop |
| laptop-01 | `10.0.50.10` | `04:ed:33:xx:xx:xx` | HP Pavilion Gaming[^Pavillion] | Windows 11 | Roaming | Laptop |
| laptop-02 | `10.0.50.80` | `4c:ea:41:xx:xx:xx` | Apple MacBook Pro[^MacBook] | macOS 26 | Roaming | Laptop |
| workstation-01 | `10.0.50.69` | `e8:f6:73:xx:xx:xx` | Microsoft Surface Laptop 6[^Surface] | Windows 11 | Roaming | Corporate |
| workstation-02 | `10.0.50.70` | `4c:ea:41:xx:xx:xx` | Microsoft Surface Laptop 6[^Surface] | Windows 11 | Roaming | Corporate |
| mobile-01 | `10.0.50.105` | `fe:ee:aa:xx:xx:xx` | Apple iPhone[^iPhone16] | iOS 26 | Roaming | Phone |
| mobile-02 | `10.0.50.109` | `fa:cc:aa:xx:xx:xx` | Google Pixel[^Pixel] | Android 13 | Roaming | Phone |
| wearable-01 | `10.0.50.112` | `f6:b8:72:xx:xx:xx` | Apple Watch[^Watch10] | watchOS 26 | Roaming | Watch |
| eero-trusted-1 | `10.0.50.104` | `9c:57:bc:xx:xx:xx` | eero Pro 6E[^eero] | eeroOS | Main floor | Wi-Fi |
| eero-trusted-2 | `10.0.50.110` | `9c:57:bc:xx:xx:xx` | eero Pro 6E[^eero] | eeroOS | Main floor | Wi-Fi |
| eero-trusted-3 | `10.0.50.111` | `fc:3f:a6:xx:xx:xx` | eero Pro 6E[^eero] | eeroOS | Lower floor | Wi-Fi |

### Notes

- Desktops are wired Cat6; one eero is wired as backhaul, the other two mesh.
- **What this segment reaches on Winterfell is a list of destinations, not the
  segment.** Ten passes sit above a logged *Block access to Winterfell*, and
  everything else from 50 to 99 is dropped:

  | Destination | Ports |
  | --- | --- |
  | `10.0.99.0/24` — the segment | `22/tcp`, ICMP echo |
  | `10.0.99.1` — `morpheus` | `443/tcp` admin UI, `53/tcp+udp` resolver, `123/udp` NTP |
  | `10.0.99.10` — `mjolnir` | `80,443/tcp` UPS card |
  | `10.0.99.20` — `prometheus` | `3000/tcp` Grafana |
  | `10.0.99.30` — `oracle` | `80,443/tcp` the wiki |

  **The source is the segment, not named hosts.** Every one of those passes is
  `vlan50 → …`, so any device on Hicks may use any of them. This note used to
  say the opposite — "only specific hosts, and only on management ports" — and
  had the narrowing backwards in both halves: it is by destination and port, and
  never by host.
- **Corporate laptops are subject to exactly the same rules as everything else
  here.** They are intended to be treated as untrusted endpoints that happen to
  sit on a trusted segment, and nothing on the firewall enforces that: no alias
  holds `10.0.50.69` or `10.0.50.70`, and no rule names them. It is a policy
  about how they are used, and it is written here as one rather than as a
  control.
- **Prometheus' and Loki's ingest ports are not on the list above.** `9090` and
  `3100` are published without authentication
  ([#182](https://github.com/Gerrrt/HomeLab/issues/182)) and were reachable from
  this segment for as long as the catch-all was the only rule between them;
  *Block access to Winterfell* now drops them. Narrower, not gone:
  `10.0.30.110` still has an explicit pass to both ports for `Saruman`'s Alloy
  agent, and nothing stops a host already on Winterfell.
- **ImaginationLAN is still reached entire**, on every protocol and port,
  because no rule blocks it and the catch-all below is reached.
  [#228](https://github.com/Gerrrt/HomeLab/issues/228) is where that gets
  decided. *Allow Hicks access to ImaginationLAN* now sits on **this** interface
  — ADR-0013 found it on the ImaginationLAN interface, where a rule can never
  match traffic that enters on Hicks — and grants nothing the catch-all was not
  already granting.
- The switch LAN is blocked apart from `10.7.7.2:80`, the switch's own web UI;
  the block below that pass is logged.

[^Desktop1]: [Build 1](https://pcpartpicker.com/b/KXv323)
[^Desktop2]: [Build 2](https://pcpartpicker.com/list/XgZpfd)
[^Surface]: [Microsoft Surface Laptop 6 for Business](https://www.microsoft.com/en-us/surface/business/surface-laptop-6-for-business)
[^MacBook]: [Apple MacBook Pro](https://www.apple.com/macbook-pro/)
[^iPhone16]: [Apple iPhone](https://www.apple.com/iphone/)
[^Watch10]: [Apple Watch Series 10](https://www.apple.com/apple-watch-series-10/)
[^Pavillion]: [HP Pavilion Gaming](https://www.hp.com/us-en/shop/cat/laptops/gaming-laptops)
[^Pixel]: [Google Pixel](https://store.google.com/category/phones)
[^eero]: [eero Pro 6E](https://eero.com/shop/eero-pro-6e)

---

## CasaBonita — VLAN 40 — Media

🟡 **Yellow** on the rack.

Televisions and consoles. Internet only.

| Hostname | IP | MAC (OUI) | Device | OS | Zone | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | `10.0.40.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 15.0 | Rack U5 | Firewall |
| nibelheim | `10.0.40.10` | `78:c8:81:xx:xx:xx` | Sony PlayStation 5[^PS5] | — | Lower floor | Console |
| hyrule | `10.0.40.20` | `00:05:1b:xx:xx:xx` | Nintendo Switch[^Nintendo] | — | Lower floor | Console |
| mediatv | `10.0.40.100` | `58:fd:b1:xx:xx:xx` | LG OLED[^OLEDTV] | webOS | Media room | TV |
| streambox | `10.0.40.101` | `f0:46:3b:xx:xx:xx` | Xumo Stream Box[^StreamBox] | entOS | Media room | Streaming |

### Notes

- All wired with Cat6.
- Internet only, no path to any other segment. Smart TVs run unauditable
  firmware with a permanent internet connection and no patch guarantee, so they
  get the same trust level as a guest.
- The planned NAS lands here — `zion` at `10.0.40.30`, decided by
  [ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
  and not yet bought. It does not change the *Reaches* column: nothing on this
  segment will initiate anywhere, and the three rules that ADR writes down all
  let a more trusted segment reach **in**. That is the direction this row
  records, and it is the one that is unchanged.

[^OLEDTV]: [LG OLED TV](https://www.lg.com/us/tvs/oled)
[^PS5]: [PlayStation 5](https://www.playstation.com/en-us/ps5/)
[^Nintendo]: [Nintendo Switch](https://www.nintendo.com/us/switch/)
[^StreamBox]: [Xumo Stream Box](https://www.xfinity.com/learn/xumostreambox)

---

## ImaginationLAN — VLAN 30 — Lab

🟢 **Green** on the rack.

Where things get broken on purpose.

| Hostname | IP | MAC (OUI) | Device | OS | Location | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | `10.0.30.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 15.0 | Rack U5 | Firewall |
| shiva | `10.0.30.10` | `94:57:a5:xx:xx:xx` | HPE iLO 4 (DL360 Gen9 BMC)[^Shiva] | iLO 2.82 | Rack U3 | Out-of-band management |
| Saruman | `10.0.30.110` | `14:02:ec:xx:xx:xx` | HPE ProLiant DL360 Gen9[^Shiva] | Proxmox VE 9 | Rack U3 | Hypervisor |

### Notes

- Reachable from Hicks only; outbound internet permitted.
- `shiva` and `Saruman` are the same physical box: `shiva` is the iLO BMC on its
  dedicated port, `Saruman` is the Proxmox install. They are separate addresses
  and separate names, and conflating them is a mistake this document previously
  made.
- `Saruman` currently runs no guests.
- `Saruman` runs an Alloy agent and is the one host on this segment with a path
  into Winterfell: a single pass, `10.0.30.110 → 10.0.99.20` on 9090 and 3100
  TCP, unlogged and above the ADR-0014 tripwire. The hypervisor's own telemetry
  only; guests get no such rule (ADR-0007, as amended by #88).
- **`Saruman` is the one fixed address that sits inside a DHCP pool.** Every
  other static in the estate lives below `.100`; this one is at `.110`, and the
  ImaginationLAN pool runs `.100–.200`. Until 2026-08-30 there was no
  reservation for it either, so Kea could have leased the same address to
  another device. There is one now, and it holds *because* the server is Kea:
  `reservations-in-subnet` is true and `reservations-out-of-pool` is unset, so
  reservations are consulted on every allocation. Under ISC dhcpd, whose
  binaries are still on the box, the same reservation would not reliably
  protect an in-pool address. Moving `Saruman` below `.100` is the fix that
  does not depend on that.
- A second server (`ifrit`) will carry the attack tooling and the
  deliberately-vulnerable targets. It joins this segment single-homed, on an
  untagged access port, at `10.0.30.30` — a static below `.100`, with a
  reservation; the targets live on a bridge inside it with no physical port, on
  a subnet `morpheus` does not route, so they have no path anywhere. Egress
  from this segment stays open by decision, not omission —
  [ADR-0014](adr/0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md).
  That bridge is `172.30.30.0/24` and nothing on it has a default route, per
  [ADR-0017](adr/0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md); it
  is the third private block in the house and the only one that is not routed
  anywhere, which is what makes a `172.30.30.x` source in a firewall block a
  leak reporting itself. The attack VM takes a lease from the pool like any
  other guest. The build is
  [`build-the-playground.md`](runbooks/build-the-playground.md), and `Saruman`
  moves to `10.0.30.20` as part of it.

> [!NOTE]
> `10.0.30.10` is the iLO BMC, not the hypervisor, and it is what
> `stacks/observability/prometheus/targets/snmp.yaml` polls — the `hypervisor-bmc`
> role label there is accurate. The BMC takes its address by DHCP, so it is held
> by a reservation on pfSense; without one, a new lease would silently break the
> SNMP target, which hard-codes the address.

[^Shiva]: [HPE ProLiant DL360 Gen9](https://buy.hpe.com/us/en/servers/rack-servers/proliant-dl300-servers/proliant-dl360-server/p/1010026922)

---

## Skids — VLAN 20 — IoT

🔵 **Blue** on the rack.

Everything with a cloud dependency and no patch story. The largest segment and
the least trusted.

| Hostname | IP | MAC (OUI) | Device | OS | Zone | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | `10.0.20.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 15.0 | Rack U5 | Firewall |
| eero-iot-1 | `10.0.20.101` | `fc:3f:a6:xx:xx:xx` | eero Pro 6E | eeroOS | Upper floor | Wi-Fi mesh |
| eero-iot-2 | `10.0.20.102` | `fc:3f:a6:xx:xx:xx` | eero Pro 6E | eeroOS | Main floor | Wi-Fi mesh |
| eero-iot-3 | `10.0.20.103` | `9c:57:bc:xx:xx:xx` | eero Pro 6E | eeroOS | Lower floor | Wi-Fi mesh |
| bifrost | `10.0.20.104` | `ec:b5:fa:xx:xx:xx` | Philips Hue Bridge[^Huebridge] | — | Main floor | Lighting |
| speaker-01…04 | `.113`, `.124`, `.128`, `.132` | `d4:90:9c:xx:xx:xx`, `94:ea:32:xx:xx:xx`, `f4:34:f0:xx:xx:xx` | Apple HomePod[^homepod] | audioOS | Various | Assistant |
| assistant-01…05 | `.105`, `.109`, `.114`, `.133`, `.144` | `74:d4:23:xx:xx:xx`, `58:a8:e8:xx:xx:xx`, `1c:fe:2b:xx:xx:xx`, `4c:ef:c0:xx:xx:xx`, `68:b6:91:xx:xx:xx` | Amazon Echo[^echo] | FireOS | Various | Assistant |
| camera-01…07 | `.112`, `.118`, `.119`, `.126`, `.130`, `.145`, `.146` | `10:08:2c:xx:xx:xx`, `b4:bc:7c:xx:xx:xx`, `3c:e1:a1:xx:xx:xx`, `54:e0:19:xx:xx:xx`, `18:7f:88:xx:xx:xx` | Ring cameras, floodlights, doorbell[^floodlight] [^doorbell] [^camera] | — | Interior & exterior | Camera |
| alarm-hub | `10.0.20.121` | `2c:6b:7d:xx:xx:xx` | Ring Alarm Base Station[^basestation] | — | Main floor | Hub |
| monitor-01 | `10.0.20.117` | `a4:97:5c:xx:xx:xx` | VTech camera[^Monitor] | — | Upper floor | Baby monitor |
| monitor-02 | `10.0.20.149` | `a4:97:5c:xx:xx:xx` | VTech tablet[^Monitor] | — | Upper floor | Baby monitor |
| appliance-01 | `10.0.20.108` | `c0:49:ef:xx:xx:xx` | Litter-Robot 4[^litterrobot] | — | Utility | Appliance |
| appliance-02 | `10.0.20.115` | `50:8b:b9:xx:xx:xx` | Tuya white-noise machine[^Whitenoise] | — | Upper floor | Appliance |

### Notes

- All wireless. One eero is wired as backhaul.
- Internet only. No device here can initiate a connection to any other segment,
  which is the entire reason this VLAN exists. A camera or a $20 Tuya device
  with a hardcoded credential is a foothold, not a light switch.
- Device addresses and rooms are collapsed above deliberately. The exact
  camera-to-room mapping is not something a public repository needs to carry.

[^Huebridge]: [Philips Hue Bridge](https://www.philips-hue.com/en-us/p/hue-bridge/046677458478)
[^echo]: [Amazon Echo](https://www.amazon.com/dp/B07XKF5RM3)
[^litterrobot]: [Litter-Robot 4](https://www.litter-robot.com/litter-robot-4.html)
[^floodlight]: [Ring Floodlight Cam](https://ring.com/products/floodlight-cam-plus-wired)
[^doorbell]: [Ring Doorbell](https://ring.com/products/battery-doorbell)
[^basestation]: [Ring Alarm Base Station](https://ring.com/products/alarm-base-station-v2)
[^camera]: [Ring Indoor Cam](https://ring.com/products/indoor-camera)
[^homepod]: [Apple HomePod](https://www.apple.com/homepod/)
[^Whitenoise]: [White noise machine](https://a.co/d/9NG05GM)
[^Monitor]: [VTech baby monitor](https://www.vtechkids.com/monitors)

---

## Degens — VLAN 10 — Guest

🟣 **Purple** on the rack.

| Hostname | IP | MAC (OUI) | Device | OS | Zone | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | `10.0.10.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 15.0 | Rack U5 | Firewall |
| eero-guest-1 | `10.0.10.10` | `fc:3f:a6:xx:xx:xx` | eero Pro 6E | eeroOS | Main floor | Wi-Fi mesh |
| eero-guest-2 | `10.0.10.101` | `9c:57:bc:xx:xx:xx` | eero Pro 6E | eeroOS | Main floor | Wi-Fi mesh |

### Notes

- Wired and wireless. A small unmanaged switch on the main floor serves wired
  guests.
- Internet only, client isolation on, no access to any other segment.

---

## Rack and hardware

See [`hardware.md`](hardware.md).

## Diagrams

- [Current topology](diagrams/current/matrix_elysium.png) — high-resolution
  export. An inline Mermaid version is in [`architecture.md`](architecture.md).
- [Previous topology](diagrams/previous/Network_Diagram.png) — kept for
  comparison.
