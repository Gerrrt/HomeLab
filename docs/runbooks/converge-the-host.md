# Runbook: Let the host deploy itself

How `prometheus` and `trinity` converge on `main`, how to set each up, and what
to do when either refuses.

The decision and its reasoning are in
[ADR-0021](../adr/0021-converge-on-a-timer-instead-of-deploying-over-ssh.md).
This is the operating half. The schedule this joins is
[`schedule-maintenance.md`](schedule-maintenance.md), and the manual deployment
it does not replace is [`deploy-stack.md`](deploy-stack.md).

## Read this part first

`scripts/converge.sh` runs hourly on two hosts, each converging its own stack:

| Host | Stack | Unit | Runs as, from |
| --- | --- | --- | --- |
| `prometheus` | `observability` | `homelab-converge` | `robo`, `/home/robo/code/Gerrrt/HomeLab` |
| `trinity` | `sensitive` | `homelab-converge-sensitive` | the operator, `~/code/Gerrrt/HomeLab` |

`trinity` joined in #533 — before that the tier holding the household's real
data was the one tier deployed by hand. Everything below applies to both; the
differences are in §On trinity. On each host it does five things:

1. Fetches `main` from `https://github.com/Gerrrt/HomeLab.git` — anonymously,
   with no credential, over a URL that cannot push.
2. Refuses to continue if the checkout has uncommitted changes.
3. Refuses to continue unless the fetched tip carries a good GPG signature from
   GitHub's web-flow key.
4. Fast-forwards `main` — never a merge, never a rebase, never a rollback.
5. Runs `make up`, which is the same command a human runs.

**A merged pull request is deployed within the hour.** That is the point of it.
If you need it sooner, `make converge` on the host does it now
(`make converge STACK=sensitive` on `trinity`).

**Every refusal is loud and leaves the host where it was.** Nothing here ever
overwrites a local edit, and nothing rolls the host backwards.

> **This is not how `oracle` and `saruman` are deployed.** They run Alloy and
> are pushed to with [`make deploy-agent`](../../scripts/deploy-agent.sh). They
> have no repository checkout and no age key, and ADR-0021 §"Three things it
> deliberately does not do" is why that is not changing.

## Set it up

The timer is installed by `make install-timers` along with every other job —
see [`schedule-maintenance.md`](schedule-maintenance.md) §Install. There is one
step specific to this job, and it belongs **before** that: `make install-timers`
primes every job by running it once, so an unimported key means convergence
fails its very first run.

### Import GitHub's signing key

Convergence verifies every commit against one fingerprint. Until the key is in
`robo`'s keyring, nothing on this host can verify anything, so every run refuses
and `DeployUnverified` fires. Do this once, on the monitoring host, as `robo`:

```bash
curl -fsSL https://github.com/web-flow.gpg | gpg --import
```

Then confirm you imported what you meant to. The fingerprint must be
`968479A1AFF927E37D1A566BB5690EEEBB952194`:

```bash
gpg --fingerprint 968479A1AFF927E37D1A566BB5690EEEBB952194
```

That file also contains `4AEE18F83AFDEB23`, which **expired on 2024-01-16** and
is not the key in use. Importing both is harmless — `converge.sh` accepts only
the fingerprint above — but do not confuse them if you are checking by eye.

### Prove it before trusting it

`--dry-run` does everything except the fast-forward and the `make up`:

```bash
make converge ARGS=--dry-run
```

A converged host prints `converged — <revision> is main` and nothing else. A
host that is behind lists the commits it would apply and stops. A host whose
checkout is at `main` but was never deployed from it says
`the checkout is at <revision>, but make up last applied <other>` and stops;
without `--dry-run` it runs `make up`.

### Start in report-only mode

**This is how it is being rolled out.** The timer is installed and watched for a
while before it is allowed to change anything. Do this before
`make install-timers`, as root:

```bash
printf 'HOMELAB_CONVERGE_APPLY=0\n' | sudo tee -a /etc/default/homelab-timers
```

Every run then fetches, verifies and records, and applies nothing — deployment
stays a thing a human does with `make up`.

> **Every merge needs a manual apply while this is set, including config that
> would otherwise need no deploy at all.** This is the part that is easy to miss,
> because a merge in this mode looks like it landed: `git pull` moves the
> checkout, the files are on disk, and the containers bind-mount the directories
> they came from. Nothing has re-read them.
>
> It caught this change out on its first day. The merge that installed the agent
> also added `deploy.rules.yaml`, so Prometheus sat with 48 alerting rules where
> the repository had 53 — and the five missing ones were the rules that watch
> convergence, `DeployApplyDisabled` among them. The mode had silently disabled
> the alerting that reports the mode. `make reload` fixed it in one hot reload,
> no container restart:
>
> ```bash
> cd /home/robo/code/Gerrrt/HomeLab && make reload
> ```
>
> Prometheus re-reads rule files at startup and on `POST /-/reload`, and at
> nothing else. Loki is the exception that makes this easy to get wrong — it
> polls its rule directory, so its rules DO arrive on their own, and seeing them
> update is not evidence that Prometheus has.
>
> So while report-only is on, treat `make up` — or `make reload` for a
> config-only change — as part of merging, not as an optional follow-up. The
> check is one command:
>
> ```bash
> curl -s localhost:9090/api/v1/rules | jq '[.data.groups[].rules[] | select(.type=="alerting")] | length'
> ```
>
> Compare it against `grep -c '^      - alert:' stacks/observability/prometheus/rules/*.rules.yaml`.
> Note the `jq` rather than a `grep -c` on the response: the API returns the
> whole document on one line, so `grep -c` counts that line and answers `1`
> however many rules are loaded.

Two alerts describe that state together, and reading them as a pair is the
point:

- `DeployApplyDisabled` (info) says the host is deliberately not deploying. It
  fires six hours in and **resolves by itself** on the first run after the line
  is removed.
- `DeployBehind` (warning) says how far behind it has got. In this mode that
  alert *is* the report and firing is expected, not a fault.

When only `DeployBehind` is firing, report-only is **not** the explanation and
something is genuinely refusing — see §When it refuses.

### Letting it act

Remove the line, then restart the timer:

```bash
sudo sed -i '/^HOMELAB_CONVERGE_APPLY=0$/d' /etc/default/homelab-timers
```

```bash
sudo systemctl restart homelab-converge.timer && sudo systemctl start homelab-converge.service
```

`DeployApplyDisabled` resolves on that run. Nothing else needs doing: the first
convergence catches up however many commits have accumulated, in one
fast-forward.

### On trinity

The same steps, as the operator — the `<you>` the build runbook installed as,
whose `~/code/Gerrrt/HomeLab` serves the tier — and with the profile and the
stack named. Do them in this order. Steps 1–3 come **before any**
`make install-timers PROFILE=sensitive` — on a fresh build that is before
[`build-the-sensitive-tier-host.md`](build-the-sensitive-tier-host.md) §12's
install, which points back here — because the installer primes the job and
applying is the default. On a host whose backup timers are already installed,
step 4 simply re-runs the install.

1. Import and check GitHub's signing key, exactly as §Import GitHub's signing
   key, as `<you>` rather than `robo`.

2. Prove it by hand. A bare `make converge` names `robo`'s checkout and is
   refused, so the stack is not optional here:

   ```bash
   make converge STACK=sensitive ARGS=--dry-run
   ```

3. Report-only first, **before** installing — `make install-timers` primes the
   job, and without this line its first run would apply:

   ```bash
   printf 'HOMELAB_CONVERGE_APPLY=0\n' | sudo tee -a /etc/default/homelab-timers
   ```

   The file is shared with `homelab-backup-sensitive` and
   `homelab-backup-library`; neither reads the variable.

4. Install it with the rest of the tier's schedule:

   ```bash
   make install-timers PROFILE=sensitive
   ```

5. Watch it. `DeployApplyDisabled` fires for `trinity` after six hours, and
   `DeployBehind` with it whenever `main` has moved. Each run says what it
   would have done:

   ```bash
   journalctl -u homelab-converge-sensitive.service -n 20 --no-pager | grep homelab-deploy
   ```

   While this lasts, every merge that touches `stacks/sensitive` — a Dependabot
   bump included — still needs `make converge STACK=sensitive` by hand. Use
   that rather than `git pull`: it is the same verified fetch, and it deploys
   what it moves to.

6. Let it act, when a few runs have read right:

   ```bash
   sudo sed -i '/^HOMELAB_CONVERGE_APPLY=0$/d' /etc/default/homelab-timers
   ```

   ```bash
   sudo systemctl restart homelab-converge-sensitive.timer && sudo systemctl start homelab-converge-sensitive.service
   ```

From then on a merged Dependabot bump to `stacks/sensitive` is on `trinity`
within the hour, with nobody at a shell — the point of #533.

What differs from the monitoring host, and why:

- **The secrets are the tier's own.** `make up STACK=sensitive` decrypts
  `secrets/sensitive.sops.yaml`, whose `.sops.yaml` rule holds `trinity`'s
  age key and nothing else of the estate's (ADR-0020's shape). The unit points
  `SOPS_AGE_KEY_FILE` at `<you>`'s `~/.config/sops/age/keys.txt`, the same key
  the backups use.
- **It shares the `backups` lock** with `homelab-backup-sensitive`, which stops
  most of the tier at 04:30. The 04:25 run can hold it briefly; the backup
  waits. A run that starts mid-backup waits up to 900s and is late, not wrong.
- **`make up` there seeds Home Assistant and Actual** before starting anything
  (`stacks/sensitive/README.md`), so a converged deploy is the same deploy a
  human types — there is still one deployment path.
- **The checkout has no push credentials**, which convergence never needs: it
  fetches the public https URL.

## What it records

Ten gauges in `/var/lib/node_exporter/textfile_collector/homelab-deploy.prom`,
written on every exit path including the refusals, so a run that declined to
move still reports what the host is on.

| Metric | Question it answers |
| --- | --- |
| `homelab_deploy_revision_info{revision}` | What the checkout is on, which is what is deployed while `unapplied` is 0 |
| `homelab_deploy_commit_timestamp_seconds` | How old the checkout's revision is, which is the running configuration's age while `unapplied` is 0 |
| `homelab_deploy_behind_commits` | How far the checkout is behind `main`; `-1` means the fetch failed |
| `homelab_deploy_tree_dirty` | Whether someone edited a file on the host |
| `homelab_deploy_verified` | Whether the checkout's revision has a valid signature, which is the deployed one's while `unapplied` is 0 |
| `homelab_deploy_apply_enabled` | Whether this host applies what it fetches, or is in report-only mode |
| `homelab_deploy_unapplied` | Whether the checkout has moved past what `make up` last applied |
| `homelab_deploy_tip_ci` | What CI said about the fetched tip: `1` passed, `0` did not, `-1` not asked (nothing to deploy) or not finished |
| `homelab_deploy_services_revived` | How many stopped stack services this run started again; `-1` means docker could not be asked |
| `homelab_deploy_services_stopped` | How many stack services meant to run this run left stopped, and why is in the journal; `-1` as above |

**Where the checkout is and what is running are two facts, and the first
version recorded only one.** On 2026-10-01 the checkout reached #781's merge by
a `git pull` by hand, and no `make up` ran. Convergence compared HEAD with
`main`, found them equal and reported `converged` every hour while Prometheus
served the pre-merge rules; every alert here read HEAD, so none fired. `make up`
now ends by recording the revision it applied (`scripts/record-applied.sh`, a
file inside the checkout's `.git`), and convergence deploys any checkout whose
HEAD differs from it. A hand pull therefore clears on the next run in apply
mode, and `DeployUnapplied` fires if it is still true after two. The first run
after this shipped has no record and redeploys once, which is expected.

Still, on this host, **`make converge`, not `git pull`**. It is the same fetch,
verified, and it deploys what it moves to.

The quickest read of "what is this host running" is the journal, which Alloy
already ships to Loki:

```bash
journalctl -u 'homelab-converge*' -n 20 --no-pager | grep homelab-deploy
```

`converge` is also an ordinary row in the `JOBS` table (`converge-sensitive` in
`SENSITIVE_JOBS` on `trinity`), so `ScheduledJobStale`,
`ScheduledJobFailed` and `ScheduledJobNeverRan` cover it exactly as they cover
the backups.

## When a service is stopped

Every run, on every path, including the refusals below, convergence looks for
a container of its stack that should be running and is not. That means the
compose working directory is this checkout's `stacks/<stack>`, the restart
policy is `unless-stopped` or `always`, and the state is exited or dead. It
starts each one with `docker start`, which uses the config it already had, so
this deploys nothing
([ADR-0087](../adr/0087-start-a-stopped-stack-service-from-the-converge-timer.md)).
It exists because a `docker kill` is a user stop, which `unless-stopped`
respects. On 2026-10-07 a scratch test killed containers by image, took the
production `alloy` with them, and nothing started it for 47 minutes.

`DeployServiceRevived` (info) says it happened. **Something stopped that
service, so find out what.** The journal names the container:

```bash
journalctl -u 'homelab-converge*' -n 50 --no-pager | grep -E 'started|leaving|held|backup'
journalctl -u docker --since today | grep 'stopping restart-manager'
```

It leaves a service alone in three cases.

| Case | Why | Until |
| --- | --- | --- |
| Stopped under 30 minutes ago | A runbook's deliberate stop, such as `docker stop alertmanager` in [`verify-the-alert-path.md`](verify-the-alert-path.md) | The first run after half an hour. `HOMELAB_CONVERGE_REVIVE_GRACE` (seconds) in `/etc/default/homelab-timers` changes it |
| Named in the hold file | A longer deliberate stop, such as a restore | The line is removed |
| `backups/volumes/.lock` is held | A hand-run `make backup` stops the services whose volumes it copies, and starting one mid-copy archives a live store. Timer-run backups share converge's `backups` lock and cannot overlap at all | The backup finishes |

**The hold file** is `.git/homelab-hold-<stack>` in the deployment checkout:
one compose **service** name per line (as in `compose.yaml`, so `caddy` for the
`ingest-proxy` container), `*` for all of them, and `#` for comments. Say why
in the comment:

```bash
printf '# restoring loki, #NNN\nloki\n' >> "$(git -C /home/robo/code/Gerrrt/HomeLab rev-parse --git-path homelab-hold-observability)"
```

It is outside the tree, so it is not drift. Anything it holds is still counted
in `homelab_deploy_services_stopped`, and `DeployServicesStopped` fires after
two hours, so a hold nobody came back to is not silent. A report-only host
counts what it would have started the same way.

## When it refuses

Every one of these leaves the host running what it was already running. None of
them is an emergency, and none of them is fixed by re-running the timer.

### The tree is dirty

```text
error: the deployment checkout has uncommitted changes (above).
```

Someone edited a file on the deployment host instead of in the repository.
Convergence has stopped and will stay stopped — this is the drift that used to
be destroyed silently at the next deploy.

Look at it first, then choose. There is no third option and no `--force`. On
`trinity` the checkout is `~/code/Gerrrt/HomeLab` rather than `robo`'s:

```bash
git -C /home/robo/code/Gerrrt/HomeLab status
```

```bash
git -C /home/robo/code/Gerrrt/HomeLab diff
```

To keep it, get it into the repository the normal way — a branch, a pull
request, CI. To discard it, `git checkout -- .` in that directory, and delete
any untracked files the status listed.

### The tip did not verify

```text
error: <sha> did not verify (signature: E, key: B5690EEEBB952194).
```

`signature: E` means gpg could not check it at all, which almost always means
the key was never imported — do the import above.

```text
error: <sha> did not verify (signature: N, key: ).
```

`signature: N` means the commit carries no signature. `main` moved by something
other than a GitHub merge: a direct push past the pull request, or a tip served
by something that is not GitHub. **Look at it before you deploy it.**

```bash
git -C /home/robo/code/Gerrrt/HomeLab log --show-signature -1 FETCH_HEAD
```

If it is genuinely yours and you want it anyway, deploy it deliberately and by
hand rather than teaching the timer to ignore signatures:

```bash
/home/robo/code/Gerrrt/HomeLab/scripts/converge.sh --allow-unsigned
```

### CI did not pass, or has not finished

```text
error: CI did not pass on <sha> (above).
```

Before deploying a tip, convergence asks GitHub for the tip's own check-runs. These are
the four `ci.yml` jobs that run on a push to `main`: Lint, Validate configs,
Boot hardened services and Secret scan. It lists each with its state above the
error ([#833](https://github.com/Gerrrt/HomeLab/issues/833)). It asks
anonymously, and only on a run with something to deploy.

The ruleset on `main` requires those checks before a merge
(`.github/rulesets/main.json`), so a red tip reaching `main` at all means the
ruleset was loosened, a check failed on the push run after passing on the pull
request, or someone merged with a bypass. Check the first:

```bash
make check-ruleset
```

Then fix `main` the usual way, with a new pull request. If the red tip is
genuinely what should run, deploy it deliberately and by hand:

```bash
/home/robo/code/Gerrrt/HomeLab/scripts/converge.sh --allow-red
```

`DeployTipRed` fires after two runs see the same red tip.

Only a check that **finished and failed** is a refusal. In these cases the run
waits instead: it says so, exits 0, stays where it is, and the next hourly run
asks again.

- A check is still queued or running.
- A check has no run at all.
- A check was `cancelled`.
- GitHub did not answer.

CI on `main` takes about four minutes, so a wait is normally one hour's delay at
most. Any wait that lasts fires `DeployBehind` at three hours. When it does, the
lines above the warning in the journal say which check is holding it:

| What the journal shows | Usual cause | What to do |
| --- | --- | --- |
| `missing` | A job in `ci.yml` was renamed | Rename it in `REQUIRED_CHECKS` in `converge.sh` and in `.github/rulesets/main.json`, together |
| `cancelled` | A manual cancel on the tip's run | Re-run it in GitHub |
| no lines at all | The API is unreachable, or the anonymous rate limit was hit | It clears by itself |

### It is not a fast-forward

```text
error: <sha> is not a fast-forward from <sha>.
```

Either `main` was rewritten, or somebody committed on the deployment host. The
two commands the error prints tell you which — the second one lists commits the
host has that `main` does not.

A rewritten `main` is a human decision to re-point the host at, and local
commits on the deployment checkout want rescuing to a branch before anything
else happens. Convergence deliberately resolves neither, because both
resolutions can roll the host onto a revision somebody replaced on purpose.

### It refuses the directory

```text
error: refusing to converge /home/robo/code/Gerrrt/HomeLab/.claude/worktrees/...
```

You ran it from a worktree or a second clone. `make render` writes into the
`.rendered/` of the tree it runs from, and no container mounts a worktree's
copy — so converging there would report success and change nothing. Run it from
`/home/robo/code/Gerrrt/HomeLab`, or on `trinity` from `~/code/Gerrrt/HomeLab`
with `STACK=sensitive`. A bare `make converge` on `trinity` lands here too: it
names `robo`'s checkout, which is not the one serving the tier.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `DeployUnverified` right after install | GitHub's key is not in `robo`'s keyring, so nothing can verify | The import above. This is the expected state between installing the timer and doing it |
| `DeployUnverified` with the key present | `HEAD` is a commit that did not come through a pull request — usually someone committing on the host | `git log --show-signature -1` on the host. Get the commit onto a branch and merge it properly |
| `DeployDrifted` | A file was edited on the deployment host | §"The tree is dirty". The edit is still there — this alert exists because it used to not be |
| `DeployBehind` **with** `DeployApplyDisabled` | Report-only mode — the host is fetching and recording but not applying | Working as intended. §Letting it act when you want it to deploy |
| `DeployBehind` **without** `DeployApplyDisabled` | Convergence is genuinely refusing | `journalctl -u homelab-converge.service -n 50` names the refusal; every case is in §When it refuses |
| `DeployUnapplied` **with** `ScheduledJobFailed` | The checkout moved and `make up` is failing on it every hour | `journalctl -u homelab-converge.service -n 50`; the failure is `make up`'s own, so [`deploy-stack.md`](deploy-stack.md) §Troubleshooting |
| `DeployUnapplied` **with** `DeployApplyDisabled` | Report-only, and something moved the checkout by hand | `make up` from the checkout, or let it act |
| `DeployApplyDisabled` you did not expect | Somebody set `HOMELAB_CONVERGE_APPLY=0` and it was forgotten | That is what this alert is for. `grep CONVERGE /etc/default/homelab-timers` |
| A merged change is on disk but the stack does not have it | Report-only mode applies nothing, and Prometheus re-reads rule files only on reload | `make reload`, or `make up` if compose or a rendered file changed. Expected in this mode — §Start in report-only mode |
| Prometheus has fewer alerting rules than the repository | The same thing: a rule file landed and nothing reloaded | `make reload`. Loki polls its rule directory and updates on its own, so Loki being current is not evidence that Prometheus is |
| `DeployBehind` with `ScheduledJobFailed` | The refusal is real and recurring | The journal names it; every case is in §"When it refuses" |
| `DeployRecordMissing` for one host | That host declares a converge job but its `homelab-deploy.prom` is not arriving, while the other host's is — so `DeployMetricsAbsent` stays quiet | The file on that host, then `journalctl -u 'homelab-converge*' -n 50` there. On `trinity` right after install, the priming run has not written it yet |
| `DeployMetricsAbsent` | `homelab-deploy.prom` stopped arriving, while the backup metrics still do | Two separate files fail independently. Check `node_textfile_scrape_error`, then the file itself. If the timer was never installed, `make install-timers` |
| `homelab_job_last_exit_code{homelab_job="converge"}` is 75 | It never started — the weekly backup held the `backups` lock for the full 900s | Expected at most once a week, on Sunday. Persistent means a backup is hanging: `systemctl list-units 'homelab-*'` |
| `homelab_job_last_exit_code{homelab_job="converge-sensitive"}` is 75 | The 04:25 run waited out `homelab-backup-sensitive`'s hold on the `backups` lock | Expected occasionally. Every night means the backup is hanging |
| The stack restarted at 03:25 and nobody deployed | Somebody merged a pull request | Working as designed — ADR-0021 §Consequences. `journalctl -u homelab-converge.service` names the revision |
| Convergence succeeds but a config change did not take | The container reads its config once at startup and nothing reloaded it | `make up` runs `reload-config.sh`, so this should not happen. If it does, it is a bug in that script's service list, not in convergence |
| `git fetch` fails every hour | No egress to github.com, or DNS | The host stays where it is, which is correct. `homelab_deploy_behind_commits` goes to `-1` rather than lying about the lag |

## Turning it off

The timer is one of several installed together; removing just this one:

```bash
sudo systemctl disable --now homelab-converge.timer
```

On `trinity`, `homelab-converge-sensitive.timer`. `make validate` there then
fails until it is back, because a tier that serves without converging is the
hand-deployed state #533 ended.

The host then stays on whatever revision it is on until someone runs `make up`
or `make converge`, which is exactly the pre-#99 model. `homelab-deploy.prom` is
deliberately left in place — deleting it would make the host look like it had
never deployed rather than like it had stopped converging, and those are
different things.

`make install-timers` puts it back (`PROFILE=sensitive` on `trinity`).
