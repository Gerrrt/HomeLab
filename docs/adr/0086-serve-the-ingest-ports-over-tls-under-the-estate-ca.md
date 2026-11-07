# ADR-0086: Serve the ingest ports over TLS under the estate CA

**Status:** Accepted · 2026-10

## Context

[ADR-0067](0067-authenticate-the-ingest-ports-with-a-token-per-client.md) put
a token-checking proxy on `10.0.99.20:9090` and `:3100` and served it over
plain HTTP. It accepted cleartext tokens on two grounds. First, a workstation
on Hicks can route to the ports but cannot see VLAN 99's switched traffic.
Second, a foothold on VLAN 99 already reaches the hosts that hold the tokens.
It called TLS "worth doing and … a follow-up", and
[#764](https://github.com/Gerrrt/HomeLab/issues/764) is that follow-up.

The second ground was weaker than it read. Saruman's agent pushes from VLAN 30
through a single firewall pass ([`network.md`](../network.md)), so its token
crosses a segment boundary. A firewall that forwards that packet can also read
it. And even on VLAN 99, a reader token sniffed off the wire is a credential
that outlives the foothold that took it.

The proxy has seven clients on four hosts:

- the Alloy agents on `oracle`, `trinity` and `Saruman`, one of them a native
  package deployed from the Mac;
- Homepage and Home Assistant on `trinity`;
- `deploy-agent.sh`'s arrival check;
- the blackbox probes on the monitoring host.

TLS means every one of them must trust a CA.

## Decision

**The proxy terminates TLS with a leaf from the estate CA.** The leaf is
`prometheus.matrix.elysium`, with an IP SAN for `10.0.99.20` because every
client dials the address. `scripts/gen-certs.sh` issues it, like Grafana's
and speedtest-tracker's. The Caddyfile loads it as files: `tls cert key` under
`auto_https off`, because there is no ACME here and nothing for Caddy to
manage.

The ports, the paths and the token policy are unchanged; only the scheme moves.
Plain http to either port gets Caddy's 400, not a redirect. A client left
behind fails loudly, and no push is ever redirected.

**The CA's certificate is committed.** `stacks/observability/alloy/ingest-ca.pem`
is a copy of `certificates/ca.pem`, and the only `.pem` that `.gitignore` lets
through. A certificate is public by construction. Committing it puts it in
every checkout that deploys a client, including the Mac's for Saruman and
trinity's, with no copy step to forget after a re-mint.

`scripts/check_ingest_ca.sh` runs in validate and CI and fails unless the file
is exactly one CA certificate. On the monitoring host it also fails unless the
file matches `certificates/ca.pem`, so a re-mint cannot leave clients trusting
the old root.

**Each client verifies the chain, by the means it has:**

| Client | How it trusts the CA |
| --- | --- |
| Alloy agents | `tls_config { ca_file = sys.env("INGEST_CA_FILE") }` on both writers. `deploy-agent.sh` ships the file into `/etc/alloy` and sets the variable, for the estate's proxy only |
| Arrival check | `curl --cacert` on the committed file |
| Homepage | `NODE_EXTRA_CA_CERTS`: one bundle of the tier root and this CA, because Node reads a single file |
| Home Assistant | `REQUESTS_CA_BUNDLE`: the host's public roots plus this CA. Home Assistant builds every client SSL context from that variable when it is set, and from certifi otherwise (`homeassistant/util/ssl.py`). The variable *replaces* certifi rather than adding to it |
| Blackbox | `http_2xx_lab_ca` for the health probes, and `ca_file` on `http_401_ingest_refused` |

`render-config.sh` builds trinity's two bundles from the committed file.

Every behaviour above was measured on the pinned images before it was relied
on:

- **Alloy:** an empty `ca_file` changes nothing, and a `.pem` in the config
  directory is not loaded as config.
- **Home Assistant:** its own `client_context()` verifies the real leaf with
  the bundle and refuses it with certifi.
- **The proxy**, under its own uid, group and read-only root, with the real
  leaf:
  - health returns 200;
  - no token, and Loki's delete, both return 401 with the realm;
  - plain http returns 400;
  - a client without the CA, or asking for another name, is refused.

**Rollout takes two changes, trust first.** ADR-0067's ordering trick does not
carry over. Prometheus ignored a header it had not asked for, so tokens could
be rolled out first. An https client gets nothing from an http listener, so
there is no overlap to exploit.

1. The first change gave every client its trust while the URLs stayed http.
   It also mounted the leaf, so a key the proxy could not read would surface
   then. It was deployed to every host before the second change.
2. The second change, which this ADR records, flips the proxy and every URL at
   once.

The agents on `oracle` and `Saruman` change only when `deploy-agent.sh` runs.
So they are redeployed straight after the monitoring host applies the flip,
and until then the proxy refuses them.

## Consequences

- **No token crosses any segment in cleartext any more**, including Saruman's
  VLAN 30 → 99 pass. This closes ADR-0067's "plain HTTP, for now".
- **A short gap at cutover is accepted.** For metrics, the agent's
  remote-write WAL holds them until it is redeployed. For logs, `loki.write`
  retries and then drops, so a few minutes of `oracle`'s and `Saruman`'s logs
  can be lost, and `LogEntriesDropped` says how many. To keep the gap short,
  run `make converge` and both redeploys straight after the merge rather than
  waiting for :29.
- **The leaf expires in 825 days.** The probes carry its expiry, so
  `TlsCertificateExpiringSoon` names `prometheus` and `loki` 30 days out.
  Re-issuing is the same `make certs` line followed by `make up`.
- **Re-minting the CA now touches more places.** The trust table in
  [`generate-certificates.md`](../runbooks/generate-certificates.md) lists
  them. `check_ingest_ca.sh` fails until the committed copy is replaced, which
  puts that step in front of whoever re-mints.
- **Home Assistant's public roots now come from the host, not certifi.** Both
  Ubuntu's `ca-certificates` and certifi derive from Mozilla's store, and
  unattended-upgrades keeps the host's copy current.
- **A refusal probe whose handshake fails is silent on its own.** It has no
  status code, so `IngestAuthNotEnforced` cannot fire, and
  `EndpointUnreachable` skips refusal probes. The health probes on the same
  ports, with the same CA, page instead.
- **The lab's proxy is unchanged** (`stacks/lab/Caddyfile`, #834). It still
  serves plain http, and `deploy-agent.sh --monitoring-host 10.0.30.40` still
  speaks it. Whether the lab follows is its own question.

## Alternatives considered

- **A second, TLS-only port to phase clients in.** It would have given an
  overlap. It would also have needed new firewall passes (Saruman's pass covers
  9090 and 3100 only), new ports in ADR-0012's published list, and a second
  migration back. Two PRs and an immediate redeploy cost less.
- **Copying `ca.pem` to each checkout instead of committing it.** This keeps
  `*.pem` free of exceptions. But it means a manual copy to the Mac and to
  trinity, repeated after every re-mint, and nothing notices a stale copy
  until a client refuses the proxy. The committed copy is checked on every
  validate.
- **Bind-mounting a bundle over certifi's `cacert.pem` in Home Assistant.**
  This works too, but it ties the mount path to the image's Python version and
  certifi's layout. `REQUESTS_CA_BUNDLE` is an interface Home Assistant reads
  on purpose.
- **`verify_ssl: false` for Home Assistant.** This encrypts the token but hands
  it to whatever answers on `10.0.99.20`, which is half of what TLS is for.
- **mTLS per agent.** ADR-0067 rejected this, and its reason still holds: a
  certificate lifecycle for every agent, for a threat the token already
  answers.

This ADR supersedes nothing. It closes the "plain HTTP, for now" paragraph of
ADR-0067, which carries a note pointing here.
