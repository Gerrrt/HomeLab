#!/usr/bin/env bash
#
# Pull morpheus's pfSense configuration, encrypt it at rest, and copy it off
# this host.
#
# morpheus routes every VLAN in this lab. If it dies, the house has no DHCP, no
# DNS and no internet until it is rebuilt — and until this script existed there
# was no config export, no runbook and no spare. That is the single largest
# unmitigated failure in the estate; see docs/runbooks/restore-the-firewall.md.
#
# WHY THE OUTPUT IS NOT COMMITTED
#
# Every other secret here lives in the repository, SOPS-encrypted, because
# `git log -p` then shows which credential rotated and when. A firewall config
# is different in kind. config.xml carries the WAN address, the full rule set,
# user password hashes and any certificate material — and docs/security.md
# states plainly that rule bodies and the WAN address are deliberately not
# published. Committing them, even encrypted, to a public repository means one
# age-key compromise hands over the complete blueprint of the network. This
# repository has already had one credential exposure; that is enough.
#
# So backups/ is gitignored, `make validate` asserts nothing under it is
# tracked, and CI asserts the same. The repository holds the tooling. The
# artifact goes to the backup target and offsite.
#
# WHY THE COPY IS PART OF THE JOB AND NOT A SEPARATE ONE
#
# For its first two weeks this script ended by printing "copy it to the backup
# target and offsite", and nothing did (#92). A backup on the machine it
# protects covers morpheus failing and nothing else; the shelf `prometheus`
# sits on is the same room, the same mains and the same burglar. So the copy is
# now a step of THIS job, and a run whose copy fails exits non-zero even though
# the local file was written and verified. That is deliberate: the nightly
# timer records the exit code (scripts/run-scheduled.sh), so "the export is
# happening but has stopped leaving this host" becomes ScheduledJobFailed
# within the hour instead of a sentence nobody reads. A separate copy job with
# its own metric would say the same thing with one more unit, one more lock and
# one more threshold to keep coherent.
#
# WHERE IT GOES, AND WHAT THE FAR END CAN DO WITH IT
#
# `oracle` (10.0.99.30), the other laptop on the shelf. It has no role (#94),
# it is on the management segment already, and this is the smallest job that
# needs a machine that is not the monitoring host: a directory and sshd. The
# age private key is NOT copied there and must never be. What lands on oracle
# is sops ciphertext, which is what makes a second copy of the most sensitive
# artefact in the estate acceptable — a compromise of oracle yields nothing,
# and a compromise of the key on prometheus yields what it already yielded.
#
# The login there is `atropos`, not `robo`. This shipped defaulting to
# `robo@10.0.99.30` and every copy would have failed on `Permission denied`
# from the first nightly run — the local export written and verified, the copy
# step dead, the job correctly reporting failure for a reason nobody would have
# guessed from the message. It was invisible for a day only because the
# checkout the timer runs from was behind this commit's parent.
#
# Same room, so this is off-host and not offsite. A fire still takes both.
# Offsite is the half that still has no destination; see docs/roadmap.md.
#
# The verification pulls the bytes BACK and compares them against the file that
# was just proven to decrypt — proving the remote holds a restorable backup
# without the remote ever being able to read one. Known limit, stated rather
# than engineered away: the ssh key that writes there can also delete there. A
# rogue prometheus could clobber every copy on oracle. Retention below widens
# that key's reach from overwrite to remove, which is the same trust in the
# same key rather than a new exposure. Append-only storage is a different
# mechanism and a different issue.
#
# WHAT RETENTION DELETES, AND WHAT IT REFUSES TO
#
# For its first day this script kept every export it had ever taken, on both
# sides, forever. Nightly, that is unbounded. FW_KEEP bounds it: the newest
# FW_KEEP exports survive here and on the far side, and nothing else is
# touched. The newest is never evicted, a file this script did not write is
# counted and reported but never deleted, and a name that fails validation is
# refused rather than removed — the posture scripts/backup-volumes.sh prune()
# already sets.
#
# It is one knob for both sides on purpose. A smaller far-side bound would have
# prune remove what the next run's copy step then re-uploads, nightly, forever;
# a larger one cannot be expressed at all, because the delete list is derived
# from a locally-computed picture of what the far side should be holding.
#
# FW_KEEP and not KEEP: all four units read the same /etc/default/homelab-timers
# and scripts/backup-volumes.sh already owns `KEEP` there. One line meant for
# nightly exports would otherwise also reset the retention on weekly volume
# sets, which are measured in gigabytes.
#
# Usage:
#   scripts/backup-firewall.sh                    pull, encrypt, verify, copy off-host
#   scripts/backup-firewall.sh --local-only       the same without the copy — bench use
#   scripts/backup-firewall.sh --verify-only      re-verify the newest backup, here and on the far side
#   scripts/backup-firewall.sh --list             show what exists, here and on the far side
#   scripts/backup-firewall.sh --prune            apply retention only, both sides
#
# Environment:
#   FW_HOST      default morpheus.matrix.elysium (falls back to 10.0.99.1)
#   FW_USER      default root
#   FW_PATH      default /cf/conf/config.xml
#   FW_OFFHOST   default atropos@10.0.99.30:backups/firewall — user@host:dir,
#                the dir relative to that user's home unless absolute. The
#                nightly unit can override it in /etc/default/homelab-timers.
#   FW_KEEP      default 30              exports to retain, here and there
set -euo pipefail

FW_HOST="${FW_HOST:-10.0.99.1}"
FW_USER="${FW_USER:-root}"
FW_PATH="${FW_PATH:-/cf/conf/config.xml}"
FW_OFFHOST="${FW_OFFHOST:-atropos@10.0.99.30:backups/firewall}"
FW_KEEP="${FW_KEEP:-30}"
OUT_DIR="backups/firewall"
SOPS_POLICY=".sops.yaml"

# Nightly, so 30 is a month of history — long enough to reach back past a bad
# firewall change nobody noticed for a fortnight. backup-volumes.sh keeps 7 of
# a WEEKLY set, which is a longer window from a smaller number; the cadences
# differ, so the numbers do too.
#
# Rejected rather than clamped: a mistyped FW_KEEP in an environment file is
# not a request to delete every backup of the firewall.
if ! [[ $FW_KEEP =~ ^[0-9]+$ ]] || ((FW_KEEP < 1)); then
  printf '\033[0;31mFW_KEEP must be a positive integer, got %s\033[0m\n' "$FW_KEEP" >&2
  exit 1
fi

# BatchMode so a missing key, or an unknown host key, fails loudly instead of
# hanging a timer on a prompt.
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;34m--\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { red "missing dependency: $1"; exit 1; }; }

# The age recipient is read from .sops.yaml rather than duplicated here. One
# source of truth for the key; rotating it in .sops.yaml rotates it here too.
recipient() {
  grep -oE 'age1[0-9a-z]{50,}' "$SOPS_POLICY" | head -1
}

# Newest first, sorted by NAME and not by mtime. The stamp is UTC ISO-8601
# basic form, so a reverse name sort IS a reverse chronological sort — the same
# rule and the same reasoning as backup-volumes.sh. It matters twice now that
# retention exists: mtime is something a touch, a cp or a restore-from-media can
# change, and retention must not key on it; and the far side can only offer a
# name sort, so keying on names here makes both sides the same function of the
# same strings. Two orderings in one script is how the two sides come to
# disagree about which are the newest FW_KEEP, and that disagreement is a
# delete/re-upload loop that repeats every night.
list_backups() {
  if [[ -d $OUT_DIR ]] && compgen -G "$OUT_DIR/*.sops.yaml" >/dev/null; then
    ls -1r "$OUT_DIR"/*.sops.yaml
  fi
}

newest() { list_backups | head -1; }

# An untested backup is not a backup. Decrypt what we just wrote, in a clean
# environment, and confirm it is a pfSense config rather than an empty file or
# an error page.
verify() {
  local f="$1" plain
  [[ -f $f ]] || { red "no such backup: $f"; exit 1; }
  # --input-type yaml, matching the --output-type yaml these are written with.
  # It said binary, which made sops parse a `data: ENC[...]` document as JSON
  # and fail on the first character. Like the creation-rule bug above it had
  # never run, because the encrypt half died before anything reached here.
  # --output-type binary is right and stays: it emits the stored bytes, which
  # are the config XML.
  plain="$(env -i "PATH=$PATH" "HOME=$HOME" sops --decrypt --input-type yaml --output-type binary "$f" 2>/dev/null)" \
    || { red "FAILED to decrypt $f"; exit 1; }
  grep -q '<pfsense>' <<<"$plain" \
    || { red "decrypted $f but it does not look like a pfSense config"; exit 1; }
  local rules ver
  rules=$(grep -c '<rule>' <<<"$plain" || true)
  ver=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' <<<"$plain" | head -1)
  green "verified $(basename "$f") — config version ${ver:-unknown}, ${rules} firewall rules"
}

# ---------------------------------------------------------------------------
# The far side
#
# Nothing here needs more than sshd and coreutils on the target: no rsync, no
# agent, no key. Files are streamed over ssh into a temp name and renamed, so a
# copy that dies mid-transfer leaves a .part on the far side and never a
# plausible-looking backup that is short.
# ---------------------------------------------------------------------------
OFFHOST_TARGET="${FW_OFFHOST%%:*}"
OFFHOST_DIR="${FW_OFFHOST#*:}"
[[ $FW_OFFHOST == *:* && -n $OFFHOST_TARGET && -n $OFFHOST_DIR ]] \
  || { red "FW_OFFHOST must be user@host:dir, got '$FW_OFFHOST'"; exit 1; }

# The checks above are enough for a directory only ever handed to `ls` and
# `cat`. They are not enough for one handed to `rm`, and retention now hands it
# to `rm`. FW_OFFHOST is read from an operator-edited
# /etc/default/homelab-timers, so this is typo-safety and not a threat model —
# but a stray quote in that file would otherwise close the quoting around
# $OFFHOST_DIR and turn the rest of the line into remote command text. Same
# rule as backup-volumes.sh: never construct an rm target from an unvalidated
# variable.
[[ $OFFHOST_DIR =~ ^[A-Za-z0-9._/-]+$ ]] \
  || { red "FW_OFFHOST directory may only contain letters, digits, . _ - and /, got '$OFFHOST_DIR'"; exit 1; }
[[ $OFFHOST_DIR != "/" && $OFFHOST_DIR != *..* ]] \
  || { red "FW_OFFHOST directory may not be / or contain '..', got '$OFFHOST_DIR'"; exit 1; }

# zsh resolves a `cd` argument through CDPATH unless it starts with / ./ or ../
# and oracle's login shell IS zsh, so a CDPATH set in its zshenv could land the
# prune's cd somewhere else entirely. Anchoring it here costs two characters.
# `ls` and `cat` do not consult CDPATH, so nothing else in this file needs it.
OFFHOST_CD="$OFFHOST_DIR"
[[ $OFFHOST_CD == /* ]] || OFFHOST_CD="./$OFFHOST_CD"

# WHAT MAY BE SENT THROUGH HERE, AND WHY IT IS NARROWER THAN IT LOOKS
#
# Every command below is handed to the far side's LOGIN SHELL, which on oracle
# is zsh. zsh has `nomatch` on by default, so a glob matching nothing is a
# fatal error rather than the literal that bash would pass through: the obvious
# `rm -f "$dir"/*.part` exits non-zero on an empty directory, and a non-zero
# remote command here fails the whole job. A clean night would report
# ScheduledJobFailed and send the reader to debug the copy step, which is fine,
# over an rm that had nothing to delete.
#
# So: nothing sent from this file may contain a glob. Retention deletes by
# explicit basename, each one a string the far side just reported and that was
# re-validated here. And nothing sent may be bash-only — no arrays, no [[ ]],
# no $( ). What crosses the wire is ls, mkdir -p, cat, mv, cd, rm and
# single-quoted literals, which behave the same under zsh, dash, bash or ash.
# All the bash stays on this side.
#
# The four commands that predate retention happened to comply. That was luck.
# This is the note that makes it a rule.
#
# stdin closed by default so a command that does not stream cannot eat the
# caller's. The copy is the one that streams, and says so.
remote()       { "${SSH[@]}" "$OFFHOST_TARGET" "$@" </dev/null; }
remote_stdin() { "${SSH[@]}" "$OFFHOST_TARGET" "$@"; }

# Basenames only; the far side is a mirror of $OUT_DIR, nothing more. Returns
# non-zero only when the host could not be asked — an empty directory and a
# missing one both come back as nothing, which is the same finding.
remote_ls() { remote "ls -1 '$OFFHOST_DIR' 2>/dev/null; true"; }

# Newest first, like list_backups, and for the same reason: retention slices
# the tail off this list, so an ascending list would delete the newest export
# and keep the oldest. `ls -1` on the far side is ascending, so the reverse is
# applied HERE — sort is a local dependency, and nothing that could be read as
# a pattern is sent over there.
list_remote() {
  local out
  out="$(remote_ls)" || return 1
  grep -E '^config-.*\.sops\.yaml$' <<<"$out" | sort -r || true
}

# The regex above requires a .sops.yaml ending, so a .part left behind by a
# copy that died mid-transfer is invisible to every other path in this file and
# accumulates forever, up to 200 KB at a time. This is what makes them
# visible. The grep runs here, not there — see the note on remote().
list_remote_parts() {
  local out
  out="$(remote_ls)" || return 1
  grep -E '^config-.*\.sops\.yaml\.part$' <<<"$out" || true
}

# The proof that a copy is a backup: pull the bytes back and compare them with
# the file verify() already decrypted. Byte-identical to something proven to
# decrypt IS proven to decrypt, and it costs one round trip instead of a second
# decrypt — which oracle could not do anyway, and must not be able to.
verify_remote() {
  local f="$1" name
  name="$(basename "$f")"
  if remote "cat '$OFFHOST_DIR/$name'" | cmp -s - "$f"; then
    green "verified $name on $OFFHOST_TARGET — byte-identical to the local copy"
  else
    red "$OFFHOST_TARGET:$OFFHOST_DIR/$name is missing or differs from the local copy"
    return 1
  fi
}

# Every local backup the far side does not have, not just the newest. A night
# oracle was off would otherwise leave one export that never left this host,
# and nothing would ever go back for it.
copy_offhost() {
  local have name f copied=0 local_files=()
  have="$(list_remote)" || { red "cannot reach $OFFHOST_TARGET"; return 1; }
  remote "mkdir -p '$OFFHOST_DIR' && chmod 700 '$OFFHOST_DIR'" \
    || { red "cannot create $OFFHOST_DIR on $OFFHOST_TARGET"; return 1; }
  mapfile -t local_files < <(list_backups)
  for f in "${local_files[@]}"; do
    name="$(basename "$f")"
    grep -qxF "$name" <<<"$have" && continue
    info "copying $name to $OFFHOST_TARGET:$OFFHOST_DIR"
    remote_stdin "cat > '$OFFHOST_DIR/$name.part' && mv -f '$OFFHOST_DIR/$name.part' '$OFFHOST_DIR/$name'" < "$f" \
      || { red "copy of $name to $OFFHOST_TARGET failed"; return 1; }
    verify_remote "$f" || return 1
    copied=$((copied + 1))
  done
  ((copied)) || info "$OFFHOST_TARGET:$OFFHOST_DIR already has every local backup"
}

# ---------------------------------------------------------------------------
# Retention
#
# ORDER: prune_local, then copy_offhost, then prune_offhost. Both boundaries
# are forced, and getting either wrong is a loop rather than a wrong answer.
#
# prune_offhost AFTER the copy, because copy_offhost uploads every local file
# the far side lacks. Prune the far side first and the copy in the SAME run
# sees a directory it just shortened, re-uploads what was deleted, and verifies
# it — then tomorrow deletes it again. That cycle is invisible except as
# slightly longer runs.
#
# prune_local BEFORE the copy, because a file outside the newest FW_KEEP here is
# outside the newest FW_KEEP there too. Copying it first would transfer it,
# spend a full verify round trip on it, and have prune_offhost delete it
# seconds later in the same run. Pruning first means the copy only ever moves
# bytes we intend to keep.
#
# Worst case — oracle unreachable for longer than FW_KEEP nights, so the two
# sides share no file at all — the next successful run uploads the local set
# and removes oracle's stale one. One run, converged, no state kept anywhere.
# ---------------------------------------------------------------------------

# One predicate, used before anything is deleted on either side. The character
# class is the point: no quote, backtick, $, space, newline, leading dash, and
# no glob metacharacter can survive it. So a validated name cannot break out of
# the single quotes it gets embedded in, cannot be read as a flag, and cannot
# be a pattern for zsh's nomatch to fire on.
is_backup_name() { [[ $1 =~ ^config-[0-9A-Za-z._-]+\.sops\.yaml(\.part)?$ ]]; }

# Local retention. Runs on the strength of the local write, not the job's:
# a night when oracle is unreachable still writes a file here, so if this hung
# off the copy's success an unreachable far side would quietly restore the
# unbounded growth it exists to stop.
prune_local() {
  local -a files=() victims=() strays=()
  local f name newest_f
  newest_f="$(newest)"

  while IFS= read -r f; do
    [[ -n $f ]] || continue
    if is_backup_name "$(basename "$f")"; then files+=("$f"); else strays+=("$f"); fi
  done < <(list_backups)

  # Reported, never deleted. backups/firewall is not this script's private
  # property and a file it did not write is not a failed backup.
  ((${#strays[@]} == 0)) \
    || warn "${#strays[@]} file(s) in $OUT_DIR not written by this script — never pruned, inspect by hand"

  ((${#files[@]} > FW_KEEP)) || {
    info "${#files[@]} export(s) here, keeping $FW_KEEP — nothing to prune"
    return 0
  }

  victims=("${files[@]:FW_KEEP}")
  for f in "${victims[@]}"; do
    name="$(basename "$f")"
    # FW_KEEP >= 1 already makes this unreachable. It stays because an
    # invariant that holds only by arithmetic is one refactor from not holding.
    [[ $f == "$newest_f" ]] && { info "keeping $name — the newest export"; continue; }
    if [[ -z $f || $f != "$OUT_DIR/config-"*.sops.yaml || ! -f $f ]]; then
      red "refusing to prune $f"
      continue
    fi
    info "pruning $name"
    rm -f -- "$f"
  done
}

# Far-side retention, plus the dead .part files nothing else can see. One round
# trip carries both.
#
# A .part is deleted on a STATE predicate rather than an age guard, which is
# strictly stronger and needs no clock on either host: copy_offhost reuses the
# same .part name for a given export on every attempt, so a fragment is
# consumed by the next run that retries that export. It survives only if the
# export will never be retried — which is exactly when the export is already
# on the far side, or is no longer in the local retained set. The one case
# excluded is the file a concurrent run would be streaming right now, so this
# cannot race a live transfer. An age guard only makes that unlikely, and would
# want find(1), which the far side is not required to have.
prune_offhost() {
  local -a have=() parts=() victims=() strays=()
  local name out newest_name
  newest_name="$(basename "$(newest)")"

  local have_out parts_out
  have_out="$(list_remote)"        || { red "cannot reach $OFFHOST_TARGET"; return 1; }
  parts_out="$(list_remote_parts)" || { red "cannot reach $OFFHOST_TARGET"; return 1; }
  [[ -n $have_out ]]  && mapfile -t have   <<<"$have_out"
  [[ -n $parts_out ]] && mapfile -t parts  <<<"$parts_out"

  local -a keep_names=()
  while IFS= read -r name; do
    [[ -n $name ]] && keep_names+=("$(basename "$name")")
  done < <(list_backups)

  local i=0
  for name in "${have[@]}"; do
    [[ -n $name ]] || continue
    i=$((i + 1))
    ((i > FW_KEEP)) || continue
    [[ $name == "$newest_name" ]] && continue
    if is_backup_name "$name"; then victims+=("$name"); else strays+=("$name"); fi
  done

  local part base
  for part in "${parts[@]}"; do
    [[ -n $part ]] || continue
    is_backup_name "$part" || { strays+=("$part"); continue; }
    base="${part%.part}"
    # Dead if the finished file is already there, or if nothing local will ever
    # retry it. Live otherwise, and left alone.
    if printf '%s\n' "${have[@]}" | grep -qxF "$base" \
       || ! printf '%s\n' "${keep_names[@]}" | grep -qxF "$base"; then
      victims+=("$part")
    fi
  done

  ((${#strays[@]} == 0)) \
    || warn "${#strays[@]} file(s) on $OFFHOST_TARGET not written by this script — never pruned, inspect by hand"

  ((${#victims[@]})) || {
    info "$OFFHOST_TARGET:$OFFHOST_DIR holds ${#have[@]} export(s), keeping $FW_KEEP — nothing to prune"
    return 0
  }

  # Every name here came back from the far side and passed is_backup_name, so
  # the delete set is by construction a subset of what we were just shown. cd
  # first and name the files relatively: no path is concatenated over there,
  # and a cd that fails for any reason short-circuits before the rm.
  local cmd="cd -- '$OFFHOST_CD' && rm -f --"
  for name in "${victims[@]}"; do cmd+=" '$name'"; done

  info "pruning ${#victims[@]} file(s) on $OFFHOST_TARGET"
  out="$(remote "$cmd" 2>&1)" || { red "prune on $OFFHOST_TARGET failed: $out"; return 1; }

  local n_parts=0
  for name in "${victims[@]}"; do [[ $name == *.part ]] && n_parts=$((n_parts + 1)); done
  ((n_parts == 0)) \
    || info "removed $n_parts stale .part file(s) on $OFFHOST_TARGET — a copy died mid-transfer"
}

LOCAL_ONLY=0
case "${1:-}" in
  --list)
    # The dry run for retention, which is what makes it defensible as a default.
    # It must agree with prune: same newest-first order, same FW_KEEP, and the
    # same is_backup_name partition — a listing that counted the strays prune
    # skips would mark the wrong files, which is the one way this output could
    # do harm.
    for side in here there; do
      if [[ $side == there ]]; then
        printf '\n'
        info "on $OFFHOST_TARGET:$OFFHOST_DIR"
        listing="$(list_remote)" || { red "unreachable — nothing off this host is known to exist"; exit 0; }
      else
        listing="$(list_backups)"
      fi
      n=0; n_strays=0
      while IFS= read -r f; do
        [[ -n $f ]] || continue
        f="$(basename "$f")"
        is_backup_name "$f" || { n_strays=$((n_strays + 1)); continue; }
        n=$((n + 1))
        if ((n > FW_KEEP)); then printf '%s\tprunes next run\n' "$f"
        else printf '%s\n' "$f"; fi
      done <<<"$listing"
      ((n)) || info "(nothing)"
      info "$n export(s) $side, keeping $FW_KEEP"
      ((n_strays == 0)) || warn "$n_strays file(s) $side not written by this script — never pruned, inspect by hand"
    done
    # Counted, not classified: whether a given fragment is dead depends on the
    # state prune_offhost computes, and a second copy of that rule here is a
    # second thing to keep true.
    if remote_parts="$(list_remote_parts)" && [[ -n $remote_parts ]]; then
      warn "$(grep -c . <<<"$remote_parts") .part file(s) there from a copy that died mid-transfer — retention removes the ones nothing can finish"
    fi
    exit 0 ;;
  --prune)
    need ssh
    prune_local
    printf '\n'
    prune_offhost || exit 1
    exit 0 ;;
  --verify-only)
    need sops
    need cmp
    f="$(newest)"; [[ -n $f ]] || { red "no backups in $OUT_DIR"; exit 1; }
    verify "$f"
    verify_remote "$f" || { red "the newest backup exists only on this host"; exit 1; }
    exit 0 ;;
  --local-only) LOCAL_ONLY=1 ;;
  "") ;;
  *) red "unknown argument: $1"; exit 1 ;;
esac

need ssh
need sops
need cmp

AGE_RECIPIENT="$(recipient)"
[[ -n $AGE_RECIPIENT ]] || { red "no age recipient found in $SOPS_POLICY"; exit 1; }

mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$OUT_DIR/config-$STAMP.sops.yaml"

info "pulling $FW_PATH from $FW_USER@$FW_HOST"

# Piped straight into sops — the plaintext config never touches this disk.
#
# --filename-override is load-bearing, not cosmetic. sops matches its
# creation_rules against the path of the INPUT, and the input here is
# /dev/stdin, which matches nothing in .sops.yaml — so every run of this script
# since it was written died on `error loading config: no matching creation rules
# found` before a byte reached the disk. Passing --age does not skip that check.
# The override tells sops to match rules as though it were writing $DEST, which
# .sops.yaml now has a rule for.
#
# shellcheck disable=SC2094  # --filename-override never opens $DEST; it is a
# string sops matches creation_rules against. The only reader here is
# /dev/stdin and the only writer is the redirect.
if ! "${SSH[@]}" "$FW_USER@$FW_HOST" "cat $FW_PATH" \
     | sops --encrypt --age "$AGE_RECIPIENT" --input-type binary --output-type yaml \
            --filename-override "$DEST" /dev/stdin \
     > "$DEST"; then
  rm -f "$DEST"
  red "pull or encrypt failed — nothing written"
  red "check: SSH enabled on pfSense, key authorised for $FW_USER, sops on PATH,"
  red "and a .sops.yaml creation rule matching $DEST"
  exit 1
fi

# A zero-byte or tiny result means the pipeline succeeded while producing
# nothing useful — which is exactly the failure a backup script must not
# report as success.
if [[ $(wc -c < "$DEST") -lt 512 ]]; then
  rm -f "$DEST"
  red "result was implausibly small — nothing written"
  exit 1
fi

verify "$DEST"
green "wrote $DEST"

# Local retention here, before the copy: a file past FW_KEEP here is past it
# there too, so copying it first would transfer and verify bytes that
# prune_offhost deletes seconds later in the same run. It sits ahead of the
# --local-only exit deliberately, so a bench run is bounded as well.
prune_local

if ((LOCAL_ONLY)); then
  printf '\n'
  info "--local-only: this is on the same host as everything else it protects."
  info "Retention was applied here; $OFFHOST_TARGET was not touched."
  info "Run without the flag, or copy it yourself — see docs/runbooks/restore-the-firewall.md"
  exit 0
fi

# The local file is written and proven. From here a failure is still a failure
# of the JOB — see the header — but the message has to say which half.
if ! copy_offhost; then
  printf '\n'
  red "wrote $DEST but the off-host copy FAILED — this backup is on the machine it protects"
  red "check: $OFFHOST_TARGET reachable, its host key in ~/.ssh/known_hosts, and this"
  red "host's key authorised there — docs/runbooks/restore-the-firewall.md"
  exit 1
fi

# Only once the copy has succeeded, so the far side is never shortened in a run
# that then re-uploads what it removed.
if ! prune_offhost; then
  printf '\n'
  red "wrote and copied $DEST but retention on $OFFHOST_TARGET FAILED"
  red "the backup is safe; the far side is growing unbounded — see docs/roadmap.md"
  exit 1
fi
