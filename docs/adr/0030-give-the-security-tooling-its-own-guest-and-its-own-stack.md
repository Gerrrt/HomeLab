# ADR-0030: Give the security tooling its own guest and its own stack

**Status:** Accepted · 2026-09

> [!NOTE]
> The host this ADR calls `zion` is named **`smaug`** since 2026-09
> ([ADR-0038](0038-name-the-nas-smaug-and-reserve-zion-for-the-box-that-does-not-exist.md)).
> The address, the rules and the decision are unchanged — only the label. The
> text here is left as written, per ADR-0001. `zion` is now reserved for the
> dedicated firewall cold spare ADR-0034 defers, which does not exist.

## Context

[ADR-0007](0007-defensive-estate-and-offensive-range.md) put Wazuh and
Velociraptor on `Saruman` alongside the Windows domain.
[#101](https://github.com/Gerrrt/HomeLab/issues/101) split them into
[#266](https://github.com/Gerrrt/HomeLab/issues/266) and
[#267](https://github.com/Gerrrt/HomeLab/issues/267), and named the reason the
first of those is not a line item: "Wazuh in particular is not a small thing to
run — it is the heaviest component in the ADR by a wide margin."

[ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md) already
settled that a compose stack on `Saruman` runs in a guest, because `Saruman` is
the one host in the estate that must not run Docker. What it did not settle is
*which* guest, and #266 is explicit that this is the question and that it must
not be answered by default: "Decide it explicitly; do not let it be decided by
whoever writes the compose file first."

The two issues are treated as one decision here because they are one. Both point
at the same domain ([ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)),
both are bounded by the same mirrored pair, both put an agent on the same six
endpoints, and #267's own framing is that they are halves of one loop: "Wazuh
tells you an alert fired, Velociraptor is how you go and ask the endpoint what
actually happened."

### What the arithmetic says, and where #266's premise needs correcting

Issue #266 expects the indexer to be "the single component in #101 most likely to be
what actually runs out", and reads that as a disk problem. The disk half does
not survive contact with the numbers.

Wazuh's own sizing guidance gives, for ninety days of alerts, roughly 3.7 GB per
server agent and 1.5 GB per workstation agent. ADR-0029's estate is four servers
and two workstations, plus the guest itself:

```text
5 servers      × 3.7 GB  = 18.5 GB
2 workstations × 1.5 GB  =  3.0 GB
                          -------
90 days of alerts        ≈ 21.5 GB   →  ~0.24 GB/day
```

Twenty-odd gigabytes a quarter is nothing on a 1 TB pair. **What runs out is
heap-per-shard, and after that, IOPS.**

Wazuh writes daily indices at one primary shard each, and OpenSearch's guidance
is no more than **25 shards per GiB of JVM heap**. The shipped Docker heap is
1 GiB, which is 25 shards — under a month, before the `wazuh-monitoring-*`,
`wazuh-statistics-*`, `wazuh-states-vulnerabilities-*` and
`wazuh-states-inventory-*` families take their share. And the shard-*size*
guidance points the other way: 21 GB spread over ninety daily shards is about
240 MB each, against a recommended 10–50 GB. This cluster sits two orders of
magnitude inside the many-tiny-shards regime, which is precisely the regime
where heap fails and disk does not.

### Three homes were considered

1. **Into `stacks/lab/` on `alexander`.** No new guest, no new address, no new
   age key. `alexander` is 4 vCPU, 8 GiB and 64 GiB. Wazuh's stated *minimums*
   are 4 GiB for the indexer and 2 GiB for the manager — **six before the
   dashboard**, and before the four services already running there. `stacks/lab`
   sets no `mem_limit:` by decision, so nothing bounds the collision: the
   failure mode is the guest's OOM killer choosing between the SIEM and the
   thing that would have recorded the SIEM dying. Two further costs are specific
   to this option. `vm.max_map_count` is not a namespaced sysctl, so the
   observability guest acquires a kernel-tuning prerequisite it does not have
   today and its runbook becomes wrong. And the blast radius #266 names is worse
   than "two UIs": `make down STACK=lab` becomes "stop detection, and stop the
   ability to see that detection stopped", in one command.
2. **Two stacks on the one guest.** Worth stating because it was checked rather
   than assumed, and because "the tooling wouldn't let us" would be a false
   reason. It would work: [`stacks.sh`](../../scripts/stacks.sh) keys on
   directories and not hosts, `STACK_DIR` and `SECRETS` are parameterised, and
   `check_host_stack_table` in [`check_docs.py`](../../scripts/check_docs.py)
   gathers stack names with a `findall` across the Stack column, so one host row
   may legitimately name two stacks. The one place it bites is secrets, where
   [`bootstrap.sh`](../../scripts/bootstrap.sh) refuses when the host's key
   already belongs to another rule — correct behaviour that would have to be
   worked around. It fails for option 1's memory arithmetic, not for any of
   that.
3. **A second guest, and a second directory under `stacks/`.**

## Decision

**Wazuh and Velociraptor run together in `stacks/soc/`, on `odin` — a second
guest on `Saruman` at `10.0.30.60`.**

### A second guest is what ADR-0004 asks for, not a departure from it

[ADR-0004](0004-one-compose-stack-per-host.md) says it in as many words:
"host-to-stack mapping lives in `docs/architecture.md`, not in the directory
tree. A second host means a second directory under `stacks/`." A second guest is
a second host. The tension #266 feels is not with ADR-0004 at all — it is with
the unstated assumption that Wazuh has to land on the guest that already exists.

### Both tools in one stack, and the directory is not named for either

ADR-0004's definition of a stack is the set of services deployed together as a
unit. Wazuh and Velociraptor share the same clients, the same lifecycle and the
same failure meaning: `make down STACK=soc` means "detection and response are
both gone", which is one outage rather than two. Velociraptor is a single Go
binary and a few hundred megabytes of RSS, so a third guest is not earned.

The directory is therefore **not** `stacks/wazuh/`. A directory named after one
of its two components goes stale the day the second one lands, which is
ADR-0004's own argument against one directory per service, turned on this
decision. `odin` continues the segment's Final Fantasy summons alongside
`shiva`, `ifrit`, `alexander` and ADR-0029's six.

Velociraptor runs as a container (`ghcr.io/velocidex/velociraptor-server`) and
not as the native binary, because this repository's entire verification
apparatus applies to images and not to binaries: tag-and-digest pinning,
Dependabot, `docker compose config`, `check_compose_health.py --probe`,
`check_image_pins.py`. A binary dropped on the guest is converged by nothing.
**One thing to check on the day rather than discover in CI:** if only `:latest`
is published when this is built, the pinning rule cannot be satisfied and the
native binary becomes the honest choice — in which case this paragraph is the
one to supersede.

### Retention: thirty days, bounded by heap

Heap is **2 GiB** (`-Xms2g -Xmx2g`, equal by Wazuh's own tuning guidance), which
buys ~50 shards. The non-alert index families take roughly 15 of those, leaving
~35 for daily alert indices — **rounded down to 30 days**. At ~0.24 GB/day that
is about 7 GB of alerts, which the disk does not notice; the bound is the shard
budget and the ADR should be read that way.

Half of system RAM would be 4 GiB and is what Wazuh's guidance suggests. It is
declined: it buys more shard budget than a six-agent estate needs, and takes
page cache away from a spinning pair that needs it more.

**This number is a bound, not a measurement**, in exactly the sense
`stacks/lab/compose.yaml` already uses for its own retention. It is re-derived
after a fortnight from `_cat/indices/wazuh-*`, `_cat/shards`,
`_nodes/stats/jvm`, and `_plugins/_ism/explain/wazuh-alerts-*` — the last being
the equivalent of `prometheus_tsdb_time_retentions_total`: if the delete has
never fired, retention is longer than this document claims; if it fires early,
shorter.

Four index settings are not defaults and each has a trade worth writing where
the file is:

| Setting | Value | Why, and what it differs from |
| --- | --- | --- |
| `number_of_replicas` | `0` | The default of 1 leaves the replica unassigned forever on a single node, so the cluster is **permanently yellow** — and a health signal that is always yellow is not a health signal |
| `number_of_shards` | `1` | Wazuh's own guidance: shards follow nodes |
| `refresh_interval` | `30s` | The default of 1s makes one new segment per shard per second and then merges them, on ~90 random write IOPS. It costs thirty seconds of alert visibility on a lab the operator is sitting in front of |
| ISM delete policy | `30d` on `wazuh-alerts-*` | **Wazuh ships none.** Without one, retention is "forever" and the shard budget is spent inside a month |

`vm.max_map_count=262144` is a `/etc/sysctl.d` file on the guest, not a compose
setting — it is not namespaced, so the container cannot set it and the runbook
has to.

Rollover-based indices are the correct long-term fix, because they decouple
shard count from day count. Named here as the escape hatch if the re-derivation
shows growth beyond the estimate, and deliberately not built now, because it
means diverging from Wazuh's shipped index template on day one.

### Two stores, and nothing queries across them

Issue #266 asks whether two log stores with two UIs is sensible division or duplicated
upkeep, and says it depends on whether anything ever queries across them.
Nothing will.

- **The lab's Loki, on `alexander`, holds the lab's own infrastructure logs** —
  guest syslog, journal, `auth.log`, container logs. It is how you debug the
  lab.
- **The Wazuh indexer, on `odin`, holds the estate's security events.** It is
  how you answer ADR-0007's "did the detection fire?"

A cross-store query is "what was the lab guest's Docker daemon doing when the DC
alerted", which is a question asked twice a year by opening two tabs.

**Wazuh's alerts are not copied into Loki.** `alerts.json` is tailable and it is
a bad idea: it duplicates every alert into a second store with a second
retention and untyped fields, so "which one is authoritative" arrives
immediately. The indexer is where the fields are typed.

**The crossing that is built runs the other way: indexer health into the lab's
Prometheus.** Alloy ships a first-party `prometheus.exporter.elasticsearch`
which speaks to OpenSearch with `basic_auth` — no new image, one new `.alloy`
file. It gives cluster status, heap used, shard count and indexing rate, which
is both what the retention re-derivation needs and what says *the SIEM stopped
ingesting*. A store that quietly stops ingesting is the
[#62](https://github.com/Gerrrt/HomeLab/issues/62) and
[#63](https://github.com/Gerrrt/HomeLab/issues/63) shape this repository keeps
paying for, and it is the one thing worth alerting on across the boundary.

That file goes in `stacks/soc/alloy/`, and **not** in
`stacks/observability/alloy/`. The estate's Alloy mounts that whole directory,
so a file placed there would be loaded on VLAN 99 pointing at an OpenSearch that
does not exist — a healthy exporter collecting nothing, which is the same
failure one layer along.

### No Grafana OpenSearch datasource

Pointing the lab's Grafana at the indexer would, on paper, remove the Wazuh
dashboard service. It is refused for two reasons, and the trade is stated rather
than left implicit because the saving is real.

`grafana-opensearch-datasource` is a **plugin, not core**, so installing it
means `GF_INSTALL_PLUGINS` fetching an unpinned artefact from grafana.com at
every container start. That is worse than a digest written somewhere
Dependabot cannot bump, which `check_image_pins.py` already forbids: it is no
digest at all.

And the Wazuh dashboard is not a viewer. It is agent enrolment and group
management, the ruleset editor, the vulnerability view and the MITRE mapping.
Grafana panels replace the charts and none of the rest, so the dashboard stays
and the plugin buys nothing.

### Ports, per ADR-0012

[ADR-0012](0012-publish-only-ports-with-an-off-host-consumer.md) publishes a
port only where something off the host uses it.

| Port | Off-host consumer | Published |
| --- | --- | --- |
| Velociraptor `8000` — client frontend | The six domain endpoints | Yes |
| Velociraptor `8889` — GUI | A browser on Hicks, over the 50→30 rule that already exists | Yes — the same call `stacks/lab` made for Grafana, and it authenticates |
| Velociraptor `8001` — gRPC API | Nothing | No |
| Velociraptor `8003` — metrics | The lab's Prometheus, on `alexander` — genuinely off-host | Yes, and it is a residual rather than a solved problem |
| Wazuh `1514`, `1515` — agent comms and enrolment | The six endpoints | Yes |
| Wazuh `443` — dashboard | A browser on Hicks | Yes |
| Wazuh `9200` — indexer | This guest's own Alloy | No |

**None of this needs a firewall rule.** `odin` and `alexander` are both on VLAN
30, and so are the endpoints, so every one of these paths is intra-segment.
Worth writing down, because the reflex is to assume a new listener means a new
rule.

### Each tool keeps its own CA; only the browser-facing leaf comes from the lab CA

Issue #267 asks for this to be decided once rather than discovered later. The decision
turns on the two CAs doing different jobs, and that is the sentence to keep: the
lab CA issues **server** certificates that browsers and Prometheus verify;
Velociraptor's internal CA issues the **client identity material** for mTLS
between each endpoint and the frontend, and its public half is compiled into
every client config.

Three costs of replacing it, each checkable:

1. The internal CA **cannot be reissued without redeploying every client**. So
   replacing it later is a re-deploy of the whole estate, and replacing it now
   buys nothing anyone can point at.
2. Self-signed mode **pins** the server certificate — clients reject even
   globally-trusted alternatives. Swapping in a lab-CA leaf means turning that
   pinning off, which is strictly weaker than what ships.
3. [`gen-certs.sh`](../../scripts/gen-certs.sh) issues server leaves with IP and
   DNS SANs. It does not issue client certificates, and teaching it to would be
   new code for a job the tool already does.

The same holds for Wazuh's `wazuh-certs-generator`, which issues the
indexer-to-manager-to-dashboard mTLS. Both are left alone.

Where the lab CA **is** the right tool is the two browser-facing surfaces — the
Wazuh dashboard and the Velociraptor GUI. That is `grafana-lab.matrix.elysium`'s
job exactly, one `make certs` each. It ships self-signed and the leaves are a
named follow-up rather than a prerequisite: the browser on Hicks already trusts
`certificates/ca.pem` for the two Grafanas, so it is a small win, and pretending
it blocks the build would only delay it.

### Agents are deployed by GPO, because the domain is the exercise

Both agents go out as MSIs assigned to a computer OU. Three reasons, and the
third outranks "quickest":

1. ADR-0029's domain exists to be a domain. Using domain mechanics is the
   exercise; hand-installing six MSIs teaches nothing a shell loop does not.
2. It is **self-healing**. A reverted or rebuilt workstation re-enrols at the
   next policy refresh — which matters because ADR-0029 runs the endpoints on
   demand and the lab's whole mode is snapshot-and-revert.
3. The upkeep is honestly small: two MSIs on a SYSVOL share, one GPO each, and a
   re-repack of the Velociraptor MSI on client version bumps. That is less
   standing work than a configuration-management tool this estate does not
   otherwise run.

Use the MSI software-installation form and **not** the GPO startup-script form,
at least for Velociraptor: upstream records that script deployments launch the
client repeatedly and want `--mutant`. The MSI-as-service form avoids the
problem rather than mitigating it.

`WAZUH_REGISTRATION_PASSWORD` and `VELOCIRAPTOR_INITIAL_ADMIN_PASSWORD` live in
`secrets/soc.sops.yaml` behind compose guards, and `render-config.sh` writes
`authd.pass` into the stack's `.rendered/` the way it already does for
`snmp.yaml`. The repacked MSIs, `client.config.yaml` and `server.config.yaml`
are build artefacts and not repository files — the last holds the CA private key
and is git-ignored, with a stripped `server.config.yaml.example` tracked in its
place.

## Consequences

- **A third guest to build, patch and remember**, and the full second-stack cost
  ADR-0020 already enumerated for the first one: a new age keypair created **on
  that guest**, a `creation_rule` in [`.sops.yaml`](../../.sops.yaml) ordered
  above the catch-all and scoped with the optional group that
  [#321](https://github.com/Gerrrt/HomeLab/issues/321) is about, a
  `secrets/soc.example.yaml` and its encrypted twin, a `.github/dependabot.yml`
  entry, a row in `architecture.md` the moment the directory exists, and seed
  values in [`seed-validation-env.sh`](../../scripts/seed-validation-env.sh) for
  every new guard.
- **The lab's Prometheus and Loki become published for the first time**, because
  this guest's Alloy is the first genuine off-host client either has had. That
  is the line `stacks/lab/compose.yaml` was written waiting for — and it is a
  different case from ADR-0029's, which declined to publish for endpoints that
  had a scrape available instead. Here there is no scrape alternative: Alloy
  pushes.
- **Two more web UIs on the segment that exists to hold attackers**, both
  authenticated, both reachable only from Hicks over a rule that already exists.
- **`vm.max_map_count` is a guest-OS prerequisite**, so this stack cannot be
  moved to another host by copying a directory. The runbook carries it, and a
  stack whose prerequisites live outside its own compose file is a real, if
  small, departure from how every other stack here behaves.
- **The retention figure is a bound and is written as one.** If the
  re-derivation shows the shard budget spent early, the fix is rollover indices
  and not a larger number.
- **The tooling would have supported two stacks on one host, and that is not why
  this went the way it did.** Recorded so the next person does not read the
  decision as a limitation of `stacks.sh`.
- **Nothing here pages**, for ADR-0020's reason: there is no Alertmanager in
  `stacks/lab` and none is added. The indexer-health rules are visible in the
  lab's Grafana and nowhere else.

  [ADR-0028](0028-let-guest-liveness-cross-but-not-guest-telemetry.md) answered #257 while this
  was being written, and it is worth being precise about how little that helps
  here. What may cross is a guest's **run state**, read from the hypervisor. So
  the estate learns that `odin` stopped; it does not learn that `odin` is up and
  its indexer stopped ingesting, which is the failure this stack is far more
  likely to have and the one the Alloy exporter above exists to catch. The
  crossing is real and it is not coverage of the SIEM.
- **`odin` holds the evidence, and has revert rather than backup.**
  [ADR-0027](0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md)
  settled #268 while this was being written: no PBS until `zion` exists, PVE
  snapshots in the meantime. That is a sharper consequence here than it is for
  the domain, because a domain controller can be rebuilt from a runbook and
  ninety days of alerts cannot be rebuilt from anything. Losing the mirrored
  pair loses the record of what the estate saw, which is the one thing this
  stack exists to keep — and it is an argument for `zion` arriving before this
  store is treated as evidence rather than as practice.
- **Reopened by:** Velociraptor publishing no versioned image tag; the indexer
  needing more than 2 GiB of heap once six agents are real; a decision to query
  across the two stores after all; or `wazuh-archives` being turned on, which is
  five to twenty times the alert volume and changes every number here.
