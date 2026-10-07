# ADR-0087: Start a stopped stack service from the converge timer

**Status:** Accepted · 2026-10

## Context

On 2026-10-07 at 05:34:23 UTC the production `alloy` container on
`prometheus` stopped with exit 137. Another session was testing Alloy configs
on the same Docker daemon. It ended each test with
`docker ps -q --filter ancestor=<image> | xargs docker kill`, and the image
was the pinned one production runs, so the kill took production too. Alloy
carries the host's metrics, its logs and `morpheus`'s syslog. The outage paged
`InstanceDown`, `RemoteWriteJobStale` and `FirewallLogsStopped`. It lasted 47
minutes, until another session noticed, asked the user, and ran
`docker start alloy`.

Two mechanisms that could have restarted it did not:

- **`restart: unless-stopped` does not restart after `docker stop` or
  `docker kill`.** Docker treats both as a user's decision. That is correct,
  and it is the reason the policy exists. A crash would have been restarted.
- **`converge.sh` did nothing.** Under
  [ADR-0021](0021-converge-on-a-timer-instead-of-deploying-over-ssh.md) it does
  nothing at a tip it has already applied, and never calls Docker. The 06:26
  run that day was not even on that path. A merge was waiting on CI, so it
  took the "CI has not finished" exit. Either way, it returned before anything
  could look at the containers.

Detection worked: the alerts fired within minutes. Recovery depended on
someone reading them and on that someone having a shell. The usual answer
would have been "the next merge redeploys", and that happened only by chance
at 07:27.

## Decision

**Every converge run looks for containers of its stack that should be running
and are not, and starts them with `docker start`.** The check runs on every
path: the no-op, the CI wait, and the refusals.

- **What counts.** A container counts when:
  - its compose working directory is the deployment checkout's
    `stacks/<stack>`, so no worktree's or scratch project's container
    qualifies;
  - it is not a one-off `compose run`;
  - its restart policy is `unless-stopped` or `always`, which marks it as
    meant to run, so a one-shot that finished is not stopped;
  - it is exited or dead.
- **`docker start`, not `make up`.** It starts the container with the config it
  was created with, which is what was last applied. It reads nothing from the
  checkout, so it is as safe on a dirty tree or a red tip as on a clean one.
  The decision to deploy stays where ADR-0021 put it, and this decides nothing
  about what runs.
- **What is left alone.** These are stops a person or a job made on purpose:
  - **Stopped under 30 minutes ago.** The runbooks' deliberate stops, such as
    `docker stop alertmanager` to test the heartbeat or AdGuard's ten minutes,
    finish inside that time. `HOMELAB_CONVERGE_REVIVE_GRACE` changes the
    threshold.
  - **Named in `.git/homelab-hold-<stack>`.** This is for a longer deliberate
    stop. It lists compose service names, or `*` for all.
  - **Anything while `backups/volumes/.lock` is held.** A hand-run backup stops
    the services whose volumes it copies. Starting one mid-copy would make the
    archive a copy of a live store. Timer-run backups already share this
    unit's `backups` lock.
  - **Anything on a dry run or a report-only host.** These say what they would
    start.
- **It is recorded.** `homelab_deploy_services_revived` and
  `homelab_deploy_services_stopped` are written beside the deploy gauges, with
  `-1` when Docker could not be asked.
  - `DeployServiceRevived` (info) fires when a service was started. Something
    stopped it, and that cause is still out there.
  - `DeployServicesStopped` (warning) fires after two hours of a service left
    stopped. That is how a forgotten hold file stays visible.

## Consequences

- **The worst case for a killed service is about 90 minutes.** It is up to
  thirty minutes of grace, plus up to an hour to the next run. This is not a
  supervisor. A tighter bound would need a faster timer, and the converge
  timer's cadence belongs to deployment.
- **A deliberate stop longer than half an hour needs a hold.** If it has none,
  the service is started under the person doing the work, and
  `DeployServiceRevived` says so. The hold file, its format and an example are
  in `docs/runbooks/converge-the-host.md`.
- **The no-op path now calls Docker:** `docker info`, `docker ps` and
  `docker inspect` on every run. It still renders nothing and touches no
  running container.
- **The cause of a stop is not this ADR's to find.** It restores the service
  and reports the revival. The 2026-10-07 cause was an image-wide kill in a
  test, and the lesson recorded for sessions on this host is to kill scratch
  containers by name or label, never by image.
- **`trinity` gets the same behaviour** for `stacks/sensitive`, under its own
  converge unit, which applies (`homelab_deploy_apply_enabled` was 1 there on
  2026-10-07). Its backups share that unit's `backups` lock as on
  `prometheus`. The ten-minute AdGuard stop in `forward-dns-to-adguard.md`
  is inside the grace period. A sensitive-tier restore that keeps a service
  down longer needs a hold first.
