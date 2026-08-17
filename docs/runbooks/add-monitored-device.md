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
  -e LOKI_URL=http://10.0.99.20:3100/loki/api/v1/push \
  -e PROMETHEUS_REMOTE_WRITE_URL=http://10.0.99.20:9090/api/v1/write \
  -v /opt/alloy/config.alloy:/etc/alloy/config.alloy:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v /var/log:/var/log:ro \
  -v /:/rootfs:ro \
  -p 127.0.0.1:12345:12345 \
  grafana/alloy:v1.6.1 \
    run --server.http.listen-addr=0.0.0.0:12345 \
        --storage.path=/var/lib/alloy/data \
        /etc/alloy/config.alloy
```

The two `*_URL` variables are the only difference from the monitoring host's own
agent — inside the compose stack they default to service names.

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

Three edits, no restart.

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

Keep the OID list tight. The `ilo` module walks the whole HP Insight tree and
produces ~1,355 metrics from one device; that is fine once and a cardinality
problem if repeated.

### 2. Add the credential

```bash
make secrets-edit      # add SNMP_COMMUNITY_NEWDEVICE
```

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
# Does the device answer at all?
snmpwalk -v2c -c '<community>' 10.0.99.40 1.3.6.1.2.1.1.1.0

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
