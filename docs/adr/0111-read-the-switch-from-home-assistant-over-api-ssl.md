# ADR-0111: Read the switch from Home Assistant over api-ssl, and give it no write

**Status:** Accepted · 2026-11

## Context

The operator wants `neo`, the CRS326 on the switch LAN (`10.7.7.2`), in Home
Assistant through the core **MikroTik** integration, to show the switch's
health on a dashboard. [#1388](https://github.com/Gerrrt/HomeLab/issues/1388)
carries the work. Home Assistant runs on `trinity` (`10.0.99.40`,
Winterfell, 99).

Three earlier decisions stand in the way, and all three were deliberate:

- **The RouterOS API is off.** [`swap-the-switch.md`](../runbooks/swap-the-switch.md)
  §1.4 disables `api` and `api-ssl` with the other services nothing used.
- **Winterfell cannot reach the switch LAN.**
  [ADR-0025](0025-close-the-switch-lan-to-winterfell.md) put a logged block
  from `10.0.99.0/24` to `10.7.7.0/24` above Winterfell's catch-all. The one
  pass above it is SNMP from `10.0.99.20`.
- **The switch's management plane is TLS only.**
  [ADR-0041](0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md)
  turned plain `www` and SNMP v2c off, because the switch admin credential
  had crossed the wire in clear through the switch it protects.

[ADR-0035](0035-scope-the-99-to-20-rule-to-the-hue-bridge.md) set the shape
for a pass from Home Assistant to a device, and
[ADR-0097](0097-reach-the-lg-tv-from-home-assistant-and-wake-it-across-the-vlan.md)
and [ADR-0099](0099-control-the-homepods-from-home-assistant-and-leave-their-audio-out.md)
followed it. Read the code that would use the pass, write down the narrowest
rule that code needs, and put that rule above the segment's deny. The code
here was read in the pinned image, `2026.11.1`, on 2026-11-10, and the
connection code again on upstream `dev` the same day.

### What the integration does on a switch

The integration is `local_polling`. It polls every ten seconds over
`librouteros` 4.2.2, the RouterOS API, on `8728`, or on `8729` with TLS. It
creates:

| Platform | What it reads or does | RouterOS path |
| --- | --- | --- |
| `sensor`, `binary_sensor` | CPU, memory, temperature, uptime, each port's link state | reads |
| `update` | RouterOS and RouterBOARD versions | reads |
| `device_tracker` | Clients, from the wireless registration table or, failing that, the DHCP server's leases | reads |
| `switch` | Enables and disables a port | `/interface/enable`, `/interface/disable` |
| `select` | Sets a port's PoE mode | `/interface/ethernet/poe/set` |
| `button` | Reboots or shuts down the switch | system commands |

**Presence comes from nowhere on this device.** `update_devices` builds its
client list from wireless interfaces, then from DHCP leases. `neo` has no
radio and serves no DHCP: Kea on `morpheus` holds the leases, and the eeros
do the Wi-Fi. The tracker will be empty, and that is not a fault.

### The integration does not verify the switch's certificate

The config flow's last field is *Verify SSL certificate*. In the code it is
the switch that turns TLS on, and it verifies nothing
(`components/mikrotik/coordinator.py`, `get_api`):

```python
if entry[CONF_VERIFY_SSL]:
    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE
```

With the box off, the connection is plaintext `8728`, and `login_plain`
sends the password in the clear. With it on, the session is encrypted, but
anything that answers on the switch's address is accepted. The context is
also built with `ssl.create_default_context()`, not with Home Assistant's
`homeassistant.util.ssl`, so the estate CA in `REQUESTS_CA_BUNDLE`
([ADR-0086](0086-serve-the-ingest-ports-over-tls-under-the-estate-ca.md)) is
never consulted. Upstream `dev` has the same lines.

ADR-0086 declined `verify_ssl: false` for Home Assistant's token to
Prometheus, because that hands the token to whatever answers on the address.
The same objection applies here, and this ADR accepts it rather than
answering it. The reasons are under *Decision*.

## Decision

**One pass from `trinity` to `api-ssl` on `neo`, a user that can only read,
and TLS that encrypts without authenticating, recorded as a residual.**

| Where | What | Purpose |
| --- | --- | --- |
| `morpheus`, interface 99 | pass `10.0.99.40 → 10.7.7.2:8729/tcp`, *Allow HA API to LAN Switch*, **above** *Block access to the untagged LAN* | The API over TLS |
| `neo`, `/ip/service` | `api-ssl` on, with the `neo.matrix.elysium` leaf and `address=10.0.99.40/32`. Plain `api` stays off | One listener, one client |
| `neo`, `/user/group` | `homeassistant`, `policy=read,api,test` | No `write`, no `reboot`, no `policy` |
| `neo`, `/user` | `homeassistant` in that group, `address=10.0.99.40/32` | The credential works from `trinity` and nowhere else |

1. **The source is `trinity`, the destination is the switch, on one port.**
   This is ADR-0035's argument again. `10.0.99.20` keeps its SNMP pass and
   gains nothing, and nothing else on Winterfell reaches the switch LAN. The
   rule is stateful, so the switch needs no return pass. The switch LAN
   initiates nothing new.
2. **`api-ssl`, not `api`.** The plaintext API would put the password on
   Winterfell and the switch LAN in clear on every reconnect. That is the
   property ADR-0041 bought the CRS326 to remove. `api-ssl` uses the
   `www-ssl` leaf the switch already has, from the estate CA, with both
   SANs. No new certificate is issued.
3. **Read-only, enforced by the switch.** The group has `read`, `api` and
   `test`, the minimum the integration's documentation names. `test` is for
   its ARP ping, which a switch with no leases never uses, but the
   integration expects it. With no `write`, the switch refuses the port
   switches, the PoE selects and the restart and shutdown buttons, whatever
   Home Assistant offers. Those entities are disabled in the UI so that they
   do not sit there failing. A user with `write` would be a credential in
   Home Assistant's store that can disable any port, including port 1, the
   untagged link ADR-0041 keeps as the way back in. The operator did not ask
   for control, and it is not granted.
4. **Unverified TLS is accepted, as a residual.** No setting in the
   integration verifies the certificate, so the choice is between this, a
   local patch and no integration. This is acceptable for this credential
   and not for ADR-0086's token, for three reasons:
   - **To impersonate the switch, an attacker must be on the path.** Between
     `trinity` and `10.7.7.2` are `morpheus`, `neo`, and Winterfell's own
     layer 2, where a host could poison `trinity`'s ARP entry for the
     gateway. So the attacker must already own a host on the management
     segment, the router or the switch.
   - **What a stolen credential buys is small.** It reads the switch's
     configuration and counters. The group has no `sensitive` policy, so
     the SNMPv3 passphrases and other secrets stay hidden. The switch
     refuses the credential from any address but `10.0.99.40`. An attacker
     who already owns a host on Winterfell could also take that address,
     and would gain a read-only view of a switch they can already see
     traffic through.
   - **The password is not reused.** It is generated for this user and held
     nowhere else.

   A local patch, in the shape of `ring_push_guard`
   ([ADR-0101](0101-patch-ring-doorbells-push-parser-locally-until-upstream-ships-a-fix.md)),
   could verify against the bundle. It would mean carrying a whole core
   integration's coordinator through every Home Assistant bump, for a
   credential that can only read. Declined.
5. **The host is `neo.matrix.elysium`**, so the entry survives a renumbering
   in step with everything else that names the switch. The integration
   ignores the name for TLS, so this is about the address, not the
   certificate.
6. **The password lives where Home Assistant puts it**, in `.storage`. This
   is the deviation ADR-0035 recorded. It is generated with
   `make gen-secret`, typed into the switch and the config flow, and kept
   nowhere else. If it is lost, it is reset on the switch.
7. **Nothing is created by this ADR.** #1388 creates the pass, the service
   and the user, adds the integration and proves a port toggle is refused.
   [`connect-the-switch-to-home-assistant.md`](../runbooks/connect-the-switch-to-home-assistant.md)
   is the procedure. Until then, [`network.md`](../network.md) and
   [`security.md`](../security.md) carry the pass as decided.

## Alternatives considered

- **Sensors from Prometheus instead.** `homelab_rack.yaml` already reads the
  UPS through Prometheus with the reader token, and Prometheus scrapes `neo`
  over SNMPv3. REST sensors on the same pattern would need no API, no
  credential and no pass. The operator chose the integration. This remains
  the fallback if the residual in decision 4 is reopened.
- **Plain `api` on `8728`.** It is the integration's default, and it is
  declined in decision 2.
- **A user with `write`.** Declined in decision 3.
- **A local patch that verifies.** Declined in decision 4.
- **Presence from this integration.** Not available on a switch. If
  presence is wanted, it comes from Kea's leases, the way `eero.yaml` reads
  DHCP renewals from Loki. That is a separate decision.

## Consequences

- **The switch LAN takes its second pass from Winterfell.** ADR-0025's
  posture holds: a block, with named passes above it. Its table is the state
  on 2026-09-06 and is not edited. `docs/firewall-claims.yaml` records only
  wholesale reach, so it does not change, and `make check-firewall` stays
  clean.
- **The switch serves a second TLS listener on the same leaf.** It has the
  same 825-day lifetime and the same diary entry in
  [`schedule-maintenance.md`](../runbooks/schedule-maintenance.md). A leaf
  reissued for `www-ssl` must also be rebound to `api-ssl`.
- **A rebuild of the switch turns the API off again.** `swap-the-switch.md`
  §1.4 disables `api-ssl` on a reset device, which is right for a fresh
  switch. It names the runbook here as the step that turns it back on.
- **Home Assistant gains a ten-second poll of the switch.** The integration
  does not set a slower interval. The CRS326 is not the MokerLink that
  locked up under polling, and the switch's CPU is one of the sensors this
  adds.
- **Home Assistant parses replies from the switch.** The switch is
  infrastructure, more trusted than Home Assistant, so this is a smaller
  exposure than the Hue bridge or the TV.
- **Reopened by:** an integration release whose TLS option verifies, which
  turns decision 4 from a residual into a setting. Also by the switch
  gaining a role that serves DHCP or Wi-Fi, which gives the tracker
  something to read. And by a request for control, which needs its own
  answer about port 1.
