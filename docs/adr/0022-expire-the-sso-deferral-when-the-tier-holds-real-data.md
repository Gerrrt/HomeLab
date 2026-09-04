# ADR-0022: Expire the SSO deferral when the tier holds real data

**Status:** Accepted · 2026-09

## Context

[ADR-0008](0008-place-services-by-data-trust.md) defers Authelia knowingly and
records why: two users, no external exposure, and *"per-application
authentication with TOTP is proportionate."* What it does not record is when the
deferral stops being the right answer. A deferral with no end condition and a
decision never to do the thing are the same document six months later, and by
then nobody remembers which one was meant.

The gap today is genuinely small, and it is worth being precise about why rather
than taking it on faith. **Grafana is the only authenticated service the estate
runs.** It has one account; anonymous access and sign-up are off and the password
comes from SOPS (`stacks/observability/compose.yaml`); and the Hicks tab reaches
`10.0.99.20` on `3000` and nothing else on that host, above a logged *Block
access to Winterfell*. Nothing untrusted reaches it at all.

That stops being the shape of the problem the moment ADR-0008's sensitive tier
exists. [#102](https://github.com/Gerrrt/HomeLab/issues/102) puts Vaultwarden,
Immich, Paperless-ngx and Home Assistant on Winterfell — by ADR-0008's own trust
argument, the four things in the estate most worth a second factor, which is
exactly why the argument for deferring gets weaker as the build gets closer
rather than staying where it was.

**The premise that does not survive checking is the third one.** ADR-0008 offered
per-application TOTP *in place of* SSO. Read against the services that actually
authenticate a person, that substitute exists for half of them:

| Service | Its own second factor |
| --- | --- |
| Vaultwarden | TOTP and WebAuthn, built in |
| Paperless-ngx | TOTP and WebAuthn, through `django-allauth` |
| Home Assistant | TOTP, built in |
| Immich | **None.** Upstream has declined it repeatedly and points at OAuth — which in this house means Authelia or Authentik |
| Grafana OSS | **None, in any edition.** "Grafana and the Grafana Cloud portal currently do not include built-in support for multi-factor authentication"; the documented route is an external identity provider |
| AdGuard Home | **None.** One admin account, password only |

ntfy and Homepage are left out of that table because neither authenticates a
household identity — ntfy has basic auth on a topic, Homepage has no login at
all.

Two things follow, and both cut against the deferral as written. **For Grafana
and Immich an identity provider is not a heavier alternative to per-application
TOTP — it is the only route to a second factor there is.** And Grafana is the one
of the six that is deployed *today*, so the substitute ADR-0008 named has never
existed in this estate. The line it points at in `security.md` is not a gap
awaiting a decision; for the only service it currently describes, it is a
standing property.

AdGuard Home is the third, and its data is easy to under-rate. Under
[ADR-0010](0010-keep-the-resolver-on-the-gateway.md) Unbound forwards to it, so
its query log is the whole household's browsing history — without per-client
attribution, which is the one mitigation, and which ADR-0010 arrived at for
unrelated reasons.

Finally, `SECURITY.md` records the monitoring host's unencrypted disk and swap as
an accepted residual, measured on `prometheus`. **The mini PC is not bought**, so
full-disk encryption there is a build-time choice rather than a retrofit — and a
password vault behind one factor on an unencrypted disk is a different bet from a
metrics dashboard behind one factor on the same disk. The two decisions belong in
the same sitting, which is the observation
[#103](https://github.com/Gerrrt/HomeLab/issues/103) was filed on.

## Decision

**The deferral stands, and it now ends on a stated condition.** ADR-0008 is
neither superseded nor amended — [ADR-0001](0001-record-architecture-decisions.md)
keeps it immutable, and its SSO paragraph gets a forward pointer to this document
and nothing else. Everything it decided about placement holds.

**The expiry is a state, not a date.** Nothing about this risk is driven by the
calendar, so a date would be arbitrary, and an arbitrary date is a deadline
everyone learns to move. Three triggers, whichever comes first:

1. **The sensitive tier holds real data** — the first real credential in
   Vaultwarden, the first real photo in Immich, or the first real document in
   Paperless-ngx. Seeded test entries do not count. Deciding *before* the data
   arrives rather than after is the whole point.
2. **Any of it becomes reachable from outside the house**, by any means,
   including a VPN terminating on 99. This is ADR-0008's *no external exposure*
   premise made testable.
3. **A third person gets an account on any of it.** ADR-0008's *two users*
   premise, likewise. That ADR already says the household growing should force a
   revisit; this makes it a trigger rather than an aspiration.

**Expiry means a decision gets recorded, not that Authelia gets deployed.** At
the first trigger, a new ADR either stands an identity provider up or re-accepts
the deferral with its reasons. Re-accepting is a legitimate outcome — it is what
happened here once already. What this document removes is the third option, which
is arriving at the same place by never looking.

**Three things are due before #102's tier holds anything.** They are the floor
the deferral rests on, and none of them is automatic:

- **TOTP enrolled at first login on Vaultwarden, Paperless-ngx and Home
  Assistant.** This is precisely what ADR-0008 claims is in place of SSO, and all
  three ship with it off.
- **Immich and AdGuard Home named in `security.md` as unable to carry a factor
  at all**, rather than folded into a single line about MFA that reads as uniform
  and is not.
- **The mini PC's disk encryption decided at build time**, on #102, rather than
  inherited from `prometheus` by default. Recorded here; not decided here.

**Grafana does not wait for the tier and its gap does not close on this
timetable.** No edition of Grafana OSS can carry a second factor, so its only
path is the same identity provider, and until one exists "no MFA" is true of it
permanently rather than pending. `docs/security.md` now says that instead of
implying otherwise.

## Consequences

- **#102 cannot be finished without meeting the floor or explicitly declining
  it.** A deferral with a trigger is something a reader can check the estate
  against; one without is a sentence.
- **The decision now lands before hardware is bought rather than after data is
  loaded.** Authelia in front of Immich is a compose-file change on a box with
  nothing on it. The same change under a live photo library and a working vault
  is a migration, a re-enrolment and a household outage.
- **"No MFA on the internal services" turns out not to be one gap.** Three
  services can close it themselves today and three cannot close it at all. The
  single line in `security.md` flattened the distinction that decides the answer,
  and the flattening is what made the deferral look cheaper than it is.
- **The cost of Authelia is unchanged and still real.** It puts one container in
  the authentication path of everything, and its failure is a house-wide login
  outage that looks like every service breaking at once — the same shape of
  failure ADR-0010 declined for DNS, for the same reason. That is why this ADR
  sets a trigger rather than mandating an identity provider now.
- **The unencrypted disk and single-factor auth compound, and the compounding is
  new.** `SECURITY.md` accepts plaintext at rest on `prometheus` on the strength
  of a threat model that excludes physical access to the rack. That exclusion was
  written when the most valuable thing on the disk was 30 days of metrics. The
  mini PC is the last moment the disk half of that bet is cheap to change.
- **Some of the estate will re-accept the deferral, and should.** ntfy, Homepage
  and the whole streaming tier hold nothing whose exposure costs anything, and an
  identity provider in front of a page of links is exactly the operational weight
  ADR-0008 was right about.
- Nothing here changes a rule, a container or a byte of configuration. It is a
  condition written down, which is the smallest possible artefact and the one the
  deferral was missing.
