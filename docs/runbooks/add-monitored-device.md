# Runbook: Add a monitored device

Two paths, depending on whether the device can run an agent.

---

## A Linux host

Nothing on the monitoring host changes. Alloy pushes; Prometheus does not need
to be told the host exists.

On the new host:

```bash
sudo mkdir -p /opt/alloy
sudo cp /path/to/HomeLab/stacks/observability/alloy/config.alloy /opt/alloy/

sudo docker run -d \
  --name alloy --restart unless-stopped --privileged \
  --hostname "$(hostname)" \
  -e LOKI_URL=http://10.0.99.20:3100/loki/api/v1/push \
  -e PROMETHEUS_REMOTE_WRITE_URL=http://10.0.99.20:9090/api/v1/write \
  -v /opt/alloy/config.alloy:/etc/alloy/config.alloy:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v /var/log:/var/log:ro \
  -v /:/rootfs:ro \
  -p 127.0.0.1:12345:12345 \
  "$(/path/to/HomeLab/scripts/image-for.sh alloy)" \
    run --server.http.listen-addr=0.0.0.0:12345 \
        --storage.path=/var/lib/alloy/data \
        /etc/alloy/config.alloy
```

The two `*_URL` variables are the only difference from the monitoring host's own
agent — inside the compose stack they default to service names.

The image comes from `compose.yaml` rather than being written out here, so a new
host starts on the same Alloy — tag *and* digest — that the monitoring host runs,
and keeps doing so after Dependabot bumps it. A version copied into this runbook
would be stale from the next bump onward, which is the whole argument in the
header of `scripts/image-for.sh`. If the repository is not on the new host, run
`./scripts/image-for.sh alloy` on the monitoring host and paste the reference it
prints.

`--hostname` is not optional. Alloy labels everything it produces with
`constants.hostname`, which inside a container is the **container ID** unless one
is set — a hex string that identifies nothing and changes every time the
container is recreated. Without it the new host appears in Loki and Prometheus
under a name that is different tomorrow, and `sum by (host)` groups by noise.
The compose stack does the same thing via `ALLOY_HOSTNAME`, written by
`scripts/render-config.sh`.

Keep the image tag in step with `stacks/observability/compose.yaml`. The version
above is the one the stack currently runs; the compose file pins it by digest as
well, which this command deliberately does not — a remote agent that will not
start because a digest moved is worse than one running a slightly older tag.

> [!IMPORTANT]
> **Editing `/opt/alloy/config.alloy` later does nothing on its own.** It is a
> bind mount, and Alloy reads it once at startup. Copying a new one over it
> leaves the running process on the old config with no indication anything is
> wrong — no error, no restart, no change in behaviour except that your edit is
> not in effect.
>
> After any change to that file: `sudo docker restart alloy`. Confirm it took by
> checking the process is newer than the file, which is the one measurement that
> cannot be fooled:
>
> ```bash
> docker inspect -f '{{.State.StartedAt}}' alloy
> stat -c '%y  %n' /opt/alloy/config.alloy
> ```
>
> On the monitoring host itself this is handled by `make up`, via
> `scripts/reload-config.sh`. A standalone agent started with `docker run` has no
> such wrapper, so it is on you.

**Verify** (from the monitoring host, within a minute or two):

```promql
up{instance=~".*<new-hostname>.*"}
```

```logql
{host="<new-hostname>"}
```

The host appears on the Host Overview and Logs dashboards automatically — both
template their host variable from live label values.

**Firewall:** the new host must be able to reach `10.0.99.20` on 9090 and 3100.
If it is not on VLAN 99 or 50, that is a rule you have to add, and one worth
thinking about before you do.

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
