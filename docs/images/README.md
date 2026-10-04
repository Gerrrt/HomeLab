# Screenshots

[![part of README.md](https://img.shields.io/badge/part%20of-README.md-30363d?style=plastic)](../../README.md)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/grafana/)

Dashboard screenshots go here and are referenced from the root `README.md`.

Every one is a real render of the real stack. A mocked-up dashboard image in a
monitoring repository is worse than none, because it cannot be checked against
the JSON that produced it — so an image that cannot honestly be captured is left
out rather than illustrated.

## What is here now

Five images, captured in a single run on 2026-10-04 over a 24-hour window. One
run rather than five afternoons: a set shot at the same moment is comparable,
and a gap in one of them is visible against the others.

Which file holds which dashboard is in the table under "Capturing them" below,
because that pairing is defined in the capture script rather than here.

Some things in them are real and should not be tidied away. A screenshot of a
stack with nothing wrong would be the less honest picture, so each of these is
recorded here instead of being cropped out:

- **`host-overview.png`:** the alert table shows `HypervisorGuestStopped` for
  the Packer templates 901 and 911. Templates never run, so this is the rule
  needing a template exclusion, not a guest that died ([#885](https://github.com/Gerrrt/HomeLab/issues/885)).
- **`network-snmp.png`:**
  - *Firewall uptime* reads 12 years. `pfStatusRuntime` is in hundredths of a
    second and the panel treats it as seconds, so the value is about 44 days
    ([#886](https://github.com/Gerrrt/HomeLab/issues/886)). The panel now divides by
    100; the image predates the fix.
  - The firewall's *Filesystem usage* panel says *No data*. #873 added it, and
    on the day of the capture the running stack was not yet collecting
    `hrStorage` from `morpheus`: its rendered `snmp.yaml` predated the generator
    change. It was re-rendered and the exporter recreated the same day
    ([#887](https://github.com/Gerrrt/HomeLab/issues/887)), and the panel
    has had data since.
  - The iLO *Hardware health* table shows raw `cpqHeTemperature` column names
    ([#888](https://github.com/Gerrrt/HomeLab/issues/888)).
  - The `IloBatteryCondition` fault the 2026-08-22 capture showed is gone: the
    pack was replaced on 2026-09-02.
- **`ups-power.png`:**
  - It now shows measured values under the banner that records the pack being
    fitted and proven.
  - *Input frequency* reads 600: the card reports tenths of a hertz and the
    panel did not divide ([#889](https://github.com/Gerrrt/HomeLab/issues/889)). It now divides by 10;
    the image predates the fix.
- **`observability-stack.png`:** this is its first capture. The step in
  ingestion near 22:00 is the stack being redeployed two hours before the
  shot.

The set before this one was shot on 2026-08-22 and showed `mjolnir` with no
battery fitted. The Container inventory panel in an earlier set published the
absolute path of `compose.yaml`, and so a username, because it excluded fields
by name and cAdvisor kept adding new ones. It now filters to an allowlist. That
was caught by the checklist below, which is the argument for having it.

## Capturing them

```bash
make up            # the stack has to be running
make screenshots
```

`scripts/capture-screenshots.sh` starts the `capture` profile's renderer, shoots
five of the seven dashboards over a 24-hour window, and stops the renderer
again. Nothing is left running, and `docker compose ps` shows the same services
afterwards as before. The renderer carries `homelab.logs=off`, the label the
estate's other throwaway containers use. That keeps `ContainerGone` from paging
for a week about a container that was meant to go
([#883](https://github.com/Gerrrt/HomeLab/issues/883)). Before #883 a capture
needed a silence on `ContainerGone{name="renderer"}`.

Filenames and dashboards are paired in the script, not here, so they cannot
drift:

| File | Dashboard |
| --- | --- |
| `host-overview.png` | Host Overview |
| `docker-containers.png` | Docker Containers |
| `network-snmp.png` | Network & Firewall |
| `ups-power.png` | UPS & Power |
| `observability-stack.png` | Observability Stack |

Height is derived per dashboard from its own JSON, so adding a panel makes the
screenshot taller instead of pushing the new panel out of frame — up to
`BROWSER_MAX_HEIGHT` on the renderer, above which the request is silently
clamped and the crop comes back. `homelab-stack` is 4582px against a default of
3000, which is why `compose.yaml` raises it and `MAX_HEIGHT` in the script
matches. A dashboard that outgrows 5000 needs both moved again.

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

## What is not captured, and why

There are seven dashboards and five screenshots. `homelab-logs` and
`homelab-security` are excluded on purpose and always will be.

### `homelab-logs` is excluded on purpose

Its Authentication log panel renders `auth.log` verbatim — real usernames, real
source addresses, real session IDs — and so do the other two stream panels. That
is not a bad time range or an unlucky window; showing log lines is the entire
point of the dashboard, so there is no capture of it that does not publish them.

Excluding it in the script beats capturing it and relying on someone noticing.
The check that catches this is the one that runs every time, not the one that
depends on reading carefully at the end of a long afternoon.

If it is ever wanted, the thing to build first is redaction — not a reminder.

### `homelab-security` is excluded for the same reason

It arrived with [#82](https://github.com/Gerrrt/HomeLab/issues/82) and it is the
Logs dashboard's argument again, in a segment where the addresses matter more.
Three of its panels exist to show them: *Top blocked source addresses* is a
table of real source IPs, and the priority-1 Suricata stream and the
terminal-segment violations stream both render log lines verbatim. A window with
nothing in those panels is not a safe capture either — it is a picture of a
dashboard with its point removed.

Suricata makes it worse than `homelab-logs` rather than merely equal to it.
Alert bodies carry raw packet bytes, MAC addresses among them, and
[`SECURITY.md`](../../SECURITY.md) requires MACs truncated to an OUI anywhere
they are published. That is a per-line edit on a stream panel, which is not a
checklist item — it is redaction, and the same conclusion follows: build it
first, or leave the dashboard out.

## Before publishing

These are going into a public repository. Check each image for:

- Full MAC addresses in table panels
- The WAN IP address in any interface panel
- Hostnames or usernames anywhere in a table or legend
- Anything in a Grafana annotation or query bar you did not mean to publish

Crop or blur rather than re-shooting — it is easier to be thorough. There is no
image editor on the monitoring host; do it wherever you are reading this.
