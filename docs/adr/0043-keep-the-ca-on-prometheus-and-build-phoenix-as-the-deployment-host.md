# ADR-0043: Keep the CA on `prometheus`, and build `phoenix` as the deployment host

**Status:** Accepted · 2026-09 · supersedes the management-plane rule of
[ADR-0014](0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
and amends the first consequence of
[ADR-0039](0039-decline-proxmox-clustering-while-ifrit-is-the-range.md)

## Context

[#436](https://github.com/Gerrrt/HomeLab/issues/436) is the prerequisite for
the Packer, OpenTofu and Ansible work that follows it. The estate has
thirty-odd ADRs and a convergence loop that refuses to deploy without a pinned
signature, and it builds virtual machines by clicking in a browser from a
Hicks workstation. The toolchain that would change that wants a host: one that
holds a Proxmox API token, an SSH key and a checkout, and stays up. The issue
places it — a guest on `Saruman`, VLAN 30, a dedicated Proxmox user rather
than `root@pam` — and then carries one question it declines to answer by
default: where the estate's certificate authority should live, given that the
root key sits today on the monitoring host's unencrypted disk.

The issue asked for that to be decided rather than inherited, and for the key
not to move as a side effect of the build. Both are honoured here. Deciding it
meant reading the root first, and the reading changed the question.

### The issue's premise, corrected

The issue says the tree is already shaped for a move either way, because
"`stacks/sensitive`'s step-ca is already an intermediate beneath that root".
It is not. The estate's root is minted with
`basicConstraints=critical,CA:TRUE,pathlen:0`
([`scripts/gen-certs.sh`](../../scripts/gen-certs.sh)), which forbids any CA
beneath it, and
[ADR-0037](0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md)
gave the tier a root of its own for exactly that reason — after measuring the
failure, `path length constraint exceeded`, in the Go `crypto/x509` every
client here is built on. "An intermediate beneath the lab CA" is the sentence
ADR-0037 was written to retract, and the issue was written before it.

Two things follow. The CA question is not a tree-shape question; there is one
root, it can have nothing beneath it, and the only thing to decide is where
one key file sits. And losing that file does not mean "cannot reissue" — it
means a new root: `--ca --force`, two leaves, one copy through the Mac, and a
re-trust everywhere the old `ca.pem` was imported. That path is already
written in [`successor-handover.md`](../runbooks/successor-handover.md), and
ADR-0037 counted its cost. It is bounded. What is *not* written is the list of
places `ca.pem` was ever trusted, which ADR-0037 admits is "the Mac's system
store and Firefox's separate one, at least, and whatever else nobody wrote
down".

### What `phoenix` is, and what it holds

A deployment host is not a server that serves anything. It is the one machine
in the estate whose purpose is to hold **credentials for other machines**: a
Proxmox API token that can create and destroy guests on the hypervisor whose
own firewall ADR-0014 relies on, an SSH key that the toolchain will inject into
every guest it builds, and a checkout of this repository. It is the estate's
first hypervisor API credential — nothing in this repository calls `pveum` —
and it is a pet: the thing that rebuilds everything else, and that nothing
rebuilds. Since
[ADR-0042](0042-terminate-the-remote-path-on-the-lab-and-route-it.md) it is
also the host the estate's first inbound path from the internet terminates
on: the WireGuard peers of `172.31.0.0/24` arrive on `phoenix` and are routed
into the lab from it.

That is the property that decides the CA question, and it decides it before
any argument about disks. The estate's signing key on the same host as the
estate's lateral-movement credentials means one compromise yields both "I can
reach every box" and "I can mint a certificate any of them will trust".
Keeping those two things on different machines is not a refinement; it is the
whole reason to have a key that never leaves one host. A machine that is both
the tunnel's end and the holder of the hypervisor's token is the last place in
the estate for its signing key.

### Where the key could go, counted

**On `prometheus`, where it is.** A 2012 laptop with an unencrypted disk and
swap, recorded as an accepted residual in [`SECURITY.md`](../../SECURITY.md)
on a threat model that excludes physical access to the rack, and already the
custodian of the estate's two other root secrets: the age key
([ADR-0005](0005-secrets-with-sops-and-age.md)) and the tier's cold root
(ADR-0037 §2). `gen-certs.sh` prices its passphrase-less key against exactly
this: "the exposure this time is bounded by the key never leaving this host".

**On `phoenix`, on VLAN 30.** The issue frames this as trading one unencrypted
disk for another. The disks are equivalent; the segments are not. ADR-0014
calls ImaginationLAN "the segment that holds attackers" in its own decision,
scopes `ifrit`'s attack VM to reach `10.0.30.0/24` on purpose, and has it take
a lease from the pool like any other guest. `10.0.30.70` is inside the range
the estate's own Kali is configured to scan.
[`build-the-lab-guest.md`](../runbooks/build-the-lab-guest.md) already says
what that means for this file: "a copy of it on a machine that sits on the
segment built to hold attackers is a different class of problem from a leaked
leaf". And the transfer the move is meant to remove does not go away — it
inverts and grows. `99 → 30` is closed, so today one leaf, `alexander`'s, is
carried through the Mac with `scp -3`. With the CA on `phoenix`, the Grafana
leaf on `prometheus` acquires that hop, `alexander`'s keeps it, and both hops
now carry a private key rather than a certificate.

**Cold, on the offline medium that holds the age key's second copy.** This is
the tier's model, and it works for the tier because an intermediate does the
daily issuing while the root sleeps. The estate's root has `pathlen:0`; there
is no intermediate and cannot be one. "Cold" here means every issuance mounts
removable media, which is the interactive-issuance failure `gen-certs.sh`
rejects in as many words: "how a lab ends up with one long-lived certificate
nobody dares reissue".

**On `trinity`, beside the tier's root.** The tier's root is not on `trinity`.
ADR-0037 §2 keeps it cold on `prometheus` and ships `trinity` a bundle with the
key left out — so "beside the tier root" already means `prometheus`. `trinity`
is also the host ADR-0037 describes as carrying the largest attack surface in
the estate, in a section titled *What `trinity` could forge*, and it is not
built ([#404](https://github.com/Gerrrt/HomeLab/issues/404)).

**Re-mint at `pathlen:1`, and issue from an intermediate on `phoenix`.** The
one option that gives the deployment host issuing power without the root, and
the one that has to be answered rather than dismissed. ADR-0037 costed this
exact re-mint and declined it for a stronger warrant — so that the household's
devices could trust one root — with the test "not the size of the cost but who
pays it and for what". A deployment host is a weaker warrant than the
household. And it re-creates precisely what ADR-0037 closed: an intermediate
on VLAN 30 can mint `grafana.matrix.elysium`, and Prometheus, blackbox and the
operator's browser will accept it.

There is one PKI role a deployment host can hold without touching any of
this: carrying the *public* root, `ca.pem`, which `gen-certs.sh` prints as
"safe to distribute", to the guests it builds. That is noted and not decided.

### Three declines this has to answer

[ADR-0002](0002-vlan-segmentation-strategy.md) and
[ADR-0012](0012-publish-only-ports-with-an-off-host-consumer.md) both say a
bastion "is not worth it at this scale", and a host called a jumpbox reads as
one. Both declines are about a specific thing: an SSH chokepoint a compromised
Hicks workstation would have to traverse to reach Winterfell. `phoenix` is not
that and structurally cannot be. It is a guest on VLAN 30, VLAN 30 has no pass
into 99, and "guests get no such rule" is
[ADR-0007](0007-defensive-estate-and-offensive-range.md)'s sentence, restated
three times in [`network.md`](../network.md). A machine that cannot reach the
segment a bastion exists to protect is not that bastion.

[ADR-0021](0021-converge-on-a-timer-instead-of-deploying-over-ssh.md) chose
pull over push, and rejected `ansible-pull` as "a wrapper around `make up`".
It decided how a host **that already exists and runs a stack** gets its
configuration. It decided nothing about how a host comes into existence,
because there is no host-creation plane in the estate at all: eight guests
are planned, six of them Windows, every one built by hand from a runbook.
ADR-0021 also kept a push plane on purpose and said so — "`oracle` and
`saruman` are pushed to by `deploy-agent.sh`. That is not a transitional
state" — and `phoenix` inherits that half, not the half ADR-0021 decided
against.

### The rule the issue did not count

The issue says the host "needs no new rule", and on `morpheus` that is true:
[ADR-0031](0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md)
already carries Hicks to all of VLAN 30, and everything `phoenix` pushes to is
on its own segment. But the Proxmox API is not behind `morpheus`. ADR-0014
closes it on the hypervisor itself: the Proxmox firewall on `Saruman` "admits
`8006`, `8007` and `22` from `10.0.50.0/24` only", written as the one control
against "an attacker sharing a broadcast domain with the estate's hypervisor".
A guest on VLAN 30 that drives the API has to be admitted through it, and
today nothing on VLAN 30 is — ADR-0039 lists that as a consequence it relies
on.

ADR-0042 saw the same collision and left it here: "whichever issue lands
first owns it, and routed mode is what stops a widened `8006` rule from
silently admitting every VPN peer." This is that decision.

So building what #436 asks widens that rule by exactly one source address on
exactly one port, on the hypervisor's own firewall and nowhere on `morpheus`.
The alternatives are a host on Hicks, which has no hardware to be a guest of,
and a host on Winterfell, which the issue rejects for ADR-0008's reason and
which would need a rule on `morpheus` instead. The widening is accepted, with
its cost stated below rather than found later.

## Decision

**The estate's root key stays on `prometheus`. `phoenix` is built as a guest
on `Saruman` at `10.0.30.70`, holds the hypervisor's first API credential and
no key that signs anything, and gets one pass to `8006` on `Saruman` and no
pass anywhere else.** Four parts.

**1. `certificates/ca-key.pem` does not move, and this ADR is the reason the
next proposal argues with.** The arguments are the ones counted above, in
order of weight: the host that holds credentials for every other host must
not also hold the key every other host trusts; VLAN 30 is the segment ADR-0014
built to hold attackers, at an address the range is scoped to reach; the
through-the-Mac transfer inverts and doubles rather than disappearing; and
custodianship of root secrets is already a property of `prometheus` decided
twice, so moving one of three creates a second place to remember rather than
less concentration. Nothing in `gen-certs.sh` binds the CA to a host — the
path is relative to whichever checkout runs it — so this invariant is a
sentence in this document and a comment beside the `pathlen:0` line, and
those are what hold it.

**2. `phoenix`.** A VM, not an LXC, on `Saruman`, VMID `170`, `10.0.30.70/24`
with a Kea reservation, Ubuntu Server LTS, and a Final Fantasy summon like
every other named host on the segment — `shiva`, `ifrit`, `alexander`, `odin`
and ADR-0029's six. That is a segment-local pattern and is claimed as one;
[ADR-0038](0038-name-the-nas-smaug-and-reserve-zion-for-the-box-that-does-not-exist.md)
holds that the estate has no naming scheme, and it is right. It runs no
compose stack and no Docker. Its Alloy is the native package, deployed by
`scripts/deploy-agent.sh` from the Mac, and pushes to the lab's stores on
`alexander` — never to `10.0.99.20`, per ADR-0007 — which makes it the first
use of that script's `--monitoring-host` flag and the second client the lab's
Prometheus and Loki open their ports for, or the first, whichever of it and
`odin` is built first.

Three sentences bound what it is, and each is a control only because it is
written down:

- **It gets no pass out of VLAN 30.** It is a guest, and ADR-0007's "guests
  get no such rule" covers it exactly as it covers `alexander` and `odin`. A
  rule from `10.0.30.70` into Winterfell would make it the bastion ADR-0002
  and ADR-0012 twice declined; that is a new ADR, not a runbook step, and
  [`firewall-claims.yaml`](../firewall-claims.yaml) will not catch it, because
  it records wholesale posture and "deliberately NOT a list of what each
  segment can reach".
- **It is a deployment host, not a transit host into any other segment.**
  What crosses it is ADR-0042's tunnel, routed into the lab and nowhere else,
  and that is the whole of it: no interactive SSH to another machine goes
  through it, `ProxyJump` through `phoenix` is not a supported path, and the
  day it becomes one is the day ADR-0002's decline is reopened rather than
  worked around.
- **It holds no age key and runs no `make up` against another host.** The
  toolchain builds machines. Once a machine exists and runs a stack, ADR-0021
  owns how it converges, and a `phoenix` that pushed compose stacks over SSH
  would be the `ansible-pull` rejection re-litigated with a different tool.

**3. The hypervisor credential, and the one rule that admits it.** A dedicated
Proxmox user, `phoenix@pve`, with a role of its own scoped to guests and the
storage and bridge they need — `VM.*`, `Datastore.AllocateSpace`,
`Datastore.AllocateTemplate`, `SDN.Use` on `/vms`, the two storages and
`vmbr0` — plus read-only audit on the node, and nothing under `/nodes` beyond
that. Never `PVEAdmin`, never `root@pam`: the token that can create guests
must not be able to touch the host firewall ADR-0014 depends on. The token is
issued with privilege separation off, as the issue asks, so it carries the
user's permissions and no second set to keep in step.

The credential lives on `phoenix` at mode 600, outside this repository. That
is a stated deviation from the issue's "credential into `secrets/`", and it is
forced rather than chosen: `scripts/check_sops_rules.py` derives the paths it
proves each rule against from the stack directories, so a `secrets/phoenix`
rule matches nothing and fails CI until a `stacks/phoenix` exists, and
`bootstrap.sh` needs an example file and a placeholder rule to run at all. The
encrypted-in-repo form arrives with the toolchain issue that consumes the
token, which is what defines the file's shape. Until then it is
[ADR-0015](0015-give-oracle-the-off-host-jobs.md)'s posture in reverse: one
file, one host, nothing in git.

ADR-0014's rule on `Saruman` gains one line: `10.0.30.70` to `8006`, TCP,
unlogged. Not `22` — the API is the whole interface, and `qm` over SSH is the
clicking this host exists to replace. The cost, stated: the rule is by source
address on a segment where the attack VM shares the wire, so it can be spoofed
by a guest that takes `.70` while `phoenix` is off. What that buys an attacker
is reachability to an authenticated API from a less trusted segment than
Hicks — Proxmox's login surface, not its privileges. The token is the control;
the rule is the door. ADR-0042's routed mode is what keeps the door that
narrow: a tunnel peer arrives with its own `172.31.` source and does not
inherit a pass written for `10.0.30.70`, which under NAT every peer would. `firewall-claims.yaml` cannot see this either, because
it lives in `/etc/pve` and not in pf, and the marked amendment on ADR-0014 and
ADR-0039 is the only place the widening is recorded.

**4. The custody of `ca-key.pem` is a found gap, named here and fixed under
[#496](https://github.com/Gerrrt/HomeLab/issues/496).** The age key has
[ADR-0024](0024-hold-a-second-age-recipient-and-prove-each-one-separately.md)
and [`back-up-the-age-key.md`](../runbooks/back-up-the-age-key.md): a second
recipient off-host and off-estate, proved on demand by decrypting the real
ciphertext, nagged at ninety days. The tier's root goes to the same offline
medium by [`build-the-tier-ca.md`](../runbooks/build-the-tier-ca.md). The
estate's root has nothing — not a copy, not a sentence. The loss is bounded,
as counted above, and the reason it gets the age key's backup and not, yet,
the age key's alerting is one sentence: an age key has no re-mint path, and a
CA does. Two things are decided so the issue is specifiable rather than
aspirational. It is not SOPS-in-git — ADR-0037 rejected that for the tier's
root, and this key is one of the ones purged from history. And it is not a
passphrase, which reopens the trade `gen-certs.sh` closes deliberately. The
proof, when it is built, needs no decryption: the public half of the backup
compared with the public half of `ca.pem`, a sibling of
`verify-key-backup.sh` with the same refusal to run against the live key.

## Consequences

- **The lab's Prometheus and Loki open to a first off-host client, and the
  runbooks stop assuming which one.** `stacks/lab/compose.yaml` ships both
  `ports:` blocks commented, and
  [`build-the-soc-guest.md`](../runbooks/build-the-soc-guest.md) §7 was the
  step that uncomments them for `odin`. `phoenix` is the same kind of client
  and may be built first, so its runbook carries the same step conditionally
  and the comments in `stacks/lab` name both. Being scraped by `alexander`
  instead, the way ADR-0029's six are, was considered and loses on one fact: a
  deployment host's value in an incident is its logs — what it did, to which
  guest, when — and a scrape carries nothing to Loki.
- **One address on VLAN 30 now reaches the hypervisor's API**, and two ADRs
  said none did. ADR-0014's rule is superseded by this one and ADR-0039's
  first consequence is amended, each with a marked note per
  [ADR-0001](0001-record-architecture-decisions.md), and the text of both is
  left as written. ADR-0042 listed this widening under what would reopen it,
  and it has happened; it is discharged rather than reopened, because what
  that ADR asked of the widening — routed mode, so the pass admits one host
  and not every peer — is what part 3 relies on, and it carries a note saying
  so.
- **Its telemetry lands where no house alert looks, and ADR-0042 already says
  so.** The Alloy on the host that terminates the internet's only path in
  pushes to `alexander`, per ADR-0007, and nothing on Winterfell reads that
  store. This ADR does not change that; it notes that the deployment host and
  the tunnel host are the same machine, so the gap ADR-0042 records is this
  host's.
- **The estate holds its first hypervisor API credential**, and its scope is
  the sentence to argue with when the toolchain wants more. The Packer and
  OpenTofu issues will find out which privileges the role is missing; they add
  privileges to the role, not the role to `/`.
- **No purchase.** A guest on hardware already owned. Every other new host in
  the roadmap has arrived with a row in the buy table, and this one does not.
- **`gen-certs.sh`'s `pathlen:0` comment gains a line** saying the key does
  not move to the deployment host and why, the way ADR-0037 amended the same
  comment. That comment is where the next person will look.
- **`docs/hardware.md`'s Alloy agent count is wrong on the day `phoenix` is
  built**, not before: a `**Not built yet**` row does not count, and dropping
  the marker fails `check_docs.py` until the sentence says the new number.
  The runbook's last section lists that with the other build-day edits.
- **Reopened by:** ADR-0037's own condition — Grafana renewing from step-ca,
  at which point the estate's CA can be argued out of existence and this
  question with it; `phoenix` needing any pass out of VLAN 30, or `22` on
  `Saruman`, either of which is the bastion this ADR says it is not; or a
  client appearing that must trust both roots.
