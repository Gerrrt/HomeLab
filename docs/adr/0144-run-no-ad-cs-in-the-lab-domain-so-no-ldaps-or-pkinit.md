# ADR-0144: Run no AD CS in the lab domain, so no LDAPS or PKINIT

**Status:** Accepted · 2026-11 · within
[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
and [ADR-0083](0083-give-the-lab-domain-its-deliberate-weaknesses-as-switchable-tags.md)

## Context

A read-only audit of `leviathan` (2026-11-13 to 2026-11-26) found that neither
DC has a certificate, and the repository says nothing about it. On
2026-11-27 both DCs read the same:

- `LocalMachine\My` and the NTDS store are empty, and the AD CS role is not
  installed on either. The Configuration partition holds no enrollment
  service, no AIA CA and an empty `NTAuthCertificates`, so there is no
  enterprise CA anywhere in the forest.
- `636` and `3269` listen with nothing to serve. Directory Service event 1220
  says LDAP over SSL is unavailable.
- KDC events 19 and 29 (no certificate for smart-card logon and PKINIT) and
  CertEnroll event 86 (no enrollment policy) are logged at each boot. In the
  30 days to 2026-11-27 that was 10 and 6 on `leviathan`, and 4 and 6 on
  `bahamut`.

Only one thing in the repository depends on this, and it already plans
around it:
[`build-the-bloodhound-guest.md`](../runbooks/build-the-bloodhound-guest.md)
says `bloodhound-ce-python` and `netexec` cannot collect, because signing
refuses plain LDAP and `636` has no certificate. SharpHound on a domain host
is the collector, and the `unsigned_ldap` switch of
[ADR-0141](0141-switch-three-of-the-dcs-shipped-defaults-and-keep-dsheuristics.md)
lets the Linux collectors in when an exercise needs them.

ADR-0141 also relies on the missing CA. With signing enforced and no AD CS,
coercing a DC has no complete relay path. ADR-0083's negative test, a plain run
then `verify.yml` with no path to Domain Admin, holds only while that is true.

## Decision

**The lab domain runs no AD CS.** There is no enterprise CA, so the DCs get no
LDAPS certificate and the KDC gets none for PKINIT. LDAP stays on `389`,
signed and sealed, as Server 2025 ships it.

**The certificate events are expected.** Directory Service 1220, KDC 19 and 29,
and CertEnroll 86 at a DC's boot are noise by this decision, not a finding.

**`verify.yml` holds the domain to it.** On every DC, it fails if the
Configuration partition holds an enrollment service or a CA in
`NTAuthCertificates`.

**An AD CS exercise is a new decision.** ESC1 to ESC8 are the techniques AD CS
would bring, and they are worth an exercise of their own. They come in under
ADR-0083's reopen clause: a member server for the CA, switchable templates,
and a plain run that removes them, so that the negative test still holds.
Until that ADR exists, no CA is installed.

## Alternatives considered

- **Install an enterprise CA for LDAPS.** It would give the DCs a certificate
  and let the Linux collectors use `636`. It would also add the whole ESC
  surface outside the switch model, including web enrollment relay, which
  completes the coercion path ADR-0141 says does not exist. A plain run would
  then no longer be the negative test.
- **Self-signed certificates on the DCs, for LDAPS only.** This gives `636` a
  certificate with no CA. Nothing in the lab needs LDAPS: the `unsigned_ldap`
  switch already lets the Linux collectors in. The certificates would also
  need renewal, which nothing here would own.

## Consequences

- **`636` and `3269` stay open with nothing behind them.** That is how a DC
  ships without a CA. They are in the §10 port table and are not removed
  (§0).
- **No smart-card logon, no PKINIT, and no shadow-credential authentication
  against the KDC.** `msDS-KeyCredentialLink` can still be written, but the
  KDC cannot complete a PKINIT logon with it while it has no certificate. A
  future AD CS ADR changes that, and has to say so.
- **A future audit should not raise the missing certificate.** It should check
  that `verify.yml`'s "no AD CS" check still passes.
