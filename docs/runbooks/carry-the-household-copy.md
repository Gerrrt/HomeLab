# Runbook: Carry the household copy

**Target:** the household drive, a WD Elements Portable 5 TB, mounted on
`trinity` (10.0.99.40), from the Immich library sets and a fresh Paperless-ngx
export
**Time:** an afternoon the first time, because the drive is formatted and the
whole library is written to it. About an hour every ninety days after that
**You will need:** the drive and its Micro-B cable, a shell on `trinity`, and,
for a copy of record, a `household` key in
[`stacks/sensitive/household.recipients`](../../stacks/sensitive/household.recipients)

[ADR-0073](../adr/0073-carry-the-household-copy-on-a-drive-the-holder-keeps.md)
is the decision this carries out, and
[`open-the-household-copy.md`](open-the-household-copy.md) is the holder's half.
Read both before the first visit.

## Why

[ADR-0023](../adr/0023-keep-the-household-recovery-path-outside-the-estate.md)
classes Immich and Paperless-ngx as *Durable*. Every copy short of this one
shares the house:

- the library's USB disk;
- `trinity`'s SSD;
- `oracle`, where
  [ADR-0064](../adr/0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)
  sends a set every night.

One fire takes all three. This drive lives at the holder's address. Each set
on it opens with the holder's key and with ADR-0024's technical second's, and
the holder can open it on their own computer.

**What a visit is.** `make household-copy` re-verifies everything the drive
already holds. It then carries the newest library set and a Paperless export
made on the spot, and hashes each copy. It also refreshes the age binaries and
`HOW-TO-OPEN.txt`, and leaves a proof challenge only the holder's key opens. A
successful run records `household-copy`, and `HouseholdCopyStale` fires ninety
days later. The drive is visited, never scheduled, so nothing else resets that
deadline.

**No holder, no copy of record.** Until the recipients file has a `household`
key, `make household-copy` refuses before it runs, and `ScheduledJobNeverRan`
reports `household-copy` and `household-proof`. That is correct: there is no
copy ADR-0023 would accept yet. `ARGS=--rehearse` writes the same thing to the
drive without recording it.

## 1. Before the first visit

**The tools.** The drive carries `age` for every OS the holder might use,
pinned in
[`stacks/sensitive/household-age.sha256`](../../stacks/sensitive/household-age.sha256).
Download them once into `backups/household/tools/` on `trinity`:

```bash
mkdir -p backups/household/tools && cd backups/household/tools
for a in windows-amd64.zip windows-arm64.zip darwin-arm64.tar.gz darwin-amd64.tar.gz linux-amd64.tar.gz linux-arm64.tar.gz; do
  curl -fsSLO "https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-$a"
done
cd - >/dev/null
```

Every run hashes each one against its pinned line, and refuses a mismatch
before it writes anything.

**The drive.** It ships formatted for Windows. Give it one exFAT partition,
because the holder's OS is unknown and exFAT is the filesystem all three read.
Find its device with `lsblk` and be certain of it. The commands below erase the
whole disk:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN
sudo wipefs -a /dev/sdX
sudo parted -s /dev/sdX mklabel gpt mkpart HOUSEHOLD 1MiB 100%
sudo mkfs.exfat -L HOUSEHOLD /dev/sdX1
```

**Mount it** as the user that runs the stack, with nothing readable by anyone
else:

```bash
sudo mkdir -p /mnt/household
sudo mount -o uid=$(id -u),gid=$(id -g),umask=077 /dev/sdX1 /mnt/household
```

It is shingled. The first copy writes the whole library in one sequential
pass, which is how it should be written, and it is slow.

## 2. Rehearse

This writes the full copy and proves it, records nothing, and marks the drive
`REHEARSAL-NOT-THE-HOUSEHOLD-COPY.txt`:

```bash
make household-copy DEST=/mnt/household ARGS=--rehearse
make household-copy DEST=/mnt/household ARGS=--verify-only
```

To rehearse the holder's side too, make a throwaway key **on another
computer**, ideally a Windows or Mac machine. Write the proof to its public
half, then follow [`open-the-household-copy.md`](open-the-household-copy.md)
§2 on that computer:

```bash
make household-copy DEST=/mnt/household ARGS="--rehearse --proof-recipient age1..."
```

The rehearsal's sets open with the technical second's key and `trinity`'s, not
with the throwaway. Only `PROOF/` opens with it, which is what keeps the real
archives away from a key made for practice.

## 3. Add the holder

The holder makes their key on their own computer
([`open-the-household-copy.md`](open-the-household-copy.md) §1) and sends the
`age1…` line. Add it **above** the technical second, under its role:

```text
# role: household  (<who>, generated on their own device, <date>)
age1...
```

If the holder **is** the technical second, do not add a second line. Change
the existing role comment to `# role: household-and-technical-second`, because
one person's single key is written once.

```bash
./scripts/household-recipients.sh --check
python3 scripts/check_sops_rules.py
```

The first refuses a mistyped key by its checksum. If it does, ask for the
line again rather than correcting it by eye.

Commit it. It is a public key, and it never goes in `.sops.yaml`; the check
fails if it does. The next nightly library set encrypts to it. Wait for that
set, or make one now:

```bash
make backup-library
```

A library set made before the key was added cannot be opened with it. The
copy refuses such a set by name rather than carrying it.

## 4. Copy, and prove it

```bash
make household-copy DEST=/mnt/household
```

In order, and each step stops the run if it fails:

1. Re-verify every set already on the drive, and every tool against its pin.
2. Refuse a newest library set that some household recipient cannot open.
3. Export Paperless-ngx into `stacks/sensitive/export/`, and archive it into
   `backups/paperless-documents/<STAMP>/`. The archive is encrypted and
   verified like every other set.
4. Check the drive has room for the new sets before the old ones are pruned.
5. Copy each set into a `.part`, writing its MANIFEST last, then sync, rename
   and hash it again.
6. Refresh `tools/` and `HOW-TO-OPEN.txt`. A challenge still waiting to be
   proved stays as it is. Otherwise write a new one to `PROOF/`, encrypted to
   the household key only.
7. Prune to one set of each kind, and remove dead `.part`s.

The Paperless set in `backups/paperless-documents/` is not re-verified
nightly, unlike every other set on `trinity`
([#942](https://github.com/Gerrrt/HomeLab/issues/942)). Nothing reads it
after the visit that made it. The next visit exports Paperless again, step 3
verifies the new set, and the old one is pruned. A restore copies the set back
from the drive, not from `trinity`. The documents themselves are in the
nightly volume sets (`paperless-media` and `paperless-db`), and
`verify-backups-sensitive` re-reads those every night, here and on `oracle`.
The copy on the drive is checked at every visit, by step 1 and
`ARGS=--verify-only`.

The last line is green and names both sets. Then:

```bash
sudo umount /mnt/household
```

The drive goes back to the holder's address, **with its cable**.

## 5. The holder's proof

Once a year, and once after the first copy of record, the holder opens
`PROOF/proof.txt.age` on their own computer without you there, and phones you
the code:

```bash
make household-proof CODE=1234-5678-9012
```

A mistyped code fails before anything is recorded, so try again. A match
records `household-proof`, which is ADR-0023's second condition. Write the date
in [`changelog.md`](../changelog.md). The first proof is also the day
ADR-0064 stops being the stand-in. Its NOTE says how to mark that.

## The ninety-day deadline

`HouseholdCopyStale` fires when `household-copy` is older than ninety days, or
`household-proof` older than a year. Its thresholds are the two sensitive rows
in `scripts/install-timers.sh`. Between visits the recovery point on the drive
is the last visit. The nightly copy to `oracle` covers the disk failing in the
meantime, but not the house.

## Restoring from the drive

The sets are the estate's standard layout. On `trinity`, or its replacement:

```bash
cp -a /mnt/household/household/immich-library/<STAMP> backups/immich-library/
cp -a /mnt/household/household/paperless-documents/<STAMP> backups/paperless-documents/
```

Then follow [`restore-the-sensitive-tier.md`](restore-the-sensitive-tier.md).
Without this estate, the holder's own page restores the files themselves.
Paperless re-imports its export with `document_importer` at the same version
(3.2.1 today).

## If something goes wrong

- **"no household holder".** Correct until §3 is done. Rehearse instead.
- **"… is not encrypted to age1…".** The newest library set predates a
  recipient. Run `make backup-library`, then copy again.
- **"differs from its MANIFEST entry".** The drive does not hold what was
  written. Nothing was copied or deleted. Remove the named set from the drive
  and run again; it is copied fresh. If it recurs, the drive is failing.
- **"does not match its pinned sha256".** A tool under
  `backups/household/tools/` is not the pinned build. Delete it and download it
  again.
- **"has … free and this visit needs …".** Prune with `ARGS=--prune`. If the
  library itself no longer fits twice on 5 TB (about 2.4 TB), the drive is
  outgrown, and that is a decision, not a fix.
- **"the destination is …".** It refused a path that is not the drive, such
  as RAM, `/tmp` or `trinity`'s own disk. Mount the drive and point `DEST` at
  it.
