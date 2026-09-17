# ADR-0041: Run the CRS326 on RouterOS, and keep neo and its switch LAN

**Status:** Accepted · 2026-09 · supersedes the plain-HTTP clause of
[ADR-0018](0018-name-the-switch-and-leave-its-ui-on-plain-http.md)

## Context

[ADR-0018](0018-name-the-switch-and-leave-its-ui-on-plain-http.md) closed #97's
certificate goal as *not achievable on this hardware* and said the only thing
that would reopen it was replacing the switch. A replacement was bought on
2026-09-13 — a used MikroTik CRS326-24G-2S+RM, recorded in
[`hardware.md`](../hardware.md) — and
[#444](https://github.com/Gerrrt/HomeLab/issues/444) is where it was decided.

It was bought for **one property, a TLS management interface**. The issue
originally named three residuals one purchase would close;
[ADR-0036](0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md)
had already removed the middle one, because `neo`'s agent answers SNMPv3 on the
wire and the switch was never what blocked
[#85](https://github.com/Gerrrt/HomeLab/issues/85). What stands is the plain
HTTP — no TLS listener, no certificate import, checked against the live device
on 2026-09-04 — and with it the fact that the switch admin credential, which is
read-write, crosses the wire in clear *through the switch it protects*.
[#84](https://github.com/Gerrrt/HomeLab/issues/84)'s un-deletable community
rides along, because it leaves with the firmware that will not persist its
deletion.

**Why this is written before the switch is racked, and not during.** ADR-0018's
own note said the successor ADR would be written then. That is the wrong time.
`neo` carries every VLAN, so the swap is a house-wide outage sharing a rack
visit, and an outage is not when to weigh a dual-boot device's two operating
systems or to decide whether a management LAN survives. This record decides the
half that cannot be changed later; what the device turns out to be — serial,
management MAC, the OS and version it arrives on, the factory reset — is learned
at the bench and written to `hardware.md`, which is the split
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) already
uses for a purchase. Nothing in the estate changes until the cabling window;
[`swap-the-switch.md`](../runbooks/swap-the-switch.md) is the procedure.

### The operating system is not really a choice

The CRS326 dual-boots RouterOS and SwOS, and SwOS is the tempting one: a single
web page, no routing stack, nothing to misconfigure on a device that should only
switch. It cannot do the job. SwOS serves its web UI over plain HTTP with no
certificate import, and its SNMP agent answers v1 and v2c only. Choosing it
would reproduce, exactly, both of the firmware limits the purchase exists to
escape — and would do so on hardware that is capable, which is worse than the
MokerLink's honest incapacity. RouterOS has a `www-ssl` service that binds an
imported certificate, and an SNMP implementation with v3 authentication,
encryption and address-based access control.

This is recorded rather than left obvious because the device is dual-boot: the
reset button offers the other OS, and a future operator troubleshooting a
RouterOS bridge at 1am will be tempted by the simpler page. The simpler page
gives the credential back to the wire.

### The switch LAN outlives the reason it was built for

[`network.md`](../network.md) says `10.7.7.0/24` exists "solely to reach the
switch's management UI, which will not bind to a tagged interface". That is a
MokerLink limitation, and it leaves with the MokerLink. Read narrowly, the LAN
should go: RouterOS will happily put management on a tagged VLAN, and ADR-0018
recorded that `10.7.7.2` is the one address in a `10.0.x` estate that does not
match the convention.

It should stay, for a reason it did not originally have. The way an operator
loses a RouterOS switch is a bridge VLAN-filtering commit — the config that
decides which ports carry which tags is the same config the management path
depends on, and a wrong `frame-types` or a forgotten tagged member on the
management VLAN locks the door from the inside. On the device that carries every
VLAN in the house, that is not a hypothetical. An untagged point-to-point link
from `morpheus`'s `igc0` to port 1 is unaffected by any of it: it is the way back
in, and it is a cable rather than a configuration. ADR-0018's other argument
survives untouched — the name depends on Unbound on `morpheus`, so
`neo.matrix.elysium` is gone at the moment the switch matters most, and
`10.7.7.2` is the break-glass form. Both stay written down.

Keeping the **name** is the cheaper half of the same decision. `device: neo` is
a label on the SNMP scrape target, a series in two Grafana dashboards, a subject
in eleven runbooks and a node in `architecture.md`'s diagram. The switch is a
role before it is a box, and the role does not change. The alternative buys a
tidier history — one hostname, one physical device — at the cost of touching
every one of those during the window that is already the longest outage this
estate plans for.

### The certificate comes from the estate's CA, not the tier's

There are two certificate authorities here and
[`generate-certificates.md`](../runbooks/generate-certificates.md) opens by
saying which is which. The sensitive tier's CA issues over ACME from step-ca,
with seven-day leaves, for what Caddy serves on `trinity`
([ADR-0037](0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md)).
A switch cannot ask for an ACME renewal, so that root is out on mechanism alone.

The estate's CA is the right one for a second reason, not just by elimination:
Prometheus and blackbox-exporter already verify leaves beneath `ca.pem` by
`ca_file`. That means the `switch-ui` probe can move from `http` to `https` and
actually *verify* the certificate, rather than reaching for
`insecure_skip_verify` and monitoring a TLS listener without checking it is the
right one — which would be a strange end for a purchase made to stop trusting
the wire.

### What does not change

Port mirroring was in #444's selection criteria, and the CRS326 has it. It stays
off. [ADR-0006](0006-detect-at-the-chokepoint.md) decided at length that the
sensor belongs on `morpheus` at the chokepoint and that mirroring on `neo` stays
disabled, available on demand as a deliberate, temporary action;
[ADR-0039](0039-decline-proxmox-clustering-while-ifrit-is-the-range.md) restated
it. Buying a device that *can* mirror is not a decision to mirror, and the
criterion was about not foreclosing the option.

Renumbering onto `10.0.99.x` also stays rejected. ADR-0018 rejected it rather
than deferring it, and every cost it named — the firewall's LAN interface, the
hard-coded targets, and the narrow passes that are all
[ADR-0025](0025-close-the-switch-lan-to-winterfell.md) left reaching
`10.7.7.0/24` — is still there.

## Decision

**RouterOS, the same name and address, and TLS on the management UI.**

1. **The CRS326 runs RouterOS.** SwOS is rejected, not deferred: it serves
   HTTP only, which reproduces exactly the limit the purchase exists to escape,
   and it speaks SNMP v1 and v2c only, which gives back the authPriv the
   replacement would otherwise gain.
2. **It inherits `neo` and `10.7.7.2`, and the switch LAN stays.** ADR-0018's
   host override and its decision to keep the address written down beside the
   name both survive as written. The LAN's justification is replaced, not
   removed: it is the out-of-band path that survives a bad bridge
   VLAN-filtering commit, not a workaround for a UI that would not bind to a
   tag.
3. **`www-ssl` serves the UI, and plain `www` is disabled** — not merely
   unused. The certificate is a leaf from the estate's CA,
   `make certs ARGS="--host neo.matrix.elysium --ip 10.7.7.2"`, carrying both
   the name and the break-glass address.
4. **An SNMPv3 authPriv user, by §4 of
   [`rotate-snmp-community.md`](../runbooks/rotate-snmp-community.md), and v2c
   off.** ADR-0036 left `neo` on v2c because the device could not be trusted to
   persist the change; the replacement can. #85's switch half closes here, and
   #84's community leaves with the hardware rather than being deleted from it.
5. **Port mirroring stays disabled**, per ADR-0006, and the capability is
   recorded as available on demand.

What the device turns out to be is not decided here. The serial, the management
MAC, the OS and version it ships with, and the factory reset go to
`hardware.md` at the bench.

## Consequences

- **Two accepted residuals close together, and they are the ones `neo` still
  carried.** `SECURITY.md` and [`security.md`](../security.md) hold the plain
  HTTP and #84's un-deletable community as knowingly accepted; both change at
  the window, not before, and #84 closes on `snmp-verify.sh` clean over GET
  *and* GETBULK against the new device.
- **The certificate is an 825-day leaf that the switch cannot renew.** The tier
  CA's seven-day ACME leaves renew themselves; this one does not, and a switch
  UI that has stopped being trusted by the browser is how an operator learns to
  click through warnings. It needs a diary entry, and
  [`schedule-maintenance.md`](../runbooks/schedule-maintenance.md) is where that
  lives.
- **`switch-ui` and its `via: dns` twin move to `https` with a `ca_file`.**
  [`blackbox.test.yaml`](../../stacks/observability/prometheus/tests/blackbox.test.yaml)
  uses `switch-ui` as its worked example of an endpoint with no dns twin; that
  comment stopped being true under ADR-0018 and now needs a different subject
  entirely.
- **The SNMP module is renamed and the port mapping is not assumed.** The
  `mokerlink` module in `generator.yaml`, `auth_mokerlink`, the scrape target
  and the switch block in `network.rules.yaml` all name a device that is gone.
  More quietly: this is a 24 + 2 device replacing a 26-port one, so `ifIndex`
  and `ifName` change, and any dashboard panel or rule that names a port must be
  re-checked rather than carried across.
- **A firewall rule names the port, and it is the one change that can lock the
  operator out.** [`network.md`](../network.md) records the switch LAN as
  "blocked apart from `10.7.7.2:80`, the switch's own web UI". Turning plain
  `www` off without widening that pass to `443` first leaves a reachable switch
  that nothing is allowed to reach — from Hicks, which is the workstation the
  window is being run from. Pass `443`, prove the new UI, then close `80`: that
  ordering is in the runbook and it is not optional.
- **`snmp-walk.sh` may stop earning its keep.** It exists because the MokerLink
  locks up under normal polling. If the CRS326 does not, the script becomes a
  workaround for a device nobody has — which is a deletion, on evidence, not a
  tidy-up.
- **The switch LAN is now documented as deliberate, which it was not.**
  `network.md`'s note currently explains it as a consequence of the MokerLink's
  firmware. Left as written, the next reader would correctly conclude the LAN
  could go, and would be removing the way back in.
- **Nothing is deployed by this record.** It is a decision and a runbook; the
  estate still runs on the MokerLink, still on plain HTTP, until a cabling
  window outside working hours takes the house offline.
- **Reopened by:** the CRS326 arriving dead or misdescribed, which puts the
  selection criteria back in play rather than this posture; a certificate
  automation path the estate can actually serve a switch over, which would
  retire the 825-day leaf and its diary entry; or a decision to give the estate
  a second managed switch, at
  which point whether `neo` is a role or a box has to be answered properly.
