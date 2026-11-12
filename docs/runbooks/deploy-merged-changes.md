# Runbook: Get merged changes onto the hosts

A merge to `main` deploys itself on two hosts only: `prometheus` and
`trinity`. Every other host takes a change by hand, in its own way, and some
changes have to go in a set order. This page is the map: what changed, which
hosts it touches, what to run on each, and in what order.

It restates no procedure. Each host's steps live in the runbook or README
linked from its section, and that page wins where the two differ.

## Read this part first

| Host | What it runs from this repository | How a change gets there |
| --- | --- | --- |
| `prometheus` | `stacks/observability`, the estate's timers | itself, hourly ([`converge-the-host.md`](converge-the-host.md)) |
| `trinity` | `stacks/sensitive` | itself, hourly (same runbook, §On trinity) |
| `oracle` | `stacks/wiki` | by hand, verified ([`stacks/wiki/README.md`](../../stacks/wiki/README.md#deploying-a-change)) |
| `alexander` | `stacks/lab` | by hand: `git pull`, `make up STACK=lab` |
| `odin` | `stacks/soc` | by hand: `git pull`, `make up STACK=soc` |
| `fenrir` | `stacks/sensor` | by hand: `git pull`, `make up STACK=sensor` |
| `eden` | `stacks/bloodhound` | by hand: `git pull`, `make up STACK=bloodhound` |
| `garuda` | `stacks/analyst` | by hand: `git pull`, `make up STACK=analyst` |
| `phoenix` | `tofu/` | by hand: `git pull`, then plan and apply ([`provision-lab-guests.md`](provision-lab-guests.md)) |
| `smaug` | `stacks/media` | by hand, commit-pinned ([`build-the-nas.md`](build-the-nas.md), `scripts/smaug-fetch.sh`) |
| agent hosts | the Alloy agent | `deploy-agent.sh`, from the Mac |
| agent hosts | the textfile collectors | `make install-agent-collectors`, from the Mac |

Three rules decide the order:

- **Servers before clients.** A change that moves both ends of a connection
  deploys the end that answers first: the lab's ingest proxy on `alexander`
  before any lab agent, and the estate's on `prometheus` before `oracle`'s
  and `Saruman`'s agents.
- **`phoenix` plans only with `gandalf` up.** The tree's second provider reads
  `gandalf`, so every `tofu plan` needs it powered on
  ([ADR-0116](../adr/0116-build-the-range-attack-vm-with-opentofu-and-prove-it-with-a-script.md)).
- **A runbook's own order beats this page's.** When a change comes with
  steps of its own (a TLS move, a rebuild), do them in the order that
  runbook gives.

## 1. Find what changed

On the Mac, `git pull` first: `deploy-agent.sh`, `install-agent-collectors.sh`
and `smaug-fetch.sh` all ship this checkout's files, so a stale checkout ships
stale files.

Then list what changed since a host was last deployed. That is not the
checkout's `HEAD`: a `git pull` whose `make up` failed, or never ran, moves
`HEAD` and leaves the old configuration running (the 2026-10-01 incident in
`scripts/record-applied.sh`). For a host deployed by `make up`, read the
revision its last finished `make up` recorded, and compare that with `main`:

```bash
git fetch origin main && ./scripts/record-applied.sh --read lab
```

```bash
git diff --stat <the printed revision> origin/main -- stacks/lab stacks/observability/alloy scripts Makefile
```

Use the host's stack and path from the table above. An empty or `-dirty`
record means nothing is known about what runs: deploy, do not skip. A stack
reads more than its own directory. Every lab stack mounts files from
`stacks/observability/alloy/`, and `make up` runs scripts from `scripts/` and
the `Makefile`, so those paths count for every host.

For the tools run from the Mac, compare these paths against the last
deploy you know of:
- **The agent:** `stacks/observability/alloy/`, the image pin in
  `stacks/observability/compose.yaml`, and `scripts/deploy-agent.sh`.
- **The collectors:** `scripts/collect-*`, `systemd/agent/` and
  `scripts/install-agent-collectors.sh`.

Changes to `.github/` and to offline-only validation need nothing below. Not
every file under `docs/` or every `check_*` script is offline-only, though:
`make up` runs `scripts/check_mounted_config.py`, and the `firewall-claims`
timer reads `docs/firewall-claims.yaml`. A merge that touched one of those
reaches the hosts that run them.

## 2. `prometheus` and `trinity`

Nothing to do, unless the change is urgent or the host is in report-only
mode. Within the hour each host fetches `main`, verifies its signature and CI,
fast-forwards and runs `make up`.

- **Now, not within the hour:** `make converge` on `prometheus`,
  `make converge STACK=sensitive` on `trinity`.
- **Report-only mode:** if `/etc/default/homelab-timers` holds
  `HOMELAB_CONVERGE_APPLY=0`, converge reports and changes nothing, and
  `DeployApplyDisabled` says so. Report-only does not fast-forward, so a
  bare `make up` there redeploys the old revision (and on `trinity`, without
  `STACK=sensitive`, the wrong stack). Run the converge commands above by
  hand instead: the setting is read by the timer's unit, not by your shell,
  so a hand run verifies, fast-forwards and applies. Check that your shell
  does not export `HOMELAB_CONVERGE_APPLY=0`. Or turn the timer back on
  (*Letting it act* in [`converge-the-host.md`](converge-the-host.md)).
- **A change under `systemd/`:** converge does not install units. Run
  `make install-timers` from the deployment checkout (`PROFILE=sensitive`
  on `trinity`)
  ([`schedule-maintenance.md`](schedule-maintenance.md#install)).

Either way, `make check-timers` afterwards compares what is installed with
the repository.

## 3. `oracle`

The three steps in [`stacks/wiki/README.md`](../../stacks/wiki/README.md#deploying-a-change),
*Deploying a change*: fetch from the canonical URL, check that commit's CI,
then verify its signature, fast-forward to exactly it and `up -d`. Not
`make up`: `oracle` holds no age key, by design. If the change touched
`stacks/wiki/.env.example`, compare `/opt/wiki/.env` with it afterwards.

## 4. The lab stack, on `alexander`

`git pull && make up STACK=lab`. This is the lab's ingest proxy, so it goes
before any of the guests in §5 when they changed together. If the stack's
README gives a proof for the change, run it before moving on.

## 5. The lab guests

On `odin`, `fenrir`, `eden` and `garuda`: `git pull`, then
`make up STACK=<stack>` from the table. `eden` is on demand, so a change can
wait for its next start. Then check the guest's newest data in the lab's
Grafana is minutes old.

## 6. The agents and the collectors

From the Mac, after `git pull`:

- **The Alloy agent.** `make deploy-agent ARGS="<user>@<host>"` for `oracle`
  and `Saruman`, which push to `prometheus`. For `phoenix` and `golem`, which
  push to the lab, add `--monitoring-host 10.0.30.40`.
  - **Tokens.** For a lab host, nothing is decrypted on the Mac: export
    `INGEST_TOKEN` and `INGEST_TOKEN_READER` from `secrets/lab.sops.yaml` on
    `alexander` first. For `Saruman`, export them from the password manager.
    Header comments in `scripts/deploy-agent.sh` give the reason.
  - **Arrival check.** The script checks that the agent's data arrives. A
    missing or refused reader token, or a proxy it cannot reach, makes it
    skip that check with a warning and still exit 0. Only a `PASS` on
    arrival is proof. After a skip, check the host's newest data in Grafana
    by hand.
- **The collectors.** `make install-agent-collectors AGENT=<user>@<host>
  ARGS='--only <collector>'`, for each changed collector and each host that
  runs it. Without `--only` the installer tries every collector and starts
  each one whose prerequisites it finds, so an update to one can start
  others. Check a host first with `--check --only <collector>`, which
  changes nothing. The host's build runbook lists which collectors it
  runs.

## 7. `phoenix`

1. `git pull` in its checkout.
2. Power `gandalf` on, and source `phoenix.env` as
   [`provision-lab-guests.md`](provision-lab-guests.md) does.
3. `tofu -chdir=tofu plan`. Read every line: the plan must touch only the
   guests the change meant to touch. Anything else is a stop, not an apply.
4. Apply, then whatever post-apply step the guest's runbook gives. For
   `ragnarok` that is always `scripts/finish-attack-vm.sh`; until it passes,
   forwarding is not off ([`build-the-playground.md`](build-the-playground.md),
   §5).

## 8. `smaug`

Changes to `stacks/media` follow [`build-the-nas.md`](build-the-nas.md):
`scripts/smaug-fetch.sh` prints the commit-pinned, checksum-checked commands
to run there. To see whether `smaug` has drifted, run
`scripts/smaug-fetch.sh --verify` with the same files and run what it prints
on `smaug`. It says OK or FAILED for each file.

## Open one-time steps

Some merges come with a step that is run once and is then done. Each one is
listed here while its issue is open, and leaves this page when the issue
closes.

- **`eden` and `ragnarok` into the pipeline ([#1443](https://github.com/Gerrrt/HomeLab/issues/1443)).**
  Before the first plan on `phoenix`:
  1. Add `TF_VAR_gandalf_endpoint` and `TF_VAR_gandalf_api_token` to
     `phoenix.env` ([`build-the-playground.md`](build-the-playground.md), §5).
  2. Add both guests' MACs to `tofu/identities.auto.tfvars`, and re-escrow it
     ([`provision-lab-guests.md`](provision-lab-guests.md), §3).

  Until both guests are rebuilt, the plan shows changes for `eden` and
  `ragnarok`, and for nothing else. Then:
  - `eden`: [`build-the-bloodhound-guest.md`](build-the-bloodhound-guest.md),
    *Once: bring the hand-built `eden` into the pipeline*.
  - `ragnarok`: [`build-the-playground.md`](build-the-playground.md), §5,
    ending in `finish-attack-vm.sh`.

## If something goes wrong

| Symptom | Where to look |
| --- | --- |
| Converge refused | [`converge-the-host.md`](converge-the-host.md), *When it refuses*, by the refusal's own words |
| `oracle`'s step 3 stopped at a `&&` | the list under that step in the wiki's README names what each test refuses |
| A lab agent logs `x509` or `connection refused` | `alexander` is behind the agent: §4 first |
| `make up` failed naming a service | the service's healthcheck output is in the failure; [`recover-a-container-without-its-ports.md`](recover-a-container-without-its-ports.md) if it lost its ports |
| `tofu plan` hangs or fails on the `gandalf` provider | `gandalf` is off, or `phoenix.env` lacks the `TF_VAR_gandalf_*` lines |
| `smaug-fetch.sh` refuses | the checkout is dirty, or `HEAD` is not on `origin/main` |
