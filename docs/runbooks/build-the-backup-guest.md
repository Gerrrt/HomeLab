# Runbook: Build `golem`, the Proxmox Backup Server guest

**Target:** `golem` — a guest on `Saruman`, ImaginationLAN (VLAN 30), with its
datastore on `smaug` (CasaBonita, VLAN 40)
**Time:** an evening. The first real backup is the guests' first full copy
over the firewall, so start it before bed
**You will need:** the Proxmox web UI on `Saruman`, the TrueNAS UI on `smaug`
and its console shell, the pfSense UI and a shell on `morpheus`, a Proxmox
Backup Server ISO, a browser on Hicks, and `alexander` for the lab's SOPS
file
**Before this:** nothing blocks the build. But
[ADR-0053](../adr/0053-run-pbs-on-saruman-with-its-datastore-on-smaug-over-nfs.md)
backs up the Windows domain ([#414](https://github.com/Gerrrt/HomeLab/issues/414))
and `odin` ([`build-the-soc-guest.md`](build-the-soc-guest.md)), and on
2026-09-23 neither exists. Built before them, `golem` has nothing to protect
yet. §9 proves the path with a one-off backup of `phoenix` instead, and §8's
job gains its guests as they are built. **`erebor` is also one disk until
[#558](https://github.com/Gerrrt/HomeLab/issues/558)**, so the datastore
starts on a pool with no redundancy of its own. ADR-0053 accepts that.

This is ADR-0053 made into steps: one PBS guest, its only datastore an NFSv4
share on `erebor`, TrueNAS snapshots as the copy PBS cannot prune, and every
backup encrypted before it leaves `Saruman`. Where a step matches another
guest's runbook, this points there rather than carrying a second copy.

---

## 0. What is decided, and why

| | Decision | Why |
| --- | --- | --- |
| Name | `golem` | A summon, like the rest of the segment, and the one known as a guardian. `carbuncle` was the obvious one and belongs to ADR-0029's domain |
| Address | `10.0.30.80/24` | Static below `.100`, the next decade after `phoenix`'s `.70` |
| VMID | `180` | Last octet legible from `qm list` |
| Kind | **VM, from the PBS ISO** | The appliance installer brings the right repositories, kernel and packages. PBS in an LXC is possible and adds NFS-in-a-container problems for nothing |
| vCPU / RAM | 2 / **4 GiB** | Deduplication and verification hash every chunk; PBS's stated minimum is 2 GiB, and 4 lets verify run beside a backup. `Saruman` has 128 GB |
| OS disk | 32 GB on `large_data` | Only the OS and PBS's own logs. The data is not on `Saruman` |
| Datastore | `erebor/pbs` over NFSv4 | ADR-0053. `atime` on, owned by uid and gid 34, shared to `10.0.30.80` alone |
| Encryption | On, key made by PVE | The datastore is on the media segment's NAS. The key is copied into `secrets/lab.sops.yaml` (§7) |
| Retention | PBS prune job: 7 daily, 4 weekly, 3 monthly | PBS decides retention, not the PVE job, so there is one place to read it |

## 1. Create the VM

On `Saruman`, as for `alexander` (its §1 explains each flag). Upload the PBS
ISO to `local` first, and check `pvesm status` for room on `large_data`:

```bash
qm create 180 \
  --name golem \
  --ostype l26 \
  --cpu host --cores 2 --sockets 1 \
  --memory 4096 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 large_data:32,discard=on,iothread=1,ssd=1 \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 \
  --onboot 1 \
  --ide2 local:iso/proxmox-backup-server_<version>.iso,media=cdrom \
  --boot order='scsi0;ide2'
```

Leave the NIC's firewall off, as `build-the-playground.md` §4 says for every
guest: the hypervisor's firewall guards the hypervisor, not its guests.

## 2. Install PBS

Boot the VM and run the graphical installer onto the 32 GB disk:

| | |
| --- | --- |
| Hostname (FQDN) | `golem.matrix.elysium`, the suffix the lab's other hosts carry |
| Address | `10.0.30.80/24` |
| Gateway | `10.0.30.1` |
| DNS | `10.0.30.1` — Unbound on the gateway ([ADR-0010](../adr/0010-keep-the-resolver-on-the-gateway.md)) |

When it reboots, open `https://10.0.30.80:8007` from a browser on Hicks. That
path is Hicks to ImaginationLAN, which the firewall already allows. Log in as
`root@pam`.

Then the repositories, the way `Saruman` runs: in the web UI,
*Administration → Repositories*, disable the enterprise repository and add
the **No-Subscription** one. Then, on `golem`'s shell:

```bash
apt update && apt full-upgrade -y
```

And the guest agent, which `--agent enabled=1` expects and does not install:

```bash
apt install -y qemu-guest-agent nfs-common && systemctl start qemu-guest-agent
```

`qm guest exec 180 -- uptime` from `Saruman` is the check.

## 3. The dataset, the share and the snapshots, on `smaug`

In the TrueNAS UI.

**The dataset.** *Datasets → `erebor` → Add Dataset*: name `pbs`, preset
*Generic*. Under *Advanced Options*, set **Atime: On**. That is the setting
the whole datastore depends on: PBS's garbage collection marks the chunks
still in use by touching their access time, then deletes the untouched ones.
On a dataset that ignores the touch, garbage collection deletes chunks that
backups still need. A new dataset may inherit `atime` off from the pool, so
check it on the dataset's page after saving, not on the form:
`zfs get atime erebor/pbs` on the console must say `on`.

**The owner**, from `smaug`'s console shell. PBS writes as its `backup` user,
uid and gid 34, and so does TrueNAS's Debian base. Confirm that, then give it
the dataset:

```bash
id backup && chown 34:34 /mnt/erebor/pbs && chmod 750 /mnt/erebor/pbs
```

`id` must print `uid=34(backup) gid=34(backup)`. If the numbers differ, stop:
the share mapping below would map to the wrong user.

**The share.** First *System → Services → NFS*: enable **NFSv4** and start
the service. Then *Shares → Unix (NFS) Shares → Add*:

| | |
| --- | --- |
| Path | `/mnt/erebor/pbs` |
| Authorized hosts | `10.0.30.80` |
| Maproot User / Group | `backup` / `backup` |
| Mapall | empty |

**Maproot to `backup`, not to `root`.** PBS creates the datastore as root, and
a share that squashes root to `nobody` refuses to let it. Mapping root to uid
34 lets the datastore be created with the owner it will be written by, and
still maps nothing on `golem` to root on `smaug`. That is ADR-0053's "nothing
maps to root".

**The snapshots.** *Data Protection → Periodic Snapshot Tasks → Add*: dataset
`erebor/pbs`, not recursive, schedule daily, lifetime **14 days**. These are
the copy PBS cannot prune: a snapshot is read-only to an NFS client, so root
on `Saruman` or on `golem` can delete backups from the datastore and not
from the last fortnight of snapshots.

## 4. The pass on `morpheus`

One rule, on the **ImaginationLAN (30)** interface in the pfSense UI:
protocol `tcp`, source `10.0.30.80`, destination `10.0.40.30`, port `2049`,
description exactly **`Allow NFS from golem to smaug`**. NFSv4 needs only
`2049`: no portmapper, no second port.

**Where it goes depends on a rule this repository does not name.** The
segment is "reachable from Hicks only; outbound internet permitted"
(`network.md`), so something on `igc0.30` stops it reaching the other
private segments, and the pass has to sit above that. Read the interface's
rules first, from `morpheus`, and find the first block whose destination
covers `10.0.40.0/24`:

```bash
pfctl -sr -vv | grep -E 'on igc0\.30 '
```

Put the pass directly above that block, save, and read the same command
again: `Allow NFS from golem to smaug` must now come before it. Read the
order, not the `@` numbers, for the reason
[`build-the-nas.md`](build-the-nas.md) §0.6 gives. Then write the block's
description into `network.md`'s ImaginationLAN notes (§12), so the next
reader does not have to find it again.

And from both sides of the scope. From `golem`, the port answers:

```bash
nc -z -w 3 10.0.40.30 2049 && echo "2049 open"
```

From `alexander`, which is on the same segment and is not `golem`, it must
not. That proves the rule is scoped to one address rather than to the
segment:

```bash
nc -z -w 3 10.0.40.30 2049 && echo "2049 OPEN - wrong" || echo "2049 refused - correct"
```

## 5. Mount the share, and make the datastore

On `golem`. The mountpoint gets the same guard `odin`'s data disk has
([`build-the-soc-guest.md`](build-the-soc-guest.md) §2): made immutable while
empty, so an unmounted share leaves nothing for PBS to write into, instead of
quietly filling the 32 GB OS disk:

```bash
mkdir -p /mnt/datastore/erebor && chattr +i /mnt/datastore/erebor
```

```bash
echo "10.0.40.30:/mnt/erebor/pbs /mnt/datastore/erebor nfs4 rw,hard,_netdev,nofail 0 0" >> /etc/fstab && systemctl daemon-reload && mount /mnt/datastore/erebor && df -h /mnt/datastore/erebor
```

**No `noatime` in those options**, for §3's reason. `df` should show
`10.0.40.30:/mnt/erebor/pbs` with the pool's free space.

Then the datastore:

```bash
proxmox-backup-manager datastore create erebor /mnt/datastore/erebor
```

It creates the chunk directories, which takes a minute over NFS. Recent PBS
releases also check at this point that access times are recorded. If it
refuses on `atime`, the dataset setting in §3 did not take.

## 6. Retention, garbage collection and verification

Still on `golem`. Three schedules, all out of hours, because each one walks
the datastore over NFS on a spinning mirror and takes hours:

```bash
proxmox-backup-manager prune-job create daily --store erebor --schedule 'daily' --keep-daily 7 --keep-weekly 4 --keep-monthly 3
```

```bash
proxmox-backup-manager datastore update erebor --gc-schedule 'sat 03:00'
```

```bash
proxmox-backup-manager verify-job create weekly --store erebor --schedule 'sun 03:00' --ignore-verified true --outdated-after 30
```

The verify job re-reads every snapshot not verified in the last 30 days, and
checks each chunk against its hash. If a subcommand's options differ in the
installed release, `--help` on it shows the current form; the web UI's
*Datastore → erebor* tabs set the same three things.

**A user for `Saruman`, with a token, allowed to back up and nothing else:**

```bash
proxmox-backup-manager user create pve@pbs && proxmox-backup-manager user generate-token pve@pbs saruman
```

Keep the token secret it prints for §7; it is shown once. Then its
permission, on the datastore only:

```bash
proxmox-backup-manager acl update /datastore/erebor DatastoreBackup --auth-id 'pve@pbs!saruman'
```

And the fingerprint §7 pins:

```bash
proxmox-backup-manager cert info | grep -i fingerprint
```

## 7. `Saruman` stores to it, encrypted

On `Saruman`:

```bash
pvesm add pbs golem --server 10.0.30.80 --datastore erebor --username 'pve@pbs!saruman' --password '<token secret from §6>' --fingerprint '<fingerprint from §6>' --encryption-key autogen
```

`--encryption-key autogen` makes a key on `Saruman` and encrypts every backup
with it before the chunks leave. The key is at
`/etc/pve/priv/storage/golem.enc`, and **it is the only thing that can read
those backups.** A rebuilt `Saruman` without it has a datastore full of
ciphertext.

So copy it off now, in two forms. Into the lab's SOPS file, from `alexander`,
which holds the lab's age key (ADR-0020):

```bash
cd ~/HomeLab && make secrets-edit STACK=lab
```

Add a key `PBS_ENCRYPTION_KEY` whose value is the whole contents of
`golem.enc`, a short JSON document. Commit the re-encrypted file. And a paper
copy, which survives the lab's age key being lost too:

```bash
proxmox-backup-client key paperkey /etc/pve/priv/storage/golem.enc --output-format text
```

Print it, and keep it where the age key's own backup lives
([`back-up-the-age-key.md`](back-up-the-age-key.md)).

`pvesm status` now lists `golem` as *active*.

## 8. The backup job

*Datacenter → Backup → Add* on `Saruman`:

| | |
| --- | --- |
| Storage | `golem` |
| Schedule | `21:00` |
| Selection | `odin` (160) and the domain's six, as each is built |
| Mode | Snapshot |
| Retention | *Keep all backups* — PBS's prune job in §6 decides |

On the day this is built, the selection may be empty. That is correct: ADR-0053
backs up the domain and `odin`, and neither may exist yet. `alexander`,
`phoenix`, `ifrit` and `golem` itself are rebuilt from this repository and
stay out.

## 9. Prove it: one backup, one restore, then delete both

Nothing is proved by a datastore that has never held a backup. Use `phoenix`
(170), which exists and is small, for one run:

```bash
vzdump 170 --storage golem --mode snapshot
```

Then read, on `golem`'s web UI, that the snapshot is marked **encrypted**,
and run a verify on it by hand (*Datastore → erebor → Content →* the
snapshot *→ Verify*). It must pass.

Then restore it to a spare VMID, which proves the key in §7 is the right one
and that the backup is readable, not just present:

```bash
qmrestore golem:backup/vm/170/<timestamp> 979 --storage large_data --unique 1
```

`--unique 1` gives the copy a new MAC, so it cannot collide with the real
`phoenix`. Start it detached from the network if you want to check it boots,
then remove both:

```bash
qm destroy 979 --purge
```

And delete the test snapshot from `golem`'s UI, so the datastore holds only
what §8 puts there.

## 10. Make the verification visible

ADR-0053 and ADR-0027 both require that a verify job's outcome reaches where
the lab already looks, because a verify nobody watches is a green check with
nothing behind it. Two pieces:

1. **`golem`'s agent**, as `phoenix`'s: the native Alloy package, from the
   Mac, pushing to `alexander`
   ([`build-the-jumpbox.md`](build-the-jumpbox.md) §6):

   ```bash
   ./scripts/deploy-agent.sh --runtime native --monitoring-host 10.0.30.40 root@10.0.30.80
   ```

   PBS is Debian with journald and may ship no `/var/log/auth.log` or
   `/var/log/syslog`. `build-the-lab-guest.md` explains why that makes
   `config.alloy` collect nothing from them while reporting healthy, and
   `apt install -y rsyslog` is the fix.
2. **The PBS task outcomes**, which the agent cannot see by itself. This is
   a textfile collector that does not exist yet: something that reads the
   last verify, prune and garbage-collection results from
   `proxmox-backup-manager` and writes them into the textfile directory, with
   a rule in the lab's Prometheus that fires when the last verify failed or
   is older than a fortnight. It is written, with fixtures, as its own change
   once there is a real PBS to read output from.
   **[#485](https://github.com/Gerrrt/HomeLab/issues/485) stays open until it
   exists.**

## 11. If something goes wrong

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `mount` hangs | The `2049` pass is missing, below the block, or scoped to the wrong address | §4's `pfctl` line and the `nc` from `golem` |
| `mount` works, `datastore create` fails with permission denied | The share squashes root to `nobody` | §3's Maproot, set to `backup` |
| `datastore create` refuses on `atime` | `atime` is off on `erebor/pbs` | Turn it on in the dataset's settings, then run §5's create again |
| PBS writes to the OS disk and `/` fills | The share was not mounted | Cannot happen with §5's `chattr +i`. If `/mnt/datastore/erebor` is writable while unmounted, the attribute is missing |
| Backups succeed, restore fails to decrypt | The key on `Saruman` is not the one the backups were made with | Restore `golem.enc` from `secrets/lab.sops.yaml` or the paper key, to `/etc/pve/priv/storage/golem.enc` |
| Garbage collection deletes chunks a backup needs, and verify reports missing chunks | `atime` was off when garbage collection ran | Roll `erebor/pbs` back to the newest TrueNAS snapshot from before that run, then fix `atime` |

## 12. Write it down

- `docs/network.md` — a row for `golem` in the ImaginationLAN table, the new
  pass in the CasaBonita section, and the description of the `igc0.30` block
  §4 placed it above.
- `docs/architecture.md` — a row for `golem`; `check_docs.py` says what the
  marker rules are, as it does for `odin`.
- `docs/hardware.md` — the Alloy agent count rises by one.
- ADR-0053's consequence and `build-the-soc-guest.md`'s note that `odin`
  "has revert rather than backup" become history, dated.
- `build-the-nas.md` §8's PBS bullet: done, with the date.
- [#485](https://github.com/Gerrrt/HomeLab/issues/485) closes when §10's
  collector exists and the first real backup of a guest from §8 has
  verified, not on the day `golem` boots.
