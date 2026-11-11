# Runbook: Rip a disc into Jellyfin

Turn a DVD into a film in Jellyfin's *Movies* library, using `smaug`'s DVD-RW
and MakeMKV in a browser
([ADR-0114](../adr/0114-rip-discs-on-smaug-with-makemkv-started-only-to-rip.md)).

---

## Before the first session

[`build-the-nas.md`](build-the-nas.md) §6.11 has to have been done once: the
`Allow 5800 to smaug` pass, the `rips/` and `movies/` folders, and the
*Movies* library in Jellyfin. **Until its Done block exists, it has not
been.**

**This drive reads DVDs only.** A Blu-ray case is blue and carries the
Blu-ray logo, and a 4K UHD case is black with *4K Ultra HD* across the top.
Neither will open in this drive. Put them aside: ADR-0114 says what a Blu-ray
drive would take.

---

## A session

### 1. Start the ripper

In the TrueNAS shell (**System → Shell**):

```bash
cd /mnt/erebor/apps/stack
sg=$(sed -n 's|^MAKEMKV_SG_DEVICE=/dev/||p' .env)
if [ -n "$sg" ] && [ "$(ls "/sys/class/scsi_generic/$sg/device/block" 2>/dev/null)" = sr0 ]; then
  docker compose --profile rip up -d makemkv
else
  echo "REFUSING: ${sg:-no sg device} is not the DVD drive. See build-the-nas.md §6.11 step 2."
fi
```

**The check is the point, so never skip it.** SCSI-generic numbers follow
probe order and can move after a reboot or a change of drives. `.env` names
the node that was the DVD drive when it was last read, and a node that has
since become a pool disk would hand the container raw SCSI access to it. The
start runs only if the node `.env` names still belongs to `sr0`. If it
refuses, re-read the nodes by §6.11 step 2, change `MAKEMKV_SG_DEVICE` in
`.env.example` in a commit, re-fetch, and start again.

Wait for `docker compose ps makemkv` to read `healthy`, about a minute.

**If `smaug` restarts during a session, the ripper stays down.** Its restart
policy is `"no"`, so the GUI never comes back without someone starting it.
Start it again with the block above, which repeats the check.

### 2. Rip each disc

1. Put the disc in `smaug`'s drive, the 5.25" bay on the front.
2. From a Hicks workstation, open `http://10.0.40.30:5800`. MakeMKV's window
   appears in the page.
3. Click the drive's large icon to open the disc. MakeMKV reads it, which
   takes a minute or two for a DVD.
4. **Choose the main feature.** It is usually the longest title, at the
   film's running time. Untick the rest: trailers, extras and menus.
   - **Several titles the same length** means the disc hides the real film
     among decoys. Look up the film's running time on the case, and pick
     the title whose length and chapter count match it. If two still match,
     rip both, and keep the one that plays in order.
5. **Choose its tracks.** Expand the title. Keep the main audio track in the
   original language and the household's, and the subtitles you want.
   MakeMKV keeps the lossless video; nothing is re-encoded.
6. The output folder is `/output`. Leave it. Click **Make MKV**. A DVD takes
   about 15–30 minutes.
7. Eject from MakeMKV's toolbar or the drive's button, and go to the next
   disc.

### 3. File each rip in the library

Over the share `\\10.0.40.30\media`, signed in as `samwise`, move each file
out of `rips\` into its own folder under `movies\`, named the way Jellyfin
expects:

```text
movies\The Film Title (1999)\The Film Title (1999).mkv
```

The year is what tells Jellyfin which film it is when titles collide. It is a
move within one dataset, so it is instant. Jellyfin picks the film up at its
next scan. **Dashboard → Libraries → Scan All Libraries** brings it in now.

### 4. End the session

In the TrueNAS shell:

```bash
cd /mnt/erebor/apps/stack
docker compose rm -sf makemkv
```

**Do not leave it running.** Its page has no login, and while it runs anything
on CasaBonita can reach it, the game consoles included. Removing the
container is the boundary ADR-0114 chose instead of a password.

---

## When it goes wrong

- **The drive list is empty.** The container cannot see the drive. Read
  §6.11 step 2 again: the sg node may have moved, and `.env.example` must
  name the one whose block device is `sr0`.
- **A read error partway through.** Clean the disc with a soft cloth from the
  centre outward, and retry once. If it fails again, note the title and move
  on. Some scratched discs will not rip in this drive.
- **MakeMKV says the key is out of date.** The image fetches the current beta
  key on start, so end the session and start a new one. DVDs rip without a
  key in any case.
- **Jellyfin shows the wrong film.** The folder name is the fix: correct the
  title or year, and rescan. **Identify** on the film's menu matches it by
  hand.
- **`rips\` is filling.** Files there are not in any library. Move them or
  delete them. The pool has room for thousands of DVDs, but nothing cleans
  that folder on its own.
