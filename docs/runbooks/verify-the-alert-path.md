# Verify the alert path

**Who watches the thing that tells you something is wrong.**

`AlertmanagerNotificationsFailing` catches delivery *errors* — a refused
connection, a 5xx. It cannot catch a webhook URL that is well-formed, reachable,
and pointed at nothing. A 200 into a deleted ntfy topic is a successful
notification by every measure Alertmanager has, and the only symptom is that
alerts stop arriving, which is also what a healthy week looks like.

This lab has already lived through that failure: the webhook was the
`ntfy.example.invalid` placeholder for the entire life of the stack and nothing
noticed. See [#67](https://github.com/Gerrrt/HomeLab/issues/67).

## The two halves

`prometheus/rules/watchdog.rules.yaml` holds one rule, `Watchdog`, whose
expression is `vector(1)`. It fires unconditionally and forever. Its firing
carries no information; **its absence is the entire signal.**

Alertmanager sends it to two places, from one rule, via the only `continue: true`
in the routing tree:

| Route | Destination | Cadence | Catches |
| --- | --- | --- | --- |
| `heartbeat` | external cron-monitor ping | every 5m | Prometheus stopped evaluating, Alertmanager died, the host lost outbound network |
| `default` | the real alert channel | every 24h | the alert channel itself is a 200 into nothing |

Both halves are needed, and neither substitutes for the other. The heartbeat
route proves delivery to a *different* URL than real alerts use, so it cannot
see a deleted ntfy topic. The daily route travels the identical URL your warnings
travel, but nothing machine-checks its absence — you do.

## Setting up the external watcher

The watcher has to live somewhere other than the monitoring host. A watcher on
this host fails at the same moment as the thing it is watching, which is not
watching at all.

A cron-monitor / heartbeat service is the least effort:
[healthchecks.io](https://healthchecks.io) (free tier is enough for one check),
Cronitor, or an Uptime Kuma "push" monitor on any other machine.

1. Create one check. Name it so a 3am notification is self-explanatory —
   `homelab alerting path`, not `check 1`.
2. Set **period 5m** and **grace 15m**. See "The timing is coupled" below before
   changing either.
3. Point the check's own notification at something that is **not** the webhook
   this stack uses. If both go to the same ntfy topic, a deleted topic takes out
   the alert and the warning about the alert together. Email is fine here; it
   fails independently.
4. Put the ping URL into the encrypted secrets file and render:

   ```bash
   make secrets-edit     # set ALERTMANAGER_HEARTBEAT_URL
   make up
   ```

5. Confirm the check goes green within one `repeat_interval`.

## The timing is coupled

Alertmanager sends the first notification after `group_wait` and then re-sends
every `repeat_interval`. The heartbeat route uses `group_wait: 0s`,
`group_interval: 1m` and `repeat_interval: 5m`.

- **`group_interval` < `repeat_interval`, on the heartbeat route specifically.**
  A group is only reconsidered on a `group_interval` tick, and only then asks
  whether `repeat_interval` has elapsed. Equal values make the +5m tick land
  fractionally before the deadline it tests, so it skips and fires at +10m: a
  heartbeat at half its advertised rate, every notification a success, nothing
  failing. This is not hypothetical — the route shipped with both at 5m and the
  live stack measured 600s between pings (#120). Verify the real rate rather
  than reading it off the config:

  ```bash
  curl -s --data-urlencode \
    'query=600 / increase(alertmanager_notifications_total{integration="webhook"}[6h])' \
    http://localhost:9090/api/v1/query
  ```

  That is seconds per notification over six hours; it should be near 300, and
  near 600 means this bug is back. Note it counts every webhook receiver, so a
  noisy warning period pulls it below 300 — read it on a quiet stack.
- **External period ≥ `repeat_interval`.** A period shorter than 5m expects pings
  that are never sent, and the check alarms on a perfectly healthy stack.
- **External grace ≥ 2 × `repeat_interval`.** One missed ping is a hiccup — a
  reload, a restart, a slow scrape. Two consecutive misses is a fault. A grace
  under 10m turns every `make reload` into a page.
- **External grace > the weekly backup's downtime.** `homelab-backup-volumes`
  quiesces the stack every Sunday at 03:30, which stops Prometheus evaluating
  and therefore stops this heartbeat for the length of the archive. A backup
  that outruns the grace pages you at 03:31 for a backup that worked. The run is
  normally about ninety seconds against a 15m grace — check yours with
  `grep downtime backups/volumes/*/MANIFEST | tail -1` rather than assuming.
  This is why that timer is the only one with `RandomizedDelaySec=0`: a
  randomised start would make the expected gap unstateable. See
  [`schedule-maintenance.md`](schedule-maintenance.md).

Change `repeat_interval` in `alertmanager/alertmanager.yaml` and the external
check's period and grace move with it — and `group_interval` has to stay under
it. Nothing enforces that from here, which is why it is written down.

## Confirming it actually works

Do not trust a green check you have never seen go red.

```bash
docker stop alertmanager
# wait out the grace window — 15m by default
# the external check must report DOWN and notify you
docker start alertmanager
# it must return to green within one repeat_interval
```

Doing this once is worth more than the rule is. A dead man's switch nobody has
ever seen trip is indistinguishable from a dead man's switch that does not work.

To confirm the daily half without waiting a day, temporarily lower
`repeat_interval` on the second Watchdog route, `make reload`, and check the
notification arrives on your normal alert channel:

```bash
amtool alert query --alertmanager.url=http://localhost:9093 alertname=Watchdog
```

Put it back to `24h` afterwards.

## Reading the failure

| What you see | What it means |
| --- | --- |
| External check DOWN, daily heartbeat still arriving | The heartbeat URL is wrong or that specific destination is unreachable. The alert path itself is fine. |
| External check UP, daily heartbeat stopped | The **real alert channel** is broken — a deleted topic, a rotated URL. This is #67's original failure, and every real alert is being lost right now. |
| Both stopped | Prometheus, Alertmanager, or this host. Start with `docker compose ps` and `curl -s localhost:9093/-/healthy`. |
| Both fine, but you expected an alert about something else | Not this runbook. The path works; check the rule, then the routing tree with `amtool config routes test`. |

The second row is the one this whole arrangement exists for, and it is the one
that looks like nothing is wrong.

## Related

- `prometheus/rules/watchdog.rules.yaml` — the rule, and why `severity: none` is
  load-bearing rather than a placeholder
- `loki/rules/security.rules.yaml` — `FirewallLogsStopped`, and the comment
  explaining why Suricata has no log-based equivalent;
  `prometheus/rules/ids.rules.yaml` is the process-table rule that answers it.
  Same reasoning, applied to a different silent component
- [`docs/observability.md`](../observability.md#routing) — the full routing table
