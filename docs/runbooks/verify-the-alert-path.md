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

## The ruler's half

The heartbeat proves Prometheus's path, and Loki's ruler evaluates every
security alert on a path of its own. `LokiRulerWatchdog` fires forever in
Loki and is routed to `null`. Prometheus watches the ruler's sent counter,
and `LokiRulerSilent` pages if it stops climbing
([#837](https://github.com/Gerrrt/HomeLab/issues/837)). To see it working,
on the monitoring host:

```bash
curl -s localhost:3100/prometheus/api/v1/alerts | grep -c LokiRulerWatchdog
```

The command should print `1`. In Prometheus, `increase(loki_prometheus_notifications_sent_total[15m])`
should be above zero.

## Where the real alerts go

Since [#136](https://github.com/Gerrrt/HomeLab/issues/136) the three real
channels are delivered to the sensitive tier's own ntfy, at
`https://ntfy.matrix.elysium` on `trinity`. They are no longer delivered to
ntfy.sh, with one deliberate exception:

| Receiver | In-house ntfy | ntfy.sh | Why |
| --- | --- | --- | --- |
| `default` | yes | no | A slow scrape can wait until the phone is home |
| `urgent` | yes | **yes** | A page has to reach a phone that is not on the home network |
| `security` | yes | **yes** | Likewise |
| `heartbeat` | **never** | no | healthchecks.io. A watcher inside the house fails with the house |

The ntfy.sh copies exist because nothing about the tier is exposed. A phone
off the home network cannot reach `trinity`, since the WireGuard path
([ADR-0042](../adr/0042-terminate-the-remote-path-on-the-lab-and-route-it.md))
goes to the lab and not here. So an in-house-only page would wait in the cache
until the phone came home. With the heartbeat gone from ntfy.sh (#407), two
channels that fire on real faults sit far inside its free budget.

Two consequences are worth holding in mind:

- **The daily Watchdog proves the in-house path, not the ntfy.sh copies.** The
  24h route goes to `default`, which has no external twin. The copies are
  proved by the cutover drill below and by every real page after it. The
  comment on that route in `alertmanager.yaml` says why a daily Watchdog on the
  loud channels would be worse than the gap.
- **A dead in-house ntfy still reaches you.** It surfaces as
  `EndpointUnreachable` for `ntfy` (the blackbox probe) and as
  `AlertmanagerNotificationsFailing`, once anything tries to page. Both are
  critical, so both route to `urgent`, whose ntfy.sh copy does not depend on
  the thing that failed. `scripts/validate.sh` pins those two routes.

## Cutting over to the in-house ntfy

Run this once, when #136 is deployed. Do it in order: each step's check is
what makes the next one mean anything.

> **Done 2026-09-28/29**, on `trinity` and `prometheus`, with both phones in
> hand ([#136](https://github.com/Gerrrt/HomeLab/issues/136)). Times are UTC,
> read from Caddy's access log, ntfy's cache and Prometheus's `ALERTS`:
>
> | | |
> | --- | --- |
> | ntfy up; leaf issued by step-ca, verified against `tier-ca.pem` | 2026-09-28 21:59:03 |
> | Deny-all from outside: anonymous publish and read `403`, sign-up refused | 2026-09-28, step 4 |
> | Test publish with Alertmanager's token, received on both phones; the Pixel trusts the user-installed root | 2026-09-28, step 5 |
> | Probe from the live exporter: `probe_success 1`, leaf expiry 2026-10-05 21:59:04 | 2026-09-28, step 7 |
> | First delivery from `prometheus` through the in-house path (`template=alertmanager`, before #716) | 2026-09-29 01:29:53 |
> | First delivery rendered by `homelab.yml` | 02:00:02 |
> | Synthetic page resolved, in-house, new format (`✅ Resolved: …`) | 02:07:05 |
> | Synthetic page firing, **seen on the ntfy.sh copy with Wi-Fi off**, in the same format (#719) | 03:11:18 |
> | `docker stop sensitive-ntfy` | 03:12:05 |
> | Probe fails | 03:12:25 |
> | `EndpointUnreachable` for `ntfy` pending | 03:13:25 |
> | `EndpointUnreachable` fires | 03:18:26 |
> | **Page received on the ntfy.sh urgent topic** | 03:18 |
> | `AlertmanagerNotificationsFailing` pending, `integration="webhook"` (the in-house half failing) | 03:19:26 |
> | `docker start sensitive-ntfy`; healthy | 03:20:07; 03:20:14 |
> | Held-back notifications delivered in-house on Alertmanager's retries, including the drill's own page | 03:20:29, 03:20:42 |
> | `EndpointUnreachable` resolves | 03:21 (in-house `✅ Resolved` at 03:23:29) |
> | `AlertmanagerNotificationsFailing` fires, `reason="serverError"` (Caddy's 502 for the stopped upstream), with ntfy already back | 03:24:26, delivered 03:24:32 |
>
> What the cutover found, each fixed on the day:
>
> - **Enabling the probe paged `urgent` within ten minutes**, with "ntfy's
>   certificate has 7 days left" (02:04:29). The tier's leaves always last
>   seven days, so they were always inside the estate's 7-day rule. The
>   estate's two expiry rules now skip `renewal: acme` targets, and
>   `TlsAcmeRenewalStalled` watches those instead
>   ([#718](https://github.com/Gerrrt/HomeLab/pull/718)).
> - **`make secrets-edit` leaves the deployment checkout dirty.** The
>   encrypted file is tracked. On `prometheus` that raised `DeployDrifted` and
>   stopped convergence for about four hours. The edited files were committed
>   encrypted ([#717](https://github.com/Gerrrt/HomeLab/pull/717),
>   [#720](https://github.com/Gerrrt/HomeLab/pull/720)).
> - **A secrets edit changes nothing until `make render`.** Alertmanager reads
>   the rendered files under `.rendered/`, not SOPS. The first synthetic page
>   (01:57:05) went out on the old URLs for that reason.
> - **The phones received walls of text** until #716 and #719 gave both copies
>   a title and a line.
>
> **Not run:** step 8's second half. Neither the lowered Watchdog route (daily
> route to the in-house alerts topic only) nor the `category=security` page
> has been observed. The daily Watchdog has arrived in-house only since the
> cutover, which is evidence for the first but not a drill.

1. **Secrets on `trinity`.** Run `make secrets-edit STACK=sensitive` and set
   the six `NTFY_*` keys, as `secrets/sensitive.example.yaml` describes them.
   New keys are new lines at the bottom of the file; the template is not
   merged in. Keep the `phone` password in the password manager. The edit
   leaves the tracked, encrypted file modified. Commit it through a pull
   request, as #717 did.
2. **Serve it.** On `trinity`, run `make up STACK=sensitive`, then look for
   `certificate obtained` for `ntfy.matrix.elysium` in Caddy's log.
3. **The name.** Add `ntfy` under *Additional Names for this Host* on
   `trinity`'s host override
   ([`add-a-host-override.md`](add-a-host-override.md)). From `prometheus`,
   this must print `{"healthy":true}`:

   ```bash
   curl --cacert certificates/tier-ca.pem https://ntfy.matrix.elysium/v1/health
   ```

4. **Deny-all, from outside.** An anonymous publish must answer `403`:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' --cacert certificates/tier-ca.pem \
     -d test https://ntfy.matrix.elysium/anything
   ```

5. **The phones**, on Wi-Fi. The stack README's ntfy section has the setup.
   Both phones must be subscribed to all three in-house topics and keep their
   two ntfy.sh subscriptions.
6. **Secrets on `prometheus`.** Run `make secrets-edit`:
   - Move the current `urgent` and `security` ntfy.sh URLs into
     `ALERTMANAGER_URGENT_EXTERNAL_URL` and `ALERTMANAGER_SECURITY_EXTERNAL_URL`.
   - Point the three `ALERTMANAGER_*_WEBHOOK_URL` keys at the in-house topics.
   - Set `ALERTMANAGER_NTFY_TOKEN` to the token from step 1.

   Then run `make up`. Rendering refuses to start without
   `certificates/tier-ca.pem`, which `make tier-ca ARGS=--mint` left on this host.
   Commit the encrypted file through a pull request (#720 did), or
   `DeployDrifted` stops convergence here. Any later change to these URLs
   takes `make render`: Alertmanager reads the rendered files, not SOPS.
7. **The probe.** Verify from the running exporter, then uncomment the ntfy
   target in `prometheus/targets/blackbox.yaml`. The command is in the comment
   above it.
8. **Observe delivery, on both paths.** Fire a synthetic page and resolve it:

   `amtool` is not installed on the host; it is in the container.

   ```bash
   docker exec alertmanager amtool alert add --alertmanager.url=http://localhost:9093 \
     alertname=AlertPathCutover severity=critical category=availability \
     --annotation=summary='#136 cutover: in-house and ntfy.sh'
   # on Wi-Fi: it arrives on the in-house urgent topic, on both phones,
   #   as a title and one line (templates/homelab.yml), not JSON
   # on mobile data, Wi-Fi off: it arrives on the ntfy.sh urgent topic,
   #   in the same format (render-config.sh passes the template inline)
   docker exec alertmanager amtool alert add --alertmanager.url=http://localhost:9093 \
     alertname=AlertPathCutover severity=critical category=availability \
     --end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   ```

   Then lower the second Watchdog route as in *Confirming it actually works*,
   below. It must arrive on the in-house alerts topic, and nowhere else. The
   same check with `category=security` proves the security pair.
   Resolve before firing again. While it is still firing, `urgent` does not
   resend it for four hours. Changes to a group that has already notified go
   out on its next `group_interval` tick, up to five minutes later.
9. **Kill it, and be paged anyway.** Run `docker stop sensitive-ntfy` on
   `trinity`. `EndpointUnreachable` for `ntfy` must arrive on the ntfy.sh
   urgent topic, about six minutes later: a probe cycle, then the rule's
   five-minute `for`. Then run `docker start sensitive-ntfy`.
   `AlertmanagerNotificationsFailing` for `webhook` goes pending a minute after
   the page. It counts failures over fifteen minutes, so it fires about five
   minutes later even with ntfy back, reporting the drill truthfully with
   `reason="serverError"`, and clears on its own. In-house pages sent during a
   short outage are not lost: Alertmanager retries them, and they arrive after
   the restart.

A 200 is not evidence. Only a notification seen on a phone is, and step 8 is
seen twice, on two networks. Write the times down here, the way the table
below was written, before the issue is closed.

## Setting up the external watcher

> **Done 2026-09-09.** One check on healthchecks.io, period 5m, grace 15m,
> notifying by email — not through this stack's ntfy topics, and not through
> ntfy.sh at all, since the whole house shares one public address and one free
> daily budget there ([#407](https://github.com/Gerrrt/HomeLab/issues/407)).
> The ping URL is in `ALERTMANAGER_HEARTBEAT_URL`; `check_alert_channels.py
> --live` reads its destination as `hc-ping.com`, a service that watches for
> absence, and passes. From 2026-09-07 to this date the URL pointed at `ntfy.sh`
> like every other receiver, and there was no dead man's switch, only a
> heartbeat nobody was waiting on
> ([#359](https://github.com/Gerrrt/HomeLab/issues/359)). **The drill below was
> run the same day** — [#288](https://github.com/Gerrrt/HomeLab/issues/288) —
> so "the check goes red when the stack dies" is an observation, with times,
> under *Confirming it actually works*.

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

> **Done 2026-09-09**, both halves in one sitting, read off the monitoring host
> with the phone in hand ([#288](https://github.com/Gerrrt/HomeLab/issues/288)):
>
> | | |
> | --- | --- |
> | `docker stop alertmanager` | 03:07:37 UTC, seconds after a ping went out |
> | Check DOWN, email received | 03:25:58 UTC — 18 minutes; period 5m + grace 15m says 20 at most |
> | `docker start alertmanager` | 03:25:58 UTC, ready 5 s later |
> | First ping after restart | 03:27:57 UTC — 2 minutes, inside one `repeat_interval` |
> | Second Watchdog route at 2m, `make reload` | 03:28:29 UTC |
> | Watchdog on the normal ntfy channel | 03:28 UTC, on the phone |
> | Route back to 24h, `make reload` | 03:33:16 UTC |
>
> Zero delivery failures across the whole window. One thing the daily half
> showed on the way: a route with `repeat_interval` below the root's
> `group_interval` (5m) repeats on the 5m tick, not at its own interval — the
> same coupling the heartbeat route works around above. It does not affect the
> 24h route, and the first notification still went out immediately.

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
| External check UP, daily heartbeat stopped | The **real alert channel** is broken — since #136 the in-house ntfy: a token that no longer matches, a topic renamed on one host and not the other, the phone's subscription or password. This is #67's original failure. Pages still reach you over the ntfy.sh copies; nothing else does. |
| `EndpointUnreachable` for `ntfy` on the ntfy.sh topic | The in-house ntfy, Caddy, or `trinity` itself. Warnings sent meanwhile reached no one — `default` has no second route — so read what fired in Alertmanager, through Grafana, once it is back. |
| Both stopped | Prometheus, Alertmanager, or this host. Start with `docker compose ps` and `curl -s localhost:9093/-/healthy`. |
| `LokiRulerSilent` or `LokiRulerNotificationsFailing` | The heartbeat is fine and Loki's ruler is not: every log-based alert, the security ones among them, is silent. `docker logs loki 2>&1 \| grep -i ruler`. |
| Both fine, but you expected an alert about something else | Not this runbook. The path works; check the rule, then the routing tree with `amtool config routes test`. |

The second row is the one this whole arrangement exists for, and it is the one
that looks like nothing is wrong.

## Related

- `prometheus/rules/watchdog.rules.yaml` — the rule, and why `severity: none` is
  load-bearing rather than a placeholder
- `loki/rules/security.rules.yaml` — `FirewallLogsStopped` and
  `SuricataLogsStopped`, and the comment on why the second waits nine hours;
  `prometheus/rules/ids.rules.yaml` is the process-table rule that answers the
  fast half. Same reasoning, applied to a different silent component
- [`docs/observability.md`](../observability.md#routing) — the full routing table
