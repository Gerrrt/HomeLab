# ADR-0075: Re-accept the SSO deferral once the tier holds real data

**Status:** Accepted · 2026-10

> [!NOTE]
> **Pocket ID weighed on 2026-10-07, and it changes nothing until a trigger
> fires** ([#860](https://github.com/Gerrrt/HomeLab/issues/860)). The
> Alternatives below weighed only Authelia and Authentik. Pocket ID is a
> lighter class: one container, passkey-only login, a certified OIDC
> provider, and no forward-auth, SAML or LDAP server of its own. Checked
> against v2.18.0, Immich v3.2.4 and Grafana 13.0.2:
>
> - **As an added login, it adds no factor.** Immich's password login is a
>   separate switch (`passwordLogin.enabled`), so OIDC beside local accounts
>   locks no one out during an outage. It also leaves the one-password route
>   open, and that route is the residual this record accepts. Grafana's local
>   form likewise stays unless `disable_login_form` is set.
> - **As the only login, the first objection returns, smaller.** With password
>   login off, a Pocket ID outage blocks new Immich logins. The mobile app's
>   existing sessions survive it. That is a smaller outage than Authentik in
>   front of the tier, and it is still the standing cost the Decision weighs.
> - **Linking is cheap for Immich and not for Grafana.** Immich links an
>   existing user by email at the first OIDC login, so the service is not
>   migrated. Grafana links by email only with
>   `oauth_allow_insecure_email_lookup`, which its own documentation says can
>   lower the instance's security. Grafana also runs on `prometheus`, not
>   `trinity`, so putting it behind a provider on the tier would make the
>   monitoring host's login depend on the sensitive tier.
> - **Recovery is the operator's.** A lost passkey is recovered with a
>   one-time login code from the admin page, or with `pocket-id
>   one-time-access-token <user>` on `trinity`. Pocket ID can offer
>   self-service recovery, an emailed login code requested from the sign-in
>   page (`EMAIL_ONE_TIME_ACCESS_AS_UNAUTHENTICATED_ENABLED`, off by default).
>   The shape weighed here leaves it off, for two reasons:
>   - it needs an SMTP credential, and the tier holds none on purpose (see
>     Vaultwarden's block in `compose.yaml`);
>   - it makes reading a mailbox enough to sign in, which is the
>     password-reset path a passkey exists to remove.
>
>   So recovery stays with the operator, and each person should enrol a
>   passkey on two devices. The provider
>   would sit in ADR-0023's *Never on the path* class: the photographs'
>   recovery route is the off-estate copy, not Immich's login.
> - **The footprint fits the tier's rules.** The distroless `nonroot` image,
>   SQLite under `/app/data`, and a built-in healthcheck fit `cap_drop: ALL`,
>   one volume with a sentinel, and Caddy in front.
>
> **When a reopen condition fires, Pocket ID is the first candidate,** ahead
> of Authelia and Authentik. In front of Immich alone, with password login
> off, is the shape that buys a factor. That is still a new record, as the
> Decision requires, and not a note on this one. The text below is left as
> written, per ADR-0001.

## Context

[ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)
ended [ADR-0008](0008-place-services-by-data-trust.md)'s deferral of an
identity provider on a state, not a date. It named three triggers:

1. the sensitive tier holds real data;
2. any of it becomes reachable from outside the house;
3. a third person gets an account on any of it.

It also said what has to happen when a trigger fires: "a new ADR either stands
an identity provider up or re-accepts the deferral with its reasons." This is
that record.

**Trigger 1 fired on 2026-09-28.** Immich's first real photographs arrived
that day, before this record existed. The build runbook's §13 and the stack
README both say so. The gate was passed with this decision open, which is the
outcome ADR-0022 was written to prevent. This record closes that, four days
late.

The other two triggers were read on the same date:

- **Trigger 2 has not fired for the tier.** The only inbound path is
  [ADR-0042](0042-terminate-the-remote-path-on-the-lab-and-route-it.md)'s
  WireGuard tunnel. It terminates on ImaginationLAN and reaches the lab only
  (`network.md`, Winterfell's notes and the `172.31.0.0/24` note). Nothing on
  `10.0.99.40` is reachable from it, so the firing ADR-0022 already records
  against ADR-0042 is still about the lab's Grafana and nothing on the tier.
- **Trigger 3 has not fired.** The tier's accounts belong to the two people
  ADR-0008 counts. The only key held for the off-estate copy is the
  technical second's (ADR-0024), which is a key and not a login.
  [ADR-0073](0073-carry-the-household-copy-on-a-drive-the-holder-keeps.md)'s
  household holder is not chosen yet (#455), and no household key exists.
  When one is chosen, that role is a key too. A login for them on any
  service would be trigger 3.

ADR-0022 also set a floor the deferral rests on. Each of its three items is met:

- **TOTP is enrolled on every service on the tier that can carry it.**
  - Home Assistant's owner account, at its acceptance on 2026-09-28.
  - Stirling-PDF's admin, at first login on 2026-09-29
    ([ADR-0063](0063-add-stirling-pdf-to-the-sensitive-tier-and-keep-its-documents-in-memory.md)).
  - Vaultwarden and Paperless-ngx, which the operator reported enrolled on
    2026-10-02.
- **The services that cannot carry a factor are named in `security.md`.**
  Immich and AdGuard Home were named there first. Miniflux, Memos, Mealie,
  linkding and Actual joined them, each by its own ADR.
- **`trinity`'s disk encryption was decided at build time.** LUKS on both
  disks, with the root's key sealed to the TPM
  ([ADR-0054](0054-encrypt-trinitys-disks-and-seal-the-root-key-to-the-tpm.md)).

## Decision

**The deferral is re-accepted. No identity provider is stood up.**

The reasons are ADR-0008's premises, re-checked against the tier as built
rather than as planned:

- **Two users, and no external exposure.** Both still hold, as read above.
- **The things most worth a second factor have one.** Vaultwarden holds the
  household's credentials, Paperless-ngx its documents, and Home Assistant
  the device tokens in its `.storage`. All three now ask for TOTP, as does
  Stirling-PDF.
- **An identity provider's cost has not moved.** It puts one container in the
  login path of every service, and its failure is a house-wide login outage
  that looks like everything breaking at once. ADR-0022's consequences named
  that cost, and nothing since has made it smaller.

**The residual is the "None" rows, and Immich is the one that matters.** It
holds real photographs behind one password, and upstream's only route to a
second factor is OAuth, which is the identity provider again. Every other
factorless service holds data whose disclosure costs less than Immich's
photographs. Recipes, bookmarks, feeds and notes need no argument. Actual's
budget is the closest call: [ADR-0062](0062-add-actual-to-the-sensitive-tier.md)
already accepts it behind one password. AdGuard's query log is accepted on
the same terms as in ADR-0022's context. This record accepts all of them
knowingly, and the reasons are the two premises above. The services sit on
Winterfell, and the only pass to them from another segment is Hicks to
Caddy on `443`.

**What reopens it.** Any one of these needs a new record, not a note on this
one:

- anything on `trinity` becoming reachable from outside the house, by any
  path, including a widened WireGuard route (ADR-0022 trigger 2);
- a third person getting an account on any service on the tier (ADR-0022
  trigger 3);
- a factorless service starting to hold something ADR-0023 classes as
  *Durable* or worse, other than Immich and Actual, which this record
  accepts by name.

## Alternatives considered

**Stand up Authelia or Authentik in front of the tier now.** Rejected for the
cost above. ADR-0022 observed that the change is cheapest on an empty box.
The box is no longer empty, and ADR-0022 is right that the change is now a
migration: accounts linked to the provider, factors re-enrolled, and an
outage for the household while that happens. That cost grows with every
account and is accepted knowingly. The cost that decides it is still the
standing login outage, not the one-off effort.

**Put an identity provider in front of Immich alone.** Rejected. Immich's
route is OAuth, so the provider sits in Immich's login path and has to be
running, backed up and restored with the tier like any other service. One
client makes it a small deployment but not a smaller dependency. If the
photographs alone ever justify it, that is the third reopen condition
read the other way, and it gets its own record.

**Leave ADR-0022's trigger unanswered until the off-estate copy exists.**
Rejected. ADR-0022's point is that a trigger gets a decision rather than a
wait. Access to the data and its recovery are separate questions
([ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)).

## Consequences

- **ADR-0022's trigger 1 is spent.** Triggers 2 and 3 keep their full force,
  and this record restates them as its own reopen conditions so they cannot
  be lost with it.
- **`security.md`'s MFA paragraph is a statement about the built tier**, not
  a plan. "No MFA" on Immich, AdGuard Home, Miniflux, Memos, Mealie, linkding
  and Actual is a standing property until an identity provider exists, as it
  already is for Grafana.
- **TOTP enrolment becomes part of rebuilding a service.** A restore that
  recreates Vaultwarden's, Paperless-ngx's, Home Assistant's or
  Stirling-PDF's accounts from
  scratch, rather than from their volumes, has to re-enrol before the service
  counts as restored.
- **[#404](https://github.com/Gerrrt/HomeLab/issues/404)'s §13 item 4 is
  done.** Items 2, 3 and 5 remain: the second age recipient, the off-estate
  copy of record, and ADR-0023's *Independent* proof.
- Nothing here changes a rule, a container or a byte of configuration.
