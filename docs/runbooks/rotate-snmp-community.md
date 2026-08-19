# Runbook: Rotate the SNMP communities

**Target:** four SNMP devices — pfSense, the APC NMC, the MokerLink switch, HPE iLO
**Time:** ~45 minutes, one device at a time
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
> — but you cannot reconfigure it until you get back in. `docs/network.md` lists
> `10.7.7.0/24` as reaching **Nothing**, so the monitoring host at `10.0.99.20`
> polling `10.7.7.2` depends on a pfSense rule that is not documented anywhere in
> this repository. **If exactly one device fails verification and it is this one,
> suspect that rule before you suspect the community.**

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
secure. Moving to SNMPv3 authPriv is tracked in [`roadmap.md`](../roadmap.md) —
the MokerLink switch not supporting it is the blocker.

## 2. Rotate each device

Work through them in this order — cheapest recovery first, physical access last:
**pfSense → APC → MokerLink → iLO**.

For each device, run the whole of §2.1 to §2.5 before starting the next one.

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

### 2.5 Remove the old community, then prove it is gone

Only once §2.4 is green. Delete the old entry in the device's UI — some UIs
require deleting the row rather than blanking the field — then:

```bash
./scripts/snmp-verify.sh --old
```

It asks for the old community **per device**, without echoing it, and asserts
each one now refuses it. Press Enter to skip a device — the usual case is
checking the one you just rotated, and a single string tested against all four
proves nothing about the three it never belonged to. It refuses to report
success if you skip everything.

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
| Only `neo` (`10.7.7.2`) fails | `10.7.7.0/24` is a separate segment reached through pfSense; the rule permitting `10.0.99.20 → 10.7.7.2` either does not exist, was reset, or does not cover UDP/161 | `ping 10.7.7.2` and `nc -vz 10.7.7.2 80` from the monitoring host. If both succeed while SNMP times out, the return path is fine and the fault is protocol-specific — check the *protocol and port* on the pfSense rule (**Firewall → Rules**) before you touch the switch |
| A device `FAIL`s and you cannot tell whether you broke it | An SNMPv2c timeout looks identical for a wrong community, a filtered path, and a device that never worked | Ask Prometheus before rolling anything back: `max_over_time(up{job="snmp",instance="<ip>"}[30d])`. `1` means it worked before you started, so the rotation is the suspect. `0` means it never worked, the rotation is not the cause, and rolling back will not help |
| One device fails right after you changed it | The UI truncated the community, or you removed the wrong entry | Re-enter it; check the field's max length (the APC NMC truncates at 15 on several firmwares; the card in this lab does not — it is verified at 16) |
| `--old` reports `STILL ACCEPTED` | The device added the new community alongside the old one | Delete the old entry explicitly — some UIs need the row deleted, not blanked |
| `--old` reports `SKIP` | The current-community check failed for that device, so a timeout proves nothing | Fix the current check first |
| `error: ... contains whitespace or '#'` | A community was typed with a space or `#` into SOPS | `make secrets-edit`; regenerate with `make gen-secret` |
| `error: malformed line ... expected 'KEY: value'` | A key was written `KEY:value`, with no space after the colon | `make secrets-edit` |
| Target still `DOWN` a minute after `make reload` | snmp-exporter reloaded from the *old* rendered file | You skipped `make render`. Run `make render && make reload` |
| `unsubstituted placeholders remain` | A `SNMP_COMMUNITY_*` key is missing from the secrets file | `make secrets-edit` |
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
