# Runbook: Shut down on the UPS's signal, and measure the pack once

**One rack visit that halts the rack on purpose, in an order that matters,
and one mains pull that turns the card's estimate into a number.**

> **Status — 2026-09-20: decided, not built.**
> [ADR-0049](../adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md)
> decides who shuts down on `mjolnir`'s signal and who does not; nothing below
> has been done, and the two proofs in §5 and §6 are what closes
> [#574](https://github.com/Gerrrt/HomeLab/issues/574). Every number this
> runbook quotes for the pack is the card's claim.

The pfSense NUT package has been installed on `morpheus` since 2026-08-20 and
has never been configured — `MODE=none`, no `ups.conf`, nothing on 3493. This
runbook configures it as the estate's NUT server, subscribes `Saruman` and
`smaug` to it on their own gateway address, scopes the listener so that only
those two hosts can reach it, proves the sequence with a forced shutdown that
does not touch the pack, and then measures the pack with a real pull.

The order of the sections is the order of the work. §2 before §3 and §4,
because a client configured before the pass is above the block will fail in
a way that looks like a wrong password. §5 before §6, because a mains pull on
a sequence that has not been proved is a hard stop of the rack with extra
steps.

## Before you start

- **A window.** §5 halts `Saruman`, every guest on it, `smaug` and the
  firewall, and §6 pages the urgent receiver for real. `neo` carries every
  VLAN and the firewall is the house's DNS and DHCP, so this is a
  [`schedule-maintenance.md`](schedule-maintenance.md) window outside anyone's
  working hours, not an evening's tinkering.
- **The card's credential.** The driver on `morpheus` needs what the exporter
  has, and since 2026-09-21 that is SNMPv3 authPriv:
  [ADR-0036](../adr/0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md)
  moved the card ([#85](https://github.com/Gerrrt/HomeLab/issues/85)), so the
  driver takes the user `prometheus` with SHA, AES and the
  `SNMP_AUTHPASS_APC` / `SNMP_PRIVPASS_APC` pair — named for the auth label
  `auth_apc` in `generator.yaml`, not for the device, which is where every
  tool derives these names from. There is no v2c community for this card to
  fall back on. It comes out of SOPS with `make render` on the main checkout
  and goes into a browser form, never onto a command line where `ps` can read
  it, and never into this file. **If the card's passphrases are ever rotated
  after this is built, the driver's copy moves in the same visit** — a driver
  left on a stale credential is a shutdown path that fails silently until the
  mains go.
- **One NUT credential for the subscribers**, made up now and kept in the
  operator's password manager: a username and a password that `Saruman` and
  `smaug` will both present. It is a *secondary* credential. What it buys
  anyone who steals it is the pack's status; it cannot set the forced-shutdown
  flag, and the primary's credential is never given to a subscriber.
- **The stack up on `prometheus`**, which stays up on its own cell through
  everything below and is how you watch it.
- **A way to power hosts back on** that does not depend on the network: the
  KVM in U6 for the firewall, the iLO from a Mac on VLAN 30 for `Saruman`, and
  the front button on `smaug` in the media room. §5 ends with all three off.

## 1. `morpheus`: the NUT server

*Services → UPS* on the firewall's web UI. The field names below are the
package's as of `pfSense-pkg-nut 2.8.2_9`; if the UI has moved, the files
that must result are the ones quoted after the table, and those are what
`upsc` in step 1.3 verifies.

| Field | Value | Why |
| --- | --- | --- |
| UPS Name | `mjolnir` | Every client's `MONITOR` line names it |
| UPS Type | *Remote SNMP* | The card speaks SNMP and nothing else this estate reads |
| Remote IP address | `10.0.99.10` | The card, on the segment the firewall is on natively — no rule |
| SNMP community | blank | The card has moved to v3 (ADR-0036, 2026-09-21) and answers no community; the v3 lines go in the advanced box below |
| Additional `ups.conf` lines | `mibs = apcc`, `pollfreq = 15`, and for v3: `snmp_version = v3`, `secLevel = authPriv`, `secName`, `authProtocol = SHA`, `privProtocol = AES`, `authPassword`, `privPassword` | `apcc` is NUT's PowerNet MIB; `snmp-ups` autodetects it and the line just makes the choice visible |
| Additional `upsd.conf` lines | `LISTEN 10.0.30.1 3493` and `LISTEN 10.0.40.1 3493` | The two subscriber segments' gateway addresses, and **nothing else** — not `0.0.0.0`, not the Winterfell address, not the WAN |
| Additional `upsd.users` lines | a `[<secondary user>]` block with `password = <the secondary credential>` and `upsmon secondary` | The one credential both subscribers present |
| Additional `upsmon.conf` lines | `HOSTSYNC 120` and `FINALDELAY 30` | See below |
| Enable | on | |

**`HOSTSYNC` and `FINALDELAY` are the two numbers this runbook chooses.**
When the primary decides to shut down it sets the forced-shutdown flag, then
waits up to `HOSTSYNC` seconds for every secondary to disconnect before it
proceeds, then waits `FINALDELAY` seconds more before halting itself. NUT's
defaults are 15 and 5. Fifteen seconds is not long enough for a Proxmox host
to halt four guests, and a primary that gives up waiting halts the firewall
with the hypervisor still shutting down — which still works, because
`Saruman` needs no route to halt, but it is the wrong order and it is not
what §5 is proving. 120 and 30 are starting values; §5 measures how long
`Saruman` actually takes and this table is corrected to it.

Save, then read back on the firewall over SSH — configuration, not
credentials, so the lines below drop anything that looks like one:

```bash
ssh admin@10.0.99.1 'grep -vE "^\s*#|^\s*$" /usr/local/etc/nut/nut.conf; \
  grep -vE "^\s*#|^\s*$|[Pp]assword|community" /usr/local/etc/nut/ups.conf /usr/local/etc/nut/upsd.conf /usr/local/etc/nut/upsmon.conf; \
  sockstat -l4 | grep 3493'
```

Expected: `MODE=netserver`, a `[mjolnir]` block with `driver = snmp-ups` and
`port = 10.0.99.10`, exactly two `LISTEN` lines, a `MONITOR mjolnir@localhost
1 … primary` line, and `upsd` bound to `10.0.30.1:3493` and `10.0.40.1:3493`
and to nothing else. A `LISTEN 127.0.0.1` line is fine — the primary's own
`upsmon` uses it.

### 1.3 The driver sees the card

```bash
ssh admin@10.0.99.1 'upsc mjolnir@localhost 2>&1 | grep -E "^(ups.status|ups.model|battery.charge|battery.runtime|ups.load|battery.runtime.low|driver.name)"'
```

`ups.status` must read `OL` and `ups.model` the same `Smart-UPS X 1500` the
exporter reports as `upsIdentModel`. Compare `battery.charge`,
`battery.runtime` (seconds) and `ups.load` against Prometheus — same card,
same numbers, or the driver is talking to something else:

```bash
for m in upsEstimatedChargeRemaining upsEstimatedMinutesRemaining upsOutputPercentLoad; do
  printf '%-32s ' "$m"
  curl -sG http://localhost:9090/api/v1/query \
    --data-urlencode "query=${m}{device=\"mjolnir\"}" |
    python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "no data")'
done
```

**Write down `battery.runtime.low`.** That is the card's low-battery
threshold in seconds, the point at which it raises `LB` and every subscriber
starts halting. It is the card's number, not one chosen here, and §6 is what
says whether it is enough. The same value is `upsAdvConfigLowBatteryRunTime`
in PowerNet, under `1.3.6.1.4.1.318.1.1.1.5.2`, if you want it from the wire
with `scripts/snmp-walk.sh --device mjolnir`.

## 2. The two pass/block pairs, above the catch-all

Read with `pfctl -sr` on 2026-09-20: on both `igc0.30` and `igc0.40` the only
blocks to the gateway's own address are HTTP, HTTPS and SSH, and the *Allow
internet* catch-all then passes the segment to `any` — which includes the
gateway's address on that segment. So both subscribers **already reach the
listener**, and so does every television. These rules do not open anything;
they narrow it to the one host per segment that should have it.

On each interface, **two rules, in this order, both above *Allow internet*
and next to the three *Block … to pfSense* rules already there:**

| On interface | Rule | Position | Description |
| --- | --- | --- | --- |
| ImaginationLAN (30) | `pass tcp 10.0.30.110 → 10.0.30.1:3493` | above the block below | `Allow NUT from Saruman` |
| ImaginationLAN (30) | `block tcp ImaginationLAN net → 10.0.30.1:3493` | below the pass, above *Allow internet* | `Block NUT to pfSense` |
| CasaBonita (40) | `pass tcp 10.0.40.30 → 10.0.40.1:3493` | above the block below | `Allow NUT from smaug` |
| CasaBonita (40) | `block tcp CasaBonita net → 10.0.40.1:3493` | below the pass, above *Allow internet* | `Block NUT to pfSense` |

Apply, then verify from `morpheus` rather than from the UI, the way
[`build-the-nas.md`](build-the-nas.md) §0.6 did:

```bash
ssh admin@10.0.99.1 'pfctl -sr | grep -E "igc0\.(30|40)" | grep -nE "3493|Allow internet"'
```

Each interface must print the pass, then the block, then *Allow internet*,
in that order by line number. A pass that prints after *Allow internet* is
the fault ADR-0016 warned about and will never match.

**The strong test is the block's counter, not "the NAS can connect".** The
NAS could connect before these rules existed. After them, `pfctl -vsr` shows
each block's packet counter; it should stay at zero for the NAS and rise the
first time anything else on 40 tries port 3493 — which nothing legitimate
will, so a rising counter on `igc0.40` is a finding about a television.

## 3. `Saruman`: a NUT secondary

From a Mac on VLAN 30 (the monitoring host cannot reach 30 —
[ADR-0033](../adr/0033-keep-the-ilo-on-the-lab-segment.md)):

```bash
sudo apt install nut-client
```

`/etc/nut/nut.conf`:

```text
MODE=netclient
```

`/etc/nut/upsmon.conf` — the credential is the secondary one from *Before
you start*, typed in with an editor and not echoed from the shell:

```text
MONITOR mjolnir@10.0.30.1 1 <secondary user> <password> secondary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POWERDOWNFLAG /etc/killpower
POLLFREQ 5
POLLFREQALERT 5
DEADTIME 15
```

Then:

```bash
sudo chmod 640 /etc/nut/upsmon.conf && sudo chown root:nut /etc/nut/upsmon.conf
sudo systemctl enable --now nut-monitor
upsc mjolnir@10.0.30.1 ups.status
```

`OL`, from the firewall's VLAN 30 address, or the pass in §2 is in the wrong
place. `journalctl -u nut-monitor` should read *Login on UPS
[mjolnir@10.0.30.1] failed* for a wrong credential and nothing for a right
one.

**What `shutdown -h` does to the guests** is Proxmox's business, not NUT's:
`pve-guests.service` stops every running guest on the way down, in the order
and with the per-guest timeout the datacenter's shutdown policy sets. Read
that policy before §5 — a guest with a long timeout is what `HOSTSYNC` in §1
has to cover. The Proxmox host firewall was enabled on 2026-09-20
([#566](https://github.com/Gerrrt/HomeLab/issues/566)) with `policy_in`
accepting and the `local_network` alias narrowed; `policy_in` does not touch
outbound, so this client — an outbound connection to `10.0.30.1` — needs
nothing from it.

## 4. `smaug`: TrueNAS's UPS service in slave mode

From a Hicks workstation, on the UI at `https://10.0.40.30`:

*System → Services → UPS*, configure:

| Field | Value |
| --- | --- |
| Identifier | `mjolnir` |
| UPS Mode | *Slave* |
| Remote Host | `10.0.40.1` |
| Remote Port | `3493` |
| Monitor User | the secondary user |
| Monitor Password | its password |
| Shutdown Mode | *UPS reaches low battery* |
| Shutdown Timer | leave at default — it applies to the other mode |
| Power Off UPS | **off** — a subscriber must never command the UPS |
| Start Automatically | on |

Start the service, then from the TrueNAS shell at the console — not over
SSH, which is `frodo`'s read-only key and nothing else
([ADR-0045](../adr/0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md)):

```bash
upsc mjolnir@10.0.40.1 ups.status
```

`OL`. TrueNAS's own alerting will now also raise a UPS alert when the pack is
low; that is a second place alerts come from, the same residual
[#483](https://github.com/Gerrrt/HomeLab/issues/483) named for SMART, and it
is accepted for the same reason — the host cannot push to Loki, and a
subscriber that halts is more valuable than a single alert path.

**The `igc0.40` tripwire must not have moved.** Read it now, before §5 —
`pfctl -vsr | grep -A1 TRIPWIRE` on the firewall — and again after. The NAS
talking to its own gateway is not a packet the tripwire can see, and the
counter staying at zero is the proof that this runbook kept ADR-0016's
property.

## 5. Prove the sequence without draining the pack

This is the test, and it halts everything. Window open, pages expected,
`prometheus` watching.

On the firewall:

```bash
ssh admin@10.0.99.1 'upsmon -c fsd'
```

That sets the forced-shutdown flag on `mjolnir` as if the card had raised
`LB`. Watch from `prometheus`, on the Alertmanager UI or with:

```bash
watch -n 5 'curl -s http://localhost:9093/api/v2/alerts | python3 -c "import json,sys; [print(a[\"labels\"][\"alertname\"], a[\"labels\"].get(\"instance\",\"\")) for a in json.load(sys.stdin)]"'
```

Expected, in order, with the clock running from the `fsd`:

1. `Saruman`'s guests stop — `HypervisorGuestStopped` for each, then
   `InstanceDown` for `Saruman` itself.
2. `InstanceDown` for `smaug`, at about the same time; `erebor` is exported
   on the way down.
3. The firewall halts after every secondary has disconnected, or after
   `HOSTSYNC` seconds, plus `FINALDELAY` — `SnmpTargetDown` for `morpheus`,
   the blackbox probes for its UI, and then, because DNS is gone, a great deal
   else.
4. `mjolnir` stays on. Nothing in this configuration writes to the card
   (every SNMP path in this repository reads, and the driver's credential is
   the exporter's read-only one), so the UPS keeps its outlets live and
   `UpsOnBattery` never fires — which is the point of proving the sequence
   this way.

**Write down how long step 1 took.** That is the number `HOSTSYNC` in §1 has
to exceed, with margin, and it is corrected there now rather than remembered.

Then power everything back, in this order, by hand: the firewall (KVM),
`Saruman` (iLO), `smaug` (the button). `Saruman`'s guests come back on their
own if their *Start at boot* is set. When the stack shows every target up,
read the tripwire's counter again (§4) and every block's counter (§2).

**Two things this test does not prove, named rather than assumed.** Whether
each host powers back on by itself when mains returns after a real cut is a
BIOS setting per host (*Restore on AC Power Loss* or its equivalent on the
ProDesk, the TS150 and the ProLiant) and the card's own behaviour, and the
`fsd` test never removed power. And whether the primary *should* command the
UPS off at the end — which would make a real cut end with the UPS cycling its
outlets and every host restarting when mains returns — is left open: it
needs a write credential on the card, which nothing in this estate holds, and
it is a decision for an amendment to ADR-0049 rather than a line here.

## 6. Measure the pack, once, with the load on

Everything running, the sequence from §5 proved and every host back up. The
card claims 47 minutes at 21 % load (2026-09-20); this is what replaces the
claim.

1. Baseline, from `prometheus`:

   ```bash
   for m in upsEstimatedChargeRemaining upsEstimatedMinutesRemaining \
            upsOutputPercentLoad upsBatteryVoltage upsSecondsOnBattery; do
     printf '%-32s ' "$m"
     curl -sG http://localhost:9090/api/v1/query \
       --data-urlencode "query=${m}{device=\"mjolnir\"}" |
       python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "no data")'
   done
   ```

2. **Pull the UPS's own plug from the wall.** Not a host's plug, not the
   PDU's — the UPS's. `UpsOnBattery` pages inside a minute; that is the
   system working, and it is the first time in the life of this stack that
   the alert has fired for a cut rather than a self-test.
3. Re-run the loop every two minutes and write the rows down: minutes on
   battery, charge, runtime-remaining, load. **Stop at 60 % charge or
   twenty minutes, whichever comes first**, and plug it back in. `UpsChargeLow`
   fires under 50 % for ten minutes; staying above it is deliberate, and
   running the pack down to `LB` is not this test — §5 already proved what
   happens there, and a pack drained to empty is a pack that needs hours to
   be worth anything again.
4. The number: charge fell from 100 to *C* in *M* minutes, so the full pack
   at this load is about `M × 100 / (100 − C)` minutes. Write it beside the
   card's claim, with the load it was measured at and the date, in three
   places: the paragraph under the Rack table in
   [`hardware.md`](../hardware.md#rack), the *Mains power loss* row in
   [`security.md`](../security.md), and the status block at the top of this
   file. If the card's runtime-remaining series tracked the measured slope,
   say so, and `fit-the-ups-battery.md` §5's warning about that series can
   be softened; if it did not, the warning stands and the measured number is
   the only one to plan on.
5. **Compare it to `battery.runtime.low` from §1.3.** The card raises `LB`
   that many seconds before it thinks the pack is empty, and §5 measured how
   long the sequence takes. If the sequence is longer than the threshold, the
   threshold is raised on the card — a write to the NMC's web UI, the one
   place in this estate that writes to it — and this step is repeated.

## 7. What becomes true afterwards

| File | What changes |
| --- | --- |
| This file | The status block: built on *date*, sequence proved in *N* seconds, pack measured at *M* minutes at *L* % |
| [`hardware.md`](../hardware.md) | The Rack paragraph's "not measured" becomes the measured number |
| [`security.md`](../security.md) | The *Mains power loss* row stops saying nothing shuts down on the signal |
| [ADR-0049](../adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md) | Its "a configuration nobody has tested" line is amended with the dates, per ADR-0001 — a `> [!NOTE]` block, not an edit |
| [`network.md`](../network.md) | The VLAN 30 and VLAN 40 notes gain the pass/block pair each, counted where their other exceptions are counted |
| [`rotate-snmp-community.md`](rotate-snmp-community.md) | Gains the step: the NUT driver's copy of the card's credential moves with the card's |
| [`fit-the-saruman-ssds.md`](fit-the-saruman-ssds.md) | Its reason for withholding the HDD write cache is now answered; whether to enable it is a separate re-reading, not a step here |
| [`fit-the-ups-battery.md`](fit-the-ups-battery.md) | §5's runtime warning, softened or confirmed by step 6.4 |

Then close [#574](https://github.com/Gerrrt/HomeLab/issues/574).

## If something goes wrong

**`upsc` on a subscriber reads *Connection refused*.** The listener is not
bound to that gateway address — check `sockstat` in §1 — or the pass in §2
sits below the block. Both look identical from the client.

**`upsc` reads *Access denied* or the client logs a failed login.** The
credential, or the `upsd.users` block is missing `upsmon secondary`. Not the
firewall.

**The firewall halted before `Saruman` finished.** `HOSTSYNC` is too short
for the guests' shutdown timeouts; raise it in §1 and re-run §5.

**`smaug` did not halt.** TrueNAS's UPS service logs to the system log at
*System → Advanced → System Log*; a slave that never saw `FSD` is a slave that
was not connected, and the block counter on `igc0.40` says whether the
firewall refused it.

**`UpsOnBattery` did not fire in §6 inside a minute.** The scrape is 60 s and
the rule's `for` is 30 s, so two minutes is the outside; past that, the card
is not reporting the transfer, which is a finding about the card and the
pull should be ended.
