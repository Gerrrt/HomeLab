# Screenshots

[![part of README.md](https://img.shields.io/badge/part%20of-README.md-30363d?style=plastic)](../../README.md)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?style=plastic&logo=grafana&logoColor=white)](https://grafana.com/oss/grafana/)

Dashboard screenshots go here and are referenced from the root `README.md`.

Every one is a real render of the real stack. A mocked-up dashboard image in a
monitoring repository is worse than none, because it cannot be checked against
the JSON that produced it — so an image that cannot honestly be captured is left
out rather than illustrated.

## What is here now

Six images, captured in a single run on 2026-10-10 over a 24-hour window. One
run rather than six afternoons: a set shot at the same moment is comparable,
and a gap in one of them is visible against the others.

Which file holds which dashboard is in the table under "Capturing them" below,
because that pairing is defined in the capture script rather than here.

Some things in them are real and should not be tidied away. A screenshot of a
stack with nothing wrong would be the less honest picture, so each of these is
recorded here instead of being cropped out:

- **`host-overview.png`:** the alert table shows `HostBatteryTempNotMeasured`
  for `oracle` and `prometheus`. It is `info` on purpose: neither laptop pack
  reports a temperature, and the rule says so for as long as that is true (the
  comment above it in `host.rules.yaml` has why). The `HypervisorGuestStopped`
  rows for the Packer templates the 2026-10-04 set showed are gone
  ([#885](https://github.com/Gerrrt/HomeLab/issues/885)).
- **`docker-containers.png`:** `memtest-ag2` and `memtest-ag3` lead three of
  the legends. They were scratch containers measuring an image's memory, and
  were removed before this was written.
- **`internet.png`:** this is its first capture. The download dips near 20:00,
  07:00 and late morning and the 32 % loss spike near 09:00 are real tests and real loss,
  not render artefacts; WAN receive errors stayed at zero throughout, so they
  are not the #914 cable.

The 2026-10-04 set recorded four panel faults that this one shows fixed:
*Firewall uptime* reading 12 years ([#886](https://github.com/Gerrrt/HomeLab/issues/886)),
the firewall's *Filesystem usage* saying *No data* ([#887](https://github.com/Gerrrt/HomeLab/issues/887)),
raw `cpqHeTemperature` column names in the iLO *Hardware health* table
([#888](https://github.com/Gerrrt/HomeLab/issues/888)), and *Input frequency*
reading 600 ([#889](https://github.com/Gerrrt/HomeLab/issues/889)). Every image in
that set also lost its last legend row: the kiosk footer covered the bottom
~40px, which the height formula did not allow for until this capture
([#924](https://github.com/Gerrrt/HomeLab/issues/924)).

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
six of the eight dashboards over a 24-hour window, and stops the renderer
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
| `internet.png` | Internet |

Height is derived per dashboard from its own JSON, so adding a panel makes the
screenshot taller instead of pushing the new panel out of frame. The ceiling is
`BROWSER_MAX_HEIGHT` on the renderer (7000 in `compose.yaml`), above which a
request is silently clamped and the crop comes back. `MAX_HEIGHT` in the script
must equal it. A dashboard taller than that is refused rather than cropped:
the script stops before rendering anything, and `capture-screenshots.sh
--check`, run in CI, fails the PR that grows it. To move the ceiling, raise
both numbers together, after measuring the pinned renderer at the new height
([#954](https://github.com/Gerrrt/HomeLab/issues/954) has how).

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

There are eight dashboards and six screenshots. `homelab-logs` and
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
