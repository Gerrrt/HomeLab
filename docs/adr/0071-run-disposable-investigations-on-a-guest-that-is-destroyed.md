# ADR-0071: Run disposable investigations on a guest that is destroyed

**Status:** Accepted · 2026-10

## Context

[ADR-0030](0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)
put Wazuh and Velociraptor in `stacks/soc/` on `odin` and sized them for the
**durable** case: a 2 GiB indexer heap, a shard ceiling of 25 per GiB, and a
thirty-day ISM delete policy that keeps the estate's security record inside
that ceiling. `odin` is the thing that has been watching all along, and what it
holds is the record the estate is judged by.

[#438](https://github.com/Gerrrt/HomeLab/issues/438) is the other case.
Detonating a sample, or working one question over a weekend, wants a store that
can be filled with noise, queried hard and then deleted. Doing that on `odin`
spends its shard budget, mixes the noise into the durable record, and reopens
the retention argument every time.

The issue named the one thing to get right: **the lifecycle must be visible.** A
throwaway stack that quietly stays up for four months is `odin` with worse
retention and nobody watching it. The repository already has one disposable
machine and has not solved this for it.
[ADR-0017](0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md) records
that "nothing knows whether `ifrit` is powered". The useful statement is "this
host is on when it should be off", and every rule shape available then said the
opposite and fired nightly.

Two existing decisions constrain the answer:

- **ADR-0028** lets a guest's *run state* cross from the hypervisor to the
  estate, because it is a hypervisor fact. It rejected a table of which guests
  are expected to be up, because that is a second copy of a fact that changes
  whenever a VM is created.
- **ADR-0020** gives each stack on a less-trusted guest its own age recipient,
  so a guest that holds investigation data cannot decrypt the estate's
  credentials.

## Decision

**A sibling stack, `stacks/scratch/`, on its own guest that is expected to be
destroyed:** `diabolos`, `10.0.30.61`, VMID 161. That is in `odin`'s decade on
VLAN 30, because every `.x0` from `.10` to `.90` is already taken or reserved,
and VMID 161 keeps the 100-plus-octet rule. A second host means a second
directory, so this fits
[ADR-0004](0004-one-compose-stack-per-host.md) without amending it.

**soc's shape, mounted rather than copied.** The stack runs the same four
services as `stacks/soc` on the same pinned digests: the Wazuh indexer, manager
and dashboard, and Velociraptor. Its static configuration is mounted from
`../soc` unchanged, the way soc mounts `../observability/alloy`. A disposable
copy of the SIEM that has drifted from the SIEM would answer a different
question from the one asked of it. Three things belong to the guest itself:

- its mTLS CA;
- its Velociraptor CA;
- the indexer's user-database template, because `render-config.sh` renders the
  template it finds under the deploying stack's own `wazuh/`.

Dependabot opens a PR for each stack's directory, and each bump is merged together
with its twin.

**What it does not have, and why each absence is the disposability:**

- **No ISM delete policy.** The heap and the shard ceiling are the same as
  `odin`'s, but nothing deletes on a schedule. Teardown is the retention
  policy.
- **No Alloy and no lab scrape.** `odin` pushes its journal, container logs and
  indexer health to the lab's stores on `alexander`. A detonation's noise in the
  lab's Loki would outlive the guest that produced it, under the lab's
  retention. Velociraptor's metrics port is not published.
- **No backup and no PBS.** The datastores sit on the guest's second disk, which
  `qm destroy --purge` removes with everything else.

**The lifecycle is a tag on the guest, read by the hypervisor's collector.**

- The guest is created with the Proxmox tag `disposable`
  (`qm create --tags disposable`).
- `scripts/collect-guest-state.sh` already reads `qm list` on `Saruman`. It now
  also reads each guest's `qm config` and emits two series:
  - `homelab_guest_disposable`, from the tag;
  - `homelab_guest_created_timestamp_seconds`, from the `ctime` PVE writes into
    `meta:` at creation.
- The new estate alert **`DisposableGuestOutlived`** fires when a disposable
  guest is **more than a fortnight old, running or stopped**. A detonation takes
  an afternoon and a weekend question takes three days. Past two weeks the guest
  is no longer an investigation; it is an unmanaged SIEM.
- `HypervisorGuestStopped` now ignores disposable guests. For a throwaway,
  stopped is the expected state between sessions and destroyed is the goal.

Both facts are the **hypervisor's own config**, the class ADR-0028 lets cross
("that a guest exists, its VMID and name"). That makes them unlike
[ADR-0070](0070-let-guest-disk-capacity-cross-read-through-the-hypervisor.md)'s
filesystem sizes, which come from the guest's agent and so are hostile input. A
guest cannot set its own tag or its own `ctime`; only someone on `Saruman` can.

The alert measures **age, not uptime.** A stopped disposable guest still holds
a detonation's output on the segment that exists to hold attackers. The age
comes from the guest's own config, so a Prometheus restart cannot reset it the
way it would reset a `for: 14d`.

**The secrets are the guest's, and they are never committed.**

- `.sops.yaml` gets a `scratch` rule above the catch-all. Its
  `REPLACE_WITH_SCRATCH_AGE_PUBLIC_KEY` placeholder is **permanent in git**.
- Each incarnation runs `make secrets-init STACK=scratch` on itself. That writes
  the guest's public key into its own checkout only and encrypts
  `secrets/scratch.sops.yaml` there.
- `.gitignore` keeps that file out of git.
- The key is not backed up. The guest, its key and its secrets are destroyed
  together.

**Teardown is `qm destroy 161 --purge`,** after exporting whatever the case
needs. Nothing in git changes per investigation. The build and the teardown are
one runbook,
[`run-a-scratch-investigation.md`](../runbooks/run-a-scratch-investigation.md).

### Rejected

- **A second stack on `odin`.** ADR-0030 found two stacks on one guest workable,
  but this one would share `odin`'s heap and disk and so spend exactly the
  budget #438 exists to protect. `bootstrap.sh` also refuses to give one host's
  key a second stack.
- **An alert keyed on the guest's name**, `homelab_guest_running{guest="diabolos"}`
  held for N days. No collector change, but it is a one-row table of which
  guests are expected to be up, the shape ADR-0028 rejected. It also misses a
  stopped guest, which still holds the data.
- **A runbook and a naming convention only.** That is ifrit's shape in ADR-0017,
  and it is the failure #438 was written to prevent: the convention is only as
  good as the memory of whoever used it last.
- **Committing the secrets per incarnation, as soc does.** Every investigation
  would leave a commit to `.sops.yaml` and a file in git encrypted to a key that
  no longer exists. A dead-key ciphertext is harmless but untrue.
- **An ISM policy with a shorter window.** It would be a retention argument
  inside a guest whose whole retention argument is its own lifetime.

## Consequences

- **A disposable guest that outlives its investigation is noticed** two weeks
  after creation, by the estate and with no list of guests anywhere in this
  repository. The mark and the thing marked are the same object, set by the
  same `qm create`.
- **The mechanism is not specific to this stack.** Any future throwaway guest is
  covered the day it is tagged. `ifrit` is a host rather than a guest, so this
  does not close ADR-0017's gap for it. It does show the shape that would.
- **A stopped disposable guest is silent** where any other stopped guest warns
  after an hour. That is intended, and `DisposableGuestOutlived` covers the case
  that matters.
- **The tag is the switch.** Removing `disposable` from a guest silences the
  alert, which is the right way to say a guest is no longer a throwaway. It also
  means the tag must not be removed to quiet a reminder.
- **`docs/architecture.md` will carry `diabolos` as not built yet most of the
  time.** That is accurate. Its row says it is torn down between
  investigations, and `docs/network.md` reserves the address in prose, the way
  `ifrit`'s is, rather than in the built-host table.
- **Detonation does not happen here.** This stack is the store, not the sandbox.
  Running a sample is a question for the range (ADR-0014, ADR-0017), and a
  sample's host enrols into this guest's manager with this guest's password,
  never into `odin`'s.
- **Two copies of one file.** `stacks/scratch/wazuh/indexer/internal_users.yml`
  must follow soc's. Its header says so. Everything else is mounted.
