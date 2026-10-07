# Runbook: Build `eden`, the BloodHound CE guest

**Target:** `eden`, a guest on `Saruman` on ImaginationLAN (VLAN 30), running
[`stacks/bloodhound`](../../stacks/bloodhound).

**Time:** about an evening. §1–§3 take under an hour, because the OS comes
from a template rather than an installer.

**You will need:** root on `Saruman`, the Ubuntu template `901`
([ADR-0074](../adr/0074-build-the-lab-templates-with-packer-from-phoenix.md)),
the Mac on Hicks for §4's certificate copy, and `alexander`.

**Before this:** the domain ([#414](https://github.com/Gerrrt/HomeLab/issues/414),
built 2026-09-25) and its population
([#449](https://github.com/Gerrrt/HomeLab/issues/449)). Ingesting an empty
domain proves the plumbing and nothing else. The paths get interesting once
the weaknesses of #449 are applied.

This builds what
[ADR-0081](../adr/0081-run-bloodhound-ce-on-a-saruman-guest.md) decided for
[#451](https://github.com/Gerrrt/HomeLab/issues/451): BloodHound CE on a guest
of its own, off between sessions, backed up by nothing. It follows
[`build-the-soc-guest.md`](build-the-soc-guest.md) and
[`build-the-sensor-guest.md`](build-the-sensor-guest.md). Where a step is the
same, this runbook points there and does not keep a second copy that drifts.

---

## 0. What is decided, and why

| | Decision | Why this and not the obvious alternative |
| --- | --- | --- |
| Name | `eden` | Continues the segment's summons |
| Address | `10.0.30.41/24` | Every `.x0` is taken. It sits in `alexander`'s decade, beside the other lab guest that serves a UI to a human |
| VMID | `141` | The last octet, legible from `qm list` |
| Tags | `on-demand` | Off between sessions, and `HypervisorGuestStopped` knows it ([ADR-0079](../adr/0079-tag-on-demand-guests-and-leave-them-out-of-the-stopped-guest-alert.md)) |
| `onboot` | `0` | For the same reason. A `Saruman` reboot does not bring it back, and should not |
| vCPU / RAM | 4 / 8 GiB | The stack's limits add up to about 5.5 GiB: BloodHound's 3 and Postgres's 2. The rest is the kernel, Docker and page cache |
| OS disk | 32 GB on `local-lvm` | `phoenix`'s choice. An OS disk does almost no I/O, and `large_data` is already allocated past its size (ADR-0081) |
| Data disk | 32 GB on `large_data` | Postgres holds the graph too (ADR-0081), and its random reads are what the SSDs are for. A domain of tens of objects is megabytes of graph |
| Backup | **None** | The graph is one collection run from rebuilt, and the guest is rebuilt from this repository. It stays out of `golem`'s job |
| Firewall | `firewall=0`, and no rule on `morpheus` | The upload, the browser and the Alloy push are all intra-segment or already allowed (ADR-0081) |

## 1. Create the VM, from the template

On `Saruman`. The guest is a **full clone of template `901`**, Packer's Ubuntu
26.04 ([ADR-0074](../adr/0074-build-the-lab-templates-with-packer-from-phoenix.md)),
not an ISO install. A clone needs no console, and it starts from an image that
has already passed `scripts/packer-smoke.sh`. It also inherits the template's
shape, which differs from `alexander`'s and `odin`'s: q35 and OVMF, with an EFI
disk, and the guest agent already installed.

Check the room first, against both numbers ADR-0081 states. `pvesm status`
gives what is written, and the `lvs` sum gives what is allocated:

```bash
pvesm status | grep -E 'large_data|local-lvm'
lvs --noheadings --units g -o lv_size,pool_lv large_data \
  | awk '$2=="large_data"{s+=$1} END{print s " GiB allocated"}'
```

On 2026-10-06 that was 28.7% written and 920 GiB allocated of 876. This guest
adds 32 to the allocation. If the written figure is past half, stop and ask
why before adding anything.

Clone onto `local-lvm`. That puts the OS disk, the EFI disk and the cloud-init
drive on the HDD mirror, as ADR-0081 decides:

```bash
qm clone 901 141 --name eden --full 1 --storage local-lvm
```

Then size it, add the data disk on the SSDs, and give cloud-init the user, the
key and the address. The key is the one already in `garnet`'s
`authorized_keys` on `alexander`:

```bash
qm guest exec 140 -- cat /home/garnet/.ssh/authorized_keys \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["out-data"],end="")' \
  | grep ssh-ed25519 > /root/eden.pub
```

```bash
qm set 141 \
  --cores 4 --memory 8192 --balloon 0 --onboot 0 --tags on-demand \
  --net0 virtio,bridge=vmbr0,firewall=0 \
  --scsi0 local-lvm:vm-141-disk-1,cache=none,discard=on,iothread=1,replicate=0 \
  --scsi1 large_data:32,discard=on,iothread=1,ssd=1 \
  --ciuser garnet --sshkeys /root/eden.pub \
  --ipconfig0 ip=10.0.30.41/24,gw=10.0.30.1 --nameserver 10.0.30.1
```

- **`--net0` is restated** to get `firewall=0`, as on every guest here, and a
  fresh `bc:24:11` MAC.
- **`--scsi0` is restated** to drop the template's `ssd=1`. That disk is on the
  HDD mirror now, and the flag would tell the guest otherwise.
- **The search domain** is not set, so Proxmox fills it from the host,
  `Isengard.Lab`. It is harmless, but it was not chosen. Add
  `--searchdomain` if that matters.

`qm set` warns that the sum of thin volumes exceeds the pool. That is the
allocation ADR-0081 accepts, and the warning is expected.

## 2. First boot, and the data disk

```bash
qm start 141
```

**Cloud-init's first boot leaves the guest on DHCP. Reboot once.** Its netplan
renames the NIC to `eth0` by MAC, and on the first boot the rename fails with
`[busy]` because the interface is already up. The guest then keeps a DHCP
lease (`10.0.30.103` on the first build) with the right config written but not
applied. `cloud-init status --long` shows the rename error. Once
`cloud-init status` says `done`:

```bash
qm reboot 141
qm guest exec 141 -- ip -br addr show eth0    # 10.0.30.41/24
```

The hostname comes from the VM's name, so it is `eden`. Every log line this
guest ships is labelled with it.

**The data disk** is `odin`'s § *The data disk*, with `bloodhound-data` for
`soc-data`, on the 32G `sdb`. That includes the `chattr +i` guard on the empty
mountpoint. Then create the two directories, owned by the uids the services
run as:

```bash
sudo install -d -m 0700 -o 999   -g 999   /srv/bloodhound-data/postgres
sudo install -d -m 0750 -o 65534 -g 65534 /srv/bloodhound-data/work
df -h /srv/bloodhound-data
```

`qm guest cmd 141 get-fsinfo` on `Saruman` should list `/` and
`/srv/bloodhound-data`.

## 3. Docker, the repository, and its own key

Install Docker, `age`, `git` and `make` as `alexander`'s §3 describes, and add
`garnet` to the `docker` group.

**`sops` is the release binary, not the `.deb`.** Match the version to
`alexander`'s (`sops --version` there; 3.9.4 on 2026-10-06). The release's
`checksums.txt` covers the bare binaries and not the `.deb`, so the binary is
the one that can be verified:

```bash
V=3.9.4
curl -fsSLO https://github.com/getsops/sops/releases/download/v$V/sops-v$V.linux.amd64
curl -fsSL https://github.com/getsops/sops/releases/download/v$V/sops-v$V.checksums.txt \
  | grep " sops-v$V.linux.amd64$" | sha256sum -c -
sudo install -m 0755 sops-v$V.linux.amd64 /usr/local/bin/sops
```

Clone the repository as `garnet` to `~/code/Gerrrt/HomeLab`. Then, **on
`eden`**:

```bash
cd ~/code/Gerrrt/HomeLab
make secrets-init STACK=bloodhound
```

That writes `eden`'s public key over `REPLACE_WITH_BLOODHOUND_AGE_PUBLIC_KEY`
in the `bloodhound` rule of `.sops.yaml`. Check that the file resolves to that
rule and not to the catch-all:

```bash
scripts/check_sops_rules.py | grep bloodhound
```

`secrets-init` also says to back the key up off the machine. **Do not.**
ADR-0081 gives this key no backup on purpose: everything it opens is
re-issuable.

Fill the three values that are made here.
[`secrets/bloodhound.example.yaml`](../../secrets/bloodhound.example.yaml)
says how each is made, and the admin password's symbol is the one that gets
forgotten:

```bash
make gen-secret ARGS='--count 2'
openssl rand -base64 32
make secrets-edit STACK=bloodhound
```

Leave `INGEST_TOKEN` for §5.

## 4. The certificate

As `alexander`'s §5, with a different leaf. **On `prometheus`**, where the CA
lives:

```bash
make certs ARGS="--host bloodhound.matrix.elysium --ip 10.0.30.41 --dns bloodhound"
```

Three files go to `eden`: `ca.pem`, `bloodhound.matrix.elysium.pem` and
`bloodhound.matrix.elysium-key.pem`. The CA is what this guest's Alloy
verifies the metrics port against: BloodHound serves that port on the same
leaf, and the `bloodhound` DNS SAN is the name the scrape checks.
**Never `ca-key.pem`.**

From the Mac, since `99 → 30` is closed:

```bash
ssh garnet@10.0.30.41 'mkdir -p code/Gerrrt/HomeLab/certificates && chmod 700 code/Gerrrt/HomeLab/certificates'
```

```bash
CERTS=/home/robo/code/Gerrrt/HomeLab/certificates
scp -3 -p \
  robo@10.0.99.20:$CERTS/ca.pem \
  robo@10.0.99.20:$CERTS/bloodhound.matrix.elysium.pem \
  robo@10.0.99.20:$CERTS/bloodhound.matrix.elysium-key.pem \
  garnet@10.0.30.41:code/Gerrrt/HomeLab/certificates/
```

On `eden`, the key must be `0640` and yours. BloodHound runs as `nobody` and
reads it through your gid (`group_add: ${RENDER_GID}`), the way Grafana does:

```bash
chmod 640 ~/code/Gerrrt/HomeLab/certificates/bloodhound.matrix.elysium-key.pem
```

> [!WARNING]
> **Do not run `make certs ARGS=--ca` on `eden`.** If the files are missing,
> `render-config.sh` stops and tells you not to. It would mint a second CA that
> no browser on Hicks trusts.

## 5. Its token at the lab's ingest proxy

`eden`'s Alloy pushes to `alexander`, and since
[#834](https://github.com/Gerrrt/HomeLab/issues/834) every client pushes with
its own token. The lab's half of this goes in **the same pull request** as
`eden`'s `.sops.yaml` key, in the order golem's did
([#896](https://github.com/Gerrrt/HomeLab/pull/896)).
`stacks/lab/compose.yaml` requires every token it names, so merging the name
before the value is in `secrets/lab.sops.yaml` fails `alexander`'s next
render.

1. **On `alexander`**, generate it and add it as `INGEST_TOKEN_EDEN`:

   ```bash
   openssl rand -hex 32
   make secrets-edit STACK=lab
   ```

2. **In the same branch**, add `INGEST_TOKEN_EDEN` in the five places golem's
   was added:
   - the `ingest_auth` map in `stacks/lab/Caddyfile`, as `eden agent`, and the
     client list in its header comment;
   - the `caddy` service's environment in `stacks/lab/compose.yaml`;
   - `COMPOSE_VARS` in `scripts/render-config.sh`;
   - `scripts/seed-validation-env.sh`;
   - `secrets/lab.example.yaml`, with where its other copy goes.

   Then update the client count in `stacks/lab/README.md`.
3. **On `eden`**, set `INGEST_TOKEN` to the same value with
   `make secrets-edit STACK=bloodhound`.
4. Once merged, `make up STACK=lab` on `alexander`.

## 6. Bring it up

On `eden`:

```bash
make up STACK=bloodhound
docker compose -f stacks/bloodhound/compose.yaml ps
```

`app-db` must be `healthy`, and `bloodhound` and `alloy`
`running`. `bloodhound` has no health check; ADR-0081 and its compose comment
say why.

**Three things in this stack were reasoned, not booted, when it was written.**
Check each one now:

- **BloodHound as `nobody`**, writing only to `work/`:

  ```bash
  docker logs bloodhound-app 2>&1 | grep -iE 'permission|denied|read-only' || echo clean
  ```

  If it fails, find out **what** it writes before changing the user. The
  compose comment says not to take that line out quietly.
- **The graph in Postgres.** BloodHound's start log names the graph driver
  it opened. It must be `pg`, and `docker logs bloodhound-app` must show no
  `neo4j` connection attempts:

  ```bash
  docker logs bloodhound-app 2>&1 | grep -iE 'graph|driver|neo4j' | head
  ```

- **The metrics scrape, over TLS.** The image is distroless, so nothing in it
  can `curl` its own port. Alloy's UI on `127.0.0.1:12345` shows
  `prometheus.scrape.bloodhound`'s last scrape and error. A certificate error
  there means the leaf lacks the `bloodhound` SAN. §7's `up{job="bloodhound"}`
  is the same answer from `alexander`.

Then shut it down cleanly. That is what "off between sessions" means, and the
first session should start from it:

```bash
sudo poweroff
```

## 7. Verify, and the proof that closes #451

Start the guest from `Saruman` with `qm start 141`, and wait for `make up`'s
containers to come back. They have `restart: unless-stopped`.

1. **The UI, over TLS.** From the Mac, open `https://10.0.30.41:8443/`. The
   certificate must verify against the estate's CA, which Hicks already
   trusts for the two Grafanas. Log in as `admin` with
   `BLOODHOUND_ADMIN_PASSWORD`.
2. **A collection, ingested.** Download SharpHound from the UI, under
   *Download Collectors*. That way its version is the one the server's schema
   expects. Run it from a domain-joined host as an ordinary domain user, for
   example from `carbuncle`:

   ```powershell
   .\SharpHound.exe -c All --domain ad.matrix.elysium --zipfilename eden-first.zip
   ```

   Then upload the zip under *Administration → File Ingest*. The job must
   finish **Complete**, not *Partially Complete*.
3. **A graph with edges in it.** In *Explore*, search
   `DOMAIN ADMINS@AD.MATRIX.ELYSIUM` and open *Members*. Then run the
   pre-built query *Shortest paths to Domain Admins*. Before #449's
   weaknesses, a short path through the Tier 0 groups is the expected answer.
   After them, the answer is the point of the exercise.
4. **It reaches `alexander`, and nothing reaches VLAN 99.**
   - In the lab's Grafana, `up{job="bloodhound", instance="eden"}` must read
     1, and `{host="eden"}` in Loki must return container logs.
   - In the estate's Prometheus, `{host="eden"}` must be empty, and
     `homelab_guest_on_demand{vmid="141"}`, which is the hypervisor's fact
     about the guest, must read 1.
5. **Off is not an alert.** `qm shutdown 141`. An hour later,
   `HypervisorGuestStopped` must not have fired for VMID 141.
6. **Nothing was backed up.** On `golem`, `proxmox-backup-client snapshot
   list` shows no `vm/141`.

## 8. Saved queries, if they ever matter

ADR-0081 backs up nothing, and the one thing on this guest that a collection
run does not rebuild is the custom queries saved in the UI. If those become
worth keeping, export them, not the volume. *Explore → Cypher → Saved
Queries* exports each one as JSON, and the JSON is small enough to commit
under `stacks/bloodhound/` as a file the next build imports. That is a
decision for the day it happens, and ADR-0081 lists it as a reason to reopen.

## 9. Write it down

On the same day, in one pull request with §5's lab changes:

- `.sops.yaml` with `eden`'s key, and the new `secrets/bloodhound.sops.yaml`.
- In `docs/architecture.md`, drop **Not built yet** from `eden`'s row and
  count it in `Saruman`'s.
- In `docs/network.md`, give `eden` a row in the VLAN 30 table and rewrite its
  note in the past tense. `scripts/check_docs.py` fails until both are done.
  The Alloy-agent count in `docs/hardware.md` rises by one in the same run.
- A `docs/changelog.md` entry with §7's results.
- In `docs/roadmap.md`, mark #451 done. That closes the automation milestone.
- The pull request's description says "Closes #451." as its own sentence.

## 10. Take it out

1. `qm shutdown 141` then `qm destroy 141 --purge`. `--purge` removes it from
   every backup job and HA group that names it. None should.
2. Remove the `bloodhound` rule from `.sops.yaml`, then
   `secrets/bloodhound.sops.yaml`. On `alexander`, remove `INGEST_TOKEN_EDEN`
   from the five places §5 added it.
3. Remove `stacks/bloodhound/`, its Dependabot entry and its line in
   `ABSENT_BINARIES`. Then let `scripts/check_docs.py` say which sentences are
   left.
4. Revoke the leaf on `prometheus` by deleting its two files. The estate's CA
   has no CRL, so the leaf stays valid until it expires. Nothing trusts it for
   anything but `bloodhound.matrix.elysium`.
