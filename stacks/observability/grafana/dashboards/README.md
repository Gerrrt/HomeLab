# Dashboards

Seven dashboards, provisioned from this directory into a **HomeLab** folder. The
table of what each one covers is in
[`docs/observability.md`](../../../../docs/observability.md#dashboards); this
file holds the things that are true of all of them and that a panel description
is too small to say.

`allowUiUpdates` is `false`. Edits made in the Grafana UI are discarded on
restart — the JSON here is the source of truth. To change a dashboard: edit it
in the UI, **Dashboard settings → JSON Model**, copy, and commit it over the
file.

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
