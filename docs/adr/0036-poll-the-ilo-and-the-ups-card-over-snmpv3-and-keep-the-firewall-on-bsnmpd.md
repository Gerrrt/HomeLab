# ADR-0036: Poll the iLO and the UPS card over SNMPv3, and keep the firewall on bsnmpd

**Status:** Accepted · 2026-09

## Context

[#85](https://github.com/Gerrrt/HomeLab/issues/85) asks whether to move to
SNMPv3 authPriv on "the three devices that can" and accept a mixed estate, or
to treat the whole thing as blocked until the MokerLink switch is replaced.
Both readings rest on the same premise — three can, one cannot — and on
2026-09-09 both halves of it were checked against the devices rather than
inherited from the issue. Neither holds as stated, and the correction changes
the answer.

### What was checked

**The firewall cannot, and the switch is not why.** `morpheus` answers SNMP
from bsnmpd — `/usr/sbin/bsnmpd` is what holds `10.0.99.1:161` — and pfSense
writes its configuration: `services.inc` and `services_snmp.php` contain no
USM, VACM or engine line, so there is no way to create a v3 user that
survives the next save or boot, because pfSense regenerates
`/var/etc/snmpd.conf` from `config.xml` on both. The daemon does *parse* v3 on
the wire — a discovery packet gets a proper USM Report back, "Unknown user
name" — but `snmp_usm.so` is not loaded and no user can exist. The Net-SNMP
package (`pfSense-pkg-net-snmp 0.1.5_16` over `net-snmp 5.9.5.2`) is
installed, would do SNMPv3 with SHA and AES from its own GUI, and is not
enabled; it should stay that way. net-snmp has no BEGEMOT-PF-MIB. Everything
the `pfsense` module is polled for — `pfStatusRunning`, the state table, the
pf counters and tables — is served by bsnmpd's `snmp_pf` module and by nothing
else. Moving the firewall to the daemon that can encrypt would silence
`PfNotRunning`, `PfStateTableNearLimit` and `PfMemoryDropsIncreasing` to
protect a credential whose entire value is those same tables. So the one
credential in the estate that matters most stays on SNMPv2c, and the switch
has nothing to do with it.

**The switch's agent speaks SNMPv3 on the wire.** The same discovery packet
sent to `10.7.7.2` gets the same USM Report as the other three devices. What
"cannot do SNMPv3 at all"
([ADR-0018](0018-name-the-switch-and-leave-its-ui-on-plain-http.md), from this
issue) was true of is the web UI as it was read. Whether that UI has a page to
create a USM user has not been checked, and its login is the only way to check
it — every unauthenticated path on it serves the same 367-byte login frameset.
So the blocker is at most a UI limit, recorded here as unverified, and this
decision does not depend on it either way.

**The iLO and the UPS card can, with the protocols this decision wants.**
`shiva` is iLO 4 at 2.82; its SNMP Settings page carries three SNMPv3 users
(MD5 or SHA, DES or AES, passphrases of 8 to 49 characters), an engine ID, and
a separate *SNMPv1 Request* switch — HPE iLO 4 User Guide, *SNMP settings*.
`mjolnir`'s card is an **AP9641**, a Network Management Card 3 on AOS 2.0.0.6,
read off its sysDescr today rather than assumed from the UPS model; the NMC3
user guide gives four SNMPv3 user profiles (SHA or MD5, AES or DES, passphrases
of 15 to 32 ASCII characters), a per-NMS access-control list on each, and
SNMPv1 access as a separate enable. Both can therefore run authPriv with SHA
and AES and then refuse v1 and v2c altogether, which is the whole point: a
device that still answers a community beside a v3 user has moved nothing.

**Where each poll actually travels.** Each of the four polls leaves
`10.0.99.20`, and `neo` carries every VLAN, so every one of them crosses the
switch — a foothold *on* the switch reads all four whatever this ADR decides,
which is the argument for replacing it that ADR-0018 already makes. What
differs is the last hop:

| Poll | Last hop is on | Who else is there | What the credential reads |
| --- | --- | --- | --- |
| `shiva` | ImaginationLAN (30) | the attack VM [ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md) puts there, on purpose | the whole HP Insight tree: hardware inventory, host names, health |
| `mjolnir` | Winterfell (99) | the monitoring host and the firewall's admin UI | UPS state |
| `morpheus` | Winterfell (99) | the same | the pf state table and every interface |
| `neo` | the switch LAN | nothing but the switch | 26 ports' counters, and `"Switch"` |

One of these polls is delivered, by design, into a broadcast domain that will
hold a Kali VM. A guest on VLAN 30 that ARP-spoofs `10.0.30.10` reads the
iLO's community every sixty seconds — no mirror port, no foothold on the
switch, nothing more than the lab ADR-0014 wants it to be able to do.
[ADR-0033](0033-keep-the-ilo-on-the-lab-segment.md) accepted that the BMC is
part of the estate under attack; it did not have to accept handing the
attacker a credential to it. That poll is the one worth encrypting, and
encrypting it costs no firewall change: the rule is `161-162/udp`, and v3 is
the same port. The other three ride on VLAN 99, where anything that can sniff
is already on the segment that holds the firewall's UI and this host — a
community is not what such an attacker lacks.

### What a mixed estate costs

The tooling assumed one credential per device, and one shape:
`snmp-targets.sh` derived `SNMP_COMMUNITY_<X>` from the `auth_<x>` label, and
the five copies of the device list were held together by that derivation.
A v3 device has a user name, an authentication passphrase and a privacy
passphrase, and `snmp-verify.sh` and `snmp-walk.sh` both spoke to net-snmp
through a `defCommunity` line. That is the real price of "move the ones that
can", and it is paid once, in the change that carries this ADR, rather than
per device.

## Decision

**Encryption is decided per poll, by where the poll goes, and the estate is
mixed on purpose.** Not uniform-or-nothing, and not blocked on a purchase that
has never been decided.

1. **`shiva` moves to SNMPv3 authPriv first** — SHA authentication, AES
   privacy, a user that exists for `10.0.99.20` and nothing else, and
   *SNMPv1 Request* switched off once the v3 poll is verified. Procedure in
   [`rotate-snmp-community.md` §4](../runbooks/rotate-snmp-community.md#4-move-a-device-to-snmpv3).
   It is the one poll that crosses into the lab, and the one whose credential
   the lab is meant to be able to try for.
2. **`mjolnir` follows on the same procedure.** The gain is smaller — its poll
   never leaves Winterfell — but the card supports the same protocols, the
   procedure is the same four steps, and a UPS card that refuses v1 is one
   fewer cleartext credential on the segment. Its passphrases are 15 to 32
   characters; `make gen-secret` at its default 24 fits both devices.
3. **`morpheus` stays on bsnmpd and SNMPv2c.** The pf MIB is worth more than
   the community that reads it, and pfSense offers no v3 that keeps it.
   Reopened by pfSense's SNMP page growing USM users, or by a pf module for
   net-snmp — neither is expected. The controls are what they were: a
   community unique to the device, a daemon bound to the VLAN 99 address only
   (`sockstat` shows it on `10.0.99.1` and nowhere else), and a segment only
   trusted hosts enter.
4. **`neo` stays on SNMPv2c**, and its UI is checked once, at the next login,
   for an SNMPv3 user page. If there is one, it follows §4 in the same reboot
   window as [#84](https://github.com/Gerrrt/HomeLab/issues/84), with the
   expectation — given the community table — that a user may not persist
   either; if there is not, ADR-0018's replacement criterion stands. Either
   answer goes into `hardware.md`.
5. **authPriv or nothing.** A v3 auth block in `generator.yaml` must be
   `authPriv`. `snmp-targets.sh --check` refuses `authNoPriv` and
   `noAuthNoPriv`, because a v3 poll that authenticates and then sends the
   tables in clear has kept the cost of this change and given up the benefit.
6. **The credential's shape is declared where the exporter reads it.**
   `generator.yaml`'s auth block is the source of truth for a device's
   version, user name and protocols, and every tool derives the secret key
   names from it — `SNMP_COMMUNITY_<X>` for v2c, `SNMP_AUTHPASS_<X>` and
   `SNMP_PRIVPASS_<X>` for v3 — rather than holding a copy
   (`scripts/snmp-auth.sh`). The user name is not a secret and stays in the
   tracked file: USM sends it in the clear header of every message.

The order of operations stays *device first, then repository*, one device at
a time, exactly as a community rotation. The change that carries this ADR
ships with all four devices still on v2c: the repository could hold a v3 auth
block before the device has a user, but rendering it would fail on the missing
keys, and that is the wrong side of the order.

## Consequences

- **The estate is mixed, and the documents say which is which.**
  `docs/security.md`'s SNMPv2c section stops saying "not done — the switch
  does not support it" and says instead which polls are encrypted and why the
  other two are not. `SECURITY.md`'s residual for the switch is unchanged.
- **`--old` gains a meaning on a v3 device.** `snmp-verify.sh --old` probes
  with the *old community over v2c*; against a device moved to v3 with SNMPv1
  switched off, that is exactly the check that v1/v2c access is really off. A
  `STILL ACCEPTED` there means the community is still answered and the move
  is not complete.
- **v3 rejections are loud where v2c ones were silent.** A wrong passphrase
  or unknown user returns a USM Report, so `snmp-verify.sh` distinguishes
  "rejected" from "no response" for the first time — on these devices only.
  Measured against the live iLO with a user that does not exist: net-snmp
  reports `Unknown user name`, and the pinned exporter (v0.30.1, run beside
  the stack with the same block) logs `incoming packet is not authentic,
  discarding` and returns a 500 for the scrape. The `SKIP` logic for `--old`
  is unchanged, because the old-community probe is still v2c.
- **The scrape shape on the iLO does not change.** Same OIDs, same port, same
  45-second budget; SNMPv3 adds one engine-discovery round trip per scrape
  session. Measured after the move rather than assumed, and recorded on #85.
- **ADR-0018's "cannot do SNMPv3 at all" is narrowed by this record**, not by
  a new fact about the UI: the agent answers v3 on the wire, and whether the
  firmware lets a user be created is the unchecked half. ADR-0018's
  replacement criterion — a TLS management interface, and SNMPv3 — stands;
  the SNMPv3 half of it now reads "a v3 user that can be created and
  persists".
- **The Net-SNMP package on `morpheus` is installed and disabled**, and this
  ADR is the reason it should stay disabled rather than be tried: enabling it
  beside bsnmpd is a second listener with a second credential, and replacing
  bsnmpd with it loses the pf MIB.
- **Reopened by:** pfSense growing USM users in its GUI; the switch's UI
  turning out to have a v3 user page, which reopens only #85's switch half;
  or the iLO poll changing segments under ADR-0033's own reopeners, at which
  point the "one poll crosses into the lab" argument goes and what is left
  is the weaker case made for the UPS card.
