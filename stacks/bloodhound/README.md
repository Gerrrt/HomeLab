# BloodHound stack

[![host: eden](https://img.shields.io/badge/host-eden-30363d?style=plastic)](../../docs/network.md#imaginationlan--vlan-30--lab)
[![VLAN 30: ImaginationLAN](https://img.shields.io/badge/VLAN%2030-ImaginationLAN-2ea043?style=plastic)](../../docs/network.md#imaginationlan--vlan-30--lab)
![status: not built](https://img.shields.io/badge/status-not%20built-d29922?style=plastic)
[![BloodHound CE](https://img.shields.io/badge/BloodHound%20CE-c0392b?style=plastic)](https://github.com/SpecterOps/BloodHound)
[![Neo4j](https://img.shields.io/badge/Neo4j-4581C3?style=plastic&logo=neo4j&logoColor=white)](https://neo4j.com)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-2496ED?style=plastic&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

Attack-path analysis for the lab domain, `ad.matrix.elysium`: which path to
Domain Admin exists, so that Wazuh, Zeek and Sysmon can be asked whether they
saw it ([#451](https://github.com/Gerrrt/HomeLab/issues/451)). It runs on
`eden` (`10.0.30.41`, ImaginationLAN / VLAN 30), a guest on `Saruman` that is
**not built yet** and is off between sessions.
[ADR-0081] is the decision: why `Saruman` and not `ifrit`, Winterfell or the
domain, why it is off by default, and why nothing here is backed up.
[`build-the-bloodhound-guest.md`] is the build.

```bash
make secrets-init STACK=bloodhound     # on eden, once: its own age key and rule
make secrets-edit STACK=bloodhound     # the five values in secrets/bloodhound.example.yaml
make up STACK=bloodhound
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `bloodhound` | `specterops/bloodhound` | 8443 (https) | The API, the ingest workers and the UI. TLS on a leaf from the estate's CA. Serves the SharpHound and AzureHound release it was built with |
| `app-db` | `postgres` | *internal* | Users, saved queries, upload jobs, audit log |
| `graph-db` | `neo4j` | *internal* | The graph. Held to 4.4, which is what BloodHound CE speaks |
| `alloy` | `grafana/alloy` | 12345 (localhost) | This guest's collector. Pushes to `alexander`, and scrapes BloodHound's metrics as `job="bloodhound"` |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy` | *internal* | Holds the Docker socket so Alloy does not: GET-only, the estate's allowlist ([#836](https://github.com/Gerrrt/HomeLab/issues/836)) |

## A session

The guest is tagged `on-demand`
([ADR-0079](../../docs/adr/0079-tag-on-demand-guests-and-leave-them-out-of-the-stopped-guest-alert.md)),
so a session starts and ends on `Saruman`:

```bash
qm start 141       # the containers come back on their own
```

```bash
qm shutdown 141    # when done; nothing pages
```

Between the two:

1. Download SharpHound from the UI's *Download Collectors*. That way its
   version is the one this server's schema expects.
2. Collect from a domain-joined host.
3. Upload the zip under *Administration → File Ingest*.

A collection replaces nothing. A fresh exercise starts from *Administration →
Database Management → Clear data*.

## What it keeps, and what it does not

- **The graph is a map of the lab's weaknesses.** It stays on the lab segment,
  and nothing of it crosses to VLAN 99 (ADR-0007). Alloy ships this guest's
  telemetry and container logs to `alexander`, not the graph.
- **Nothing is backed up** (ADR-0081). A lost graph is one collection run
  away. Saved queries are the one thing that is not, and
  [`build-the-bloodhound-guest.md`] § 8 says what to do if they ever matter.
- **Cypher mutations stay off**, as upstream ships them, so that a query typed
  in the UI cannot rewrite the graph it is reading.

[ADR-0081]: ../../docs/adr/0081-run-bloodhound-ce-on-a-saruman-guest.md
[`build-the-bloodhound-guest.md`]: ../../docs/runbooks/build-the-bloodhound-guest.md
