# ADR-0132: Turn TrueNAS Connect off on `smaug`

**Status:** Accepted · 2026-11 · amends
[ADR-0047](0047-collect-smaug-smart-through-a-root-cron-and-the-textfile-collector.md),
deciding the egress question its fourth decision left open

## Context

[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md) keeps
CasaBonita terminal outward: more trusted segments reach in, and nothing on
VLAN 40 starts a connection into the estate. `network.md` gives the segment
the internet, and `smaug` one exception inward, `Allow NUT from smaug` to its
own gateway.

TrueNAS Connect is a connection `smaug` starts to the vendor's cloud. It is
internet egress, so it does not break ADR-0016, as ADR-0047 noted. What it
is instead is a vendor account registered to the appliance that holds the
backup datastore, which this repository neither configures nor tests. It was
on from the first boot, and emailed the faulted Exos's alert to the
operator's mailbox 37 s after it fired on 2026-09-20
([`replace-the-nas-disk.md`](../runbooks/replace-the-nas-disk.md)).
ADR-0047 named it "a second channel" and left "whether `smaug`
should keep initiating a connection to TrueNAS Connect at all" undecided.

A read-only audit of `smaug` on 2026-11-13 found it still enabled and
registered: `tn_connect.config` read `enabled: true, status: CONFIGURED`, and
the box held a `truenas_connect_*` certificate for a `truenas.direct` name,
valid to 2026-12-15. `network.md` and `security.md` did not list it.

What it bought in September no longer needs it. The faulted leaf it caught
was invisible to Prometheus at the time, and has not been since §6.8 of
[`build-the-nas.md`](../runbooks/build-the-nas.md) was done on 2026-10-02:
`ZpoolVdevNotOnline` and `ZpoolVdevErrors` page per leaf, `SmartDriveBadSectors`
and its siblings page per disk since §6.4, and `ZpoolNotOnline` covers the
pool. Each of them pages a phone. TrueNAS Connect reached a mailbox.

## Decision

**TrueNAS Connect is turned off on `smaug`, and the registration is removed.**
`smaug` then starts no connection to anything but its gateway's NUT server,
its time and name servers, and the registries its image pulls come from.
[`build-the-nas.md`](../runbooks/build-the-nas.md)
§6.12 is the procedure and the proof.

**TrueNAS's own alerts stay where they are: the web UI.** No alert service is
configured in its place. The paging path for this host is the one ADR-0047
chose, Prometheus over the textfile collector, with the estate's rules, tests
and silences behind it.

## Alternatives considered

- **Keep it and record it.** Add it to `network.md`'s outbound list and
  accept the residual. Rejected: it duplicates a path that already pages,
  and what it adds is an untested vendor channel into the appliance that
  holds the backup datastore.
- **Mail the alerts another way**, with TrueNAS's SMTP alert service.
  Rejected for ADR-0047's reason: it is a second alerting path, with none of
  the estate's rules, tests or silences behind it.

## Consequences

- **No vendor account is registered to `smaug`.** The documents never
  recorded one, and now there is none to record.
- **Some TrueNAS alert classes now reach only the web UI**: a failed periodic
  snapshot task, a failed cron job, a scrub that did not run. The ones that
  matter for data loss have Prometheus counterparts. The cron jobs that feed
  the textfile collector have staleness rules (`SmartStateStale`,
  `ZpoolVdevStateStale`, `CertExpiryStateStale`). A failed snapshot task has
  none, and is the gap to watch. Reopen this if it bites.
- **The `truenas_connect_*` certificate goes with the registration.** The UI
  keeps its self-signed certificate, which `collect-cert-expiry.sh` already
  watches, and is reached from Hicks on `443`, as `network.md` says.
- Turning it back on is a new ADR, because it is a vendor channel into the
  backup datastore's host.
