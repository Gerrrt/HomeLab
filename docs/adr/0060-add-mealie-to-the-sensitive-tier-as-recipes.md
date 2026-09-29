# ADR-0060: Add Mealie to the sensitive tier as `recipes`, with no second factor

**Status:** Accepted · 2026-09 · adds a service to the tier
[ADR-0008](0008-place-services-by-data-trust.md) created, beyond the nine it counted, and a name to
the list [ADR-0022](0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)
keeps of services that cannot carry a factor; decides
[#146](https://github.com/Gerrrt/HomeLab/issues/146)

## Context

[#146](https://github.com/Gerrrt/HomeLab/issues/146) proposed Mealie, a recipe
manager with meal plans, shopping lists and import from a pasted URL. The
argument for it is not technical. Nearly everything else in the estate is
infrastructure the household benefits from without touching. **This is one of
the few services someone other than the operator will open on purpose**, and a
homelab that produces something the rest of the house likes is easier to keep
paying for. grocy was the adjacent option. It is far more ambitious — stock,
chores, batteries — and it needs daily discipline to stay accurate, and an
inaccurate stock database is worse than none. Mealie asks much less.

It is beyond ADR-0008's nine, and the roadmap's *Tier extras* rule is that each
such service needs its own decision before it is authored. This is Mealie's.
[ADR-0057](0057-add-miniflux-to-the-sensitive-tier-with-its-fetcher-kept-off-winterfell.md)
was Miniflux's, decided the same day, and it asked a question this one must
answer too: what a fetcher on Winterfell does with a URL a user hands it.

**Placement.** ADR-0008's test is the trust of the data, and recipes are not
sensitive. By that test alone Mealie belongs on CasaBonita with the media. But
there it would be reachable from the televisions and not from the phones and
laptops that will use it, which are on Hicks. [ADR-0050](0050-add-audiobookshelf-to-the-media-tier-behind-a-fifth-hicks-pass.md)
paid for exactly that with a fifth Hicks pass. On Winterfell, behind `trinity`'s
Caddy, it costs nothing. The issue said it would ride "the 50→99 rule that
already exists". There is no such rule — since
[ADR-0031](0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md),
Hicks reaches a named list of destinations on 99 — but one entry on that list is
`10.0.99.40:443`, the tier's front door, in force since 2026-09-28
([`network.md`](../network.md)). A new name behind the same port is not a new
rule, and so, unlike ADR-0050's, this one is true.

It is also exactly the kind of low-consequence, human-facing service that would
have made the strongest case for the dedicated services VLAN that ADR-0008
rejected. It does not reopen that decision on its own. It is a data point, and
it is recorded here so that the next one can be counted.

Measured on the pinned image on 2026-09-29:

- `/app/data` is `0:0 755` in the image. The entrypoint usermods, `chown -R`s
  `/app` and gosus to 911 when it starts as root, unless the uid it is running
  as already equals `PUID`. With `PUID=0`, `cap_drop: [ALL]`, `read_only` and a
  `/tmp` tmpfs it came up healthy, and `docker diff` showed nothing written
  outside `/app/data`.
- SQLite, in rollback-journal mode. Two token-signing secrets, `.secret` and
  `.session_secret`, are generated into `/app/data` on the first start.
- `ALLOW_SIGNUP=false` makes `POST /api/users/register` answer `403`.
- **No second factor in any form.** There is no TOTP or WebAuthn in the code,
  only OIDC and LDAP, which would each need an identity provider.
- The image's own `change_password.py` resets a password on the running
  container. It was proved on a scratch boot: the new password answered `200`
  and the old one `401`.
- Nothing is scheduled to back itself up. The daily tasks purge tokens and
  exports, and nothing else.
- 224 MiB idle and 396 MiB at the peak of three URL imports.
- **URL import refuses to fetch inward.** Every fetch goes through Mealie's
  `safehttp` transport, which resolves the name and refuses private, loopback,
  link-local, reserved and CGNAT addresses at connect time, unless the host
  is on `HTTP_ALLOW_LIST`, which is empty by default. Measured with a server
  on the same Docker network serving a real recipe page: an import by its
  name, by its address, and of `127.0.0.1:9000`, `10.0.99.1`,
  `10.0.99.20:9090` and `169.254.169.254` each failed with
  `InvalidDomainError: invalid request on local resource`, and the server
  logged no request. With its name on `HTTP_ALLOW_LIST`, the same import
  succeeded, so the refusals were the guard and not a broken scraper.

## Decision

1. **Mealie joins `stacks/sensitive` on `trinity`, at
   `https://recipes.matrix.elysium`.** It is named for its purpose, not its
   software, as Homepage is `home`. The people using it will type it, not find
   it (#97 is the same problem for the switch). The service follows
   Vaultwarden's shape:
   - `expose:` and no `ports:`;
   - root with every capability dropped;
   - `no-new-privileges` and `read_only`;
   - pinned by digest;
   - healthchecked with the image's own script;
   - `1024m`, which is two and a half times the measured peak.

   It uses SQLite and one named volume, `mealie-data`, with no database
   container.

2. **No new firewall rule.** Hicks reaches it through `10.0.99.40:443`, which
   already passes. The name needs a host override on `morpheus`, added beside
   the tier's others ([`add-a-host-override.md`](../runbooks/add-a-host-override.md)).

3. **Sign-up is off from the first start.** The default admin
   (`changeme@example.com` / `MyPassword`) is renamed and re-passworded at the
   first login. Accounts are made by that admin.
   **Accounts are for the same two people ADR-0008 assumes.** A third account —
   a child, a guest, a relative — fires ADR-0022's trigger 3 as surely on this
   service as on the vault, even though the data is recipes. That is deliberate:
   the trigger counts people with accounts on the tier, not the sensitivity of
   what each account can read, and Mealie shares Caddy, the network and the
   host with everything else here.

4. **Mealie is named unable to carry a second factor**, beside Immich and
   AdGuard Home, as Miniflux and Memos are. It is accepted without one because a compromised
   Mealie account exposes recipes and a shopping list, and can write the same.
   Nothing on this service is a credential or a record. The route to a factor
   is the one Immich and AdGuard already wait on, an identity provider in
   front. Mealie's OIDC support means that route is a configuration change here
   rather than a proxy.

5. **No SOPS secret.** Mealie generates its signing secrets into its own volume,
   and keeps the admin password as a bcrypt hash in its database, where no
   environment variable reaches. SMTP, LDAP, OIDC and the OpenAI integration
   stay unset.

6. **URL import reaches out and never in, and `HTTP_ALLOW_LIST` stays empty.**
   The server fetches the page a user pastes. Winterfell already has internet
   egress, so this adds no rule. That the fetch cannot be pointed at the
   firewall's UI, step-ca or `prometheus` rests on the guard measured above,
   because hosts on one segment reach each other without crossing the
   firewall. So `compose.yaml` writes `HTTP_ALLOW_LIST` out as empty rather
   than leaving it to the default, as ADR-0057 writes out Miniflux's flag.
   Anything added to it is a hole into Winterfell, and needs a decision of its
   own.

7. **`mealie-data` joins the weekly volume set** with `./mealie.db` as its
   sentinel and the two secrets as companions, so a restore that loses them
   shows in the verify line rather than as everyone being logged out. Mealie's
   own backup feature is not used. Nothing schedules it, and a zip of the same
   database inside the volume would only double every set.

## Consequences

- **The tier runs one more container**, and one more service that the
  household depends on for something other than safety. `trinity` has the
  memory: with this one, Miniflux and Memos, every ceiling in the stack
  sums to 17.2 GiB of its 32.
- **ADR-0022's list of unable services grows again.** Grafana, Immich,
  AdGuard Home, Miniflux, Memos and now Mealie. The argument for an identity provider gets one
  service stronger each time, and this ADR makes that visible rather than
  quietly adding to it.
- **Trigger 3 is now more likely to fire**, because this is a service whose
  whole point is that more of the household uses it. When someone asks
  for an account for a third person, the answer is the decision ADR-0022
  requires, not the account.
- **Homepage links to it and does not read it.** Mealie's API tokens carry all
  of their user's rights, and there is no read-only scope, so a widget would
  hold a key that can edit recipes.
- **ADR-0008 and ADR-0022 are not superseded.** ADR-0008's tier gains a
  service by its own rule. ADR-0022 gains a pointer here and a name on its list,
  and its triggers are unchanged.
- **The dedicated services VLAN stays rejected**, with one data point against
  that rejection now recorded, here.
