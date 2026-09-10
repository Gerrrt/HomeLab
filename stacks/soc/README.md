# SOC stack

Wazuh and Velociraptor — the security half of [ADR-0007]'s defended estate —
on `odin` (`10.0.30.60`, ImaginationLAN / VLAN 30), a **second guest on
`Saruman`** beside `alexander`. **The guest is not built yet**; the build is
[`build-the-soc-guest.md`], it waits on the domain ([#414]), and this directory
is the stack it deploys, authored ahead of the host the way `stacks/lab` was.
[ADR-0030] is the decision: why a second guest and not `alexander`, why one
stack and not two, why the directory is not called `wazuh`.

```bash
make up STACK=soc        # from the repository root, on odin
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `wazuh.indexer` | `wazuh/wazuh-indexer` | *internal* (9200) | OpenSearch — the store for the estate's security events. 2 GiB heap, 30-day retention, and both numbers are bounds ([ADR-0030]) |
| `wazuh.manager` | `wazuh/wazuh-manager` | 1514, 1515 | The analysis engine the six domain agents report to and enrol with; enrolment needs a password |
| `wazuh.dashboard` | `wazuh/wazuh-dashboard` | 443 (https) | Agent enrolment, group management, the ruleset editor, the MITRE mapping — not a viewer, which is why Grafana does not replace it |
| `velociraptor` | `ghcr.io/velocidex/velociraptor-server` | 8000, 8889 (https), 8003 | Ask the endpoint what actually happened. Frontend for the clients, GUI for a browser on Hicks, metrics for the lab's Prometheus |
| `alloy` | `grafana/alloy` | 12345 (localhost) | This guest's collector, pushing to the lab's stores on `alexander` — and the indexer-health exporter |
| `wazuh.certs-generator` | `wazuh/wazuh-certs-generator` | — | Behind the `certs` profile: run once, before the first start, to issue the indexer/manager/dashboard mTLS material |

Six services, and what is absent is as deliberate as what is here:

- **No Prometheus, Loki or Grafana.** They are on `alexander`, four hundred
  metres of copper away on the same segment, and this guest's Alloy pushes to
  them: `LOKI_URL` and `PROMETHEUS_REMOTE_WRITE_URL` in `compose.yaml` point at
  `10.0.30.40`. That makes `odin` the first genuine off-host client the lab's
  stores have had, and the day it comes up is the day
  `stacks/lab/compose.yaml`'s two commented `ports:` blocks are uncommented —
  [`build-the-soc-guest.md`] §7, not before. Nothing here remote-writes to
  `10.0.99.20` ([ADR-0007]).
- **No Grafana OpenSearch datasource on the lab's Grafana**, refused in
  [ADR-0030]: it is a plugin fetched unpinned at every start, and the Wazuh
  dashboard is not a viewer that Grafana panels could replace.
- **No copy of Wazuh's alerts into Loki.** Two stores, and nothing queries
  across them. The indexer holds the estate's security events with typed
  fields; the lab's Loki holds this guest's own journal, `auth.log` and
  container logs, the way it holds `alexander`'s. Tailing `alerts.json` into
  Loki would put every alert in two stores with two retentions.
- **No Alertmanager, here or on `alexander`.** Nothing in the lab pages
  ([ADR-0020]). The six rules that read this stack's health are visible in the
  lab's Prometheus and Grafana and nowhere else.
- **No syslog listener, no API port.** Upstream's single-node file publishes
  `514/udp` and `55000`; nothing off this host consumes either
  ([ADR-0012]), so neither is published.

## The one thing that crosses

[`alloy/opensearch.alloy`](alloy/opensearch.alloy) is the file this stack adds
to the two it mounts unchanged from `stacks/observability/alloy/`. It runs
Alloy's first-party `prometheus.exporter.elasticsearch` against the indexer —
verified against the indexer's own root CA, signed in as `admin` — and pushes
cluster status, heap, shard count and indexing rate to the lab's Prometheus.
That is what says *the SIEM stopped ingesting*, which is the #62/#63 failure
this repository keeps paying for and the one thing worth alerting on across
the boundary. The rules live where the series arrive:
[`stacks/lab/prometheus/rules/soc.rules.yaml`](../lab/prometheus/rules/soc.rules.yaml),
six of them, each with a firing and a quiet promtool case.

The file lives here and **not** in `stacks/observability/alloy/`, because the
estate's Alloy mounts that whole directory and would load it on VLAN 99
pointing at an OpenSearch that does not exist — a healthy exporter collecting
nothing, one layer along.

## Layout

```text
compose.yaml                     six services, one network, health-gated ordering
.env.example                     non-sensitive tunables — edit this, not .env
alloy/opensearch.alloy           the indexer-health exporter (see above)
wazuh/
  certs.yml                      input to the certs generator — service names, dots included
  certs/                         its output; gitignored, private keys
  indexer/opensearch.yml         upstream's single-node file, verbatim
  indexer/internal_users.yml     TEMPLATE — two accounts, two ${HASH} placeholders;
                                 rendered to .rendered/ by scripts/render-config.sh
  indexer/template-wazuh-alerts.json   1 shard, 0 replicas, 30s refresh, on wazuh-alerts-*
  indexer/ism-wazuh-alerts.json        delete wazuh-alerts-* at 30 days — Wazuh ships no policy
  manager/ossec.conf             upstream's file with ONE change: enrolment needs a password
  manager/.rendered/authd.pass   that password, rendered from SOPS
  dashboard/opensearch_dashboards.yml  upstream's file, verbatim
velociraptor/
  init.vql                       the image's first-start VQL with two changes, marked inside
  etc/                           the generated server config; gitignored — it holds a CA key
```

Secrets are `secrets/soc.sops.yaml`, encrypted to this stack's own rule in
`.sops.yaml` — `odin`'s key opens this file and nothing else of the estate's or
the lab's ([`secrets/soc.example.yaml`](../../secrets/soc.example.yaml) says
why, and lists the seven keys). No certificate here comes from the lab CA:
each tool keeps its own ([ADR-0030]), and the two browser-facing leaves from
the lab CA are a named follow-up rather than a prerequisite.

## Things worth knowing before editing

- **Four of the settings are not defaults, and each is a trade.** One primary
  shard per index, no replicas, a 30-second refresh interval and a 30-day
  delete policy on `wazuh-alerts-*`. [ADR-0030] argues each; the two JSON files
  under `wazuh/indexer/` carry them, and the runbook applies them after the
  first start. The lab's `WazuhIndexerClusterYellow` rule is what says they
  stopped applying: on a single node with no replicas, green is the only
  correct colour.
- **The retention figure is a bound, not a measurement.** 2 GiB of heap buys
  about 50 shards at OpenSearch's 25-per-GiB; the non-alert families take ~15;
  thirty daily alert indices fit. Re-derive after a fortnight from
  `_cat/indices/wazuh-*`, `_cat/shards`, `_nodes/stats/jvm` and
  `_plugins/_ism/explain/wazuh-alerts-*` — the last says whether the delete
  has ever fired. If the budget is spent early, the fix is rollover indices,
  not a larger number.
- **The memory limits are vendor minimums, not measurements** — the one place
  this file departs from `stacks/lab`'s refusal to guess. Wazuh states 4 GiB
  for the indexer and 2 GiB for the manager; the indexer gets 3.5 GiB here
  because the guest has 8 and four other services. Re-derive from
  `container_memory_rss` in the lab's Prometheus, the way #114 did.
- **`vm.max_map_count` is a guest-OS prerequisite**, not a compose setting —
  it is not namespaced, so the container cannot set it. The runbook writes
  `/etc/sysctl.d/99-wazuh-indexer.conf`; without it the indexer refuses to
  start, loudly. This stack cannot be moved to another host by copying the
  directory, which [ADR-0030] names as a real if small departure from every
  other stack here.
- **Render as uid 1000.** The indexer image runs as uid 1000 and mounts the
  0600 `internal_users.yml` that `make render` writes; `render-config.sh`
  refuses any other uid. On `odin` that is the first user the installer
  creates.
- **The Wazuh service names carry a dot.** `wazuh.indexer`, not
  `wazuh-indexer`: the certs generator refuses a bare hostname as an invalid
  DNS name, and filebeat verifies the indexer's certificate in `full` mode, so
  the SAN and the name the manager dials must match. `wazuh/certs.yml` says so.
- **`init.vql` is a copy of an upstream file**, mounted over the image's, and
  the image's can move on a bump. The file's header has the `diff` command;
  run it after each Dependabot PR. Its two changes are the fixed ports and the
  monitoring listener bound to every interface so `alexander` can scrape 8003.
- **`8003` is a residual.** Velociraptor's metrics listener is unauthenticated
  and published, because the lab's Prometheus is genuinely off-host — the
  same class of exposure as the estate's published Prometheus and Loki, on the
  segment where it matters most. [ADR-0030] says so in as many words.
- **The Velociraptor CA cannot be reissued without redeploying every client.**
  `velociraptor/etc/server.config.yaml` holds it. Deleting that file makes the
  next start mint a new one and orphans every enrolled endpoint; back the
  directory up with the guest, and remember that `odin` has revert, not backup
  ([ADR-0027]).
- **Agents go out by GPO**, because the domain is the exercise. Velociraptor's
  repacked MSI by software installation assigned to the computer OU; Wazuh's
  by startup script, because its MSI takes the manager address and the
  enrolment password as properties. The runbook has both.
- **`CERT_TOOL_VERSION` in `compose.yaml` is the one thing Dependabot cannot
  bump.** It names the script the certs generator downloads and tracks the
  `wazuh/*` images' major.minor; a bump to 4.15 changes it in the same PR.
- **Nothing converges this stack.** The `homelab-*` timers are the estate's;
  a merged change reaches `odin` when someone goes and applies it.

## Validate before deploying

```bash
make validate
```

Every checker in `scripts/validate.sh` iterates `scripts/stacks.sh`, so this
stack is covered by everything the estate's is: `docker compose config`, the
image-pin and digest checks, `alloy fmt --test` on `opensearch.alloy`,
`check_compose_health.py --probe` (which execs each healthcheck binary inside
the pinned image — `curl` in the three Wazuh images, busybox `wget` in
Velociraptor's), and `check_sops_rules.py` on the `soc` rule. The six rules
and their tests run under the lab stack's promtool step, because that is
where they live.

What `make validate` still does **not** prove about this stack, in the order
it matters:

- **That it runs.** Nothing here has been deployed — the host is
  [`build-the-soc-guest.md`]. Every check is static.
- **That the indexer accepts the rendered user database.** A malformed bcrypt
  hash in SOPS parses as YAML and fails inside the security plugin on first
  start; the runbook's verification step is the check.
- **That the four index settings applied.** They are applied by hand after the
  first start; `WazuhIndexerClusterYellow` and `_cat/indices` are what say so.
- **That the exporter speaks to this OpenSearch.** The component it wraps
  promises "reasonable attempts" at OpenSearch compatibility, not a guarantee;
  `elasticsearch_clusterinfo_up == 1` in the lab's Explore is the proof.

[ADR-0007]: ../../docs/adr/0007-defensive-estate-and-offensive-range.md
[ADR-0012]: ../../docs/adr/0012-publish-only-ports-with-an-off-host-consumer.md
[ADR-0020]: ../../docs/adr/0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md
[ADR-0027]: ../../docs/adr/0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md
[ADR-0030]: ../../docs/adr/0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md
[#414]: https://github.com/Gerrrt/HomeLab/issues/414
[`build-the-soc-guest.md`]: ../../docs/runbooks/build-the-soc-guest.md
