# Hardware

A 9U open-frame rack, a firewall built from a refurbished mini PC, a
decommissioned enterprise server, and two laptops that were headed for a
landfill.

## Rack

| U | Device | Role |
| --- | --- | --- |
| U1–U2 | APC Smart-UPS[^UPS] | Power |
| U3 | HPE ProLiant DL360 Gen9[^Shiva] | Proxmox hypervisor (`shiva`) |
| U5 | HP ProDesk 600 G4 Mini[^ProDesk] | pfSense firewall (`morpheus`) |
| U6 | MT-VIKI 8-port KVM[^KVM] | Console access |
| U7 | Jadol 24-port patch panel[^Panel] | Cabling |
| U8 | 10-outlet PDU[^PDU] | Power distribution |
| U9 | MokerLink 26-port managed switch[^MokerLink] | Core switching (`neo`) |

Off-rack: two Ubuntu Server laptops on a shelf (`prometheus`, `oracle`), an
8-port unmanaged TP-Link switch feeding them, and eero Pro 6E units distributed
through the house.

## Compute

| Host | Hardware | CPU | RAM | Storage | OS |
| --- | --- | --- | --- | --- | --- |
| `morpheus` | HP ProDesk 600 G4 Mini | i5-8500T | 32 GB | 1 TB SSD | FreeBSD 15.0 (pfSense) |
| `shiva` | HPE ProLiant DL360 Gen9 | 2× Xeon E5 v3/v4 | — | — | Proxmox VE |
| `prometheus` | Apple MacBook Pro (2012) | i5/i7 | — | SSD | Ubuntu Server 24.04.3 |
| `oracle` | Dell Inspiron 15 | i5-1235U | 32 GB | 2 TB SSD | Ubuntu Server 24.04.3 |

The observability stack runs on a thirteen-year-old MacBook. It handles four
SNMP devices at a 60-second interval, two Alloy agents, and 30 days of metric
retention without complaint — which is a useful thing to know before spending
money on a monitoring host.

## Accessories

- 1U rackmount tray for the ProDesk Mini[^ProDeskRackmount]
- Sliding rails for the ProLiant[^Sliderail]
- 1U universal rack mount for the APC[^Rail]
- ViewSonic N1700W LCD, used as a rack console via the KVM
- RJ45 Cat6 in-line couplers[^Couplers]
- Cat6 patch cables[^Patchcables]

[^UPS]: [APC Smart-UPS](https://www.apc.com/us/en/product-range/61913-smart-ups/)
[^Shiva]: [HPE ProLiant DL360 Gen9](https://buy.hpe.com/us/en/servers/rack-servers/proliant-dl300-servers/proliant-dl360-server/p/1010026922)
[^ProDesk]: [HP ProDesk 600 G4 Mini](https://www.microcenter.com/product/692358/)
[^KVM]: [MT-VIKI 8-port rackmount KVM](https://a.co/d/2yQl4KH)
[^Panel]: [Jadol 24-port patch panel](https://a.co/d/izggRoK)
[^PDU]: [10-outlet 1U PDU](https://a.co/d/ibEygxZ)
[^MokerLink]: [MokerLink 26-port managed switch](https://a.co/d/gaJvCKV)
[^ProDeskRackmount]: [1U rackmount for ProDesk Mini](https://a.co/d/4d7klOL)
[^Sliderail]: [Sliding rails for ProLiant](https://a.co/d/5d4A4FO)
[^Rail]: [1U universal rack mount](https://a.co/d/6R0vjHz)
[^Couplers]: [Cat6 in-line couplers](https://a.co/d/gP3b948)
[^Patchcables]: [Cat6 patch cables](https://vetco.net/collections/cables-cat6-patch-cables)
