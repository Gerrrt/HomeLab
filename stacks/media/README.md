# Media stack

[ADR-0008]'s media tier — the household's media server — on `smaug`
(`10.0.40.30`, CasaBonita / VLAN 40), the ThinkServer TS150 that [#413] bought
and [ADR-0040] gave TrueNAS. **The pool is not built yet**;
[`build-the-nas.md`] §6 deploys this stack, and this directory is authored
ahead of the storage the way `stacks/sensitive` was authored ahead of
`trinity`.

```bash
make up STACK=media
```

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| jellyfin | `jellyfin/jellyfin` | 8096 (http), on the segment | The media server the televisions reach directly, with Quick Sync hardware transcoding on the E3-1225 v6's HD P630 ([#138], [ADR-0016]) |

One service, and that is a decision rather than a starting point. [ADR-0016]
builds **Jellyfin alone** and adds Plex only if a screen on 40 turns out to
have no working Jellyfin client — the LG OLED, which is the primary screen,
has one. Plex authenticates its clients through `plex.tv` even on a local
network, which would make a household service that works today depend on a
third party staying up and keeping its terms. That is a deferral against a
test nobody has run, not a rejection. Audiobookshelf ([#140]) and Navidrome
([#141]) land here later, in the shape this file already has.

## Why there is no reverse proxy, and why that is not an omission

`stacks/sensitive` puts twelve services behind Caddy and publishes exactly one
port, because that tier holds the data whose loss hurts. **This tier is the
other half of [ADR-0008]'s bargain** and gets the opposite treatment on
purpose:

> a failure of the media box costs a film night, and a failure of the sensitive
> box costs a restore — never both at once.

Its clients are televisions, and a television is not a browser. It speaks to
Jellyfin on 8096 on the same broadcast domain, with **no firewall rule
involved at all** — which is the whole of what [ADR-0008] bought by placing the
server *with* its clients instead of punching a hole through a terminal
segment to reach it. A proxy in front of that would add a hop, a certificate
every television would have to trust, and a second thing to be down.

## What is published, and to whom

| Who | Reaches it how |
| --- | --- |
| Televisions on CasaBonita | Natively, same broadcast domain — the firewall never sees the packet |
| A Hicks workstation | The one rule in [`build-the-nas.md`] §0.5, `50 → 10.0.40.30:443,8096` |
| Everything else on the estate | Not at all — default deny |

[ADR-0012] asks for a named off-host consumer before a port is published, and
here there are two: every screen in the house, and one workstation.

## The backup split

**Jellyfin's state is backed up. The library is not.** That is deliberate, it
is what [#138] demanded a deliberate answer on, and it is carried in the
volume layout rather than in a policy document:

| Volume / mount | What it holds | Backed up |
| --- | --- | --- |
| `jellyfin-config` | database, users, **watch history, resume positions**, metadata | **yes** — `scripts/backup-volumes.sh` |
| `jellyfin-cache` | transcode scratch, image caches | no — regenerable |
| `${MEDIA_PATH}` → `/media` | the library itself | no — see below |

[ADR-0008] already ruled the library replaceable and its loss *"annoying rather
than catastrophic"*, so backing up 18 TB of re-acquirable files would spend the
mirror's capacity contradicting a decision already taken. But re-acquiring a
series does not restore **which episode anyone was on**, and that part is
measured in megabytes. The mirror buys availability; the backup buys the index.

The library is mounted **read-only**. Jellyfin keeps metadata in `/config` by
default, so it has no need to write there — and a media server on the segment
with the game consoles should not be able to delete the thing it serves.

## What was measured rather than assumed

Every non-obvious line in `compose.yaml` came off the pinned image on
2026-09-16, not off upstream's documentation:

- **It declares no user**, so it would run as root unless told otherwise.
  Nothing else in this estate does, and neither does this.
- **`/config` and `/cache` are mode `777`**, which is what lets it run as
  `65534` with no chown sidecar — the dance `stacks/sensitive` documents for
  Caddy is not needed here.
- **`curl` is present; `wget`, `busybox` and `nc` are not**, which decides the
  healthcheck shape this repository otherwise writes with busybox wget.
- **`/health` answers `200` with a body reading `Degraded`** on a fresh
  instance. The healthcheck therefore keys on the status code and ignores the
  body — requiring `Healthy` would mark the container unhealthy from first boot
  until somebody finished the setup wizard, which on `restart: unless-stopped`
  is a restart loop.
- **65 MiB idle RSS**, which is what the 2 GiB ceiling is a ceiling over.

## The check that is not done yet

[ADR-0040] keeps the media stack in this repository on the strength of Quick
Sync working, and names its own reopen condition: **the iGPU reaching a
container**. The CPU half is confirmed — `Active Video: IGD` on an E3-1225 v6,
read off the machine — but a live P630 and a P630 a container can use are
different claims. `devices: /dev/dri` and `RENDER_GID` are where the second
claim is made; [`build-the-nas.md`] §6 is where it gets tested, **before the
library exists**, because moving a populated library is a weekend.

[ADR-0008]: ../../docs/adr/0008-place-services-by-data-trust.md
[ADR-0012]: ../../docs/adr/0012-publish-only-ports-with-an-off-host-consumer.md
[ADR-0016]: ../../docs/adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md
[ADR-0040]: ../../docs/adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md
[`build-the-nas.md`]: ../../docs/runbooks/build-the-nas.md
[#138]: https://github.com/Gerrrt/HomeLab/issues/138
[#140]: https://github.com/Gerrrt/HomeLab/issues/140
[#141]: https://github.com/Gerrrt/HomeLab/issues/141
[#413]: https://github.com/Gerrrt/HomeLab/issues/413
