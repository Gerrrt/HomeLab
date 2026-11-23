# ADR-0128: Give `prometheus` a key-only `sshd` and no host firewall

**Status:** Accepted · 2026-11

## Context

`prometheus` holds more than any other host in the estate:

- the estate's CA key ([ADR-0043](0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)
  keeps it here);
- the observability stack's age key, which opens every volume backup set;
- every metric and log the estate writes.

Converge runs here as the operator's account, which is in `sudo` and
`docker`. So whoever logs in as that account owns all three.

The root-only reads that finished the audit of 2026-11-13 were taken on
2026-11-23. They found the way in wider than on the hosts this one
administers:

- `sshd -T` reads `passwordauthentication yes`, from cloud-init's
  `50-cloud-init.conf`, the only drop-in present;
- `x11forwarding yes`;
- `ufw` inactive, and no other host firewall.

`permitrootlogin no` and `permitemptypasswords no` already hold.

`phoenix` ([ADR-0117](0117-give-phoenix-a-key-only-sshd-and-a-default-deny-inbound-policy.md)),
`trinity`, `heimdall` and the lab's key holders (`alexander`, `odin`) all take
keys only. The host holding the CA and the age key that opens the backups is
the one that still takes a password.

Who reaches `22` here:

- **Hicks**, by `morpheus`'s pass for `22` to the whole of `10.0.99.0/24`
  ([`network.md`](../network.md), the Hicks table). The source is the segment,
  so every household device on Hicks can try a password.
- **Every host on VLAN 99,** which `morpheus` never filters between.
- Sixty days of `ssh` journal show key logins from four Hicks addresses. They
  also show two password logins from `trinity`, which the change below must
  give a key first.

Docker publishes Grafana (`3000`) and speedtest-tracker (`8443`) on
`0.0.0.0`. On `10.0.99.20` it publishes the ingest proxy's `9090` and
`3100`, and Alloy's syslog listener on `6514`. Docker's rules run ahead of `ufw`'s for published ports, so a
`ufw` policy here would govern `22` alone. That was the finding on `trinity`
too (changelog, 2026-11-23).

## Decision

**`sshd` on `prometheus` is key-only.** A drop-in,
`/etc/ssh/sshd_config.d/10-prometheus.conf`, sorts ahead of cloud-init's
`50-cloud-init.conf`. `sshd` keeps the first value it reads, so the drop-in
wins without the installer's file being edited. It sets:

- `PasswordAuthentication no` and `KbdInteractiveAuthentication no`;
- `PermitRootLogin no`;
- `X11Forwarding no`.

`authorized_keys` keeps the machines the host is administered from: Hicks's
workstations, and `trinity`'s key if the operator still logs in from there.
Each proves a key login before the drop-in goes in. That ordering is the
whole risk of the change, so the runbook makes it a check rather than a
reminder.

**No host firewall, by decision,** as on `trinity`. The only port a `ufw`
policy would cover is `22`, and the key is the control there. The published
ports are fenced elsewhere:

- `morpheus` admits Hicks to `3000` and `8443` only;
- on `9090` and `3100`, the ingest proxy serves a push or a query only to a
  token, over TLS
  ([#182](https://github.com/Gerrrt/HomeLab/issues/182),
  [#764](https://github.com/Gerrrt/HomeLab/issues/764));
- on `6514`, Alloy's syslog listener takes TLS only, and only with
  `morpheus`'s pinned client certificate. It keeps a line only when the
  connection's source address is on its sender list
  ([#1049](https://github.com/Gerrrt/HomeLab/issues/1049),
  [#844](https://github.com/Gerrrt/HomeLab/issues/844),
  `stacks/observability/alloy/syslog.alloy`);
- Alertmanager and the rest bind to loopback.

A host firewall that did cover those ports would have to be written in
`DOCKER-USER`. A mistake there drops the agents' pushes from every host,
on the one host whose job is to notice that the others have gone quiet.

**Nothing converges host configuration here, so this is applied by hand.**
The step is [`restore-the-stack.md`](../runbooks/restore-the-stack.md)
§*Make `sshd` key-only*. Step 0 of a rebuild (§3) applies it in the same
place. The step ends with the checks that prove both halves.

## Alternatives considered

- **`ufw` default-deny, as on `phoenix`.** Declined. It would cover `22`
  alone, because Docker's rules run first for every other port. On `22` it
  would narrow the source to Hicks and VLAN 99, which is already everything
  that can route here. It adds a second tool's state to read in every audit,
  and no control.
- **Rules in `DOCKER-USER`** to narrow the published ports by source.
  Declined for now. `morpheus` already narrows the Hicks side. On VLAN 99,
  the ingest proxy's tokens bound the agents, and the syslog listener's
  pinned certificate bounds `6514`. A wrong rule fails
  silently, on the monitoring host itself.
- **`AllowUsers` naming the operator.** Not needed today. The host has one
  login account, and the unused `prometheus` user has `/bin/false` (the
  2026-11-13 audit's finding 7). Reopen it if a second login account appears.
- **Leave passwords on and rely on `morpheus`.** Declined. `morpheus`'s pass
  is the whole of Hicks, a segment of household devices.

## Consequences

- **A lost key now locks a workstation out,** where before it fell back to a
  password. The recovery path is the laptop's own keyboard and screen in the
  rack, where a local login still takes a password.
- **`trinity`'s logins here need a key,** or stop. Its runbook already gives
  `prometheus`'s key to `trinity`. The reverse direction is new.
- **The published ports keep their current fence:** `morpheus` by
  destination, the ingest proxy by token, and the syslog listener by
  certificate and sender address. This ADR does not change them.
- **Reopened by:**
  - a host listener on something other than `22` that is not loopback;
  - `morpheus`'s Hicks pass narrowing to named workstations, which would let
    `sshd` or a firewall name them as well;
  - a converger for host configuration, which would carry this drop-in
    instead of the runbook.
