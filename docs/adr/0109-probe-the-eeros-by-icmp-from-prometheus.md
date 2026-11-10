# ADR-0109: Probe the eeros by ICMP from `prometheus`

**Status:** Accepted · 2026-11 · adds to the lease check #1228 built, and
corrects a premise `targets/blackbox-latency.yaml` stated about ICMP

## Context

The eight eero units are the house's Wi-Fi: three on Hicks, three on Skids,
two on Degens, bridged, each on a Kea reservation below its segment's pool
([#1228](https://github.com/Gerrrt/HomeLab/issues/1228)). Since 2026-10-21
Home Assistant shows each one as connected when Kea's log has a lease renewal
from its address in the last two hours, and `eero_offline` tells the household
when one stops (`packages/eero.yaml`). That costs no firewall row and no eero
cloud, which [ADR-0019](0019-read-device-joins-from-the-dhcp-server.md)
declined. Its cost is time: the eeros renew about hourly, so a unit that dies
is noticed up to two hours later.

Issue #1228 left the faster check as a decision of its own, for two reasons:

- **No path.** Winterfell's catch-all reaches no segment
  (`docs/firewall-claims.yaml`). `prometheus` has no pass into Hicks, Skids or
  Degens, and Degens has none from anywhere.
- **The capability.** `targets/blackbox-latency.yaml` chose TCP over ICMP
  (#166), partly because "an `icmp` prober needs CAP_NET_RAW", which
  blackbox-exporter gave up with `cap_drop: [ALL]` (#187).

The eeros have no local API and serve nothing on a port the house uses, so
ping is the only question this host can ask them.

The capability premise was checked on 2026-11-10 and is wrong. The pinned
`prom/blackbox-exporter` v0.29.1 ran with `--cap-drop ALL`,
`no-new-privileges`, uid 65534 and a read-only root, with one `icmp` module.
Inside it, `CapEff` read `0000000000000000` and
`net.ipv4.ping_group_range` read `0 2147483647`, Docker's default for a
container. An echo to `10.0.99.1` and to `10.0.99.20` returned
`probe_success 1`. As a non-root user, blackbox opens an unprivileged ICMP
datagram socket (its log names a `udp` socket), and the kernel allows that to
any gid in the range. An echo to `10.0.50.11` and to `10.0.20.11` timed out,
as it should with no pass in place.

## Decision

1. **An `icmp_echo` module and a `blackbox-eero` job.** Every 60 s, one echo
   request to each of the eight reserved addresses, from the exporter on
   `prometheus`. The exporter keeps every capability dropped. The targets live
   in `targets/blackbox-eero.yaml`, and the job builds each unit's `name`
   (`eero Hicks 11`) to match its Home Assistant entity.
2. **`EeroUnreachable` at warning, `category: availability`.** It fires on
   five failed probes in a row and routes to `default`. `validate.sh` pins
   that route. The job is separate so `EndpointUnreachable`, which is critical
   and routed to `urgent`, never sees these targets. A Wi-Fi access point down
   is a job for the morning, not a page.
3. **One Winterfell row:** a pass from `10.0.99.20` to a new alias `eeros`
   (the eight addresses), ICMP `echoreq` only, above the *Block access to …*
   rows. The replies return on state. It is one row, not one per segment,
   because the source, the protocol and the reason are the same for all
   eight.
4. **Home Assistant's lease check stays.** It is the second, independent
   source: it reads Kea, not the network path. When the two disagree, the
   question is the path, not the unit.

## Alternatives considered

- **The eero cloud.** Declined by ADR-0019, for reasons this does not change.
- **pfSense's ARP table over SNMP.** It needs no new row, because SNMP to the
  firewall already exists. But an entry outlives its device by up to
  FreeBSD's 20-minute ARP age, and reading the table means regenerating
  `snmp.yaml` with a walk that exports the MAC of every device in the house
  into Prometheus. It is slower than the probe and discloses more.
- **A TCP probe.** No port on an eero is documented as listening. A port
  found by scanning would be an undocumented one that a firmware update could
  close.
- **Probing only Hicks and Skids.** It keeps any new row out of Degens. That
  was weighed and not taken: the row leaves the most trusted segment, carries
  echo requests and nothing else, and gives Degens no way to start anything.
  The two guest eeros fail the same way as the rest.
- **Shorter `for:`.** At 60 s a single lost echo is ordinary on Wi-Fi gear
  under load, and a unit reboots in a few minutes. Five minutes is the same
  window `EndpointUnreachable` uses.

## Consequences

- **The first rows into Hicks and Degens from Winterfell.** They are host-
  and protocol-scoped, so `firewall-claims.yaml` is unchanged: the
  catch-all still reaches nothing. `network.md` and `security.md` list the
  row with the other named passes.
- **The capability argument in `blackbox-latency.yaml` no longer holds.**
  That file now says so. Its choice of TCP stands on its other reason: a
  TCP connect measures what a game or call experiences, and ISPs deprioritise
  ICMP.
- **Not yet verified: that an eero answers an echo request.** Winterfell's
  blocks do not log, so the 2026-11-10 timeouts cannot tell a dropped echo from
  an ignored one. The first deploy step checks it: create the row, ping one
  unit from `prometheus`, and only then deploy the job. If the eeros do not
  answer, the row is removed and this ADR is superseded.
- **Order matters on deploy.** Without the row, all eight targets read 0 and
  `EeroUnreachable` fires eight times. The rule's description says that eight
  firing together points at the row before the units.
- **Glance shows them.** Its *Estate* and *Uptime* widgets read
  `probe_success` from every job, as they already do for the latency and DNS
  probes. So the eight units appear by name on the household and homelab
  pages, and count toward the probes-down figure.
- **An eero that is up but unreachable from 99 looks down.** That is a
  firewall or path fault, worth knowing about, and the lease check
  distinguishes it.
- **Reopened by:** eero shipping a local API, a unit that stops answering
  echo after a firmware update, or the household moving off eero.
