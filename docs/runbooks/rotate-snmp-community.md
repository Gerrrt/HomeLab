# Runbook: Rotate the SNMP communities

**Target:** four SNMP devices — pfSense, the APC NMC, the MokerLink switch, HPE iLO
**Time:** ~45 minutes, one device at a time; §4, the move of one device to
SNMPv3, is a separate pass of about 20 minutes
**You will need:** the age key, physical access to the ProLiant for the iLO step,
and a way onto `10.7.7.0/24` that does not depend on the switch you are about to
reconfigure

**Why this is not optional.** A single SNMP community string was committed to
this public repository in plaintext and shared across pfSense, the MokerLink
switch, the APC UPS and the ProLiant's iLO. It is still in git history. Anyone
who cloned the repository at any point has it.

These are read-only communities, which sounds mild. On a firewall, read-only
means the complete state table, every interface and the full pf configuration
surface. Treat them as credentials.

**Order matters:** change the device first, then the repository. Doing it the
other way round means the exporter starts failing before the device is ready.

**Rotate one device end to end, then move to the next.** The repository already
holds a separate key per device, so each one is independent: a mistake takes down
one target instead of four, rollback is per-device, and if a UI locks you out
half way through you are left with some devices done and the rest untouched
rather than a fleet in an unknown state. Do not batch the four changes.

---

## Before you start

Only the four `snmp` targets are affected by any of this. Prometheus, Loki,
Grafana and every Alloy agent keep running throughout.

Each device has its own way of locking you out. Read these before you start, not
after.

**HPE iLO** (`shiva`, 10.0.30.10) — do this one last, and only with physical
access to the ProLiant.

> Saving SNMP settings can reset the management processor and drop your session.
> Nothing about that touches the running server — the BMC is out-of-band — but
> you lose remote console until it comes back. Recovery is `hponcfg` from the
> host OS, or a trip to the rack.

**APC Network Management Card** (`mjolnir`, 10.0.99.10) — the card restarts its
network interface on save, typically for 30-60 seconds.

> **The UPS keeps supplying power throughout** — the NMC is management only, not
> the inverter. If the card does not come back, recovery is its serial console.
> On most NMCs the pinhole is short-press-to-restart and
> long-press-to-factory-default; know which one you are pressing, because a
> factory default means reconfiguring the entire card.

**MokerLink switch** (`neo`, 10.7.7.2) — this is the switch everything runs
through.

> Losing its management address does not drop traffic — layer 2 keeps forwarding
> — but you cannot reconfigure it until you get back in. The monitoring host at
> `10.0.99.20` reaches `10.7.7.2` through two pfSense rules, both recorded in
> [ADR-0013](../adr/0013-segment-access-as-implemented.md): the outbound
> `10.0.99.20 → 10.7.7.2:161-162/udp` and the switch's return path
> `10.7.7.2 → 10.0.99.20:161-162/udp`. Either one missing presents the same way,
> as a timeout. **If exactly one device fails verification and it is this one,
> suspect those rules before you suspect the community.**
>
> Its SNMP community table also will not persist a deletion, and every attempt
> drops the SNMP agent until the switch is rebooted. §2.5 has a separate route
> for this device; read it before you open the UI.

**pfSense** (`morpheus`, 10.0.99.1) — the low-risk one, but check what you are
standing on.

> Confirm the SNMP daemon binds only to the VLAN 99 interface — not WAN, not
> "all" — and that you are not administering the firewall through the interface
> you are editing.

## 1. Generate four distinct communities

```bash
make gen-secret ARGS=--snmp
```

One per device, keyed by the device list in `prometheus/targets/snmp.yaml`. The
whole reason the old arrangement was dangerous is that a single string unlocked
everything.

**Check each device's maximum community length first.** Several APC NMC firmware
revisions cap it at 15 characters and truncate silently, which presents as the
UPS rejecting a community you know you typed correctly. If yours is one of them:

```bash
make gen-secret ARGS="--snmp --length 15"
```

15 alphanumerics is still ~89 bits, which is fine. The generator uses
`[A-Za-z0-9]` only — every other character has a specific way of going wrong
quietly somewhere between `secrets-edit` and the wire.

The card in this lab accepts 16 and is verified working at that length, so the
cap is not universal to the model. Check yours rather than assuming it either
way: from the monitoring host, a silent truncation and a correct community are
indistinguishable — both present as the device refusing you.

Note that SNMPv2c sends these in cleartext on every poll. Distinct communities
limit the blast radius of a captured packet; they do not make the protocol
secure. The iLO and the UPS card move to SNMPv3 authPriv under
[ADR-0036](../adr/0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md)
— that is [§4](#4-move-a-device-to-snmpv3), a separate pass — and a device
that has moved has two passphrases here instead of a community.
`make gen-secret ARGS=--snmp` prints whichever shape each device currently
has. The firewall and the switch stay on v2c, for reasons the ADR gives.

## 2. Rotate each device

Work through them in this order — cheapest recovery first, physical access last:
**pfSense → APC → MokerLink → iLO**.

For each device, run the whole of §2.1 to §2.5 before starting the next one.

The one exception is the MokerLink switch, whose §2.5 needs a reboot window and
can legitimately be left for a later pass — §2.1 to §2.4 stand on their own, and
the switch polls correctly on its new community in the meantime. That is exactly
what happened on the rotation this runbook came out of; the leftover is
[#84](https://github.com/Gerrrt/HomeLab/issues/84). Deferring it is a decision to
record, not one to make silently.

### 2.1 Add the new community — do not remove the old one yet

> **Add, do not replace.** Until the new community is proven end to end, the old
> one is your rollback credential. Deleting it before you have verified the new
> one is what turns a typo at 2am into a drive to the rack. Some devices append
> rather than replace anyway; §2.5 is where that gets cleaned up.

**pfSense** (`morpheus`, 10.0.99.1) — **Services → SNMP.** Set the read community
string. Confirm the daemon binds only to the VLAN 99 interface.

**APC Smart-UPS** (`mjolnir`, 10.0.99.10) — Network Management Card web UI,
**Configuration → Network → SNMPv1 → Access Control.** Set the community for the
`prometheus` host entry, access **Read**, and restrict the NMS address to
`10.0.99.20` if the card supports it.

**MokerLink switch** (`neo`, 10.7.7.2) — Web UI at `http://10.7.7.2`,
**SNMP → Community.** Add the read-only community. Delete any default
`public`/`private` entries while you are in there — those are not your rollback
credential and should not survive this.

> Expect those deletions not to stick. This firmware does not persist a removal
> from the community table: the row can be deleted, applied and saved, and it is
> still there after a restart — and each attempt drops the SNMP agent until the
> switch is rebooted. On `neo` they did not stick: both `public` and `private`
> still answer, measured from the monitoring host on 2026-09-06 and 2026-09-09. Retiring an entry here means overwriting it, which is
> [§2.5's MokerLink route](#the-mokerlink-switch-overwrite-the-row). Nothing in
> this step depends on the deletion succeeding, so add the new community, try the
> defaults once, and carry on.

**HPE iLO** (`shiva`, 10.0.30.10) — **Administration → Management → SNMP
Settings.** Set the read community.

### 2.2 Update the repository

```bash
make secrets-edit
```

Set the one key for the device you just changed:

```yaml
SNMP_COMMUNITY_PFSENSE: <new>
SNMP_COMMUNITY_APC: <new>
SNMP_COMMUNITY_MOKERLINK: <new>
SNMP_COMMUNITY_ILO: <new>
```

Mind the space after the colon. `KEY:value` without it does not fail — it sets
the community to the entire line, which renders cleanly and is rejected only by
the device.

### 2.3 Apply

```bash
make render
make reload
```

`make render` fails loudly if any placeholder is left unsubstituted, so a typo in
a key name is caught before anything restarts. `make reload` is enough:
snmp-exporter reads its config once at startup but serves an unconditional
`POST /-/reload`, so no container needs recreating.

`make up` also works — it runs the same reload after `docker compose up -d`.
Until PR #19 it did **not**, and that was a trap rather than a longer road:
`compose up -d` recreates a container only when its *service definition*
changes, so a freshly rendered `snmp.yaml` was invisible to it. `make up`
reported success and snmp-exporter went on polling with the old community.

### 2.4 Verify

```bash
./scripts/snmp-verify.sh --device morpheus
```

Or `make snmp-verify` for all four at once. Each device must report `PASS` with
its sysDescr string — that is also how you confirm you reached the box you meant
to.

The same run then probes every device that passed with the stock `public` and
`private`. A device that answers either is reported `WARN` — not a failure in
plain mode, for the reason the script's comment gives: the weekly timer runs
plain mode into an alert that would otherwise stay lit for the weeks it takes
to get a reboot window on `neo`, hiding any other failure behind it. Under
`--old` the same finding is a `FAIL`. Today `neo` is the device that warns;
[§2.5](#the-mokerlink-switch-overwrite-the-row) is where that gets fixed.

The community never appears in an argument vector. The block this replaced put it
into your shell history and, for the life of the process, into
`/proc/<pid>/cmdline`, which is world-readable — any local user running `ps` gets
it. `snmp-verify.sh` passes it to net-snmp through a `defCommunity` line in an
`snmp.conf` under `SNMPCONFPATH`, in a 0700 directory on tmpfs that is removed on
every exit path including Ctrl-C.

Then confirm Prometheus agrees — **Status → Targets**, job `snmp`, or:

```promql
up{job="snmp"}
```

The target should return within 60 seconds. The `SnmpTargetUnreachable` alert
fires after 10 minutes, so a mistake here announces itself.

If a device fails here, establish whether you broke it before you roll anything
back — `max_over_time(up{job="snmp",instance="<ip>"}[30d])`. `1` means it was
working before you started and the rotation is the suspect; `0` means it never
worked, the rotation is not the cause, and reverting will not bring it back.

### 2.5 Retire the old community, then prove it is gone

Only once §2.4 is green. How you retire it depends on the device.

#### Most devices: delete the row

pfSense, the APC NMC and iLO. Delete the old entry in the device's UI — some UIs
require deleting the row rather than blanking the field. Then go to
[**Prove it**](#prove-it).

#### The MokerLink switch: overwrite the row

`neo` is the exception, and the paragraph above does not work on it. Its
firmware accepts the deletion, applies it and saves it, and the row is still
there after a restart. Every attempt also drops the SNMP agent until the switch
is rebooted, so retrying is not free — this is the residual recorded in
[`SECURITY.md`](../../SECURITY.md) and tracked as
[#84](https://github.com/Gerrrt/HomeLab/issues/84).

There is more than one row to retire. Besides the previous community, the
switch still answers the stock `public` and `private` — the defaults §2.1
deletes, whose deletion did not persist either. Measured from the monitoring
host on 2026-09-06 and 2026-09-09, one GETBULK of `sysDescr` per string, with
the other three devices refusing both as the control. Whether the `private`
row is read-write, as it ships on most switches, is not known: the only test
from the monitoring host is a SET, which is a change to the device, so read it
off the row's access column while you are in the UI. Every stale row goes in
the same window. The reboot is the only test there is, and there will not be
another window soon.

**Do this only in a window where the switch can be rebooted**, ideally one it is
already going down for. `neo` carries every VLAN: the reboot stops layer 2, not
just SNMP. This is not a drive-by change at the end of a rotation.

1. **Overwrite the rows, do not delete them.** Web UI at `http://10.7.7.2`,
   **SNMP → Community.** Edit each stale row in place — the *old* community,
   `public`, `private` — and write the **current** community into it, the value
   already in `SNMP_COMMUNITY_MOKERLINK`. Note the access column of the
   `private` row before you overwrite it; if it is read-write, that is the
   worst of the three and the one to do first. If the firmware accepts the
   duplicates, the switch ends up answering exactly one string, nothing in this
   repository changes, and there is no `make render` or `make reload` to do.

2. **If it rejects a duplicate entry**, write a fresh value instead — one per
   row, because a table that refuses one duplicate will refuse the next:

   ```bash
   make gen-secret
   ```

   Plain, not `ARGS=--snmp`: that variant prints one `SNMP_COMMUNITY_*` line per
   device, ready to paste into `make secrets-edit`, which is the opposite of what
   this value is. You want one bare 24-character string, and it does not go into
   SOPS.

   Understand what that leaves you with: extra live communities on the switch
   that are not in SOPS and are not polled by anything — one per row you had to
   do this way, and if the `private` row's access could not be changed either,
   one of them read-write. That is a worse record than step 1 and it must be
   written into `SECURITY.md` if you take it. It is still a large improvement,
   because the values it displaces are the shared string that was published to
   a public repository and the two defaults every scanner tries first.

3. **Reboot the switch.** This is the test, not housekeeping. The deletion that
   started all this looked like it had worked until a restart, so an un-rebooted
   result says nothing about what the switch has actually saved.

4. **Check the current community still works**, before checking anything else:

   ```bash
   ./scripts/snmp-verify.sh --device neo
   ```

   This must be `PASS`. If it is not, the overwrite hit the wrong row and `neo`
   is unmonitored — fix that first. It is also the precondition for the next
   step: `--old` reports `SKIP` for a device that failed here, and a `SKIP` would
   tell you nothing. The stock-community line underneath it is the first
   verdict on the reboot: `refuses public private` means the two default rows
   are gone, `STOCK COMMUNITY ACCEPTED` means they came back.

5. **Then** go to [**Prove it**](#prove-it), answering for `neo` and pressing
   Enter through the other three.

If it still reports `STILL ACCEPTED` after a reboot — or the stock line still
says a default answers — the overwrite did not persist either. **Stop — do not
retry.** Each attempt costs another agent outage for a firmware behaviour you
have now tested twice. Leave the switch polling on its current community and
write what the overwrite actually did into `SECURITY.md`, replacing the
"overwrite rather than delete" sentence, which will have been disproved.

#### Prove it

```bash
./scripts/snmp-verify.sh --old
```

It asks for the old community **per device**, without echoing it, and asserts
each one now refuses it. Press Enter to skip a device — the usual case is
checking the one you just rotated, and a single string tested against all four
proves nothing about the three it never belonged to. It refuses to report
success if you skip everything.

Before it asks for anything it has already tried `public` and `private`
against every device that answered its current community. Those are not
secrets, so nothing is typed and nothing is skipped: under `--old` a device
that answers either is a `FAIL`, the same verdict as `STILL ACCEPTED`, because
a rotation that leaves a default row live has not retired anything a scanner
would try.

It requires a terminal and refuses a pipe on purpose — `echo "$old" | ...` would
put the old community into your shell history, which is the leak this tooling
exists to close. Run it yourself; no script or agent can.

`--old` only checks devices that just passed their current-community check.
SNMPv2c has no "wrong community" reply — a device that rejects you simply drops
the packet — so a timeout against an unreachable device is indistinguishable from
a timeout against a device that correctly refused you. Anything else is reported
`SKIP`, never `PASS`: reporting it as success would be the tool agreeing with you
rather than checking you.

A `SKIP` is not a pass deferred, it is an open question. If a device never
answered its current community, you do not know whether it still accepts the old
one — and if the old one leaked, that device is still exposed. Do not record the
rotation as complete while any device is `SKIP`. Fix the current-community check
first; `--old` only becomes meaningful for that device at that point.

Nothing re-runs this afterwards. The weekly `homelab-snmp-verify.timer` runs
plain mode only — `--old` needs a terminal, so a timer cannot drive it. What it
prints here is a point-in-time result and the only evidence you will have, which
is why §3 has you paste it onto the issue.

## 3. Commit

```bash
git add secrets/observability.sops.yaml
git commit -m "chore(secrets): rotate SNMP communities"
```

The diff shows *which* keys changed and nothing about their values — SOPS
encrypts values and leaves keys in plaintext.

Then close the loop, because these files carry the rotation's status and will
otherwise assert it never happened:

- [`SECURITY.md`](../../SECURITY.md) — the "Known exposure" row. This is the
  ledger; correct it here first.
- [`docs/security.md`](../security.md) — the historical-exposure row and the
  SNMPv2c bullets, which `SECURITY.md` points at for detail. Leaving this one
  stale makes the two disagree, which is worse than either being stale alone.
- [`docs/roadmap.md`](../roadmap.md) — the checkbox.

[`secrets/README.md`](../../secrets/README.md) points at `SECURITY.md` rather
than restating the status, and needs no edit. Keep it that way.

Record what `snmp-verify` actually printed — which devices passed, which refused
the old community, which were `SKIP` — on the tracking issue. §2.5's output is
the only evidence the rotation happened, and it lives in a terminal that closes.

## 4. Move a device to SNMPv3

A separate pass from a rotation, one device at a time, and the same rule:
**the device first, then the repository.** The repository can hold a v3 auth
block before the device has a user, and `make render` would then fail on the
two missing keys — loudly, which is the right failure, and also a stack that
cannot be re-rendered until the device is done. Do not merge the repository
half early.

Which devices this applies to is decided, not chosen here
([ADR-0036](../adr/0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md)):
**`shiva` first, then `mjolnir`.** Not `morpheus` — bsnmpd is the only daemon
that serves the pf MIB and pfSense writes no v3 user for it. Not `neo` unless
its UI turns out to have a user page; check that once, at the next login, and
record the answer in `hardware.md` either way.

What the two devices offer, from their vendors' guides for the firmware each
one reported over SNMP on 2026-09-09 — the pages themselves are behind logins
the monitoring host does not have, so the first person through this checks
the field names against the screen and corrects the table if they differ:

| Device | Where | Users | Auth | Priv | Passphrases | Turn v1 off with |
| --- | --- | --- | --- | --- | --- | --- |
| `shiva`, iLO 4 2.82 | **Administration → Management → SNMP Settings** | three | MD5, **SHA** | DES, **AES** | 8–49 characters | *SNMPv1 Request*: Disabled |
| `mjolnir`, AP9641 (NMC3, AOS 2.0.0.6) | **Configuration → Network → SNMPv3** | four profiles | MD5, **SHA** | DES, **AES** | 15–32 ASCII | **Configuration → Network → SNMPv1 → Access**: disabled |

Bold is what to pick. `make gen-secret` at its default 24 characters fits both.

### 4.1 Generate the two passphrases

```bash
make gen-secret ARGS="--count 2"
```

Plain, not `ARGS=--snmp`: that variant prints the keys the inventory
*currently* has, which for a device that has not moved yet is still its
community. Two bare strings — the first is the authentication passphrase, the
second the privacy passphrase. They stay in your scrollback until §4.3.

### 4.2 Create the user on the device — leave the community in place

> **Add, do not replace.** The v2c community is your rollback credential and
> the exporter is still polling with it. Nothing is removed until §4.5.

**HPE iLO** (`shiva`, 10.0.30.10) — **Administration → Management → SNMP
Settings**, and the same warning as §2.1: saving can reset the management
processor and drop your session, so do this with physical access to the
ProLiant. In **SNMPv3 Users**, fill one of the three slots: security name
`prometheus`, authentication protocol **SHA** with the first passphrase,
privacy protocol **AES** with the second. Leave *SNMPv1 Request* enabled for
now. Apply.

**APC Network Management Card** (`mjolnir`, 10.0.99.10) — **Configuration →
Network → SNMPv3**. Under **Access**, enable SNMPv3. Under **User Profiles**,
edit one of the four: user name `prometheus`, authentication **SHA** with the
first passphrase, privacy **AES** with the second, and enable the profile.
Under **Access Control**, give that profile one entry for `10.0.99.20` and
access **Read**. Leave SNMPv1 enabled for now. The card restarts its network
interface on save, per §*Before you start*; the UPS keeps supplying power.

The user name goes in the repository as a literal, so use the one above or be
ready to write what you chose into `generator.yaml`.

### 4.3 Update the repository — device first, then these five files

The auth block in `snmp-exporter/generator.yaml` is where the version is
declared, and every tool reads the device's shape from it. For the iLO:

```yaml
  auth_ilo:
    username: prometheus
    password: ${SNMP_AUTHPASS_ILO}
    priv_password: ${SNMP_PRIVPASS_ILO}
    security_level: authPriv
    auth_protocol: SHA
    priv_protocol: AES
    version: 3
```

Replacing the `community:` line, which must not survive — `make validate`
refuses a v3 block that still carries one. Then:

```bash
make snmp-generate      # copies the block into snmp.yaml; needs make snmp-mibs once
make secrets-edit       # replace SNMP_COMMUNITY_ILO with the two keys:
                        #   SNMP_AUTHPASS_ILO: <first>
                        #   SNMP_PRIVPASS_ILO: <second>
```

Mind the space after the colon, as in §2.2. Then the two plaintext copies of
the key list: the `REQUIRED` array in `scripts/render-config.sh` — the one
community line becomes the two passphrase lines — and
`secrets/observability.example.yaml`, where the two keys replace the one with
`change-me` values. `make validate` cross-checks all five files and refuses
the mixed state where one still names the community.

The device name, address and module in `prometheus/targets/snmp.yaml` do not
change; `auth: auth_ilo` is the same label with a different shape behind it.

### 4.4 Apply and verify

```bash
make render && make reload
./scripts/snmp-verify.sh --device shiva
```

`PASS` with the device's sysDescr, exactly as §2.4 — but this time the check
went over SNMPv3, which the dry run shows as `v3` against the device. A
`FAIL` here is more informative than a v2c one: USM answers a wrong user or
passphrase with a report, so the line says *rejected over SNMPv3: Unknown user
name* or *Authentication failure* rather than a bare timeout. A timeout
against a v3 device means SNMPv3 is not enabled on it, or the same firewall
questions as before.

Then Prometheus: `up{job="snmp",instance="10.0.30.10"}` back to `1` within a
minute. If it is not, `make logs SERVICE=snmp-exporter` — the exporter's
phrase for a bad user or passphrase is `incoming packet is not authentic,
discarding`, measured against the pinned image.

### 4.5 Turn SNMPv1 off, then prove it

Only once §4.4 is green. On the iLO, *SNMPv1 Request* → Disabled; on the
card, **Configuration → Network → SNMPv1 → Access** → disabled. Then:

```bash
./scripts/snmp-verify.sh --old
```

Enter the device's community — the value `SNMP_COMMUNITY_ILO` held — and
press Enter through the others. `--old` always probes over v2c, whatever the
device speaks now, so against a device that has moved this is precisely the
check that v1/v2c access is off. `rejected` is the result you want.
`STILL ACCEPTED over v2c` means the switch did not take, and the move is not
complete until it does.

Then a second `./scripts/snmp-verify.sh --device shiva`, because disabling v1
on the iLO is another save of the SNMP page.

### 4.6 Commit

```bash
git add secrets/observability.sops.yaml stacks/observability/snmp-exporter/ \
        scripts/render-config.sh secrets/observability.example.yaml
git commit -m "feat(snmp): poll shiva over SNMPv3 authPriv (#85)"
```

The diff shows the community key replaced by two passphrase keys and nothing
about any value. Then, as §3: the *SNMPv2c* section of
[`docs/security.md`](../security.md) names which devices have moved, and #85
gets the `snmp-verify` output — including the `--old` line — because that is
the only evidence the v1 path is closed. Record the scrape duration too
(`scrape_duration_seconds{job="snmp",instance="10.0.30.10"}` before and
after): SNMPv3 adds one discovery round trip per scrape, and ADR-0036 says the
cost is measured rather than assumed.

## If something goes wrong

**A device is rotated but the repository is not.** Only that one target is down,
and `SnmpTargetUnreachable` gives you 10 minutes. Go forward — `make secrets-edit`,
fix the one key, `make render && make reload`. Or go back: re-enter the old
community on the device. You still have it, which is the entire reason §2.5 comes
after §2.4.

**The repository is rotated but the device is not.** That target goes `DOWN` on
the next scrape.

```bash
git checkout -- secrets/observability.sops.yaml     # if uncommitted
git revert <sha>                                    # if committed
make render && make reload
```

To read what the value was before, while you still hold the age key:

```bash
git stash                              # if you have uncommitted changes
git checkout HEAD~1 -- secrets/observability.sops.yaml
make secrets-show                      # careful — prints every secret
git checkout HEAD -- secrets/observability.sops.yaml
```

**Two devices are done and the third's UI locks you out.** Stop. The two that are
done are done and monitored, the third is unmonitored, and the fourth is untouched
and still monitored. Do not "finish the job" on the fourth — that adds an
unverified change while one device is already in an unknown state. Restore access
first using the per-device recovery in **Before you start**, then continue. This
is exactly what rotating one device at a time buys you.

**You changed the device but no longer have the new string.** It exists in two
places: the device, and your terminal scrollback. If both are gone, generate a
third one and set it again — `make gen-secret` is cheap and the device does not
care how many times you write it.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| All four `FAIL` | Not the devices — you are not on `10.0.99.0/24`, or sops decrypted a stale file | `ping 10.0.99.1`; re-run `make render` |
| Only `neo` (`10.7.7.2`) fails | `10.7.7.0/24` is a separate segment reached through pfSense; the rule permitting `10.0.99.20 → 10.7.7.2` either does not exist, was reset, or does not cover UDP/161 | `ping 10.7.7.2` and `nc -vz 10.7.7.2 80` from the monitoring host. If both succeed while SNMP times out, the return path is fine and the fault is protocol-specific — check the *protocol and port* on the pfSense rule (**Firewall → Rules**) before you touch the switch. The rule as it should be is in [ADR-0013](../adr/0013-segment-access-as-implemented.md) |
| A device `FAIL`s and you cannot tell whether you broke it | An SNMPv2c timeout looks identical for a wrong community, a filtered path, and a device that never worked | Ask Prometheus before rolling anything back: `max_over_time(up{job="snmp",instance="<ip>"}[30d])`. `1` means it worked before you started, so the rotation is the suspect. `0` means it never worked, the rotation is not the cause, and rolling back will not help |
| One device fails right after you changed it | The UI truncated the community, or you removed the wrong entry | Re-enter it; check the field's max length (the APC NMC truncates at 15 on several firmwares; the card in this lab does not — it is verified at 16) |
| `--old` reports `STILL ACCEPTED` | The device added the new community alongside the old one | Delete the old entry explicitly — some UIs need the row deleted, not blanked. **Not `neo`** — see the next row |
| `--old` reports `STILL ACCEPTED` on `neo`, after a delete | Expected. This firmware does not persist a removal from the community table, and the attempt has cost you the SNMP agent until reboot | Do not delete it again. Overwrite the row instead — [§2.5's MokerLink route](#the-mokerlink-switch-overwrite-the-row), which needs a window in which the switch can be rebooted |
| `--old` reports `SKIP` | The current-community check failed for that device, so a timeout proves nothing | Fix the current check first |
| `rejected over SNMPv3: Unknown user name` | The user in `generator.yaml` does not exist on the device, or SNMPv3 is enabled but the profile is not | Compare the literal `username:` with the device's user list; on the APC card, check the profile is *enabled* and its access-control entry names `10.0.99.20` |
| `rejected over SNMPv3: Authentication failure` | The authentication passphrase, or the protocol, differs from the device | `make secrets-edit`; check SHA on the device. A wrong *privacy* passphrase reads the same way from net-snmp |
| A v3 device times out where a v2c one would say `rejected` | SNMPv3 is not enabled on the device at all — the iLO's SNMP page or the card's **SNMPv3 → Access** — or the same firewall questions as any other timeout | Enable it; then the *Only `neo` fails* row's method for telling a filter from a refusal |
| `--old` reports `STILL ACCEPTED over v2c` on a device moved to v3 | SNMPv1/v2c access is still enabled beside the v3 user, so the community still works | §4.5: switch v1 off on the device, then run `--old` again |
| `error: ... is version 3 with security_level 'authNoPriv'` | A v3 block that authenticates and sends the tables in clear | `authPriv`, per ADR-0036 — the check refuses anything else on purpose |
| `error: ... contains whitespace or '#'` | A community was typed with a space or `#` into SOPS | `make secrets-edit`; regenerate with `make gen-secret` |
| `error: malformed line ... expected 'KEY: value'` | A key was written `KEY:value`, with no space after the colon | `make secrets-edit` |
| Target still `DOWN` a minute after `make reload` | snmp-exporter reloaded from the *old* rendered file | You skipped `make render`. Run `make render && make reload` |
| `unsubstituted placeholders remain` | An `SNMP_*` credential key is missing from the secrets file — after a move to v3, usually the second of the two | `make secrets-edit` |
| `error: snmp-exporter is not running` | The container is stopped or crash-looping | `make ps`, then `make up` |
| `error: snmp-exporter refused the reload` | The rendered `snmp.yaml` does not parse; it is **still serving the old config** | `make snmp-generate` output is bad — inspect it, or `git checkout --` it |
| Target `UP` but every metric missing | The community works; the module does not match the device | `curl -s 'localhost:9116/snmp?target=<ip>&module=<m>&auth=auth_<m>'` |
| iLO unreachable after saving | The management processor reset | Wait 2 minutes, then `hponcfg` from the host OS, or the rack |
| The UPS card stops responding on save | The NMC restarted its NIC | Wait 60s. The UPS is still supplying power |

---

## Also required

Rotating the live credential does not remove the old one from git history.
Follow [`purge-git-history.md`](purge-git-history.md) as well — one without the
other leaves the job half done. That runbook needs the old communities written
into `.purge-secrets.txt`, so do it while you still have them.
