# Runbook: Connect the Ring Alarm

Sign ring-mqtt in to Ring once and point Home Assistant at its broker, so the
Ring Alarm's base station, sensors, keypads and arming appear in Home
Assistant ([ADR-0104](../adr/0104-bring-the-ring-alarm-into-home-assistant-through-ring-mqtt.md)).

**Target:** `trinity` (10.0.99.40), and Home Assistant's web UI
**Time:** ~15 minutes
**Needs:** the Ring location owner, with their phone for Ring's 2FA code
**Reversible:** delete the MQTT integration in Home Assistant, and revoke
`ring-mqtt-xxxxx` in Ring's Control Center

---

## Why this exists

ring-mqtt and Mosquitto start with `make up STACK=sensitive` like everything
else on the tier, but ring-mqtt cannot sign in to Ring on its own: Ring wants
a password and a 2FA code from a person. Until that happens it runs, logs
*"No refresh token was found"* every start, and publishes nothing. And Home
Assistant's MQTT integration is set up in its UI, not in YAML, so it is a
step too.

The sign-in must be the **Ring location owner's** account. A shared user's
token can read the alarm but Ring refuses its setting changes, and Ring's
newer shared-access role returns no devices at all (ADR-0104's context).

## 1. Start the two services

From the repository root on `trinity`, on a `main` that has ADR-0104:

```bash
make up STACK=sensitive
```

```bash
docker ps --filter name=sensitive-mosquitto --filter name=sensitive-ring-mqtt --format '{{.Names}} {{.Status}}'
```

Mosquitto reads `(healthy)`. ring-mqtt reads `Up`, and its log says it is
waiting for a token:

```bash
docker logs --tail 5 sensitive-ring-mqtt
```

## 2. Sign ring-mqtt in to Ring

Run ring-mqtt's own sign-in tool inside the running container. It asks for
the owner's Ring email, password, and then the code Ring sends:

```bash
docker exec -it sensitive-ring-mqtt node /app/ring-mqtt/init-ring-mqtt.js
```

It ends with *"State file /data/ring-state.json saved with updated refresh
token"* and a device name, `ring-mqtt-` and five characters. That name
appears in the Ring app under Control Center → Authorized Client Devices,
which is where this sign-in is revoked.

Restart ring-mqtt so it starts with the token:

```bash
docker restart sensitive-ring-mqtt
```

```bash
docker logs --since 2m sensitive-ring-mqtt 2>&1 | grep -E 'Successfully|Found|Device Discovery|MQTT'
```

It should list the base station, each sensor and keypad, then *"Device
Discovery Complete!"* and a successful MQTT connection. A broker refusal
here means `MQTT_RING_PASSWORD` and the running broker disagree: run
`make up STACK=sensitive` again so both start from the same SOPS file.

## 3. Add the MQTT integration in Home Assistant

Read Home Assistant's broker password on `trinity`. It prints to your
terminal only, so don't paste it anywhere else:

```bash
sops -d --extract '["MQTT_HA_PASSWORD"]' secrets/sensitive.sops.yaml
```

Then in Home Assistant: **Settings → Devices & services → + Add integration →
MQTT**, choose to enter the broker by hand, and fill in:

| Field | Value |
| --- | --- |
| Broker | `mosquitto` |
| Port | `1883` |
| Username | `homeassistant` |
| Password | the value printed above |

Leave TLS off; the broker is only on the internal `mqtt` network.

## 4. Check what arrived

**Settings → Devices & services → MQTT** lists one device per alarm
component: the base station's alarm panel (`alarm_control_panel`), each
contact and motion sensor, each keypad with its battery, and any range
extender. Open a door with a contact sensor: its entity turns *open* within
a second or two.

Then label what automations will use, in the UI, as the other packages do:
a label never reveals which sensor is on which door.

## After adding, re-pairing or resetting alarm devices

ring-mqtt asks the base station for its device list once, when it connects
at start. A broker reconnect or Home Assistant's birth message makes it
republish the devices it already holds, not ask again, so a sensor or keypad
paired after the start is not noticed until ring-mqtt restarts. Once the Ring
app shows the base station *Online* and every new device joined, restart
ring-mqtt with step 2's `docker restart` and watch its log for one *"New
device:"* line per device and *"Device Discovery Complete!"*.

*"No assets (alarm hubs or beam bridges) found"* means Ring listed no base
station for the location at that moment, as it does while one is being
enrolled. ring-mqtt exits on it and Docker restarts it; a pass that then ends
in *"No devices found"* stays empty until the restart above.

A base station that was reset or replaced comes back with new device ids,
and so do the devices paired to it. Home Assistant keeps the old devices,
*unavailable*, and gives the new entities a `_2` suffix. Delete the stale
devices under **Settings → Devices & services → MQTT** *before* the restart;
any label or area set on them goes with them. If the ids did not change,
discovery recreates them as they were.

The cameras are the core Ring integration's, which lists its devices once,
at setup. A camera added in the Ring app appears after **Settings → Devices
& services → Ring → ⋮ → Reload**.

## Rotating a broker password

Generate a new value with `scripts/gen-secret.sh`, put it in
`secrets/sensitive.sops.yaml` with `make secrets-edit STACK=sensitive`, and
run `make up STACK=sensitive`. For `MQTT_HA_PASSWORD`, also open the MQTT
integration's options in Home Assistant and enter the new value there.

## Rebuilding

`ring-mqtt-data` is not backed up (ADR-0104). On a rebuilt `trinity`, or if
the token is revoked or expires, repeat step 2. Revoke the old
`ring-mqtt-xxxxx` in Ring's Control Center when you do.
