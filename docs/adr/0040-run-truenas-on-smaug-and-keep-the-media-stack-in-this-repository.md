# ADR-0040: Run TrueNAS on `smaug`, and keep the media stack in this repository

**Status:** Accepted · 2026-09 · supersedes the operating-system clause of
[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md)

## Context

[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md), under
*"The box is built like the rest of the estate"*, decided:

> Ubuntu Server and one Docker Compose stack, per
> [ADR-0004](0004-one-compose-stack-per-host.md), not an appliance OS. TrueNAS
> or Unraid would make the storage easier and put the host outside every
> mechanism this repository has — no compose file, no pinned digests, no
> `make validate`, configuration that exists only as clicks.

**The operator was only ever going to install TrueNAS**, and nobody found out
until 2026-09-15 — the day the TS150 was unboxed and the next step was said out
loud:

> "Ubuntu Server is most definitely NOT going on the NAS, and never was. If
> that's in the documentation, then that is wrong. I was ONLY ever going to
> install TrueNAS on that."

This is the second divergence between the record and the operator's intent on
this one machine, and it was found the same way as the first.
[ADR-0038](0038-name-the-nas-smaug-and-reserve-zion-for-the-box-that-does-not-exist.md)
caught the naming four days earlier, by someone reading a plan aloud rather
than by any check. **Neither was catchable by CI**, because both are
disagreements about intent and every document involved was internally
consistent — which is the useful thing to write down here, since
[ADR-0026](0026-check-the-documents-where-the-truth-is.md) exists on the
premise that documents can be checked against the truth.

**Unlike ADR-0038, this one is not nominal.** That was two names for one
machine and the substance was never in dispute. This is a decision ADR-0016
considered, named and declined, and reversing it costs something real. It is
worth stating what, rather than reversing it quietly.

### Three-quarters of the objection has expired

ADR-0016's case was four specific losses: *no compose file, no pinned digests,
no `make validate`, configuration that exists only as clicks*. The first three
rested on an assumption about appliance operating systems that stopped being
true. TrueNAS (the Linux line, formerly SCALE) **replaced k3s with Docker in
24.10 "Electric Eel"** and runs user-supplied compose files. A stack in this
repository can be the thing it launches.

So the objection reduces to its fourth clause, and that one stands.

### The quarter that survives

**The storage layer is clicks and stays clicks.** Pool geometry, datasets,
snapshot schedules, share definitions and permissions live in the appliance's
own configuration database. None of it is in git, `make validate` cannot see
any of it, and a rebuild reproduces it from someone's memory.

That is a genuine cost and it is the one being bought. It is also the cost
ADR-0016 was least entitled to charge against TrueNAS specifically: the
alternative was hand-rolled ZFS on Ubuntu, where the pool layout would have
been exactly as absent from git, with the added job of maintaining ZFS
packaging on a distribution that treats it as a guest. `oracle`'s hand-made
wiki containers — the precedent ADR-0016 cited, which took until
[#251](https://github.com/Gerrrt/HomeLab/issues/251) to become visible — are an
argument about *services*, and services are the part this ADR keeps.

### The hardware already assumed it

Not an argument for the decision, but worth recording because it went unnoticed
while the documents said Ubuntu: TrueNAS wants a **dedicated boot device it
never uses for data**, which is precisely what the Intel DC S3520 in the
TS150's 5.25" optical bay is — bought, bracketed and taped for exactly that
shape. ECC memory under ZFS is its home ground rather than something to
assemble. The parts list has fitted this decision better than the written one
since 2026-09-11.

## Decision

**1. `smaug` runs TrueNAS.** This supersedes ADR-0016's operating-system clause
and nothing else in it. The address, the three firewall rules, the terminal-
outward property, the scrape direction and the no-logs residual
([#255](https://github.com/Gerrrt/HomeLab/issues/255)) are all unchanged — they
were never OS decisions. The release installed is recorded in
[`hardware.md`](../hardware.md) on the day, as a release line and not a point
release, which is what [`check_docs.py`](../../scripts/check_docs.py) requires
of the Compute table.

**2. The media stack stays on `smaug` and stays in this repository.**
`stacks/media/` is authored in the ADR-0004 shape and run as a **compose file
under TrueNAS's app runtime**, not as catalogue apps. The difference is not
taste:

- **Dependabot edits `compose.yaml` and nothing else.** It is live here and
  merges bumps weekly. Catalogue apps lose it, and with it the digest pinning
  [`check_image_pins.py`](../../scripts/check_image_pins.py) enforces — every
  image carrying both a tag and a `sha256:`, so a moved tag cannot change what
  deploys.
- **`make validate` keeps working on the stack** — `compose-guards.sh`, the
  image-pin check, `check_compose_health.py`.
- **The restore path already assumes compose volumes**
  ([`restore-the-stack.md`](../runbooks/restore-the-stack.md),
  `backup-volumes.sh`). Catalogue apps would need a second, unwritten one.

**3. [ADR-0004](0004-one-compose-stack-per-host.md) is unchanged, and
`smaug` is not an exception to it.** That ADR decides the repository's layout —
one directory per stack, host-to-stack mapping in
[`architecture.md`](../architecture.md). It says nothing about which init
system or runtime launches the stack, so a compose file started by TrueNAS
satisfies it exactly as one started by `docker compose` does. Earlier drafts of
this decision called `smaug` "ADR-0004's documented exception"; it is not one,
and saying so would have invented a precedent for exempting hosts.

**4. What is not in git is named, not waived.** The pool and dataset layout,
the snapshot schedules, the shares and their permissions are written into a
runbook as they are created, so the appliance's configuration has a
reproducible description even though it has no manifest. A NAS whose layout
exists only in the appliance is a NAS that cannot be rebuilt by anyone but the
person who built it, and this estate already has a
[`successor-handover.md`](../runbooks/successor-handover.md) that assumes
otherwise.

**5. The ADRs are not edited.** Per [ADR-0001](0001-record-architecture-decisions.md)
and ADR-0038's fourth decision, ADR-0016 keeps its text and gains a note
pointing here.

## What would reopen decision 2

**Quick Sync passthrough into a container under TrueNAS.**
[#138](https://github.com/Gerrrt/HomeLab/issues/138) wanted this box for the
TS150's Intel HD P630 specifically, and
[`roadmap.md`](../roadmap.md) uses it to decline Plex Pass on the grounds that
Jellyfin gets hardware transcoding for nothing. If the iGPU does not reach a
container cleanly on the installed release, decision 2 is reopened — the
options then being catalogue apps that manage the passthrough, or the media
stack moving off this host.

**It is checked before the library exists, not after.** Moving a populated
library is a weekend; moving an empty stack is an afternoon.

## Consequences

- **[#256](https://github.com/Gerrrt/HomeLab/issues/256)'s scrape path needs a
  decision it did not need before.** It makes `smaug` the estate's first
  scraped host via `node_exporter` on `99 → 40:9100`. TrueNAS ships its own
  metrics endpoint, so this is either `node_exporter` installed anyway to keep
  the target shape the issue specifies, or a different scrape with a different
  label set and different rules. **Not decided here** — it is that issue's, and
  it now has a fork in it.
- **[ADR-0027](0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md)'s
  PBS shape needs re-reading.** It installs PBS with a datastore local to
  `Saruman` and a **sync job to `smaug`**, and a PBS sync target is another PBS
  instance. On TrueNAS that is PBS in a VM or a container, or the shape changes
  to an NFS/SMB datastore. **Not decided here**; it is ADR-0027's to answer on
  the day PBS is installed, and that day is still gated on the NAS answering.
- **The storage layer leaves CI's reach**, permanently and by choice. Decision
  4 bounds it; nothing removes it.
- **[#413](https://github.com/Gerrrt/HomeLab/issues/413)'s order of work is
  otherwise unchanged.** Place, address, the three rules in order, the scrape,
  then the stack. Only step 1's installer image changes.
- **A second decision on this machine was caught by saying it out loud.** Both
  were found in the week the hardware landed and neither was findable by any
  check this repository has. The cheap version of that lesson is to say the
  next step aloud before taking it, while the boxes are still unopened; the
  expensive version is a rebuild.
