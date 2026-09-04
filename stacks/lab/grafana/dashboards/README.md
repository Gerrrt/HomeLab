# Lab dashboards

There are none yet, and that is a decision rather than an omission.

The estate has seven, and copying them here is the obvious move and the wrong
one. They are built on the estate's datasources, the estate's metrics and the
estate's device inventory: `homelab-network` draws SNMP counters from a switch
this stack does not poll, `homelab-ups` draws an APC on the other side of a
firewall, and `homelab-security` draws labels that
`stacks/observability/alloy/syslog.alloy` extracts from firewall logs this
stack deliberately never receives. A copy would render four rows of empty
panels and one that works, and an empty panel is indistinguishable from a
broken collector — which is the failure mode this repository has been bitten by
more than any other (#62, #63, #71).

What the lab needs is not known yet, because the thing it exists to observe
does not exist yet. The Windows domain is [#265]; Wazuh is [#266]. Both come
with their own questions about what is worth drawing.

Until then, `Explore` against the two provisioned datasources is the whole
interface, and it works from the first `make up STACK=lab` — the provider in
`../provisioning/dashboards/dashboards.yaml` reads this directory every 30
seconds, so the first dashboard committed here appears without a redeploy.

## When you do add one

The conventions in
[`stacks/observability/grafana/dashboards/README.md`](../../../observability/grafana/dashboards/README.md)
hold here too, and they are worth reading before starting rather than after:
they are what `scripts/check_dashboards.py` enforces.

Two things about this stack specifically:

- **`check_dashboards.py` does not enforce them here.** That checker is pinned
  to `stacks/observability`, along with every other validator in the
  repository. Making them multi-stack is [#263]. Until it lands, a dashboard
  committed to this directory is checked by nothing, so check it by hand.
- **`make dashboards-export STACK=lab` works, and nothing reminds you to run
  it.** `scripts/export-dashboards.sh` takes a stack argument, and the provider
  here sets `allowUiUpdates: true` so that it can. What the lab does not have
  is the estate's `dashboards-drift` timer, which runs `--check` and turns a
  forgotten export into a stale job. Here, a dashboard edited in the UI and
  never exported simply stays uncommitted.

[#263]: https://github.com/Gerrrt/HomeLab/issues/263
[#265]: https://github.com/Gerrrt/HomeLab/issues/265
[#266]: https://github.com/Gerrrt/HomeLab/issues/266
