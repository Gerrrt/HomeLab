# Observability

What is collected, where it goes, and how to change it.

**This document describes the estate's stack, on `prometheus` (10.0.99.20).**
There is a second one. [`stacks/lab`](../stacks/lab) is the lab's own
Prometheus, Loki, Grafana and Alloy, and it is deliberately not part of any of
what follows: no series it holds reaches this Prometheus, no log line reaches
this Loki, and none of the alert rules or dashboards below can see it. That is
ADR-0007's decision — lab telemetry stays in the lab, so that deliberately
hostile data never lands in the store the estate is actually run from — and
[ADR-0020](adr/0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)
settles its shape. It is built but not yet deployed; the guest that runs it is
[#262](https://github.com/Gerrrt/HomeLab/issues/262).

The one path that does cross belongs to the hypervisor and not to any guest:
`Saruman`'s own agent remote-writes here over a single unlogged pass
([#88](https://github.com/Gerrrt/HomeLab/issues/88)). A DL360 with an ageing
mirrored pair is estate hardware, and its health belongs with the rest of the
estate's.

The consequence worth carrying into everything below: **nothing here can tell a
quiet lab from a dead one.** `RemoteWriteJobStale` keys on jobs that arrive on
this Prometheus, so by construction it can never cover a stack that never
arrives. That gap is [#257](https://github.com/Gerrrt/HomeLab/issues/257), and
it is not closed by anything in this document.

## What is collected

| Source | Via | Interval | Examples |
| --- | --- | --- | --- |
| Linux hosts | Alloy → `node_exporter` | 60s | CPU, memory, filesystem, network, load, clock offset |
| Docker containers | Alloy → cAdvisor | 60s | Per-container CPU, memory, network, restarts, OOM |
| Container logs | Alloy → Docker socket | stream | stdout/stderr per container |
| systemd journal | Alloy | stream | unit, boot ID, transport, priority. Delivery is watched by `JournalSourceStopped` |
| `/var/log/auth.log` | Alloy | 60s poll | sshd, sudo, PAM |
| syslog, `/var/log/*.log` | Alloy | 60s poll | Everything else |
| pfSense | snmp-exporter | 60s | pf state table, counters, interface stats |
| pfSense logs | syslog → Alloy on 1514 | stream | `filterlog` decisions, `suricata` alerts, `kea-dhcp4` leases |
| MokerLink switch | snmp-exporter | 60s | Interface status and 64-bit octet counters |
| APC UPS | snmp-exporter | 60s | Charge, runtime, load, voltage, alarms |
| ProLiant iLO | snmp-exporter | 60s | Temperature, PSU, drive and battery health |
| The stack itself | Prometheus | 15s | Every component scrapes itself |
| Each Alloy agent | Alloy → itself | 60s | Remote-write throughput and lag, component health, lines forwarded |

Retention is 30 days for both metrics (`PROMETHEUS_RETENTION` in `.env`) and
logs (`retention_period` in `loki/loki-config.yaml`). Change both together or
dashboards will show metrics with no matching logs at the far end of the range.

Metrics carry a second bound: `PROMETHEUS_RETENTION_SIZE` caps the store at
12 GiB, and whichever limit is reached first wins. It is sized from the write
rate rather than the store's current size — 72.9 MiB/day gives 2.28 GiB over
30 days, 2.73 GiB with `Saruman` reporting — so it is roughly 4.4x the
planned estate and should never bind. In normal operation the 30 days above is
the limit that applies; if the size cap ever binds, that 30 days stops being
true and `PrometheusSizeRetentionActive` is what says so. Loki has no
equivalent size bound.

## Log level normalisation

Logs arrive spelling severity about twenty different ways — `ERROR`, `err`,
`eror`, `crit`, `fatal`, `panic`, `dbug`. `config.alloy` maps all of them onto
five canonical values before they reach Loki:

```text
emerg, panic, corrupt, fatal, alert, crit, critical  →  critical
err, eror, error                                     →  error
warn, warning                                        →  warning
info, information, informational, notice             →  info
dbug, debug, dbg                                     →  debug
```

This is what makes `{level="error"}` a useful query across a FreeBSD firewall, a
Ubuntu host and a Go container at the same time.

Three mechanisms do it, because the sources carry severity in three different
places. They share the table above and must keep sharing it:

| Source | Mechanism | Reads |
| --- | --- | --- |
| `/var/log` files, container stdout | `loki.process "log_processor"` | the line body, by regex |
| pfSense and other network syslog | `loki.relabel "network_syslog"` | the syslog PRI severity |
| the systemd journal | `discovery.relabel "journal"` | journald's priority keyword |

Where the protocol carries a severity, it is mapped rather than guessed at —
regex-sniffing a line whose PRI already says `err` is strictly worse. Where it
does not, the body is all there is. Each mechanism defaults to `info` for
anything it cannot classify, which is what keeps the vocabulary *closed*: a
severity nobody anticipated lands inside the five values instead of becoming a
sixth.

`scripts/check_dashboards.py` asserts that the values `config.alloy` can emit
and the values the Logs dashboard's Level picker offers are the same set, and
that no relabel rule copies a severity into `level` unmapped. That check exists
because both halves of #83 were invisible in a diff.

> **This has been silently broken twice.** First the extracting regex used `\b`
> inside a double-quoted Alloy string, where `\b` is a backspace escape rather
> than a word boundary. The regex never matched, so the template's
> `{{ else }}info{{ end }}` fallback labelled *every* line `info`. It is now a
> backtick string.
>
> Then (#83) the syslog and journal paths copied their severity to `level`
> instead of mapping it, and the Docker path set no `level` at all — so pfSense
> sat at `informational`, the journal at `notice` and `alert`, and containers
> at nothing. All of it was outside a picker whose setting said "All", which
> matched about a seventh of what was being ingested.
>
> If you edit any of the three mechanisms, verify afterwards that the vocabulary
> is still closed and still complete:
>
> ```logql
> sum by (level) (count_over_time({host=~".+"}[10m]))
> ```
>
> At most five series, every name in the table above. Only `info` means a regex
> is not matching. Then check that nothing escaped labelling entirely — these
> two must return the same number:
>
> ```logql
> sum(count_over_time({host=~".+"}[10m]))
> sum(count_over_time({host=~".+", level=~".+"}[10m]))
> ```
>
> A gap is a source reaching `loki.write` without passing through one of the
> three. Queries spanning an edit will show the old and new spellings side by
> side until retention ages the old ones out; that is not a regression.

## Dashboards

Seven dashboards are provisioned from `grafana/dashboards/` into a **HomeLab**
folder:

| Dashboard | UID | Covers |
| --- | --- | --- |
| Host Overview | `homelab-host-overview` | CPU, memory, storage, network per host |
| Docker Containers | `homelab-docker` | Per-container resources, restarts, OOM kills |
| Network & Firewall | `homelab-network` | pf state table, switch interfaces, iLO health |
| UPS & Power | `homelab-ups` | Battery, runtime, load, input voltage |
| Logs | `homelab-logs` | Volume by level and source, error and auth streams |
| Observability Stack | `homelab-stack` | Scrape health for every target, and Prometheus, Loki, Alertmanager and Alloy watching themselves |
| Security | `homelab-security` | Firewall blocks by interface and direction, top blocked sources, Suricata classification and priority, terminal-segment violations |

The JSON in git is the source of truth: Grafana re-provisions over its own copy
whenever a file changes, so a UI edit never outlives the next commit that
touches its dashboard. To change one, edit it in the UI, save, and run:

```bash
make dashboards-export        # ARGS=--check to report drift and write nothing
```

That pulls every dashboard back by uid and writes it over the file, so the loop
is edit → one command → `git diff`. It replaced a hand copy out of **Dashboard
settings → JSON Model** ([#100](https://github.com/Gerrrt/HomeLab/issues/100)),
and making it work meant setting `allowUiUpdates: true`: with `false`, Grafana
refuses to *store* a UI edit at all, so the export could only ever hand back the
file it started from — a silent no-op over the edit it was meant to capture.
What that flag used to guarantee is now bought explicitly, by the daily
`dashboards-drift` job and by a CI check that the save path still works;
[`grafana/dashboards/README.md`](../stacks/observability/grafana/dashboards/README.md)
has the whole trade, and what the export drops and refuses to overwrite.

CI checks the result parses, that every datasource UID resolves, that panels fit
the grid and do not overlap, and that every panel expression is syntactically
valid — PromQL through `promtool`, LogQL through a real Loki, since nothing else
parses it. It also boots the pinned Grafana image and asserts the committed JSON
is what Grafana produces from it, so an export never arrives as a diff nobody
can read.

### Watching the collection path

`homelab-stack` exists because the stack watched four devices and two hosts
attentively and did not watch itself at all
([#81](https://github.com/Gerrrt/HomeLab/issues/81)). Two of the three faults
found while verifying #12 would have been visible on it within a minute:
remote_write failing to a stale address, and cAdvisor reporting one series where
it should report hundreds. Both were invisible for hours because the only view
of the collection path was `up{job="alloy"}`, which stayed `1` throughout.

`up` is a poor liveness signal for half of what this stack collects, and the
dashboard says so rather than papering over it. Prometheus scrapes nine jobs
directly; the rest arrive by remote_write — one `<host>-metrics` and one
`<host>-alloy` per agent, plus `integrations/cadvisor` wherever there is
Docker. **A directly scraped target that dies sets `up` to 0. A remote-writing
agent that dies just stops pushing, so its `up` goes stale and ages out instead
of falling** — and `InstanceDown` is `up == 0`, so it cannot see that at all.
The *Sample staleness by job* panel is what covers the pushed jobs on the
dashboard, and the *Every target* table puts `Staleness` next to `Up` for the
same reason.

`RemoteWriteJobStale` in `stack.rules.yaml` is the alert for it, and it is
deliberately not written as a threshold on that staleness panel. `time() -
timestamp(up) > 300` reads correctly and cannot fire for any input: an instant
selector stops returning a sample once the lookback delta passes, so the
difference is bounded below any threshold worth alerting on. Measured over 24
hours of real data the largest value any job reached was 79 seconds. The rule
therefore asks the question the other way round — which jobs were reporting in
the last 24 hours and are not reporting now — because `count_over_time` reads a
range and sees through staleness where an instant selector cannot.

Two consequences worth knowing. It matches on the job-name convention
`config.alloy` builds (`<hostname>-metrics`, `<hostname>-alloy`,
`integrations/cadvisor`) rather than a list, so a new agent is covered the day
it is deployed — `Saruman` ([#88](https://github.com/Gerrrt/HomeLab/issues/88))
needed nothing added. And the 24-hour window is a real bound: an agent that
comes back inside a day resolves the alert truthfully, one that stays away
longer resolves it falsely once the window no longer remembers it, having
notified at least twice by then.

Alongside it, **samples returned per scrape** is the panel that catches a
collector which is still answering but has stopped exporting most of what it
used to. That is precisely the cAdvisor fault: `up` at 1, scrape succeeding,
one series where there should be hundreds.

Since #81 each Alloy agent also scrapes itself and remote-writes the result
under `<hostname>-alloy`, so `prometheus_remote_storage_*` and
`alloy_component_*` exist for every agent rather than only the one on this host.
`oracle` publishes Alloy's port on loopback (ADR-0012) and there is no address
Prometheus could be pointed at; pushing down the pipe that is already open costs
nothing and needs no new exposure. The monitoring host's agent is consequently
collected twice — `job="alloy"` by direct scrape and `job="prometheus-alloy"` by
push — which is deliberate: the first is the only one whose `up` can reach 0.

### Drawing the labels the parsing work exists to produce

`homelab-security` exists because `syslog.alloy` went to real trouble to extract
`interface`, `action` and `direction` from pfSense filterlog, and
`classification` and `priority` from Suricata; five Loki rules fire on them; and
nothing charted any of it ([#82](https://github.com/Gerrrt/HomeLab/issues/82)).
"Network & Firewall" is SNMP — the pf state table and interface counters — and
says nothing about what the firewall decided. "Logs" counts lines by level. The
dimensions the parsing exists to produce had no view, so the only way to see a
scan, a misconfigured device or a segmentation failure was as an alert that had
already fired.

Two things about it are worth stating here rather than only in a panel
description.

**Addresses are parsed at query time, not indexed.** *Top blocked source
addresses* runs `| regexp` over the line body, because ADR-0003 keeps addresses
out of the labels and a label per source address is the textbook way to detonate
Loki's cardinality. The regex anchors on the adjacent `src,dst` pair rather than
counting CSV fields, because pfSense's IPv6 filterlog layout puts `src` at a
different index — v6 lines therefore do not appear in that table, which is a
stated limit rather than an oversight.

**Its panels cannot tell you the IDS is alive.** Suricata watches Skids (VLAN
20) and Degens (VLAN 10), one process each, and a quiet IDS and a stopped one
produce identical log output, so empty Suricata panels are not evidence of
anything, and `security.rules.yaml` still declines to paper over that with a
log-based rule. What can is `SuricataStopped` in
`prometheus/rules/ids.rules.yaml`, which reads the firewall's process table over
SNMP and fires per declared interface
([#90](https://github.com/Gerrrt/HomeLab/issues/90)); the dashboard's alert
table lists it alongside the five Loki rules. The text panel at the top still
says so, rather than letting a flat line be read as calm.

**And it found that the firewall logged blocks only.** Building the panels
turned up something the alerts had not: across the full 30-day retention the
`action` label had exactly one value, `block`, at roughly 85,000 lines a day and
not one `pass`. `TerminalSegmentReachedInternalNetwork` matches
`{app="filterlog", action="pass"}`, so **it could not fire for any input** — the
same shape of defect as [#63](https://github.com/Gerrrt/HomeLab/issues/63),
where `ContainerHighMemory` divided by a limit no service set and showed as
loaded and healthy throughout.

[#223](https://github.com/Gerrrt/HomeLab/issues/223) armed it, and the way it
was armed is the point. Logging the *inter-VLAN* pass rules would not have
worked: every one of them is sourced from an internal segment, so no packet they
pass can have a terminal VLAN as its source. Logging the terminal VLANs' own
`→ any` egress rules would have worked and would have cost about 12.6M lines a
day — roughly 142× the existing volume, against a 30-day retention on one disk.

Instead there are three **tripwire** rules, one per terminal interface
(`igc0.10`, `igc0.20`, `igc0.40`), each a `pass` + `log` for
`<terminal net> → Internal_Segments`, placed *below* the eight block rules that
already stop that path and *above* the `→ any` egress rule. While segmentation
holds, the blocks match first and the tripwire logs nothing, so it adds no
volume. It can only match if those blocks are removed or reordered — the exact
failure the alert exists for — and in that case the `→ any` rule would have
passed the packet anyway, so nothing is weakened by it being there.

A tripwire that never fires is indistinguishable from a broken one, which is
this whole family of defect, so the logging path was proven rather than assumed:
logging was briefly enabled on the lowest-volume terminal egress rule, and 49 of
49 resulting `pass` lines carried the source address in exactly the position the
alert's regex reads. The destination half of the same regex already matched 2058
block lines. Both halves are therefore verified against real traffic; only the
combination is absent, which is what "the segmentation is holding" looks like.

*Passed (1h)* still reads *not logged*, because ordinary egress genuinely is
not. *Terminal→internal passes* reads *none* when the query matches nothing —
deliberately not `0`. Grafana's `noValue` fires on an empty result, not on a
measured zero, so rendering a number there would claim a measurement in exactly
the case where the stream is broken, absent or relabelled. None of these stats
render a number they did not get; *Firewall log arrival rate* next door is what
separates a quiet stream from a stopped one.

## Alerting

76 rules in total: 60 metric-based in `prometheus/rules/`, and 16 log-based in
`loki/rules/`.

### Log-based (Loki ruler)

Some conditions only exist in logs. A metric confirms sshd is running; only the
log shows it rejecting forty passwords in five minutes. `loki/rules/security.rules.yaml`
covers SSH brute force, SSH accepted from outside VLAN 50/99, repeated sudo
failures, user/group creation, kernel OOM kills, read-only remounts and disk I/O
errors.

The five authentication rules read a **three-branch union** — `authlog`, then
`journal`, then `syslog` constrained to the `sshd`/`sudo` apps — joined with
`or`, rather than the single `{log_type="authlog"}` selector they all used until
[#261](https://github.com/Gerrrt/HomeLab/issues/261). Only two hosts produce that
label, and the two that do not are `saruman` (journald-only, so there is no
`/var/log/auth.log` to tail) and `morpheus` (pfSense, which arrives over syslog).
Those are the two hosts where `root` can be reached with a password, so a
password-guessing run against either produced no alert at any volume — 54
accepted logins over the week to 2026-09-05, none of them visible to any of the
five rules. Nothing was missing from the store; the rules could not see it.

`or` rather than a wider selector because it deduplicates: `oracle` and
`prometheus` ship the same sshd events twice, once via `auth.log` and once via
the journal, and summing a combined selector would double-count them and halve
every threshold on the two hosts that already worked. The dashboard's two
auth panels in `logs-explorer.json` carry the same union for the same reason.

It also covers **a device taking its first DHCP lease on a segment** — one rule
for Hicks and one for Winterfell, plus the `absent_over_time` rule that says the
lease stream itself has stopped. That is
[ADR-0019](adr/0019-read-device-joins-from-the-dhcp-server.md): device joins
come from Kea on `morpheus` rather than from the eero cloud, because the
firewall sees the join on the wire and the cloud sees it two minutes later over
the WAN. "First" is expressed as the last ten minutes `unless` the seven days
before it, which needs no state anywhere and no list of known devices in the
repository.

They use the same `severity` and `category` labels as the Prometheus rules and
are sent to the same Alertmanager, so routing and inhibition are shared.

Loki's local ruler reads `<directory>/<tenant>/`, and with `auth_enabled: false`
the tenant is literally `fake` — hence the `loki/rules:/etc/loki/rules/fake`
mount in `compose.yaml`. Getting that path wrong produces no error, just a ruler
that silently evaluates nothing.

`promtool` cannot validate these; it parses PromQL and rejects every LogQL
stream selector. `scripts/check_loki_rules.sh` boots the pinned Loki image with
the rules mounted and fails on a parse error, then asserts the ruler actually
evaluated them. Note that `loki -verify-config` is *not* sufficient on its own —
it validates the config file and never opens the rule files. A file containing
`count_over_time({{{BROKEN` passes `-verify-config` and is caught only by the
boot check.

### Is the collection itself complete?

A rule that parses and can see every host is still only as good as what reaches
Loki, and two rules in `stack.rules.yaml` watch that:

- `JournalSourceStopped` fires when an agent that is up and publishing metrics
  has read no journal entries for two hours. Zero is a safe assertion rather
  than a tuned threshold because the quietest host in the estate, `Saruman`,
  still reads about three entries an hour — measured, not assumed.
- `LogEntriesDropped` fires when Loki *rejects* what an agent sends, and only
  when it keeps doing so for an hour. There is no retry behind a rejection, so
  those lines are gone — but an agent restart produces a burst of rejections
  that are not loss at all, and `for: 1h` is what separates the two.

Both came out of [#194](https://github.com/Gerrrt/HomeLab/issues/194), which
reported the journal arriving at 1.5%. That turned out to be a measurement
artifact — the query named `job="/var/log/journal"` while the stream carries
`job="loki.source.journal.journal"`, so it counted one label set and missed the
other. Compared like with like, delivery was 98.8% on the day of the report and
is 100% now. What the search did find is that Loki had been discarding around
185,000 entries a week and nothing said so, which is
[#341](https://github.com/Gerrrt/HomeLab/issues/341).

That check answers whether the rules *parse*. It cannot answer whether they can
*see*, and those are different failures with the same symptom — a green run.
[#261](https://github.com/Gerrrt/HomeLab/issues/261) was the second kind: five
authentication rules that were valid, loaded, evaluated, and matched nothing on
two of the four monitored hosts, because they selected `log_type="authlog"`
while `Saruman` ships a journal and `morpheus` ships syslog.

`scripts/check_loki_coverage.py` (`make check-loki-coverage`) asks the second
question, and it has to run against the **live** Loki on the monitoring host —
CI has no log store, so this one is deliberately outside `make validate`. For
each host-scoped rule it compares the hosts the rule's own stream selectors
reach against the hosts shipping logs at all, and for a host it cannot reach it
asks whether lines matching what the rule hunts exist there anyway. A rule blind
to a host that is producing exactly those lines fails; one blind to a host with
nothing to see warns.

There is no table of which rule should see which host, deliberately — a table
like that drifts, and a drifting table is the same class of defect. The
expectation comes out of the data instead, which is also what makes `useradd`
never matching on FreeBSD `morpheus` a non-event rather than an exception
somebody has to write down.

It runs daily at 07:45 as `homelab-loki-coverage.timer`, over a 24-hour window
([#335](https://github.com/Gerrrt/HomeLab/issues/335)). The window is short
because it sets detection lag, not sensitivity — see
[`runbooks/schedule-maintenance.md`](runbooks/schedule-maintenance.md) for the
argument and for what to do when it exits 1.

### Metric-based (Prometheus)

60 rules across eleven files in `prometheus/rules/`:

| File | Covers |
| --- | --- |
| `host.rules.yaml` | Instance down, predictive disk fill, memory, load, clock skew, reboots |
| `network.rules.yaml` | SNMP reachability, pf not running, state table, switch links, iLO hardware and Smart Array cache. `shiva`'s Smart Storage Battery read failed from 2026-08-18 until it was replaced on 2026-09-02, with the array in write-through as a result, so stored metrics before that date show the failed pack — `IloBatteryCondition` names the spare part to order, and the controller rollups are deliberately read at *failed* rather than *degraded* ([#76](https://github.com/Gerrrt/HomeLab/issues/76)) |
| `ups.rules.yaml` | On battery, low battery, runtime, load, temperature. A pack was fitted on 2026-08-28 and passed its self-test, so these read real hardware; stored metrics older than that date are the card's fabricated values — see [`runbooks/fit-the-ups-battery.md`](runbooks/fit-the-ups-battery.md) |
| `containers.rules.yaml` | Restart loops, OOM kills, memory, throttling |
| `stack.rules.yaml` | The stack watching itself: config reloads, rule evaluation, notification delivery, log ingestion, and remote-writing agents that stop pushing — the case `up == 0` structurally cannot see. Split off `containers.rules.yaml` onto `component: stack` in [#81](https://github.com/Gerrrt/HomeLab/issues/81) so a Prometheus that cannot reload its config stops being filed as a container fault |
| `watchdog.rules.yaml` | One rule that always fires, so that its absence is detectable |
| `blackbox.rules.yaml` | Whether an endpoint can actually be reached, from outside the service, and how many days its certificate has left — Grafana verified against the lab CA, the APC card's self-signed one read but not trusted, the wiki, Prometheus, Loki, Alertmanager and the switch UI over plain http. The iLO and pfSense UIs are written into `targets/blackbox.yaml` and left disabled: each needs a firewall pass from `10.0.99.20` that is a segmentation decision, not a monitoring one ([#91](https://github.com/Gerrrt/HomeLab/issues/91)) |
| `dns.rules.yaml` | Whether the house is still filtering DNS, asked directly at AdGuard Home on port 53 rather than through pfSense — a probe sent down the normal resolver path always passes, because Unbound's fallback is doing its job. [ADR-0010](adr/0010-keep-the-resolver-on-the-gateway.md) made losing the filter silent on purpose, and these two rules are what distinguishes "this site was never on a list" from "AdGuard has been dead for three weeks". Warning, not critical: nothing is down and nobody is blocked. The targets are written into `targets/blackbox-dns.yaml` and left disabled until [#102](https://github.com/Gerrrt/HomeLab/issues/102) builds the mini PC ([#126](https://github.com/Gerrrt/HomeLab/issues/126)) |
| `backup.rules.yaml` | Whether the scheduled maintenance jobs are still being run at all — staleness, failure, and never-ran |
| `deploy.rules.yaml` | Whether this host is running what the repository says — an uncommitted edit made on the host, a revision that did not verify, and how far behind `main` the host is. Reads the record `scripts/converge.sh` writes hourly ([#99](https://github.com/Gerrrt/HomeLab/issues/99), [ADR-0021](adr/0021-converge-on-a-timer-instead-of-deploying-over-ssh.md)) |
| `ids.rules.yaml` | Whether Suricata is running on each interface it is declared for, read from the firewall's process table over SNMP — the process metric `security.rules.yaml` says a log rule cannot be ([#90](https://github.com/Gerrrt/HomeLab/issues/90)) |

`promtool check rules` validates that these parse. It does not — and cannot —
tell you whether a rule can ever be true: `ContainerHighMemory` passed it for
months while dividing by a memory limit no service set at the time, so it showed
as loaded and healthy and could not fire for any input ([#63](https://github.com/Gerrrt/HomeLab/issues/63)).
`prometheus/tests/*.test.yaml` holds `promtool test rules` unit tests, which
feed a rule synthetic series and assert it fires — paired with a case asserting
it stays quiet, because a test that only ever expects silence would have passed
against the broken rule too. Coverage is thirty-nine rules of 60 so far — the five
in `blackbox.rules.yaml`, both in `dns.rules.yaml`, `ContainerHighMemory`,
`ContainerNearMemoryLimit`, `ContainerRestartLoop`, `ContainerCpuThrottled` and
`PrometheusSizeRetentionActive`, `Watchdog`, the three iLO rules from
[#76](https://github.com/Gerrrt/HomeLab/issues/76), all five in
`backup.test.yaml`, all five in `deploy.test.yaml`, `RemoteWriteJobStale`,
`SuricataStopped`, and all seven in `host.rules.yaml` —
`HostDiskWillFillIn24h` from [#189](https://github.com/Gerrrt/HomeLab/issues/189)
and the other six from [#320](https://github.com/Gerrrt/HomeLab/issues/320).
The other 21 are still validated for syntax only, which is exactly the
standing #63 had. Both numbers are checked by `scripts/check_docs.py` — the
sentence they replaced claimed six and named two, and had been wrong for
weeks.

`ContainerCpuThrottled` is the odd one in that list: it is
inert in production and cannot fire against anything cAdvisor
currently reports, because no service sets a CPU quota. Its tests are what make
the rule's correctness checkable anyway, which is the #63 lesson applied before
rather than after the fact ([#185](https://github.com/Gerrrt/HomeLab/issues/185)).

Disk alerting is predictive rather than a fixed threshold — `predict_linear` over
a 6-hour window, firing when the extrapolation reaches zero within a day *and*
free space is already under 30%. A disk sitting at 86% and stable is not an
emergency; one climbing fast at 60% is.

### Routing

Four receivers, **four separate destinations** (see
`alertmanager/alertmanager.yaml`). Three of them were names for one webhook URL
until [#66](https://github.com/Gerrrt/HomeLab/issues/66), which meant `urgent`
and `default` differed only in how often they repeated — a UPS on battery and a
slow scrape landed in the same place. The routing tree decides which alert is
urgent; only a distinct destination makes that difference audible, because
per-topic sound and do-not-disturb settings live on the receiving end.

The table below is the alert routing, and covers three of the four. The fourth,
`heartbeat`, carries no alerts at all — it is the dead man's switch, and it is
described in [its own section](#the-dead-mans-switch) below.

| Matches | Receiver | First notification | Repeats |
| --- | --- | --- | --- |
| `critical` + `category=power` | `urgent` | immediately | 30m |
| `critical` + `category=security` | `security` | immediately | 1h |
| `warning` + `category=security` | `security` | 30s | 4h |
| `critical` (anything else) | `urgent` | 10s | 4h |
| `warning` (anything else) | `default` | 30s | 12h |
| `info` | `null` | never | — |

Security has its own destination at both severities because eleven rules carry
`category: security` — SSH brute force, a terminal segment reaching the internal
network, IoT lateral movement, priority-1 Suricata, Suricata not running — and routed on `severity`
alone, the warning-severity half of that list arrived in the default channel on
a 12-hour repeat, indistinguishable from a disk filling up. `category=power`
was the precedent.

**First match wins and nothing sets `continue`, so the order of those rows is
the design.** A category route moved below the bare `severity` rows silently
stops matching, and `amtool check-config` still reports SUCCESS — that mutation
was tried. `scripts/validate.sh` and CI therefore assert the table itself with
`amtool config routes test --verify.receivers`, one assertion per row.

Inhibit rules stop cascades: a down host suppresses its own disk warnings, a
dead `snmp-exporter` suppresses the "every device is unreachable" storm that
would otherwise follow, and a certificate inside seven days of expiry suppresses
its own thirty-day warning rather than resolving it — a "resolved" for a
certificate three days from expiry would be a lie.

### The dead man's switch

`AlertmanagerNotificationsFailing` catches delivery *errors*. It cannot catch a
webhook URL that is well-formed, reachable, and pointed at nothing — a 200 into a
deleted ntfy topic is a successful notification by every measure Alertmanager
has. That is not hypothetical: the webhook was the `ntfy.example.invalid`
placeholder for the entire life of the stack and nothing noticed, because the
only symptom is that alerts stop arriving, which is also what a healthy week
looks like ([#67](https://github.com/Gerrrt/HomeLab/issues/67)).

`prometheus/rules/watchdog.rules.yaml` holds one rule, `Watchdog`, whose
expression is `vector(1)`. It fires unconditionally and forever. **Its firing
carries no information; its absence is the entire signal.** One `continue: true`
— the only one in the tree — sends it to two places:

| Route | Destination | Cadence | Catches |
| --- | --- | --- | --- |
| `heartbeat` | external cron-monitor ping | 5m | Prometheus stopped evaluating, Alertmanager died, no outbound network |
| `default` | the real alert channel | 24h | the alert channel itself is a 200 into nothing |

Neither half substitutes for the other. The heartbeat proves delivery to a
*different* URL than real alerts use, so it cannot see a deleted topic; the daily
notification travels the identical URL your warnings travel, but nothing
machine-checks its absence.

The watcher lives off this host by necessity — a watcher here fails at the same
moment as the thing it is watching. Setting it up, the coupling between
`repeat_interval` and the external check's period and grace, and how to read
which half went quiet are in
[`runbooks/verify-the-alert-path.md`](runbooks/verify-the-alert-path.md).

This is the same reasoning `loki/rules/security.rules.yaml` already applies to
the firewall with `FirewallLogsStopped`, and the reason it gives for deliberately
*not* writing a log-based `SuricataStopped` rule: absence of alerts is
indistinguishable from absence of the service, and detecting that needs a
heartbeat rather than a threshold — which `prometheus/rules/ids.rules.yaml` now
reads from the firewall's process table. The notification path was the one
place that argument had not been turned on itself.

### Scheduled jobs

The same inversion, applied to maintenance. `make backup`,
`make backup-firewall`, `make snmp-verify` and `make secrets-verify-backup` were
all commands someone had to remember, and nothing ran any of them
([#77](https://github.com/Gerrrt/HomeLab/issues/77)). A job that fails is loud;
a job that stops being run is silent, and silence is also what a healthy week
looks like.

Four of them are now systemd timers on the monitoring host. Every run — timer or
human — goes through `scripts/run-scheduled.sh`, which records four gauges into
a textfile the node exporter already scrapes:

| Metric | Says |
| --- | --- |
| `homelab_job_last_success_timestamp_seconds` | when this job last exited 0. A failed run carries the previous value forward rather than clobbering it |
| `homelab_job_last_run_timestamp_seconds` | when it last finished, whatever the outcome |
| `homelab_job_last_exit_code` | 0, or 75 for "never started, another job held the lock" |
| `homelab_job_duration_seconds` | how long it took |

The threshold each job is held to is a *fifth* series,
`homelab_job_max_age_seconds`, written by `scripts/install-timers.sh` from the
same table that decides the cadence. That is what lets the five rules in
`prometheus/rules/backup.rules.yaml` cover every job without naming any of them,
and what makes `make check-timers` able to assert that a threshold is at least
twice its timer's real period.

Two things are deliberate and easy to undo by accident:

- **The label is `homelab_job`, not `job`.** `config.alloy`'s
  `discovery.relabel "metrics"` sets `job` on every target from that exporter,
  and scrapes default to `honor_labels: false` — so a `job` label in the file
  would arrive as `exported_job` and every rule would match nothing while still
  showing as loaded and healthy. `backup.test.yaml` has a case that pins this.
- **The staleness rules compare against a stored timestamp rather than using a
  long `for:`.** A long `for` measures continuous pending time in Prometheus's
  own memory, and one of the jobs being measured is the one that stops
  Prometheus. `UpsBatteryUnproven` records the same reasoning.

**What this does not prove.** Every one of these jobs runs on the machine it is
checking, with the key that is on that machine, against the disk that is in it.
`verify-backups` proves an archive still decrypts; it says nothing about a dead
disk or a fire. The only job that proves off-host recoverability is
`secrets-verify-backup`, and it is precisely the one that cannot be automated —
it needs a human to mount removable media, so `SecretsKeyBackupUnproven` nags at
ninety days instead. That alert is the one rule in `backup.rules.yaml` not keyed
on `homelab_job`:
[ADR-0024](adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)
allows the secrets to be encrypted to more than one age recipient, so it fires
per recipient off `homelab_key_recipient_last_proof_timestamp_seconds` rather
than off the job. One timestamp for every copy would mean proving either one
vouched for the other, which is backwards when the whole point of the second
copy is that it fails independently. With a single recipient it behaves exactly
as it always has. One output does leave: `backup-firewall` copies each export
to `oracle` and fails if it cannot, so its failure alert doubles as "the config
has stopped leaving this host". The volume sets do not leave; that is
[#92](https://github.com/Gerrrt/HomeLab/issues/92).

Installing, tuning and troubleshooting all of it:
[`runbooks/schedule-maintenance.md`](runbooks/schedule-maintenance.md).

## Adding a monitored device

See [`runbooks/add-monitored-device.md`](runbooks/add-monitored-device.md). In
short:

- **A Linux host:** run Alloy with `LOKI_URL` and
  `PROMETHEUS_REMOTE_WRITE_URL` pointed at `10.0.99.20`. Nothing on the
  monitoring host changes.
- **An SNMP device:** append a target to
  `prometheus/targets/snmp.yaml` and a module plus auth to
  `snmp-exporter/generator.yaml`. file_sd picks the target up within five
  minutes without a restart.

## Cardinality

The stack is small, but two things will bite if ignored:

- **The `ilo` SNMP module exposes ~1,600 metrics.** The HP Insight tree is
  enormous. It is scraped once a minute from one device, which is fine — but do
  not add a second module that broad without trimming the OID list in
  `generator.yaml`. All four modules together are ~1,800 metrics per scrape
  cycle.
- **Loki labels must stay low-cardinality.** `host`, `level`, `log_type`,
  `service_name` and `unit` are bounded. Never promote a request ID, IP address
  or timestamp to a label; use `|=` line filters instead. A MAC address is the
  same class of mistake, which is why the ADR-0019 rules extract `mac` with a
  query-time `| regexp` and it exists nowhere in the index.

`module` and `auth` are deliberately dropped by `labeldrop` in `prometheus.yaml`
after being converted to query parameters, so they never become metric labels.

## Operating

```bash
make up                    # render secrets, start everything
make ps                    # container status
make logs SERVICE=grafana  # tail one service
make reload                # hot-reload Prometheus, Alertmanager, snmp-exporter
make validate              # everything CI runs
make backup                # quiesce, archive, encrypt and verify the data volumes
make restore ARGS=--list   # the backup sets that exist
make down                  # stop, keep data
make nuke                  # stop, destroy data (prompts) — recoverable, see
                           #   docs/runbooks/restore-the-stack.md
```

Prometheus and Alertmanager are started with lifecycle endpoints enabled, so
rule and route changes apply via `make reload` without dropping the TSDB head
block. snmp-exporter serves `POST /-/reload` unconditionally, with no lifecycle
flag to enable.

`make up` runs that same reload as its last step. It has to: `docker compose up
-d` keys off the service definition, not the contents of the files it mounts,
so without the reload a re-rendered config would sit on disk while the
container served the copy it parsed at startup.
