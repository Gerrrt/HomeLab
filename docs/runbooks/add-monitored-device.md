# Runbook: Add a monitored device

Four paths: a host that can run an agent, a device that cannot, an endpoint
with a URL, and a resolver — which is asked what it answered rather than
whether it can be reached.

---

## A Linux host

Nothing on the monitoring host changes. Alloy pushes; Prometheus does not need
to be told the host exists.

One command, from any checkout of this repository that can ssh to the host —
the monitoring host for anything on VLAN 99, your workstation for anything
else:

```bash
./scripts/deploy-agent.sh <user>@<host>
```

`make deploy-agent ARGS="<user>@<host>"` is the same thing. Run it again to
update: after a change under `stacks/observability/alloy/`, after Dependabot
bumps the Alloy image, or because you are not sure what a host is running. It
converges the host on this checkout every time, and nothing on the host is
edited by hand.

What it does, in order: reads the image and version out of `compose.yaml` via
`scripts/image-for.sh` (the one place a version lives); copies the agent
config to the host and checks the copy byte for byte; installs or recreates
the agent with the hardening `compose.yaml` applies to the monitoring host's
own; waits for the process to stay up for ten seconds and then for a full
minute of its log with no `level=error`; and asks Prometheus and Loki whether
the host has arrived. It picks the runtime from what the host has — a `docker`
binary means the Docker runtime, otherwise the native package — and
`--runtime docker|native` forces it.

### On a Docker host

The account needs to be in the `docker` group and nothing else — no sudo, and
nothing lands on the host's filesystem. The config goes in a named volume,
`alloy-config`, and the agent's WAL and positions in another, `alloy-data`, so
a recreate keeps its place. The container is `compose.yaml`'s `alloy` service
written out flag for flag: no capabilities, `no-new-privileges`, `cgroupns
host`, the syslog-owning group and the image's own group added, the Docker
socket and `/var/log` and `/` read-only, the debug port on loopback. What it
does not have is `--privileged` and a mount of `/var/lib/docker/containers`,
both of which the first version of this page told you to add and #188 later
measured as unnecessary.

To see what a host is running: `docker exec alloy cat /etc/alloy/config.alloy`.
To change it: change the repository and run the script again. Editing a file
on the host is not a thing that can be done any more, which is the point — the
previous shape was a bind mount that Alloy read once at startup, so a copied-in
change silently did nothing until someone remembered to restart.

### On a host without Docker — the native package

`Saruman` is a Proxmox hypervisor, and Docker does not belong on one: Proxmox
says run it in a guest, and Docker rewrites the host's iptables, which the
Proxmox firewall ADR-0014 relies on shares. So the agent there is the `alloy`
`.deb` from the GitHub release matching the compose tag, installed with
`apt-get` from a downloaded file rather than from a repository, so that the
version still lives in exactly one place.

The account needs to be root or have passwordless sudo. The script writes
`/etc/alloy/` (only `config.alloy` — there is no Docker socket, so
`docker.alloy` would just log errors) and `/etc/default/alloy`, which the
packaged unit reads as its environment: the two endpoint URLs,
`ALLOY_HOSTNAME`, and `ALLOY_ROOTFS=/` because there is no `/rootfs` bind
mount. The service runs as the package's `alloy` user, added to
`systemd-journal` and `adm` so the journal and `/var/log` are readable, the
same job `group_add` does in the container. Debian 13 has no rsyslog, so the
`auth.log` and `syslog` file sources find nothing there and the journal carries
everything. Logs are `journalctl -u alloy`.

### The host label

Everything the agent sends is labelled with `ALLOY_HOSTNAME`, which the script
sets from the host's own `hostname`. That is the value `instance` and `host`
carry, the prefix of the `<hostname>-metrics` and `<hostname>-alloy` job names,
and what the dashboards' host pickers list — so it is case-sensitive and it is
worth looking at what the script prints. `config.alloy` falls back to
`constants.hostname` if the variable is unset, which inside a container is the
container ID: a name that is different tomorrow. The script never leaves it
unset.

### Expect errors on the first run, and check they stop

On a Docker host Alloy reads container logs from the beginning, and a host with
months of history will push entries older than Loki's retention window, which
Loki rejects:

```text
status=400 ... has timestamp too old: 2025-12-08T09:33:33Z,
oldest acceptable timestamp is: 2026-08-23T05:03:12Z
```

That is correct behaviour on both sides. It stops once the agent reaches
entries inside the window — on `oracle`, about forty seconds — and the script
waits for a sixty-second window with none before it reports success. If you
check by hand, read stderr: Alloy logs there, and
`docker logs alloy | grep -c level=error` is always `0` because the pipe only
carries stdout. `docker logs --since 60s alloy 2>&1 | grep -c level=error` is
the count. The first version of this page had the former, and it passed every
time for the wrong reason. Two lines are noise and the script ignores exactly
those: cAdvisor's `rootDiskErr` while sizing overlay layers, which a container
without `DAC_READ_SEARCH` cannot always do — partial, and the one filesystem
series the Docker Containers dashboard charts is a blkio counter that does not
depend on it — and node_exporter's one-time `udev` line at startup.

### Verify

The script does this itself when it can reach the monitoring host; from
anywhere else, within a minute or two:

```promql
up{instance="<hostname>"}
```

Three jobs on a Docker host — `<hostname>-metrics`, `<hostname>-alloy`,
`integrations/cadvisor` — and two on a native one.

```logql
{host="<hostname>"}
```

The host appears on the Host Overview and Logs dashboards automatically — both
template their host variable from live label values — and `RemoteWriteJobStale`
covers it from the first push, because it matches the job-name convention
rather than a list.

### Firewall

The host must reach `10.0.99.20` on 9090 and 3100. From VLAN 99 or 50 that is
already true. From anywhere else it is a rule you have to add, and one worth
thinking about before you do — `security.md` names "a lab VM escaping into the
house" as a threat, and the control is that VLAN 30 is reachable only *from*
trusted, never *to* it.

`Saruman` is the worked example. It sits on VLAN 30 with an attack VM planned
for the same segment (ADR-0014), and the decision — recorded against ADR-0007,
which had said the opposite — is that the hypervisor's *own* telemetry crosses
into Winterfell over one narrow pass, while the lab guests' does not. The rule,
on the **ImaginationLAN** interface:

| Action | Source | Destination | Ports | Log |
| --- | --- | --- | --- | --- |
| pass, TCP | `10.0.30.110` | `10.0.99.20` | 9090, 3100 | **off** |

Place it **above** the ADR-0014 tripwire (`vlan30 net → Internal_Segments`,
pass + log). Below it, every push from `Saruman` is a logged pass on the
tripwire, and the Loki rule #234 builds on that will fire on the agent doing its
job. Not logged, for the same reason. The script cannot check any of this; what
it can do is tell you the host is up and Prometheus has not heard from it,
which is what a missing rule looks like.

---

## An SNMP device

Three steps, no restart. They touch five files:

| File | What goes in it |
| --- | --- |
| `snmp-exporter/generator.yaml` | the auth block and the module (step 1) |
| `secrets/observability.sops.yaml` | the real community, via `make secrets-edit` (step 2) |
| `scripts/render-config.sh` | the key name, in the `REQUIRED` array (step 2) |
| `secrets/observability.example.yaml` | the key name and a `change-me` placeholder (step 2) |
| `prometheus/targets/snmp.yaml` | the target and its labels (step 3) |

`make validate` cross-checks all of these against each other, so forgetting one
is caught before it reaches a device. The `snmp-generate` target used to carry a
sixth copy of the list; it now derives that from `targets/snmp.yaml`, so there is
nothing to update there.

### 1. Define how to poll it — `snmp-exporter/generator.yaml`

```yaml
auths:
  auth_newdevice:
    community: ${SNMP_COMMUNITY_NEWDEVICE}
    security_level: noAuthNoPriv
    version: 2

modules:
  newdevice:
    walk:
      - 1.3.6.1.2.1.2.2      # IF-MIB::ifTable
```

Keep the OID list tight. The `ilo` module walks the HP Insight tree and produces
~1,600 metrics from one device; that is fine once and a cardinality problem if
repeated.

Prefer listing the subtrees you want over the vendor's enterprise root. Several
vendors define that root in more than one MIB under slightly different names,
which leaves net-snmp with sibling nodes for the same OID; the generator
descends only the first and quietly emits a handful of metrics instead of
thousands. The `ilo` module walks seven explicit `1.3.6.1.4.1.232.*` subtrees
for exactly that reason.

Regenerating `snmp.yaml` after editing this file needs the vendor MIBs, which
are not in the repository:

```bash
make snmp-mibs        # one-off, ~6 MB into a gitignored mibs/
make snmp-generate
```

`snmp-generate` reports the metric count before and after and warns if the total
dropped — `snmp.yaml` is marked `-diff` in `.gitattributes`, so a regression is
not something you can eyeball in a diff.

### 2. Add the credential

```bash
make secrets-edit      # add SNMP_COMMUNITY_NEWDEVICE
```

Add the same key name to [`secrets/observability.example.yaml`](../../secrets/observability.example.yaml)
with a `change-me` value, so the required set stays discoverable without a
decryption key.

Give it its own community. Reusing one across devices means a single captured
SNMPv2c packet — which is cleartext — grants read access to all of them.

Then add the variable to the `REQUIRED` array in `scripts/render-config.sh`.
That array is the single list — the substitution loop below it is derived from
`REQUIRED`, filtered to `SNMP_COMMUNITY_*`, so there is no second place to
forget.

Forgetting it fails closed: `render-config.sh` greps the rendered file for any
surviving `${SNMP_COMMUNITY` and refuses to continue, so you get an error at
render time rather than an exporter polling with an empty community.
`make validate` also checks that every device in `targets/snmp.yaml` has a
matching key here, in `secrets/observability.example.yaml`, and in
`generator.yaml`.

### 3. Add the target — `prometheus/targets/snmp.yaml`

```yaml
- targets: ["10.0.99.40"]
  labels:
    module: newdevice
    auth: auth_newdevice
    device: <hostname>
    role: <what it does>
    vlan: "99"
```

`module` and `auth` become query parameters and are then dropped, so they never
land as metric labels. `device`, `role` and `vlan` do persist and are what alert
annotations use.

### 4. Apply

```bash
make render && make up      # re-render snmp.yaml with the new community
```

Prometheus re-reads the targets file every 5 minutes on its own — no restart
needed for the target itself. The `make up` is for snmp-exporter picking up the
new module.

### Verify

```bash
# Does the device answer at all? (reads the community from SOPS rather than
# taking it on the command line, where ps would expose it)
./scripts/snmp-verify.sh --device <hostname>

# Does the device answer the walk you are about to configure? One subtree at a
# time, GETBULK at the exporter's request shape, community never in argv.
./scripts/snmp-walk.sh --device <hostname> 1.3.6.1.2.1.1

# Does the exporter understand it?
curl -s 'http://localhost:9116/snmp?target=10.0.99.40&module=newdevice&auth=auth_newdevice' | head
```

Then **Prometheus → Status → Targets**, job `snmp`, and confirm the new instance
is `UP`.

### 5. Document it

Add a row to [`docs/network.md`](../network.md) with the MAC truncated to its
OUI, and consider whether it needs an alert rule in
`prometheus/rules/network.rules.yaml`. A device nobody alerts on is a device
nobody notices failing.

## A web endpoint

Anything with a URL — a service on this host, a device's management page —
can be probed from the outside by blackbox-exporter, which is a different
question from whether its process or its SNMP agent answers. One file, no
restart, and one check first:

```bash
# Does the endpoint do what you are about to say it does? The module is chosen
# by what it serves, and the first deploy of this file got that wrong.
docker exec blackbox-exporter wget -qO- \
  'http://localhost:9115/probe?target=https://10.0.99.40/&module=http_2xx_self_signed' \
  | grep -E '^probe_(success|http_status_code|ssl_earliest_cert_expiry)'
```

`probe_success 1` with the module you intend, then append to
`prometheus/targets/blackbox.yaml`:

```yaml
- targets: ["https://10.0.99.40/"]
  labels:
    module: http_2xx_self_signed   # http_2xx_lab_ca | http_2xx_self_signed | http_2xx_plain
    name: <what the alert says>
    role: <what it does>
    host: <hostname, as network.md has it>
    via: address
```

The table at the top of `blackbox/blackbox.yaml` says which module fits. A
certificate the lab CA issued gets `http_2xx_lab_ca` and is verified; one the
device made for itself gets `http_2xx_self_signed`, which reads its expiry and
trusts nothing. Both feed the 30-day and 7-day expiry alerts, so a self-signed
management page is watched for the one thing about it that changes.

If the endpoint has a name people type, add a second block with that URL and
`via: dns`, same `name`. That pair is what lets `EndpointNameNotResolving` tell
"the resolver is broken" from "the service is down" — see the wiki's two
entries.

Prometheus re-reads the file within five minutes. Then **Prometheus → Status →
Targets**, job `blackbox`, and confirm the new instance is `UP` — an `UP` there
means the exporter answered, so check `probe_success` in the panel, not the
target state.

If the probe from the exporter timed out, look at the firewall before the
device: from `10.0.99.20` a segment is unreachable unless a rule on the
Winterfell interface says otherwise ([ADR-0013](../adr/0013-segment-access-as-implemented.md)).
The iLO and pfSense UI targets sit disabled in `targets/blackbox.yaml` for
exactly that reason, with the rule each needs written beside them. Do not
enable a target that fails today — it pages `urgent` until someone changes the
firewall, and a permanently-red check is one the operator learns to scroll
past.

---

## A DNS resolver

A resolver is the one thing here that can be *asked a question*, so it is
monitored by what it answers rather than by whether the port is open. That
distinction is the whole reason this section exists:
[ADR-0010](../adr/0010-keep-the-resolver-on-the-gateway.md) puts AdGuard Home
behind Unbound with the public upstreams listed alongside it, so when it dies
the house keeps resolving and nothing reports anything. (Neither the filter nor
the forwarding is deployed yet — the targets ship disabled, see below.)

**Aim the probe at the resolver itself, never through the normal path.** A
query to pfSense is answered by whichever forwarder is alive and passes
whatever the filter is doing, which is exactly the check that would have looked
right for three weeks while filtering was off (#126).

Two modules in `blackbox/blackbox.yaml` ask the two questions. Unlike an http
module, a `dns` module carries its own query, so the module *is* the question:

| Module | Asks | Fails when |
| --- | --- | --- |
| `dns_answers` | resolve `example.com`, expect an A record | the service is stopped, or answering SERVFAIL |
| `dns_filters` | resolve the blocked canary, expect `0.0.0.0` | blocklists are not loaded, or the blocking mode changed |

Probe both from the running exporter before adding anything, and probe the
negative case too — a filtering check that cannot go red is measuring nothing:

```bash
docker exec blackbox-exporter wget -qO- \
  'http://localhost:9115/probe?target=<resolver>:53&module=dns_filters' \
  | grep -E '^probe_(success|dns_answer_rrs)'
```

Then append both blocks to `prometheus/targets/blackbox-dns.yaml` — a separate
file from `targets/blackbox.yaml`, and a separate scrape job, so that
`EndpointUnreachable` does not page `urgent` for a filter the design lets fail
open:

```yaml
- targets: ["<resolver>:53"]
  labels:
    module: dns_answers
    name: <what the alert says>
    check: liveness
    role: dns-filter

- targets: ["<resolver>:53"]
  labels:
    module: dns_filters
    name: <same name as above>
    check: filtering
    role: dns-filter
```

**Both blocks must share `name`.** `AdGuardNotFiltering` joins the two probes
on it, and a mismatch leaves a rule that loads, reports healthy and can never
fire — the #63 shape, which is why `tests/dns.test.yaml` asserts the join.

Prometheus re-reads the file within five minutes. Confirm under **Status →
Targets**, job `blackbox-dns`, then read `probe_success` for both `check`
values rather than the target state.
