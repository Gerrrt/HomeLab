# Runbook: Build `smaug`, the NAS on CasaBonita

**Target:** `smaug` — the ThinkServer TS150 of
[#413](https://github.com/Gerrrt/HomeLab/issues/413), CasaBonita (VLAN 40), at
`10.0.40.30`
**Time:** §0 is about half an hour and needs no drives. §1–§7 is about twenty
minutes once the drives are in hand.
**You will need:** a console on `smaug` — its web UI cannot run §2 or §6, and
SSH is off until §6.2 turns it on for the backup pull and nothing else —
`neo`'s web UI at `http://10.7.7.2` and a yellow Cat6 lead for
§0.2b, the pfSense UI on `morpheus`, a shell on the monitoring host for §0.6,
and the two Exos X20 drives for §1 onward.

> **Status — 2026-09-19: the drives are in, the pool exists, the stack is
> deployed and the scrape is on.** The Exos pair landed on 2026-09-18, a day
> after the carrier's window lapsed, and §1–§6 were done that evening and the
> next morning. Both drives read **0 power-on hours in the FARM log** as well
> as in SMART, which is the reading that settles the listing's claim (§2).
> `erebor` is a mirror with encryption off by decision (§3); `erebor/media`
> and `erebor/apps` exist (§4); the share is `media` and its user is `bilbo`
> (§5); the stack runs from `/mnt/erebor/apps/stack` under TrueNAS's Docker,
> and **§6 as previously written could not run on this box** — it is rewritten
> below. `node_exporter` answered the three §6.1 checks from the monitoring
> host and the target in `targets/node.yaml` is live. Inside the container the
> render node is present and the process carries GID 107 — the two halves of
> ADR-0040's condition that a shell can check. **By the evening of 2026-09-19
> the transcode had passed, a television had played something, and the
> tripwire and port 15 were re-read** (§6.1, §7). **Both extended self-tests
> completed without error**, read at the console on 2026-09-20 at lifetime
> hours 25 and 26 (§7). **Every line of §7 is read, and
> [#413](https://github.com/Gerrrt/HomeLab/issues/413) closed on the last
> of them.** What this runbook leaves open is §8, and each item there has an
> issue of its own.
>
> **Status — 2026-09-16: §0 is the work that can be done before the drives
> land, and it is the whole of what is blocking.**
>
> The machine is built to the end of its install: TrueNAS 25.10.7 on the Intel
> DC S3520 in the optical bay, booting UEFI, `Configure SATA as [AHCI]`, on
> DHCP at `10.0.40.100`. Its spec is read off the machine rather than off a
> listing and recorded in [`hardware.md`](../hardware.md).
>
> **§0 is complete as of 2026-09-16.** BIOS flashed (§0.1), AMT found on its
> factory-default credential and disabled (§0.2), the switch port moved into
> CasaBonita untagged (§0.2b), the static set (§0.3), the reservation added
> (§0.4), and the rules created as four host- and port-scoped passes rather
> than three (§0.5) — `443,8096` from Hicks split into two rules, `9100` and
> `22` from `10.0.99.20`.
>
> **§0.2b is the one step here with no date of its own.** It was added after the
> fact by [#481](https://github.com/Gerrrt/HomeLab/issues/481), which is why it
> records a reading rather than a day's work.
>
> §0.6 verified from `morpheus` rather than from the UI: every pass sits above
> *Block access to CasaBonita* on its interface, Winterfell is still correctly
> refused on `443`, and the `igc0.40` tripwire matched **zero packets**.
>
> **No rule numbers are recorded here, and that is deliberate.** This block
> first carried them — 167–168 before 169 on `igc0.99`, 194–195 before 196 on
> `igc0.50`. Those are right for `pfctl -sr | grep -n` and wrong for
> `pfctl -sr -vv`, which on 2026-09-17 numbered the same four rules `@148`,
> `@149`, `@175` and `@176`. Both readings came off the live ruleset in one
> invocation: `-vv` numbers each ruleset from zero, `grep -n` counts output
> lines, and the two therefore disagree by however many `scrub` rules precede
> the filter set. **The command §0.6 needs is the one the numbers do not
> match**, because a tripwire check reads a counter and counters only come
> from `-vv`. So match on the rule descriptions, which do not depend on how
> the ruleset is being printed.
>
> What was left on 2026-09-16 was the drives. They landed two days later.

This builds what [ADR-0016](../adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
placed and [ADR-0040](../adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)
gave an operating system. Read both before deviating: the address, the rule
positions and the terminal-outward property are decided there, not here.

---

## §0 — Before the drives arrive

Every step here is independent of the drives. Doing it now is what turns
arrival day into §1–§7 rather than an evening.

### §0.1 — Flash the BIOS, or decide not to

> **Done 2026-09-16.** `S06KT03R` (2017-05-22) → **`S06KT81L` (2024-02-05)**,
> boot block `1.03` → `1.81`, by the DOS utility from a FreeDOS stick. `CSM`
> and `AHCI` were both re-checked afterwards and both survived; so did the
> machine type-model, the serial, the MAC and the clock. The embedded
> controller still reads `S06CT01A` — see [`hardware.md`](../hardware.md). The
> section below is kept for the next machine, and for the next time this one
> needs it.

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

### §0.2b — Move its switch port to CasaBonita

> **Done, and the only step in §0 without a date.** Read off the switch on
> 2026-09-17: `smaug` is on **port 15 of `neo`**, whose PVID is **40**, untagged
> only, with `smaug`'s MAC learned on it in VLAN 40 and the link up at **1000M
> full** — the fastest thing answering on CasaBonita when it was read, which is
> what identifies the port. The move itself was never recorded. The map was last
> read on 2026-09-04 with port 15 still ImaginationLAN's and matching the
> documented map exactly, so it happened between that day and this one, and the
> install on 2026-09-16 is the obvious occasion — an inference, not a reading.
> The section below is kept for the next machine, and for the next time this one
> is re-cabled.
>
> **Port 15 is a fact about the MokerLink, not about `neo`.** The CRS326 bought
> under [#444](https://github.com/Gerrrt/HomeLab/issues/444) inherits both the
> name and `10.7.7.2`
> ([ADR-0041](../adr/0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md)
> decision 2), so `neo` still answers on this address after the swap while its
> port numbering does not carry over. §1.1 of
> [`swap-the-switch.md`](swap-the-switch.md) captures the map on the way past,
> and is where this number is re-read rather than assumed.

In `neo`'s web UI at `http://10.7.7.2`, add the port to CasaBonita's untagged
members in the static VLAN table, take it out of ImaginationLAN's, and set its
**PVID to 40**. What you are making is a **Yellow access port, untagged VLAN 40
— no trunk, no tagged port**, the same shape
[`build-the-playground.md`](build-the-playground.md) asks for in Green on the
lab segment. The UI is plain HTTP, and that is decided rather than outstanding
([ADR-0018](../adr/0018-name-the-switch-and-leave-its-ui-on-plain-http.md)).

**Read both tables back after saving.** Membership and PVID are set in separate
places on this firmware, and a port with the right membership and a stale PVID
is the failure below wearing a working port's clothes.

Not **port 1**, which is the trunk to `morpheus`, and not **port 3**, which
feeds the unmanaged shelf switch that `prometheus` and `oracle` hang off.

**Then re-patch it yellow.** CasaBonita is the yellow cable and ImaginationLAN
the green one
([ADR-0009](../adr/0009-colour-vlans-by-cable-not-by-trust.md)), so a port taken
from the lab segment still has a green cable in it. That ADR makes colour
evidence rather than decoration, and a green cable in a CasaBonita port is
exactly what destroys it.

**This comes before §0.3, and the order is not cosmetic.** §0.3 sets a static on
`10.0.40.0/24`, and TrueNAS applies it on a test-and-confirm timer: on a port
still carrying VLAN 30 that static loses contact the moment it is applied and
rolls itself back. If it somehow sticks, the result is worse — a machine on the
lab segment holding a media-segment address, which no inbound rule reaches, so
*"can I reach the NAS"* fails in a way **indistinguishable from a firewall
fault**. §0.5 warns about the mirror image of that, a rule appended where it
matches nothing and leaves the question passing for the wrong reason; this one
leaves it failing for the wrong reason, and sends you to the pfSense UI, where
the answer is not.

**It is lettered rather than renumbered, and it has to stay that way.**
Shifting §0.3 onward to make room would move §0.5, and **ADR-0016 and ADR-0040
both cite §0.5 by name** — ADRs are immutable (ADR-0001), so renumbering would
break the only pointer two settled decisions have at the rule table.

**Write the port number down**, which is what this section is for. §0.3 and
§0.4 hold the address twice because either alone is a single point of drift; a
port that nothing records is worse than either, because a successor re-cabling
this machine has nothing to re-cable it to. Only this machine's own port belongs
here — the full map is the wiki's `infrastructure/switching` page and stays
there, because
[ADR-0026](../adr/0026-check-the-documents-where-the-truth-is.md) keeps facts
where they are checked rather than copying them somewhere nothing checks them.

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

### §0.5 — Create the four rules, in order and in position

**Position is the whole difficulty.** All four sit above a deny that has been
in place since 2025; appended where new rules naturally land they would match
nothing, and *"can I reach the NAS"* would still pass for the wrong reason.

| On interface | Protocol / source → destination | Description | Position |
| --- | --- | --- | --- |
| Hicks (50) | `tcp` `vlan50 net` → `10.0.40.30` port `443` | `Allow HTTPS to smaug` | **above** *Block access to CasaBonita* |
| Hicks (50) | `tcp` `vlan50 net` → `10.0.40.30` port `8096` | `Allow 8096 to smaug` | **above** *Block access to CasaBonita* |
| Winterfell (99) | `tcp` `10.0.99.20` → `10.0.40.30` port `9100` | `Allow 9100 to smaug` | **above** *Block access to CasaBonita* |
| Winterfell (99) | `tcp` `10.0.99.20` → `10.0.40.30` port `22` | `Allow SSH to smaug` | **above** *Block access to CasaBonita* |

**Four, where [ADR-0016](../adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
wrote three.** The Hicks pass is one rule per port rather than one rule
carrying a port list — functionally identical, and worth the extra row because
the description is what §0.6 matches on and a description naming one port is
unambiguous about which rule answered. **Set these descriptions exactly**; they
are load-bearing in the next section, not decoration.

**The Hicks rule's ports differ from ADR-0016's table, and deliberately.** That
table says `22,8096`, which assumed a box administered over SSH — ADR-0016
decided Ubuntu Server. `smaug` runs TrueNAS, which is administered over HTTPS,
so the admin port is **443** and not 22.
[ADR-0040](../adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)
records the correction; it had originally claimed the rules were untouched by
the operating-system change, and the ports were the part of them that was not.

Port 22 stays on the Winterfell rule, which is `prometheus` pulling the
metadata backup. **TrueNAS ships SSH disabled**, so that rule was inert from
2026-09-16 until 2026-09-19, when **§6.2 switched the service on** — with the
pull built, bench-tested and its user created first, per
[ADR-0045](../adr/0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md). Not
before, and not for administration.

**The televisions need no rule at all.** They are on the same broadcast domain
and the firewall never sees the packets. That is the whole of what ADR-0008
bought by putting the server with its clients.

### §0.6 — Prove the rules did what you meant

**Do this from `morpheus` and from the monitoring host, not from the pfSense
UI.** An appended rule matches nothing while looking perfectly present in the
UI, and that is the failure this whole section exists to catch.

**First, position — the check the other three assume.** On `morpheus`:

```bash
pfctl -sr -vv \
  | grep -E 'on igc0\.(99|50) ' \
  | grep -E 'descr=(Allow .* to smaug|Block access to CasaBonita)'
```

Each pass must appear **above** the *Block access to CasaBonita* rule on its
own interface: `Allow 9100`/`Allow SSH` before the block on `igc0.99`, and
`Allow HTTPS`/`Allow 8096` before it on `igc0.50`. **Read the order, not the
numbers.** `-vv` numbers each ruleset from zero rather than counting output
lines, so its `@` indices match neither `pfctl -sr | grep -n` nor anything
written down here — they are a printing artefact, and only the sequence is a
fact about the firewall.

From a Hicks workstation, the NAS's UI should answer:

```bash
curl -kIs https://10.0.40.30 | head -1
```

From the monitoring host, which is on Winterfell, `443` should **still be
refused** — the two Winterfell rules are scoped to `10.0.99.20` and to ports
`9100` and `22`, so a success here would mean one of them is wider than it
reads:

```bash
nc -z -w3 10.0.40.30 443 && echo "WRONG: 99 can reach 443" || echo "correct: blocked"
```

Then read **the tripwire counter on `igc0.40`**
([#223](https://github.com/Gerrrt/HomeLab/issues/223)). It matches packets
*originating* on CasaBonita, and the return traffic for a session Hicks opened
is carried by state and never reaches the ruleset. **Its packet count must
still be zero.** The evaluation counter beside it climbs constantly and means
nothing — it is every packet the rule was tested against. If *packets* have
moved, something on 40 is initiating outward and that is a bigger finding than
anything in this runbook.

---

## §1 — Fit the drives

> **Done 2026-09-18.** Both trays, `SATA2` and `SATA3`, the bay fan left
> alone. **The power lead had four wires and no orange one**, so the pin-3
> trap below did not fire on this supply; both drives spun up and appeared in
> `lsblk` first time.

Power down, unplug, hold the power button five seconds, ground yourself.

Both 3.5" trays are already in the bays and empty. Screw a drive into each,
slide them home, and cable them to **`SATA2`** and **`SATA3`** — the boot disk
is on `SATA5`, inherited from the optical drive it replaced, and `SATA0`/`SATA1`
stay free.

**Do not disturb the bay fan on `AUX1_FAN`.** It is the airflow over these two
drives, and two 7200 rpm Exos under a scrub will want it.

**Look at the power lead before the case closes.** The Exos, like every
enterprise SATA drive since about 2016, reads **pin 3 of its power connector as
Power Disable**: a supply that puts 3.3 V on that pin holds the drive off, so it
never spins and never appears in `lsblk`. A desktop supply's SATA lead with
**five wires, one of them orange**, carries that 3.3 V; four wires and no orange
does not. If the orange wire is there, put Kapton tape over pin 3 on each
drive's power receptacle, or feed the bays through a Molex-to-SATA adapter,
which has no 3.3 V to offer. The boot disk booting proves nothing here — the
S3520 predates the feature and ignores the pin. A drive missing from §2's
`lsblk` is this before it is a cable or a port.

The connectors themselves are ordinary SATA, and it is worth saying because
the drive held PCB-up does not look like it: the wide receptacle is the 15-pin
power, the narrow one the 7-pin data, and the small four-pin block beside them
is Seagate's jumper header, which stays empty.

## §2 — Read the drives before trusting them

> **Done 2026-09-18.** `sda` was `ZVTBS4NL` and `sdb` was `ZVTBSDL3`, both
> `PASSED`, 0 reallocated, 0 pending, 0 power-on hours by SMART — and, the
> reading this section did not know to ask for, **0 power-on hours and 0
> spindle hours by `smartctl -l farm`** on both. Seagate's FARM log keeps an
> hours counter that a SMART reset does not touch, and it is what caught the
> used Exos drives sold as new through 2025; the `smartctl` on TrueNAS 25.10
> reads it. Run it, and treat SMART's zero as a claim until it agrees.
> `ZVTBSDL3` arrived carrying a Windows quick format — a 16 MB reserved
> partition and an NTFS volume labelled `New Volume` — with about 370 MB
> written and one short self-test at hour 0, which is a seller's bench check
> and nothing more; the pool creation wiped it. Extended tests started on
> both the same evening, at about 28 hours each, and **both completed without
> error** — read on 2026-09-20 at lifetime hours 25 (`sda`) and 26 (`sdb`),
> no LBA of first error on either. Full readings are in
> [`hardware.md`](../hardware.md).

From **option 8, Open Linux Shell**, at the console — **not over SSH**.
TrueNAS ships SSH disabled, and on the day this ran §0.5's port-22 pass was
inert. Enabling it here to save a walk to the machine would have widened this
host's attack surface for the sake of five commands; §6.2's backup pull was
the reason to turn it on, on 2026-09-19, and this was not it. The service
now answers one key-only user, `frodo`, who can read a snapshot and nothing
else — still not a way to administer the box.

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

> **Done 2026-09-18.** Mirror of the two Exos, encryption unchecked, with the
> extended self-tests still running underneath it. `zpool status erebor` on
> 2026-09-19: `ONLINE`, one `mirror-0` of two members, 0 read, 0 write, 0
> checksum errors, no known data errors.

**Storage → Create Pool.**

| Setting | Value |
| --- | --- |
| Name | `erebor` |
| Layout | **Mirror** |
| Disks | the two Exos X20 |
| Encryption | **off** |

**Encryption is off by decision, not by default.** ADR-0008 ruled the library
replaceable and `erebor/apps` is watch history; encryption at rest is what the
sensitive tier gets, and nothing asks it of this one. Both key modes cost
something here: a key file auto-unlocks from a boot pool that lives on a used
SSD with reallocated sectors, and a passphrase leaves the pool locked after
every reboot on a box whose remote console was disabled on purpose (§0.2).
Either is a new secret with a handover obligation, guarding films. ZFS
encryption is per dataset, so a future dataset that holds something that
matters can be created encrypted on this plain pool; pool-level encryption
cannot be removed later without a rebuild. Saying no keeps the option.

**A mirror of two is one drive's capacity — 18 TB usable, not 36.** ADR-0016
chose availability, not capacity: a dead disk becomes a drive swap instead of a
re-acquisition weekend.

The boot disk is **not** part of this pool and must not be added to it. TrueNAS
keeps its boot pool separate by design, which is the arrangement the S3520 in
the optical bay exists for.

## §4 — Datasets

> **Done 2026-09-18.** `erebor/media` on the **SMB** preset — case-insensitive
> with NFSv4 ACLs, which is what televisions and Windows clients expect and
> cannot be changed after creation — and `erebor/apps` on the **Apps** preset.
> The Add Dataset dialog calls these *Dataset Presets*; the record size and
> atime are under its advanced options.
>
> **The row that says "backed up" became true on 2026-09-20.** As deployed
> on 2026-09-19, Jellyfin's `/config` was a Docker named volume, and TrueNAS
> keeps named volumes on the pool it was given for Apps, in a dataset of its
> own — `erebor/ix-apps/docker`, not `erebor/apps`. So `erebor/apps` held the
> compose file and its `.env` (§6) and nothing Jellyfin writes
> ([#484](https://github.com/Gerrrt/HomeLab/issues/484)).
> [ADR-0045](../adr/0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md)
> settled it: `/config` is a **bind mount** at
> `/mnt/erebor/apps/jellyfin/config` (§6 migrated the state that already
> existed), this dataset has the nightly snapshot task in §4.1, and the
> monitoring host pulled the newest snapshot's copy over the port-22 rule
> for the first time on 2026-09-20 — §6.2's Done block has the set.

**Storage → `erebor` → Add Dataset.** Two of them, and the split is the backup
decision made deliberately rather than drifted into.

| Dataset | Record size | atime | What it holds | Backed up |
| --- | --- | --- | --- | --- |
| `erebor/media` | `1M` | off | films, music, the library | **no** |
| `erebor/apps` | default | off | the compose files, and Jellyfin's `/config` as a bind mount | **yes** — §4.1 and §6.2 |

**Why the split.** ADR-0008 already ruled the library replaceable — its loss is
*"annoying rather than catastrophic"* — and backing up 18 TB of re-downloadable
files would contradict a decision already taken while spending the mirror's
capacity. But **the metadata is not replaceable**: watch history, resume
positions, accounts, and how the library is organised. Re-acquiring a series
does not restore which episode you were on, and that is measured in megabytes.

`1M` records on `erebor/media` because it holds large sequential files;
compression stays on and costs nothing on already-compressed media.

### §4.1 — Snapshot `erebor/apps` nightly

This is the quiesce for the backup, and the first entry in the snapshot
schedule ADR-0040's fourth decision said would be written down as it was
created. Jellyfin keeps its state in SQLite, and a copy of a live SQLite
database is a file that looks like a backup; the estate's other backups stop
the service to get a consistent one. Stopping Jellyfin from the monitoring
host would need the Docker socket here, which is root, for a user whose whole
design is that it reads one directory. A ZFS snapshot is atomic across the
dataset instead — the database, its write-ahead log and its shared-memory
file are frozen at one instant — and `scripts/backup-nas.sh` reads the newest
one through `.zfs/snapshot/`. Jellyfin never stops.

**Data Protection → Periodic Snapshot Tasks → Add**, and every setting below
is load-bearing for the script, not a preference:

| Setting | Value | Why the script depends on it |
| --- | --- | --- |
| Dataset | `erebor/apps` | The bind mount in §6 is a directory on it, not a child dataset, so this is enough |
| Recursive | **off** | One thing beneath it is a dataset, and the pull needs nothing in it. `erebor/apps/home` is `frodo`'s home directory — TrueNAS made it a child dataset when §6.2 step 1 created the user, at 21:53 on 2026-09-19 — and it holds that user's shell files and authorized key, nothing Jellyfin writes. `jellyfin/config` is a directory on `erebor/apps` itself, so a non-recursive snapshot freezes all of it. Recursive on would be harmless and buy nothing: the script reads one dataset's `.zfs/snapshot/`, and a child's snapshot is not visible there |
| Naming schema | `auto-%Y-%m-%d_%H-%M` | The default. The script accepts only names of this shape, and reads the snapshot's age out of the name — in this host's zone, which is why §6.2 records that zone |
| Schedule | daily, `03:00` | The pull runs weekly and fails if the newest snapshot is older than **two days**, twice the period; a daily task tolerates one missed night |
| Lifetime | 2 weeks | Local rollback history; the off-host copy is the backup |
| Allow Taking Empty Snapshots | **on** | Off, a night with no writes produces no snapshot and the pull fails for a reason that is not a fault |

Then record the host's timezone here from **System → General**, because the
snapshot names are in it and the monitoring host is in UTC: `NAS_SNAPSHOT_TZ`
in `scripts/backup-nas.sh` defaults to **`America/Los_Angeles`**, and if the
host is ever set to another zone, the override goes in
`/etc/default/homelab-timers` on the monitoring host.

Check it the next day, from the console shell: the newest name under
`/mnt/erebor/apps/.zfs/snapshot/` is this morning's. The directory is hidden
from `ls /mnt/erebor/apps` and reachable by path regardless; `snapdir` is
left at its default.

```bash
ls -1 /mnt/erebor/apps/.zfs/snapshot/
```

> **Done 2026-09-19, 23:00 PDT.** Created with every value in the table and
> run once by hand from the task's menu rather than waiting for 03:00, which
> produced `auto-2026-09-19_23-00` — the name the pull in §6.2 read minutes
> later. The host's zone is **`America/Los_Angeles`** (System → General;
> `date` on the box prints PDT while `/etc/timezone` says UTC, because
> TrueNAS keeps the zone in its own config, so read it from the UI and not
> from that file). §6.2 step 5's cross-check agreed to the second:
> `zfs get -Hp creation` on the snapshot and the script's parse of its name
> both gave `1789884000`. Recursive is off for the reason the table now
> states, not the one it used to.

## §5 — The household share

> **Done 2026-09-18.** The share is **`media`**, reached as
> `\\10.0.40.30\media`, created from the dataset dialog's *Create SMB Share*
> box rather than from the Shares page — same result. The user is **`bilbo`**:
> SMB on, and TrueNAS access, shell, SSH and sudo all off, so the credential
> that lives on televisions can mount one share and do nothing else anywhere.
> It needed no ACL entry of its own: an SMB user joins `builtin_users` on
> creation, and the SMB preset's default ACL already grants that group
> Modify, so `bilbo` reads and writes. What the ACL was missing was
> **Jellyfin's** read path — the container reads the library as uid 65534,
> which is nobody's group and not `builtin_users` — so one entry was added:
> `everyone@`, Allow, Basic Read, Inherit. The list now has five entries, the
> four the preset wrote and that one.
>
> **No workstation can mount this share, and that was found by trying.** The
> Hicks rules from §0.5 pass `443` and `8096` to `smaug` and nothing else;
> SMB is `445`, so a Hicks machine that reaches the TrueNAS UI and Jellyfin
> gets nothing from `\\10.0.40.30\media`. Only devices already on
> CasaBonita can mount it, and those are televisions. Getting a film onto the
> library today means the console shell — `mkdir` and `curl` under
> `/mnt/erebor/media/` — which is how the test clip in §6.1 arrived. Whether
> the answer is a fifth Hicks rule on `445` or something else is
> [#523](https://github.com/Gerrrt/HomeLab/issues/523)'s; it is recorded
> here because the share exists and looks usable and is not.

**Shares → Windows (SMB) → Add**, pointed at `erebor/media`.

Create a dedicated TrueNAS user for it rather than sharing the admin account.
The admin credential is the one that guards everything on this box, and an SMB
share is mounted by televisions.

## §6 — The stack, and the scrape

Deploy the stack from the repository, per
[ADR-0040](../adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md):
a compose file this repository owns, run under TrueNAS's app runtime, **not** a
catalogue app. That is what keeps Dependabot, the digest pins and
`make validate` reaching it.

> **Done 2026-09-19, and not the way this section said.** It read
> `make up STACK=media` until then. That target renders config first, the
> render decrypts `secrets/<stack>.sops.yaml`, and this stack has no secrets
> file because it needs no secrets — so the render dies on the missing file,
> on a box that ships neither `make` nor `sops` in any case. What `make up`
> does underneath is `docker compose up`, and that is what runs here. The
> steps below are what was done.

**First, give Apps a pool.** Docker does not exist on TrueNAS until it has
one: **Apps → Configuration → Choose Pool → `erebor`**, and wait for Apps to
report running. That creates `erebor/ix-apps`, where Docker's images and named
volumes live from then on.

**Then fetch the two files the stack is.** The repository is public and this
host has egress, so they come straight from `main`. The `.env` is copied
as-is, because every value in it is a plain host fact:

```bash
mkdir -p /mnt/erebor/apps/stack && cd /mnt/erebor/apps/stack \
  && curl -fsSLO https://raw.githubusercontent.com/Gerrrt/HomeLab/main/stacks/media/compose.yaml \
  && curl -fsSL  https://raw.githubusercontent.com/Gerrrt/HomeLab/main/stacks/media/.env.example -o .env
```

The folder is under `erebor/apps` because that is the dataset §4 set aside
for application state; its name is arbitrary, since the compose file sets its
own project name. **Do not call it `media`** — that is the library's name one
level up, and the collision confused the first person to do this.

**Then create the directory Jellyfin's state lives in.** `.env` names it as
`JELLYFIN_CONFIG_PATH`, and it is a bind mount on this dataset rather than a
named volume, for the reason §4's status block gives. A bind mount does not
inherit the image's world-writable `/config` the way a fresh volume does, and
Jellyfin runs as `65534`, so the directory has to exist and be owned before
the first `up`:

```bash
mkdir -p /mnt/erebor/apps/jellyfin/config \
  && chown 65534:65534 /mnt/erebor/apps/jellyfin/config \
  && chmod 755 /mnt/erebor/apps/jellyfin/config
```

> **Migrating the state that already exists.** The stack ran from 2026-09-19
> with `/config` as a named volume, so on this host the directory above is
> not empty on first use — it is filled from the volume, with Jellyfin
> stopped, before the compose file that names it is applied. As root, from
> the stack directory:
>
> ```bash
> docker compose stop jellyfin \
>   && src="$(docker volume inspect media_jellyfin-config --format '{{.Mountpoint}}')" \
>   && cp -a "$src/." /mnt/erebor/apps/jellyfin/config/ \
>   && chown -R 65534:65534 /mnt/erebor/apps/jellyfin/config
> ```
>
> The mountpoint is asked for rather than written down, because where TrueNAS
> keeps its volumes is its business. Then re-fetch the two files (the `curl`
> lines above), `docker compose up -d`, and prove the state came across
> before anything is removed: the users and the watch history are there in
> the web UI, and `docker exec media-jellyfin ls /config/data` lists
> `jellyfin.db`. Only then remove the orphan — compose will warn about it on
> every `up` until you do, and that warning is the reminder, not a fault:
>
> ```bash
> docker volume rm media_jellyfin-config
> ```
>
> **Not yet done** as of the day this block was written; the date goes here.

Confirm `RENDER_GID` still matches what this host reports — it is hard-coded
in `.env`, and `107 render` was re-read on 2026-09-19 — then bring it up:

```bash
stat -c '%g %G' /dev/dri/renderD128
docker compose up -d && docker compose ps
```

Jellyfin binds `8096` and reads `erebor/media`. `node-exporter` binds `9100`
and is the whole of how this host is monitored — see §6.1. Jellyfin's state
is the bind mount above, on `erebor/apps`, which is what §4.1 snapshots and
§6.2 pulls; its cache is a named volume on `erebor/ix-apps`, and is not
backed up by anything, by decision.

**Updating the stack is the same two `curl` lines and `docker compose up -d`
again.** Nothing on this host pulls from `main` on its own: there is no
converge timer here, so a Dependabot bump that merges is not deployed until
someone does this. That is a residual of ADR-0040's shape and not a defect in
it, and it wants a line in `stacks/media/README.md` rather than an issue until
it bites.

### §6.1 — Turn the scrape on, and prove it before you do

The `node-exporter` service comes up with the stack. Nothing was scraping it
until now: [#256](https://github.com/Gerrrt/HomeLab/issues/256) wrote the `node`
job and `prometheus/targets/node.yaml` with **the target commented out**,
because a scrape aimed at a port with nothing behind it means `up == 0` and
`InstanceDown` paging `urgent` every four hours until the drives arrive —
[ADR-0017](../adr/0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)'s refusal.

From the monitoring host, which can reach `9100` and nothing else on this
segment:

```bash
curl -s http://10.0.40.30:9100/metrics | grep -c '^node_filesystem_avail_bytes'
```

**It must be greater than zero, and it must count `erebor`.** A wrong
`--path.rootfs` produces a container's filesystems, or none, while `up` still
reads 1 and the target shows green — so a zero here means every disk rule on
this host is blind and nothing else will tell you.

Then uncomment the four lines at the end of `prometheus/targets/node.yaml` and
commit. That directory is a bind mount, so Prometheus re-reads it within five
minutes: no restart, no deploy, no `--force-recreate`.

> **Done 2026-09-19.** From the monitoring host: `9100` open, `443` and
> `8096` refused, `node_uname_info` and `node_boot_time_seconds` present,
> **36** `node_filesystem_avail_bytes` series including `erebor`,
> `erebor/media` and `erebor/apps`, and **0** `node_network_*` series. The
> target was uncommented the same morning. Inside the container:
> `renderD128` listed as `root 107` and `id` read
> `uid=65534(nobody) gid=65534(nogroup) groups=65534(nogroup),107` — both
> halves of the check below that a shell can make. **The transcode passed
> the same day**, read off the ffmpeg command line Jellyfin logged rather
> than off the dashboard, which hides the answer behind a hover: libva
> opened the `iHD` driver, the input was decoded with `-hwaccel vaapi`,
> scaled on the GPU with `scale_vaapi`, and encoded by **`h264_qsv`** —
> 300 frames of 1080p to 540p in 0.76 s, about five times real time, on a
> 10-second Big Buck Bunny clip played at a forced 480p. **ADR-0040's
> reopen condition is closed and decision 2 stands.** The log is
> `/config/log/FFmpeg.Transcode-*.log` inside the container; `docker top
> media-jellyfin` shows the same line while a stream is running.

Expect **no** `node_network_*` series from this host. Those collectors are
disabled on purpose, because a bridged container reads its own veth and would
chart it as this NAS's throughput; `stacks/media/compose.yaml` carries the
measurement.

> **The check ADR-0040 named as its reopen condition belongs here, and it has
> to run *inside* the container.** The host half is already settled —
> `Active Video: IGD` on an E3-1225 v6, and render node `107 render` read off
> this machine on 2026-09-16. Running `ls -l /dev/dri` on the host re-confirms
> the half that was never in doubt and says nothing about the condition, which
> is whether the device reaches a container:
>
> ```bash
> docker exec media-jellyfin ls -l /dev/dri
> ```
>
> The node has to be present **and** the container's supplementary groups have
> to include the render GID — which is what `group_add` in the compose file is
> there to do, and the thing most likely to be silently wrong:
>
> ```bash
> docker exec media-jellyfin id
> ```
>
> Then check that Jellyfin's playback settings offer **QSV** hardware
> transcoding, and transcode something with it. A device node a container can
> list and a device node it can *use* are still different claims.
>
> If it does not pass, decision 2 of ADR-0040 reopens: catalogue apps that
> manage the passthrough, or the media stack moves off this host. **Check it
> before the library exists**, because moving a populated library is a weekend.

### §6.2 — Turn the backup pull on

This is the step §0.5 deferred: the port-22 pass has existed since
2026-09-16 and matched nothing, because TrueNAS ships SSH disabled and
nothing was built to use it. [ADR-0045](../adr/0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md)
is the decision and `scripts/backup-nas.sh` is the mechanism: the monitoring
host logs in as one unprivileged user, reads Jellyfin's `/config` out of the
newest snapshot §4.1 takes, and encrypts it on arrival. Every step of the
script was bench-tested against a directory on `oracle` over real ssh before
this section was written; **none of it has touched this host**, which is
what the checklist below is for. Do the steps in order — the proof in step 5
is what makes step 7 safe.

1. **Create the user.** Credentials → Users → Add: name **`frodo`**, a
   full name that says what it is for, **Disable Password** on, SMB off,
   no sudo, no auxiliary groups, shell **zsh** (the default for a user with
   shell access; the script's commands are written to behave the same under
   zsh and bash). Paste the monitoring host's operator public key —
   `/home/robo/.ssh/id_ed25519.pub`, the key that already reaches `morpheus`
   and `oracle` — into **Authorized Keys**. If the form will not store a key
   against the default home directory, give the user one at
   `/mnt/erebor/apps/home/frodo` — on the dataset the user already needs to
   read — and record that here. **Done 2026-09-19:** the form did need a
   home, and it is there. One thing *was* created for it: TrueNAS made
   `erebor/apps/home` a **child dataset** rather than a directory, which is
   why §4.1's snapshot task is non-recursive on purpose and not by accident —
   the pull needs nothing under it, and a recursive task would only be
   snapshotting an authorized key.

2. **Give the user read on the dataset, and nothing else.** From the console
   shell, read what the Apps preset set on the dataset root before changing
   it, and record both lines here the way §5 recorded `bilbo`'s:

   ```bash
   zfs get -H acltype,aclmode erebor/apps \
     && stat -c '%U:%G %a %n' /mnt/erebor/apps /mnt/erebor/apps/jellyfin /mnt/erebor/apps/jellyfin/config
   ```

   Then Datasets → `erebor/apps` → Permissions → Edit, add one entry — Who
   **User** `frodo`, permissions **Read** (the basic set: read and traverse),
   flags **Inherit** — and apply it recursively so the files Jellyfin has
   already written carry it. Jellyfin creates files at `0644` in directories
   at `0755`, so in practice `frodo` needs traverse on the two directories
   above `config` and nothing more; the entry is the smallest thing that
   grants it and survives a file Jellyfin one day writes tighter.

3. **Turn SSH on.** System → Services → SSH: **Start Automatically** on,
   then Configure — *Log in as Root with Password* **off**, *Allow Password
   Authentication* **off**, *Allow TCP Port Forwarding* **off** — and start
   it. The firewall already scopes port 22 to `10.0.99.20`; this is the
   service behind that rule and nothing else may reach it.

4. **Record the host key on the monitoring host.** `BatchMode` needs
   something to check against, so connect once by hand and accept the
   fingerprint **after** comparing it with what this host prints from its
   console shell — `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. A
   reinstall of TrueNAS changes this key and the job then fails until this
   step is repeated; that is the correct behaviour.

   ```bash
   ssh frodo@10.0.40.30 true
   ```

5. **Prove the read, as the user, against a snapshot.** This is the same
   `tar` the job runs, thrown away, and its exit status is the whole
   result: `0` means every file under the path is readable by `frodo`;
   `2` names the file that is not, and the fallback in ADR-0045 decision 4
   is the remedy rather than a wider grant here. `<newest>` is the last name
   `ls` printed in §4.1.

   ```bash
   ssh frodo@10.0.40.30 "tar -cf /dev/null --numeric-owner -C '/mnt/erebor/apps/.zfs/snapshot/<newest>/jellyfin/config' . && echo readable"
   ```

   Cross-check the name against the pool's own clock once, so the zone in
   §4.1 is known to be right: from the console shell,
   `zfs get -Hp creation erebor/apps@<newest>` is an epoch, and the script's
   reading of the same name is `TZ=America/Los_Angeles date -d '<date> <time>' +%s`
   on the monitoring host. They agree to the minute or the zone is wrong.

6. **The first run, by hand, on the monitoring host**, from the deployment
   checkout — and watch it: it prints the snapshot it chose, the size, the
   verification line with `./data/jellyfin.db present`, and the set it
   wrote. Then list and verify.

   ```bash
   make backup-nas && make backup-nas ARGS=--list && make verify-backups
   ```

7. **Install the timer.** `make install-timers` on the deployment checkout
   adds `homelab-backup-nas.timer` (Saturdays 03:30 UTC) and repoints the
   nightly `verify-backups` at both directories. Step 6 comes first because
   the nightly verification fails on an empty `backups/nas/` — a missing set
   is a finding, and the first run is what makes it not one.

8. **Re-read the tripwire.** From `morpheus`, the `igc0.40` counter in §0.6
   is **still zero**: every packet of this was inbound to the NAS, and
   nothing on it initiated anything.

9. **Rewrite the sentences that said "inert".** Three documents and two
   blocks in this runbook say port 22 is inert until this section is done:
   [`security.md`](../security.md) under CasaBonita, [`network.md`](../network.md)
   in `smaug`'s bullet, [`roadmap.md`](../roadmap.md) in the NAS paragraph,
   §0.5 above, and §4's status block. Each names this section; each becomes
   past tense with today's date, in the one commit that also fills the Done
   block below.

10. **What this leaves, said plainly.** One more service on the NAS, key-only,
    one address, one user who can read Jellyfin's configuration — which
    includes its users' password hashes — and whose key lives on the host
    that already holds the estate's age identity. What lands on the
    monitoring host is ciphertext to the same two recipients that open
    `grafana.db`, and the same run copies the set to `oracle` beside the
    volume sets and hashes it there, by the helpers
    [#535](https://github.com/Gerrrt/HomeLab/issues/535) built. Off-host
    twice, offsite never: one shelf holds all of it.

> **Done 2026-09-20.** Steps 1 to 8 in order over 2026-09-19 and 2026-09-20
> local time. Step 2 read `acltype nfsv4`, `aclmode passthrough` off the
> dataset, and `root:root 770` on `/mnt/erebor/apps` and its `jellyfin`
> directory with `nobody:nogroup 770` on `config`; `frodo`'s entry is
> `r-x---a-R-c---:fd-----:allow`, inherited, beneath the preset's own. Step 5
> tarred `auto-2026-09-19_23-00/jellyfin/config` to nowhere as `frodo` and
> exited 0. Step 6, the first set, is **`20260920T060234Z`** — 76 entries,
> 2.7 MB, `./data/jellyfin.db` present, Jellyfin never stopped — copied to
> `oracle` and hashed there in the same run, and `make verify-backups`
> re-read it beside the six observability sets. Step 7 installed
> `homelab-backup-nas.timer` on the same day; its priming run failed only
> because it came before step 6, exactly as this section warned. Step 8:
> the `igc0.40` tripwire read **0 packets** on 2026-09-20 with the pull
> done. Step 9 is the commit this block landed in.

### §6.3 — Restore Jellyfin's state

Two cases, in the order to try them.

**The pool is fine and Jellyfin is not** — a bad upgrade, a corrupted
database, a mistake in the web UI. The nightly snapshots from §4.1 are on
the pool, and the newest one from before the fault is the restore. As root,
from the stack directory, with Jellyfin stopped:

```bash
docker compose stop jellyfin \
  && cp -a /mnt/erebor/apps/.zfs/snapshot/<name>/jellyfin/config/. /mnt/erebor/apps/jellyfin/config/ \
  && docker compose up -d
```

**The pool is gone.** Rebuild §3 to §6 with the bind directory (the
migration block does not apply; the directory starts empty), then bring the
set back from the monitoring host. Verify it there first, then stream the
decrypted archive to a staging directory on this host that is created for
the occasion — plaintext may land on this pool because this pool is where
the data lives — and unpack it as root with Jellyfin stopped:

```bash
make backup-nas ARGS="--verify-only --set <STAMP>"
```

```bash
age --decrypt -i ~/.config/sops/age/keys.txt backups/nas/<STAMP>/jellyfin-config.tar.gz.age \
  | ssh frodo@10.0.40.30 "mkdir -p '/mnt/erebor/apps/home/frodo/restore' && cat > '/mnt/erebor/apps/home/frodo/restore/jellyfin-config.tar.gz'"
```

Then on this host, as root, from the stack directory:

```bash
docker compose stop jellyfin \
  && tar --numeric-owner -xzf /mnt/erebor/apps/home/frodo/restore/jellyfin-config.tar.gz -C /mnt/erebor/apps/jellyfin/config \
  && chown -R 65534:65534 /mnt/erebor/apps/jellyfin/config \
  && docker compose up -d \
  && rm -r /mnt/erebor/apps/home/frodo/restore
```

The proof is the same as the migration's: the users and the watch history
are back in the web UI. `--numeric-owner` on both ends is what keeps `65534`
as `65534` across two hosts that spell it differently.

## §7 — Verify

> **As of 2026-09-19:** the monitoring-host line holds in both halves, the
> QSV transcode passed (§6.1), `zpool status erebor` is `ONLINE` with no
> errors, `up{job="node",instance="smaug"}` reads 1, and the tripwire and
> the rule order were re-read from `morpheus` after the stack came up:
> 143,780 evaluations, **0 packets**, all four passes still above the block.
> **Port 15 re-read in the switch UI the same evening: VLAN 40, PVID 40,
> untagged only.** **A television on CasaBonita played something on the
> evening of 2026-09-19**, read by the operator on the screen and with no
> firewall rule in the path — this line had been claimed once earlier that
> day and withdrawn within the hour, so this is the reading and that was not.
> **Both extended self-tests completed without error**, read at the console
> on 2026-09-20 with `smartctl -l selftest`: `sda` (`ZVTBS4NL`) logged the
> completion at lifetime hour 25, `sdb` (`ZVTBSDL3`) at 26, no LBA of first
> error on either. They were at 10 % remaining the evening before and 20 %
> through at six lifetime hours that morning. The result is in
> [`hardware.md`](../hardware.md)'s Exos entry, and it was the last line of
> this list: **every line below is read**, and
> [#413](https://github.com/Gerrrt/HomeLab/issues/413) closed on it.
>
> **2026-09-20: the `zpool status erebor` line below stopped being true the
> evening before.** `sdb` (`ZVTBSDL3`) FAULTED at 20:55 PDT on 2026-09-19, at
> about lifetime hour 27 and an hour after the self-test above completed
> clean, and node_exporter stopped answering nine minutes earlier, so
> `up{job="node",instance="smaug"}` reads 0 as well. The pool runs on
> `ZVTBS4NL` alone. [`replace-the-nas-disk.md`](replace-the-nas-disk.md) is
> the procedure, and §6.2 — still not done — is its step 2, because
> `erebor/apps` has no copy off this host.
> [#558](https://github.com/Gerrrt/HomeLab/issues/558) carries it.

- A television on CasaBonita finds Jellyfin and plays something **without** any
  firewall rule being involved
- A Hicks workstation reaches `https://10.0.40.30` and `http://10.0.40.30:8096`
- The monitoring host reaches `9100` and **nothing else**. Both halves are
  checkable now: `443` and `8096` must be refused from the monitoring host, and
  `node_exporter` must be answering — §6.1 is what stands it up, and
  [#256](https://github.com/Gerrrt/HomeLab/issues/256) settled that it is
  `node_exporter` rather than TrueNAS's own endpoint. `up{job="node"}` should be
  `1`, labelled `instance="smaug"` rather than an address
- The `igc0.40` tripwire counter is **still zero**
- `make backup-nas ARGS=--list` on the monitoring host shows a **complete**
  set, and the nightly `verify-backups` has passed at least once since (§6.2)
- Port 15 on `neo` reads PVID **40**, untagged, with `smaug`'s MAC learned on it
  in VLAN 40 — read in the switch UI, and **not** inferred from the host having
  an address (§0.2b)
- The `igc0.40` tripwire's **packet** count is **still zero** — its evaluation
  count will have climbed, and that is not a finding
- `zpool status erebor` is `ONLINE` with no errors
- Both Exos self-tests from §2 completed without error

## §8 — What this leaves open

- **A faulted disk, one day in.** `ZVTBSDL3` FAULTED on 2026-09-19 and the
  pool is a mirror of one until it is replaced;
  [`replace-the-nas-disk.md`](replace-the-nas-disk.md) is the procedure and
  [#558](https://github.com/Gerrrt/HomeLab/issues/558) carries it. Its step
  2 is §6.2.
- **[#255](https://github.com/Gerrrt/HomeLab/issues/255)**, the residual saying
  this host ships no logs, which is true the day it exists.
- **[ADR-0027](../adr/0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md)'s
  PBS**, whose sync job wants another PBS instance — on TrueNAS that is PBS in
  a VM or a change to an NFS/SMB datastore.
  [#485](https://github.com/Gerrrt/HomeLab/issues/485) carries it.
- **Offsite.** §6.2 gets Jellyfin's state off `smaug`, onto the monitoring
  host and onto `oracle`, and every one of those copies is on the same shelf
  under the same roof — the position the volume sets and the firewall export
  are in, and [`roadmap.md`](../roadmap.md) is where that residual lives.
- **Plex**, deferred by ADR-0016 against a test nobody has run: whether any
  screen on 40 lacks a working Jellyfin client.
  [#139](https://github.com/Gerrrt/HomeLab/issues/139) carries the test.
