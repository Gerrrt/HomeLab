# ADR-0114: Rip discs on smaug with MakeMKV, started only to rip

**Status:** Accepted · 2026-11

## Context

The household wants its movie discs in Jellyfin. `erebor/media` holds almost
nothing yet: about 31 MiB of a pool with 15.6 TiB free on 2026-11-10.

There are two optical drives in the house, and neither is on a desktop:

- **`smaug`'s PLDS DVD-RW**, `sr0`, which went back into the 5.25" bay on
  2026-09-29 for burning discs ([`hardware.md`](../hardware.md)). It is
  `/dev/sg3` on the SCSI-generic side, read off the host on 2026-11-10. The
  pool's two Exos are `sg1` and `sg2`, and the boot SSD is `sg4`. It reads
  DVDs and not Blu-ray.
- **`oracle`'s laptop drive.** `oracle` has 4 GB of RAM and two cores, it sits
  on Winterfell, and it has no path to the `media` share. Using it would add a
  second host to the ripping path for one more drive.

Ripping a disc needs a program to read it and a person to choose its titles.
On Linux MakeMKV is that program, and it needs both the block device and the
drive's SCSI-generic node.

Two decisions limit what may write into the library.
[ADR-0008](0008-place-services-by-data-trust.md) ruled `erebor/media`
replaceable and not backed up.
[ADR-0050](0050-add-audiobookshelf-to-the-media-tier-behind-a-fifth-hicks-pass.md)
deferred Audiobookshelf's podcast downloader because it would make a service a
writer into that dataset. Every service in `stacks/media` mounts the library
read-only, and the roadmap declines the *arr stack, an automated writer, for
now.

## Decision

**Run MakeMKV on `smaug` as a container in `stacks/media`, behind the compose
profile `rip`, so it runs only while someone is ripping.**

- **The image** is `jlesage/makemkv`, digest-pinned like every other. It is
  MakeMKV's GUI in a virtual display, served to a browser on `5800` through
  noVNC. The person at a Hicks workstation chooses the titles, and nothing
  rips on its own: the image's `AUTO_DISC_RIPPER` stays off.
- **Its devices** are `/dev/sr0` and the drive's SCSI-generic node, `sg3`,
  named in `.env` and read off the host, never guessed. A wrong guess here is
  raw SCSI access to a pool disk.
- **It writes to one folder only:** `erebor/media/rips`, mounted at
  `/output`. No Jellyfin library points at it. A person moves each finished
  file into `movies/` over the `media` share, as `samwise`. It is a rename in
  one dataset, so it is instant. The rest of the library is not mounted, and
  Jellyfin's `/media` stays read-only.
- **It is not running between sessions.** `docker compose --profile rip up -d
  makemkv` starts it, and `docker compose stop makemkv` ends the session.
  A plain `docker compose up -d`, the media stack's normal deploy, does not
  start it. Its restart policy is `"no"`, not the stack's `unless-stopped`,
  because a profile does not bind Docker's restart manager. A reboot
  mid-session leaves it down rather than reopening the GUI on its own.
- **Every start checks the drive first.** SCSI-generic numbers follow probe
  order, so the session start in `rip-a-disc.md` refuses to run unless the sg
  node `.env` names still belongs to `sr0`.
- **Its state** is `/mnt/erebor/apps/makemkv/config`, on the snapshotted apps
  dataset with the other services' state. It holds MakeMKV's settings and the
  beta key, and nothing anyone would miss.
- **It starts as root.** The image's `/init` prepares `/config` and then runs
  MakeMKV as `USER_ID`/`GROUP_ID`, here 65534, so the rips match what
  Jellyfin reads and inherit the `everyone@` read entry. Its capabilities are
  cut to six, the way speedtest-tracker's are: the five that preparing
  `/config` and dropping privilege need, and `KILL`, for an init that signals
  processes it no longer shares a uid with. `no-new-privileges` holds,
  because the drop is `setuid(2)` and not a setuid binary. **That set is
  written from the image's design and not yet measured.** No daemon was
  available where this was authored, so §6.11's first start is the
  measurement, and `compose.yaml` records what it finds.
- **A Hicks pass on `5800`,** `Allow 5800 to smaug`, above *Block access to
  CasaBonita*, in the same shape as the others in
  [`build-the-nas.md`](../runbooks/build-the-nas.md) §0.5.
- **The procedure** is [`rip-a-disc.md`](../runbooks/rip-a-disc.md). Deploying
  the service is `build-the-nas.md` §6.11.

## Alternatives considered

- **A USB drive on a Windows desktop** with MakeMKV for Windows. Nothing new
  on the NAS, no new port, and a 4K-capable drive is possible. It means
  buying a drive when the house already has two. Declined for DVDs, and still
  open for Blu-ray (below).
- **Automatic Ripping Machine,** or the image's own `AUTO_DISC_RIPPER`. The
  disc rips as soon as it is inserted, with no one choosing titles. That makes
  it an automated writer into `erebor/media`, the thing ADR-0050 deferred, and
  it guesses the main title on discs that hide it among decoys. Declined.
- **MakeMKV on `oracle`,** headless with `makemkvcon`. A second host, the
  weakest one in the estate, and a new path from Winterfell to the share.
  Declined.
- **Always running.** It would save typing one command per session. It would
  also leave an unauthenticated GUI with a writable folder on the segment with
  the game consoles all day. Declined, and the profile is what replaces it.
- **The GUI's own login** (`WEB_AUTHENTICATION`). It needs a password handed
  in from the environment, and this stack has no secrets file by decision
  ([#528](https://github.com/Gerrrt/HomeLab/issues/528)). The profile is
  cheaper. Revisit if the container ever runs unattended.

## Consequences

- **A third image in the estate that starts as root,** after Alloy and
  speedtest-tracker. Its init stays uid 0 for the life of the container, the
  way s6 does in speedtest-tracker, while MakeMKV runs as 65534. Its
  capabilities are the six listed in `compose.yaml`. `docs/security.md`
  records it.
- **While it runs, its GUI is unauthenticated on `5800`** to anything on
  CasaBonita, as Jellyfin's `8096` is, and to Hicks through the pass. Anyone
  who reaches it can read the disc in the drive and write into `rips/`. That
  is about filling the pool, not reaching the library. Bounded by stopping it
  after each session.
- **The disc is the backup.** Rips are replaceable by ADR-0008's test, so
  `erebor/media` stays out of the backup.
- **Blu-ray is not covered.** The DVD-RW cannot read BD. If the household has
  Blu-rays, a 5.25" SATA BD drive in the same bay keeps every line here true,
  and it goes on the roadmap's purchase list when one is wanted. A 4K UHD disc
  also needs a drive model MakeMKV can read in LibreDrive mode.
- **MakeMKV's DVD ripping is free.** The image's default `MAKEMKV_KEY=BETA`
  fetches the current beta key, which also unlocks Blu-ray while MakeMKV is in
  beta. It expires and is re-fetched on start, so a session after a long gap
  may need a restart.
- **Reopened by:** a Blu-ray drive, which this decision already allows; a want
  for unattended ripping, which is the declined alternative and needs its own
  decision; or `smaug`'s drive coming out of the bay again.
