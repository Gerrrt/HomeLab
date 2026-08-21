# Screenshots

Dashboard screenshots go here and are referenced from the root `README.md`.

They are deliberately absent rather than faked — a mocked-up dashboard image in
a monitoring repository is worse than none, because it cannot be checked against
the JSON that produced it.

## What is here now

Two of the four, not four. `network-snmp.png` and `ups-power.png` pass the
checklist at the bottom of this file. `host-overview.png` and
`docker-containers.png` do not yet, and are absent rather than committed with a
note apologising for them:

| File | Why it is not here |
| --- | --- |
| `host-overview.png` | A 14-hour hole, 02:00 to 16:00, where the agent was down. Half the panels are a flat line — the exact thing "The window matters" below warns about. |
| `docker-containers.png` | cAdvisor only started reporting correctly in [#62](https://github.com/Gerrrt/HomeLab/pull/62), so 22 of the 24 hours are empty. |

Both are a re-shoot, not a repair: run `make screenshots` again once the stack
has a clean day behind it. Tracked in
[#12](https://github.com/Gerrrt/HomeLab/issues/12).

The Container inventory panel on the Docker dashboard used to publish the
absolute path of `compose.yaml` — and so a username — because it excluded
fields by name and cAdvisor kept adding new ones. It now filters to an
allowlist. That was caught by this checklist working, which is the argument for
having it.

## Capturing them

```bash
make up            # the stack has to be running
make screenshots
```

`scripts/capture-screenshots.sh` starts the `capture` profile's renderer, shoots
four of the five dashboards over a 24-hour window, and stops the renderer again.
Nothing is left running and `docker compose ps` shows the same six services
afterwards.

Filenames and dashboards are paired in the script, not here, so they cannot
drift:

| File | Dashboard |
| --- | --- |
| `host-overview.png` | Host Overview |
| `docker-containers.png` | Docker Containers |
| `network-snmp.png` | Network & Firewall |
| `ups-power.png` | UPS & Power |

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

## The Logs dashboard is not captured

There are five dashboards and four screenshots. `homelab-logs` is excluded on
purpose.

Its Authentication log panel renders `auth.log` verbatim — real usernames, real
source addresses, real session IDs — and so do the other two stream panels. That
is not a bad time range or an unlucky window; showing log lines is the entire
point of the dashboard, so there is no capture of it that does not publish them.

Excluding it in the script beats capturing it and relying on someone noticing.
The check that catches this is the one that runs every time, not the one that
depends on reading carefully at the end of a long afternoon.

If it is ever wanted, the thing to build first is redaction — not a reminder.

## Before publishing

These are going into a public repository. Check each image for:

- Full MAC addresses in table panels
- The WAN IP address in any interface panel
- Hostnames or usernames anywhere in a table or legend
- Anything in a Grafana annotation or query bar you did not mean to publish

Crop or blur rather than re-shooting — it is easier to be thorough. There is no
image editor on the monitoring host; do it wherever you are reading this.
