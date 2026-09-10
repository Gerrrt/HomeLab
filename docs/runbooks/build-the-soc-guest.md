# Runbook: Build `odin`, the guest that runs `stacks/soc`

**Target:** `odin` — a second guest on `Saruman`, ImaginationLAN (VLAN 30)
**Time:** about two hours, an evening; the domain's agent rollout (§11) is a
second evening
**You will need:** the Proxmox web UI on `Saruman` (or a shell on it through
the KVM or `shiva`), an Ubuntu Server ISO, a shell on `alexander` for §7 and
§9, and a domain admin on `bahamut` for §11
**Before this:** the domain — [#414](https://github.com/Gerrrt/HomeLab/issues/414),
[`build-the-lab-domain.md`](build-the-lab-domain.md). Everything up to §10 can
be done without it, and §10's checks will pass on a SIEM with nothing to say;
"an agentless Wazuh still has nothing to say" is why #266 waits on #414 and why
this runbook does not close either issue by itself.

This builds the host [ADR-0030](../adr/0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)
called for: Wazuh and Velociraptor in one stack on a guest of their own,
because `alexander`'s 8 GiB cannot hold the lab's four services and an
OpenSearch whose vendor minimum is 6 GiB before the dashboard, and because
`make down STACK=lab` must not mean "stop detection, and stop the ability to
see that detection stopped" in one command.

It is the shape of [`build-the-lab-guest.md`](build-the-lab-guest.md), and it
leans on it: where a step is identical, this says so and points there rather
than carrying a second copy that drifts.

---

## 0. What is decided, and why

| | Decision | Why this and not the obvious alternative |
| --- | --- | --- |
| Name | `odin` | Continues the segment's summons: `shiva`, `ifrit`, `alexander`, and ADR-0029's six. Minted in ADR-0030 |
| Address | `10.0.30.60/24` | Static below `.100`, the next decade after `alexander`'s `.40` and the domain's `.50` block. Decided in ADR-0030 |
| VMID | `160` | Last octet legible from `qm list`, as `alexander` is `140` |
| Kind | **VM, not LXC** | Same reason as `alexander`: `cgroup: host`, `cap_drop`, a Docker socket mount, and now `vm.max_map_count`, which an LXC cannot set for itself at all |
| OS | **Ubuntu Server LTS** | Same reason as `alexander`, and check it the same way: `config.alloy` tails `/var/log/auth.log` and `/var/log/syslog`, and a journald-only install collects nothing from either while reporting healthy. §10 is the check |
| vCPU | 4 | OpenSearch and fifteen Wazuh daemons are not single-threaded; the host has 48 threads and compute was never the constraint (ADR-0007) |
| RAM | **8 GiB** | ADR-0030's heap arithmetic assumes it: "half of system RAM would be 4 GiB". The indexer gets 3.5 GiB, the manager 2, and the rest the other three services and the page cache |
| Disk | 96 GB | ~7 GB of alerts at 30 days, the vulnerability feed, the inventory and states indices, Velociraptor's datastore and ~5 GB of images. Bounded, not measured; the same spindles as everything else, with `balloon 0` and `iothread=1` for the same reasons `alexander` has them |
| First user | **uid 1000** | The indexer image runs as uid 1000 and mounts the 0600 user database `make render` writes; `render-config.sh` refuses any other uid. The first user the installer creates is 1000 — do not create a second one to deploy from |

> [!IMPORTANT]
> **`odin` holds the evidence, and has revert rather than backup.**
> ADR-0027 defers PBS until `zion` answers on `10.0.40.30`; until then a lost
> mirrored pair loses the record of what the estate saw, which cannot be
> rebuilt from a runbook the way a domain controller can. Snapshot the guest
> in Proxmox before each exercise, and treat the store as practice rather than
> evidence until the NAS is built.

## 1. Create the VM

On `Saruman`, as for `alexander` (§1 there explains every flag; nothing about
them changes except the numbers):

```bash
qm create 160 \
  --name odin \
  --ostype l26 \
  --cpu host --cores 4 --sockets 1 \
  --memory 8192 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:96,discard=on,iothread=1 \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 \
  --onboot 1 \
  --ide2 local:iso/ubuntu-24.04-live-server-amd64.iso,media=cdrom \
  --boot order='scsi0;ide2'
```

`--onboot 1` matters more here than it did for `alexander`: nothing converges
this stack, and a SIEM that stays down after a hypervisor reboot is a SIEM
whose gap nobody sees until the next exercise.

## 2. Install Ubuntu Server

As `alexander`'s §2, with these values. **Hostname `odin`** — every metric and
log line this guest ships to the lab is labelled with it, and so is every
alert in `soc.rules.yaml`.

| | |
| --- | --- |
| Address | `10.0.30.60/24` |
| Gateway | `10.0.30.1` |
| DNS | `10.0.30.1` — Unbound on the gateway ([ADR-0010](../adr/0010-keep-the-resolver-on-the-gateway.md)) |

Install OpenSSH. Skip the snap Docker.

## 3. Docker, sops, age, and the repository

Identical to `alexander`'s §3 — the Docker repository, `git clone` into
`~/HomeLab`, `age` from apt and `sops` from its release page at the version the
monitoring host runs. Deploy from a checkout **on this host**: `make render`
writes into the tree it runs from.

Before going further, the one check this stack adds:

```bash
id -u
```

Must print `1000`. If it does not, the indexer will not be able to read the
user database §5 renders, and the failure surfaces as a healthcheck that never
passes rather than as a permissions error anywhere you are looking.

## 4. The kernel prerequisite

OpenSearch refuses to start unless the host allows 262,144 memory-mapped
areas per process; the default is 65,530. The setting is not namespaced, so the
container cannot set it and compose cannot carry it — this is the "prerequisite
outside its own compose file" ADR-0030 names as a real if small departure from
every other stack here.

```bash
printf 'vm.max_map_count = 262144\n' | sudo tee /etc/sysctl.d/99-wazuh-indexer.conf
sudo sysctl --system
sysctl vm.max_map_count
```

The last line must print `262144`. A file under `sysctl.d` survives a reboot,
which is why it is not `sysctl -w` alone.

## 5. Its own age key, and the seven secrets

**On `odin`, never on the monitoring host** — `alexander`'s §4 explains why
`bootstrap.sh` refuses when the key it would write already belongs to another
rule, and the same refusal means the same thing here.

```bash
cd ~/HomeLab
make secrets-init STACK=soc
```

Two of the seven values are bcrypt hashes, made with the indexer image's own
tool. It prompts for the password and prints the hash, so nothing lands in
shell history; run it twice, once for `INDEXER_PASSWORD` and once for
`DASHBOARD_PASSWORD`, and paste each hash into the matching `*_HASH` key:

```bash
docker run --rm -it --entrypoint bash \
  "$(COMPOSE_FILE=stacks/soc/compose.yaml scripts/image-for.sh wazuh.indexer)" \
  /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh
```

Then:

```bash
make secrets-edit STACK=soc
```

[`secrets/soc.example.yaml`](../../secrets/soc.example.yaml) says what each of
the seven is for. Generate the passwords with `make gen-secret`, and read the
note there about `API_PASSWORD` first: the Wazuh API refuses a password without
upper, lower, digit and symbol, and the image pastes it into a JSON document
unquoted, so no `"`, `\` or `$`.

Commit and push `.sops.yaml` and `secrets/soc.sops.yaml` from here, then:

```bash
python3 scripts/check_sops_rules.py
```

`secrets/soc.sops.yaml` must resolve to the `secrets/soc...` rule and not to
the catch-all. That is the whole point of the rule.

## 6. The Wazuh certificates

The indexer, manager and dashboard authenticate to each other with mTLS from
a CA of their own — **not** the lab CA, for the reasons ADR-0030 gives: this CA
issues the identities three containers use to trust each other, the lab CA
issues server leaves that browsers verify, and neither tool wants the other's.
The generator is a service behind the `certs` profile, so `make up` never runs
it:

```bash
docker compose -f stacks/soc/compose.yaml --profile certs run --rm wazuh.certs-generator
ls -ln stacks/soc/wazuh/certs/
```

Twelve files, mode `0400`, and the generator has already set their owners to
the uid each container runs as — `1000` for the indexer's and dashboard's,
`999` for the manager's. No chown. `root-ca.key` is the CA's private key; it
stays in that gitignored directory and nowhere else.

> [!NOTE]
> The generator downloads its tool for the version in `CERT_TOOL_VERSION`
> (`compose.yaml`), which is the `wazuh/*` images' major.minor. If the run
> ends with "does not exist in any bucket", that number and the image tags
> have drifted apart — Dependabot bumps the tags and cannot bump the number.

## 7. Open the lab's doors

**On `alexander`.** This guest's Alloy pushes to the lab's Prometheus and Loki,
and until now nothing off `alexander` did — the two `ports:` blocks in
`stacks/lab/compose.yaml` and the two port lines in `stacks/lab/.env.example`
have been commented since the day that stack landed, waiting for a client with
no scrape alternative. This is that client (ADR-0030).

Uncomment all four — `PROMETHEUS_PORT` and `LOKI_PORT` in `.env.example`, and
the `ports:` block under `prometheus` and under `loki` in `compose.yaml` — and
apply:

```bash
cd ~/HomeLab
make up STACK=lab
ss -ltn '( sport = :9090 or sport = :3100 )'
```

Both must show `10.0.30.40` or `0.0.0.0`. **Commit and push the change from
`alexander`**: ADR-0030 decided it, and the day it happens is the day the
repository should say it did. Read the comment above each block before
uncommenting it — it says what is now listening on the segment that exists
to hold attackers, and that is a thing to know rather than discover.

## 8. Bring it up

Back on `odin`:

```bash
cd ~/HomeLab
git pull
make render STACK=soc
make up STACK=soc
```

`render` writes three things: `.env`, the indexer's user database with the two
hashes substituted, and the manager's `authd.pass`. It refuses if any of the
seven keys is missing, and refuses if you are not uid 1000.

The first start is slow, and slow in a particular order. Watch it:

```bash
make ps STACK=soc
```

The indexer initialises its security index from the rendered user database
(about a minute), the manager waits for the indexer to be healthy and then
starts fifteen daemons and filebeat (another minute), and the dashboard waits
for both. Velociraptor generates its config, creates the `admin` account and
then **downloads the client release from GitHub to build the MSI, deb and
rpm** — that is the outbound connection you will see, and it is why
`start_period` on that service is two minutes. Three to five minutes to all
healthy is normal.

If the indexer stays unhealthy past that, the first thing to check is §4:

```bash
docker logs soc-wazuh-indexer 2>&1 | grep -i max_map_count
```

## 9. The index settings, and the lab's scrape

Four settings are not defaults, and ADR-0030 argues each of them: one shard,
no replicas, a thirty-second refresh, and a delete at thirty days on
`wazuh-alerts-*`. **Wazuh ships no retention policy**; without the last one,
retention is forever and the shard budget is spent inside a month. Both files
are under `stacks/soc/wazuh/indexer/`, and both are applied through the
indexer's own `curl`, signed in with the admin certificate, because 9200 is
not published:

```bash
cd ~/HomeLab
AUTH='--cert /usr/share/wazuh-indexer/config/certs/admin.pem --key /usr/share/wazuh-indexer/config/certs/admin-key.pem'
docker compose -f stacks/soc/compose.yaml exec -T wazuh.indexer \
  curl -sk $AUTH -H 'Content-Type: application/json' \
  -XPUT https://localhost:9200/_template/wazuh-alerts-homelab \
  --data-binary @- < stacks/soc/wazuh/indexer/template-wazuh-alerts.json
docker compose -f stacks/soc/compose.yaml exec -T wazuh.indexer \
  curl -sk $AUTH -H 'Content-Type: application/json' \
  -XPUT https://localhost:9200/_plugins/_ism/policies/wazuh-alerts-30d \
  --data-binary @- < stacks/soc/wazuh/indexer/ism-wazuh-alerts.json
```

Both answer with `"acknowledged":true` (the policy call also echoes the policy
back). The settings template is a legacy template at `order: 1` so that it
merges **over** Wazuh's own `wazuh` template, which is at order 0 and carries
the field mappings — a composable template would replace those mappings
entirely, which is why it is not one. Confirm the mappings survived and the
settings landed on the next daily index (or force one by restarting the
manager):

```bash
docker compose -f stacks/soc/compose.yaml exec -T wazuh.indexer \
  curl -sk $AUTH 'https://localhost:9200/_cat/indices/wazuh-alerts-*?v&h=index,pri,rep,docs.count'
docker compose -f stacks/soc/compose.yaml exec -T wazuh.indexer \
  curl -sk $AUTH 'https://localhost:9200/_plugins/_ism/explain/wazuh-alerts-*'
```

`pri 1 rep 0` on every alert index, and every one of them holding the
`wazuh-alerts-30d` policy. The explain output is also the retention
re-derivation ADR-0030 asks for after a fortnight: an index that never left
the `hot` state means the delete has never fired.

Then **on `alexander`**, uncomment the `velociraptor` job at the foot of
`stacks/lab/prometheus/prometheus.yaml` and apply it:

```bash
make up STACK=lab
```

It landed commented for the reason the `windows` job did: a scrape of an
address that does not exist yet is `InstanceDown` firing from the day the
file deploys. Commit that too.

> [!NOTE]
> **If the indexer was ever started with the wrong user database** — a first
> attempt with a placeholder hash, say — the security index already exists and
> a corrected file is not read at the next start. Reapply it from inside the
> container; the paths are the image's:
>
> ```bash
> docker compose -f stacks/soc/compose.yaml exec wazuh.indexer bash -c '
>   export JAVA_HOME=/usr/share/wazuh-indexer/jdk
>   bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
>     -cd /usr/share/wazuh-indexer/config/opensearch-security/ -nhnv -icl \
>     -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
>     -cert /usr/share/wazuh-indexer/config/certs/admin.pem \
>     -key /usr/share/wazuh-indexer/config/certs/admin-key.pem -p 9200'
> ```

## 10. Verify — including the things that fail quietly

```bash
make validate
```

Checks all three stacks and names which is which on every line. Then the
things `make validate` cannot see:

**The two UIs, from Hicks.** `https://10.0.30.60/` is the Wazuh dashboard
(`admin`, `INDEXER_PASSWORD`); `https://10.0.30.60:8889/` is Velociraptor
(`admin`, `VELOCIRAPTOR_INITIAL_ADMIN_PASSWORD` — change it in the GUI now,
because the value in SOPS is inert from here on). Both are self-signed and
both browsers will warn; the two leaves from the lab CA are the named
follow-up in ADR-0030. The existing 50 → 30 rule carries both; no firewall
change anywhere.

**The crossing, in the lab's Grafana** — Explore, Prometheus datasource:

```promql
elasticsearch_clusterinfo_up{job="wazuh-indexer"}
elasticsearch_cluster_health_status{job="wazuh-indexer",color="green"}
up{job="velociraptor"}
```

All three must be `1`. The first is the proof that Alloy's exporter speaks to
this OpenSearch at all — the component it wraps promises "reasonable attempts"
at compatibility, not a guarantee — and it is the series every rule in
`soc.rules.yaml` stands on. If it is absent rather than `0`, the push from
`odin` is not arriving: check §7.

**The log sources**, Loki datasource — the same check `alexander`'s §7 exists
for, for the same reason:

```logql
count by (job) (count_over_time({host="odin"} [15m]))
```

Three jobs at minimum: `/var/log/auth.log`, `/var/log/syslog` and
`/var/log/journal`. Two is a journald-only install, and `sudo apt-get install
-y rsyslog` fixes it.

**And that the SIEM is ingesting**, which is the one thing this whole stack is
for. In the Wazuh dashboard, *Server management → Status* shows every daemon
running; in Explore, after an hour:

```promql
increase(elasticsearch_indices_indexing_index_total{job="wazuh-indexer"}[1h])
```

Non-zero, even with no agents: the manager indexes its own events and the
dashboard writes `wazuh-monitoring-*` on a schedule. Zero here with the
cluster green is `WazuhIngestionStalled`, and it means filebeat on the manager
cannot reach the indexer — its verification mode is `full`, so a certificate
issued for a name other than `wazuh.indexer` fails exactly here and nowhere
visible.

## 11. Agents, by GPO — the second evening, and after #414

Both agents go to ADR-0029's six machines through the domain, because the
domain is the exercise (ADR-0030): a reverted or rebuilt workstation re-enrols
at the next policy refresh, which is what makes snapshot-and-revert and a SIEM
compatible. Two mechanisms, and they differ for a reason.

**Velociraptor — software installation, assigned to the computer OU.** In the
GUI, *Server Artifacts → Server.Utils.CreateMSI* has already run on the first
start and produced a repacked MSI with `client.config.yaml` inside it; download
it from the artifact's results. It is self-contained — server URL, CA, nonce —
so the MSI needs no parameters and the software-installation form works. That
form and **not** a startup script, at least for this one: upstream records
that script deployments launch the client repeatedly and want `--mutant`, and
the MSI-as-service form avoids the problem rather than mitigating it. Put the
MSI on SYSVOL, assign it in a GPO linked to the OU the six machines live in,
and check in the GUI that each appears after its next boot.

**Wazuh — startup script.** The Wazuh agent MSI takes the manager's address and
the enrolment password as MSI **properties**, which the software-installation
form cannot pass without a transform. The vendor's own GPO procedure is a
startup script, and this one follows it:

```powershell
msiexec.exe /i \\ad.matrix.elysium\SYSVOL\ad.matrix.elysium\scripts\wazuh-agent.msi /q `
  WAZUH_MANAGER="10.0.30.60" `
  WAZUH_REGISTRATION_SERVER="10.0.30.60" `
  WAZUH_REGISTRATION_PASSWORD="<WAZUH_REGISTRATION_PASSWORD from SOPS>" `
  WAZUH_AGENT_GROUP="default"
NET START Wazuh
```

The MSI version must match the manager's. The password in that script is
readable by every domain computer, which is the trade: what it buys an
attacker who reads it is the ability to enrol a rogue agent, which is exactly
the noise the exercise is meant to notice, and the `authd.pass` on the manager
can be rotated with one `make secrets-edit STACK=soc` and one `make up`.

Confirm in the dashboard: *Agents* shows four active while the servers run
and six during a session, and each server's `wazuh-alerts-*` count climbs.

## 12. Write it down

The guest is not built until the documents say so, and `make check-docs` walks
you through the first three:

- `docs/network.md` — a row for `odin` in the ImaginationLAN table, and the
  planned-guest note in that section becomes a description.
- `docs/architecture.md` — drop `**Not built yet**` from the `odin` row. The
  marker is load-bearing: while it stands, `check_docs.py` requires the host to
  be **absent** from `network.md`, so the row and the marker cannot coexist.
- `docs/hardware.md` — removing the marker raises the Alloy agent count, and
  the sentence there that states it fails until it says the new number.
- `docs/observability.md` and `README.md` — "authored and not yet built"
  stops being true in both.
- The status table on [#101](https://github.com/Gerrrt/HomeLab/issues/101),
  and #266 and #267 close on the day the six agents report in — not on the
  day this guest comes up.

Then, a fortnight later, the re-derivations this stack was built to want:
`container_memory_rss` per service for the `mem_limit` bounds, and the four
indexer queries in ADR-0030 for the retention bound.
