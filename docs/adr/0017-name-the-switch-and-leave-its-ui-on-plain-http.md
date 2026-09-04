# ADR-0017: Name the switch, and leave its UI on plain HTTP

**Status:** Accepted · 2026-09

## Context

[#97](https://github.com/Gerrrt/HomeLab/issues/97) asks for two things about the
MokerLink management UI: that it be reached by a name rather than by
`10.7.7.2`, and that it hold a certificate that verifies. They read as one task
— give it a name so the lab CA has something to issue for — and they are not.
One is a host override. The other is a property of the device, and the device
does not have it.

`neo` is the 26-port MokerLink at `10.7.7.2`, on the untagged LAN that exists
for exactly one reason: its management interface will not bind to a tagged one
([`network.md`](../network.md)). That interface is not going away, so whatever
is decided here is decided about `10.7.7.2`.

### What the device serves

Checked from `prometheus` (`10.0.99.20`) on 2026-09-04, against the live
switch:

| Check | Result |
| --- | --- |
| TCP 80 | open |
| TCP 443 | no listener |
| `GET /` | `200`, a two-frame frameset over `cookie.cgi` and `login.cgi` |
| `<title>` | `G2402GSM` |
| `Server:` / `Date:` headers | neither is sent |

That is a Realtek-SDK web UI: CGI, frames, and an HTTP server too small to
announce itself. There is no TLS listener to point a certificate at, and no
import to put one in. [`targets/blackbox.yaml`](../../stacks/observability/prometheus/targets/blackbox.yaml)
already recorded "plain http, and http only — 443 is dropped"; this is that
claim re-checked rather than inherited.

This is the same firmware that **will not persist an SNMP community deletion**
([#84](https://github.com/Gerrrt/HomeLab/issues/84), and an accepted residual in
[`SECURITY.md`](../../SECURITY.md)) and **cannot do SNMPv3 at all**
([#85](https://github.com/Gerrrt/HomeLab/issues/85)). A TLS stack and a
certificate import are a larger ask than either of the things it has already
failed to do.

So the certificate half of #97 is not blocked on the name. **It is blocked on
the device, and naming the device does not move it.** The issue's framing — that
a switch reached by IP "cannot be given a certificate that verifies, so it stays
on plain HTTP" — has the dependency backwards for this switch. It stays on plain
HTTP because that is all it serves. It would stay there with a name.

### Two things the issue left open, now closed

**It is not blocked behind ADR-0008.** The issue wonders whether AdGuard Home on
the sensitive tier is a prerequisite.
[ADR-0010](0010-keep-the-resolver-on-the-gateway.md) settled that: clients keep
pfSense as their only resolver, AdGuard sits behind Unbound as a forwarder, and
"the `matrix.elysium` host overrides stay where they are." Overrides were never
downstream of that decision, and four of them have been live since 2026-08-30.

**`10.7.7.2` is not undocumented.**
[`add-a-host-override.md`](../runbooks/add-a-host-override.md) closes by calling
it "outside every documented subnet, which is the harder half." Re-read: it is
in [`network.md`](../network.md)'s segment table and has its own section. What
is true is narrower — it is outside the `10.0.x` convention every *other*
management address follows, which is the typo risk the issue names and not a
routing problem. The segments that need it already reach it: Winterfell's egress
rule does not block the switch LAN, which is why the blackbox probe of
`http://10.7.7.2/` succeeds from `10.0.99.20` every scrape, and Hicks reaches it
through its catch-all ([ADR-0013](0013-segment-access-as-implemented.md)).

There is precedent for the subnet appearing in DNS answers, too: `morpheus`
already resolves to `10.7.7.1` *and* `10.0.99.1`, because pfSense registers the
firewall's hostname on each interface.

### The certificate, if it were wanted anyway

A reverse proxy on `prometheus` or `oracle` could terminate
`https://neo.matrix.elysium` with a lab-CA leaf and proxy to `http://10.7.7.2`.
It was considered and rejected on three counts, the first of which is decisive:

- **It puts the switch behind the things the switch carries.** You open that UI
  when the network is wrong. Reaching it would then require Unbound on
  `morpheus` *and* a container on another host to both be healthy — through the
  switch being diagnosed. The current path needs one address and a browser.
- The credential still crosses the last hop in clear, so the padlock would
  describe the proxy's leg and not the one that carries the password.
- A frameset UI driven by `cookie.cgi` is the kind that breaks behind a proxy in
  ways that cost an evening.

## Decision

**Give the switch its name, and stop pursuing the certificate.**

1. **Add one host override:** `neo` / `matrix.elysium` → `10.7.7.2`, by the
   procedure in [`add-a-host-override.md`](../runbooks/add-a-host-override.md).
   Nothing else claims that address in `host_entries.conf` — verified on
   `morpheus`, 2026-09-04 — so it takes the forward record and the PTR, and the
   ordering trap in that runbook does not apply.
2. **The UI stays plain HTTP**, at `http://neo.matrix.elysium/`. #97's
   certificate goal is closed as *not achievable on this hardware*, not left
   open as pending work.
3. **`10.7.7.2` stays in the documentation**, alongside the name rather than
   replaced by it.

## Consequences

- **The name is a convenience, and should not be described as anything else.**
  It fixes the typo-and-memory problem the issue names — one address in a
  `10.0.x` estate — and it fixes nothing about what crosses the wire. Switch
  admin credentials still travel in cleartext, and they travel *through `neo`
  itself*, which is the part worth saying out loud: a foothold or a mirrored
  port on the switch sees the password to the switch. The controls are what they
  already were — a unique password, and a firewall that only lets Hicks and
  Winterfell reach `10.7.7.0/24` at all.
- **The address has to stay documented, because the name depends on `morpheus`.**
  If the firewall is what you are diagnosing, `neo.matrix.elysium` is gone at the
  moment the switch matters most. Every other name in this estate can afford
  that dependency. This one is the break-glass path to the device the whole
  network runs through, so both forms stay in the runbooks.
- **The name gets a `via: dns` blackbox twin, and the order matters.** Adding the
  twin before the override exists makes `EndpointNameNotResolving` fire — truthfully,
  and for planned work. Override first, target second; the wiki was done in that
  order for the same reason.
- **A test comment stops being true.**
  [`blackbox.test.yaml`](../../stacks/observability/prometheus/tests/blackbox.test.yaml)
  uses `switch-ui` as its worked example of "an endpoint with no dns twin". The
  case still needs an example once `switch-ui` has one.
- **Renumbering the switch onto `10.0.99.x` is rejected, not deferred.** It is
  the only change that would make the address match the convention, and it means
  re-addressing the LAN interface of the firewall, the SNMP and blackbox targets
  that hard-code `10.7.7.2`, and two ADR-0013 rules — to make one address
  prettier, on the box that would lock everything out if it went wrong. The name
  buys the readable half at none of that cost.
- **Replacing the switch is the only thing that reopens this.** `neo` is already
  carrying two accepted residuals for firmware limits (#84, #85); this is the
  third, and three is the argument for a replacement rather than for another
  workaround. When one is specced, **a TLS management interface belongs in the
  selection criteria** — along with SNMPv3, which is the same sentence.
