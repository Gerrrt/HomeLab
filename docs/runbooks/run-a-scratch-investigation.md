# Runbook: Run a scratch investigation on `diabolos`, then destroy it

**Target:** `diabolos`, a guest on `Saruman`, ImaginationLAN (VLAN 30), that
exists only for the length of one investigation
**Time:** about an hour to build and five minutes to destroy. The investigation
in between is yours.
**You will need:**
- a shell on `Saruman`;
- an Ubuntu Server ISO;
- a browser on Hicks.

**Before this:** nothing. `stacks/scratch` does not depend on `odin` being up.

This builds and destroys the guest that
[ADR-0071](../adr/0071-run-disposable-investigations-on-a-guest-that-is-destroyed.md)
calls for: soc's stack in a store that is meant to be filled with noise and
deleted. **The build and the teardown are one runbook on purpose.** A guest
whose destruction lives in a different document is a guest that stays.

Most steps are identical to [`build-the-soc-guest.md`](build-the-soc-guest.md).
Where one is, this runbook points there rather than carrying a second copy that
drifts. What follows covers only where `diabolos` differs, and every difference
is one of three things:

- it is tagged;
- nothing on it is committed;
- nothing on it is kept.

---

## 1. Create the VM, tagged

On `Saruman`:

```bash
qm create 161 \
  --name diabolos \
  --tags disposable \
  --ostype l26 \
  --cpu host --cores 4 --sockets 1 \
  --memory 16384 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 large_data:32,discard=on,iothread=1,ssd=1 \
  --scsi1 large_data:96,discard=on,iothread=1,ssd=1 \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 \
  --onboot 0 \
  --ide2 local:iso/ubuntu-24.04-live-server-amd64.iso,media=cdrom \
  --boot order='scsi0;ide2'
```

The numbers are `odin`'s, and soc's §1 explains each flag. Two of them differ,
and they differ on purpose:

- **`--tags disposable` is the lifecycle.** `collect-guest-state.sh` reads it
  from `qm config 161` on its next run and reports
  `homelab_guest_disposable` along with the guest's creation time.
  `DisposableGuestOutlived` fires a fortnight from now if this guest still
  exists. Do not leave the tag off to save yourself the reminder. The reminder
  is the design.
- **`--onboot 0`.** `odin` comes back after a hypervisor reboot because a SIEM
  that stays down is a gap. This guest staying down is fine.

Check that the tag landed and that the estate can see it:

```bash
qm config 161 | grep -E '^(tags|meta):'
sudo /usr/local/bin/homelab-collect-guest-state --print | grep 'vmid="161"'
```

The first command prints `tags: disposable` and a `meta:` line with `ctime=`.
The second prints `homelab_guest_disposable{...} 1` and a
`homelab_guest_created_timestamp_seconds` line. If `ctime` is missing, the alert
cannot measure this guest's age. Say so in the case notes and destroy the guest
by hand.

## 2. Ubuntu, the data disk, Docker and the kernel setting

Follow soc's §2 to §4 with these values:

| | |
| --- | --- |
| Hostname | `diabolos` |
| Address | `10.0.30.61/24` |
| Gateway, DNS | `10.0.30.1` |
| Data disk mountpoint | `/srv/scratch-data` (`SCRATCH_DATA_DIR`), labelled `scratch-data` |

Make the same four directories under `/srv/scratch-data` with the same owners,
and apply the same `chattr +i` guard on the empty mountpoint. Run the same
`id -u` check, which must print `1000`. Set the same `vm.max_map_count`. Then
make the Velociraptor config directory root's:

```bash
sudo chown root:root ~/HomeLab/stacks/scratch/velociraptor/etc
```

## 3. Its own age key, which is never committed

Run this on `diabolos`:

```bash
cd ~/HomeLab
make secrets-init STACK=scratch
```

`bootstrap.sh` writes this guest's public key over
`REPLACE_WITH_SCRATCH_AGE_PUBLIC_KEY` in `.sops.yaml`. **That edit stays in this
checkout.** Do not commit it, and do not push from this guest.

Make the two hashes with the indexer image's tool, as in soc's §5:

```bash
docker run --rm -it --entrypoint bash \
  "$(COMPOSE_FILE=stacks/scratch/compose.yaml scripts/image-for.sh wazuh.indexer)" \
  /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh
```

Then fill in the seven values:

```bash
make secrets-edit STACK=scratch
```

Use **fresh values**, never `odin`'s.
[`secrets/scratch.example.yaml`](../../secrets/scratch.example.yaml) lists the
keys. `API_PASSWORD` has the same character rules as soc's.

Run the two checks:

```bash
git status --short
python3 scripts/check_sops_rules.py
```

- `git status` shows `.sops.yaml` modified and **no** `secrets/scratch.sops.yaml`,
  because `.gitignore` keeps it out.
- `check_sops_rules.py` passes.

**Do not back this key up.** Every other age key in this repository has a
proved off-box copy (ADR-0024). This one is meant to die with the guest.

## 4. Certificates, then up

```bash
make render STACK=scratch
docker compose -f stacks/scratch/compose.yaml --profile certs run --rm wazuh.certs-generator
make up STACK=scratch
make ps STACK=scratch
```

Soc's §6 and §8 describe what to expect: twelve certificate files, the slow
first start, and Velociraptor fetching its client release. Soc's §6 also has a
`chmod 0444` on `root-ca.pem`. That step is for soc's Alloy, and this stack has
no Alloy, so skip it.

Container names are prefixed `scratch-`, so `docker logs scratch-wazuh-indexer`
is the first place to look.

## 5. The index template, and deliberately no retention

Apply the one-shard, zero-replica template from soc's directory, because the
reason for it (a single node) is the same:

```bash
AUTH='--cert /usr/share/wazuh-indexer/config/certs/admin.pem --key /usr/share/wazuh-indexer/config/certs/admin-key.pem'
docker compose -f stacks/scratch/compose.yaml exec -T wazuh.indexer \
  curl -sk $AUTH -H 'Content-Type: application/json' \
  -XPUT https://localhost:9200/_template/wazuh-alerts-homelab \
  --data-binary @- < stacks/soc/wazuh/indexer/template-wazuh-alerts.json
```

**Do not apply `ism-wazuh-alerts.json`.** This store has no retention policy;
teardown is the retention policy. That also means `.opendistro-ism-config` is
never created, so soc's replica fix is not needed.

## 6. The investigation

Open the dashboard at `https://10.0.30.61` and Velociraptor at
`https://10.0.30.61:8889` from Hicks.

- **Agents** enrol against `10.0.30.61` with this guest's
  `WAZUH_REGISTRATION_PASSWORD`. Velociraptor clients are built from this
  guest's own config and pinned to this guest's own CA, so none of them can
  ever report to `odin`.
- **The sample does not run here.** This guest is the store; the range is where
  things detonate (ADR-0014, ADR-0017).

Write the case notes somewhere that outlives the guest, starting now.

## 7. Export what the case needs

Nothing on `diabolos` survives step 8. Before destroying it, copy off whatever
the case needs, such as a Velociraptor collection export, a dashboard report or
saved searches, and put it where the case notes are. A file that only exists on
this guest after this step is gone after the next one.

## 8. Destroy it

On `Saruman`:

```bash
qm stop 161
qm destroy 161 --purge
```

`--purge` also removes the guest from backup jobs and HA. The guest, both disks,
the age key, `secrets/scratch.sops.yaml`, both CAs and every indexed event go
together. **Nothing in git changes**, and there is nothing to commit or revert.

## 9. Check it is gone

```bash
qm list | grep -w 161 || echo gone
```

On the next collector run, `homelab_guest_disposable{vmid="161"}` stops being
reported, and `DisposableGuestOutlived`, if it had fired, resolves. A
`DisposableGuestOutlived` that is still firing after this step means the guest
was not destroyed. Do not silence the alert. Destroy the guest.

If the investigation turns out not to be disposable after all, and its store
is now something to keep, **removing the tag is a decision, not a fix for a
reminder.** At that point it is a second durable SIEM, so build it the way
`odin` was built and write the ADR.
