# Runbook: Build `smaug`, the NAS on CasaBonita

**Target:** `smaug` — the ThinkServer TS150 of
[#413](https://github.com/Gerrrt/HomeLab/issues/413), CasaBonita (VLAN 40), at
`10.0.40.30`
**Time:** §0 is about half an hour and needs no drives. §1–§7 is about twenty
minutes once the drives are in hand.
**You will need:** a console on `smaug` (or its web UI), the pfSense UI on
`morpheus`, a shell on the monitoring host for §0.6, and the two Exos X20
drives for §1 onward.

> **Status — 2026-09-16: §0 is the work that can be done before the drives
> land, and it is the whole of what is blocking.**
>
> The machine is built to the end of its install: TrueNAS 25.10.7 on the Intel
> DC S3520 in the optical bay, booting UEFI, `Configure SATA as [AHCI]`, on
> DHCP at `10.0.40.100`. Its spec is read off the machine rather than off a
> listing and recorded in [`hardware.md`](../hardware.md).
>
> Nothing below §0.3 has been done. The pool does not exist, the address is
> still DHCP, and none of the three firewall rules is created.

This builds what [ADR-0016](../adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
placed and [ADR-0040](../adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)
gave an operating system. Read both before deviating: the address, the rule
positions and the terminal-outward property are decided there, not here.

---

## §0 — Before the drives arrive

Every step here is independent of the drives. Doing it now is what turns
arrival day into §1–§7 rather than an evening.

### §0.1 — Flash the BIOS, or decide not to

`S06KT03R` dated **2017-05-22**, which predates the Spectre and Meltdown
microcode. Lenovo ships DOS, Windows and Linux update utilities for the TS150;
there is no network flash on this machine, because it has no BMC.

**If you flash it, flash it now** — the box is empty, and this is the cheapest
it will ever be. Two things to know:

- **The DOS utility needs `CSM` enabled**, and yours is disabled. Enable it to
  boot the update, then **put it back to disabled** before anything else.
- **A flash resets BIOS settings.** Afterwards, re-check `Configure SATA as
  [AHCI]` and `CSM [Disabled]`. A reset to RAID would put a controller between
  ZFS and the disks; a reset of CSM would leave a UEFI install unbootable.

Deciding *not* to flash is a legitimate answer for a box on a terminal segment
running no untrusted code. It is only a bad answer if taken by forgetting.

### §0.2 — Look at the Management Engine

The boot menu offers `<CTRL-P>` for the Management Engine setup screen. That
means this board carries **Intel AMT**: out-of-band management on its own
ports, running on the chipset, reachable when the OS is off.

`smaug` is about to live on the segment with the televisions, the consoles and
the streaming box. Enter `CTRL-P` and record what state AMT is in. If it is
provisioned, or sitting on a default credential, that is a finding and wants
its own issue — the precedent is
[ADR-0033](../adr/0033-keep-the-ilo-on-the-lab-segment.md), which kept
`Saruman`'s iLO and hardened it deliberately rather than leaving it as shipped.

There is also an `ME_DIS` header on the board if the answer turns out to be
"remove it entirely".

### §0.3 — Give it the static address

In the TrueNAS UI, **Network → Interfaces**, edit the onboard NIC: remove DHCP
and set `10.0.40.30/24`, gateway `10.0.40.1`.

`10.0.40.30` is below the DHCP range, which starts at `.100` — ADR-0016 chose
it for exactly that reason.

> TrueNAS applies network changes on a **test-and-confirm** timer: if you lose
> contact after applying, it rolls back on its own. That is a feature here,
> because you are changing the address you are connected on.

### §0.4 — Reserve it in Kea

On `morpheus`, **Services → DHCP Server → CasaBonita**, add a reservation
mapping the NIC's MAC to `10.0.40.30`.

The MAC is on the machine and in [`hardware.md`](../hardware.md) as an OUI,
`4c:cc:6a:xx:xx:xx` — this repository is public, so the full address lives on
the box and in the firewall, not here.

The static is set on the host and the reservation is set on the server, and
both are done because either alone is a single point of drift.

### §0.5 — Create the three rules, in order and in position

**Position is the whole difficulty.** Two of these sit above a deny that has
been in place since 2025; appended where new rules naturally land they would
match nothing, and *"can I reach the NAS"* would still pass for the wrong
reason.

| On interface | Protocol / source → destination | Position |
| --- | --- | --- |
| Hicks (50) | `tcp` `vlan50 net` → `10.0.40.30` ports `443,8096` | **above** *Block access to CasaBonita* |
| Winterfell (99) | `tcp` `10.0.99.20` → `10.0.40.30` port `9100` | **above** *Block access to CasaBonita* |
| Winterfell (99) | `tcp` `10.0.99.20` → `10.0.40.30` port `22` | **above** *Block access to CasaBonita* |

**The Hicks rule's ports differ from ADR-0016's table, and deliberately.** That
table says `22,8096`, which assumed a box administered over SSH — ADR-0016
decided Ubuntu Server. `smaug` runs TrueNAS, which is administered over HTTPS,
so the admin port is **443** and not 22.
[ADR-0040](../adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)
records the correction; it had originally claimed the rules were untouched by
the operating-system change, and the ports were the part of them that was not.

Port 22 stays on the Winterfell rule, which is `prometheus` pulling the
metadata backup. **TrueNAS ships SSH disabled**, so that rule is inert until
the service is switched on — turn it on when the backup path is actually built,
not before.

**The televisions need no rule at all.** They are on the same broadcast domain
and the firewall never sees the packets. That is the whole of what ADR-0008
bought by putting the server with its clients.

### §0.6 — Prove the rules did what you meant

Two checks, and the second is the one that matters.

From a Hicks workstation, the NAS's UI should answer:

```bash
curl -kIs https://10.0.40.30 | head -1
```

From the monitoring host, which is on Winterfell, `443` should **still be
refused** — that rule is scoped to `10.0.99.20` and to port `9100`, so a
success here would mean the rule is wider than it reads:

```bash
nc -z -w3 10.0.40.30 443 && echo "WRONG: 99 can reach 443" || echo "correct: blocked"
```

Then read **the tripwire counter on `igc0.40`**
([#223](https://github.com/Gerrrt/HomeLab/issues/223)). It matches packets
*originating* on CasaBonita, and the return traffic for a session Hicks opened
is carried by state and never reaches the ruleset. **It must still be zero.**
If it has moved, something on 40 is initiating outward and that is a bigger
finding than anything in this runbook.

---

## §1 — Fit the drives

Power down, unplug, hold the power button five seconds, ground yourself.

Both 3.5" trays are already in the bays and empty. Screw a drive into each,
slide them home, and cable them to **`SATA2`** and **`SATA3`** — the boot disk
is on `SATA5`, inherited from the optical drive it replaced, and `SATA0`/`SATA1`
stay free.

**Do not disturb the bay fan on `AUX1_FAN`.** It is the airflow over these two
drives, and two 7200 rpm Exos under a scrub will want it.

## §2 — Read the drives before trusting them

From **option 8, Open Linux Shell**, or over SSH once enabled:

```bash
lsblk
```

The two new 18 TB devices will be `/dev/sdb` and `/dev/sdc` or similar — the
S3520 is the 223.6 G one. Then, for each:

```bash
smartctl -a /dev/sdX
```

**The listing's "zero power-on hours" is a claim, not a fact**, and this is the
moment it becomes one or the other. Record for each drive:

- `Serial Number` — it goes in [`hardware.md`](../hardware.md)
- `Power_On_Hours` — against the claim
- `Reallocated_Sector_Ct` and `Current_Pending_Sector` — both should be 0
- `SMART overall-health self-assessment` — `PASSED`

> A drive with hours on it is not automatically bad, but it is not what was
> paid for. Decide before it is in a pool, not after.

Then start the baseline on both, because an 18 TB extended test is hours and
you want it running while you do the rest:

```bash
smartctl -t long /dev/sdb
smartctl -t long /dev/sdc
```

## §3 — Create the mirror

**Storage → Create Pool.**

| Setting | Value |
| --- | --- |
| Name | `erebor` |
| Layout | **Mirror** |
| Disks | the two Exos X20 |

**A mirror of two is one drive's capacity — 18 TB usable, not 36.** ADR-0016
chose availability, not capacity: a dead disk becomes a drive swap instead of a
re-acquisition weekend.

The boot disk is **not** part of this pool and must not be added to it. TrueNAS
keeps its boot pool separate by design, which is the arrangement the S3520 in
the optical bay exists for.

## §4 — Datasets

**Storage → `erebor` → Add Dataset.** Two of them, and the split is the backup
decision made deliberately rather than drifted into.

| Dataset | Record size | atime | What it holds | Backed up |
| --- | --- | --- | --- | --- |
| `erebor/media` | `1M` | off | films, music, the library | **no** |
| `erebor/apps` | default | off | Jellyfin's database and config | **yes** |

**Why the split.** ADR-0008 already ruled the library replaceable — its loss is
*"annoying rather than catastrophic"* — and backing up 18 TB of re-downloadable
files would contradict a decision already taken while spending the mirror's
capacity. But **the metadata is not replaceable**: watch history, resume
positions, accounts, and how the library is organised. Re-acquiring a series
does not restore which episode you were on, and that is measured in megabytes.

`1M` records on `erebor/media` because it holds large sequential files;
compression stays on and costs nothing on already-compressed media.

## §5 — The household share

**Shares → Windows (SMB) → Add**, pointed at `erebor/media`.

Create a dedicated TrueNAS user for it rather than sharing the admin account.
The admin credential is the one that guards everything on this box, and an SMB
share is mounted by televisions.

## §6 — Jellyfin

Deploy the stack from the repository, per
[ADR-0040](../adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md):
a compose file this repository owns, run under TrueNAS's app runtime, **not** a
catalogue app. That is what keeps Dependabot, the digest pins and
`make validate` reaching it.

Jellyfin binds `8096`, reads `erebor/media`, and writes its state to
`erebor/apps`.

> **The check ADR-0040 named as its reopen condition belongs here.** Confirm
> the iGPU reaches the container:
>
> ```bash
> ls -l /dev/dri
> ```
>
> and that Jellyfin's playback settings offer **QSV** hardware transcoding. The
> CPU half is already confirmed — `Active Video: IGD` on an E3-1225 v6 — but a
> live P630 and a P630 a container can use are different claims.
>
> If it does not pass, decision 2 of ADR-0040 reopens: catalogue apps that
> manage the passthrough, or the media stack moves off this host. **Check it
> before the library exists**, because moving a populated library is a weekend.

## §7 — Verify

- A television on CasaBonita finds Jellyfin and plays something **without** any
  firewall rule being involved
- A Hicks workstation reaches `https://10.0.40.30` and `http://10.0.40.30:8096`
- The monitoring host reaches `9100` and **nothing else**
- The `igc0.40` tripwire counter is **still zero**
- `zpool status erebor` is `ONLINE` with no errors
- Both Exos self-tests from §2 completed without error

## §8 — What this leaves open

- **[#256](https://github.com/Gerrrt/HomeLab/issues/256), the scrape path.** It
  specifies `node_exporter` on `9100`, and TrueNAS ships its own metrics
  endpoint — so the target shape is a fork that issue now has to settle.
- **[#255](https://github.com/Gerrrt/HomeLab/issues/255)**, the residual saying
  this host ships no logs, which is true the day it exists.
- **[ADR-0027](../adr/0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md)'s
  PBS**, whose sync job wants another PBS instance — on TrueNAS that is PBS in
  a VM or a change to an NFS/SMB datastore.
- **The off-host copy of `erebor/apps`**, which §4 decided should exist and this
  runbook does not build.
- **Plex**, deferred by ADR-0016 against a test nobody has run: whether any
  screen on 40 lacks a working Jellyfin client.
