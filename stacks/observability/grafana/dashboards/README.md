# Dashboards

Seven dashboards, provisioned from this directory into a **HomeLab** folder. The
table of what each one covers is in
[`docs/observability.md`](../../../../docs/observability.md#dashboards); this
file holds the things that are true of all of them and that a panel description
is too small to say.

The JSON here is the source of truth. Grafana re-provisions over its own copy
whenever a file changes, so a UI edit never outlives the next commit that
touches its dashboard. To change one:

```bash
make dashboards-export
```

Edit the dashboard in the UI, save it, run that, and read `git diff`. The
command pulls every dashboard back out of the running Grafana by uid and writes
it over the file here.

## Why `allowUiUpdates` is `true`, and what pays for it

It was `false` until [#100](https://github.com/Gerrrt/HomeLab/issues/100), and
the export could not be automated while it stayed that way. With `false`,
Grafana does not merely discard a UI edit at the next restart — it refuses to
store one at all, answering every save to a provisioned dashboard with
`400 Cannot save provisioned dashboard`. So the API could only ever hand back
the file it was provisioned from, and an export would have been a guaranteed
no-op over the very edit it was meant to capture: the command succeeds, exits
zero, writes nothing, and `git diff` reports no change to something that is
plainly different on the screen. The old loop worked around it by hand —
**Dashboard settings → JSON Model**, select all, copy, paste over the file —
which `docs/roadmap.md` was blunt about: manual, and therefore skipped under
pressure.

What `false` bought was a real property: the running dashboard and the committed
one could not disagree. `true` gives that up, so it is bought back explicitly
rather than dropped:

- **`make dashboards-export ARGS=--check`** writes nothing and exits non-zero
  when Grafana holds an edit git does not have. The `dashboards-drift` timer
  runs it daily, so forgetting to export ages into a stale job with an alert
  behind it rather than into work quietly lost weeks later —
  [`schedule-maintenance.md`](../../../../docs/runbooks/schedule-maintenance.md).
- **`make check-dashboard-roundtrip`** boots the pinned Grafana image in CI and
  asserts a save to a provisioned dashboard is still accepted. Flipping
  `allowUiUpdates` back to `false` breaks the export *silently*, so the setting
  is asserted rather than trusted.

## What the export drops, and what it will not take from you

Grafana does not hand back what it was given, and
[`scripts/export_dashboards.py`](../../../../scripts/export_dashboards.py) is
where every difference is reconciled. Two categories matter when reading a
diff:

**Dropped every time.** Top-level `id`, `version` and `iteration`, and each
panel's `id`. These are Grafana's bookkeeping — row identity, a concurrency
counter, a save timestamp — and all of them change on every save. Committing
them would put a guaranteed diff in front of every real one. None of the
dashboards here has ever carried a panel `id`, which is the evidence that
Grafana assigns them at load and does not need them in the file.

**Taken from the file, not from Grafana.** The time picker's range (`time`) and
each variable's selection and cached option list (`templating.list[].current`
and `.options`). Grafana persists whatever the browser happened to be showing
at save time, so exporting its copy would let one person's afternoon of
debugging silently become everyone's default time range and everyone's default
host filter. **To change those, edit the JSON by hand** — it is the one thing
the round trip deliberately cannot do for you.

Key order is preserved against the committed file. Grafana serialises
alphabetically at every level, so a naive write-back would reorder every key in
all seven files and bury the change you actually made.

## The alert tables do not know about silences

Six of the seven carry an alert table at the top, querying `ALERTS`. Five filter
on that dashboard's `component` label; the Security dashboard filters on
`alertname` instead, because every Loki rule carries `component=logs` and most
of them belong to the Logs dashboard rather than to it. **`ALERTS` is a series
Prometheus exposes about its own rule evaluation. It knows nothing about
Alertmanager.**

So a silenced alert still appears in these tables as `firing`. That is not a
bug to be worked around — the rule *is* firing, and the dashboard is showing the
rule's state truthfully. Alertmanager is where the decision not to notify
anybody lives, and it is downstream of everything drawn here.

The practical consequence: a row in one of these tables is not by itself
evidence that anyone was told. To find out whether an alert is suppressed, ask
Alertmanager:

```bash
curl -s http://localhost:9093/api/v2/silences | jq '.[] | select(.status.state == "active")'
```

Every deliberate silence in this lab is also recorded in prose, by UUID and
expiry, in three places that move together: `docs/roadmap.md`, the relevant
runbook, and a comment in the rule file it silences. An active silence that
those three do not account for is one somebody forgot to write down. The
Observability Stack dashboard charts the silence count for exactly that reason.

## Panel expressions are parsed by CI, which constrains how they are written

`scripts/check_dashboards.py --emit-promql` feeds every Prometheus expression in
every panel to `promtool check rules`. A typo in a panel query otherwise shows
up as an empty panel rather than an error, which reads as "nothing is happening"
instead of "this is broken".

`scripts/check_dashboards.py --emit-logql` does the same for the Loki panels,
handing them to `scripts/check_loki_rules.sh`, which boots the pinned Loki image
because nothing else parses LogQL. A `logs` panel's query is a bare stream
selector, which the ruler will not accept, so it is wrapped in
`count_over_time(… [5m])` before being handed over — the selector and its
pipeline are what a typo lands in, and those are parsed either way.

Those checks are why **no dashboard here uses `$__rate_interval`**. Grafana
would substitute it at query time, but promtool sees the literal string and
fails to parse it, and Loki fails the same way on `$__range` in a duration
position. Range windows are written as fixed durations — `[5m]` — so the same
text is valid in both places, and a stat panel names its window in its title
rather than inheriting the time picker.

Dashboard variables in *label matchers* are fine (`instance=~"$instance"`,
`interface=~"$interface"`), because both parsers read that as an ordinary
string.

## Datasource UIDs are hardcoded

`prometheus`, `loki` and `alertmanager`, matching
[`provisioning/datasources/datasources.yaml`](../provisioning/datasources/datasources.yaml).
There is no `${DS_*}` input variable. Grafana accepts a dashboard naming a
datasource UID that does not exist and renders its panels empty, so
`check_dashboards.py` resolves every UID against provisioning and fails on one
that does not.

Every panel carries its datasource, and so does every target inside it. That
redundancy is load-bearing: the query language is decided by the datasource, and
a target that names none of its own is what #78 was about.

## Screenshots

Five of the seven are captured into `docs/images/` by `make screenshots`. Which
files hold which dashboard, why `homelab-logs` and `homelab-security` are
deliberately never captured, and what to check before publishing an image are
all in [`docs/images/README.md`](../../../../docs/images/README.md).
