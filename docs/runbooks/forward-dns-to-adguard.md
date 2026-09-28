# Runbook: Forward DNS to AdGuard Home

Put the filter one hop behind the resolver the house talks to, the way
[ADR-0010](../adr/0010-keep-the-resolver-on-the-gateway.md) decided, with
AdGuard as the **only** forwarder, the way
[ADR-0055](../adr/0055-forward-to-adguard-alone.md) corrected it. Then prove
the alert that makes that dependency safe.

> [!NOTE]
> **Run on 2026-09-28**, and the first run changed the design. With the public
> resolvers beside AdGuard, as this runbook first said, Unbound spread lookups
> across all three and 38 of 60 blocked names leaked. Steps 2 and 3 below are
> the corrected procedure. ADR-0055 has the measurements.

**Target:** `morpheus` (10.0.99.1), the pfSense web UI; `trinity` (10.0.99.40)
for the failure test
**Time:** ~30 minutes, and the failure test is ten more, taken when nobody needs the internet
**Reversible:** one checkbox, no DHCP change, no lease to wait out

---

## Why this exists

Every client in the estate has exactly one resolver, pfSense, and that does not
change. What changes is what Unbound on `morpheus` does with a name it cannot
answer itself: before this it walks the root servers, and after it forwards
to AdGuard Home on `trinity` and nothing else. Filtering happens behind the
resolver instead of in front of it, and no client VLAN ever holds a DNS path
into Winterfell. **A dead AdGuard now costs the house every outside name**
(internal ones keep resolving from the host overrides). That is why
`AdGuardNotAnswering` is critical at five minutes, and why step 4 exists.

ADR-0010's own verification found the decision costs more than it reads:
before this, **Unbound forwarded to nothing**, so *Enable Forwarding Mode* is
a resolution-mode change, not an edit to a list. It hands a query stream that
reached no third party to AdGuard, and through AdGuard's encrypted upstreams to
Cloudflare and Google. That price was accepted in the ADR. This runbook is
where it is paid, and where what the ADR could not measure is measured: that
DNSSEC survives the forwarder, how much leaks, and how long a dead AdGuard
goes unnoticed.

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

**Only that row.** Delete any public resolvers already listed (`1.1.1.1` and
`8.8.8.8` were there). Every server in this list becomes an Unbound forwarder,
and Unbound picks among them at random within about 400 ms of the fastest, not
in order. Leave *DNS Resolution Behavior* as it is. Save.

**Services → DNS Resolver → General Settings:**

- **Enable Forwarding Mode** — tick it. This is the change.
- **Enable DNSSEC Support** — stays ticked. Do not untick it to make a problem
  go away; step 3 checks it still works through the forwarder.
- **Use SSL/TLS for outgoing DNS Queries to Forwarding Servers** — stays
  unticked. It would send every forwarder DNS-over-TLS on 853, and AdGuard
  listens on plain 53. The hop to `trinity` is on VLAN 99; the hop that leaves
  the house is encrypted by AdGuard's own upstreams.

Save, then **Apply Changes**. Then **restart `unbound`** under *Status →
Services*, which empties its cache of anything answered before the change.

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

One `forward-zone:` block, `name: "."`, and **one** `forward-addr:` line,
`10.0.99.40`. Zero blocks means the checkbox did not take. More than one line
means a public resolver is still in General Setup, and it will leak (step 3's
last check measures by how much).

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
| `doubleclick.net` | no address: `SERVFAIL` | the filter is in the path. Not `0.0.0.0`: Unbound's DNSSEC validation rejects AdGuard's block answer for lack of a proof that the zone is unsigned ([ADR-0055](../adr/0055-forward-to-adguard-alone.md)). A **real** address here is a leak |
| `example.com` flags | `ad` among them | Unbound still validates DNSSEC, and the forwarder passed the records it needs |
| `dnssec-failed.org` | `SERVFAIL` | validation is on, not merely flagged |
| `lemmiwinks.matrix.elysium` | `10.0.99.30` | host overrides survived the mode change |

`ad` missing on `example.com` is the failure ADR-0010 warned about — a forwarder
stripping DNSSEC records — and it will look like a wider outage within the hour
as signed zones start to SERVFAIL. Untick *Enable Forwarding Mode* and apply,
then find out why, from the stack side: `enable_dnssec: true` in
`AdGuardHome.yaml` is the setting that was measured to pass RRSIGs through.

**The leak test.** One cached answer proves little, so ask for names nothing
can have cached: random subdomains of a blocked domain. On `morpheus` (its
shell is FreeBSD `sh`, so no `\s` in patterns and no `$RANDOM`):

```sh
b=0; l=0; for i in $(jot 60); do
  a=$(drill "p$(jot -r 1 100000 999999)q$i.doubleclick.net" @127.0.0.1)
  case "$a" in *"rcode: SERVFAIL"*|*0.0.0.0*) b=$((b+1));; *) l=$((l+1));; esac
done; echo "blocked=$b leaked=$l"
```

`blocked=60 leaked=0`. On 2026-09-28, with three forwarders, it read
`blocked=22 leaked=38`; with AdGuard alone, `60` and `0`.

---

## 4. Stop AdGuard on purpose, and time the page

Since [ADR-0055](../adr/0055-forward-to-adguard-alone.md) there is no fallback
to prove. What this proves is that the page reaches you, and about how long
the house is without outside names before it does. **Do not silence
`AdGuardNotAnswering` for this**: the page is the result. Pick a moment
nobody in the house needs the internet for about ten minutes.

On `trinity`:

```bash
docker compose -f stacks/sensitive/compose.yaml stop adguard
```

Then from a Hicks machine:

```bash
dig @10.0.99.1 example.org A | grep status
dig +short @10.0.99.1 lemmiwinks.matrix.elysium
```

`SERVFAIL` for the outside name, and `10.0.99.30` for the internal one: the
host overrides do not need AdGuard. Note the time, and wait for the page.
`AdGuardNotAnswering` is critical with `for: 5m`, so with the one-minute
probe and Alertmanager's grouping it arrives about six to seven minutes after
the stop. **If nothing has arrived by ten minutes, start AdGuard anyway**,
then find out why the alert did not.

```bash
docker compose -f stacks/sensitive/compose.yaml start adguard
```

Unbound may keep the forwarder marked down for a short while after AdGuard
is healthy. To skip the wait, on `morpheus`:

```bash
unbound-control -c /var/unbound/unbound.conf flush_infra all
```

Then step 3's leak test once more, and wait for the *resolved* notification.

| Date | Stopped | Page arrived | DNS back | Resolved notice |
| --- | --- | --- | --- | --- |
| *not yet run* | — | — | — | — |

**If AdGuard cannot be brought back** and the house needs DNS now: add
`1.1.1.1` under *System → General Setup → DNS Servers* on `morpheus` and
apply. Outside names resolve again, unfiltered. Take it back out once AdGuard
answers, or the leak ADR-0055 measured comes back with it.

---

## Reversing it

*Services → DNS Resolver → General Settings*, untick **Enable Forwarding
Mode**, Save, Apply, and put the public resolvers back in *System → General
Setup* for the firewall's own lookups. Unbound is recursive again within the
reload. Disable the two targets in `blackbox-dns.yaml` in the same sitting, or
`AdGuardNotAnswering` will page about a service nobody uses.

That the reversal is still two pages and no client change is the property
ADR-0010 chose this design for. The day something makes AdGuard harder to
remove than that (a client pointed at it directly, a rewrite that only it
answers) is the day to reopen the ADR rather than to add it.

---

## What this does not do

- **It does not filter one machine.** `Mekenna-Laptop` (`10.0.50.69`) has a
  static map handing it `8.8.8.8` and `9.9.9.9` directly, so it never reaches
  Unbound and is never filtered. ADR-0010 records it as deliberate — a work
  machine kept off the household's split-horizon DNS — and nothing here changes
  it. It is the one exception to *clients cannot select around the filter*.
- **It does not make DNS blocking a control.** ADR-0010 is explicit, and
  ADR-0055 does not change it: a name being blocked here is a convenience,
  and nothing may be documented as relying on it for security. What changed
  is availability. The design now **fails closed** for outside names when
  AdGuard is down, and `AdGuardNotAnswering` paging is what makes that
  acceptable.
- **It does not give AdGuard per-client visibility.** Every query arrives from
  `10.0.99.1`, so the dashboard is one aggregate and per-device rules are not
  possible. If that is ever wanted, reopen the ADR; every workaround leads back
  to the options it rejected.
- **It does not give the name a certificate.** `adguard.matrix.elysium` is a
  host override on `morpheus` ([`add-a-host-override.md`](add-a-host-override.md)),
  and its certificate comes from step-ca over ACME like every name on the tier.
  Neither is DNS forwarding, and both are in the stack README.
