# ADR-0021: Converge on a timer instead of deploying over SSH

**Status:** Accepted · 2026-09

## Context

Deployment is `make up`, typed into an SSH session on `prometheus`
(`10.0.99.20`). [#99](https://github.com/Gerrrt/HomeLab/issues/99) asks for
something pull-based, so the host converges on the repository rather than being
pushed to, and names three reasons.

**Nothing records what is deployed.** `make up` on an uncommitted working tree
and `make up` on `main` produce the same output and the same exit code. The
difference surfaces weeks later, as a configuration nobody can account for.
This is not hypothetical here: the header of
[`scripts/deploy-agent.sh`](../../scripts/deploy-agent.sh) is four paragraphs
about `oracle` running a different Alloy version, a different container shape
and a config three weeks stale, for two days, because nothing compared the host
to the repository.

**Nothing detects drift.** A configuration edited on the host stays edited until
the next deploy overwrites it silently. Both halves are bad, and the second is
worse: the edit is destroyed *and* the destruction is invisible.

**It is [#77](https://github.com/Gerrrt/HomeLab/issues/77) again.** "Nothing
schedules anything" and "nothing deploys anything" want the same three parts —
something on a timer, a wrapper that records what it did, and alert rules that
read the record. #77 already built all three.

### The secrets constraint, re-examined

The issue names the awkward part: `render-config.sh` needs the age key, so a
pull-based agent needs it too, "and that is a key sitting on a host that pulls
from a public repository."

Checked rather than accepted, and it dissolves. The key is already there. It has
been since the stack was first deployed — [`.sops.yaml`](../../.sops.yaml) says
so in as many words, `~/.config/sops/age/keys.txt` is where it lives, and every
`make up` over SSH has decrypted with it on that host. A pull-based agent
running as the same user, on the same machine, reading the same file, adds no
exposure at all.

The word doing the damage in that sentence is *public*, and public means
**readable**. A key that decrypts local files is not endangered by strangers
being able to read the repository; it would be endangered by strangers being
able to *write* it. So the constraint the issue was reaching for is real but
differently shaped:

> A host that executes whatever a branch says, unattended, has replaced "do I
> trust this code" with "do I trust whoever can move that branch."

That is the question this ADR has to answer, and it is a question about write
access, not about visibility.

### What actually protects `main` today

Measured on 2026-09-04, against this repository:

| Property of `main` | Result |
| --- | --- |
| First-parent commits | 177 |
| Consecutive GitHub-signed merge commits from the tip | 110 |
| Oldest of that run | `2ea4cb4`, PR #33, 2026-08-19 |
| What is at 2026-08-19 | The git-history secret purge — the last force-push |
| Signing key on all 110 | `968479A1AFF927E37D1A566BB5690EEEBB952194` |
| `%G?` on all 110, with that key imported | `U` — good signature, untrusted keyring |

Every advance of `main` for the last three weeks and 110 merges has been a merge
commit GitHub made and signed, because every change went through a pull request.
Nothing enforced that; it is simply how this repository has been worked. But it
is a property that can be *checked*, and checking it converts "trust the remote"
into "trust one fingerprint pinned on the host."

### The options

| Option | Why not |
| --- | --- |
| Flux, Argo CD | Both reconcile Kubernetes objects. There is no Kubernetes here and [ADR-0004](0004-one-compose-stack-per-host.md) is a decision not to have any. Adopting one to deploy a Compose file means adopting a cluster to run the operator that deploys the Compose file |
| `ansible-pull` | The closest fit, and still the wrong size. It brings a second configuration language, a second templating system and a second secrets story alongside SOPS, to schedule a `make` target that already exists. The playbook would be a wrapper around `make up` |
| A GitHub Actions self-hosted runner | Inverts the security story rather than improving it. A runner holds a registration token, keeps an outbound connection to GitHub, and runs whatever a workflow file says — and workflow files are in the repository being deployed. It is a push model with extra steps and a credential |
| A webhook receiver | A port to publish, a service to pin and back up, and a secret to rotate, so that deploys are prompt. [ADR-0012](0012-publish-only-ports-with-an-off-host-consumer.md) is the standing decision against publishing a port with no off-host consumer, and "prompt" is worth an hour at most here |
| `git pull` in cron | This, minus the record, minus the drift check, minus the refusals, and minus the alerting. The distance between that one line and what is decided below *is* the issue |

## Decision

**A script on an hourly systemd timer fetches `main`, verifies its signature,
fast-forwards, and runs `make up` — reusing #77's timer, wrapper and alert
machinery rather than introducing a second way to run things on a schedule.**

[`scripts/converge.sh`](../../scripts/converge.sh), `homelab-converge.timer`,
one row in the `JOBS` table in
[`scripts/install-timers.sh`](../../scripts/install-timers.sh), and
[`prometheus/rules/deploy.rules.yaml`](../../stacks/observability/prometheus/rules/deploy.rules.yaml).

### It decides when to deploy; it does not reimplement deploying

The last thing `converge.sh` does is `make up`. It does not learn to render
config, start containers or reload Prometheus — `make up` already does all
three, and it is what every runbook tells a human to type.

This keeps the blast radius of this ADR on the *decision* to deploy rather than
on deployment itself. Every existing runbook stays true, there is exactly one
deployment path, and both callers — the timer and the human — exercise it.

### The gate is a fingerprint, not a remote

Convergence refuses to move unless the fetched tip verifies against
`968479A1AFF927E37D1A566BB5690EEEBB952194`, pinned in the script. A full
fingerprint and not the 16-hex key id, because a key id is claimed by the
signature itself and a fingerprint is not.

It also fetches an explicit `https://` URL rather than `origin`. `origin` is
SSH, and an unattended process using it would need a passphraseless key that can
also *push* to the repository this host executes. The repository is public, so
the agent needs no credential whatsoever — and a read-only URL that cannot push
is a better thing for a deployment host to hold than a key that can.

**What the gate buys:** a commit pushed straight to `main` past the pull request
does not deploy, and neither does a tip served by anything that is not GitHub.

**What it does not buy, stated plainly:** it does not stop a compromised GitHub
account. Someone who can open and merge a pull request gets a signature like
everybody else, and this host deploys it within the hour. That exposure is not
new — the operator ran `make up` from this checkout after pulling, which
executed exactly the same code — but the window changes, from "whenever someone
next deploys, having probably glanced at the diff" to "at most an hour, with
nobody looking." **The compensating control is the record, not the gate.**

### Drift is refused, never overwritten

An uncommitted change in the deployment checkout stops the run. It is not
overwritten, not stashed and not forced past; the run exits non-zero and keeps
doing so every hour, with `DeployDrifted` and `ScheduledJobFailed` both firing,
until a human commits the change or throws it away.

Overwriting is what the old model did. Refusing is the entire point, so there is
no `--force`: `git checkout -- .` is one command and it belongs to the human.

### What gets recorded

`converge.sh` writes five gauges into the textfile directory
[`run-scheduled.sh`](../../scripts/run-scheduled.sh) already writes to, in its
own file, on every exit path — **including the refusals**, because a convergence
that declined to move still knows what the host is running.

| Metric | Answers |
| --- | --- |
| `homelab_deploy_revision_info{revision}` | What is deployed |
| `homelab_deploy_commit_timestamp_seconds` | How old the running configuration is |
| `homelab_deploy_behind_commits` | How far behind `main` the host is; `-1` for "the fetch failed", so not-knowing cannot read as being-behind |
| `homelab_deploy_tree_dirty` | Whether anyone edited the host |
| `homelab_deploy_verified` | Whether the deployed revision carries a good signature |
| `homelab_deploy_apply_enabled` | Whether the host applies what it fetches, or is in report-only mode |

Because `converge` is an ordinary row in the `JOBS` table, `ScheduledJobStale`,
`ScheduledJobFailed` and `ScheduledJobNeverRan` cover "the convergence stopped
running" and "it ran and failed" with no new rule. `deploy.rules.yaml` adds only
what those cannot say — which *refusal*, and how far behind the host is as a
result.

### Hourly, and the no-op path is free

The cadence is a claim about how long a merged change may take to reach the
host, and an hour makes "merged" and "deployed" nearly the same word without
anything chasing a webhook.

It is affordable because it costs one fetch, not one deploy: when the checkout
is already at the fetched tip and the tree is clean, `converge.sh` exits before
rendering anything and never calls Docker. Almost all 24 daily runs touch no
container.

### Three things it deliberately does not do

**It does not roll back.** Fast-forward only. A non-fast-forward means `main`
was rewritten or the checkout has local commits, and a timer that resolves
either one is a timer that can roll the host onto a revision somebody
deliberately replaced.

**It does not converge anything but this host's stack.** `oracle` and `saruman`
run Alloy, which [`scripts/deploy-agent.sh`](../../scripts/deploy-agent.sh)
still pushes over SSH. Those hosts have no age key, no repository checkout and
no reason to grow either — and giving three machines a copy of this loop is a
larger decision than #99 asked for.

**It does not check that running containers match their pins.** `make up`
converges the *configuration*; whether a running image still matches the digest
`compose.yaml` names is `make check-digests`'s question, and answering it here
would be two checks with one name.

### Report-only exists, it is one variable, and it is how this ships

`HOMELAB_CONVERGE_APPLY=0` in `/etc/default/homelab-timers` — the file every
unit here already reads — makes every run fetch, verify and record while
applying nothing.

**That is the chosen rollout.** The timer goes on in report-only, and applying
is switched on once it has been watched deciding correctly for a while. "Let a
timer restart my monitoring stack unattended" is a reasonable thing to want to
see working first, and the alternative to a switch is not installing the timer
at all, which is the state that produced #99.

The mode is a gauge, not just a file. `homelab_deploy_apply_enabled` is written
with the rest of the record, because a mode that lives only in `/etc` on one
host is unrecorded state — the exact thing this ADR exists to stop — and
because without it `DeployBehind` could only say "it is refusing, OR
report-only is set" and leave the operator to go and read a file.

`DeployApplyDisabled` (info) reports the mode, and it is deliberately an alert
rather than an issue on the roadmap: it fires six hours in, and it **resolves by
itself** on the first run after the line is removed. There is nothing to close
and no way to leave it stale, which is the failure mode a tracked task for
"remember to turn this on" would have. Being temporary is enforced by the thing
itself rather than by anyone remembering.

## Consequences

- **`make up` over SSH still works and is still correct.** It is the escape
  hatch, and it remains the documented way to deploy something urgently. What
  changes is that the host no longer waits to be told.

- **A merged pull request reaches the monitoring host within an hour, with no
  human in the loop — once report-only is switched off.** That is the point, and
  it is also the cost. Merging becomes deploying, so a change that would break
  the stack breaks it at 03:25 rather than when someone was watching. The
  mitigations are the ones this repository already leans on — `make validate` in
  CI on every pull request, and a stack whose failure is loud. Until the switch
  is flipped, `DeployBehind` and `DeployApplyDisabled` fire as a pair and
  deployment stays manual.

- **One new setup step, and it fails loudly rather than silently.** GitHub's
  web-flow key has to be imported into `robo`'s keyring once. Until it is,
  nothing on the host can verify anything, convergence refuses every run, and
  `DeployUnverified` says so. That is deliberate: the alternative — treating an
  unverifiable commit as fine — would make the gate decorative.

- **Editing a file on the monitoring host now stops deployment.** Previously it
  was silently destroyed at the next deploy. This is strictly better and will
  still be annoying the first time it happens at an inconvenient moment; the
  runbook's answer is two commands.

- **`homelab_deploy_revision_info` adds one series per deployed revision.** At
  177 first-parent commits in roughly six months, that is a rounding error
  against a stack already holding cAdvisor's per-container series, and it buys
  the ability to read what was deployed and when off a Grafana panel.

- **The estate is now split two ways on deployment, on purpose.** This host
  pulls; `oracle` and `saruman` are pushed to by `deploy-agent.sh`. That is not
  a transitional state and no issue tracks unifying it — the hosts that hold no
  key and no checkout are better served by a script that ships them files.

- **`ScheduledJobFailed` becomes a routine sight during the first week.** Every
  refusal is an exit code, so a missing key or a stray edited file will fire it.
  That is the design, and it is the reason `deploy.rules.yaml` names which
  refusal rather than leaving a bare non-zero exit to be interpreted.
