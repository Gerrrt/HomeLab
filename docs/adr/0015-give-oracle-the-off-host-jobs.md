# ADR-0015: Give oracle the off-host jobs

**Status:** Accepted · 2026-09

> [!NOTE]
> "Not a second age recipient", below, is narrowed by
> [ADR-0024](0024-hold-a-second-age-recipient-and-prove-each-one-separately.md).
> The rejection of **`oracle`** as a recipient is unchanged and still the design
> — this machine holds ciphertext and no key. What ADR-0024 sets aside is the
> broader framing quoted with it, that a second recipient is worth having only
> once the lab stops being a one-person project: that makes a loss problem read
> as a headcount one. A second recipient, held offline and off this estate, is
> now the design. The text here is left as written, per ADR-0001.

## Context

[#94](https://github.com/Gerrrt/HomeLab/issues/94) opens with "`oracle`
(10.0.99.30) has no defined purpose" and offers four options: an off-host
watcher for the dead man's switch, a second SOPS/age recipient, a backup
target, or switch it off.

The premise is false, and has been since 2025-11-12. Checked on the host on
2026-09-03:

```console
$ docker ps --format '{{.Names}}\t{{.Image}}\t{{.CreatedAt}}'
wiki    ghcr.io/requarks/wiki:2  2026-09-03 04:45:46 +0000 UTC
alloy   grafana/alloy:v1.19.2    2026-09-02 00:17:32 +0000 UTC
db      postgres:17              2025-11-12 22:55:04 +0000 UTC
```

That is the Lemmiwinks wiki, published on 80 and 443, with its Postgres
alongside it; `db` dates the deployment, and the `wiki` container has been
recreated since, most recently the morning this was written. It is not an
experiment somebody left running:
[ADR-0011](0011-keep-the-wiki-internal.md) names the host — "a container on
Oracle at `10.0.99.30`" — and makes it the middle of three documentation tiers.
[`stacks/observability/prometheus/targets/blackbox.yaml`](../../stacks/observability/prometheus/targets/blackbox.yaml)
probes it twice, by name and by address, labelled `host: oracle`; both probes
were green when this was written.

So `oracle` has had a defined purpose for nine months, and three places in this
repository said otherwise at the same time: the host table in
[`architecture.md`](../architecture.md) ("*(none yet)*  … otherwise
undecided"), the VLAN 99 table in [`network.md`](../network.md) ("`oracle`'s one
role is to hold the off-host copy of the firewall export"), and the header of
[`backup-firewall.sh`](../../scripts/backup-firewall.sh) ("It has no role
(#94)"). `check_docs.py` reads that architecture row for the word "Alloy" and
for a `stacks/` path, and never for what it claims the machine does — which is
how a wrong sentence sat next to a checked one for months. This ADR is
therefore as much a correction as a decision.

### What the machine actually is

Measured on 2026-09-03, not quoted from the inventory that was wrong once
already:

| | |
| --- | --- |
| CPU | AMD A6-9200, 2 cores |
| RAM | 3785 MiB total; 1236 MiB used, 2549 MiB available with the wiki, its database and Alloy all running |
| Resident | `wiki` 144 MiB, `alloy` 147 MiB, `db` 49 MiB |
| Disk | ST500LT012, 465.8 GB, 5400 rpm. `sda3` is a 462.7 GB LVM PV carrying a single 100 GB LV — 67 GB free on it, ~362 GB unallocated in the volume group |
| Network | `enp20s0` at 100 Mb/s full duplex. The NIC advertises 10/100 only, so that is the ceiling and no cable will lift it — `prometheus` links at a gigabit through the same unmanaged switch |
| Load | 0.17, at 8 days uptime |

Two slow cores and a 5400 rpm disk rule out anything with a working set or an
IOPS floor: ADR-0007's second observability stack on `Saruman`, ADR-0008's
sensitive tier, any database under load. #94 says that already and it is still
true.

They do not rule out work that is idle almost all the time and whose value is
*where it runs* rather than how fast. The estate has exactly one such
category — jobs that must not be on the monitoring host — and exactly one other
machine that is powered, monitored, on the right VLAN and already trusted with
none of the secrets.

## Decision

**`oracle` stays powered, and it is the estate's second host for small
off-host jobs: work whose whole value is that it is not running on
`prometheus`.** Nothing else. Five things, three of which it is already doing:

| Job | State |
| --- | --- |
| The Lemmiwinks wiki and its Postgres | Running since 2025-11-12. Ratified here, not newly assigned — ADR-0011 already depends on it |
| The off-host copy of the firewall export | Running since 2026-09-03, [#92](https://github.com/Gerrrt/HomeLab/issues/92). Ciphertext, no key |
| An Alloy agent | Deployed 2026-08-30, redeployed by `scripts/deploy-agent.sh`. #94 asked for this "either way"; it stays |
| The off-host copy of the volume backup sets | **New.** The remaining half of #92 |
| The dead man's switch watcher | **New.** [#67](https://github.com/Gerrrt/HomeLab/issues/67) |

The two new jobs are decided here and built under their own issues. Neither is
implemented by this ADR.

**The volume sets fit, and they are already in the right shape to leave the
host.** A set is 867 MB — five `.tar.gz.age` archives and a MANIFEST — and
`KEEP` is 7, so 6.1 GB against 67 GB free, alongside 30 firewall exports at
172 KB each. `backup-volumes.sh` already encrypts every archive to the
`.sops.yaml` recipient with `age -r` before it touches the disk, so the copy
that lands on `oracle` has exactly the property the firewall copy has: a
compromise of that machine yields ciphertext and no key. The set is written
weekly — `homelab-backup-volumes.timer` is Sunday 03:30 — and a full one is
about 75 seconds of wire time at the 100 Mb/s ceiling. Neither the disk nor the
link is the reason not to do this.

**The dead man's switch goes here because there is nowhere else.** #67's hard
requirement is a watcher that does not fail at the same time as the thing it
watches. `oracle` is the only machine in the estate that is not the monitoring
host and is already powered, monitored, reachable and administered from this
repository. `Saruman` is a hypervisor whose guests do not exist yet; `morpheus`
is the firewall and takes no third-party workloads; `ifrit` is unpurchased.
That is not an enthusiastic argument, and the Consequences below say exactly
how much it buys.

### And four things it is not

**Not a second age recipient.** This is the option that looks free and is not.
The gap `back-up-the-age-key.md` names is "one key, one person" — and it
answers itself: the fix is "a second keypair that lives only offline", "worth
doing on the day the lab stops being a one-person project, and not before —
every extra recipient is another key that can leak". A second key on a powered,
network-attached host in the same room, administered by the same person, adds
no person and no offline copy. It only adds a key.

Worse, it would be *this* host. The entire argument for putting the firewall
export on `oracle` is that the machine holds ciphertext it cannot read. Giving
it a private key that decrypts the estate's secrets makes it the one place
where the backups and the means to open them sit on the same 5400 rpm disk, and
retires the property the off-host copy was built to have. Rejected on those
grounds rather than on cost.

**Not the second observability stack, and not the sensitive tier.** ADR-0007
puts the first on `Saruman` and ADR-0008 the second on Winterfell. The hardware
table above is the whole argument.

**Not dual-homed.** `wlp22s0` exists and is `DOWN`. Bringing it up on the house
wireless would give the dead man's switch a notification path independent of
the shelf switch, which is genuinely tempting and is the reason to write this
down: it would also make a VLAN 99 host a bridge between the segment that
administers every other segment and an untrusted one, defeating ADR-0002 and
the ruleset ADR-0013 documents, in software, invisibly to the firewall. The
interface stays down. If the watcher needs an independent path badly enough,
the answer is a device that is not on VLAN 99 at all.

**Not switched off.** #94 offers this, and it was never actually available —
the wiki had been running there for nine months when the issue was filed, and
nothing said so. Powering the machine down takes the wiki with it, and ADR-0011
spends a page establishing that the wiki is the tier the household reads.

## Consequences

- **Off-host is not off-site, and here it is not even off-shelf.** Both laptops
  sit on the same shelf, behind the same unmanaged switch, on the same mains
  and under the same roof. `oracle` protects against `prometheus`'s disk
  dying, a bad `docker volume rm`, and a stack that will not come back up. It
  protects against a fire in that room not at all, and
  [#92](https://github.com/Gerrrt/HomeLab/issues/92) still says so.
- **The dead man's switch on `oracle` detects the failure it was designed for,
  and very little else.** A webhook pointed at a deleted ntfy topic returns 200
  and the watcher catches it — that is #67's whole complaint and it is worth
  the machine. A mains cut is different: both laptops ride it out on their own
  batteries (`oracle`'s is at 29.9 Wh of a 41.4 Wh design) while the switch
  between them has none, so both go deaf together and the watcher cannot report
  it. [#110](https://github.com/Gerrrt/HomeLab/issues/110) is where that gets
  fixed; until it does, the watcher's silence during a power cut is expected
  behaviour rather than a fault, and whoever writes the runbook should say so.
- **Ratifying the wiki names a gap this ADR does not close.** The wiki is not
  in this repository. Its containers were created by hand — no compose file, no
  labels, `unless-stopped`, an anonymous volume holding `/wiki/data/content`
  next to a named `pgdata`, and a database password in `/etc/wiki/.db-secret`
  at mode 664. Nothing backs either volume up, and ADR-0004 wants one compose
  stack per host. The content itself survives regardless, because Wiki.js syncs
  from the Lemmiwinks GitHub repository — what is at risk is the accounts,
  history and configuration, and the time to rebuild it. Deciding the role is
  what makes that a tracked gap instead of an unowned one:
  [#251](https://github.com/Gerrrt/HomeLab/issues/251).
- **`oracle` becomes load-bearing, which it was already, undeclared.** The
  middle of ADR-0011's three documentation tiers now has an owner written down,
  and the machine holding the backups is also the machine serving the
  documentation for restoring from them. That is acceptable at this size and
  worth re-reading if either job grows.
- **The 100 Mb/s ceiling is a constraint on what may be added later, not on
  what is decided here.** 867 MB a week is fine, and so is a 172 KB export
  every night. A job that wants to move tens of gigabytes is not, and there is
  no upgrade path on this NIC.
- **There is room to grow without touching anything.** 362 GB of the volume
  group is unallocated, so a retention increase is `lvextend` and
  `resize2fs`, not a new disk.
