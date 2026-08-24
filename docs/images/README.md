# Screenshots

Dashboard screenshots go here and are referenced from the root `README.md`.

Every one is a real render of the real stack. A mocked-up dashboard image in a
monitoring repository is worse than none, because it cannot be checked against
the JSON that produced it — so an image that cannot honestly be captured is left
out rather than illustrated.

## What is here now

All four, captured in a single run on 2026-08-22 over a 24-hour window. One run
rather than four afternoons: a set shot at the same moment is comparable, and a
gap in one of them is visible against the others.

Which file holds which dashboard is in the table under "Capturing them" below,
because that pairing is defined in the capture script rather than here.

Two things in them are real and should not be tidied away on the next capture.
`network-snmp.png` shows `IloBatteryCondition` firing on `shiva` — that is a
genuine hardware fault, tracked in
[#76](https://github.com/Gerrrt/HomeLab/issues/76), and a screenshot of a stack
with nothing wrong would be the less honest picture. `docker-containers.png`
carries a `renderer` series in two legends: that is the `capture` profile
container taking the screenshot, which exists only for the duration of a
capture, which is why the inventory below it lists six containers and not seven.

The Container inventory panel used to publish the absolute path of
`compose.yaml` — and so a username — because it excluded fields by name and
cAdvisor kept adding new ones. It now filters to an allowlist. That was caught
by this checklist working, which is the argument for having it.

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

Overwrite the existing files in place. The root `README.md` references them
by name, so a re-shoot needs no edit there — but it does need the checklist
at the bottom of this file running over it again before it is committed.

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
