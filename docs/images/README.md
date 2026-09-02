# Screenshots

Dashboard screenshots go here and are referenced from the root `README.md`.

Every one is a real render of the real stack. A mocked-up dashboard image in a
monitoring repository is worse than none, because it cannot be checked against
the JSON that produced it — so an image that cannot honestly be captured is left
out rather than illustrated.

## What is here now

Four images, captured in a single run on 2026-08-22 over a 24-hour window. One
run rather than four afternoons: a set shot at the same moment is comparable,
and a gap in one of them is visible against the others.

Which file holds which dashboard is in the table under "Capturing them" below,
because that pairing is defined in the capture script rather than here.

Two things in them are real and should not be tidied away on the next capture.
`network-snmp.png` shows `IloBatteryCondition` firing on `shiva` — that was a
genuine hardware fault, tracked in
[#76](https://github.com/Gerrrt/HomeLab/issues/76), and a screenshot of a stack
with nothing wrong would have been the less honest picture. The pack was
replaced on 2026-09-02, so the next capture will legitimately show it quiet. `docker-containers.png`
carries a `renderer` series in two legends: that is the `capture` profile
container taking the screenshot, which exists only for the duration of a
capture, which is why the inventory below it lists six containers and not seven.

`ups-power.png` is out of date in one specific way, and knowingly so. It was
shot before a battery pack was fitted to `mjolnir` on 2026-08-28, so it still
shows the old "No battery is installed in this UPS" banner and the
"(fabricated — no battery fitted)" panel titles. It stays in place rather than
being deleted — it is a real render of what the dashboard said that day, and the
root `README.md` says underneath it when it was taken and what has changed
since. Re-shoot it once the pack has passed a self-test, when the panels will
read measured values instead of unproven ones.

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
five of the seven dashboards over a 24-hour window, and stops the renderer
again. Nothing is left running and `docker compose ps` shows the same six
services afterwards.

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

There are seven dashboards and four screenshots. `homelab-logs` and
`homelab-security` are excluded on purpose and always will be. `homelab-stack`
is in the capture set and has simply not been shot yet.

### `homelab-stack` is wired for capture and is only unshot

It arrived with [#81](https://github.com/Gerrrt/HomeLab/issues/81) and carries
no log lines, no usernames and no addresses beyond the container names and
service ports already published throughout this repository. Nothing about it
needs redaction, and it is in `DASHBOARDS` in `scripts/capture-screenshots.sh` —
it wants a run of `make screenshots` with a full day of history behind it so the
panels are not half empty.

It is left out of this set rather than shot in a hurry because the window
matters more for this dashboard than for any other: it draws the collection path
itself, so a capture taken shortly after a deploy publishes the deploy's own gap
as though it were the steady state.

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
