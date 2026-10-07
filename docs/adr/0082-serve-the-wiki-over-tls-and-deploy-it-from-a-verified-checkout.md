# ADR-0082: Serve the wiki over TLS from the estate's CA, and deploy it from a verified checkout

**Status:** Accepted · 2026-10

## Context

The wiki on `oracle` was the one stack in this repository deployed and served
outside the controls every other stack has
([#847](https://github.com/Gerrrt/HomeLab/issues/847), from the 2026-10-03
repository review).

**It was deployed from an unverified fetch.** `stacks/wiki/README.md` said to
`curl` `compose.yaml` from `raw.githubusercontent.com` into `/opt/wiki` and run
`docker compose up -d`. The file pins its images by digest, and nothing pinned
the file. On `prometheus`, `scripts/converge.sh` refuses any commit not signed
by GitHub's web-flow key, compared by full fingerprint
([ADR-0021](0021-converge-on-a-timer-instead-of-deploying-over-ssh.md)).
Here, whatever answered for that URL was run as written.

**Its logins crossed the network in clear.** Wiki.js was published as
`80:3000` on every interface, plain HTTP, and its four accounts log in over
it. That includes the operator's, which administers the git storage target
and so holds a deploy key with write access to `Gerrrt/Lemmiwinks`. Nothing
had accepted that. `SECURITY.md` and the ADRs have no row for it. The one
plain-HTTP management UI with an acceptance is the switch's
([ADR-0018](0018-name-the-switch-and-leave-its-ui-on-plain-http.md)), and that
acceptance has since been overtaken by
[ADR-0041](0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md).
Hicks reaches `oracle:80`, and Hicks is where the household's phones are.

Two earlier decisions bear on any fix, and neither forbids it.

- **[ADR-0011](0011-keep-the-wiki-internal.md)** rejected *publishing the wiki
  behind Caddy and step-ca*. That decision was about reach from outside the
  house, and its reason was availability during an emergency. A proxy and a CA
  on the same rack add ways for the docs to be unreachable and no case in which
  they become reachable. Serving TLS to readers who are already inside is a
  different question. It changes who can read a password on the wire, not who
  can reach the page. ADR-0011's Decision, *no port forward, no external
  hostname, no reverse-proxy entry* on the edge, is untouched by this ADR.
- **[ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)**
  forbids putting an internal HTTPS name, or anything that depends on an
  estate-issued certificate, on a household recovery path. It allows the card's
  `lemmiwinks.matrix.elysium` because ADR-0011 classes the wiki as a
  convenience, not a recovery tool. That classification is the premise this
  ADR keeps.

What exists to build on:

- **The estate's CA** issues 825-day leaves by hand on `prometheus`
  ([ADR-0043](0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)).
  Grafana already serves one, and blackbox verifies it and alerts at 30 and 7
  days.
- **The sensitive tier's step-ca** issues seven-day leaves over ACME, and only
  to the Caddy on its own compose network, because step-ca validates by
  dialling the name from inside it
  ([ADR-0037](0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md)).
  A Caddy on `oracle` cannot complete that challenge. Carrying a seven-day leaf
  by hand is not a procedure.

## Decision

### Serve the wiki on 443 from a leaf of the estate's CA, and redirect 80

`stacks/wiki` gains a Caddy, the sensitive tier's image digest for digest. It
terminates TLS on 443 with a leaf from `make certs` for
`lemmiwinks.matrix.elysium`, `oracle.matrix.elysium` and `10.0.99.30`. It
answers 80 with a `308` to the same path on 443 and nothing else. Wiki.js is no
longer published, and Caddy is the only way in. A form posted to port 80 is
answered by the redirect and never reaches anything that reads it.

**80 is redirected rather than closed** because the card on the fridge and
every bookmark carry the http name, and ADR-0023 makes the card a document
that cannot be hot-fixed. Closing 80 would break the one link a household
reader has, to gain nothing over a redirect that carries no credential.

**The estate's CA rather than the tier's**, for the reason above: the tier's
issuer cannot reach this host, and its leaves are too short to carry by hand.
The cost is the trust question, the next decision.

### Household devices that read the wiki trust the estate's root

[`generate-certificates.md`](../runbooks/generate-certificates.md) said the
household's devices would *never* trust this root, because it was the
operator's. That stops being true for the devices that read the wiki, and each
install is written into that runbook's table like any other.

This is a real widening, and it is stated rather than played down:

- The root carries **no name constraint**. A device that trusts it would
  accept a leaf for any name, from whoever holds `ca-key.pem`.
- That key stays where ADR-0043 put it: on `prometheus`, mode 0600, plus one
  proved offline copy. It never travels to `oracle` with the leaf.
- The trust the household gains is exactly as strong as that key's custody,
  which is already what Grafana's and blackbox's trust rests on.
- Re-minting the root now means re-trusting it on phones as well. The
  runbook's table is the list of where.

### Deploy from a checkout, verified the way convergence verifies

`/opt/wiki/HomeLab` becomes a clone of this repository, and `.env` stays
beside it in `/opt/wiki`. A deploy is three steps in `stacks/wiki/README.md`:

1. Fetch `main` from the canonical URL, not `origin`, and name the commit
   by its SHA.
2. Read that commit's CI from the API.
3. Then, against that SHA:
   - require a clean tree with `main` checked out;
   - run `git verify-commit` and compare `%GF` to the fingerprint
     `converge.sh` pins;
   - `merge --ff-only` to it;
   - require `HEAD` to equal it;
   - `docker compose up -d`.

Each check refuses on its own. The comparison is the same one ADR-0021 makes:
a key id is claimed by the signature, and a verified fingerprint is not. The
last test catches what `--ff-only` lets through, a checkout already ahead of
the verified commit.

### `oracle` does not join `homelab-converge`

ADR-0021 scoped the agent to its own host's stack. #533 has since amended
that: `trinity` converges `stacks/sensitive` with the same script, the same
pinned key and the same refusals, and #833 added a gate that holds any tip
whose CI did not pass. The reason ADR-0021 gave for stopping was hosts "with
no age key, no repository checkout". This ADR gives `oracle` the checkout,
and still no age key. That is the reason it stays out:

- **`converge.sh` ends in `make up`, and `make up` cannot run here.** It
  renders a secrets file, which needs an age identity, and ADR-0015 forbids
  one on this host. ADR-0021 decided the agent decides *when* to deploy and
  does not reimplement deploying. A compose-only branch for one host would
  be a second deploy path, the thing that decision exists to prevent.
- **A third host means a third profile.** That is a units profile in
  `install-timers.sh`, a `--stack` case in `converge.sh`, and the deploy
  rules' per-host series. Each one is cheap, and none of them is worth it for
  what the wiki changes.
- **The wiki changes when Dependabot bumps it, a few times a month.** An
  hourly agent buys little over a verified hand step at that cadence. The
  risk the issue named was an unverified deploy, not a late one.

The hand step keeps both of the agent's gates. The signature is checked by
the same `%GF` comparison. The CI gate is a look at the commit's checks before
the line is run. A human makes that check here, where the agent makes it in
code, and the README says so.

## Consequences

- **A login over port 80 cannot happen.** The only listener on 80 is a
  redirect, and Wiki.js publishes nothing.
- **The wiki now has a certificate that can expire, and the card's name leads
  to it.** This is the failure ADR-0011 named: it "fails quietly and looks like
  a browser problem to whoever is holding the phone". It is accepted here, for
  two reasons:
  - ADR-0023's premise is unchanged. The wiki is a convenience, and nothing
    the household needs in an emergency is only on it. The card is.
  - Expiry is not quiet. Blackbox probes the name and the address over https,
    verifies the chain against `ca.pem`, and `TlsCertificateExpiringSoon` and
    `TlsCertificateExpiryImminent` fire at 30 and 7 days. The leaf lasts 825.
- **A device that has not installed the root warns on every visit**, which
  is worse than the silent plain-HTTP page was. It is the honest form of the
  same exposure, and installing the root is a step written down per device.
- **Hicks needs a pass to `oracle:443` again**, the one removed on 2026-09-30
  when nothing listened on it. 80 stays, for the redirect.
- **Wiki.js's Site URL must be the https one**, or the links and login
  redirects it builds point back at http, through the redirect, every time.
- **The deploy needs GitHub's key in the operator's keyring on `oracle`.**
  Import it once, as on `prometheus`. A deploy without it refuses rather than
  proceeding.
- **`stacks/media` still deploys by `curl`** onto `smaug`, the same shape this
  ADR retires here. It is a separate host and a separate change, and not
  decided here.
- **Reopened by:**
  - step-ca becoming reachable for issuance from another host (ADR-0037's
    reopen condition), after which the wiki's leaf could renew itself under
    the root the household already trusts, and the estate's root could leave
    their phones;
  - `make up` learning to deploy a stack with no secrets file without an age
    identity, after which `oracle` can converge like `trinity`, and the hand
    step and its human CI check retire;
  - a second stack on `oracle`, or a wiki that changes more than Dependabot
    changes it, after which a converge agent on `oracle` earns its units;
  - the wiki becoming a recovery tool, which ADR-0011 and ADR-0023 would both
    have to be superseded to allow.
