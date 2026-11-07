# ADR-0105: Hold Docker until the monitoring host's address exists

**Status:** Accepted · 2026-11

## Context

The move into the 32U rack power-cycled every host. `prometheus` booted at
23:46 on 2026-11-05 with no carrier on its USB NIC,
which got its link at 21:02 the next evening and its DHCP address,
`10.0.99.20`, at 22:28.

`docker.service` as Ubuntu ships it is already `After=network-online.target`.
That did not help. `network-online.target` only *Wants*
`systemd-networkd-wait-online.service`, and that service gave up after its
default two minutes, at 23:48:26. The target was reached and dockerd started
the observability stack.

`alloy` and `ingest-proxy` publish on `10.0.99.20` specifically.
`INGEST_BIND_ADDR` must be a specific address, because Docker cannot publish
`0.0.0.0:9090` while Prometheus holds `127.0.0.1:9090` (ADR-0067). Docker could
not bind an address the host did not hold. It logged "cannot assign requested
address" and started both containers anyway, with no networks and no published
ports. Three things then hid the fault:

- **Both reported `Up (healthy)`.** A healthcheck runs inside the container,
  against its own loopback, and that was the one part still working.
- **`docker restart` does not repair it.** Only a force-recreate did, by hand,
  on 2026-11-07.
- **The alerts that fired named the symptom, not the cause.**
  `EndpointUnreachable` on `10.0.99.20:9090` and `:3100` and `InstanceDown` on
  `alloy:12345` fired from 22:28 until the recreate. Each says "does not
  answer", which a dead process or a bad certificate also says.

Firewall, Suricata and DHCP logs, and the ingest endpoints, were dark for about
25 hours.

## Decision

**Hold `docker.service` until `10.0.99.20` is assigned, for as long as that
takes, and watch each running container's networking from outside it.**

1. **`homelab-wait-address.service`** (`systemd/host/`) is a oneshot that
   returns only once `ip -4 addr show to 10.0.99.20` finds the address. A
   drop-in on `docker.service` orders docker `After=` it and `Wants=` it.
   There is no timeout. It is self-contained, with no script from the checkout,
   so a late `/home` or a checkout mid-pull cannot hold the boot.
   `scripts/install-host-units.sh` installs it (`make install-host-units`).
   Its `--check`, which `make validate` runs, asserts that the waiter's address
   is `INGEST_BIND_ADDR`'s default. On this host it also asserts that the
   installed copies match the repository's.
2. **`scripts/collect-port-state.py`**, every 15 minutes as the `port-state`
   job, compares each running container's `HostConfig.PortBindings` with the
   ports Docker actually published, and counts its networks.
   **`ContainerNetworkingMissing`** (critical, 10m) fires on either, and its
   description gives the one fix: a force-recreate.

The runbook is `docs/runbooks/recover-a-container-without-its-ports.md`.

## Alternatives considered

- **A longer `systemd-networkd-wait-online` timeout.** It is still a timeout.
  The link was down for 21 hours, and any finite value starts docker without
  the address in the end. It would also delay every unit ordered after
  `network-online.target`, not only docker.
- **`net.ipv4.ip_nonlocal_bind=1`**, so Docker can bind an address the host
  does not hold yet. This repairs this one case and hides the worse one: an
  `INGEST_BIND_ADDR` that is simply wrong would bind silently and receive
  nothing, forever. It also changes behaviour for every socket on the host.
- **Recreate containers when the address appears** (a networkd-dispatcher
  hook). That is more moving parts to keep a state that should never exist.
  The ordering prevents the state. The alert catches it if something else
  produces it.
- **Fix the healthchecks.** A healthcheck that dials the published address
  from inside the container hairpins out through the host. It would turn the
  container unhealthy, and an unhealthy container is not restarted, and a
  restart would not help anyway. The question belongs to the daemon, from
  outside, which is where the collector asks it.

## Consequences

- A boot without the address starts no containers until the address comes.
  Nothing on this host could reach the network meanwhile anyway, and SSH and
  the console are unaffected. `docker ps` and the docker-backed timers hang or
  fail in that window, and `ScheduledJobStale` reports those failures.
- Renumbering this host means changing the waiter and `INGEST_BIND_ADDR`
  together. `install-host-units.sh --check` fails until both agree.
- The ordering and `port-state` cover only this host. Two other stacks
  publish on a specific address and carry the same exposure: `trinity`'s
  AdGuard on `DNS_BIND_ADDR` (`10.0.99.40`) and the lab's ingest on
  `alexander` (`10.0.30.40`). Their NICs are onboard, not USB, and neither has
  shown the fault. A fault there would show as `EndpointUnreachable`, as it
  did here. Extending both pieces to them is a follow-up, not part of this
  decision.
