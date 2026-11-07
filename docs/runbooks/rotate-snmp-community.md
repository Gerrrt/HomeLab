# Runbook: Rotate the SNMP communities

**Target:** four SNMP devices — one on SNMPv2c, pfSense; three on SNMPv3
authPriv, the APC NMC, the switch (`neo`) and HPE iLO
**Time:** ~45 minutes, one device at a time; §4, the move of one device to
SNMPv3, is a separate pass of about 20 minutes
**You will need:** the age key, physical access to the ProLiant for the iLO step,
and a way onto `10.7.7.0/24` that does not depend on the switch you are about to
reconfigure

**Why this is not optional.** A single SNMP community string was committed to
this public repository in plaintext and shared across pfSense, the MokerLink
that was `neo` until 2026-11-05, the APC UPS and the ProLiant's iLO. It is
still in git history. Anyone who cloned the repository at any point has it.

Read-only SNMP sounds mild. On a firewall, read-only means the complete state
table, every interface and the full pf configuration surface. Treat a
community, and a v3 user's passphrases, as credentials.

What a rotation changes depends on the device's version. pfSense has a
**community**. The APC card, the switch and the iLO each have one SNMPv3 user,
`prometheus`, and a rotation changes that user's **two passphrases**, the
authentication one and the privacy one. The steps below say which applies
where; "credential" means whichever the device has.

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

**The switch** (`neo`, 10.7.7.2), a MikroTik CRS326 on RouterOS 7
([ADR-0041](../adr/0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md))
— this is the switch everything runs through.

> Losing its management address does not drop traffic — layer 2 keeps forwarding
> — but you cannot reconfigure it until you get back in. The ways back in are
> WinBox's *Neighbors* tab, which finds the switch by MAC, and the untagged
> cable from `morpheus`'s `igc0` to port 1, which is why the switch LAN was
> kept. The UI is `https://10.7.7.2/` only; plain `http` is off.
>
> The monitoring host at `10.0.99.20` reaches `10.7.7.2` through two pfSense
> rules, both recorded in
> [ADR-0013](../adr/0013-segment-access-as-implemented.md): the outbound
> `10.0.99.20 → 10.7.7.2:161-162/udp` and the switch's return path
> `10.7.7.2 → 10.0.99.20:161-162/udp`. The switch's agent also answers
> `10.0.99.20` and nothing else. Any of the three missing presents the same
> way, as a timeout. **If exactly one device fails verification and it is
> this one, suspect those before you suspect the passphrases** — a wrong
> passphrase on a v3 device is a report, not a timeout (§4.4).

**pfSense** (`morpheus`, 10.0.99.1) — the low-risk one, but check what you are
standing on.

> Confirm the SNMP daemon binds only to the VLAN 99 interface — not WAN, not
> "all" — and that you are not administering the firewall through the interface
> you are editing.

## 1. Generate distinct credentials

```bash
make gen-secret ARGS=--snmp
```

One line per key, keyed by the device list in `prometheus/targets/snmp.yaml`
and the auth blocks in `generator.yaml`: a community for pfSense, and an
authentication and a privacy passphrase for each of the three v3 devices —
seven lines. The whole reason the old arrangement was dangerous is that a
single string unlocked everything. Rotating one device uses only that
device's lines.

The default 24 characters fits every device here: the APC card takes v3
passphrases of 15–32 characters, iLO 4 takes 8–49, and it is what
[`swap-the-switch.md`](swap-the-switch.md) §1.5 generates the switch's pair
with. The generator uses `[A-Za-z0-9]` only — every other
character has a specific way of going wrong quietly somewhere between
`secrets-edit` and the wire.

**Check a device's maximum length before you shorten or lengthen anything.**
When the APC card still had a community, several NMC firmware revisions were
known to cap it at 15 characters and truncate silently; the card in this lab
was verified at 16. From the monitoring host a silent truncation and a correct
credential are indistinguishable — both present as the device refusing you —
so if a device needs a different length, `ARGS="--snmp --length N"`.

SNMPv2c sends pfSense's community in cleartext on every poll. A distinct
community limits the blast radius of a captured packet; it does not make the
protocol secure. The iLO and the UPS card moved to SNMPv3 authPriv under
[ADR-0036](../adr/0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md)
— that is [§4](#4-move-a-device-to-snmpv3), a separate pass — and the switch
has been v3 since the CRS326 replaced the MokerLink on 2026-11-05: it was set
up with a v3 user and no v2c community at all
([ADR-0041](../adr/0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md)).
The firewall alone stays on v2c, for reasons ADR-0036 gives.

## 2. Rotate each device

Work through them in this order — cheapest recovery first, physical access last:
**pfSense → APC → switch → iLO**.

For each device, run the whole of §2.1 to §2.5 before starting the next one.

The MokerLink that was `neo` until 2026-11-05 used to be the exception: its
firmware would not persist a deletion from its community table, so retiring
an old community on it needed a reboot window and could be left for a later
pass. That leftover was [#84](https://github.com/Gerrrt/HomeLab/issues/84),
and the swap to the CRS326 made it moot: the defect left with the hardware. No
device here needs the exception now.

### 2.1 Change the device

**A v2c device: add the new community, do not remove the old one yet.**

> **Add, do not replace.** Until the new community is proven end to end, the old
> one is your rollback credential. Deleting it before you have verified the new
> one is what turns a typo at 2am into a drive to the rack. Some devices append
> rather than replace anyway; §2.5 is where that gets cleaned up.

**pfSense** (`morpheus`, 10.0.99.1) — **Services → SNMP.** Set the read community
string. Confirm the daemon binds only to the VLAN 99 interface.

**A v3 device: change the `prometheus` user's two passphrases in place.** Edit
the existing user; do not add a second one. Each device holds one pair for that
user, so there is no old credential left beside the new one to fall back on —
the rollback is the old pair, which stays in SOPS until §2.2 and in git history
after it. The target is down from the device's save until §2.3 is applied,
which `SnmpTargetUnreachable`'s ten minutes covers if you have both passphrases
to hand before you start. Leave the protocols as they are: **SHA** and **AES**.

**APC Smart-UPS** (`mjolnir`, 10.0.99.10) — Network Management Card web UI,
**Configuration → Network → SNMPv3 → User Profiles**, the `prometheus`
profile: the authentication passphrase, then the privacy passphrase. Its
access-control entry for `10.0.99.20` does not change. The card restarts its
network interface on save, per *Before you start*.

**The switch** (`neo`, 10.7.7.2) — RouterOS keeps v3 users under
`/snmp/community`, with `security=private`; the row named `prometheus` is the
user. From a terminal on the switch — WinBox's *New Terminal*, or SSH — or the
same row in WebFig at `https://10.7.7.2/`:

```text
/snmp community set prometheus authentication-password=<first> encryption-password=<second>
```

Type or paste the two values into the switch's own terminal or UI, nowhere
else: not into a shell on the monitoring host, where they land in history, and
not into an agent session, where they land in a transcript. Then read the row
back with `/snmp community print` — `security` still `private`, the
authentication and encryption protocols still SHA1 and AES, and the address
restriction still `10.0.99.20`. There is no v2c community on the switch to add,
keep or delete, and there should not be one after this either: `public` and
`private` are refused, and §2.4 checks that.

**HPE iLO** (`shiva`, 10.0.30.10) — **Administration → Management → SNMP
Settings → SNMPv3 Users**, the `prometheus` slot: both passphrases. The same
warning as *Before you start*: saving can reset the management processor, so do
it with physical access to the ProLiant.

### 2.2 Update the repository

```bash
make secrets-edit
```

Set the key, or the two keys, for the device you just changed:

```yaml
SNMP_COMMUNITY_PFSENSE: <new>
SNMP_AUTHPASS_APC: <first>
SNMP_PRIVPASS_APC: <second>
SNMP_AUTHPASS_NEO: <first>
SNMP_PRIVPASS_NEO: <second>
SNMP_AUTHPASS_ILO: <first>
SNMP_PRIVPASS_ILO: <second>
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
to. A v3 device is checked over SNMPv3 with its user and passphrases, and the
dry run (`--dry-run`) shows it as `v3`.

The same run then sends every device that passed a short and a long junk
community over GET and over GETBULK, and then the stock `public` and `private`
over GET — to the v3 devices too, because a v3 device that still answers v2c
has a second way in. The junk line is the control that makes the `PASS` above
mean the credential was checked. A junk string answered over either PDU is
`FAIL` in both modes. GETBULK used to be a `WARN`, because the MokerLink that
was `neo` until 2026-11-05 answered GETBULK to any community of sixteen
characters or fewer and no configuration changed that (`SECURITY.md`, #84);
the CRS326 refuses both PDUs, so nothing needs the exception. A device
answering junk over GET has its stock and old-community lines skipped as
meaningless. A stock string answering is `FAIL` in both modes, so the weekly
timer's run fails on it and alerts. It used to be `WARN` in plain mode, from
when a stock row on the MokerLink needed a reboot window to retire; that
exception left with the MokerLink.

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

### 2.5 Retire the old credential, then prove it is gone

Only once §2.4 is green. How you retire it depends on the device's version.

#### A v2c device: delete the row

pfSense. Delete the old entry in the device's UI — some UIs require deleting
the row rather than blanking the field. Then go to [**Prove it**](#prove-it).

#### A v3 device: nothing is left to delete

The APC card, the switch and the iLO. §2.1 changed the one user's passphrases
in place, so the old pair stopped working at that save, and §2.4 passing on
the new pair is the evidence. Check one thing while you are in the UI: the
device shows one `prometheus` user, not two. A second user added in §2.1 by
mistake would still hold the old pair, and nothing from the monitoring host can
tell you so — `snmp-verify.sh` has no old-passphrase check.

On the switch, `/snmp community print` lists every row RouterOS has: one row,
`prometheus`, with `security=private`, and no other. A row with
`security=none` is a v1/v2c community, which this switch is meant not to
have at all
([ADR-0041](../adr/0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md));
the stock-community line in §2.4 catches the two defaults, and only reading the
table catches any other string.

`--old` below still applies to a v3 device in one way: given the community the
device had before it moved, it proves v1/v2c access is off (§4.5). A rotation
of passphrases does not change that, so for a v3 device press Enter.

#### The MokerLink switch: overwrite the row

History, not a procedure; the heading stays because the changelog links it.
The MokerLink that was `neo` until 2026-11-05 accepted a deletion from its
community table, applied and saved it, and still had the row after a restart,
and each attempt dropped its SNMP agent until a reboot. This section was the
route around that: overwrite each stale row with the current community in a
window where the switch could be rebooted, then reboot as the test. It was run
on 2026-09-12, and the residual it left was
[#84](https://github.com/Gerrrt/HomeLab/issues/84). The CRS326 has no v2c
community to overwrite, so the route left with the hardware; git history keeps
the steps.

#### Prove it

```bash
./scripts/snmp-verify.sh --old
```

It asks for the old community **per device**, without echoing it, and asserts
each one now refuses it. Press Enter to skip a device — the usual case is
checking the one you just rotated, and a single string tested against all four
proves nothing about the three it never belonged to. It refuses to report
success if you skip everything.

Before it asks for anything it has already tried a short and a long junk
string, and then `public` and `private`, against every device that answered
its current community — all over GET, which is the PDU every device here
checks. Those are not secrets, so nothing is typed and nothing is skipped:
under `--old` a device that answers a stock string is a `FAIL`, the same
verdict as `STILL ACCEPTED`, because a rotation that leaves a default row
live has not retired anything a scanner would try. A junk string answered
over GETBULK is a `FAIL` here as well; it was a `WARN` only while the
MokerLink that was `neo` until 2026-11-05 answered every short string over
that PDU regardless of its table.

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
- [`docs/roadmap.md`](../roadmap.md) — the entry leaves, and the rotation
  goes to [`docs/changelog.md`](../changelog.md) under the date.

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
**`shiva` first, then `mjolnir`** — both done, on 2026-09-20 and 2026-09-21.
Not `morpheus` — bsnmpd is the only daemon that serves the pf MIB and pfSense
writes no v3 user for it. `neo` never needed this section: the MokerLink that
was `neo` until 2026-11-05 stayed on v2c, its UI never checked for a v3 user
page because #444 was going to replace it, and the CRS326 that replaced
it was set up at the bench with a v3 user and **no** v2c community before it
was ever racked
([ADR-0041](../adr/0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md),
[`swap-the-switch.md`](swap-the-switch.md) §1.5), so there was no community to
leave in place or to switch off afterwards. If the switch is ever reset, its
user is re-created by that section, and its passphrases are rotated by §2.

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
    community: ""
    username: prometheus
    password: ${SNMP_AUTHPASS_ILO}
    priv_password: ${SNMP_PRIVPASS_ILO}
    security_level: authPriv
    auth_protocol: SHA
    priv_protocol: AES
    version: 3
```

The `community:` placeholder must not survive — `make validate` refuses a v3
block that still carries one — but the line itself stays, as an explicit
empty string. The generator fills every unset auth field from its defaults,
and its default community is `public`: a v3 block with no community line at
all comes out of `make snmp-generate` as `community: public` beside the
user, which is the string the gitleaks community rule exists to catch, and
`make validate` goes red on the generated `snmp.yaml`. Found on the first
move, 2026-09-20. The empty string is dropped from the output. Then:

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
card, **Configuration → Network → SNMPv1 → Access** → disabled.

> **Anything else holding this device's community has to move first.** A
> second consumer left on v2c is what keeps v2c enabled, and switching it off
> underneath one breaks that consumer rather than the exporter — which is the
> failure this repository is worst at noticing, because the exporter stays
> green. For `mjolnir` that consumer is the NUT driver the
> shutdown-on-the-UPS decision puts on `morpheus`; on 2026-09-21, when the
> card moved, it did not exist yet — the package is installed and
> unconfigured — so there was nothing to move.
> [`shut-down-on-the-ups.md`](shut-down-on-the-ups.md) builds it with the v3
> pair from the start. Check for a consumer before this step, not after.

Then:

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
fix the key or the pair, `make render && make reload`. Or go back: re-enter the
old community or passphrases on the device. You still have them — a v2c
device's old row is still there, which is the entire reason §2.5 comes after
§2.4, and a v3 device's old pair is still in SOPS until you save §2.2.

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
| Only `neo` (`10.7.7.2`) times out | `10.7.7.0/24` is a separate segment reached through pfSense; the rule permitting `10.0.99.20 → 10.7.7.2` either does not exist, was reset, or does not cover UDP/161 — or the switch's agent is off, or no longer restricted to `10.0.99.20` but to some other address | SNMP is the only thing the firewall passes from the monitoring host to the switch LAN, so there is no second protocol to compare against from here. From a Hicks workstation, `https://10.7.7.2/` proves the switch is up; in its terminal, `/snmp print` and `/snmp community print` show the agent enabled and the `prometheus` row's address restriction. Then check the *protocol and port* on the pfSense rule (**Firewall → Rules**). The rules as they should be are in [ADR-0013](../adr/0013-segment-access-as-implemented.md). A wrong passphrase is never a timeout on this device: it is a v3 report, the next rows down |
| A device `FAIL`s and you cannot tell whether you broke it | An SNMPv2c timeout looks identical for a wrong community, a filtered path, and a device that never worked | Ask Prometheus before rolling anything back: `max_over_time(up{job="snmp",instance="<ip>"}[30d])`. `1` means it worked before you started, so the rotation is the suspect. `0` means it never worked, the rotation is not the cause, and rolling back will not help |
| One device fails right after you changed it | The UI truncated the community or a passphrase, or you removed the wrong entry | Re-enter it; check the field's max length (§1 has each device's range; the APC NMC truncated communities at 15 on several firmwares, though the card in this lab was verified at 16) |
| `--old` reports `STILL ACCEPTED` | The device added the new community alongside the old one | Delete the old entry explicitly — some UIs need the row deleted, not blanked |
| `--old` reports `SKIP` | The current-community check failed for that device, so a timeout proves nothing | Fix the current check first |
| `rejected over SNMPv3: Unknown user name` | The user in `generator.yaml` does not exist on the device, or SNMPv3 is enabled but the profile is not | Compare the literal `username:` with the device's user list; on the APC card, check the profile is *enabled* and its access-control entry names `10.0.99.20`; on the switch, `/snmp community print` shows a `prometheus` row with `security=private` |
| `rejected over SNMPv3: Authentication failure` | The authentication passphrase, or the protocol, differs from the device | `make secrets-edit`; check SHA on the device (`SHA1` on the switch). A wrong *privacy* passphrase reads the same way from net-snmp |
| A v3 device times out where a v2c one would say `rejected` | SNMPv3 is not enabled on the device at all — the iLO's SNMP page, the card's **SNMPv3 → Access**, or the switch's agent (`/snmp print`) — or the same firewall questions as any other timeout | Enable it; for the switch, the *Only `neo` times out* row |
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
