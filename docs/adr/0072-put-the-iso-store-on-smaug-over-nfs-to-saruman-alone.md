# ADR-0072: Put the ISO store on `smaug`, over NFSv4 to `Saruman` alone

**Status:** Accepted · 2026-10 · adds a rule to the set
[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md) began,
on ImaginationLAN rather than Hicks or Winterfell; decides
[#446](https://github.com/Gerrrt/HomeLab/issues/446)

> [!NOTE]
> **The checksum control is daily, not per build.** Added 2026-10-01. The
> consequence below says #440 must verify each ISO "before it builds from
> it". `phoenix`, which runs Packer, cannot: it reaches `Saruman` on `8006`
> alone and has no route to `2049`, and the Proxmox API has no call that
> hashes a stored file. So `Saruman` hashes every file on the store once a
> day against the list in `scripts/collect-iso-store-state.sh`, and
> `IsoChecksumMismatch` pages on a change
> ([`build-the-lab-templates.md`](../runbooks/build-the-lab-templates.md)
> §2b). `phoenix` holds read-only `PVEAuditor` on the store, so it cannot
> write to it either. What this costs is up to a day between a replacement
> and the page. The text below is left as written, per ADR-0001.

## Context

Packer ([#440](https://github.com/Gerrrt/HomeLab/issues/440)) builds templates
from installer ISOs, and each Windows build reads three: the installer, an
Autounattend answer-file disc, and the VirtIO disc. On `Saruman`'s local
storage those reads land on the 7.2K mirror. That mirror is the binding
constraint in every sizing decision
[ADR-0029](0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
makes, and the reason the lab domain's endpoints run per session rather than
all the time. An ISO is read once, sequentially, per build, so network latency
costs nothing. Putting the ISOs on `smaug` takes that load off the mirror.
It also puts them where a second host could reach them, though this ADR
grants that host nothing (see Consequences).

**Live VM disks stay on local storage.** Random I/O over the network would
undo what [#418](https://github.com/Gerrrt/HomeLab/issues/418)'s SSDs are for.
This store holds ISOs and nothing else.

The issue left two questions open for whoever built it:

- **Where the ISOs sit:** a dataset of their own, or under `erebor/apps`.
- **How they are shared:** through the SMB `media` share that
  [`build-the-nas.md`](../runbooks/build-the-nas.md) §5 created, or through a
  second share scoped to `Saruman`.

It also asked for the rule to be written into ADR-0016's list and not appended
to the firewall later, which is the failure mode
[#229](https://github.com/Gerrrt/HomeLab/issues/229) and
[#344](https://github.com/Gerrrt/HomeLab/issues/344) both recorded.

[ADR-0053](0053-run-pbs-on-saruman-with-its-datastore-on-smaug-over-nfs.md) has
since decided a share of the same shape: `golem` on VLAN 30 mounting
`erebor/pbs` over NFSv4, through one pass on `2049`. Its runbook,
[`build-the-backup-guest.md`](../runbooks/build-the-backup-guest.md), is the
procedure this one follows. On 2026-10-01 neither share exists, and the NFS
service on `smaug` is not running.

## Decision

1. **A dataset of its own, `erebor/iso`.** It is not under `erebor/apps`.
   That dataset is the estate's backed-up tier: it is snapshotted nightly
   (§4.1) and pulled off-host by `frodo` (§6.2). Its whole design is that it
   holds megabytes that cannot be replaced. ISOs are gigabytes that can be
   downloaded again, the same class as the library
   ([ADR-0008](0008-place-services-by-data-trust.md)), so `erebor/iso` has
   **no snapshot task and no backup**. It is capped with a **500 GiB quota**,
   so a build that loops on uploads fills the quota, not `erebor`. Record
   size `1M` and atime off, as for `erebor/media`, since it holds large
   files that are read sequentially.

2. **NFSv4, exported to `10.0.30.110` alone. Not the `media` share, and not
   a second SMB share.**
   - The `media` share is the household's. It is case-insensitive, it has
     NFSv4 ACLs written for televisions and Windows, and its two users are
     a TV and a person. A hypervisor is neither.
   - A second SMB share would put a password in `Saruman`'s storage
     configuration and need another `445` pass from VLAN 30.
   - NFSv4 is what ADR-0053 already turns the service on for. It needs only
     `2049`: no portmapper and no second port. It is the protocol Proxmox
     and Packer expect for this.
   - The export is scoped to the hypervisor's own address, as `erebor/pbs`'s
     is scoped to `golem`'s.

3. **Root on `Saruman` maps to a dedicated user, `pippin`, not to root and
   not to `nobody`.** Proxmox writes uploads as root, and Packer uploads the
   answer-file disc it generates to the same storage, so the share must
   accept writes. If root were squashed to `nobody`, those writes would be
   refused. If root mapped to root, the hypervisor would be root on the
   NAS's filesystem. `pippin` owns `/mnt/erebor/iso` and nothing else. It
   has no SMB access, no shell, no SSH and no TrueNAS access. This is
   ADR-0053's "nothing maps to root" with a user of its own instead of
   `backup`.

4. **A pass on ImaginationLAN: `10.0.30.110 → 10.0.40.30:2049/tcp`**,
   described **`Allow NFS from Saruman to smaug`**. It sits above whatever
   block on `igc0.30` first covers `10.0.40.0/24`, the same block
   `build-the-backup-guest.md` §4 tells the reader to find and name. It is a
   rule of its own, not a source added to `golem`'s, because the position
   checks match on the description. Its named consumer, as
   [ADR-0012](0012-publish-only-ports-with-an-off-host-consumer.md) requires,
   is **`Saruman`'s template builds**. It has no ordinal. #446 called it the
   fifth, #523's `445` pass was also called the fifth, and the pass counts
   in the documents have drifted twice. It is *another inbound pass*,
   specified here and created by hand.

5. **`Saruman` mounts the share from `/etc/fstab` and adds it to Proxmox as a
   `dir` storage, `smaug-iso`, with `is_mountpoint` set.** Proxmox's own NFS
   storage type checks an NFSv4 server with `rpcinfo` first, which asks the
   portmapper on `111`. Only when that fails does it fall back to probing
   `2049`. That works, but every status check then waits on a port this
   rule does not open. An `fstab` mount is what `golem` does. `is_mountpoint`
   stops Proxmox writing ISOs onto `Saruman`'s root disk when the share is
   not mounted, and the mountpoint is made immutable while empty for the same
   reason. Content is `iso` only.

6. **Created by hand, then proved, in the order the other passes were.**
   [`build-the-nas.md`](../runbooks/build-the-nas.md) §5b is the procedure:
   the user, the owner, the share, the rule checked from `morpheus`, the
   mount on `Saruman`, then the refusal from another VLAN 30 host. The
   documents describe the rule as specified until that has been done.

## Consequences

- **Anything that can send from `10.0.30.110` can write the ISOs.** NFS with
  `sec=sys` authenticates by address, and both the export and the rule are
  scoped to that address and nothing else. A guest on VLAN 30 that took the
  hypervisor's address could replace an installer, and every template built
  from it afterwards would carry the change. **#440 has to verify each
  ISO's checksum, recorded in the repository, before it builds from it.**
  Packer verifies `iso_checksum` when it downloads an ISO, not when it is
  handed one already in storage, so this needs a step of its own. That is
  the control for this residual. The rule does not provide it.
- **ImaginationLAN can reach CasaBonita on one more port, from one host.**
  `golem`'s pass and this one are the only VLAN 30 sources that can. Nothing
  on 40 initiates, the `igc0.40` tripwire's packet count stays zero, and
  ADR-0016's *Reaches* column does not move.
- **The NFS service runs on `smaug` for two consumers.** Whichever of this
  and ADR-0053 is built first turns it on, NFSv4 only. Neither share is
  reachable until its own pass exists. #523 wanted its `445` rule and this
  one created in one sitting. That did not happen, because `445` was needed
  on 2026-09-23 and this one was not. The sitting that fits now is `golem`'s
  pass and this one, which share an interface and the block they sit above.
- **The ISOs are not backed up, by decision.** Losing `erebor/iso` costs a
  re-download and one Packer run, which is less than any backup of it would.
- **#440 still owns the consumer.** This ADR builds the store and its path.
  Until Packer reads from it, the ISOs already on `Saruman`'s `local` storage
  are the only ones in use, and they move here when #440's first build is
  written against `smaug-iso`.
- **The export and the pass name an address, and `Saruman`'s address is due
  to change.** [`build-the-playground.md`](../runbooks/build-the-playground.md)
  §3 moves it from `10.0.30.110` to `10.0.30.20`. When that happens, the
  share's authorized host and this pass's source move with it, in the same
  sitting as its Alloy pass. That step now lists both. Until then,
  `10.0.30.110` is correct.
- **Only `Saruman` can use the store.** The export and the pass both admit
  one address. A second host, such as `ifrit` at `10.0.30.30`, would need its
  own address added to the share's authorized hosts and its own pass on
  `igc0.30`. That is a decision for when the host exists, not one made here.
- **ADR-0016 is not superseded.** It gains a pointer here, as it did for
  ADR-0050 and ADR-0051, and its table is not edited.
