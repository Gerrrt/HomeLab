# Runbook: Purge secrets from git history

**This rewrites every commit SHA in the repository and requires a force-push to
`main`.** Read the whole page before starting.

## What is still in history

| What | Introduced | Removed from HEAD | Still reachable at |
| --- | --- | --- | --- |
| Shared SNMP community | `ee3d443` | yes | every commit in between |
| Grafana `admin`/`admin` inline | `ee3d443` | yes | every commit in between |
| TLS private keys under `certificates/` | `efb2632` | `647d90a` | `647d90a~1` |

All nine individual findings are enumerated in
[`.gitleaksignore`](../../.gitleaksignore) with their fingerprints.

Verify for yourself before and after:

```bash
git show 647d90a~1:certificates/Gandalf.Gondor.Lab/ca-key.pem | head -1

# One literal per line, so loop — `$(cat ...)` would fold the whole file into a
# single search string and match nothing.
while IFS= read -r s; do
  [ -z "$s" ] && continue
  git log --all -S "$s" --oneline
done < .purge-secrets.txt
```

Deleting a file in a later commit does not remove it from history. `git show`
hands it straight back, GitHub's API serves it from unreachable objects for a
while after a force-push, and forks keep it indefinitely.

## Before you start

1. **Rotate the credentials first.** See
   [`rotate-snmp-community.md`](rotate-snmp-community.md) and regenerate the CA
   and leaf certificates. Anything ever pushed to a public repository is
   compromised regardless of what you do to the history — the purge stops it
   being *trivially* discoverable, not from having been seen.
2. Merge or close every open pull request. A rewrite orphans them.
3. Make sure no other clone has unpushed work.
4. Install the tool:

   ```bash
   sudo apt install git-filter-repo     # or: pipx install git-filter-repo
   ```

5. **Write the literals to redact into `.purge-secrets.txt`**, one per line:

   ```bash
   printf '%s\n' 'the-old-snmp-community' > .purge-secrets.txt
   ```

   This file is gitignored on purpose. The script reads from it rather than
   hardcoding the value, because a purge tool that contains a copy of the secret
   leaves the secret in the repository after a successful purge — which is
   exactly what the first version of this script did. Delete the file when you
   are finished.

## Dry run

```bash
make purge-history-dry-run
```

This clones a scratch mirror, rewrites *that*, and reports whether the secrets
are gone. Your repository is untouched. The scratch copy is left in place for
inspection — check it before continuing:

```bash
cd /tmp/<scratch>/repo
git log --oneline | head
while IFS= read -r s; do [ -n "$s" ] && git log --all -S "$s" --oneline; done \
  < .purge-secrets.txt          # must print nothing
```

## Execute

```bash
./scripts/purge-history.sh --execute
```

It requires a clean working tree, prompts for confirmation, and writes a full
backup bundle to `../HomeLab-backup-<sha>.bundle` before touching anything.

Restore from that bundle if something goes wrong:

```bash
git clone HomeLab-backup-<sha>.bundle HomeLab-restored
```

## Push

`git-filter-repo` removes the remote deliberately, so a rewrite cannot be pushed
by reflex. Re-add it and force-push:

```bash
git remote add origin git@github.com:Gerrrt/HomeLab.git
git push --force --all origin
git push --force --tags origin
```

## Afterwards

- **Every existing clone must be re-cloned.** A stale clone that pushes will
  reintroduce the removed objects.
- GitHub keeps unreachable objects for a while. To have them purged sooner, ask
  GitHub Support to run garbage collection on the repository.
- **Forks keep their own copy of everything.** If the repository has been forked,
  the secrets are still public through the fork and no amount of rewriting your
  copy changes that. This is the single strongest argument for rotating first
  and treating the purge as tidying rather than as remediation.
- **Delete `.gitleaksignore`.** Its fingerprints reference commits that no longer
  exist, and leaving it in place means a future finding could be masked by a
  stale entry. CI should pass on full history with no ignore file at all — that
  is how you know the purge worked.

## Verify

```bash
git log --all --oneline -- certificates/            # empty
# -F: a rotated community is a random string and may contain regex characters.
while IFS= read -r s; do
  [ -n "$s" ] && git grep -IF -e "$s" $(git rev-list --all)
done < .purge-secrets.txt        # no matches
gitleaks detect --no-banner --redact -c .gitleaks.toml --log-opts="--all"
```

## If you would rather not rewrite history

Defensible, and the cost is that you must be explicit about it. The credentials
are rotated, so what remains in history is a dead string and a set of
passphrase-encrypted keys. Document that decision in
[`security.md`](../security.md) rather than leaving a reader to discover it — a
known, accepted, written-down exposure reads very differently from an
overlooked one.
