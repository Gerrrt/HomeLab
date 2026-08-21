# Screenshots

Dashboard screenshots go here and are referenced from the root `README.md`.

They are deliberately absent rather than faked — a mocked-up dashboard image in
a monitoring repository is worse than none, because it cannot be checked against
the JSON that produced it.

## Capturing them

```bash
make up            # the stack has to be running
make screenshots
```

`scripts/capture-screenshots.sh` starts the `capture` profile's renderer, shoots
all five dashboards over a 24-hour window, and stops the renderer again. Nothing
is left running and `docker compose ps` shows the same six services afterwards.

Filenames and dashboards are paired in the script, not here, so they cannot
drift:

| File | Dashboard |
| --- | --- |
| `host-overview.png` | Host Overview |
| `docker-containers.png` | Docker Containers |
| `network-snmp.png` | Network & Firewall |
| `ups-power.png` | UPS & Power |
| `logs-explorer.png` | Logs |

Height is derived per dashboard from its own JSON, so adding a panel makes the
screenshot taller instead of pushing the new panel out of frame.

Then uncomment the screenshot block in the root `README.md`.

### The window matters

The renderer captures `now-24h` to `now`, so **anything that was broken in the
last day is in the picture**. After fixing a collection fault, wait a full day
before shooting or the image publishes the outage: a flat line across half the
host dashboard reads as "this stack does not work", which is the opposite of
what the screenshot is for.

`make screenshots` is cheap and repeatable. Re-running it tomorrow is the
correct fix for a bad window, not cropping.

## Before publishing

These are going into a public repository. Check each image for:

- Full MAC addresses in table panels
- The WAN IP address in any interface panel
- Hostnames or usernames in log lines
- Anything in a Grafana annotation or query bar you did not mean to publish

The **Logs** dashboard is the one that reliably fails this check. Its
Authentication log panel renders `auth.log` verbatim, which means real
usernames, real source addresses and real session IDs. Read that image properly
before it goes anywhere.

Crop or blur rather than re-shooting — it is easier to be thorough. There is no
image editor on the monitoring host; do it wherever you are reading this.
