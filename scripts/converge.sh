#!/usr/bin/env bash
#
# Bring the deployment checkout to what `main` says, and record what is
# deployed (#99).
#
#   scripts/converge.sh [--stack observability|sensitive] [--dry-run] [--allow-unsigned]
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
# tip, the tree is clean and `make up` last applied that same revision, nothing
# is rendered, no container is touched and docker is never called — which is
# what makes an hourly cadence reasonable.
#
# "AT THE TIP" IS NOT "DEPLOYED", and the first version treated it as though it
# were. On 2026-10-01 the checkout reached #781's merge by a `git pull` by hand,
# with no `make up`. This script then compared HEAD with `main`, found them
# equal and recorded "converged", behind=0, hourly, while Prometheus served the
# pre-merge rules — every deploy alert reads HEAD, so none could see it. `make
# up` now ends by recording the revision it applied (scripts/record-applied.sh),
# and HEAD is compared with that too: a checkout that moved without a deploy is
# deployed on the next run, and homelab_deploy_unapplied says so until it is.
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
#   scripts/converge.sh --allow-red        deploy a tip whose CI did not pass (#833)
#   scripts/converge.sh --self-test        run the CI gate's fixtures
#   scripts/converge.sh --stack sensitive  converge trinity's tier, not the
#                                          monitoring host's (default observability)
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

# ---------------------------------------------------------------------------
# CI: did the tip pass before it is deployed? (#833)
# ---------------------------------------------------------------------------
#
# The signature proves a commit came through a GitHub merge. It does not prove
# the merge was green: until #833 the ruleset required no status checks, so a
# pull request with a failing Lint could be merged, signed, and deployed here
# within the hour. The ruleset now requires them (.github/rulesets/main.json),
# and this asks again on the host, so the gate does not live only in a GitHub
# setting that a later edit can loosen without a diff anyone reviews.
#
# What is asked is the merge commit's OWN push run, not the pull request's:
# the commit being deployed is the one that has to have passed.
#
# The four ci.yml jobs that run on a push to main. "No close keyword in prose"
# is required by the ruleset but runs on pull_request only, so a merge commit
# never carries it and requiring it here would hold every deploy forever.
# scripts/check-ruleset.sh asserts this list sits inside the ruleset's.
REQUIRED_CHECKS=("Lint" "Validate configs" "Boot hardened services" "Secret scan")

# Anonymous and read-only, for the reason the fetch below uses an https URL:
# nothing on this host holds a GitHub credential. 60 requests an hour per
# address is the anonymous limit; this asks once per run, and only on runs that
# have something to deploy.
ci_fetch() {
  curl -fsS --max-time 20 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/Gerrrt/HomeLab/commits/$1/check-runs?per_page=100&filter=latest"
}

# check-runs JSON on stdin -> one line per required check:
#   <name> TAB <status> TAB <conclusion>
# status is GitHub's (queued, in_progress, completed) or `missing` when no run of
# that name exists; conclusion is GitHub's (success, failure, cancelled,
# timed_out, ...) or `-` until completed. Only runs posted by GitHub Actions
# count: on a public repository another installed app could post a check named
# "Lint", and the ruleset pins integration_id for the same reason.
ci_summarise() {
  python3 -c '
import json, sys
required = sys.argv[1:]
runs = json.load(sys.stdin).get("check_runs", [])
latest = {}
for r in runs:
    if (r.get("app") or {}).get("slug") != "github-actions":
        continue
    name = r.get("name")
    if name in required and (name not in latest or r.get("id", 0) > latest[name].get("id", 0)):
        latest[name] = r
for name in required:
    r = latest.get(name)
    if r is None:
        print("\t".join([name, "missing", "-"]))
    else:
        print("\t".join([name, r.get("status") or "-", r.get("conclusion") or "-"]))
' "${REQUIRED_CHECKS[@]}"
}

# Decide what the summary means. Prints exactly one word: green, wait or red.
#
#   $1  seconds since the tip was committed. Passed for the record and a
#       future policy; the one below deliberately does not use it
#   $2  1 if the API answered, 0 if curl or the JSON parse failed
#   stdin  the lines ci_summarise printed (nothing at all when $2 is 0)
#
# What each word does to the run:
#   green  deploy it
#   wait   leave the host where it is and exit 0; the next hourly run asks again,
#          and DeployBehind fires if waiting lasts 3h
#   red    refuse, exit non-zero (ScheduledJobFailed, DeployTipRed), unless
#          --allow-red was passed
#
# The policy (#833): only a check that FINISHED and FAILED is red. Everything
# that is merely not-yet-known waits, and a wait that never ends is DeployBehind
# at 3h, not a silent deploy:
#
#   missing     wait. A fresh merge may not have started CI; a renamed job never
#               will, and holding the host until a human looks is the safe half
#               of that ambiguity. The commit's age is not used for that reason.
#   cancelled   wait. ci.yml cancels a run when the next push lands, so a
#               cancellation is usually "superseded", not "failed". So is stale.
#   API down    wait. Proceeding would mean an unreachable GitHub disables the
#               gate; staying keeps the host on configuration that did pass.
#
# A red anywhere wins over a wait elsewhere: a failure is final, and waiting on
# the other checks would only delay saying so. neutral and skipped pass, as they
# do for the ruleset's required checks.
ci_verdict() {
  local api_ok="$2" name status conclusion red=0 wait=0 seen=0
  # Drain stdin on every path, so the writer never dies of a broken pipe.
  while IFS=$'\t' read -r name status conclusion; do
    [[ -n "${name}" ]] || continue
    seen=$((seen + 1))
    if [[ "${status}" != "completed" ]]; then
      wait=1                                    # queued, in_progress, missing
    else
      case "${conclusion}" in
        success|neutral|skipped) ;;
        cancelled|stale)         wait=1 ;;
        *)                       red=1 ;;       # failure, timed_out, action_required, ...
      esac
    fi
  done
  if ((red)); then echo red
  elif ((api_ok == 0 || seen == 0 || wait)); then echo wait
  else echo green
  fi
}

# Fixtures for the three functions above: the parse against check-runs shaped
# like GitHub's, and the verdict against each state a tip can be in. The rest of
# this script needs a deployment checkout and a network, and is #854's.
self_test() {
  local fail=0 got
  check() {
    if [[ "$2" == "$3" ]]; then printf '\033[0;32m  PASS\033[0m %s\n' "$1"
    else printf '\033[0;31m  FAIL\033[0m %s\n       got      %s\n       expected %s\n' "$1" "$2" "$3"; fail=1; fi
  }
  # One check-run. $1 name, $2 status, $3 conclusion (null for none), $4 app, $5 id.
  run() { printf '{"id":%s,"name":"%s","status":"%s","conclusion":%s,"app":{"slug":"%s"}}' "$5" "$1" "$2" "$3" "$4"; }
  runs() { local IFS=,; printf '{"total_count":%s,"check_runs":[%s]}' "$#" "$*"; }
  # The tip of main on 2026-10-03, as the API returned it, CodeQL included.
  green_tip() {
    runs "$(run 'Analyze (python)' completed '"success"' github-actions 1)" \
         "$(run Lint completed '"success"' github-actions 2)" \
         "$(run 'Validate configs' completed '"success"' github-actions 3)" \
         "$(run 'Boot hardened services' completed '"success"' github-actions 4)" \
         "$(run 'Secret scan' completed '"success"' github-actions 5)"
  }
  verdict() { printf '%s' "$1" | ci_summarise | ci_verdict "$2" 1; }

  got="$(green_tip | ci_summarise | cut -f2,3 | sort -u | tr '\t\n' ': ')"
  check "the four required checks are read, CodeQL is not" "${got}" "completed:success "
  got="$(runs "$(run Lint completed '"success"' some-other-app 9)" | ci_summarise | head -1)"
  check "a 'Lint' from another app is not Actions' Lint" "${got}" "$(printf 'Lint\tmissing\t-')"
  got="$(runs "$(run Lint completed '"failure"' github-actions 1)" "$(run Lint completed '"success"' github-actions 2)" \
         | ci_summarise | head -1)"
  check "a re-run supersedes the run it re-ran" "${got}" "$(printf 'Lint\tcompleted\tsuccess')"
  got="$(runs "$(run Lint in_progress null github-actions 1)" | ci_summarise | head -1)"
  check "a running check has no conclusion yet" "${got}" "$(printf 'Lint\tin_progress\t-')"

  check "all four green is green" "$(verdict "$(green_tip)" 600)" green
  check "one failure is red" \
    "$(verdict "$(green_tip | sed 's/"name":"Lint","status":"completed","conclusion":"success"/"name":"Lint","status":"completed","conclusion":"failure"/')" 600)" red
  check "one still running is wait" \
    "$(verdict "$(green_tip | sed 's/"name":"Secret scan","status":"completed","conclusion":"success"/"name":"Secret scan","status":"in_progress","conclusion":null/')" 120)" wait
  # The policy's three waits, each of which a looser rule would turn into a
  # deploy or a page.
  check "a required check with no run at all is wait, however old the tip" \
    "$(verdict "$(runs "$(run Lint completed '"success"' github-actions 2)")" 86400)" wait
  check "a cancelled check is wait: superseded, not failed" \
    "$(verdict "$(green_tip | sed 's/"name":"Lint","status":"completed","conclusion":"success"/"name":"Lint","status":"completed","conclusion":"cancelled"/')" 600)" wait
  check "an API that did not answer is wait, never green" \
    "$(ci_verdict 600 0 </dev/null)" wait
  check "an answer with no lines is wait, never green" \
    "$(printf '' | ci_verdict 600 1)" wait
  check "timed_out is a failure" \
    "$(verdict "$(green_tip | sed 's/"name":"Lint","status":"completed","conclusion":"success"/"name":"Lint","status":"completed","conclusion":"timed_out"/')" 600)" red
  check "a failure beats a check still running" \
    "$(verdict "$(runs "$(run Lint completed '"failure"' github-actions 1)" "$(run 'Secret scan' in_progress null github-actions 2)")" 600)" red

  return "${fail}"
}

DRY_RUN=0
ALLOW_UNSIGNED=0
ALLOW_RED=0
DEPLOY_STACK="observability"
while (($#)); do
  case "$1" in
    --self-test)      self_test; exit $? ;;
    --dry-run)        DRY_RUN=1 ;;
    --allow-unsigned) ALLOW_UNSIGNED=1 ;;
    --allow-red)      ALLOW_RED=1 ;;
    --stack)          [[ $# -ge 2 ]] || die "--stack needs a value"
                      DEPLOY_STACK="$2"; shift ;;
    --stack=*)        DEPLOY_STACK="${1#--stack=}" ;;
    -h|--help)        usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

# What `make up` deploys here, named rather than left to the Makefile's default,
# because the applied-revision record is per stack and must be the one read.
#
# And the checkout that stack actually runs from. Same rule, same reasoning and
# the same refusal as scripts/install-timers.sh: `make render` writes into
# .rendered/ under the tree it is run from, and no container mounts a worktree's
# copy — so converging a second clone would report success while changing
# nothing the stack can see.
#
# Two stacks pull, on two hosts (#533). The monitoring host's checkout is robo's
# and is pinned by name. trinity's operator is written <you> by the build
# runbook, so its checkout is the one under the running user's home — the same
# derivation as install-timers.sh's sensitive profile, which renders the unit
# that runs this. Any other stack is pushed to (ADR-0021), not pulled, and is
# refused here rather than converged from a root nobody chose.
case "${DEPLOY_STACK}" in
  observability) DEPLOY_ROOT="/home/robo/code/Gerrrt/HomeLab" ;;
  sensitive)     DEPLOY_ROOT="${HOME:?}/code/Gerrrt/HomeLab" ;;
  *) die "nothing converges stack '${DEPLOY_STACK}' — only observability (prometheus) and sensitive (trinity) pull" ;;
esac

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
  warn "on a deployment host this means the timers were never installed: make install-timers (PROFILE=sensitive on trinity)"
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
# 1 when HEAD is not the revision `make up` last applied. 0 until measured,
# which happens right beside HEAD below, before anything can refuse.
UNAPPLIED=0
# What CI said about the fetched tip. -1 until asked, and stays -1 on a run with
# nothing to deploy, because nothing was asked.
CI_TIP=-1

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
# HELP homelab_deploy_commit_timestamp_seconds Committer time of the checkout's revision; how old the running configuration is while homelab_deploy_unapplied is 0.
# TYPE homelab_deploy_commit_timestamp_seconds gauge
homelab_deploy_commit_timestamp_seconds ${COMMIT_TS}
# HELP homelab_deploy_behind_commits Commits the fetched branch is ahead of the checkout. 0 is at the tip; -1 means the fetch did not complete.
# TYPE homelab_deploy_behind_commits gauge
homelab_deploy_behind_commits ${BEHIND}
# HELP homelab_deploy_tree_dirty 1 when the deployment checkout has uncommitted or untracked changes.
# TYPE homelab_deploy_tree_dirty gauge
homelab_deploy_tree_dirty ${DIRTY}
# HELP homelab_deploy_verified 1 when the checkout's revision carries a good signature from the pinned key; the deployed one's while homelab_deploy_unapplied is 0.
# TYPE homelab_deploy_verified gauge
homelab_deploy_verified ${VERIFIED}
# HELP homelab_deploy_apply_enabled 1 when this host applies what it fetches. 0 is report-only, set by HOMELAB_CONVERGE_APPLY=0.
# TYPE homelab_deploy_apply_enabled gauge
homelab_deploy_apply_enabled ${APPLY_ENABLED}
# HELP homelab_deploy_unapplied 1 when the checkout's HEAD is not the revision make up last applied: it moved without a deploy, or the deploy failed.
# TYPE homelab_deploy_unapplied gauge
homelab_deploy_unapplied ${UNAPPLIED}
# HELP homelab_deploy_tip_ci What CI said about the fetched tip: 1 passed, 0 did not, -1 not asked (nothing to deploy) or not finished.
# TYPE homelab_deploy_tip_ci gauge
homelab_deploy_tip_ci ${CI_TIP}
EOF
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${PROM}"

  # One structured line for the journal, which Alloy already ships to Loki with
  # a `unit` label — findable with LogQL without parsing anything above it.
  printf 'homelab-deploy revision=%s behind=%s dirty=%s verified=%s apply=%s unapplied=%s tip_ci=%s\n' \
    "${REVISION}" "${BEHIND}" "${DIRTY}" "${VERIFIED}" "${APPLY_ENABLED}" "${UNAPPLIED}" "${CI_TIP}"
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

# Read before any check about the STATE of this checkout — the branch it is on,
# whether it is clean, what it can fetch — so that every one of those refusals
# still records what the host is running. A refusal that leaves yesterday's
# metric in place is a refusal that reads as a healthy deployment.
#
# Three guards do run earlier and can exit before this line, and all three are
# cases where recording nothing is the correct outcome rather than a gap:
#
#   - an unwritable TEXTFILE_DIR, where recording is impossible by definition
#     and dying is the point;
#   - REPO_ROOT != DEPLOY_ROOT, where HEAD belongs to some other checkout, and
#     writing its revision as "what is deployed" would be an actively false
#     statement about the host rather than a missing one;
#   - git absent, where there is no revision to read.
#
# So the claim is narrower than "before anything that can fail", and stating it
# loosely was wrong: a maintainer reading the loose version would think the
# earlier guards were an oversight to fix.
REVISION="$(git rev-parse --short=12 HEAD)"
COMMIT_TS="$(git log -1 --format=%ct HEAD)"

# What the last finished `make up` applied, beside where HEAD is. Empty when no
# deploy has recorded one — the first run after this check shipped, or a fresh
# clone — and that counts as unapplied: one redeploy of what is already running
# is cheap, and assuming a deploy that may never have happened is the bug.
APPLIED="$(./scripts/record-applied.sh --read "${DEPLOY_STACK}" 2>/dev/null || true)"
[[ "${APPLIED}" == "$(git rev-parse HEAD)" ]] || UNAPPLIED=1

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
  ${DEPLOY_ROOT}/scripts/converge.sh --stack ${DEPLOY_STACK} --allow-unsigned"
  fi
fi

# ---------------------------------------------------------------------------
# Ask whether the tip passed CI (#833)
# ---------------------------------------------------------------------------
#
# Only when there is something to deploy. The no-op path stays one fetch and no
# API call, which is what keeps the hourly cadence free.
if [[ "${TARGET}" != "$(git rev-parse HEAD)" ]] || ((UNAPPLIED)); then
  tip_age=$(( $(date +%s) - $(git log -1 --format=%ct "${TARGET}") ))
  if ci_summary="$(ci_fetch "${TARGET}" | ci_summarise 2>/dev/null)" && [[ -n "${ci_summary}" ]]; then
    ci_api_ok=1
  else
    ci_api_ok=0
    ci_summary=""
  fi
  verdict="$(printf '%s' "${ci_summary}" | ci_verdict "${tip_age}" "${ci_api_ok}")"
  [[ -n "${ci_summary}" ]] && printf '%s\n' "${ci_summary}" | sed 's/^/     /; s/\t/  /g' >&2

  case "${verdict}" in
    green)
      CI_TIP=1
      info "CI passed on $(git rev-parse --short=12 "${TARGET}")" ;;
    wait)
      CI_TIP=-1
      warn "CI has not finished with $(git rev-parse --short=12 "${TARGET}") — staying on ${REVISION}; the next run asks again"
      exit 0 ;;
    red)
      CI_TIP=0
      if ((ALLOW_RED)); then
        warn "CI did not pass on ${TARGET} — continuing because --allow-red was passed"
      else
        die "CI did not pass on ${TARGET} (above).

The ruleset should have stopped this merging; that it reached ${BRANCH} at all is
worth reading .github/rulesets/main.json and the merge's checks for. The host
stays on ${REVISION}. To deploy it anyway, deliberately and by hand:
  ${DEPLOY_ROOT}/scripts/converge.sh --stack ${DEPLOY_STACK} --allow-red"
      fi ;;
    *)
      die "ci_verdict said '${verdict}', which is none of green, wait or red" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Converge
# ---------------------------------------------------------------------------
if [[ "${TARGET}" == "$(git rev-parse HEAD)" ]]; then
  BEHIND=0
  if ((UNAPPLIED == 0)); then
    green "converged — ${REVISION} is ${BRANCH}"
    # Nothing rendered, no container touched, docker never called. This is the
    # path an hourly cadence spends almost all of its time on.
    exit 0
  fi
  # At the tip and never deployed from it — the 2026-10-01 shape. Not a
  # fast-forward, so nothing to verify beyond what was verified above; just
  # the deploy that the move skipped.
  warn "the checkout is at ${REVISION}, but make up last applied ${APPLIED:-nothing on record}"
  if ((DRY_RUN)); then
    warn "dry run — not applying"
    exit 0
  fi
  info "applying ${REVISION}"
  make up STACK="${DEPLOY_STACK}"
  UNAPPLIED=0
  green "converged — ${REVISION} is ${BRANCH}, and now deployed"
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
# Moved and not yet deployed. If `make up` fails below, set -e exits with this
# still 1, and the record says the checkout is ahead of what is running.
UNAPPLIED=1

# `make up` and not a narrower command, on purpose. It renders the config,
# recreates whatever compose says changed, and runs reload-config.sh for the
# services that read their config once at startup — and it is what every runbook
# already tells a human to type, so there is exactly one deployment path and it
# is exercised both ways.
info "applying ${REVISION}"
make up STACK="${DEPLOY_STACK}"
UNAPPLIED=0

green "converged to ${REVISION}"
