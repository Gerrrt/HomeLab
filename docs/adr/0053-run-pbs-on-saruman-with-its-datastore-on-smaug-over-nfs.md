# ADR-0053: Run PBS on `Saruman` with its datastore on `smaug` over NFS

**Status:** Accepted · 2026-09 · ends
[ADR-0027](0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md)'s
deferral in a different shape from the one it specified; decides the
re-read [#485](https://github.com/Gerrrt/HomeLab/issues/485) asked for

## Context

ADR-0027 deferred Proxmox Backup Server on one argument: *a hypervisor
backing up its own guests to itself is not a backup.* It named its trigger,
`smaug` answering on `10.0.40.30`, and the shape to build when it fired:

> the datastore local to `Saruman` for speed and dedup, and a **sync job to
> `zion`** for the copy that survives the hypervisor.

The trigger fired on 2026-09-16, and `erebor` has been online since
2026-09-19 (#522). But a PBS sync job pulls from one PBS instance into
another, and ADR-0027 assumed the NAS would be a Linux host that could run
one. [ADR-0040](0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)
made it TrueNAS. So the second instance would have to be a VM on `smaug`,
which has 8 GB of memory in one of four slots, shared by ZFS's cache and
Jellyfin's transcoding ([#599](https://github.com/Gerrrt/HomeLab/issues/599)).

The four answers #485 weighed:

| Answer | For | Against |
| --- | --- | --- |
| ADR-0027 as written: local datastore plus a PBS VM on `smaug` | Two independent instances, the shape PBS is designed around | A VM on `smaug`'s 8 GB; waits on #599 |
| **PBS on `Saruman`, datastore on `smaug` over NFS** | One instance, on the host with 128 GB; keeps deduplication, incremental backups and verify jobs; uses none of `smaug`'s memory | One instance can prune its only copy, unless something outside it keeps one |
| Plain `vzdump` to an NFS share | Nothing new to run | Full copies every time, and nothing verifies them: the green check ADR-0027 refused |
| No lab backup, by decision | Nothing to build | The domain and `odin`'s evidence stay revert-only for good |

## Decision

**A PBS guest on `Saruman` whose only datastore is an NFSv4 share on
`erebor`, with TrueNAS snapshots of that dataset as the copy `Saruman`
cannot touch.**

- **The guest.** It is named `golem`, a summon like the rest of the
  segment and the one known as a guardian, VMID `180`, at `10.0.30.80`, the
  next decade after `phoenix`'s `.70`. It gets a small OS disk on
  `large_data` and no datastore disk.
  [ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
  gave PBS "zero disk on this pool" and sized the domain's six guests
  against a pool PBS is not competing for. That still holds: the data does
  not live on `Saruman`, so PBS takes only an OS disk's worth.
- **The datastore.** It is a dataset `erebor/pbs`, shared over NFSv4 to
  `10.0.30.80` alone, owned by uid and gid 34, which is PBS's `backup`
  user. Nothing maps to root. `atime` is **on** for that dataset: PBS's
  garbage collection marks chunks by access time, and a datastore that
  cannot record one loses chunks that are still in use. Recent PBS
  releases check this when the datastore is created; check it anyway.
- **The copy outside PBS's reach.** A TrueNAS periodic snapshot task on
  `erebor/pbs`, daily, keeping fourteen. These are what ADR-0027's second
  instance was for. A snapshot is read-only to an NFS client, so root on
  `Saruman` or in PBS can prune the datastore and still not touch the last
  fortnight of it. Restoring means rolling the dataset back on `smaug`.
- **Encrypted on the client.** The datastore sits on the NAS in
  CasaBonita, on the media segment beside the televisions. PVE encrypts
  each backup with a key before it leaves `Saruman`. A copy of that key
  goes into `secrets/lab.sops.yaml`, encrypted to the lab's own age key by
  [ADR-0020](0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)'s rule, because a rebuilt
  `Saruman` without it cannot read a single backup.
- **The rule.** One more CasaBonita pass on `morpheus`:
  `10.0.30.80 → 10.0.40.30`, TCP `2049`, NFSv4 only, so no portmapper and
  no second port. It sits above *Block access to CasaBonita*, in the shape
  [#446](https://github.com/Gerrrt/HomeLab/issues/446) describes, and is
  checked from `morpheus` rather than from the UI.
- **What is backed up** is ADR-0027's table, unchanged: the Windows domain
  and `odin`, including its data disk, which holds the indexer's alerts and
  Velociraptor's collections ([#439](https://github.com/Gerrrt/HomeLab/issues/439)).
  Not `alexander`, not `ifrit`, and not `phoenix` or `golem` itself,
  which are rebuilt from this repository.
- **Verified where the lab can see it.** A scheduled verify job, and prune
  and garbage collection, whose outcome reaches the lab's Prometheus on
  `alexander` like any other guest's telemetry (ADR-0007 keeps it in the
  lab). A verify job nobody watches is ADR-0027's green check again. The
  mechanism, a textfile collector reading PBS's task list or an exporter,
  is the build's to choose.

## Consequences

- **The lab has a backup, not only revert, once this is built.** ADR-0027's
  sentence "the lab has revert and not backup" becomes false on that day,
  and so does `build-the-soc-guest.md`'s note that `odin` "has revert
  rather than backup".
- **Independence comes from ZFS, not from PBS.** A PBS sync job would have
  given a second chunk store with its own verification. TrueNAS snapshots
  give a frozen copy of the same one. That protects against pruning,
  ransomware on `Saruman` and a bad garbage collection. It does not protect
  against `erebor` itself, which is the next point.
- **The backups share `smaug`'s disks with everything else on it.** This is
  the same single NAS the estate's own sets are copied to. Until
  [#558](https://github.com/Gerrrt/HomeLab/issues/558)'s swap, that is one
  disk. The offsite answer for the estate's sets
  ([ADR-0048](0048-carry-the-estates-backup-sets-with-the-second-recipient.md))
  does not cover these, and the lab's data is not worth that medium's
  space. A lost `erebor` loses the lab's backups, and that is accepted.
- **Backup traffic crosses the firewall.** `Saruman` is on VLAN 30 and
  `smaug` on VLAN 40, so every chunk is routed by `morpheus`. PBS's
  incremental, deduplicated shape is most of why that is acceptable: after
  the first full backup, a nightly job moves what changed. The first run of
  the domain's six guests will be slow, and is best started in the evening.
- **Garbage collection and verify are slow on this datastore.** Both walk
  every chunk, over NFS, on a spinning mirror. Schedule them weekly and out
  of hours, and expect hours rather than minutes.
- **`smaug`'s memory is untouched.** None of this runs there; #599 stays a
  question about ZFS and transcoding, not about backups.
- **If `smaug` is ever given more memory**, a second PBS there and
  ADR-0027's sync job become possible. That would supersede this ADR rather
  than amend it, because the independence would move from ZFS snapshots to
  a second instance.
