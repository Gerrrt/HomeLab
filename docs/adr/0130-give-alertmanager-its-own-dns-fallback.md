# ADR-0130: Give Alertmanager its own DNS fallback

**Status:** Accepted · 2026-11

## Context

[ADR-0055](0055-forward-to-adguard-alone.md) makes AdGuard on `trinity` the
only forwarder behind Unbound on `morpheus`, and accepts what follows: while
AdGuard is down, nothing in the house resolves an outside name. It makes that
failure loud, with `AdGuardNotAnswering` at critical, and short.

The page that announces the failure needs DNS to leave the house. Alertmanager
on `prometheus` resolves through Docker's embedded resolver, which forwards to
`morpheus`. Its receivers are:

- **the in-house ntfy,** `ntfy.matrix.elysium`, which runs on `trinity`. Its
  name is a host override that `morpheus` answers itself, without AdGuard;
- **ntfy.sh,** the second copy of every urgent and security page;
- **healthchecks.io,** `hc-ping.com`, the heartbeat that pages when
  Alertmanager goes quiet.

Today, the cases are:

| What is down | In-house ntfy | ntfy.sh copy | Heartbeat | What you hear |
| --- | --- | --- | --- | --- |
| AdGuard alone | Arrives | Fails to resolve | Fails to resolve | The in-house page, then healthchecks.io calling Alertmanager dead |
| All of `trinity` | Host down | Fails to resolve | Fails to resolve | Only healthchecks.io calling Alertmanager dead |

The usual cause is the second row: `trinity` rebooting, off, or waiting at its
passphrase prompt. Then the only page names the wrong machine. It happened
on 2026-11-13, when every host was rebooted at once. Alertmanager logged
`lookup hc-ping.com … server misbehaving` from 18:21 to 18:23 while `trinity`
came up, and `AlertmanagerNotificationsFailing` fired. The audit of
`prometheus` that day recorded it as finding 4.

ADR-0055 rules out the obvious fix. A public forwarder beside AdGuard on
`morpheus` let a third of the house's lookups through unfiltered, and pfSense
cannot express `forward-first`. So a fallback has to cover the alert path
alone.

Three things were measured on `prometheus` on 2026-11-23 (Docker 29.9.1):

- **VLAN 99 already reaches public resolvers.** `1.1.1.1` and `9.9.9.9`
  answered `hc-ping.com` over UDP and TCP. blackbox-exporter's `8.8.8.8:53`
  probe ([`security.md`](../security.md)) uses the same path. Nothing in
  ADR-0129 closes it.
- **`morpheus` answers `SERVFAIL` when it cannot forward.** A name AdGuard
  blocks gets the same answer, which is why the test below could use one
  without taking AdGuard down. ADR-0055 explains the `SERVFAIL`.
- **Docker's embedded resolver tries the next server on `SERVFAIL`, in
  order.** A scratch container on a user-defined network, as Alertmanager is,
  was given `--dns 10.0.99.1 --dns 1.1.1.1`. It resolved `doubleclick.net` to
  a real address from `1.1.1.1` after `morpheus` returned `SERVFAIL`. It
  still resolved `ntfy.matrix.elysium` to `10.0.99.40` from `morpheus`. With
  `morpheus` alone, `doubleclick.net` did not resolve.

## Decision

**Alertmanager gets its own resolver list: `morpheus` first, then two public
resolvers from different operators.** In
[`stacks/observability/compose.yaml`](../../stacks/observability/compose.yaml):

```yaml
dns:
  - 10.0.99.1
  - 1.1.1.1
  - 9.9.9.9
```

`morpheus` stays first, so every name it can answer comes from it. That
includes the `matrix.elysium` overrides, which no public resolver knows. A
public resolver is asked only when `morpheus` fails, and then only for
Alertmanager's own lookups: its three receiver hosts.

The house's DNS does not change. ADR-0055 stands for every client, and
filtering is not weakened anywhere a person browses.

## Alternatives considered

- **A public forwarder on `morpheus`.** Declined: it is ADR-0010's fallback,
  which ADR-0055 measured leaking a third of the house's lookups past the
  filter.
- **Pin the receivers' addresses** with `extra_hosts`. Declined. ntfy.sh and
  healthchecks.io sit behind addresses their operators change without
  notice, and a stale pin fails silently on the path that must not.
- **Add the fallback to the host,** in systemd-resolved. Declined: Docker
  takes its upstreams from the host, so every process and container on
  `prometheus` would get the fallback. That is more than the alert path
  needs.
- **Accept it.** The failure is loud, not silent. Declined, because what is
  loud is wrong: the page blames Alertmanager for an outage on `trinity`, at
  the moment the right page matters most.

## Consequences

- **With `trinity` down, the urgent pages reach ntfy.sh.** That covers
  `AdGuardNotAnswering`, and `trinity`'s `InstanceDown` once it is due. The
  heartbeat keeps pinging, so healthchecks.io no longer calls Alertmanager
  dead for a problem on another host. The in-house copy still cannot arrive
  while `trinity` is down, because it runs there.
- **Alertmanager's lookups bypass AdGuard while `morpheus` cannot answer.**
  They are three hostnames, all of them notification services, so nothing is
  lost by not filtering them. The query leaves the house only in that window.
- **An internal name reaches a public resolver if Unbound fails while
  `morpheus` keeps routing.** The `matrix.elysium` overrides are Unbound's,
  so a stopped or wedged Unbound fails them along with every outside name.
  Docker then asks `1.1.1.1` and `9.9.9.9` for `ntfy.matrix.elysium`. They
  answer `NXDOMAIN`, and the in-house copy fails as it would have anyway, but
  the name has left the house. That is accepted: the name is already
  published in this repository, and the query carries nothing else. A whole
  `morpheus` outage leaks nothing, because then there is no route out either.
- **The fallback depends on Docker's resolver behaviour,** measured on 29.9.1.
  After the change is deployed, `nslookup doubleclick.net` inside the
  `alertmanager` container proves it in place: it answers only if the
  fallback works, because `morpheus` returns `SERVFAIL` for that name.
- **Reopen if:**
  - ADR-0055 is reopened by `forward-first` or a second AdGuard, which would
    make `morpheus` itself fail over;
  - VLAN 99 loses its path to public resolvers;
  - Docker changes how its embedded resolver treats `SERVFAIL`.
