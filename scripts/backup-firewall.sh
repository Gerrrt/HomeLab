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
# Same room, so this is off-host and not offsite. A fire still takes both.
# Offsite is the half that still has no destination; see docs/roadmap.md.
#
# The copy never deletes on the far side, and the verification pulls the bytes
# BACK and compares them against the file that was just proven to decrypt —
# proving the remote holds a restorable backup without the remote ever being
# able to read one. Known limit, stated rather than engineered away: the ssh
# key that writes there can also overwrite there. A rogue prometheus could
# clobber every copy on oracle. Append-only storage is a different mechanism
# and a different issue.
#
# Usage:
#   scripts/backup-firewall.sh                    pull, encrypt, verify, copy off-host
#   scripts/backup-firewall.sh --local-only       the same without the copy — bench use
#   scripts/backup-firewall.sh --verify-only      re-verify the newest backup, here and on the far side
#   scripts/backup-firewall.sh --list             show what exists, here and on the far side
#
# Environment:
#   FW_HOST      default morpheus.matrix.elysium (falls back to 10.0.99.1)
#   FW_USER      default root
#   FW_PATH      default /cf/conf/config.xml
#   FW_OFFHOST   default robo@10.0.99.30:backups/firewall — user@host:dir, the
#                dir relative to that user's home unless absolute. The nightly
#                unit can override it in /etc/default/homelab-timers.
set -euo pipefail

FW_HOST="${FW_HOST:-10.0.99.1}"
FW_USER="${FW_USER:-root}"
FW_PATH="${FW_PATH:-/cf/conf/config.xml}"
FW_OFFHOST="${FW_OFFHOST:-robo@10.0.99.30:backups/firewall}"
OUT_DIR="backups/firewall"
SOPS_POLICY=".sops.yaml"

# BatchMode so a missing key, or an unknown host key, fails loudly instead of
# hanging a timer on a prompt.
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;34m--\033[0m %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { red "missing dependency: $1"; exit 1; }; }

# The age recipient is read from .sops.yaml rather than duplicated here. One
# source of truth for the key; rotating it in .sops.yaml rotates it here too.
recipient() {
  grep -oE 'age1[0-9a-z]{50,}' "$SOPS_POLICY" | head -1
}

list_backups() {
  if [[ -d $OUT_DIR ]] && compgen -G "$OUT_DIR/*.sops.yaml" >/dev/null; then
    ls -1t "$OUT_DIR"/*.sops.yaml
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

# stdin closed by default so a command that does not stream cannot eat the
# caller's. The copy is the one that streams, and says so.
remote()       { "${SSH[@]}" "$OFFHOST_TARGET" "$@" </dev/null; }
remote_stdin() { "${SSH[@]}" "$OFFHOST_TARGET" "$@"; }

# Basenames only; the far side is a mirror of $OUT_DIR, nothing more. Returns
# non-zero only when the host could not be asked — an empty directory and a
# missing one both come back as nothing, which is the same finding.
list_remote() {
  local out
  out="$(remote "ls -1 '$OFFHOST_DIR' 2>/dev/null; true")" || return 1
  grep -E '^config-.*\.sops\.yaml$' <<<"$out" || true
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

LOCAL_ONLY=0
case "${1:-}" in
  --list)
    list_backups || true
    printf '\n'
    info "on $OFFHOST_TARGET:$OFFHOST_DIR"
    if have="$(list_remote)"; then
      if [[ -n $have ]]; then printf '%s\n' "$have"; else info "(nothing)"; fi
    else
      red "unreachable — nothing off this host is known to exist"
    fi
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

if ((LOCAL_ONLY)); then
  printf '\n'
  info "--local-only: this is on the same host as everything else it protects."
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
