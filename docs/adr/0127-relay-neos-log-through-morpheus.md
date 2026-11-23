# ADR-0127: Relay `neo`'s log through `morpheus`

**Status:** Accepted · 2026-11

## Context

`neo`, the CRS326 that every VLAN crosses, keeps its log in RAM only. The
read-only audit of 2026-11-13 found every logging rule pointing at `memory`,
1,000 lines deep, and the `remote` action still at `0.0.0.0`. Home
Assistant's API session logs in and out often enough to fill that buffer
([ADR-0111](0111-read-the-switch-from-home-assistant-over-api-ssl.md)), so the
window is short even without a reboot, and a reboot empties it. Who logged in
to the core switch, what they changed and which links flapped is known only to
the switch, and only for a while.

Three facts bound the answer:

- **The estate's syslog intake takes one sender.** Alloy on `prometheus`
  listens on `6514/tcp` with TLS, and its `ca_file` is `morpheus`'s own
  certificate, so no other client certificate passes
  ([#1049](https://github.com/Gerrrt/HomeLab/issues/1049),
  `stacks/observability/alloy/syslog.alloy`). The UDP listener was removed on
  purpose: a host on VLAN 99 could forge any source address over UDP.
- **RouterOS cannot meet that listener.** MikroTik documents
  `remote-protocol` as `udp`, `tcp` or `tls`, and documents that TCP and TLS
  work only with the CEF format; syslog format is always sent over UDP. The
  documented TLS settings verify the server and offer no client certificate.
  `neo` cannot present `morpheus`'s pinned leaf, or any client leaf.
- **The switch LAN has no path into Winterfell.** It blocks every VLAN and
  passes only DNS, NTP and the internet
  ([#229](https://github.com/Gerrrt/HomeLab/issues/229)). Winterfell's own
  passes into it are named one by one
  ([ADR-0025](0025-close-the-switch-lan-to-winterfell.md)).

`morpheus` already runs syslog-ng. It receives pfSense's own syslog on
`127.0.0.1:5140` and relays it over the pinned TLS connection
([`ship-firewall-logs.md`](../runbooks/ship-firewall-logs.md) §3). It is also
`neo`'s gateway, at `10.7.7.1`, on the segment `neo` lives on.

## Decision

**`neo` sends its log over UDP to syslog-ng on `morpheus`, on the switch LAN.
syslog-ng stamps the lines as `neo`'s and relays them over the TLS connection
it already holds.**

1. **On `neo`:** set the `remote` action to `10.7.7.1`, port `5514`, UDP,
   `remote-log-format=syslog`, from `src-address=10.7.7.2`. Add one logging
   rule per topic for `info`, `warning`, `error` and `critical`, with action
   `remote`. A rule that lists several topics matches only lines carrying all
   of them, so each topic needs its own rule. The `memory` rules stay, so the
   console still shows the log when `morpheus` is the suspect.
2. **On `morpheus`, one pass:** on the switch LAN interface (`igc0`),
   `10.7.7.2 → 10.7.7.1` UDP `5514`, above the per-VLAN blocks, beside the DNS
   and NTP passes to the gateway. It goes to the firewall's own address on the
   switch LAN and to nothing else. **No pass into or out of Winterfell is
   added.**
3. **In syslog-ng, a second source and log path:** a `network()` source bound
   to `10.7.7.1` on UDP `5514` with `flags(no-hostname)`, a rewrite that sets
   `HOST` to `neo`, and the existing `d_alloy_tls` destination. Port `5514`,
   not `514`: pfSense's own `syslogd` already holds `*:514`.
4. **In Alloy, a second sender rule:** connection address `10.0.99.1` **and**
   message hostname `neo` give `host="neo"`. It sits after the `morpheus` rule
   and overrides it. Every other line from `10.0.99.1` stays `host="morpheus"`.
   A line with `host="neo"` also takes a fixed `app="routeros"` instead of the
   tag it carries. Today `app` comes from the tag on every line, and the
   filterlog and Suricata rules in `security.rules.yaml` select by `app` alone,
   so without this a line on the `neo` path tagged `filterlog` would be read as
   the firewall's.
5. **In Loki, the firewall's rules name their host.** Every selector in
   `security.rules.yaml` that reads `app="filterlog"` or `app="suricata"` gains
   `host="morpheus"`, `FirewallLogsStopped` and the Suricata absence rule
   included. This is a second guard behind step 4: either one alone keeps a
   `neo` line out of the firewall's alerts and out of their absence checks.

The procedure belongs in a new section of
[`ship-firewall-logs.md`](../runbooks/ship-firewall-logs.md). The order is the
Loki rules and Alloy first, then syslog-ng, then the pass, then `neo`. That way
the first line arrives at a sender rule that names it and fixes its `app`, and
no firewall rule can read it, instead of it being stored as `morpheus`'s.
Steps 4 and 5, and the `check_syslog_senders.sh` cases below, are
prerequisites: `neo` is not pointed at the relay until they are deployed and
the cases pass.

### Why trusting a message hostname is safe here and nowhere else

`syslog.alloy` refuses the message's own hostname, because before #844 any
sender could write `host="morpheus"` with it. That reasoning still holds for
what senders write. Here the hostname is written by `morpheus`'s syslog-ng,
not by the sender. The `neo` source takes `flags(no-hostname)`, so it never
reads one from an incoming line, and a rewrite sets `neo`. pfSense's own
source is generated by the package and cannot take that flag, so its log path
gets a rewrite of its own that sets `morpheus`. Each path writes its own name,
and only the `neo` path can write `neo`. To get `host="neo"` onto a line, a forger would have to deliver
it over the pinned TLS connection, which only `morpheus` holds.

### Why the UDP hop is acceptable

The forgery that #1049 removed was a VLAN 99 host claiming `10.0.99.1` on a
segment the firewall does not stand between. This hop is different:

- The source address `neo` uses can be claimed only on the switch LAN.
  pfSense's generated antispoof rule drops a switch LAN source address that
  arrives on any other interface. That rule was confirmed on the live ruleset
  on 2026-11-23.
- The switch LAN is port 1's untagged VLAN, and its only addresses are
  `morpheus` and `neo`. A host that could put a frame on it would already
  hold `neo`'s bridge, which matters far more than its log.
- The worst a forged line can do is put false lines under `host="neo"`. It
  cannot reach `host="morpheus"`, and with steps 4 and 5 it cannot reach the
  firewall's alerts either: its `app` is fixed, and those rules read only
  `host="morpheus"`. Without them it could, because those rules select by
  `app` alone today.

## Considered and rejected

- **A UDP listener on `prometheus` for `neo` alone.** It would bring back the
  forgeable path #1049 closed, and it needs the switch LAN's first pass into
  Winterfell.
- **TLS straight to `prometheus` in CEF format.** RouterOS's TLS offers no
  client certificate, so this needs a second listener with no client
  authentication, plus the same new pass into Winterfell. CEF framing into
  `loki.source.syslog` has also never been measured.
- **Logging to `neo`'s own flash.** Only 2.9 MiB of 16 MiB is free, and that
  space is what the next RouterOS upgrade needs
  ([`schedule-maintenance.md`](../runbooks/schedule-maintenance.md)). A log on
  the device being investigated is also the wrong place for it.
- **Leaving it in RAM.** That is the gap the audit found.

## Consequences

- **The switch LAN gets a third pass to its gateway.** These current-state
  documents name only DNS and NTP today, and change in the PR that applies
  this ADR:
  - [`network.md`](../network.md), its `[^lan]` footnote and the LAN notes;
  - [`security.md`](../security.md)'s switch LAN paragraph;
  - [`architecture.md`](../architecture.md);
  - `firewall-claims.yaml`'s `igc0` comment.

  The claims check reads segment reachability, and the firewall's
  own-address check proposed beside it covers only SSH, HTTP and HTTPS, so
  neither fails on a UDP pass to `10.7.7.1`.
- **`neo`'s log reaches Loki only while `morpheus` and its syslog-ng are up.**
  That is the outage in which the log matters most. The `memory` rules stay
  for that reason. RouterOS over UDP holds nothing back while the relay is
  down, so the gap is permanent.
- **Lines carry receive time**, as `morpheus`'s already do
  (`use_incoming_timestamp = false`). Two hops on one segment and one hop on
  VLAN 99 add milliseconds.
- **Alerting becomes possible, and is a separate change.** The applying PR
  should add two Loki rules:
  - an `account` login from anywhere but the switch LAN and desktop-02;
  - an absence rule on `host="neo"`. Home Assistant's API logins were
    expected to give the stream a heartbeat, but on 2026-11-23 they came once
    in four hours. So `neo` logs a line every five minutes from a scheduler
    entry, and silence means the path is broken.

  `scripts/check_syslog_senders.sh` gains cases proving that:
  - a line from `10.0.99.1` with hostname `neo` gets `host="neo"`;
  - the same hostname from any other address is dropped;
  - a `neo` line tagged `filterlog` or `suricata` gets `app="routeros"`, and so
    neither raises a firewall alert nor keeps `FirewallLogsStopped` quiet.
- **Volume is unmeasured.** Home Assistant's login and logout pairs will be
  most of it. Measure a day of it, as
  [`ship-firewall-logs.md`](../runbooks/ship-firewall-logs.md) §8 does for
  the firewall. If the pairs dominate, drop them in Alloy by user and
  address, not on the switch, so a login by anyone else is never filtered.
- **A restore of `morpheus` has to bring syslog-ng back, and no runbook step
  says so today.** The TLS files sit outside `config.xml`, and
  [`ship-firewall-logs.md`](../runbooks/ship-firewall-logs.md) §3 says to
  copy them again after a restore, but
  [`restore-the-firewall.md`](../runbooks/restore-the-firewall.md) has no step
  that does it or checks it. Rebuilt from that runbook alone, `morpheus` comes
  back with both log streams down. The applying PR adds a step to
  `restore-the-firewall.md` that restores the TLS files and both syslog-ng
  sources, and a §4 check that `host="morpheus"` and `host="neo"` are both
  arriving in Loki.
