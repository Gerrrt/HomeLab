# Runbook: Forward DNS to AdGuard Home

Put the filter one hop behind the resolver the house talks to, the way
[ADR-0010](../adr/0010-keep-the-resolver-on-the-gateway.md) decided — and
prove the fallback it rests on, which has never run here.

**Target:** `morpheus` (10.0.99.1), the pfSense web UI; `trinity` (10.0.99.40)
for the failure test
**Time:** ~30 minutes, including the wait the failure test needs
**Reversible:** one checkbox, no DHCP change, no lease to wait out

---

## Why this exists

Every client in the estate has exactly one resolver, pfSense, and that does not
change. What changes is what Unbound on `morpheus` does with a name it cannot
answer itself: today it walks the root servers, and after this it forwards to
AdGuard Home on `trinity` with Cloudflare and Google listed beside it. Filtering
happens behind the resolver instead of in front of it, no client VLAN ever holds
a DNS path into Winterfell, and a dead AdGuard drops out of Unbound's forwarder
selection so the house keeps resolving — unfiltered, silently, which is why the
probes in step 1 exist.

ADR-0010's own verification found the decision costs more than it reads:
**Unbound forwards to nothing today**, so *Enable Forwarding Mode* is a
resolution-mode change, not an edit to a list. It hands a query stream that
currently reaches no third party to AdGuard and, whenever AdGuard is slow or
down, to Cloudflare and Google. That price was accepted in the ADR; this runbook
is where it is paid, on purpose, and where the two things the ADR could not
measure — that DNSSEC survives the forwarder, and that the fallback actually
works — are measured.

The stack half is [`stacks/sensitive`](../../stacks/sensitive): AdGuard runs
there, publishes 53 on `trinity`'s address and answers `10.0.99.1` and
`10.0.99.20` only. Nothing in this runbook touches that side except to stop it
on purpose.

---

## Before you start

- **`trinity` is built and the stack is up.** `make up STACK=sensitive` on
  `trinity`, `sensitive-adguard` healthy in `make ps STACK=sensitive`, and
  `adguard.matrix.elysium` reachable in a browser from Hicks. The host is
  [#404](https://github.com/Gerrrt/HomeLab/issues/404); until it exists there
  is nothing to forward to.
- **Take a configuration backup.** *Diagnostics → Backup & Restore → Download
  configuration as XML.* This edits the box every other machine depends on.
- **Pick the hour.** The change applies in seconds and the failure test in step
  4 takes AdGuard down for a few minutes, during which the house resolves
  unfiltered and nothing breaks. Still: not while someone is on a call.

---

## 1. Prove AdGuard answers from where the firewall will ask

Before the firewall depends on it, ask it the two questions the probes ask, from
the one host besides the firewall it will answer. On `prometheus`:

```bash
docker exec blackbox-exporter wget -qO- \
  'http://localhost:9115/probe?target=10.0.99.40:53&module=dns_answers' \
  | grep -E '^probe_(success|dns_answer_rrs)'

docker exec blackbox-exporter wget -qO- \
  'http://localhost:9115/probe?target=10.0.99.40:53&module=dns_filters' \
  | grep -E '^probe_(success|dns_answer_rrs)'
```

Both `probe_success 1`. Then the negative, because a filtering probe that cannot
go red is measuring nothing:

```bash
docker exec blackbox-exporter wget -qO- \
  'http://localhost:9115/probe?target=10.0.99.1:53&module=dns_filters' \
  | grep -E '^probe_success'
```

`0` — Unbound does not filter. If that reads `1`, stop: the probe is not
asserting what it says it asserts, and everything after this would be watched by
nothing.

**Then enable the two targets** in
`stacks/observability/prometheus/targets/blackbox-dns.yaml` — uncomment the two
blocks, keep `name: adguard` on both, commit. Prometheus re-reads the file within
five minutes; confirm under *Status → Targets*, job `blackbox-dns`. From here on,
`AdGuardNotAnswering` and `AdGuardNotFiltering` are live, and step 4 uses the
first of them.

> [!NOTE]
> A query from any other Winterfell host — `oracle`, or a shell on `trinity`
> itself — gets no answer at all. That is `allowed_clients` in
> `stacks/sensitive/adguard/AdGuardHome.yaml` doing its job, not a fault. Test
> from `prometheus` or the firewall.

---

## 2. Make the change on morpheus

Two pages, in this order.

**System → General Setup → DNS Server Settings.** The list becomes:

| Order | DNS Server | Gateway | Hostname |
| --- | --- | --- | --- |
| 1 | `10.0.99.40` | *none* | *blank* |
| 2 | `1.1.1.1` | *none* | *blank* |
| 3 | `8.8.8.8` | *none* | *blank* |

The second and third are already there; they are the firewall's own fallback
and, after the next page, Unbound's. Leave *DNS Resolution Behavior* as it is —
that field governs what the firewall itself uses, not what it serves. Save.

**Services → DNS Resolver → General Settings:**

- **Enable Forwarding Mode** — tick it. This is the change.
- **Enable DNSSEC Support** — stays ticked. Do not untick it to make a problem
  go away; step 3 checks it still works through the forwarder.
- **Use SSL/TLS for outgoing DNS Queries to Forwarding Servers** — stays
  unticked. It would send every forwarder DNS-over-TLS on 853, and AdGuard
  listens on plain 53. The hop to `trinity` is on VLAN 99; the hop that leaves
  the house is encrypted by AdGuard's own upstreams.

Save, then **Apply Changes**. Unbound reloads on apply.

> [!IMPORTANT]
> **Host Overrides are untouched.** `matrix.elysium` names keep being answered
> by Unbound from its overrides before any query is forwarded; that is what
> keeps internal names resolving while AdGuard is down. Nothing on this page
> other than the forwarding checkbox changes.

---

## 3. Verify

**Read the running config back**, rather than the page that wrote it. On
`morpheus`, over SSH:

```bash
grep -A6 '^forward-zone:' /var/unbound/unbound.conf
```

One `forward-zone:` block, `name: "."`, and three `forward-addr:` lines with
`10.0.99.40` among them. Zero blocks means the checkbox did not take; a block
without `10.0.99.40` means the General Setup save did not.

**Then from a client** that uses pfSense — a laptop on Hicks — asking
`@10.0.99.1` explicitly so a local cache cannot answer instead:

```bash
dig +short @10.0.99.1 doubleclick.net A
dig +dnssec @10.0.99.1 example.com A | grep -E '^;; flags'
dig @10.0.99.1 dnssec-failed.org A | grep -E 'status'
dig +short @10.0.99.1 lemmiwinks.matrix.elysium
```

| Query | Expect | It proves |
| --- | --- | --- |
| `doubleclick.net` | `0.0.0.0` | the filter is in the path — through Unbound, a blocked name now blocks |
| `example.com` flags | `ad` among them | Unbound still validates DNSSEC, and the forwarder passed the records it needs |
| `dnssec-failed.org` | `SERVFAIL` | validation is on, not merely flagged |
| `lemmiwinks.matrix.elysium` | `10.0.99.30` | host overrides survived the mode change |

`ad` missing on `example.com` is the failure ADR-0010 warned about — a forwarder
stripping DNSSEC records — and it will look like a wider outage within the hour
as signed zones start to SERVFAIL. Untick *Enable Forwarding Mode* and apply,
then find out why, from the stack side: `enable_dnssec: true` in
`AdGuardHome.yaml` is the setting that was measured to pass RRSIGs through.

**Which forwarder is winning** is worth reading once, because the whole leak
argument in the ADR rests on it. On `morpheus`:

```bash
unbound-control -c /var/unbound/unbound.conf lookup example.com
```

Three forwarders with an RTT each. `10.0.99.40` should be an order of magnitude
under the other two; while it is, Unbound sends nearly everything there.

---

## 4. The test the ADR asked for: stop AdGuard on purpose

> "Unbound marks an unresponsive forwarder down and carries on" is documented
> behaviour, not measured behaviour on this box. It is worth stopping AdGuard on
> purpose once #102 is built and watching resolution continue, rather than
> finding out during the first real outage.
> — ADR-0010, *Verified against the running config*

On `trinity`:

```bash
docker compose -f stacks/sensitive/compose.yaml stop adguard
```

Then from the Hicks laptop, immediately and again a minute later:

```bash
time dig +short @10.0.99.1 example.org A
dig +short @10.0.99.1 doubleclick.net A
```

What to expect, and what to write down:

- **`example.org` answers both times.** The first may be slow — Unbound has to
  time the dead forwarder out before it tries the next, and the number the
  `time` prints is the one to record here. The second is fast: the forwarder is
  marked down and skipped.
- **`doubleclick.net` now returns real addresses.** This is the house resolving
  unfiltered, which is the designed failure. Nothing else changed.
- **Within fifteen minutes, `AdGuardNotAnswering` fires** — `warning`, to the
  default receiver. Let it, if you can spare the quarter hour: it is the only
  proof the alert path for this failure works end to end, and the reason the
  probe was aimed at `10.0.99.40` rather than at pfSense is exactly what this
  test shows — a probe through the normal path would be passing right now.

Then bring it back:

```bash
docker compose -f stacks/sensitive/compose.yaml start adguard
```

Unbound keeps a forwarder marked down for up to fifteen minutes after it stops
answering, so `doubleclick.net` may keep resolving for that long after the
container is healthy. That is not a fault, and it is the one delay in this
design worth knowing about. To skip the wait, on `morpheus`:

```bash
unbound-control -c /var/unbound/unbound.conf flush_infra all
```

then `dig +short @10.0.99.1 doubleclick.net A` → `0.0.0.0` again.

Record the date and the measured timeout in the table below.

| Date | First unfiltered answer took | Filtering resumed after restart in | Alert fired |
| --- | --- | --- | --- |
| *not yet run* | — | — | — |

---

## Reversing it

*Services → DNS Resolver → General Settings*, untick **Enable Forwarding Mode**,
Save, Apply. Unbound is recursive again within the reload. `10.0.99.40` in
General Setup is then inert and can stay or go. No client notices, no lease
renews, and the AdGuard probes keep reporting on a service nobody is using —
disable the two targets in `blackbox-dns.yaml` in the same sitting, or accept
that they are measuring something true and irrelevant.

That the reversal is one checkbox is the property ADR-0010 chose this design
for, and it is worth not eroding: the day something is added that makes AdGuard
harder to remove than this — a client pointed at it directly, a rewrite that
only it answers — is the day to reopen the ADR rather than to add it.

---

## What this does not do

- **It does not filter one machine.** `Mekenna-Laptop` (`10.0.50.69`) has a
  static map handing it `8.8.8.8` and `9.9.9.9` directly, so it never reaches
  Unbound and is never filtered. ADR-0010 records it as deliberate — a work
  machine kept off the household's split-horizon DNS — and nothing here changes
  it. It is the one exception to *clients cannot select around the filter*.
- **It does not make DNS blocking a control.** ADR-0010 is explicit: the design
  fails open on purpose, so nothing may be documented as relying on it for
  security. A name being blocked here is a convenience, and the day it is
  load-bearing for something the design has to change.
- **It does not give AdGuard per-client visibility.** Every query arrives from
  `10.0.99.1`, so the dashboard is one aggregate and per-device rules are not
  possible. If that is ever wanted, reopen the ADR; every workaround leads back
  to the options it rejected.
- **It does not give the name a certificate.** `adguard.matrix.elysium` is a
  host override on `morpheus` ([`add-a-host-override.md`](add-a-host-override.md))
  and, until step-ca issues per-name leaves, a `--dns` SAN on `trinity`'s
  certificate. Neither is DNS forwarding, and both are in the stack README.
