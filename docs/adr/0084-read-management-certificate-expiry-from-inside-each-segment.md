# ADR-0084: Read the management consoles' certificate expiry from inside each segment

**Status:** Accepted · 2026-10

## Context

Four management consoles serve self-signed certificates that nothing watched
([#857](https://github.com/Gerrrt/HomeLab/issues/857)):

| Console | Where | Who can reach it |
| --- | --- | --- |
| pfSense GUI | `morpheus`, `10.0.99.1:443` | Hicks. "Block HTTPS to pfSense" on the Winterfell interface is an explicit rule |
| iLO | `shiva`, `10.0.30.10:443`, VLAN 30 | Hicks. VLAN 99 passes SNMP to it and nothing else ([ADR-0033](0033-keep-the-ilo-on-the-lab-segment.md)) |
| Proxmox UI | `Saruman`, `10.0.30.110:8006` | Hicks and `phoenix` |
| TrueNAS UI | `smaug`, `10.0.40.30:443` | Hicks |

Each expires on its own schedule. For example, the pfSense GUI's certificate
was regenerated on 2026-09-28 and runs out on 2027-04-16. Until now, the first
sign of an expiry would have been a browser warning on the day someone needed
the console.

The estate already watches certificate expiry. `TlsCertificateExpiringSoon`
reads `probe_ssl_earliest_cert_expiry` off a blackbox handshake (#91). That
needs the monitoring host to complete a handshake, and it can reach none of
these four. Probes for the iLO and pfSense were written and left disabled in
`targets/blackbox.yaml`, waiting on a firewall pass each.

Three options were weighed:

1. **A blackbox probe per console, with one firewall pass each from
   `10.0.99.20`.** This reuses the existing rules unchanged. But each pass is a
   segmentation decision, and the comment above the disabled probes says so.
   The pfSense one gives the machine every agent pushes to a path to the
   firewall's login page. The iLO one undoes the part of ADR-0033 that kept
   VLAN 99 to SNMP. Four passes would be opened for a date that changes about
   once a year.
2. **Read the expiry from inside each console's own segment, from a host that
   can already reach it, and ship it as a textfile gauge.** No new pass is
   needed.
3. **A calendar entry per certificate.** This is cheap, but it is exactly the
   remembering that the estate is built to avoid, and nothing would notice a
   certificate reissued early and the entry left stale.

## Decision

**Option 2.** `scripts/collect-cert-expiry.sh` makes a TLS handshake with each
console from a host already able to reach it. It writes
`homelab_cert_expiry_timestamp_seconds{endpoint, host}` and
`homelab_cert_checked{endpoint, host}` into that host's textfile directory.

| `endpoint` | Read from | Runs as |
| --- | --- | --- |
| `pfsense-ui` | morpheus itself, `127.0.0.1:443`, over the ssh `make gateway-state` already makes | that target, every 15 minutes |
| `pve-ui` | Saruman itself, `127.0.0.1:8006` | `homelab-cert-expiry.timer`, daily |
| `ilo-ui` | Saruman, `10.0.30.10:443`, which is the same VLAN, so no pf rule is crossed | the same timer |
| `truenas-ui` | smaug itself, `127.0.0.1:443` | a root cron job, the [ADR-0047](0047-collect-smaug-smart-through-a-root-cron-and-the-textfile-collector.md) mechanism |

The decisions inside it:

- **The handshake, not a file.** This is the principle the blackbox rules
  already follow. What matters is the certificate being served, and a file can
  be replaced while the daemon still holds the old one. On pfSense, the route
  to the file goes through `config.xml`, and a search of that file has printed
  a private key into a transcript before. `s_client` does not verify, so a
  self-signed or expired certificate still reports its date.
- **The parsing happens on Linux.** The probe is POSIX `sh` and returns
  openssl's `notAfter=` line, and GNU `date` turns it into epoch seconds on the
  collecting host. morpheus is FreeBSD and its `date` is not GNU.
- **A failed read is not an expiry.** An unread console writes
  `homelab_cert_checked 0` and no expiry sample, the
  `homelab_ddns_record_checked` pattern. `ManagementCertificateUnchecked`
  fires after six hours. Without it, a console that refused the handshake would
  make the expiry alerts quietly impossible.
- **The rules are their own.** `ManagementCertificateExpiringSoon` (30 days,
  warning) and `ManagementCertificateExpiryImminent` (7 days, critical) mirror
  the blackbox pair's tiers and reasons, aggregated `min by (endpoint, host)`.
  An inhibit in `alertmanager.yaml` makes a certificate page once.
  `CertExpiryStateStale` watches the file's mtime, as `SmartStateStale` does.
- **The old-TLS fallback.** A handshake that fails is retried once at
  `SECLEVEL=0`, because iLO 4 may not meet OpenSSL 3's default level. Nothing
  is sent and nothing read is trusted except a date, so this weakens nothing.

## Consequences

- No firewall rule changes, and `docs/firewall-claims.yaml` does not move.
- The two disabled blackbox probes stay disabled. This collector replaces them
  for **expiry only**. Whether the iLO or pfSense GUI is *reachable* from the
  monitoring host remains the separate decision their comment describes, and
  this ADR does not take it.
- Two of the four gauges need someone at a console to start them. Saruman's
  collector is installed from the Mac with
  `make install-agent-collectors AGENT=root@10.0.30.110 ARGS="--only cert-expiry"`, because VLAN 99 cannot
  reach VLAN 30. smaug's is a cron job added in TrueNAS's UI
  ([`build-the-nas.md`](../runbooks/build-the-nas.md) §6.10). The pfSense one
  starts with the next `make gateway-state` after merging.
- Resolution is a day for three of the four. Against a 30-day warning this
  costs nothing.
- If a console moves to a certificate the estate's CA or step-ca issues and the
  monitoring host is ever allowed to reach it, a blackbox probe is better
  because it also proves reachability. Its row here should then be retired, not
  kept as a second reading.
