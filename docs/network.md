# Network

Six VLANs behind a pfSense firewall, default-deny between segments — seven
internal networks counting the untagged switch-management LAN, which the table
below records with a dash because it carries no tag. Each
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
| [Winterfell](#winterfell--vlan-99--management) | 99 | 🔴 Red | `10.0.99.0/24` | Infrastructure management | Internet, named ports on 20 |
| [Hicks](#hicks--vlan-50--trusted) | 50 | 🟠 Orange | `10.0.50.0/24` | Trusted workstations | Internet, 30, named ports on 99[^hicks] |
| [CasaBonita](#casabonita--vlan-40--media) | 40 | 🟡 Yellow | `10.0.40.0/24` | TVs and consoles | Internet |
| [ImaginationLAN](#imaginationlan--vlan-30--lab) | 30 | 🟢 Green | `10.0.30.0/24` | Hypervisor / lab | Internet |
| [Skids](#skids--vlan-20--iot) | 20 | 🔵 Blue | `10.0.20.0/24` | IoT and cameras | Internet |
| [Degens](#degens--vlan-10--guest) | 10 | 🟣 Purple | `10.0.10.0/24` | Guest Wi-Fi | Internet |

[^lan]: True in both directions since 2026-09-06, and in neither before
    2026-09-02. Outbound, the interface carried pfSense's stock *Default allow
    LAN to any* until 2026-09-02, when six logged blocks — one per VLAN — were
    placed above an egress rule renamed *Allow internet*, leaving DNS and NTP to
    the gateway as the only passes above them
    ([#229](https://github.com/Gerrrt/HomeLab/issues/229)). Inbound, nothing on
    Winterfell can reach it since 2026-09-06: `Gerrrt/Lemmiwinks#177` added a
    logged block from `10.0.99.0/24`, leaving SNMP as the one pass above that.
    One residual, in both directions: the stock *Default allow LAN IPv6 to any*
    rule is still there with no IPv6 blocks above it, so on paper this interface
    reaches every VLAN over v6. Going the other way, CasaBonita, ImaginationLAN,
    Skids and Degens each carry paired `inet`/`inet6` blocks toward the six VLAN
    macros and neither toward this one, so their IPv6 catch-all reaches it. Both
    halves are latent rather than live — `igc0` has only a link-local address,
    which does not route — and the second half went unrecorded until
    `make check-firewall` derived it
    ([#363](https://github.com/Gerrrt/HomeLab/issues/363)).
    [ADR-0013](adr/0013-segment-access-as-implemented.md) read the ruleset while
    this said "Nothing" and was wrong;
    [ADR-0025](adr/0025-close-the-switch-lan-to-winterfell.md) records the
    close.

[^hicks]: Hicks has the broadest path into management of any VLAN, and since
    2026-09-02 that path is a list of destinations rather than the segment: ten
    passes sit above a logged *Block access to Winterfell*, everything else from
    50 to 99 is dropped, and the ten are enumerated in the Hicks notes below. It
    is not the only way into 99 — two host-scoped passes carry ImaginationLAN
    to `10.0.99.20`. Going the other
    way, Hicks reaches ImaginationLAN entire, by a TCP rule of its own and the
    catch-all for the rest — decided, not inherited:
    [ADR-0031](adr/0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md)
    records both halves, and why the lab stays open until the lab exists.
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
| morpheus | *(ISP-assigned)* | `80:e8:2c:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 16.0 | Rack U5 | pfSense |

### Notes

- Cat6 from the ISP gateway[^modem] to the WAN interface of the ProDesk[^ProDesk].
- The gateway runs in bridge mode; its own Wi-Fi radio stays operational but is
  unused. All wireless is handled by eero units on tagged VLANs.
- **One inbound pass, and one only** — the WireGuard endpoint decided by
  [ADR-0042](adr/0042-terminate-the-remote-path-on-the-lab-and-route-it.md): a
  UDP `rdr` to the lab jumpbox, terminating on ImaginationLAN and reaching the
  lab only. The endpoint hostname and the listen port are withheld with the WAN
  address ([`security.md`](security.md#what-this-repository-deliberately-does-not-publish)).
  Before it, `morpheus` carried no `rdr` and no inbound WAN pass beyond DHCP
  client replies — the state ADR-0011 measured in 2026-08. **Built
  2026-09-22** ([#442](https://github.com/Gerrrt/HomeLab/issues/442)): the
  `rdr` and its associated WAN pass exist, to `phoenix` at `10.0.30.70`, and
  the dynamic DNS client of
  [ADR-0044](adr/0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md)
  is bound to this interface — a record in a free provider's zone, kept
  current by `morpheus` itself, on a WAN address measured to be public rather
  than carrier-grade NAT. What the rule admits is one UDP port to one host;
  what arrives through it is a keyed peer or nothing, and how far a peer
  reaches is decided on the ImaginationLAN interface, not here.

[^modem]: [Xfinity Gateway (XB7)](https://www.xfinity.com/support/articles/broadband-gateways-userguides)
[^ProDesk]: [HP ProDesk 600 G4 Mini](https://www.microcenter.com/product/692358/)

---

## LAN

| Hostname | IP | MAC (OUI) | Device | OS | Location | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | `10.7.7.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 16.0 | Rack U5 | Firewall |
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

[^adapter]: [Intel I226 2.5 GbE card on an M.2 B+M-key adapter](https://a.co/d/dJ4BD2N) — in the G4's second M.2 slot, `igc0` to FreeBSD. It was labelled "USB NIC adapter" here until 2026-09-09, and the restore runbook and the shopping list had inherited the label.
[^MokerLink]: [MokerLink 26-port managed switch](https://a.co/d/gaJvCKV)

---

## Winterfell — VLAN 99 — Management

🔴 **Red** on the rack.

Infrastructure. The only segment that can administer other segments, and the
only one Hicks is permitted to reach for management — on the named ports
listed under [Hicks](#hicks--vlan-50--trusted), and nothing else.

| Hostname | IP | MAC (OUI) | Device | OS | Location | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | `10.0.99.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 16.0 | Rack U5 | Firewall |
| mjolnir | `10.0.99.10` | `28:29:86:xx:xx:xx` | APC Smart-UPS[^UPS] | — | Rack U1–U2 | UPS |
| prometheus | `10.0.99.20` | `00:05:1b:xx:xx:xx` | Apple MacBook Pro (2012)[^MacBookPro] | Ubuntu 24.04 LTS | Shelf | **Observability stack** |
| oracle | `10.0.99.30` | `58:8a:5a:xx:xx:xx` | Dell Inspiron 15-3565[^Dell] | Ubuntu 24.04 LTS | Shelf | **Wiki**, and the off-host jobs |
| trinity | `10.0.99.40` | `c4:65:16:xx:xx:xx` | HP ProDesk 600 G4 DM | Ubuntu 26.04 LTS | Shelf | **Sensitive tier**, and AdGuard, the house's DNS filter |

### Notes

- `prometheus` runs the whole monitoring stack from
  [`stacks/observability`](../stacks/observability) — a 2012 MacBook Pro with
  Ubuntu Server on it, which is exactly the sort of hardware a homelab should be
  built from.
- Port 3 of the main switch feeds an 8-port unmanaged switch[^tp-linkswitch]
  that `prometheus` and `oracle` hang off. Since 2026-09-08 it sits on the U4
  shelf and draws from a UPS-fed outlet, so on a mains cut the two laptops keep
  their network as well as their batteries
  ([#110](https://github.com/Gerrrt/HomeLab/issues/110)).
- **`trinity` polls the internet on a timer.** Miniflux ([#147](https://github.com/Gerrrt/HomeLab/issues/147)) fetches every
  subscribed feed about once an hour, so a steady trickle of outbound HTTPS
  from `10.0.99.40` on the WAN graphs is that and not something to chase. It
  leaves by Winterfell's existing egress rule, and its fetcher refuses every
  private address, this segment's included ([ADR-0057](adr/0057-add-miniflux-to-the-sensitive-tier-with-its-fetcher-kept-off-winterfell.md)).
- pfSense's admin UI is reachable on this interface from Hicks only, by a
  named pass to `10.0.99.1:443`. Winterfell itself is blocked from it: the 99
  interface drops HTTP and HTTPS to `10.0.99.1` above its egress rule.
- **One pass into Skids, in force since 2026-09-28:**
  `10.0.99.40 → 10.0.20.20` on `80,443/tcp` — `trinity`'s Home Assistant to
  `bifrost`, the Hue bridge, and nothing else on 20 — **above** *Block access
  to Skids*, beside the two SNMP passes that already sit above that block.
  It is two rows, one per port. `.20` rather than the `.104` ADR-0035 wrote:
  by build day the bridge had drifted to `.113` and another device held `.104`,
  so the reservation went below the pool instead, where no lease can take it. Read on 2026-09-09: every other device on Skids is reached
  through a vendor's cloud or not at all, so the segment-wide row ADR-0008
  wrote as `99 → 20` narrows to one host on two ports, and a second device
  with a local API is a second row rather than a wider one.
  [ADR-0035](adr/0035-scope-the-99-to-20-rule-to-the-hue-bridge.md) records
  the reading and the reasons. It is created under
  [#404](https://github.com/Gerrrt/HomeLab/issues/404), in the same sitting as
  the reservation that pins `bifrost`, and tested from `trinity` the same day:
  Home Assistant paired, the pass carried 430 packets on 443, and all four #223
  tripwires stayed at 0.
- DHCP enabled, with static reservations for everything listed.
- `oracle` runs the Lemmiwinks wiki and its Postgres — it has since 2025-11-12,
  and [ADR-0011](adr/0011-keep-the-wiki-internal.md) depends on it — and holds
  the off-host copies of the firewall export that `make backup-firewall` pushes
  to it, of the weekly volume sets that `make backup` pushes
  ([#535](https://github.com/Gerrrt/HomeLab/issues/535)) and of Jellyfin's
  state that `make backup-nas` pulls off `smaug` and pushes on
  ([ADR-0045](adr/0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md)), as
  ciphertext with no key. Its role is the estate's small off-host
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

Personal and work machines. The VLAN with the broadest path into management,
though not the only one — ImaginationLAN has two host-scoped passes to
`10.0.99.20`.

| Hostname | IP | MAC (OUI) | Device | OS | Zone | Role |
| --- | --- | --- | --- | --- | --- | --- |
| morpheus | `10.0.50.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 16.0 | Rack U5 | Firewall |
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
  segment.** Twelve passes sit above a logged *Block access to Winterfell*, and
  everything else from 50 to 99 is dropped:

  | Destination | Ports |
  | --- | --- |
  | `10.0.99.0/24` — the segment | `22/tcp`, ICMP echo |
  | `10.0.99.1` — `morpheus` | `443/tcp` admin UI, `53/tcp+udp` resolver, `123/udp` NTP |
  | `10.0.99.10` — `mjolnir` | `80,443/tcp` UPS card |
  | `10.0.99.20` — `prometheus` | `3000/tcp` Grafana, `8443/tcp` speedtest-tracker's UI (since 2026-10-06, [#914](https://github.com/Gerrrt/HomeLab/issues/914)) |
  | `10.0.99.30` — `oracle` | `80/tcp` the wiki, Wiki.js over plain http (443 until 2026-09-30, when nothing had listened on it; [#251](https://github.com/Gerrrt/HomeLab/issues/251)). **After [#847](https://github.com/Gerrrt/HomeLab/issues/847)'s cutover** 80 only redirects, and `443/tcp` comes back for the wiki's Caddy: add it before that deploy ([`stacks/wiki/README.md`](../stacks/wiki/README.md#tls)) |
  | `10.0.99.40` — `trinity` | `443/tcp` the sensitive tier, since 2026-09-28 |

  **The source is the segment, not named hosts.** Every one of those passes is
  `vlan50 → …`, so any device on Hicks may use any of them. This note used to
  say the opposite — "only specific hosts, and only on management ports" — and
  had the narrowing backwards in both halves: it is by destination and port, and
  never by host.
- **Corporate laptops are subject to exactly the same rules as everything else
  here.** They are intended to be treated as untrusted endpoints that happen to
  sit on a trusted segment, and nothing on the firewall enforces that. This note
  used to say "no alias holds `10.0.50.69` or `10.0.50.70`, and no rule names
  them," and the first half of that is false: a host alias `WORK_PC` holds
  `10.0.50.69` and has for as long as anyone has looked. The claim survives on
  the second half alone — **no rule references it**, and `pfctl -t WORK_PC -T
  show` prints nothing at all, because pf never loads an alias no rule uses.
  `10.0.50.70` is named nowhere. So it remains a policy about how these machines
  are used, written here as one rather than as a control; `WORK_PC` is just the
  shape such a control would take if someone reached for it.
- **The two corporate machines' model strings are unverified, and they
  disagree with the firewall.** The table above calls both a Surface Laptop 6
  for Business, citing the product page rather than the hardware, while
  `WORK_PC`'s description on `morpheus` calls `10.0.50.69` a Surface Pro 6 —
  a different machine from a different generation. Both strings arrived in a
  bulk restructure with no measurement behind either, and nothing here has read
  a model off either device. Treat both rows as unconfirmed until someone does.
- **Prometheus' and Loki's ingest ports are not on the list above.** `9090` and
  `3100` were reachable from this segment for as long as the catch-all was the
  only rule between them; *Block access to Winterfell* now drops them. They are
  also authenticated since [#182](https://github.com/Gerrrt/HomeLab/issues/182):
  an ingest proxy holds both, and serves a push only to an agent token and a
  query only to the reader token, over TLS since
  [#764](https://github.com/Gerrrt/HomeLab/issues/764). So the firewall is no
  longer the only thing between a Hicks workstation and the metric and log
  stores.
  `10.0.30.110` keeps its explicit pass for `Saruman`'s Alloy agent, which now
  presents `Saruman`'s own token.
- **ImaginationLAN is reached entire**, on every protocol and port, by
  decision: [ADR-0031](adr/0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md)
  keeps it open until the lab build produces the list of what a workstation
  needs there. *Allow Hicks access to ImaginationLAN* now sits on **this**
  interface — ADR-0013 found it on the ImaginationLAN interface, where a rule
  can never match traffic that enters on Hicks — and is TCP-only, so the
  catch-all below still carries UDP and ICMP to the lab. Widen it before any
  block for private ranges lands above the catch-all.
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
| morpheus | `10.0.40.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 16.0 | Rack U5 | Firewall |
| nibelheim | `10.0.40.10` | `78:c8:81:xx:xx:xx` | Sony PlayStation 5[^PS5] | — | Lower floor | Console |
| hyrule | `10.0.40.20` | `00:05:1b:xx:xx:xx` | Nintendo Switch[^Nintendo] | — | Lower floor | Console |
| smaug | `10.0.40.30` | `4c:cc:6a:xx:xx:xx` | Lenovo ThinkServer TS150 | TrueNAS 25.10 | Media room | NAS |
| mediatv | `10.0.40.100` | `58:fd:b1:xx:xx:xx` | LG OLED[^OLEDTV] | webOS | Media room | TV |
| streambox | `10.0.40.101` | `f0:46:3b:xx:xx:xx` | Xumo Stream Box[^StreamBox] | entOS | Media room | Streaming |

### Notes

- All wired with Cat6.
- Internet only, no path to any other segment. Smart TVs run unauditable
  firmware with a permanent internet connection and no patch guarantee, so they
  get the same trust level as a guest.
- **The NAS is here and addressed since 2026-09-16** — `smaug` at
  `10.0.40.30`, decided by
  [ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
  and running TrueNAS by
  [ADR-0040](adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)
  ([#413](https://github.com/Gerrrt/HomeLab/issues/413)). Its ZFS mirror
  `erebor` exists since 2026-09-18 and `stacks/media` runs on it since
  2026-09-19, publishing `8096` to this segment. **It does not change the
  *Reaches* column**, and that is the point ADR-0016 made in advance: nothing
  on this segment initiates anywhere, and the rules created that day all let a
  more trusted segment reach **in**. That is the direction this row records,
  and it is the one that is unchanged. **They are counted in the next bullet
  and nowhere else** — this bullet used to count them too, the two drifted
  apart, and this one still said three long after four existed.
- **`smaug` is on port 15 of the switch**, untagged with PVID 40. That port was
  ImaginationLAN's when the map was last read on 2026-09-04 and was moved for
  the install ([#481](https://github.com/Gerrrt/HomeLab/issues/481)). It is
  recorded because a single-NIC host on an access port has its segment decided
  at the switch and nowhere else: put it back on 30 and the address, the
  reservation and every inbound rule are silently pointless.
- **Inbound is no longer nothing, and that is deliberate.** Since 2026-09-16
  Hicks reaches `10.0.40.30` on `443` and `8096`, and `10.0.99.20` reaches it
  on `9100` and `22` — four host-scoped, port-scoped passes above *Block access
  to CasaBonita* on their interfaces. Everything else on every other segment is
  still refused, and the televisions need no rule at all because they share this
  broadcast domain with the server. **Two more are written for the phones on
  Hicks, and both exist.** `Allow 4533 to smaug`, Hicks →
  `10.0.40.30:4533`, for Navidrome's Subsonic apps
  ([#141](https://github.com/Gerrrt/HomeLab/issues/141)), was created on
  2026-09-22 ahead of the service and verified in position from `morpheus`,
  and a Hicks workstation and phone reached Navidrome through it on
  2026-09-30. `Allow 13378 to smaug`, Hicks → `10.0.40.30:13378`, for
  Audiobookshelf
  ([ADR-0050](adr/0050-add-audiobookshelf-to-the-media-tier-behind-a-fifth-hicks-pass.md)),
  was created by §6.5 and reached from a Hicks workstation on 2026-09-29.
  ADR-0050 calls it the fifth; 4533 and 445 were made first, so it is the
  seventh.
  [`build-the-nas.md`](runbooks/build-the-nas.md) §6.5 and §6.6 deploy the
  two services. **One more is for workstations, and it exists.** `Allow SMB to
  smaug`, Hicks → `10.0.40.30:445`, lets a Hicks workstation mount the `media`
  share as `samwise`, a second SMB user kept apart from the televisions'
  `bilbo` ([ADR-0051](adr/0051-let-hicks-workstations-mount-the-media-share-as-a-user-of-their-own.md),
  [#523](https://github.com/Gerrrt/HomeLab/issues/523)). It was created on
  2026-09-23 by `build-the-nas.md` §5, and a Hicks workstation has mounted the
  share through it. With 4533 and 13378, seven exist from Hicks and
  Winterfell. **Two more are from ImaginationLAN, and both exist, which
  makes nine.** `Allow NFS from Saruman to smaug`,
  `10.0.30.110 → 10.0.40.30:2049`, lets the hypervisor mount `erebor/iso` as
  its ISO store for Packer
  ([ADR-0072](adr/0072-put-the-iso-store-on-smaug-over-nfs-to-saruman-alone.md),
  [#446](https://github.com/Gerrrt/HomeLab/issues/446)). It was created on
  2026-10-01 by `build-the-nas.md` §5b, directly above `igc0.30`'s *Block
  access to CasaBonita*. `Saruman` has mounted the share through it, and
  `alexander` is refused. `Allow NFS from golem to smaug`,
  `10.0.30.80 → 10.0.40.30:2049`, carries `golem`'s PBS datastore on
  `erebor/pbs`
  ([ADR-0053](adr/0053-run-pbs-on-saruman-with-its-datastore-on-smaug-over-nfs.md),
  [#485](https://github.com/Gerrrt/HomeLab/issues/485)). It was created on
  2026-10-03 by [`build-the-backup-guest.md`](runbooks/build-the-backup-guest.md)
  §4, directly above the same block. `golem` has mounted the share through
  it, and `alexander` is refused.
- **What answers on `9100` is `node_exporter`**, which makes this the one host
  in the estate that Prometheus *scrapes* rather than is pushed to
  ([#256](https://github.com/Gerrrt/HomeLab/issues/256),
  [ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)).
  It has answered since 2026-09-19, and the target in
  `prometheus/targets/node.yaml` has been live since the same morning
  ([#522](https://github.com/Gerrrt/HomeLab/pull/522)). Port `22` was inert
  for a different reason — TrueNAS ships SSH disabled — until 2026-09-19,
  when [`build-the-nas.md`](runbooks/build-the-nas.md) §6.2 switched it on
  for the backup pull [ADR-0045](adr/0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md)
  decided: key-only, one read-only user, `frodo`, and the rule already scopes
  it to `10.0.99.20`. The first pull landed on 2026-09-20.

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
| morpheus | `10.0.30.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 16.0 | Rack U5 | Firewall |
| shiva | `10.0.30.10` | `94:57:a5:xx:xx:xx` | HPE iLO 4 (DL360 Gen9 BMC)[^Shiva] | iLO 2.82 | Rack U3 | Out-of-band management |
| Saruman | `10.0.30.110` | `14:02:ec:xx:xx:xx` | HPE ProLiant DL360 Gen9[^Shiva] | Proxmox VE 9 | Rack U3 | Hypervisor |
| alexander | `10.0.30.40` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Ubuntu 26.04 LTS | Rack U3 | Lab observability |
| phoenix | `10.0.30.70` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Ubuntu 26.04 LTS | Rack U3 | Deployment host |
| golem | `10.0.30.80` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Proxmox Backup Server 4 | Rack U3 | Backups (PBS) |
| odin | `10.0.30.60` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Ubuntu 26.04 LTS | Rack U3 | Security tooling (SOC) |
| bahamut | `10.0.30.50` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Windows Server 2025 | Rack U3 | Lab domain controller (PDC) |
| leviathan | `10.0.30.51` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Windows Server 2025 | Rack U3 | Lab domain controller |
| titan | `10.0.30.52` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Windows Server 2025 | Rack U3 | Lab file server |
| ramuh | `10.0.30.53` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Windows Server 2025 | Rack U3 | Lab application server |
| carbuncle | `10.0.30.54` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Windows 11 Pro | Rack U3 | Lab domain endpoint |
| siren | `10.0.30.55` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Windows 11 Pro | Rack U3 | Lab domain endpoint |
| fenrir | `10.0.30.90` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Ubuntu 26.04 LTS | Rack U3 | Zeek sensor |
| eden | `10.0.30.41` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Ubuntu 26.04 LTS | Rack U3 | BloodHound CE (on demand) |
| garuda | `10.0.30.62` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Kali Linux Rolling | Rack U3 | Analyst workstation (Kali Purple, without its SOC) |
| dot-debian | `10.0.30.91` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Debian 13 | Rack U3 | Dotfiles test VM, on demand |
| dot-fedora | `10.0.30.92` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Fedora Server 44 | Rack U3 | Dotfiles test VM, on demand |
| dot-opensuse | `10.0.30.93` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | openSUSE Tumbleweed | Rack U3 | Dotfiles test VM, on demand |
| dot-arch | `10.0.30.94` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Arch Linux | Rack U3 | Dotfiles test VM, on demand |
| dot-alpine | `10.0.30.95` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Alpine Linux 3.24 | Rack U3 | Dotfiles test VM, on demand |
| dot-gentoo | `10.0.30.96` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Gentoo Linux (systemd) | Rack U3 | Dotfiles test VM, on demand |
| dot-nixos | `10.0.30.97` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | NixOS 26.05 | Rack U3 | Dotfiles test VM, on demand |
| dot-windows | `10.0.30.98` | `bc:24:11:xx:xx:xx` | KVM guest on `Saruman` | Windows 11 Pro (unactivated) | Rack U3 | Dotfiles test VM, on demand |

### Notes

- Reachable from Hicks only; outbound internet permitted.
- **The block that stops it reaching CasaBonita is *Block access to
  CasaBonita*** on `igc0.30`, one of a run of per-segment blocks (Degens,
  Skids, CasaBonita, Hicks, Winterfell, the untagged LAN) that sit above the
  #223 tripwire and *Allow internet*. A pass from this segment to `smaug`
  goes directly above it. `Allow NFS from Saruman to smaug` does, since
  2026-10-01 ([ADR-0072](adr/0072-put-the-iso-store-on-smaug-over-nfs-to-saruman-alone.md)),
  and `Allow NFS from golem to smaug` does, since 2026-10-03
  ([ADR-0053](adr/0053-run-pbs-on-saruman-with-its-datastore-on-smaug-over-nfs.md)).
  [`build-the-backup-guest.md`](runbooks/build-the-backup-guest.md) §4
  asked for this block to be named here.
- `shiva` and `Saruman` are the same physical box: `shiva` is the iLO BMC on its
  dedicated port, `Saruman` is the Proxmox install. They are separate addresses
  and separate names, and conflating them is a mistake this document previously
  made.
- `Saruman` runs every row in the table above whose device is "KVM guest on
  `Saruman`". The table is the count, so this note does not repeat it. Several
  of them are described below. `alexander`, built 2026-09-05
  ([#262](https://github.com/Gerrrt/HomeLab/issues/262)), runs
  [`stacks/lab`](../stacks/lab) — the lab's own Prometheus, Loki, Grafana and
  Alloy. **It is a guest and not the hypervisor for a reason**: a compose stack
  is Docker, and Docker would rewrite the iptables of the box whose own
  firewall ADR-0014 relies on — the same fact that put the native `.deb` agent
  on `Saruman` rather than a container
  ([ADR-0020](adr/0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)).
  It gets **no** pass into Winterfell: the rule below is the hypervisor's, and
  ADR-0007's "guests get no such rule" covers this one too. Nothing in that
  stack remote-writes off the segment, so nothing outside the lab sees it — and
  nothing outside the lab can tell it apart from a lab nobody is using
  ([#257](https://github.com/Gerrrt/HomeLab/issues/257)).
- `carbuncle` and `siren` are [ADR-0029](adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)'s
  two endpoints. They were built and activated, reported 2026-09-26, and are
  joined to `ad.matrix.elysium`, which `bahamut`, `leviathan`, `titan` and
  `ramuh` were built by hand on 2026-09-24 and 2026-09-25 to serve
  ([`build-the-lab-domain.md`](runbooks/build-the-lab-domain.md),
  [#414](https://github.com/Gerrrt/HomeLab/issues/414)). Their
  addresses are DHCP reservations, read from `morpheus`'s `config.xml` on
  2026-09-26, and not statics. They run per session, so an absence from the
  segment is normal.
- **DNS on this segment has two answers, by decision.** The six domain members
  resolve at the two DCs, `bahamut` and `leviathan`, which are authoritative
  for `ad.matrix.elysium` and forward everything else to `10.0.30.1`.
  Everything else on the segment (`alexander`, `odin`, `phoenix`, `fenrir`,
  `Saruman`) still resolves at the gateway, as ADR-0010 has it. There is **no
  domain override for the AD zone on Unbound**, and that is deliberate
  ([ADR-0029](adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)).
  An override would put a nameserver on the attackers' segment into the house
  resolver's path. So an AD name that resolves from `alexander` is a design
  regression, not a fix.
- `10.0.30.61` and VMID 161 are reserved for `diabolos`, the disposable
  investigation guest of
  [ADR-0071](adr/0071-run-disposable-investigations-on-a-guest-that-is-destroyed.md)
  ([#438](https://github.com/Gerrrt/HomeLab/issues/438)). It is not in the table
  above because most of the time it does not exist: it is built for one
  investigation and destroyed at the end of it
  ([`run-a-scratch-investigation.md`](runbooks/run-a-scratch-investigation.md)).
  `.61` breaks the decade spacing on purpose, since every `.x0` from `.10` to
  `.90` is taken or reserved, and sits in `odin`'s decade because it runs
  `odin`'s stack. While it exists it is a static below the DHCP pool, like
  `odin`, and it gets no firewall rule the segment does not already have.
- `garuda` is at `10.0.30.62`, VMID 162, Defense's analyst workstation of
  [ADR-0091](adr/0091-put-a-kali-purple-analyst-workstation-on-saruman.md),
  **built 2026-10-10** as a full clone of template 910
  ([#921](https://github.com/Gerrrt/HomeLab/issues/921),
  [`build-the-analyst-workstation.md`](runbooks/build-the-analyst-workstation.md)).
  It is off-decade for `diabolos`'s reason, in `odin`'s decade beside the SOC it
  works from. It is a Kea reservation by the MAC pinned in `tofu/guests.tf`,
  always on and not tagged `on-demand`. It is not a lab-domain member, so it
  resolves at `10.0.30.1`. It needs no rule of its own: Hicks reaches its
  console through `Saruman`, its Alloy pushes to `alexander` within the
  segment, and it reaches the internet for packages. #921's OpenVAS phase
  will scan VLAN 30 from here, and only VLAN 30. A scan that reaches another
  segment is a `LabSegmentReachedInternalNetwork`, as it should be.
- `10.0.30.91`–`.98`, VMIDs 191–198, are the dotfiles test VMs of
  [ADR-0090](adr/0090-test-the-dotfiles-os-layers-on-on-demand-saruman-guests.md)
  ([#920](https://github.com/Gerrrt/HomeLab/issues/920),
  [`test-the-dotfiles-layers.md`](runbooks/test-the-dotfiles-layers.md)), one
  per dotfiles OS layer: `.91` `dot-debian`, `.92` `dot-fedora`, `.93`
  `dot-opensuse`, `.94` `dot-arch`, `.95` `dot-alpine`, `.96` `dot-gentoo`,
  `.97` `dot-nixos`, `.98` `dot-windows`. `.91`, `.92` and `.98` were built
  on 2026-10-08 and `.93`–`.97` on 2026-10-09, and are in the table above.
  They are off-decade for `diabolos`'s reason,
  in `fenrir`'s decade because it is the one with eight free addresses. Each
  is a Kea reservation by the MAC pinned in `tofu/guests.tf`. They are off
  between runs and tagged `on-demand`, and are not lab-domain members, so
  they resolve at `10.0.30.1`. They need no rule of their own: a run reaches
  the internet for packages and `git clone`, and `phoenix` reaches them
  within the segment.
- `10.0.30.99` is held only while template 907, 908 or 909 builds: those
  builds (`packer/alpine.pkr.hcl`, `packer/gentoo.pkr.hcl`,
  `packer/nixos.pkr.hcl`) give their machine this fixed address, because
  neither the cloud images nor the NixOS ISO carry a guest agent to report a
  DHCP one. It is otherwise unused. Give it to nothing else, or those
  builds collide with it (#920 phase 3).
- `eden` is at `10.0.30.41`, VMID 141, the BloodHound CE server of
  [ADR-0081](adr/0081-run-bloodhound-ce-on-a-saruman-guest.md), **built
  2026-10-07** as a full clone of template 901
  ([#451](https://github.com/Gerrrt/HomeLab/issues/451),
  [`build-the-bloodhound-guest.md`](runbooks/build-the-bloodhound-guest.md)).
  It is off-decade for `diabolos`'s reason: every `.x0` is taken. It sits in
  `alexander`'s decade, beside the other lab guest that serves a UI to a human.
  It is off between sessions and tagged `on-demand`, so an absence from the
  segment is normal. Every path it needs is already open:
  - a collector on the domain uploads to it within the segment;
  - Hicks reaches its UI on `8443` over the existing rule;
  - its Alloy pushes to `alexander`.

  So it adds no firewall rule. It resolves at the gateway like `alexander`. It
  reads nothing from AD's DNS, because the collector does the domain's
  lookups and uploads the result.
- `odin` is at `10.0.30.60` — a static below `.100`, continuing the decade
  spacing — for [`stacks/soc`](../stacks/soc): Wazuh and Velociraptor, the
  security half of ADR-0007, placed there by
  [ADR-0030](adr/0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md).
  Built 2026-09-27 ([`build-the-soc-guest.md`](runbooks/build-the-soc-guest.md));
  its stack runs and its Velociraptor metrics are scraped by `alexander`. Its
  Alloy pushes to `alexander` and not to Winterfell — "guests get no such rule"
  covers it — and ADR-0029's six machines enrol to it as agents by GPO, the
  step that closes [#266](https://github.com/Gerrrt/HomeLab/issues/266) and
  [#267](https://github.com/Gerrrt/HomeLab/issues/267). Every path it needs is
  intra-segment, so it adds no firewall rule. The same fact cuts the other
  way: no firewall stands between it and the rest of the lab either. So its
  two web UIs, the Wazuh dashboard on `443` and Velociraptor on `8889`, are
  published by its Caddy, which answers Hicks only
  ([#1139](https://github.com/Gerrrt/HomeLab/issues/1139)).
- A third guest, `phoenix`, is at `10.0.30.70` — the next decade — as
  the deployment host: the Proxmox API token, the SSH key and the checkout
  that the Packer, OpenTofu and Ansible work after
  [#436](https://github.com/Gerrrt/HomeLab/issues/436) runs from, placed by
  [ADR-0043](adr/0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)
  and built 2026-09-20 by
  [`build-the-jumpbox.md`](runbooks/build-the-jumpbox.md). It runs no stack
  and holds no key that signs anything — the estate's CA stays on
  `prometheus`, and that ADR says why. It is also where
  [ADR-0042](adr/0042-terminate-the-remote-path-on-the-lab-and-route-it.md)'s
  WireGuard tunnel terminates, built 2026-09-22
  ([#442](https://github.com/Gerrrt/HomeLab/issues/442)); the peers reach the
  lab through it and nothing else. Its Alloy pushes to
  `alexander` and
  not to Winterfell, and it gets no pass out of this segment: a rule from it
  into 99 would make it the bastion ADR-0002 and ADR-0012 declined. Everything
  it adds on `morpheus` belongs to the tunnel and nothing else: a gateway and a
  static route for `172.31.0.0/24` toward `10.0.30.70`, the one WAN `rdr`
  above, and on this interface the `Tunnel_Peers` alias with six logged IPv4
  blocks, one per house segment, and one tripwire — the peers' copy of the
  segment's own rules. Nothing from it into another segment. What it adds on `Saruman` is
  one line in the hypervisor's own firewall admitting `10.0.30.70` to `8006`,
  which
  `firewall-claims.yaml` cannot see because it lives in `/etc/pve` and not in
  pf. That line is written, and the firewall it sits in was turned on the same
  day it was found off: `phoenix`'s build on 2026-09-20 discovered `Saruman`'s
  Proxmox firewall disabled with ADR-0014's rules never applied, and
  [#566](https://github.com/Gerrrt/HomeLab/issues/566) closed it that day with
  all four rules, verified from `morpheus`. **Enabling it was not sufficient on
  its own, which is the part worth carrying:** Proxmox builds a `management`
  address set out of the node's own subnet, so `10.0.30.0/24` reached the API,
  SSH, VNC, the SPICE proxy and the migration range through a rule nobody
  wrote, underneath a `DROP` policy that looked closed. The `local_network`
  alias is pinned to `10.0.30.110` so that the four rules above are the only
  way in. Hicks reaches `8006`, `8007` and `22`; `phoenix` reaches `8006`;
  nothing else on this segment reaches the hypervisor at all.
- `fenrir` is at `10.0.30.90`, the next free decade, built 2026-09-30 as the
  Zeek sensor of
  [ADR-0068](adr/0068-mirror-the-lab-bridge-to-zeek-with-tc-not-open-vswitch.md)
  ([#437](https://github.com/Gerrrt/HomeLab/issues/437),
  [`build-the-sensor-guest.md`](runbooks/build-the-sensor-guest.md)). It has a
  second NIC with no address, alone on a bridge `vmbr1` on `Saruman` that has
  no physical port, no address and no VLAN awareness. That bridge carries only
  the copies of `vmbr0`'s traffic the hypervisor's `tc` mirror sends it, so it
  is not a second segment and needs no row in this document's tables. Every
  path `fenrir` needs is intra-segment — its Alloy pushes to `alexander` — so
  it adds no firewall rule.
- `Saruman` runs an Alloy agent and is the one host on this segment with a path
  into Winterfell: a single pass, `10.0.30.110 → 10.0.99.20` on 9090 and 3100
  TCP, unlogged and above the ADR-0014 tripwire. The hypervisor's own telemetry
  only; guests get no such rule (ADR-0007, as amended by #88). Past the rule,
  the ingest proxy wants `Saruman`'s agent token (#182), so the pass lets the
  host try and the token is what gets it served. The push is TLS under the
  estate CA (#764), so the token is not readable at the firewall that forwards
  it.
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

- **The WireGuard peers live on `172.31.0.0/24`, and it is routed rather than
  translated**
  ([ADR-0042](adr/0042-terminate-the-remote-path-on-the-lab-and-route-it.md);
  built 2026-09-22, [#442](https://github.com/Gerrrt/HomeLab/issues/442), one
  peer, pinned to a `/32`).
  `morpheus` carries one static route for it toward the jumpbox, so a peer's
  own address is what arrives on this interface and what a firewall log
  carries — which is what lets a rule name a peer and an alert say which one.
  The blocks and the tripwire on this interface are therefore doubled: one set
  sourced from the segment, one from the peers. It is the fourth private block
  in the house and the second that is not a VLAN. **`172.30.` is `ifrit`'s
  range bridge; `172.31.` is the tunnel** — they mean opposite things in a log
  line, and the second octet is the only thing that distinguishes them.

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
| morpheus | `10.0.20.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 16.0 | Rack U5 | Firewall |
| eero-iot-1 | `10.0.20.101` | `fc:3f:a6:xx:xx:xx` | eero Pro 6E | eeroOS | Upper floor | Wi-Fi mesh |
| eero-iot-2 | `10.0.20.102` | `fc:3f:a6:xx:xx:xx` | eero Pro 6E | eeroOS | Main floor | Wi-Fi mesh |
| eero-iot-3 | `10.0.20.103` | `9c:57:bc:xx:xx:xx` | eero Pro 6E | eeroOS | Lower floor | Wi-Fi mesh |
| bifrost | `10.0.20.20` | `ec:b5:fa:xx:xx:xx` | Philips Hue Bridge[^Huebridge] | — | Main floor | Lighting |
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
- **Inbound, one exception, in force since 2026-09-28.** `trinity`'s Home
  Assistant reaches `bifrost` on `80,443/tcp` — the Hue bridge's local API,
  the only one on this segment; everything else here is reached through its
  vendor's cloud or not at all
  ([ADR-0035](adr/0035-scope-the-99-to-20-rule-to-the-hue-bridge.md)). The
  rule sits on Winterfell's interface, so nothing here changes: the blocks
  above, the [#223](https://github.com/Gerrrt/HomeLab/issues/223) tripwire and
  the egress rule stay as they are, and the tripwire's counter — zero — is
  the test that the return traffic rides state and never reaches them. Skids
  stays terminal outbound, and is no longer terminal inbound, for one host
  on two ports.
- **One address here is reserved: `bifrost` at `10.0.20.20`**, below the
  `.100–.200` pool, since 2026-09-28. Every other device above sits inside
  the pool by lease, so its row is what it had when it was read, not what it
  will have. The build proved why the rule's destination could not be one of
  those: between 2026-09-09 and 2026-09-28 the bridge moved from `.104` to
  `.113`, and `.104` went to another device.
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
| morpheus | `10.0.10.1` | `02:26:26:xx:xx:xx` | HP ProDesk 600 G4 Mini | FreeBSD 16.0 | Rack U5 | Firewall |
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

- [Current network diagram](diagrams/current/network.svg) — drawn from this
  file and [`hardware.md`](hardware.md), so a change to a table here touches
  it in the same pull request ([`diagrams/README.md`](diagrams/README.md)).
  An inline Mermaid version is in [`architecture.md`](architecture.md).
- Previous diagrams, kept for comparison:
  [`matrix_elysium.png`](diagrams/previous/matrix_elysium.png) (2025) and
  [`Network_Diagram.png`](diagrams/previous/Network_Diagram.png).
