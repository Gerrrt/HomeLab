#!/usr/bin/env bash
#
# Edit the encrypted secrets, without the editor leaving a decrypted copy
# behind.
#
# `sops <file>` decrypts to a temp file under /tmp and opens $EDITOR on it. A
# modern vim or neovim config persists buffer state outside that temp file:
# `undofile` writes the full undo history — which is to say the buffer text —
# to a permanent undodir, and viminfo/shada records registers and marks. sops
# shreds its temp file on exit; nothing shreds the undo file.
#
# Measured on this repo's own monitoring host: three undo files in
# ~/.local/state/nvim/undodir/ named %tmp%<pid>%observability.sops.yaml, mode
# 664, holding the live SNMP community strings for pfSense, the APC NMC and
# iLO in plaintext on an unencrypted disk. They had been sitting there since
# the last `make secrets-edit`, and nothing in the repo knew.
#
# That is not the editor's fault and it is not fixable in the operator's
# dotfiles alone — this repository should not hand plaintext to a program that
# it has not told to keep quiet. So the hardening lives here, where it applies
# to whoever clones this and whatever their config says.
#
# Usage: scripts/secrets-edit.sh [stack]      (default: observability)
#        make secrets-edit
#
# Override with SECRETS_EDITOR if you need something else entirely; you are
# then responsible for that editor's persistence, and the warning below tells
# you what to check.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:-observability}"
SECRETS_FILE="${REPO_ROOT}/secrets/${STACK}.sops.yaml"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[0;33m!!\033[0m %s\n' "$*" >&2; }

command -v sops >/dev/null 2>&1 || die "sops not found.
  https://github.com/getsops/sops/releases"

[[ -f "${SECRETS_FILE}" ]] || die "no encrypted secrets at ${SECRETS_FILE}
Run 'make secrets-init' first."

# ---------------------------------------------------------------------------
# Work out what to run, and silence its persistence
# ---------------------------------------------------------------------------
# sops joins $EDITOR and the temp path into one string and hands it to `sh -c`,
# so flags and quoting inside EDITOR survive. Verified against sops 3.9.4.
#
# The flags, and why each one:
#   -n                     no swap file — .swp holds buffer text too
#   -i NONE                no viminfo (vim) / shada (nvim): no registers, no
#                          marks, no search history carrying secret fragments
#   -c 'set noundofile …'  the important one. `-c` runs after the user's config
#                          has been read, so it overrides a config that turned
#                          undofile on; --cmd would run too early and be undone.
#
# vi is included because on Debian and Ubuntu /usr/bin/vi is vim.basic and
# reads the same ~/.vimrc.
editor="${SECRETS_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"

if [[ -z "${SECRETS_EDITOR:-}" ]]; then
  case "$(basename "${editor%% *}")" in
    vi | vim | vim.basic | vim.tiny | nvim | view)
      editor="${editor} -n -i NONE -c 'set noundofile nobackup nowritebackup'"
      ;;
    *)
      warn "not hardening '$(basename "${editor%% *}")' — this script only knows how to"
      warn "silence the vim family. Check that your editor does not write undo"
      warn "history, backups or autosaves outside the file it was given; sops"
      warn "shreds its temp file, but nothing shreds an editor's leftovers."
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Run it
# ---------------------------------------------------------------------------
# sops exits 200 when the editor quit without changing anything. That is the
# normal outcome of opening the file to look at it, but as a bare recipe it
# surfaced as `make: *** [secrets-edit] Error 200` — which reads like the
# target is broken and sends you looking for a fault that is not there. Every
# other exit code is passed through untouched.
set +e
EDITOR="${editor}" sops "${SECRETS_FILE}"
status=$?
set -e

if ((status == 200)); then
  printf '\033[0;34m--\033[0m %s\n' "unchanged — nothing re-encrypted"
  exit 0
fi
exit "${status}"
