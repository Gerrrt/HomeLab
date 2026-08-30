# ADR-0012: Bind the unauthenticated ports to loopback

**Status:** Accepted · 2026-08

## Context

The observability stack published four services to every VLAN the monitoring
host can reach, because a single `BIND_ADDR` in `.env.example` governed all of
them and shipped as `0.0.0.0`. Only one of the four authenticates.

The other three do not, and each has a write surface:

- **Prometheus** runs with `--web.enable-remote-write-receiver`, so anything
  that can reach 9090 can inject metrics, and `--web.enable-lifecycle`, so it
  can force a config reload.
- **Loki** runs `auth_enabled: false`, which is correct for a single-tenant
  store but leaves the push and delete APIs open to whoever arrives.
- **Alertmanager** lets any caller create a silence.

The last is the one that decided this. Silencing an alert is a quiet way to
switch off monitoring, and the record of the act lives in the system being
switched off. It is the only one of the three whose abuse is designed to leave
no trace.

[ADR-0002](0002-vlan-segmentation-strategy.md)'s default-deny meant only Hicks
(50) could reach Winterfell (99) at all, so this was never exploitable from an
untrusted segment. But that made the firewall the entire control with nothing
behind it, and ADR-0002 itself already records the relevant weakness: *"A
compromised workstation reaches Winterfell."* One rule stood between an
ordinary desktop compromise and write access to the metric and log stores.

Investigating turned up the fact that made this cheap to fix. **Nothing outside
this host consumes those three services.** Prometheus's scrape targets,
Grafana's datasources, Alertmanager's ruler URL and the local Alloy's push
endpoints all address services by compose name on the internal network, never by
a published host port. `morpheus` reaches Loki through Alloy's syslog receiver
rather than directly, and per
[#88](https://github.com/Gerrrt/HomeLab/issues/88) no other host runs an agent
yet. The wide bind was buying nothing that was actually being used.

Two ports do have off-host clients that cannot be argued away: Grafana, opened
in a browser from Hicks, and Alloy's syslog receiver, which pfSense pushes to.

## Decision

Exposure is earned per service, not granted by a shared default.

Prometheus, Alertmanager and Loki bind to `127.0.0.1`, hard-coded in
`compose.yaml` beside the Alloy debug UI that already did so. `BIND_ADDR`
survives, now governing only the two ports that earned it — Grafana, which
earns it by authenticating and being the one UI meant for a human, and the
syslog receiver, which earns it because pfSense cannot reach loopback.

Loopback is hard-coded rather than made a second variable. `.env` is regenerated
from `.env.example` on every `make up`, so a variable would advertise a runtime
knob the deploy path does not actually provide; and widening one of these ports
hands a whole VLAN write access to the stores, which belongs in a reviewed diff
that trips the pull request template's *"No new port published to a VLAN that
could not already reach the service"* checkbox.

No service flags change. `--web.enable-remote-write-receiver` is what #88 will
need, `--web.enable-lifecycle` is what `scripts/reload-config.sh` uses from
inside the container, and Loki's `auth_enabled: false` is correct for one
tenant. Behind a loopback bind none of the three is an exposure, and removing
them would cost capability to buy nothing.

## Consequences

- The firewall is no longer the only control. A compromised host on Hicks can
  still reach Grafana, which asks it for a password.
- **Deploying an agent to another host (#88) now has a prerequisite.** The bind
  must be widened in `compose.yaml` before Alloy on `Saruman` or `oracle` can
  remote-write, and the firewall rule alone is no longer sufficient.
  `runbooks/add-monitored-device.md` states both halves; without that, the
  failure is an agent logging connection-refused against a host that answers
  ping.
- Alertmanager's `--web.external-url` still points at `10.0.99.20:9093`, so the
  `externalURL` link carried in webhook payloads now only opens on the
  monitoring host. It is left pointing at the real address because that is
  where the service is. Off-host, silences are in Grafana under Alerting, which
  proxies Alertmanager over the compose network behind a login; on-host,
  `docker exec alertmanager amtool` still works.
- The runbooks were already written from the monitoring host, so their
  `curl localhost:...` verification steps are unaffected.
- This is a smaller decision than ADR-0002 and does not supersede it. It fills
  in the layer that ADR-0002's consequences section admitted was missing, at a
  scale where a bastion is still not worth building.
