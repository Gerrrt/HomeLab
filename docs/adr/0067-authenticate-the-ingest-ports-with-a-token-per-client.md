# ADR-0067: Authenticate the ingest ports with a token per client

**Status:** Accepted · 2026-09

> [!NOTE]
> Extended to the lab by [#834](https://github.com/Gerrrt/HomeLab/issues/834),
> 2026-10. `alexander` published its own Prometheus and Loki to VLAN 30,
> unauthenticated, for `odin`, `phoenix` and `fenrir`, which was this ADR's
> Context on the segment where it mattered most. `stacks/lab/Caddyfile` is this
> decision's proxy with the lab's clients in the table. Its tokens are the
> lab's own, in `secrets/lab.sops.yaml`, never the estate's. Each client keeps
> a second copy in its own secrets, because no host there can open another's
> file. The one part that does not carry over is `IngestAuthNotEnforced`: the
> lab has no blackbox exporter and no Alertmanager (ADR-0020), so the refusal
> check is a step in `stacks/lab/README.md` rather than a rule. The text below
> is left as written, per ADR-0001.
>
> The estate's ports serve TLS under the estate CA since
> [ADR-0086](0086-serve-the-ingest-ports-over-tls-under-the-estate-ca.md)
> ([#764](https://github.com/Gerrrt/HomeLab/issues/764), 2026-10), which closes
> the "Plain HTTP, for now" paragraph below. The lab's proxy is unchanged.

## Context

[ADR-0012](0012-publish-only-ports-with-an-off-host-consumer.md) settled which
ports the observability stack publishes: those with a named off-host client.
Prometheus (9090) and Loki (3100) passed that test, because the Alloy agents on
`oracle`, `trinity` and `Saruman` push to them and are not scrape targets. That
ADR said, in as many words, that it left them *"an accepted residual, not a
fixed one"*. Neither service authenticates anything. Anything that could route
to `10.0.99.20` could:

- read every metric and every log line;
- inject metrics through `--web.enable-remote-write-receiver`;
- delete log ranges through Loki's delete API, since `auth_enabled: false`.

Default-deny was the whole control. By 2026-09 it was narrower than it had
been: Hicks reached `10.0.99.20` on 3000 only, and `10.0.30.110` had one
explicit pass for Saruman's agent. But it was still one firewall's rule
ordering standing in for authentication, and
[ADR-0002](0002-vlan-segmentation-strategy.md)'s residual still applied to
it: *"A compromised workstation reaches Winterfell."*
[#182](https://github.com/Gerrrt/HomeLab/issues/182) is the work that closes
it.

ADR-0012 answered *who may reach a port*. It did not answer *what they must
prove before they are served*, and a published port needs both answers. That
second answer is what this records. It is a new ADR rather than an edit,
because ADR-0001 makes them immutable.

When the work started, the published ports had more clients than #182 named:

| Client | Where it runs | What it does |
| --- | --- | --- |
| Alloy agent | `oracle` (Docker) | pushes metrics and logs |
| Alloy agent | `trinity` (Docker) | pushes metrics and logs |
| Alloy agent | `Saruman` (native package) | pushes metrics and logs |
| Homepage | `trinity` | queries Prometheus: `targets` and `query` |
| Home Assistant | `trinity` | queries Prometheus: rack power |
| `scripts/deploy-agent.sh` | wherever it is run | arrival check, querying both stores |
| blackbox probes | the monitoring host | health, through the published address on purpose |
| two host timers, ~20 runbooks | the monitoring host | query over `localhost` |

## Decision

**An authenticating proxy holds the published ports, and Prometheus and Loki
move to loopback.** A Caddy service (`caddy` in
`stacks/observability/compose.yaml`) publishes 9090 and 3100 on
`${INGEST_BIND_ADDR}` (`10.0.99.20`). It forwards to `prometheus:9090` and
`loki:3100` over the compose network. The port numbers do not change, so an
agent's URL stays the same and only the header it sends is new. Every consumer
inside the stack already used compose names, so none of them changed.

**One bearer token per client, and a role per token.** An agent token (one
each for `oracle`, `trinity` and `Saruman`) may `POST` the two push endpoints
and nothing else. The reader token may query (`query`, `query_range`,
`targets`, `series` and the label endpoints) and nothing else. Health paths
need no token, so the blackbox probe still tests the publish end to end. Every
other path gets a 401 whatever the token, and that list is an allowlist, not a
denylist. It covers the admin API, `/-/reload` and `/-/quit`, the UI, Loki's
delete and compactor APIs, and anything upstream adds later. The
`stacks/observability/Caddyfile` is the policy, and one `map` there turns a
token into a role.

**Loopback stays unauthenticated.** Prometheus and Loki publish on
`127.0.0.1`, so the host's timers and the runbooks' `curl localhost:9090` keep
working unchanged. A local user on the monitoring host already holds the
Docker socket, the SOPS key and the data volumes, so a token on loopback would
stop nobody.

**The tokens live in `secrets/observability.sops.yaml`.** They reach the proxy
through its environment under compose `${VAR:?}` guards, and they reach each
agent through `scripts/deploy-agent.sh`. That script sends the token over
ssh's stdin, never a command line, and lands it in a 0600 EnvironmentFile or
the container's environment. The reader token is copied into
`secrets/sensitive.sops.yaml` for Homepage and Home Assistant, because that
file is the one trinity can decrypt. `render-config.sh` refuses a token under
32 characters, or two tokens that are equal. An empty token would have made
the bare word `Bearer`, and a space, a credential.

**Plain HTTP, for now.** The tokens cross VLAN 99 in cleartext. The threat
this answers is a compromised host that can *route* to `10.0.99.20`, and the
likeliest one is a workstation on Hicks. Hicks is a different broadcast
domain behind the firewall, so a machine there can reach the ports but cannot
see VLAN 99's switched traffic to sniff a token off it. Seeing that traffic
needs a foothold on VLAN 99 itself, and a foothold there already reaches the
hosts that hold the tokens. TLS on these ports is worth doing and is a
follow-up. It is not a precondition, because it would add a CA distribution
to three agents and two applications on top of this change.

**A proof that the control is on, and a proof that data is still arriving.**
Two blackbox probes ask the published address for a query and for Loki's
delete API with no token, and succeed only on the proxy's own 401 and
challenge. `IngestAuthNotEnforced` pages when either gets any other HTTP
answer. A dead proxy has no HTTP answer, and `EndpointUnreachable` already
pages on the health probes for that. `deploy-agent.sh` no longer asks
whether a host is *listed*. It asks whether data from the agent it just
started has *arrived*: samples and a log line newer than the deploy. A
refused push looks healthy from the agent side, because Alloy retries and
buffers, so only a timestamp settles it.

## Consequences

- **The residual ADR-0012 left is closed**, and `SECURITY.md` now records the
  exposure as fixed. Reaching `10.0.99.20:9090` or `:3100` no longer grants a
  read, a write or a delete. Holding a token grants one role, and neither role
  grants a delete.
- **Adding a monitored host is one more step.** The host needs a key in the
  SOPS file, a line in the Caddyfile's map and a guard in compose.yaml
  (`docs/runbooks/add-monitored-device.md`). A host without them is refused,
  and `deploy-agent.sh` stops before it touches the host if its key is
  missing.
- **Revoking one host is deleting its line.** One host's token never needs
  rotating to revoke another's. The reader token is shared by Homepage, Home
  Assistant and the arrival check, and rotating it means `make up` on both
  hosts.
- **The tokens are readable with `docker inspect`**, on the monitoring host
  and on each Docker agent. That is the same exposure class as
  `GRAFANA_ADMIN_PASSWORD`. Caddy's access log writes the Authorization
  header as `REDACTED`, and it logs only refused requests. Logging accepted
  ones would put a line per push, from every agent, into the Loki those pushes
  are written to.
- **The token comparison is not constant-time.** Caddy's `map` is a string
  match. Against 256-bit tokens, over a network with a millisecond of jitter,
  a timing attack is not a practical one. This is recorded rather than
  engineered away.
- **Order matters on rollout.** Prometheus and Loki ignore an Authorization
  header they were not asked to check, so every client can carry its token
  before the proxy exists. Deploy the agents and trinity first, then
  `make up` on the monitoring host. The other order drops data for as long as
  the gap lasts.
- **`BIND_ADDR` now governs only Grafana and the syslog receiver.** The proxy
  has `INGEST_BIND_ADDR`, and it cannot be a wildcard: Docker cannot publish
  `0.0.0.0:9090` while Prometheus holds `127.0.0.1:9090`.

## Alternatives considered

- **Basic auth.** It was equivalent in strength, and Alloy supports both. It
  was rejected because Caddy wants a bcrypt hash of a basic-auth password. The
  SOPS file would then hold the plaintext for the agents and a hash for the
  proxy, two copies of one secret with nothing to keep them in step. Or it
  would render a hash on every `make up`, and a fresh salt each time would
  churn the mounted file. A bearer token is one value in one place.
- **mTLS per agent.** Stronger, and revocable in the same way. The lab CA
  and `scripts/gen-certs.sh` could issue the certificates. It would also mean
  a certificate lifecycle for every agent, and a renewal path nobody owns yet,
  for a threat the token already answers.
- **Narrowing the firewall instead.** A pfSense rule letting only the known
  agents reach 9090 and 3100 is cheap, and it is still worth having. But it
  does not survive a compromise of any one of those agents, and it is the
  same kind of control #182 exists to stop relying on alone.

Supersedes nothing. It adds to ADR-0012 the question that ADR did not ask.
