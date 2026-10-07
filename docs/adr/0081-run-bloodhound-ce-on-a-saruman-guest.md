# ADR-0081: Run BloodHound CE on a guest of its own on Saruman, off between sessions

**Status:** Accepted · 2026-10

## Context

The estate has no attack-path analysis.
[#414](https://github.com/Gerrrt/HomeLab/issues/414) built the domain,
`ad.matrix.elysium`, and
[#449](https://github.com/Gerrrt/HomeLab/issues/449) is filling it.
[ADR-0078](0078-populate-the-lab-domain-from-a-committed-file-and-a-seed.md)'s
41 accounts were applied on 2026-10-03, and the deliberate weaknesses are still
to come. With both in place, "can I get Domain Admin" stops being the
interesting question. The interesting one is **which** path, and whether
anything would have seen it. That is a graph problem, and BloodHound Community
Edition is the tool built for it.
[#451](https://github.com/Gerrrt/HomeLab/issues/451) asks where it runs.

BloodHound CE is one Go binary over a database. Upstream's compose file gives
it two: Postgres for its users and saved queries, and Neo4j 4.4 for the graph.
The binary also ships a Postgres graph driver, chosen at start by
`bhe_graph_driver`, which keeps the graph in the same Postgres as everything
else. Its collector, SharpHound or bloodhound-python, runs against the
domain from wherever the operator is. Its output is a zip, uploaded through the
UI. So only the server needs a home.

**One earlier decision already gave it a home, and this one moves it.**
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) sized
`ifrit`'s 32 GB around "a Kali VM with BloodHound and its Neo4j alongside a C2
server". That was a sizing sentence, not a placement argument. #451 makes the
placement argument and it comes out the other way (below). `ifrit` is still
not built.

What `Saruman` has, read on the host on 2026-10-06:

- **RAM:** 125 GiB, 75 GiB of it free, with all eleven guests running.
- **`large_data`, the SSD pair:** 876 GiB, 28.7% written.
  - Its thin volumes are **already allocated to 920 GiB, more than the pool**.
  - That is safe only while what is written stays well under the pool.
    `ThinPoolNearlyFull` watches the written figure.
  - The SSD pair is 7,952 random-write IOPS against the HDD mirror's 741
    ([#527](https://github.com/Gerrrt/HomeLab/issues/527)).
- **`local-lvm`, on the HDD mirror:** 794 GiB, 1.9% written. `phoenix`'s disk
  is there and nothing else is.

## Decision

**BloodHound CE runs as [`stacks/bloodhound`](../../stacks/bloodhound) on a new
guest on `Saruman`: `eden`, VMID 141, `10.0.30.41`.**

- **Its address.** It is a static below the DHCP pool, in `alexander`'s decade,
  because every `.x0` is taken. It sits beside the other lab guest that serves
  a UI to a human. `diabolos` broke the decade spacing first, at `.61`, for the
  same reason.
- **Its size.**

  | Resource | Size | Why |
  | --- | --- | --- |
  | vCPU | 4 | |
  | RAM | 8 GiB | The stack's memory limits add up to about 5.5 GiB: 3 for BloodHound, 2 for Postgres. The rest is for the guest kernel, Docker and page cache |
  | OS disk | 32 GiB, on `local-lvm` | Phoenix's choice: an OS disk's I/O is trivial, so it does not need the SSDs |
  | Data disk | 32 GiB, on `large_data` | Postgres lives on it, graph included, and the graph's random reads are what the SSDs are for. 32 GiB is generous for a domain of tens of objects |

  The data disk brings the SSD pool's allocation to 952 GiB of 876. What is
  written grows by megabytes.
- **It is off between sessions.** The guest carries the Proxmox tag
  `on-demand` ([ADR-0079](0079-tag-on-demand-guests-and-leave-them-out-of-the-stopped-guest-alert.md))
  and `onboot 0`. It is started for an analysis session and shut down after.
  Its 8 GiB and its I/O are spent only then.
- **One database: the graph lives in Postgres, not Neo4j.** BloodHound runs
  with `bhe_graph_driver: pg`, so its state and its graph share one Postgres
  18. That means one store on `Saruman`'s disks instead of two, one data
  directory, and one password. It also means no JVM sizing its heap and page
  cache from the host's memory rather than the container's. The disk budget
  [ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
  sized so carefully is spent once.
- **Nothing on it is backed up.**
  - **It stays out of `golem`'s nightly job**, like `alexander`, `phoenix` and
    `fenrir`. The job selects VMIDs, so leaving it out takes no change
    ([ADR-0053](0053-run-pbs-on-saruman-with-its-datastore-on-smaug-over-nfs.md)).
  - **The graph is derived data.** It is one collection run from being rebuilt,
    and a collection is the operation the tool exists for.
  - **The guest is rebuilt from this repository.**
  - **Its secrets are rebuilt by issuing new values.** They guard only this
    guest.
- **It is TLS on the estate's CA, like the lab's Grafana.** BloodHound
  terminates TLS itself on a leaf of its own, `bloodhound.matrix.elysium`.
  - **Its SANs:** `10.0.30.41` as an IP SAN, and `bloodhound` as a DNS SAN.
  - **Why TLS:** the login and the session token cross a segment built for
    ARP spoofing, so they do not cross it in clear.
  - **What it also covers:** the same leaf serves BloodHound's metrics port,
    which goes to TLS with the UI. The guest's Alloy therefore scrapes it over
    HTTPS, verified against the estate's CA by the `bloodhound` name.
- **Its telemetry goes to `alexander`, never to VLAN 99.** Its own Alloy pushes
  with its own ingest token, `INGEST_TOKEN_EDEN`. The build adds that token to
  `stacks/lab` in the same pull request that commits the guest's key. The lab's
  compose file requires every token it names, so adding the token earlier would
  fail `alexander`'s next render.
  - **What crosses:** host and container telemetry, container logs, and
    BloodHound's own metrics. `up{job="bloodhound"}` stands in for the
    health check its distroless image cannot run.
  - **What does not cross:** the graph and the query results.
- **No firewall rule anywhere.**
  - **The upload** goes from a collector on the domain, `.50` to `.55`, or from
    the attack VM once [#421](https://github.com/Gerrrt/HomeLab/issues/421)
    gives it one, to `.41`. That is intra-segment on `vmbr0`, and pfSense never
    sees it.
  - **The browser** on Hicks reaches the guest over the existing Hicks →
    ImaginationLAN rule
    ([ADR-0031](0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md)).
  - **The Alloy push** to `alexander` is intra-segment.
- **Its secrets have their own key and rule.**
  - `secrets/bloodhound.sops.yaml` gets its own `.sops.yaml` rule above the
    catch-all, and eden's own age key, made on the guest.
  - It holds four values: the database password, the first admin, the
    session signing key and the ingest token.
  - Of these, only the ingest token is also held anywhere else, on `alexander`.
- **The collector is not part of this decision.** SharpHound ships inside the
  pinned image and downloads from the UI, so the collector and the ingest
  schema always match. Where it runs is an operator's choice per session: a
  domain-joined host today, the attack VM after #421.

### Rejected

- **On `ifrit`, the range host**, as ADR-0017 assumed.
  - **It confounds the detection question.**
    [ADR-0007](0007-defensive-estate-and-offensive-range.md) separates attacker
    from target so that "did the detection fire?" has a clean answer. Analysis
    tooling on the attacker's host shares the attacker's fault domain. It also
    shares the attacker's revert: a graph that disappears with the attack VM's
    snapshot is not a record of anything.
  - **`ifrit` is unprotected by design.** ADR-0017 gives it no backups and no
    monitoring.
  - **`ifrit` is not bought yet.** Waiting for it would hold #451 behind a
    purchase it does not need.
- **On Winterfell.**
  [ADR-0008](0008-place-services-by-data-trust.md) argues against accumulating
  things on the management segment. This is lab tooling holding a map of lab
  weaknesses. Putting it on VLAN 99 would also need a pass from the lab into
  the estate for every upload, the inversion ADR-0007 exists to refuse.
- **On the domain itself, for example on `titan`.** It analyses the domain, so
  it should survive the domain being reverted, rebuilt by #448's `tofu
  destroy`, or compromised by the exercise it is measuring.
- **On `alexander` or `odin`.**
  - **`alexander`** is sized for the lab's observability
    ([ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)).
  - **`odin`'s** 16 GiB is sized to Wazuh's stated minimums
    ([ADR-0030](0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)).
  - **Neither is off between sessions.** A graph store that holds gigabytes
    all day to be used one evening a week costs more on an always-on guest
    than the guest it would avoid.
- **In Docker on the hypervisor.** Docker rewrites the iptables `Saruman`'s own
  firewall relies on
  ([ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)).
  That is why `stacks/lab` runs in a guest at all.
- **Both disks on `large_data`.** That is fenrir's shape. It adds 32 GiB more
  allocation to a pool that is already allocated past its size, to buy speed
  for an OS disk that does almost no I/O.
- **Neo4j for the graph, as upstream's compose ships it.** It is the
  better-trodden path, and BloodHound's own documentation assumes it. But it
  is a second database with a second password and a second data directory.
  Its heap and page cache size themselves from the host unless pinned, and
  BloodHound CE speaks only its 4.4 line, which Dependabot would have to be
  held to. For a domain of tens of objects, the Postgres driver answers the
  same queries from the store the stack already has.
- **Always on.** It would reserve 8 GiB, and the database's checkpointing on
  the SSDs, for a tool that is used in sessions.

## Consequences

- **A twelfth guest on `Saruman`, and the first that is off by default.** It
  costs its RAM only while it runs. Its disk costs 64 GiB of allocation, half
  of it on the SSD pool.
- **The SSD pool's overcommit grows by 32 GiB.**
  - **What is safe:** nothing here writes much. The graph of a domain of tens
    of objects is megabytes.
  - **What to watch:** `ThinPoolNearlyFull`, which reads what is written, not
    what is allocated.
  - **What the next guest must do:** state its claim against both numbers, as
    this one does.
- **The graph lives only on `eden`.** Its loss costs one collection run. So
  does a deliberate wipe before a fresh exercise. The one thing that does not
  come back is the saved queries in Postgres. If those ever start to matter,
  they get exported, not backed up
  ([`build-the-bloodhound-guest.md`](../runbooks/build-the-bloodhound-guest.md)).
- **"Would anything have seen it" is answered elsewhere.** BloodHound says
  which path exists. Whether the path was detected is in Wazuh on `odin`, Zeek
  on `fenrir` and #450's Sysmon. Those are the lab's own stores, and this ADR
  changes none of them.
- **Nothing the guest holds crosses to VLAN 99.**
  [ADR-0028](0028-let-guest-liveness-cross-but-not-guest-telemetry.md) lets
  its run state cross, as for every guest, and the `on-demand` tag keeps that
  quiet.
- **It is built before #449's weaknesses exist, and that is deliberate.** The
  graph already has edges from the 41-account population and its groups. The weaknesses land as tags on top, and each one is a reason to
  collect again, not to rebuild anything here.
- **The Postgres graph driver is the less-trodden path.** If a query or an
  ingest misbehaves in a way upstream's Neo4j setup does not, that is a
  finding about the driver. The fix is a decision to reopen this, not a quiet
  second database.
- **It is authored ahead of the build**, as `stacks/soc` and `stacks/sensor`
  were. The stack, its secrets template, its `.sops.yaml` rule with a
  placeholder and its runbook come first. The guest, its key, its token on
  `alexander` and the closing of #451 come in the pull request that writes it
  down as built.
- **Reopened by:**
  - a domain large enough that Postgres's 2 GiB, or the SSD pool's headroom,
    stops being generous;
  - BloodHound CE dropping or deprecating its Postgres graph driver, or a
    query the lab needs that only the Neo4j driver answers;
  - `ifrit` arriving with a reason to analyse from the range, which this ADR
    argues against but does not forbid;
  - saved queries becoming something worth a backup.
