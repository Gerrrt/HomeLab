# Media stack

[ADR-0008]'s media tier — the household's media and music servers — on `smaug`
(`10.0.40.30`, CasaBonita / VLAN 40), the ThinkServer TS150 that [#413] bought
and [ADR-0040] gave TrueNAS. **Deployed 2026-09-19**, from a copy of this
directory's two files on the pool, under TrueNAS's own Docker;
[`build-the-nas.md`] §6 is the procedure. `make up STACK=media` does **not**
work on that host — it renders secrets this stack does not have, on a box
without `make` or `sops` — so a change here reaches `smaug` by re-fetching
`compose.yaml` and `.env.example` from `main` into `/mnt/erebor/apps/stack`
and running `docker compose up -d` there. Nothing pulls from `main` on that
host on its own: a Dependabot bump is merged here and deployed there by hand.
A third file lives beside them since [ADR-0047]: `scripts/collect-smart-state.sh`,
fetched the same way and run by TrueNAS's cron — a change to it reaches
`smaug` only by the same re-fetch.

```bash
cd /mnt/erebor/apps/stack && docker compose up -d
```

`.env.example` names `JELLYFIN_CONFIG_PATH` and `NAVIDROME_DATA_PATH`,
directories on `erebor/apps` that have to exist, owned by `65534:65534`,
before the first `up` — §6 of the runbook creates them, and says why they are
bind mounts and not volumes.

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| jellyfin | `jellyfin/jellyfin` | 8096 (http), on the segment | The media server the televisions reach directly, with Quick Sync hardware transcoding on the E3-1225 v6's HD P630 ([#138], [ADR-0016]) |
| navidrome | `deluan/navidrome` | 4533 (http), on the segment and to Hicks | The music server, over the Subsonic API, for the apps on the phones ([#141]) |
| node-exporter | `prom/node-exporter` | 9100 (http), to `10.0.99.20` only | How this host is monitored at all — Prometheus scrapes it, because nothing on this segment may push ([#256], [ADR-0016]); it also serves the SMART textfile a root cron job on the host writes ([#483], [ADR-0047]) |

Three services, and two of them are the tier. `node-exporter` is here
because of the section below; everything else in this file is about Jellyfin
and Navidrome.

Jellyfin is the one video server, and that is a decision rather than a
starting point. [ADR-0016]
builds **Jellyfin alone** and adds Plex only if a screen on 40 turns out to
have no working Jellyfin client — the LG OLED, which is the primary screen,
has one. Plex authenticates its clients through `plex.tv` even on a local
network, which would make a household service that works today depend on a
third party staying up and keeping its terms. That is a deferral against a
test nobody has run, not a rejection.

**Navidrome is here for music, which is the weakest thing Jellyfin does**
([#141]). It speaks the Subsonic API, so the clients are a dozen mature apps
on every platform that this repository will never maintain, and it reads the
same pool from `erebor/media/music`, read-only. Its clients are phones, and
the phones are on Hicks, which is why it needs the fifth pass below where
Jellyfin needed none. Audiobookshelf ([#140]) lands here later, in the same
shape.

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
| A Hicks workstation | Two of the rules in [`build-the-nas.md`] §0.5 — `50 → 10.0.40.30:443` and `50 → 10.0.40.30:8096`, one per port |
| Prometheus, on `9100` | A third — `10.0.99.20 → 10.0.40.30:9100` |
| Prometheus, on `22` | The fourth — `10.0.99.20 → 10.0.40.30:22`, inert until [`build-the-nas.md`] §6.2 switches SSH on for the backup pull, as `frodo` with one key and read access to `erebor/apps` ([ADR-0045]) |
| A phone on Hicks, on `4533` | The fifth — `50 → 10.0.40.30:4533`, authored for Navidrome and created by §6.5 with its deploy |
| Everything else on the estate | Not at all — default deny |

[ADR-0012] asks for a named off-host consumer before a port is published, and
here there are four: every screen in the house, one workstation, the phones
and the monitoring host.

No published port is private to its consumer, and the reason is the same
for all three: everything already on CasaBonita shares this broadcast domain
and reaches them without the firewall seeing a packet. For 8096 and 4533 that
is the whole point. For 9100 it is a residual — an unauthenticated read of
this host's filesystems, uptime and load, by the televisions — and
`docs/security.md` records it rather than the firewall rule being mistaken for
a boundary it is not.

## Why this host is scraped, and runs no agent

Every other machine in the estate runs Alloy and **pushes** metrics and logs to
`10.0.99.20`. This one may not. [ADR-0016] put the NAS on a segment that is
terminal outward — nothing on CasaBonita initiates anywhere — so Prometheus
reaches in over `99 → 40:9100` and scrapes instead. The convention that every
host runs Alloy exists to serve a direction; here the direction reverses, so
the tool does too. `smaug` is the estate's first scraped host.

[#256] settled what shape that target takes, because [ADR-0040] opened a fork
in it: TrueNAS ships a metrics endpoint of its own. The answer is
`node_exporter`, for three reasons written out in full in
`stacks/observability/prometheus/targets/node.yaml` — the firewall pass already
exists for `9100`, the `host-overview` dashboard and seven rules in
`host.rules.yaml` are built on the `node_*` namespace, and a container in this
repository stays inside Dependabot, the digest pins and `make validate`, which
is [ADR-0040] decision 2's argument for this stack being here at all.

What this does **not** buy is logs. Loki has no pull, and its ingest is
unauthenticated by [ADR-0012], so centralising this host's logs would mean a
`40 → 99:3100` rule that lets anything reaching the NAS write to the log store.
The NAS gets metrics and no logs; [#255] is where that residual lives.

## SMART, and why it is a cron job on the host

The exporter above reads nothing a drive says: it is uid 65534, read-only and
cap-dropped, and its image has no `smartctl`. The estate's SMART collector
needs root. Everywhere else it is a systemd timer installed beside Alloy;
this host has an immutable root and no Alloy, so [ADR-0047] runs the same
script from a copy on the pool as a **root cron job in TrueNAS's own UI**,
writing `smart-state-smaug.prom` into `SMART_TEXTFILE_PATH`, which the
exporter bind-mounts read-only at `/textfile`. The series ride the scrape
that already exists, carry `host="smaug"` and `instance="smaug"`, and every
SMART rule in `host.rules.yaml` applies unchanged — including
`SmartDriveBadSectors`, which holds the boot SSD to the four static
reallocated sectors recorded for it in `scripts/render-smart-baselines.sh`
and pages above them, with the growth rule armed on its own account.
Nothing on this host initiates anything: the file is local
and Prometheus reads it. [`build-the-nas.md`] §6.4 is the procedure, with
the cron job's fields recorded there.

**Patch state is deliberately not collected here.** TrueNAS is an appliance
updated as an image from its own UI; there is no `apt` to ask, so the
estate's `homelab_apt_*` rules have no referent on this host and a collector
would report nothing. [ADR-0047] writes the no down rather than leaving it
to be rediscovered.

## The backup split

**Jellyfin's and Navidrome's state is backed up. The library is not.** That is deliberate, it
is what [#138] demanded a deliberate answer on, and it is carried in the
volume layout rather than in a policy document:

| Volume / mount | What it holds | Backed up |
| --- | --- | --- |
| `${JELLYFIN_CONFIG_PATH}` → `/config` | database, users, **watch history, resume positions**, metadata | **yes** — `scripts/backup-nas.sh`, weekly, from a ZFS snapshot of `erebor/apps` |
| `jellyfin-cache` | transcode scratch, image caches | no — regenerable |
| `${NAVIDROME_DATA_PATH}` → `/data` | Navidrome's database — **users, playlists, favourites, play counts** — and extracted artwork | **yes** — the same pull, the same snapshot, a second archive in the set |
| `/cache` (tmpfs) | Navidrome's transcodes and resized artwork | no — regenerable, and gone on restart |
| `${MEDIA_PATH}` → `/media`, `${MUSIC_PATH}` → `/music` | the library itself | no — see below |

[ADR-0008] already ruled the library replaceable and its loss *"annoying rather
than catastrophic"*, so backing up 18 TB of re-acquirable files would spend the
mirror's capacity contradicting a decision already taken. But re-acquiring a
series does not restore **which episode anyone was on**, and that part is
measured in megabytes. The mirror buys availability; the backup buys the index.

**How the yes works, and where it was not true.** For the first week this
table said *yes — `scripts/backup-volumes.sh`*, and that script had no entry
for the volume, cannot see this host's Docker, and would have found the state
on `erebor/ix-apps` rather than on the dataset [`build-the-nas.md`] §4 calls
backed up ([#484]). [ADR-0045] settles it: `/config` is a **bind mount** on
`erebor/apps`, TrueNAS snapshots that dataset nightly, and the monitoring host
**pulls** the newest snapshot's copy over the `99 → 40:22` pass — the rule
[ADR-0016] wrote for exactly this and nothing else — encrypting it on arrival
with `age` and copying the set on to `oracle` in the same run. Navidrome's
`/data` is a second bind mount on the same dataset and a second archive in the
same set, read out of the same snapshot, so the two are always one instant
([#141]). Neither server is ever stopped; the snapshot is the quiesce. Nothing on this host initiates
anything, which is the terminal property [ADR-0016] keeps.
[`build-the-nas.md`] §6.2 turns the pull on and §6.3 restores from it.

**What is not backed up, on purpose:** `erebor/media`, the library;
`jellyfin-cache`, which `scripts/backup-volumes.sh` lists as disposable by
name; Navidrome's `/cache`, a tmpfs; and `erebor/ix-apps`, Docker's images and that cache volume. And
`scripts/backup-volumes.sh` does not run against this stack at all —
`STACK=media` reports nothing to archive, which is the true answer here.

The library is mounted **read-only**, into both servers. Jellyfin keeps
metadata in `/config` by default and Navidrome in its database, so neither has
any need to write there — and a media server on the segment
with the game consoles should not be able to delete the thing it serves.

## Where the admin credential lives, and why there is no secrets file

Every other tier has a `secrets/<stack>.example.yaml` and a `.sops.yaml` rule
of its own. This one has neither, and [#528] decided that rather than let it
happen: **Jellyfin's `admin` is created by its own setup wizard and kept as a
hash in `jellyfin.db` inside `jellyfin-config`**. No environment variable or
rendered file is a way to hand it in, so a value in a secrets file would
reach nothing — and `make secrets-init STACK=media` has to run on the stack's
host, which ships neither `make` nor `sops`. The plaintext is in the
operator's password manager, beside pfSense's and iLO's. `docs/security.md`
§ Secrets records the exception next to Home Assistant's, which is the same
class, and names what would retire it.

What that costs is one command: `make render STACK=media` dies on the missing
file, and that is expected. This stack is deployed by the two `curl` lines in
[`build-the-nas.md`] §6, never by `make up`.

**Nobody needs the password to get back in.** From a workstation on Hicks,
*Forgot Password* on `http://10.0.40.30:8096` writes a PIN file into the
config volume; the login page then takes the PIN and sets a new password. The
file is read from a TrueNAS shell:

```bash
docker exec media-jellyfin sh -c 'cat /config/passwordreset*.json /config/data/passwordreset*.json 2>/dev/null'
```

The flow only answers an address Jellyfin counts as local, which every RFC
1918 range is until its *LAN networks* setting says otherwise — and Hicks is
the segment the `50 → 40` passes were made for. Before the wizard has been run
at all there is no admin to reset, and `/health` reads `Degraded`, which is
why the healthcheck ignores the body.

**Navidrome is the same class, and joined this section on 2026-09-22**
([#141]). Its admin is created from the TrueNAS shell, not the web form —
`docker exec -it media-navidrome navidrome user create --admin -u <name> -n`,
which prompts for the password — immediately after the first `up`
([`build-the-nas.md`] §6), because until an admin exists the first visitor to
`:4533` is offered the form that creates one. Once one exists the form
answers `403`. The hash is in `navidrome.db` on `NAVIDROME_DATA_PATH`, the
password in the password manager beside Jellyfin's. Its way back in without
the password is the same binary, from the same shell:

```bash
docker exec -it media-navidrome navidrome user edit -u <name> --set-password -n
```

Audiobookshelf ([#140]) is the same shape — a first user created through the
UI, no admin password from the environment — and joins this section rather
than `secrets/` when it lands; its root is reset by editing its user store
under `/config`.

## What was measured rather than assumed

Every non-obvious line in `compose.yaml` came off the pinned image, not off
upstream's documentation. Jellyfin's on 2026-09-16:

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

Navidrome's on 2026-09-22, from a scratch boot as `65534`, read-only and
cap-dropped, with a generated track in the library:

- **It declares no user either**, and its `/data` and `/music` are root `755`
  rather than `777`. `/data` is a bind mount created `65534`-owned; `/music`
  is only read.
- **The image has no `/cache`, and a named volume there kills it.** Docker
  makes the mount point root `755`, Navidrome cannot create
  `/cache/plugins`, and the process aborts a second after logging that it is
  ready. The cache is a tmpfs owned by `65534` instead — and it is off
  `/data` on purpose, so the backup does not carry transcodes.
- **`ND_PLUGINS_ENABLED=false`** stops it creating a `0700`
  `/data/plugins`, the one directory it wrote that the backup user could
  not be assumed to read.
- **`/ping` answers `200` before any admin exists**, so the healthcheck has
  no bootstrap problem of the kind Jellyfin's `/health` has. `wget`, `curl`,
  `busybox` and `nc` are all present; the healthcheck uses `wget`.
- **An admin made with `navidrome user create --admin` in the running
  container closes the web form**: `/auth/createAdmin` answered `403`
  afterwards, and the login took the password.
- **49 MiB idle RSS** after the first scan, which is what the 1 GiB ceiling
  — covering the 384 MiB tmpfs as well — is a ceiling over.

## The check that passed

[ADR-0040] keeps the media stack in this repository on the strength of Quick
Sync working, and names its own reopen condition: **the iGPU reaching a
container**. The CPU half is confirmed — `Active Video: IGD` on an E3-1225 v6,
read off the machine — but a live P630 and a P630 a container can use are
different claims. `devices: /dev/dri` and `RENDER_GID` are where the second
claim is made; [`build-the-nas.md`] §6 is where it gets tested, **before the
library exists**, because moving a populated library is a weekend.

**On 2026-09-19 both halves passed.** `renderD128` is listed inside the
container as `root 107`, `id` there reads `groups=65534(nogroup),107`, and
a 1080p clip played at a forced 480p was decoded with `-hwaccel vaapi` on
the `iHD` driver, scaled by `scale_vaapi` and encoded by `h264_qsv` at about
five times real time — read off the ffmpeg command line in
`/config/log/FFmpeg.Transcode-*.log`, not off the dashboard. [ADR-0040]'s
reopen condition is closed; the stack stays here.

[ADR-0008]: ../../docs/adr/0008-place-services-by-data-trust.md
[ADR-0012]: ../../docs/adr/0012-publish-only-ports-with-an-off-host-consumer.md
[ADR-0016]: ../../docs/adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md
[ADR-0040]: ../../docs/adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md
[ADR-0045]: ../../docs/adr/0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md
[ADR-0047]: ../../docs/adr/0047-collect-smaug-smart-through-a-root-cron-and-the-textfile-collector.md
[`build-the-nas.md`]: ../../docs/runbooks/build-the-nas.md
[#138]: https://github.com/Gerrrt/HomeLab/issues/138
[#140]: https://github.com/Gerrrt/HomeLab/issues/140
[#141]: https://github.com/Gerrrt/HomeLab/issues/141
[#255]: https://github.com/Gerrrt/HomeLab/issues/255
[#256]: https://github.com/Gerrrt/HomeLab/issues/256
[#483]: https://github.com/Gerrrt/HomeLab/issues/483
[#413]: https://github.com/Gerrrt/HomeLab/issues/413
[#528]: https://github.com/Gerrrt/HomeLab/issues/528
[#484]: https://github.com/Gerrrt/HomeLab/issues/484
