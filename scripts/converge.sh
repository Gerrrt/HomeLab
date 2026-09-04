#!/usr/bin/env bash
#
# Bring the deployment checkout to what `main` says, and record what is
# deployed (#99).
#
#   scripts/converge.sh [--dry-run] [--allow-unsigned]
#
# WHY THIS EXISTS
#
# Deployment was `make up` typed into an SSH session, which has three problems
# and only the first one is obvious.
#
#   1. Nothing recorded what was deployed. `make up` on an uncommitted working
#      tree and `make up` on `main` produce the same output and the same exit
#      code, and the difference surfaces weeks later as a config nobody can
#      account for. `oracle` is the worked example — scripts/deploy-agent.sh's
#      header is four paragraphs of one host quietly running something other
#      than what the repository said, for two days, because nothing compared
#      the two.
#
#   2. Nothing detected drift. A config edited on the host stayed edited until
#      the next deploy overwrote it silently, so the edit was lost AND never
#      seen.
#
#   3. It is the "nothing schedules anything" problem (#77) wearing a different
#      hat, and #77 already built the answer: a timer, a wrapper that records
#      the outcome, and alert rules that read the record. This reuses all
#      three rather than introducing a second way to run things on a schedule.
#
# WHAT CONVERGENCE MEANS HERE, EXACTLY
#
# Fetch `main` from the canonical URL, refuse to move unless the tip carries a
# good signature from the pinned key, fast-forward, and run `make up`. That is
# the whole loop. It deliberately does NOT reimplement deployment: `make up` is
# still what renders the config and starts the stack, so every runbook that
# says `make up` stays true and this script's blast radius is the DECISION to
# deploy, not the deployment.
#
# The no-op path costs one fetch. When the checkout is already at the fetched
# tip and the tree is clean, nothing is rendered, no container is touched and
# docker is never called — which is what makes an hourly cadence reasonable.
#
# WHY IT FETCHES A URL AND NOT `origin`
#
# `origin` is git@github.com:Gerrrt/HomeLab.git — SSH, with a key that can also
# push. A systemd unit has no ssh-agent, so that path would need a
# passphraseless key readable by an unattended process, and that key would
# carry write access to the repository this host executes.
#
# The repository is public, so the agent needs no credential at all. It fetches
# an explicit https:// URL, which cannot push and cannot be redirected by a
# rewritten `remote.origin.url` in a checkout someone has already edited. The
# URL is pinned below and asserted against `origin` only as a sanity check, not
# trusted from it.
#
# WHY THE SIGNATURE GATE, AND WHAT IT DOES NOT BUY
#
# A host that executes whatever a branch says, unattended, has moved the
# question from "do I trust this code" to "do I trust whoever can move that
# branch". The gate narrows it back: every commit is checked against ONE
# fingerprint pinned in this file, and `main` only moves if the tip verifies.
#
# That is not a guess about how this repository works, it is a measured
# property of it. Every one of the last 110 first-parent commits on `main` —
# unbroken back to PR #33 on 2026-08-19, which is the history purge and the
# last time anything reached `main` other than through a pull request — is a
# merge commit GitHub made and signed. All 110 verify against the fingerprint
# below, with `%G?` of `U` and `%GF` equal to the pin.
#
# So the gate costs nothing today and refuses two things it should refuse: a
# commit pushed straight to `main` past the pull request, and a tip served by
# anything that is not GitHub.
#
# It does NOT stop a compromised GitHub account. An attacker who can open and
# merge a pull request gets a signature like anyone else, and this host will
# deploy it within the hour. That risk is real, it is not new — the operator
# ran `make up` from this checkout after pulling, which executed the same code
# — and what this change alters is the window: from "whenever someone next
# deploys" to "at most an hour", with no human glancing at the diff. The
# compensating control is the record, not the gate. Every convergence writes
# the revision it deployed, and DeployBehind / DeployUnverified / DeployDrifted
# in prometheus/rules/deploy.rules.yaml make an unexpected one visible.
#
# WHY A DIRTY TREE IS A HARD STOP
#
# Refusing is the point. Overwriting is what the old model did, and losing the
# edit while never reporting it is problem 2 above. So an uncommitted change in
# the deployment checkout stops the run, exits non-zero, and shows up as
# ScheduledJobFailed and DeployDrifted — loudly, every hour, until a human
# either commits it or throws it away. There is no --force. `git checkout -- .`
# is one command and it is the human's to type.
#
# Usage:
#   scripts/converge.sh                    fetch, verify, fast-forward, make up
#   scripts/converge.sh --dry-run          say what it would do, change nothing
#   scripts/converge.sh --allow-unsigned   fast-forward past a failed signature
#
# Environment:
#   TEXTFILE_DIR             where homelab-deploy.prom goes
#                            (default /var/lib/node_exporter/textfile_collector)
#   HOMELAB_CONVERGE_APPLY   0 makes every run report-only, as though --dry-run
#                            had been passed. Set in /etc/default/homelab-timers
#                            to watch the agent decide for a while before
#                            letting it act. Recorded as
#                            homelab_deploy_apply_enabled, so the mode is
#                            visible from Prometheus rather than only from a
#                            file on the host.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The checkout the stack actually runs from. Same constant, same reasoning and
# the same refusal as scripts/install-timers.sh: `make render` writes into
# .rendered/ under the tree it is run from, and no container mounts a worktree's
# copy — so converging a second clone would report success while changing
# nothing the stack can see.
DEPLOY_ROOT="/home/robo/code/Gerrrt/HomeLab"

# Read-only, credential-free, and not taken from the checkout's own config.
CANONICAL_URL="https://github.com/Gerrrt/HomeLab.git"
BRANCH="main"

# GitHub's web-flow signing key, full fingerprint. Not the 16-hex key id: a key
# id is claimed by the signature itself and a fingerprint is not. The `%GF`
# placeholder is empty unless gpg actually verified, so comparing it to this is
# one comparison that asserts both "verified" and "by the right key".
#
# GitHub's published key file also carries 4AEE18F83AFDEB23, which EXPIRED on
# 2024-01-16 and is not this. Importing the file gets both; only this one is
# accepted.
SIGNING_FPR="968479A1AFF927E37D1A566BB5690EEEBB952194"

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="${TEXTFILE_DIR}/homelab-deploy.prom"

die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mwarning:\033[0m %s\n' "$*" >&2; }
green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }

usage() { sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

DRY_RUN=0
ALLOW_UNSIGNED=0
while (($#)); do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --allow-unsigned) ALLOW_UNSIGNED=1 ;;
    -h|--help)        usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

# The report-only switch, so the timer can be installed and watched before it is
# allowed to act. Folded into DRY_RUN rather than given a second code path —
# two ways to not-apply is two things to get wrong.
#
# APPLY_ENABLED is tracked SEPARATELY from DRY_RUN, and the distinction is the
# whole reason it exists. DRY_RUN is also set by --dry-run, which is a human
# asking a question; this is a property of how the host is configured. Only the
# second is worth recording, because only the second persists after the run and
# explains why a host stays behind.
#
# Without it, DeployBehind can only say "it is refusing, OR report-only is set",
# and telling those apart means someone with shell access reading a file in
# /etc that nothing else in this repository tracks. That is precisely the shape
# of unrecorded state #99 is about, so the mode goes in the record with
# everything else.
APPLY_ENABLED=1
if [[ "${HOMELAB_CONVERGE_APPLY:-1}" == "0" ]]; then
  info "HOMELAB_CONVERGE_APPLY=0 — reporting only, nothing will be applied"
  DRY_RUN=1
  APPLY_ENABLED=0
fi

# ---------------------------------------------------------------------------
# The record
# ---------------------------------------------------------------------------
#
# Same contract as scripts/run-scheduled.sh, and for the same reasons: written
# to a temp in the SAME directory then renamed, because rename(2) is atomic
# within a filesystem and a truncating write exposes a half-file to the
# collector; mode set explicitly, because Alloy runs with cap_drop [ALL] and so
# obeys the mode; a missing directory warns and a non-writable one dies.
#
# A SEPARATE FILE from converge.prom, which run-scheduled.sh owns. The two say
# different things and have different lifetimes: run-scheduled.sh records
# whether the JOB ran, this records what the HOST is running. The second
# survives being meaningful even when the first says the job failed — a
# convergence that refused to move still knows the revision it refused at.
RECORD=1
if [[ ! -d "${TEXTFILE_DIR}" ]]; then
  RECORD=0
  warn "no textfile directory at ${TEXTFILE_DIR} — converging without recording what is deployed"
  warn "on the monitoring host this means the timers were never installed: make install-timers"
elif [[ ! -w "${TEXTFILE_DIR}" ]]; then
  die "${TEXTFILE_DIR} is not writable by $(id -un).
The host would converge and nothing would record what it converged to, which is
the failure this script exists to prevent. Fix the directory, then re-run:
  sudo install -d -m 0755 -o $(id -un) -g $(id -gn) ${TEXTFILE_DIR}"
fi

# Filled in as the run progresses, written once by record(). Every one has a
# value that is honest before anything has been measured: an unverified
# revision, an unknown lag of -1, and a tree assumed clean until looked at.
REVISION=""
COMMIT_TS=0
BEHIND=-1
DIRTY=0
VERIFIED=0

recorded=0
record() {
  local tmp
  ((recorded)) && return 0
  recorded=1
  ((RECORD)) || return 0
  [[ -n "${REVISION}" ]] || return 0

  tmp="${TEXTFILE_DIR}/homelab-deploy.prom.$$"
  cat > "${tmp}" <<EOF
# HELP homelab_deploy_revision_info The commit the deployment checkout is on. Always 1; the revision is the label.
# TYPE homelab_deploy_revision_info gauge
homelab_deploy_revision_info{revision="${REVISION}"} 1
# HELP homelab_deploy_commit_timestamp_seconds Committer time of the deployed revision. time() minus this is how old the running configuration is.
# TYPE homelab_deploy_commit_timestamp_seconds gauge
homelab_deploy_commit_timestamp_seconds ${COMMIT_TS}
# HELP homelab_deploy_behind_commits Commits the fetched branch is ahead of the deployed revision. 0 is converged; -1 means the fetch did not complete.
# TYPE homelab_deploy_behind_commits gauge
homelab_deploy_behind_commits ${BEHIND}
# HELP homelab_deploy_tree_dirty 1 when the deployment checkout has uncommitted or untracked changes.
# TYPE homelab_deploy_tree_dirty gauge
homelab_deploy_tree_dirty ${DIRTY}
# HELP homelab_deploy_verified 1 when the deployed revision carries a good signature from the pinned key.
# TYPE homelab_deploy_verified gauge
homelab_deploy_verified ${VERIFIED}
# HELP homelab_deploy_apply_enabled 1 when this host applies what it fetches. 0 is report-only, set by HOMELAB_CONVERGE_APPLY=0.
# TYPE homelab_deploy_apply_enabled gauge
homelab_deploy_apply_enabled ${APPLY_ENABLED}
EOF
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${PROM}"

  # One structured line for the journal, which Alloy already ships to Loki with
  # a `unit` label — findable with LogQL without parsing anything above it.
  printf 'homelab-deploy revision=%s behind=%s dirty=%s verified=%s apply=%s\n' \
    "${REVISION}" "${BEHIND}" "${DIRTY}" "${VERIFIED}" "${APPLY_ENABLED}"
}
trap record EXIT

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[[ "${REPO_ROOT}" == "${DEPLOY_ROOT}" ]] \
  || die "refusing to converge ${REPO_ROOT}
The stack runs from ${DEPLOY_ROOT}, and \`make up\` here would render into a
.rendered/ directory that no container mounts — so this would report success
and change nothing. Run it from the deployment checkout."

cd "${DEPLOY_ROOT}"

command -v git >/dev/null 2>&1 || die "git is not installed"

# Read before any check that can fail, so that EVERY exit path records what the
# host is on — including the ones that give up. A refusal that leaves yesterday's
# metric in place is a refusal that reads as a healthy deployment.
REVISION="$(git rev-parse --short=12 HEAD)"
COMMIT_TS="$(git log -1 --format=%ct HEAD)"

# ---------------------------------------------------------------------------
# Signature
# ---------------------------------------------------------------------------
#
# Defined here and applied to HEAD immediately, so homelab_deploy_verified is a
# claim about the revision the host IS RUNNING on every exit path — including
# the paths that give up before fetching anything. Evaluating it only alongside
# the fetched tip would make the metric mean "the last thing we were offered",
# which is a different and much less useful sentence.
verify_commit() {
  local ref="$1" sig fpr
  sig="$(git log -1 --format='%G?' "${ref}")"
  fpr="$(git log -1 --format='%GF' "${ref}")"
  [[ "${fpr}" == "${SIGNING_FPR}" ]] || return 1
  # G is a good signature from a key marked trusted; U is a good signature from
  # a key that is not. Both are accepted, because ownertrust is a statement
  # about a local keyring and the fingerprint above is the actual assertion —
  # requiring G would mean every host had to run `gpg --lsign-key` as well as
  # import, for no additional guarantee.
  [[ "${sig}" == "G" || "${sig}" == "U" ]] || return 1
  return 0
}

verify_commit HEAD && VERIFIED=1

current_branch="$(git symbolic-ref --quiet --short HEAD || true)"
[[ "${current_branch}" == "${BRANCH}" ]] \
  || die "the deployment checkout is on '${current_branch:-a detached HEAD}', not ${BRANCH}.
Convergence only ever fast-forwards ${BRANCH}. Someone left this checkout
somewhere else; put it back deliberately rather than letting a timer do it:
  git -C ${DEPLOY_ROOT} switch ${BRANCH}"

# `origin` is not used for anything — the fetch names its own URL — but a
# checkout whose origin has been repointed is worth saying out loud, because it
# means someone has been editing the deployment host's git config.
origin_url="$(git remote get-url origin 2>/dev/null || true)"
case "${origin_url}" in
  "${CANONICAL_URL}"|git@github.com:Gerrrt/HomeLab.git|https://github.com/Gerrrt/HomeLab) ;;
  "") warn "no 'origin' remote configured — fetching ${CANONICAL_URL} regardless" ;;
  *)  warn "origin is ${origin_url}, which is not the canonical repository.
    Nothing here reads it — the fetch below names ${CANONICAL_URL} explicitly —
    but somebody changed it, and that is worth knowing." ;;
esac

# ---------------------------------------------------------------------------
# Drift: has anything on the host diverged from what is committed?
# ---------------------------------------------------------------------------
#
# --porcelain skips ignored files, which is exactly right: .rendered/, .env,
# certificates/ and backups/ are all gitignored, all written by the deploy
# itself, and none of them is drift. What is left is a tracked file someone
# edited in place, or an untracked file someone dropped in the tree — both of
# which are the thing #99 says goes unnoticed until a deploy destroys it.
dirty_files="$(git status --porcelain --untracked-files=normal)"
if [[ -n "${dirty_files}" ]]; then
  DIRTY=1
  printf '%s\n' "${dirty_files}" >&2
  die "the deployment checkout has uncommitted changes (above).

Converging would overwrite them, which is exactly the silent loss #99 is about,
so this stops instead and will keep stopping — DeployDrifted and
ScheduledJobFailed will both be firing — until a human decides which it is:

  keep it     git -C ${DEPLOY_ROOT} diff            # then commit it, on a branch, via a pull request
  drop it     git -C ${DEPLOY_ROOT} checkout -- .   # and remove any untracked files it listed

There is no --force. Choosing is the whole point."
fi

# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------
info "fetching ${BRANCH} from ${CANONICAL_URL}"
# --no-tags because nothing here reads a tag and a tag is another thing that can
# move. No --depth: a shallow fetch has no merge base, so the fast-forward
# assertion and the behind-count below would both be unanswerable.
git fetch --quiet --no-tags "${CANONICAL_URL}" "${BRANCH}" \
  || die "could not fetch ${BRANCH} from ${CANONICAL_URL}.
The host stays on ${REVISION}, which is the correct outcome of not knowing what
${BRANCH} says. If this persists, DeployBehind will not fire — nothing was
learned about how far behind the host is — but ScheduledJobFailed will."

TARGET="$(git rev-parse FETCH_HEAD)"
BEHIND="$(git rev-list --count "HEAD..${TARGET}")"

# ---------------------------------------------------------------------------
# Verify the tip before it becomes the deployed revision
# ---------------------------------------------------------------------------
target_verified=0
verify_commit "${TARGET}" && target_verified=1

if ((target_verified == 0)); then
  # Distinguish the two reasons, because they need different responses: a
  # missing key is a setup step nobody did, and a missing signature is a commit
  # that did not come through a pull request.
  detail="signature: $(git log -1 --format='%G?' "${TARGET}"), key: $(git log -1 --format='%GK' "${TARGET}" || true)"
  if ! gpg --batch --list-keys "${SIGNING_FPR}" >/dev/null 2>&1; then
    hint="The signing key is not in $(id -un)'s keyring on this host, so nothing
CAN verify. Import it once — docs/runbooks/converge-the-host.md:
  curl -fsSL https://github.com/web-flow.gpg | gpg --import
Then confirm the fingerprint it printed is ${SIGNING_FPR}."
  else
    hint="The key is present and this commit did not verify against it, which
means ${BRANCH} moved by something other than a GitHub merge — a direct push, or
a tip served by something that is not GitHub. Look at it before deploying it:
  git -C ${DEPLOY_ROOT} log --show-signature -1 ${TARGET}"
  fi

  if ((ALLOW_UNSIGNED)); then
    warn "${TARGET} did not verify (${detail}) — continuing because --allow-unsigned was passed"
  else
    die "${TARGET} did not verify (${detail}).

${hint}

The host stays on ${REVISION}. To deploy it anyway, deliberately and by hand:
  ${DEPLOY_ROOT}/scripts/converge.sh --allow-unsigned"
  fi
fi

# ---------------------------------------------------------------------------
# Converge
# ---------------------------------------------------------------------------
if [[ "${TARGET}" == "$(git rev-parse HEAD)" ]]; then
  BEHIND=0
  green "converged — ${REVISION} is ${BRANCH}"
  # Nothing rendered, no container touched, docker never called. This is the
  # path an hourly cadence spends almost all of its time on.
  exit 0
fi

# Fast-forward only. A non-fast-forward means `main` was rewritten or this
# checkout has commits of its own, and quietly resolving either one is how a
# deployment host ends up running something no branch points at.
git merge-base --is-ancestor HEAD "${TARGET}" \
  || die "${TARGET} is not a fast-forward from ${REVISION}.
Either ${BRANCH} was rewritten, or this checkout has local commits. Both need a
human — a timer that resolves this is a timer that can roll the host backwards
onto a revision someone deliberately replaced.
  git -C ${DEPLOY_ROOT} log --oneline ${REVISION}..${TARGET}
  git -C ${DEPLOY_ROOT} log --oneline ${TARGET}..${REVISION}"

info "${BEHIND} commit(s) behind — ${REVISION} to $(git rev-parse --short=12 "${TARGET}")"
git --no-pager log --oneline --no-decorate "HEAD..${TARGET}" | sed 's/^/     /' >&2

if ((DRY_RUN)); then
  # REVISION, COMMIT_TS and VERIFIED still describe HEAD, which is still what is
  # deployed — the whole point of not applying. Only BEHIND changed, and it is
  # the number that says so.
  warn "dry run — not applying"
  exit 0
fi

git merge --ff-only --quiet "${TARGET}"
REVISION="$(git rev-parse --short=12 HEAD)"
COMMIT_TS="$(git log -1 --format=%ct HEAD)"
BEHIND=0
VERIFIED="${target_verified}"

# `make up` and not a narrower command, on purpose. It renders the config,
# recreates whatever compose says changed, and runs reload-config.sh for the
# services that read their config once at startup — and it is what every runbook
# already tells a human to type, so there is exactly one deployment path and it
# is exercised both ways.
info "applying ${REVISION}"
make up

green "converged to ${REVISION}"
