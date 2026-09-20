# Runbook: Back up the CA private key

**Target:** `certificates/ca-key.pem` on the monitoring host (10.0.99.20) —
the **estate's** root, not the sensitive tier's
**Time:** ten minutes, once; five minutes every ninety days
**You will need:** shell access to the monitoring host, and the offline medium
that already holds the age key's second copy

This is the age key's runbook with one key swapped in, and it is shorter
because the loss is smaller. Read
[`back-up-the-age-key.md`](back-up-the-age-key.md) first if you have not: its
disqualifiers apply here as written.

## Why

`certificates/ca-key.pem` signs every leaf the estate's CA has issued —
Grafana's on `prometheus` and Grafana's on the lab guest — and until
[#496](https://github.com/Gerrrt/HomeLab/issues/496) it was the only root
secret in the estate with no copy and no sentence. The age key has
[ADR-0024](../adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md);
the tier's root goes to the offline medium by
[`build-the-tier-ca.md`](build-the-tier-ca.md) §2; this key had nothing.
[ADR-0043](../adr/0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)
decision 4 found the gap and fixed what the answer is not.

**What losing it costs** is bounded, and worth stating accurately. The root
is `pathlen:0`, so there is no intermediate to keep issuing — but there is a
re-mint path, already written: `make certs ARGS='--ca --force'`, two leaves
reissued, one `scp -3` through the Mac for `alexander`'s, and a re-trust on
every device that imported the old `ca.pem`
([`successor-handover.md`](successor-handover.md),
[ADR-0037](../adr/0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md)'s
cost table). Two things about that path are the real gap:

- **The re-trust list was unknown.** ADR-0037 admitted "the Mac's system store
  and Firefox's separate one, at least, and whatever else nobody wrote down".
  It is written down now — [`generate-certificates.md`](generate-certificates.md#4-trust-the-ca-where-you-need-it--and-write-down-where)
  §4 — and keeping it current is part of importing the certificate anywhere.
- **The deadline is not 825 days.** It is the next time a leaf is needed: the
  next VLAN 30 service that wants TLS, or the day Grafana's certificate
  expires and there is no key to reissue it with.

**What the answer is not.** Not SOPS-in-git — ADR-0037 rejected that for the
tier's root, and this key is one of the ones purged from this repository's
history ([`purge-git-history.md`](purge-git-history.md)). Not a passphrase —
[`gen-certs.sh`](../../scripts/gen-certs.sh) closes that trade deliberately in
its header, and says how to reopen it if you disagree. So the control is
medium, not cryptography: **one copy, on the offline medium that already holds
the age key's second copy and the tier's root, and nowhere else.**

## 1. Copy the key

On the monitoring host, with the medium mounted:

```bash
umask 077
cat certificates/ca-key.pem > /path/to/the/medium/ca-key.pem
```

`cat >`, not an editor — the age key's runbook explains
[why](back-up-the-age-key.md#do-not-open-the-copy-in-an-editor), and it is
not a style preference. One file, a single PEM block whose first line reads
`BEGIN PRIVATE KEY` between the dashes, 0600.

Record *what it is and what it signs* alongside it, as with the age key. Its
disqualifiers apply as written:

- **Not on the monitoring host.** A second copy on the same disk is not a
  backup, and the proof below refuses to verify the live key by device and
  inode for that reason.
- **Not in a git repository.** `.gitignore` here matches `certificates/` as a
  path, which protects nothing outside this tree and nothing under another
  name. The proof refuses a copy inside this repository and warns about any
  other working tree.
- **Not in a synced folder.** A plaintext copy in Dropbox, iCloud or the like
  is a readable copy on someone else's disk. The proof warns when the path
  looks like one.

The location itself is deliberately **not** written down in this repository,
for the same reason the age key's is not.

> [!NOTE]
> `certificates/ca-key.pem` still does not travel to any other *host* — not to
> `alexander` with the lab leaf
> ([`build-the-lab-guest.md`](build-the-lab-guest.md)), not to `phoenix`
> ([`build-the-jumpbox.md`](build-the-jumpbox.md)), and ADR-0043 is why. The
> offline copy is a copy, not a second place the key is used.

## 2. Prove the copy

Not optional, and not the same as looking at it. The proof needs no
decryption and no signing: a private key determines its public half, so the
copy's public key either equals the one in `certificates/ca.pem` or the file is
not this key. From a checkout on the monitoring host, with the medium mounted:

```bash
make certs-verify-backup KEY=/path/to/the/medium/ca-key.pem
```

Expect:

```console
-- public key sha256 1a8d9c61… — the backup is this CA's key
ok — ca-key.pem is the private key behind certificates/ca.pem
   Proven: this copy, on its own, is the key that signed every leaf this CA issued.
   Not proven: that where you keep it will still exist after a fire, a theft,
   or a lost medium. That part is your judgement.
   Not proven: that the list of devices trusting ca.pem is complete. That list
   is docs/runbooks/generate-certificates.md §4, and only you can check it.
```

What it proves: the file parses as a private key, and the SHA-256 of its DER
public key equals that of the public key in `ca.pem`. Nothing but that public
key leaves the file — no signing, no temporary file, no secret on the
terminal. What it refuses: the live key itself, by device and inode, so a
symlink or a hard link back to `certificates/ca-key.pem` is caught; and any
copy inside this repository. [`verify-ca-key-backup.sh`](../../scripts/verify-ca-key-backup.sh)
is [`verify-key-backup.sh`](../../scripts/verify-key-backup.sh) with the
decrypt replaced by a comparison, and its `--self-test` runs every refusal and
the proof against a throwaway CA under `make validate`.

## 3. The ninety-day deadline

Like the age key's proof, this one cannot be put on a timer — it needs a human
to mount a medium — so it is enforced from the other end. A successful run
records its timestamp **against the fingerprint of the key it proved**, and
`CaKeyBackupUnproven` fires when that proof passes ninety days old, routed to
the normal alert channel. A key that has never been proved is recorded as `0`
and fires with an absurd age rather than being invisible.

The fingerprint matters for one reason: `make certs ARGS='--ca --force'` mints
a new root, and from that moment the copy on the medium is a copy of the *old*
key. A proof recorded against "the CA key" would keep saying proved for up to
ninety days about a file that can no longer sign anything anyone trusts. So
[`ca-key-state.sh`](../../scripts/ca-key-state.sh) writes one series per key
fingerprint, `gen-certs.sh` calls it at the mint so the new key starts at `0`
the same minute, and the daily `ca-key-state` timer writes it every morning
regardless — carrying the current key's proof forward, setting none, and
dropping the old key's row with a warning. Re-minting the CA therefore means
replacing the copy on the medium and proving it again, and the alert says so
until you do.

The threshold lives in the `JOBS` table in
[`install-timers.sh`](../../scripts/install-timers.sh) beside the age key's;
the mechanism is in [`schedule-maintenance.md`](schedule-maintenance.md).

## Restoring on a rebuilt host

A file copy, nothing more:

```bash
umask 077
mkdir -p certificates && chmod 700 certificates
cat /path/to/the/medium/ca-key.pem > certificates/ca-key.pem
```

`ca.pem` is public and is wherever it was distributed — the running Prometheus
container, the lab guest, a browser export — and `make certs ARGS=--list`
reports what is present. **Do not run `make certs ARGS=--ca`** to restore: it
refuses to overwrite an existing CA, and with `--force` it mints a new one,
which is the re-trust you were avoiding.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `that is the live key on this host, not a backup of it` | `KEY=` points at `certificates/ca-key.pem`, or a symlink or hard link to it | Point it at the copy on the medium. This is the check working |
| `this is a valid private key, but not this CA's key` | A different key — usually the CA was re-minted since the copy was made, or the copy is the tier's root or a leaf key | Both fingerprints are printed. Back up the current key; the old copy signs nothing anyone trusts |
| `is not a readable PEM private key` | A partial copy, or a key with a passphrase on it | Re-copy from the original while the host still has it |
| `the backup is inside this repository` | The copy was written into the working tree | Move it out, then `git log --all -- <path>` to confirm it was never committed |
| `no CA certificate at certificates/ca.pem` | Wrong host or wrong directory — a clean clone has no CA | Run from the deployment checkout on the monitoring host |
| `CaKeyBackupUnproven` the morning after a re-mint | By design: the new key has never been proved | Copy the new key to the medium and run the proof |
| `ScheduledJobNeverRan` for `verify-ca-key-backup` | The deadline is declared and nothing has ever been proved | Expected until the first proof. Run it |
| `mode 644 — group or other can read this copy` | A copy written without `umask 077` | `chmod 600` it, and consider it seen by anything else on that medium |
