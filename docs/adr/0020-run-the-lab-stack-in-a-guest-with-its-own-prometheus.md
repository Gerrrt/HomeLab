# ADR-0020: Run the lab stack in a guest, and give it its own Prometheus

**Status:** Accepted · 2026-09

## Context

[ADR-0007](0007-defensive-estate-and-offensive-range.md) gave `Saruman` the
defended estate, and said of its telemetry: "`Saruman` runs its own Loki,
Grafana and Alloy under `stacks/lab/`, reusing `alloy/config.alloy` unchanged —
the two `*_URL` variables are the only difference."

[#101](https://github.com/Gerrrt/HomeLab/issues/101) tracks that sentence.
`stacks/` still contains one directory. Two things the sentence does not settle
block the first line of work, and both of them are the kind of question that is
cheaper to answer before a directory exists than after.

**Where it runs.** ADR-0007 says `Saruman` hosts it. `Saruman` is Proxmox VE,
and [#88](https://github.com/Gerrrt/HomeLab/issues/88) deployed its Alloy agent
as the native `.deb` rather than a container for a reason written down in
[`scripts/deploy-agent.sh`](../../scripts/deploy-agent.sh): the `.deb` is "for a
host that should not run Docker — Saruman is a Proxmox hypervisor, whose own
firewall ADR-0014 relies on and whose iptables Docker would rewrite." A compose
stack is Docker by definition. So "`Saruman` hosts `stacks/lab/`" and "`Saruman`
does not run Docker" are both true, and putting compose on the hypervisor
honours the first by breaking the second.

**What it contains.** The list is Loki, Grafana and Alloy. The same sentence
says `config.alloy` is reused unchanged with the two `*_URL` variables the only
difference — and that file has two sinks, not one: `loki.write "grafana_loki"`
and `prometheus.remote_write "metrics_service"`, at lines 386 and 395 of
[`config.alloy`](../../stacks/observability/alloy/config.alloy). Name only Loki
and `PROMETHEUS_REMOTE_WRITE_URL` has nowhere to point but `10.0.99.20`, which
is the one thing the Decision forbids. Either the lab collects no metrics, or it
remote-writes them into the estate, or it has a Prometheus of its own. The
three-item list is an omission, not a choice.

### Where it runs — three options

1. **Docker on the hypervisor.** No new guest, no new address, nothing to
   build. It rewrites the iptables of the box whose own firewall ADR-0014
   leans on, and it puts the lab's observability inside the fault domain of
   the thing hosting the lab — a guest escape reaches the stack that would
   otherwise have recorded it, which is precisely the confounding ADR-0007
   exists to remove.
2. **A guest on `Saruman`.** One more VM on a hypervisor that is about to run a
   Windows domain, Wazuh, Velociraptor and PBS. Docker's iptables live inside
   the guest and touch nothing the hypervisor's firewall depends on; the native
   agent on the hypervisor stays exactly as #88 left it.
3. **Somewhere else.** `ifrit` puts the defender's records on the attacker's
   machine and fails for the same reason option 1 does, one box over. A third
   machine buys hardware to avoid creating a VM on a hypervisor with 48 threads
   and, today, no guests at all.

## Decision

**`stacks/lab/` runs in a guest on `Saruman`, and carries its own Prometheus.**

- **Four services: Prometheus, Loki, Grafana, Alloy.** The lab's Alloy points
  both `*_URL` at the lab's own stores, which is what makes "reused unchanged"
  true rather than aspirational.
- **The guest is single-homed on VLAN 30**, like its host and for ADR-0007's
  reason — no trunk, no VLAN-aware bridge. It takes a static below `.100` with
  a reservation, which is the estate's rule for every static and the one
  `Saruman` itself currently breaks. The name and the address belong to the
  build, alongside `Saruman`'s own move to `10.0.30.20`.
- **The hypervisor keeps the native agent and the pass it already has.** #88's
  `10.0.30.110 → 10.0.99.20:9090,3100/tcp` is estate hardware telemetry and is
  untouched by this. Guests still get no such rule, and that includes the lab
  stack: it is a sink, not a source.
- **No Alertmanager *inside* the stack.** Prometheus evaluates whatever rules
  the lab carries and Grafana shows them; nothing in the lab pages. A second
  Alertmanager is a second set of four receiver URLs in a second encrypted
  file, and its entire output would be notifications about a lab the operator
  is sitting in front of. That is the composition question only.
  **It is not an answer to [#257](https://github.com/Gerrrt/HomeLab/issues/257)**,
  which asks the harder one — whether the *liveness* of the lab may cross to
  the estate even though its telemetry may not, and which already names the
  gap this leaves: ADR-0007 gives up "Loki, the dashboards and 40 alert rules",
  and the 40 rules are the half nothing here replaces. Whatever #257 decides
  lands outside this stack, not as a service in it.
- **`secrets/lab.sops.yaml` gets its own `creation_rule` and its own
  recipient.** Not the estate's. See the first consequence below — this is the
  half that fails quietly.

## Consequences

- **The lab guest must not be added to the estate's age recipient.**
  [`.sops.yaml`](../../.sops.yaml) carries one `creation_rule`, matching
  `secrets/.*\.sops\.ya?ml$`, so a recipient added to it can decrypt *every*
  file under `secrets/` — including the estate's SNMP communities and Grafana
  admin password. And that is the path the tooling walks you down:
  `make secrets-init STACK=lab` on the guest finds a different recipient
  already present and prints "Add this key as an additional recipient by hand"
  ([`bootstrap.sh:61-63`](../../scripts/bootstrap.sh)), which is correct advice
  for a second estate host and exactly wrong here. A lab host that can decrypt
  the estate's credentials inverts the trust direction ADR-0007 is built to
  protect. The fix is a second rule scoped to the lab file, ordered before the
  general one, with only the guest's key — which does not contradict the "a
  second rule would be a second copy of the key" note in that file, because
  that note is about two rules sharing *one* recipient.

- **Nothing in this repository validates a second stack.** `STACK ?=` in the
  `Makefile` parameterises the lifecycle and secrets targets and stops there.
  Every checker is pinned to the one directory — `scripts/validate.sh:17`,
  `check_docs.py:72`, `check_dashboards.py:37`, `check_compose_health.py:63`,
  `check_loki_rules.sh:28`, `seed-validation-env.sh:26`, and `STACK:
  stacks/observability` in [`ci.yml`](../../.github/workflows/ci.yml). A
  `stacks/lab/` created before that work is a stack CI has never seen: its
  compose is not `config`-checked, its rules are not `promtool`-tested, its
  dashboards are not checked against its datasources, and its images are pinned
  by nothing. That is a prerequisite, not a discovery to make afterwards.

- **`docs/architecture.md` gets a row the moment the directory exists.**
  `check_host_stack_table` in `check_docs.py` fails on any directory under
  `stacks/` that no host-and-stack row names. That is ADR-0004's "host-to-stack
  mapping lives in documentation" being enforced rather than hoped for, and it
  means the guest cannot be built without being written down.

- **Second of everything that was one**, which is the cost ADR-0007 counted and
  accepted, written out: a second age keypair, a second `secrets/lab.sops.yaml`
  and its example twin, a second Grafana admin password and renderer token, a
  second leaf certificate from the lab CA, a second dashboard set to keep from
  drifting from the first.

- **The disks are the constraint, and they now carry two TSDBs.** ADR-0007:
  "128 GB and 48 threads against a single mirrored pair of 7.2K disks. The fleet
  is sized against spindles, not RAM." The estate budgets 12 GiB of Prometheus
  and 30 days of Loki on a host that does nothing else. The lab's retention has
  to be sized against a mirrored pair already carrying a Windows domain, Wazuh,
  Velociraptor and PBS — [Wazuh's
  indexer](https://github.com/Gerrrt/HomeLab/issues/266) most of all. The
  numbers belong to the build; "the same as the estate's" is the wrong place to
  start from.

- **Nothing outside the lab knows when the lab stack dies**, and this ADR does
  not fix that. It monitors itself, which is the same circularity
  `stacks/observability` has and answers with a watcher somewhere else —
  [ADR-0015](0015-give-oracle-the-off-host-jobs.md) puts the estate's on
  `oracle`, and [#67](https://github.com/Gerrrt/HomeLab/issues/67) is the open
  version of that question for the estate. The estate's own net,
  `RemoteWriteJobStale`, keys on jobs that arrive on VLAN 99, so by
  construction it can never cover something that stays in the lab.
  [#257](https://github.com/Gerrrt/HomeLab/issues/257) owns this and predates
  this ADR; deciding the stack's composition narrows the question — a lab
  Prometheus is somewhere for a liveness rule to *live* — without answering it.

- **The lab stack is a defended asset, not a disposable one.**
  [ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) gives
  `ifrit`'s guests no backups, no monitoring and no patching, because the range
  is meant to be rebuilt. This guest is on the other side of that line: it holds
  the evidence of what the estate saw. Whether it is backed up, and by what, is
  not settled here — that is
  [#268](https://github.com/Gerrrt/HomeLab/issues/268), which has to decide what
  PBS is *for* before it is installed, because a hypervisor backing up its own
  guests to itself is not a backup.
