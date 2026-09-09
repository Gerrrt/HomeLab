# ADR-0035: Give the sensitive tier its own root, and issue beneath it over ACME

**Status:** Accepted · 2026-09

## Context

[#130](https://github.com/Gerrrt/HomeLab/issues/130) puts step-ca on the
sensitive tier and asks for two decisions before it is built: whether it
**replaces** the estate's CA or is **issued beneath** it, and how its root key
is handled — "the same class of problem as #106: the age key has one holder
and one copy. A CA root with the same property is the same mistake in a
different format." It also asks for an ACME provisioner so Caddy renews
without a runbook step, and for `scripts/gen-certs.sh` and
[`generate-certificates.md`](../runbooks/generate-certificates.md) to be
"rewritten or retired — deliberately, not left to rot alongside the new path".

The stack's foundation landed on 2026-09-09 with the first decision already
written into it. `stacks/sensitive/compose.yaml`, its README and the roadmap
all said the same thing: *an intermediate beneath the lab CA, so nothing that
trusts `certificates/ca.pem` is re-pointed, and the root key never leaves the
monitoring host.* That is the natural answer, it costs nothing to re-trust,
and it was written before anyone read the root.

### The lab root forbids it, and that was measured rather than inferred

`gen-certs.sh` mints the estate's root with
`basicConstraints=critical,CA:TRUE,pathlen:0`. A path length of zero means no
CA certificate may sit between this root and a leaf — the root may sign
end-entity certificates and nothing else. Trial on 2026-09-09, against a
throwaway root minted by the same `openssl` line and the pinned step-ca image:

| Step | Result |
| --- | --- |
| `step ca init --root ca.pem --key ca-key.pem …` | Succeeds. Copies the root, mints an intermediate, writes `config/ca.json` |
| `openssl verify -CAfile ca.pem intermediate_ca.crt` | `OK` — the intermediate is a valid certificate *of* the root |
| A leaf signed by that intermediate, verified through the chain | `error 25 at 2 depth lookup: path length constraint exceeded` |

Every client in this estate is built on Go's `crypto/x509` — Caddy, Prometheus,
blackbox-exporter, step-ca's own health check — and it enforces the constraint
the same way. So the decision as written produces a CA that mints certificates
nothing accepts. It would have failed loudly, on the first `make up` on
`trinity`: step-ca's health check verifies its own serving certificate through
that chain against the root, so the container would never have gone healthy
and Caddy, which waits on it, would never have started. Loud, but it would
have read as a trust problem inside a container rather than as a property of
the root, and the fix would have been decided at 1am.

`pathlen:0` is not a mistake to fix. It is the property that nothing beneath
the estate's root can ever become a CA, it has been on that root since the CA
was replaced after the key leak ([`security.md`](../security.md)), and it is
worth keeping. Lifting it means minting a new root, which is the replacement
the issue asked to have costed before it is started.

### The cost of replacing, counted

A new estate root with `pathlen:1` and the tier beneath it would need:

- Grafana's leaf reissued on the monitoring host and the stack restarted;
  Prometheus and blackbox read `ca.pem` by path, so they follow on restart.
- The lab guest's leaf reissued and carried with the new `ca.pem` to
  `alexander` through the Mac, because `99 → 30` is closed
  ([`build-the-lab-guest.md`](../runbooks/build-the-lab-guest.md) §5).
- Every device that imported `ca.pem` re-trusting the new one — the Mac's
  system store and Firefox's separate one, at least, and whatever else nobody
  wrote down. Until each is done, Grafana warns in that browser.
- The whole of it sequenced *before* the tier's tree is minted, on the
  monitoring host, on a day the lab guest is also reachable.

None of that is large. The CA was replaced once already and the procedure
exists. What decides it is not the size of the cost but who pays it and for
what: the estate's root would be reissued so that the household's devices can
trust it — and they have no reason to.

### Two audiences, and the precedent for separating them

The estate's CA has one client that is a person: the operator, opening Grafana
from Hicks. Everything else that verifies against it is a scrape or a probe on
the management VLAN. The tier's CA will be trusted by the household's phones
and laptops, for Vaultwarden, Immich and Home Assistant, and those devices
must import *some* root to reach the tier at all. Importing the estate's would
also have them vouch for a Grafana they cannot reach, on a segment they are
not allowed to see.

This repository has already decided, twice, that things with separate trust
get separate keys. [`.sops.yaml`](../../.sops.yaml) gives the tier its own
encryption rule "not because the host is less trusted than the estate, but
because it has no use for the estate's secrets".
[ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md) gives
the lab its own Prometheus and its own age key for the mirror-image reason. A
certificate authority is the same shape: the tier has no use for the estate's
root, and the estate has no use for a root that signs for the tier.

### What `trinity` could forge

[ADR-0008](0008-place-services-by-data-trust.md) puts the tier on the segment
where "compromise here is total", and gives that box the largest attack
surface in the estate — Immich's upload endpoint and Paperless's parsers on
one host. The intermediate key on that host signs for any name it is asked
for. Beneath the estate's root, a compromised `trinity` mints a certificate
for `grafana.matrix.elysium` that Prometheus, blackbox and the operator's
browser all accept. Beneath its own root, what it can forge is bounded to
what trusts the tier's root: the tier's own clients. That is not the reason
for the decision, but it is a consequence that points the same way.

## Decision

**The sensitive tier runs a certificate authority of its own — a root and an
intermediate minted on the monitoring host — and Caddy obtains every
certificate it serves from that intermediate over ACME.** The estate's CA is
untouched. Four parts.

**1. A root of its own, minted where the estate's root lives.**
`make tier-ca ARGS=--mint` ([`scripts/tier-ca.sh`](../../scripts/tier-ca.sh))
runs `step ca init` in the pinned step-ca image against a directory under
`certificates/` on the monitoring host. It produces the tree step-ca runs
from — `config/`, `certs/`, `secrets/`, `db/` — with the root at `pathlen:1`
and the intermediate at `pathlen:0`, which is the same shape as the estate's
root and for the same reason. It then adds the ACME provisioner offline,
against `config/ca.json`, rather than leaving it to the `--acme` default, so
that the challenge and lifetime restrictions below are in the file before the
CA ever starts. It refuses to run if a tree already exists, for the reason
`gen-certs.sh --ca` does: minting a new root invalidates every device that
trusts the old one, and that has to be deliberate.

**2. The root key is cold, stays on the monitoring host, and never reaches
`trinity`.** What ships to `trinity` is a bundle the script builds from the
tree with `secrets/root_ca_key` left out, and the script refuses to report
success if the bundle contains it. This was checked rather than assumed:
`config/ca.json` references the intermediate's certificate and key and the
root's *certificate*, and nowhere the root's key — step-ca has no use for it
at runtime. step encrypts both keys at rest with the password it is given,
and that password is `STEPCA_PASSWORD` in `secrets/sensitive.sops.yaml`,
which decrypts on `trinity` and, by ADR-0024, for the technical second — and
**not** on the monitoring host, whose age key opens the estate's secrets and
not the tier's. So the root key file on the monitoring host is inert without
a secret that host cannot read, and using it — to mint a fresh intermediate
after `trinity` is rebuilt — is a two-host operation on purpose.

That leaves the one-copy problem the issue names. It has the same shape as
the age key's and gets the same answer:
[`back-up-the-age-key.md`](../runbooks/back-up-the-age-key.md)'s offline copy
is where the tier's root key goes too, and
[`build-the-tier-ca.md`](../runbooks/build-the-tier-ca.md) says so. What
makes it a smaller problem than the age key's is how loss degrades: the
intermediate keeps issuing for its whole lifetime without the root, so a lost
root key costs nothing until the intermediate must be re-minted, and then it
costs a new root and a re-trust on the household's devices. Nothing goes
down. What is **rejected** is putting the root key in this repository under
SOPS: a passphrase-encrypted CA private key in git is the exact artefact
that was purged from this repository's history, and encrypting it with a
better cipher does not change what a reader of `security.md`'s table would
conclude on seeing it there again.

**3. ACME, `tls-alpn-01` only, seven-day leaves.** The provisioner accepts one
challenge type. Caddy solves it on 443, which is already the tier's one
published port, so 80 stays unpublished ([ADR-0012](0012-publish-only-ports-with-an-off-host-consumer.md))
and the CA never attempts `http-01` against a port nothing answers on. The
challenge is validated by step-ca connecting to the requested *name* from
inside the compose network, so every name Caddy serves is also a network
alias of the Caddy container — Docker's resolver answers `trinity.matrix.elysium`
with Caddy's address only because `compose.yaml` says so. A name in the
`Caddyfile` with no alias fails its first issuance with a DNS error at the
CA, which is loud and immediate.

The leaf lifetime is 168 hours, default and maximum, and not step-ca's
default of 24. The lifetime is not a labour cost — Caddy renews at a third of
the way from expiry and nobody types anything — it is the **outage budget**:
the time between step-ca failing and the tier's handshakes failing. This is a
single box that [ADR-0023](0023-keep-the-household-recovery-path-outside-the-estate.md)
declines to make highly available, run by one person who is sometimes away for
a weekend. With 24-hour leaves that budget is as little as eight hours; with
seven-day leaves it is never less than two days and usually closer to five.
Short-lived is the point; short enough to fail over a Saturday is not.

**4. `gen-certs.sh` and `generate-certificates.md` are rescoped, not
retired.** They are the *estate's* CA: Grafana on the monitoring host and on
the lab guest still serve leaves from it, and Grafana does not speak ACME. The
runbook now says which of the two CAs it is, and the script's header says what
it is no longer for. Its `pathlen:0` line is now commented as deliberate,
because this ADR is the record of what happens when that is forgotten.
Retiring the script waits on Grafana renewing from step-ca with
`step ca renew` on a timer — which needs 9000 published on `trinity` for its
first off-host consumer, and is a decision to take with ADR-0012 in hand, not
here.

## Consequences

- **Two private CAs, and the successor has to know there are two.** The
  operator's devices import both roots; the household's import one.
  `generate-certificates.md` opens with the table that says which is which,
  and `successor-handover.md` names both keys among the things a clean clone
  does not hold.
- **The comments that said "an intermediate beneath the lab CA" were wrong
  and are corrected** in `compose.yaml`, the stack's README and the roadmap,
  in this ADR's pull request. A decision recorded only in a comment is what
  let it go unmeasured; this is the ADR it should have had.
- **The estate's TLS-expiry alerts do not fit seven-day leaves.**
  `TlsCertificateExpiringSoon` fires at thirty days and
  `TlsCertificateExpiryImminent` at seven ([#91](https://github.com/Gerrrt/HomeLab/issues/91)),
  so a tier endpoint added to the lab-CA blackbox module would page
  permanently. The tier's endpoints stay out of those rules until a rule with a
  threshold in hours exists — [#426](https://github.com/Gerrrt/HomeLab/issues/426).
- **A dead step-ca is a dead tier within a week, and nothing pages on it
  yet.** The estate's container-health alerting watches the monitoring host's
  cAdvisor; `trinity` ships node and log telemetry only. Until #404 wires the
  tier's containers into an alert, the seven-day budget is the only signal,
  and it is a silent one.
- **Rebuilding `trinity` is `--install` again.** The bundle on the monitoring
  host is the whole CA state that matters; the ACME accounts and issued
  certificates in step-ca's database are disposable, because every leaf is
  re-issued within a week anyway. Losing `trinity`'s disk costs nothing the
  household's devices can see.
- **Reopened by:** Grafana moving onto step-ca, at which point the estate
  trusts the tier's root for a reason and the estate's own CA can be argued
  out of existence — a different ADR; or a client that must trust both roots
  appearing, which is the first sign the two audiences are not as separate as
  this ADR claims.
