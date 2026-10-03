# Scratch stack

[![host: diabolos](https://img.shields.io/badge/host-diabolos-30363d?style=plastic)](../../docs/network.md#imaginationlan--vlan-30--lab)
[![VLAN 30: ImaginationLAN](https://img.shields.io/badge/VLAN%2030-ImaginationLAN-2ea043?style=plastic)](../../docs/network.md#imaginationlan--vlan-30--lab)
![status: disposable](https://img.shields.io/badge/status-disposable-8b949e?style=plastic)
[![Wazuh](https://img.shields.io/badge/Wazuh-3595F7?style=plastic)](https://wazuh.com)
[![Velociraptor](https://img.shields.io/badge/Velociraptor-4b7b4b?style=plastic)](https://docs.velociraptor.app)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-2496ED?style=plastic&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

A **disposable** copy of [`stacks/soc`](../soc/README.md), for the investigation
that wants a store it can fill with noise, query hard and then delete:
detonating a sample, or working one question over a weekend. It runs on
`diabolos` (`10.0.30.61`, VMID 161, ImaginationLAN / VLAN 30), a guest on
`Saruman` that is **expected to be destroyed**.

**The guest does not exist most of the time.** It is built for one
investigation and torn down at the end of it.
[`run-a-scratch-investigation.md`] covers both halves, and [ADR-0071] is the
decision. Like `stacks/soc` and `stacks/sensor`, this directory was authored
before its host and is CI-validated without one.

```bash
make up STACK=scratch    # from the repository root, on diabolos
```

## The lifecycle, made visible

A throwaway that quietly stays up for four months is `odin` with worse
retention and nobody watching it ([#438]). So "disposable" is not a promise made
in this directory. It is a fact on the hypervisor, and the estate reads it:

1. The guest is created with the Proxmox tag `disposable`.
2. [`collect-guest-state.sh`](../../scripts/collect-guest-state.sh) on `Saruman`
   reports that tag and the guest's creation time from `qm config`.
3. **`DisposableGuestOutlived`** fires when a disposable guest is more than a
   fortnight old, **running or stopped**. Still existing is what gets noticed.

**`qm destroy 161 --purge` is this stack's retention policy.** Nothing in git
changes when an investigation starts or ends.

## Services

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `wazuh.indexer` | `wazuh/wazuh-indexer` | *internal* (9200) | OpenSearch: the store. The same 2 GiB heap and shard ceiling as `odin`, and no delete policy |
| `wazuh.manager` | `wazuh/wazuh-manager` | 1514, 1515 | For the agents of whatever is under investigation. Enrolment still needs a password, this guest's own |
| `wazuh.dashboard` | `wazuh/wazuh-dashboard` | 443 (https) | Query it hard |
| `velociraptor` | `ghcr.io/velocidex/velociraptor-server` | 8000, 8889 (https) | Collection from the endpoints involved, with a CA that dies with the guest |
| `wazuh.certs-generator` | `wazuh/wazuh-certs-generator` | — | Behind the `certs` profile: run once per incarnation |

The images and digests are `stacks/soc`'s. Dependabot opens a PR for each
stack's directory, so merge each bump together with its twin.

**The configuration is soc's, mounted rather than copied** (`compose.yaml`,
DIFFERENCE 1). A disposable SIEM that has drifted from the real one answers a
different question. Only three things here belong to this guest:

- `wazuh/certs/`: its own mTLS CA, gitignored.
- `velociraptor/etc/`: its own Velociraptor CA, gitignored.
- `wazuh/indexer/internal_users.yml`: the one copied file.
  `render-config.sh` renders the template under the deploying stack's own
  `wazuh/`, so this copy has to be kept in step with soc's.

## What is absent, and why each absence is the point

- **No ISM delete policy.** `odin` deletes at thirty days to stay inside its
  shard ceiling. Here, teardown is the delete.
- **No Alloy, and no lab scrape.** A detonation's noise in the lab's Loki would
  outlive the guest that made it, under the lab's retention. Velociraptor's
  metrics port is not published either: nothing consumes it ([ADR-0012]).
- **No backup.** The datastores live on the guest's second disk, which
  `--purge` removes. Export what the case needs before teardown, because
  nothing else will keep it.
- **No committed secrets.** [`.sops.yaml`](../../.sops.yaml) has a `scratch`
  rule with a placeholder that stays in git permanently. Each incarnation
  generates its own age key and encrypts `secrets/scratch.sops.yaml` in its
  own checkout, and `.gitignore` keeps that file out of git. The key, the
  secrets and the guest are destroyed together. The guest can never open the
  estate's credentials or `odin`'s ([ADR-0020]).
- **No sandbox.** This is where a detonation's evidence goes, not where the
  sample runs.

[ADR-0012]: ../../docs/adr/0012-publish-only-ports-with-an-off-host-consumer.md
[ADR-0020]: ../../docs/adr/0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md
[ADR-0071]: ../../docs/adr/0071-run-disposable-investigations-on-a-guest-that-is-destroyed.md
[#438]: https://github.com/Gerrrt/HomeLab/issues/438
[`run-a-scratch-investigation.md`]: ../../docs/runbooks/run-a-scratch-investigation.md
