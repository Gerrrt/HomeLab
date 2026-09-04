# Runbook: Let the host deploy itself

How the monitoring host converges on `main`, how to set it up, and what to do
when it refuses.

The decision and its reasoning are in
[ADR-0019](../adr/0019-converge-on-a-timer-instead-of-deploying-over-ssh.md).
This is the operating half. The schedule this joins is
[`schedule-maintenance.md`](schedule-maintenance.md), and the manual deployment
it does not replace is [`deploy-stack.md`](deploy-stack.md).

## Read this part first

`scripts/converge.sh` runs hourly on `prometheus` and does five things:

1. Fetches `main` from `https://github.com/Gerrrt/HomeLab.git` — anonymously,
   with no credential, over a URL that cannot push.
2. Refuses to continue if the checkout has uncommitted changes.
3. Refuses to continue unless the fetched tip carries a good GPG signature from
   GitHub's web-flow key.
4. Fast-forwards `main` — never a merge, never a rebase, never a rollback.
5. Runs `make up`, which is the same command a human runs.

**A merged pull request is deployed within the hour.** That is the point of it.
If you need it sooner, `make converge` on the host does it now.

**Every refusal is loud and leaves the host where it was.** Nothing here ever
overwrites a local edit, and nothing rolls the host backwards.

> **This is not how `oracle` and `saruman` are deployed.** They run Alloy and
> are pushed to with [`make deploy-agent`](../../scripts/deploy-agent.sh). They
> have no repository checkout and no age key, and ADR-0019 §"Three things it
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
host that is behind lists the commits it would apply and stops.

### Start in report-only mode

**This is how it is being rolled out.** The timer is installed and watched for a
while before it is allowed to change anything. Do this before
`make install-timers`, as root:

```bash
printf 'HOMELAB_CONVERGE_APPLY=0\n' | sudo tee -a /etc/default/homelab-timers
```

Every run then fetches, verifies and records, and applies nothing — deployment
stays a thing a human does with `make up`.

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

## What it records

Six gauges in `/var/lib/node_exporter/textfile_collector/homelab-deploy.prom`,
written on every exit path including the refusals, so a run that declined to
move still reports what the host is on.

| Metric | Question it answers |
| --- | --- |
| `homelab_deploy_revision_info{revision}` | What is deployed |
| `homelab_deploy_commit_timestamp_seconds` | How old the running configuration is |
| `homelab_deploy_behind_commits` | How far behind `main`; `-1` means the fetch failed |
| `homelab_deploy_tree_dirty` | Whether someone edited a file on the host |
| `homelab_deploy_verified` | Whether the deployed revision has a valid signature |
| `homelab_deploy_apply_enabled` | Whether this host applies what it fetches, or is in report-only mode |

The quickest read of "what is this host running" is the journal, which Alloy
already ships to Loki:

```bash
journalctl -u homelab-converge.service -n 20 --no-pager | grep homelab-deploy
```

`converge` is also an ordinary row in the `JOBS` table, so `ScheduledJobStale`,
`ScheduledJobFailed` and `ScheduledJobNeverRan` cover it exactly as they cover
the backups.

## When it refuses

Every one of these leaves the host running what it was already running. None of
them is an emergency, and none of them is fixed by re-running the timer.

### The tree is dirty

```text
error: the deployment checkout has uncommitted changes (above).
```

Someone edited a file on the monitoring host instead of in the repository.
Convergence has stopped and will stay stopped — this is the drift that used to
be destroyed silently at the next deploy.

Look at it first, then choose. There is no third option and no `--force`:

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
`/home/robo/code/Gerrrt/HomeLab`.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `DeployUnverified` right after install | GitHub's key is not in `robo`'s keyring, so nothing can verify | The import above. This is the expected state between installing the timer and doing it |
| `DeployUnverified` with the key present | `HEAD` is a commit that did not come through a pull request — usually someone committing on the host | `git log --show-signature -1` on the host. Get the commit onto a branch and merge it properly |
| `DeployDrifted` | A file was edited on the monitoring host | §"The tree is dirty". The edit is still there — this alert exists because it used to not be |
| `DeployBehind` **with** `DeployApplyDisabled` | Report-only mode — the host is fetching and recording but not applying | Working as intended. §Letting it act when you want it to deploy |
| `DeployBehind` **without** `DeployApplyDisabled` | Convergence is genuinely refusing | `journalctl -u homelab-converge.service -n 50` names the refusal; every case is in §When it refuses |
| `DeployApplyDisabled` you did not expect | Somebody set `HOMELAB_CONVERGE_APPLY=0` and it was forgotten | That is what this alert is for. `grep CONVERGE /etc/default/homelab-timers` |
| `DeployBehind` with `ScheduledJobFailed` | The refusal is real and recurring | The journal names it; every case is in §"When it refuses" |
| `DeployMetricsAbsent` | `homelab-deploy.prom` stopped arriving, while the backup metrics still do | Two separate files fail independently. Check `node_textfile_scrape_error`, then the file itself. If the timer was never installed, `make install-timers` |
| `homelab_job_last_exit_code{homelab_job="converge"}` is 75 | It never started — the weekly backup held the `backups` lock for the full 900s | Expected at most once a week, on Sunday. Persistent means a backup is hanging: `systemctl list-units 'homelab-*'` |
| The stack restarted at 03:25 and nobody deployed | Somebody merged a pull request | Working as designed — ADR-0019 §Consequences. `journalctl -u homelab-converge.service` names the revision |
| Convergence succeeds but a config change did not take | The container reads its config once at startup and nothing reloaded it | `make up` runs `reload-config.sh`, so this should not happen. If it does, it is a bug in that script's service list, not in convergence |
| `git fetch` fails every hour | No egress to github.com, or DNS | The host stays where it is, which is correct. `homelab_deploy_behind_commits` goes to `-1` rather than lying about the lag |

## Turning it off

The timer is one of several installed together; removing just this one:

```bash
sudo systemctl disable --now homelab-converge.timer
```

The host then stays on whatever revision it is on until someone runs `make up`
or `make converge`, which is exactly the pre-#99 model. `homelab-deploy.prom` is
deliberately left in place — deleting it would make the host look like it had
never deployed rather than like it had stopped converging, and those are
different things.

`make install-timers` puts it back.
