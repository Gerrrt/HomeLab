# ADR-0104: Bring the Ring Alarm into Home Assistant through ring-mqtt

**Status:** Accepted · 2026-10

## Context

The household's rule is that Home Assistant is where everything is seen and
controlled. The Ring cameras and the doorbell already are, through Home
Assistant's core `ring` integration. The Ring Alarm is not. The house has its
base station (`alarm-hub` in `network.md`), its sensors and two keypads.
Which sensor watches which door is withheld, like the cameras' rooms
(`docs/security.md`). Home Assistant could
see none of them on 2026-10-22, when its Ring entry was signed in as the
Ring location's owner and Ring's API returned the base station among the
devices.

The reason is the library, not the account. The core integration is built on
`ring_doorbell`, which reads Ring's device list and the cameras' event pushes.
The alarm's sensors, keypads and arming state are not in that list. They live
behind a separate alarm websocket the base station keeps with Ring's cloud,
and `ring_doorbell` does not speak it. No core integration does.

[ring-mqtt](https://github.com/tsightler/ring-mqtt) does. It is a Node service
built on `ring-client-api`, which implements that websocket, and it publishes
every alarm device to an MQTT broker with Home Assistant discovery. It is the
community's standard path: Home Assistant OS users run it as an add-on beside
the Mosquitto add-on. This estate runs Home Assistant *Container*, with no
add-ons, by design (`stacks/sensitive/README.md`). That README already said
what would happen on the day a device needed a broker: it "becomes a pinned
service here".

Two things found on 2026-10-22 shape where the sign-in comes from:

1. **A shared Ring user cannot change device settings.** Home Assistant's Ring
   entry was a shared user on the owner's location. Turning an indoor
   camera's motion detection off (`packages/presence.yaml`) failed with
   "Error communicating with Ring API" every time.
2. **Ring's newer shared-access role is invisible to that API.** Upgrading the
   shared user's access in the Ring app emptied Ring's `ring_devices` and
   `locations` answers to it, both to zero, while the Ring app still showed
   everything. A fresh sign-in did not change that.

So Home Assistant's Ring entry was moved to the owner's account the same day.
That made motion detection work and brought in the two floodlights and the
garage camera. ring-mqtt has the same constraint, for the same reason.

## Decision

**Run ring-mqtt and a Mosquitto broker as two pinned, hardened services in
`stacks/sensitive`, on a network of their own, with alarm devices only.**

1. **Mosquitto is on an internal network, `mqtt`, and nothing else.** That
   network has no gateway. Only Home Assistant and ring-mqtt join it; every
   other service on the tier cannot reach port 1883. That was tested on
   2026-10-22 from a container on `sensitive`. The broker carries arming
   commands, so being on the tier is not enough to reach it.
2. **Two users, one ACL.** `homeassistant` reads and writes everything.
   `ring-mqtt` may use `ring/#` and `homeassistant/#` and nothing else, so a
   compromised bridge cannot publish as another integration would. There is
   no anonymous access. The passwords are `MQTT_HA_PASSWORD` and
   `MQTT_RING_PASSWORD` in `secrets/sensitive.sops.yaml`. The broker builds
   its argon2id password file from them in a tmpfs on every start, so
   rotating one is a SOPS edit and `make up`. Home Assistant's copy is typed
   once into its MQTT integration and changes there too.
3. **Nothing is on disk for the broker.** Persistence is off and it has no
   volume. ring-mqtt republishes every device and its discovery when Home
   Assistant's birth message arrives, which happens after either restarts.
4. **ring-mqtt runs as plain Node, not through its image's s6 init.** The init
   only sets two variables and execs `ring-mqtt.js`, but it needs root, and on
   its `latest` or `dev` branch it `git pull`s newer code at run time. Instead
   it runs as `RENDER_UID`, read-only, with every capability dropped and the
   image's own code only.
5. **Its config is written to a tmpfs, and its sign-in lives in its own
   volume.**
   - **The config:** ring-mqtt reads `/data/config.json`, which holds the
     broker password. It is written to a tmpfs from the environment on every
     start and linked into `/data`.
   - **The sign-in:** `/data` is a volume for `ring-state.json`, the owner
     account's Ring refresh token, which Ring rotates and ring-mqtt writes
     back. That is how Home Assistant's own Ring entry holds its token, in
     `/config/.storage`. Neither passes through SOPS.
   - **The first sign-in:** made by hand, once, with Ring's 2FA:
     `docs/runbooks/connect-the-ring-alarm.md`.
6. **Alarm only.** `enable_cameras` is false. The cameras and doorbell stay the
   core integration's, so ring-mqtt neither lists them nor starts its bundled
   go2rtc, and nothing listens on 8554. Its token web UI on 55123 runs only
   when it has no token, is not exposed, and is not used.
7. **No disarm code in Home Assistant.** `disarm_code` is empty, so anyone
   signed in to Home Assistant can arm and disarm. They are the household,
   the same people the Ring app lets do it. A code would also have to sit in
   any automation that disarms. This ADR adds no automation that arms or
   disarms; that is a later, separate change.
8. **Both are booted under their hardening in CI.** Mosquitto's `smoke.sh`
   signs in as both users, is refused with a wrong password and with none,
   and checks the ACL. ring-mqtt's checks that it read its config through the
   link and reached the point of asking for a token.

No firewall rule changes. ring-mqtt talks to Ring's cloud from `trinity`,
as Home Assistant's Ring integration already does, and not to the base
station.

## Alternatives considered

- **Pair the sensors to Home Assistant directly over Z-Wave.** The alarm's
  sensors are Z-Wave, and a USB stick with Z-Wave JS would bring them in with
  no cloud at all. But it takes them off the Ring Alarm: the base station,
  Ring's app, its arming and any monitoring stop working, and the keypads,
  which only work with the base station, become ornaments. That is a
  decision about the alarm, not about Home Assistant. Declined, and the one
  this ADR's consequences point to if Ring's cloud ever becomes the problem.
- **ring-mqtt as published, through its s6 init and as root.** It is what
  upstream documents. It needs root to start, and the update-on-start branch
  path is one setting away. Declined for point 4.
- **A broker on the `sensitive` network** with passwords alone. It is one
  network fewer, but every other service on the tier would be one leaked
  password away from the alarm's arming topic. Declined for point 1.
- **Leave the alarm in the Ring app.** It works today, but the sensors would
  never reach an automation, and Home Assistant would stop being the one
  place the house is seen. Declined at the household's request.

## Consequences

- **The tier's first broker, and its second network.** `compose.yaml` marks it
  DIFFERENCE 14. Anything that later wants MQTT joins `mqtt`, with a user and
  an ACL entry of its own, rather than widening an existing one.
- **Community code holds the owner's Ring sign-in.** ring-mqtt is one author's
  project, built on `ring-client-api`, another's. It runs with the Ring
  location owner's refresh token, which can do anything that owner can,
  including arming, disarming and changing every camera's settings. That
  matches what Home Assistant's core integration already holds, and it is
  accepted on the same terms:
  - pinned by digest;
  - non-root, read-only, with no capabilities;
  - no inbound port;
  - reachable only by Home Assistant over an authenticated, ACL'd broker.

  The token is listed in Ring's Control Center as `ring-mqtt-xxxxx`, where it
  can be revoked.
- **ring-mqtt-data is not backed up.** `scripts/backup-volumes.sh` lists it as
  disposable: Ring rotates the token as it is used, so a nightly copy is
  usually already spent. A rebuild is one sign-in with the runbook.
- **Two more images to keep current.** ring-mqtt's newest release was 5.9.3, on
  2026-03-09, seven months before this ADR. The project answers issues but
  releases slowly. A long silence while Ring changes its API is the main
  risk.
- **The alarm's devices appear only after the runbook.** Until then ring-mqtt
  runs, waits for a token and logs that it is waiting. Mosquitto runs with no
  clients.
- **Reopened by:**
  - a core Home Assistant integration that speaks the Ring Alarm, which
    retires both services;
  - ring-mqtt going unmaintained while Ring changes the alarm API, which
    makes the Z-Wave alternative the live one;
  - the household dropping the Ring Alarm, which makes this moot.
