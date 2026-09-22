# Runbook: Shut down on the UPS's signal, and measure the pack once

**Do the steps in order. Each one says what to do, what you should see, and
what to do if you see something else. The reasoning is at the end, under
[Why it is built this way](#why-it-is-built-this-way) — you do not need it to
follow the steps.**

> **Status — 2026-09-21: decided, not built.**
> [ADR-0049](../adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md)
> decides who shuts down on `mjolnir`'s signal and who does not. Nothing below
> has been done. Steps 5 and 6 are what closes
> [#574](https://github.com/Gerrrt/HomeLab/issues/574).
>
> **Corrected 2026-09-22, still not built.** Step 1 named a v2c community that
> [#85](https://github.com/Gerrrt/HomeLab/issues/85) had already retired, and
> step 5 watched for alerts that cannot arrive inside the window it measures.
> Both are fixed below. Nothing here has been run.

## What this does

| Host | What it ends up doing |
| --- | --- |
| `morpheus` | Runs the NUT server, talks to the UPS card, halts **last** |
| `Saruman` | Subscribes, halts its two guests then itself, **first** |
| `smaug` | Subscribes, exports `erebor` and halts, **first** |
| `neo` | Nothing. It loses power with the pack |
| `prometheus`, `oracle` | Nothing. They ride the cut on their own cells |

## Before you start

Tick all six. Steps 1 to 6 assume every one of these is done.

- [ ] **A maintenance window outside anyone's working hours.** Step 5 halts
      `Saruman`, both its guests, `smaug` and `morpheus`. While `morpheus` is
      down the house has no DNS and no DHCP.
- [ ] **Physical or out-of-band access to all three hosts**, because step 5
      leaves them all powered off: the KVM in U6 for `morpheus`, the iLO at
      `10.0.30.10` from a Mac on VLAN 30 for `Saruman`, and the power button
      on the front of `smaug` in the media room.
- [ ] **The UPS card's SNMPv3 passphrases**, rendered on the **main checkout**
      and never in a worktree (the command is below this list). They are
      `SNMP_AUTHPASS_APC` and `SNMP_PRIVPASS_APC` in the rendered file, and
      below they are written `<AUTHPASS>` and `<PRIVPASS>`. Do not paste them
      into a terminal — they go into a browser form only. **There is no
      community for this card:** it moved to SNMPv3 authPriv on 2026-09-21
      ([#85](https://github.com/Gerrrt/HomeLab/issues/85)) and answers none.
      Both keys are named for the auth label `auth_apc` in `generator.yaml`,
      which is where every tool derives them from — not for the device, so
      there is no `SNMP_AUTHPASS_MJOLNIR` to go looking for.
- [ ] **A username and password you invent now** for the two subscribers to
      log in with. Below they are written `<NUTUSER>` and `<NUTPASS>`. Put
      them in Apple Passwords before you start. `upsslave` is a fine username.
- [ ] **The monitoring stack up on `prometheus`.** It stays up on its own cell
      throughout and is how you watch every step.
- [ ] **A browser that can reach three web interfaces**: the UPS card at
      `https://10.0.99.10`, the firewall at `https://10.0.99.1`, and TrueNAS
      at `https://10.0.40.30` (that one from a Hicks workstation).

Rendering the secrets, for the third box above:

```bash
cd /home/robo/code/Gerrrt/HomeLab && make render
```

---

## Step 0 — Raise the card's low-battery threshold

**Do this first.** Everything below has to finish inside the window this sets,
and the factory value is too short. See
[Why step 0 comes first](#why-step-0-comes-first).

### 0.1 Read what it is now

On `prometheus`:

```bash
cd /home/robo/code/Gerrrt/HomeLab && scripts/snmp-walk.sh --device mjolnir 1.3.6.1.4.1.318.1.1.1.5.2 | grep '5\.2\.8\.0'
```

**You should see:**

```text
.1.3.6.1.4.1.318.1.1.1.5.2.8.0 0:0:02:00.00
```

That is 2 minutes. **Write the value down** before you change it, so it can be
put back.

**If you see nothing:** the credential is wrong or the card is not answering.
Stop and fix that first — every later step depends on reaching this card.

### 0.2 Change it at the card

1. Open `https://10.0.99.10` in a browser and log in.
2. Go to **Configuration → UPS → General** (on AOS 2.x; on an older firmware
   it is **UPS → Configuration**).
3. Find the field for **low battery duration**. It is the setting whose value
   is currently **2** and whose units are minutes.
4. Change it to **8**.
5. Apply or Save.

**The label wording varies by firmware.** It is the only setting on that page
measured in minutes and currently reading 2. If two fields could match, come
back and confirm with 0.3 rather than guessing — 0.3 reads the exact object
you need to have changed.

### 0.3 Confirm it took

Re-run the command from 0.1.

**You should see:**

```text
.1.3.6.1.4.1.318.1.1.1.5.2.8.0 0:0:08:00.00
```

**If it still reads `0:0:02:00.00`:** you changed a different field. Go back
to 0.2.

---

## Step 1 — Configure the NUT server on `morpheus`

### 1.1 Open the settings page

Browse to `https://10.0.99.1`, then **Services → UPS**, then the
**UPS Settings** tab.

### 1.2 Fill in General Settings

| Field | What to set it to |
| --- | --- |
| **UPS Type** | `Remote snmp` |
| **UPS Name** | `mjolnir` |
| **Notifcations** / E-Mail | Leave unchecked |

Set **UPS Type** first. The page hides and shows fields based on it, and the
Driver Settings fields in 1.3 only appear once it reads `Remote snmp`.

> The *Notifcations* label is misspelled in the package itself. That is not
> your browser. Leave it alone — this estate alerts through Alertmanager.

### 1.3 Fill in Driver Settings

| Field | What to set it to |
| --- | --- |
| **Remote IP address or hostname** | `10.0.99.10` |
| **Remote port (optional)** | Leave empty |
| **Remote username** | **Leave empty** |
| **Remote password** | **Leave empty** |

**Leave the username and password empty even though the form offers them.**
For the `Remote snmp` type the package ignores both. The credential goes in
the next box instead, and putting it here means the driver never sees it.

If the form offers an **SNMP community** field for this UPS type, leave it
blank. The card answers no community.

In **Extra Arguments to driver (optional)**, type exactly these lines, with
the two passphrases in place of `<AUTHPASS>` and `<PRIVPASS>`:

```text
snmp_version=v3
secLevel=authPriv
secName=prometheus
authProtocol=SHA
privProtocol=AES
authPassword=<AUTHPASS>
privPassword=<PRIVPASS>
mibs=apcc
pollfreq=15
```

`secName` is `prometheus` — the username in `generator.yaml`'s `auth_apc`
block, which is the credential the exporter has already been using against
this card since 2026-09-21. `mibs=apcc` names NUT's PowerNet MIB; `snmp-ups`
autodetects it and the line only makes the choice visible.

### 1.4 Reveal and fill in Advanced settings

Click the **Display Advanced** button at the bottom of Driver Settings. Four
text boxes appear. Fill in three of them and leave one empty.

**Additional configuration lines for upsmon.conf:**

```text
HOSTSYNC 120
FINALDELAY 30
```

**Additional configuration lines for ups.conf:** leave empty.

**Additional configuration lines for upsd.conf:**

```text
LISTEN 10.0.30.1 3493
LISTEN 10.0.40.1 3493
```

**Additional configuration lines for upsd.users**, with your invented username
and password in place of `<NUTUSER>` and `<NUTPASS>`:

```text
[<NUTUSER>]
password=<NUTPASS>
upsmon secondary
```

### 1.5 Save

Click **Save**. The page restarts the service for you.

### 1.6 Check what it wrote

On `prometheus`:

```bash
ssh admin@10.0.99.1 'grep -vE "^\s*#|^\s*$" /usr/local/etc/nut/nut.conf; grep -vE "^\s*#|^\s*$|[Pp]assword" /usr/local/etc/nut/ups.conf /usr/local/etc/nut/upsd.conf /usr/local/etc/nut/upsmon.conf; sockstat -l4 | grep 3493'
```

**You should see**, among other lines:

```text
MODE=netserver
[mjolnir]
driver=snmp-ups
port=10.0.99.10
snmp_version=v3
secLevel=authPriv
secName=prometheus
mibs=apcc
pollfreq=15
LISTEN 127.0.0.1
LISTEN ::1
LISTEN 10.0.30.1 3493
LISTEN 10.0.40.1 3493
HOSTSYNC 120
FINALDELAY 30
```

and three `sockstat` lines showing `upsd` bound to `127.0.0.1:3493`,
`10.0.30.1:3493` and `10.0.40.1:3493`.

The command hides every password line on purpose — `authPassword` and
`privPassword` among them, which is why the pattern matches a capital `P` as
well as a small one. Their absence here is correct and not a problem.

**If `sockstat` shows `*:3493` or `0.0.0.0:3493`:** the `LISTEN` lines did not
take. Go back to 1.4. Do not continue — the listener would be reachable from
every segment.

### 1.7 Check the driver is really talking to the card

```bash
ssh admin@10.0.99.1 'upsc mjolnir@localhost 2>&1 | grep -E "^(ups.status|ups.model|battery.charge|ups.load|battery.runtime.low)"'
```

**You should see:**

```text
ups.status: OL
ups.model: Smart-UPS X 1500
battery.charge: 100
ups.load: 21
battery.runtime.low: 480
```

`battery.runtime.low: 480` is step 0 in seconds. Seeing it here proves both
that step 0 worked and that this driver is reading the same card.

**If you see `Driver not connected`:** one of the v3 values in 1.3 is wrong:
a passphrase, `secName`, or `secLevel`. **There is no version to fall back
to.** The card refuses v1 and v2c, so a lower `snmp_version` makes this worse
rather than better. Check the credential itself from `prometheus`, where the
same passphrases are already in daily use:

```bash
cd /home/robo/code/Gerrrt/HomeLab && scripts/snmp-walk.sh --device mjolnir 1.3.6.1.2.1.33.1.2.4
```

If that returns a value and the driver still will not connect, the fault is in
what the form wrote rather than in the credential — go back to 1.6 and read
the `[mjolnir]` block.

**If you see `Unknown UPS`:** the name in 1.2 is not `mjolnir`.

**If `ups.model` is blank or the driver logs a MIB error:** `mibs=apcc` is
already in the list in 1.3 — check it survived the save, in the readback from
1.6.

---

## Step 2 — Add four firewall rules

Two per interface: a **pass** for the one host that should reach the listener,
and a **block** for everything else on that segment, in that order, both above
the existing *Allow internet* rule.

### 2.1 Add the ImaginationLAN pass

**Firewall → Rules → ImaginationLAN**, then Add.

| Setting | Value |
| --- | --- |
| Action | Pass |
| Interface | ImaginationLAN |
| Protocol | TCP |
| Source | Single host or alias, `10.0.30.110` |
| Destination | Single host or alias, `10.0.30.1` |
| Destination port range | From `3493` to `3493` |
| Description | `Allow NUT from Saruman` |

### 2.2 Add the ImaginationLAN block

Add another rule on the same interface.

| Setting | Value |
| --- | --- |
| Action | Block |
| Interface | ImaginationLAN |
| Protocol | TCP |
| Source | ImaginationLAN net |
| Destination | Single host or alias, `10.0.30.1` |
| Destination port range | From `3493` to `3493` |
| Description | `Block NUT to pfSense` |

### 2.3 Add the same pair on CasaBonita

**Firewall → Rules → CasaBonita**, twice.

| Setting | Pass rule | Block rule |
| --- | --- | --- |
| Action | Pass | Block |
| Protocol | TCP | TCP |
| Source | `10.0.40.30` | CasaBonita net |
| Destination | `10.0.40.1` | `10.0.40.1` |
| Port | `3493` | `3493` |
| Description | `Allow NUT from smaug` | `Block NUT to pfSense` |

### 2.4 Put them in the right order and apply

On each interface, drag the rules so the order reads:

1. the **pass** rule
2. the **block** rule
3. the existing **Allow internet** rule

They belong up with the existing *Block SSH to pfSense* rules, not at the
bottom. Then click **Apply Changes**.

### 2.5 Verify the order from the firewall itself

```bash
ssh admin@10.0.99.1 'pfctl -sr | grep -E "igc0\.(30|40)" | grep -nE "3493|Allow internet"'
```

**You should see**, for each of the two interfaces, three numbered lines in
this order: the `pass` on 3493, the `block` on 3493, then `Allow internet`.

**If a `pass` line prints after its `Allow internet` line:** the rule is below
the catch-all and will never match. Go back to 2.4.

---

## Step 3 — Subscribe `Saruman`

Do this from a Mac on VLAN 30. `prometheus` cannot reach `Saruman`.

### 3.1 Install the client

```bash
sudo apt install nut-client
```

### 3.2 Set the mode

Replace the contents of `/etc/nut/nut.conf` with exactly this one line:

```text
MODE=netclient
```

### 3.3 Write the monitor configuration

Open `/etc/nut/upsmon.conf` in an editor and replace its contents with this,
substituting your username and password:

```text
MONITOR mjolnir@10.0.30.1 1 <NUTUSER> <NUTPASS> secondary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POWERDOWNFLAG /etc/killpower
POLLFREQ 5
POLLFREQALERT 5
DEADTIME 15
```

Type the password into the editor. Do not echo it from a shell.

### 3.4 Fix the permissions and start it

```bash
sudo chown root:nut /etc/nut/upsmon.conf && sudo chmod 640 /etc/nut/upsmon.conf && sudo systemctl enable --now nut-monitor
```

### 3.5 Verify

```bash
upsc mjolnir@10.0.30.1 ups.status
```

**You should see:**

```text
OL
```

**If you see `Connection refused`:** the `LISTEN 10.0.30.1 3493` line from 1.4
is missing, or the pass rule from 2.1 is in the wrong place.

**If you see `Access denied`:** the username or password does not match what
you put in 1.4. Check `journalctl -u nut-monitor` — a wrong credential logs
*Login on UPS [mjolnir@10.0.30.1] failed*.

### 3.6 Read the guest shutdown policy

In the Proxmox web interface, **Datacenter → Options → HA Settings** and each
guest's **Options → Start/Shutdown order**. Note the shutdown timeout.

`Saruman` runs two guests, `alexander` (VMID 140) and `phoenix` (VMID 170).
`shutdown -h` stops both before the host goes down. You need to know the
timeout because step 5 measures how long that actually takes, and
`HOSTSYNC 120` from 1.4 has to be larger than the answer.

---

## Step 4 — Subscribe `smaug`

From a Hicks workstation, at `https://10.0.40.30`.

### 4.1 Note the tripwire counter first

On `prometheus`:

```bash
ssh admin@10.0.99.1 'pfctl -vsr | grep -A2 "TRIPWIRE" | grep -E "igc0\.40|Packets"'
```

Write the packet count down. It should be zero, and it should still be zero at
the end of step 5.

### 4.2 Configure the service

**System → Services → UPS**, then the edit (pencil) icon.

| Field | What to set it to |
| --- | --- |
| Identifier | `mjolnir` |
| UPS Mode | `Slave` |
| Remote Host | `10.0.40.1` |
| Remote Port | `3493` |
| Monitor User | `<NUTUSER>` |
| Monitor Password | `<NUTPASS>` |
| Shutdown Mode | `UPS reaches low battery` |
| Shutdown Timer | Leave at its default |
| Power Off UPS | **Unchecked** |
| Start Automatically | Checked |

**Leave Power Off UPS unchecked.** A subscriber must never command the UPS.

If a label differs on this TrueNAS release, match it by meaning: mode is
slave or secondary, the host is the firewall's CasaBonita address, and the
shutdown trigger is low battery rather than a timer.

Save, then start the service.

### 4.3 Verify from the NAS console

At the machine's own console — **not** over SSH, which is a read-only key —
choose **8) Open Linux Shell** and run:

```bash
upsc mjolnir@10.0.40.1 ups.status
```

**You should see:**

```text
OL
```

**If you see `Connection refused`:** check the `LISTEN 10.0.40.1 3493` line
from 1.4 and the pass rule from 2.3.

---

## Step 5 — Prove the shutdown order

This halts everything. Your window must be open and you must be able to power
the three hosts back on by hand.

### 5.1 Start the timing loops

**The timings come from these loops and not from the alert list.** Every alert
that covers these hosts carries a `for:` of five minutes or more and
Prometheus scrapes every sixty seconds, so neither can time a shutdown that
takes about three minutes. 5.3 says what the alerts are still good for.

Both loops print UTC to the second and both use **addresses, never names** —
DNS goes away with `morpheus`.

On `prometheus`, which can reach `smaug` and `morpheus`:

```bash
while :; do
  curl -s -m 2 -o /dev/null http://10.0.40.30:9100/metrics 2>/dev/null && s=up || s='---'
  nc -z -w2 10.0.99.1 22 >/dev/null 2>&1 && m=up || m='---'
  printf '%s smaug=%s morpheus=%s\n' "$(date -u +%H:%M:%S)" "$s" "$m"
  sleep 2
done | tee ~/ups-fsd-timing.log
```

`smaug` is checked with `curl -m` rather than with `nc`, because its exporter
accepts the connection and then never answers when the NAS has a disk fault —
a port check would read healthy while the host was not.

On the Mac on VLAN 30, the one you used for step 3, because **nothing on
VLAN 99 can reach `Saruman`**: the single pass between those segments runs the
other way.

```bash
while :; do
  nc -z -G 2 -w 2 10.0.30.110 22 >/dev/null 2>&1 && r=up || r='---'
  printf '%s saruman=%s\n' "$(date -u +%H:%M:%S)" "$r"
  sleep 2
done | tee ~/ups-fsd-saruman.log
```

macOS `nc` takes the connect timeout as `-G`; its `-w` is the idle timeout and
will not bound a connection to a host that has gone away.

**If no Mac is available**, fall back to how fresh `Saruman`'s pushed metrics
are, read from `prometheus`. Find its job label first:

```bash
curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=group by (job) (up{job=~".*(metrics|alloy).*"})' | python3 -m json.tool | grep '"job"'
```

On 2026-09-22 that returned `Saruman-metrics` and `Saruman-alloy`, capital
`S` as in the hostname. Poll the age of the newest sample from the first:

```bash
while :; do printf '%s saruman_stale=' "$(date -u +%H:%M:%S)"; curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=time() - max(timestamp(up{job="Saruman-metrics"}))' | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "no data")'; sleep 5; done
```

It reads a few tens of seconds while the host is up — 23 s when this was
written — and climbs without bound once the agent stops.

That is worth about sixty seconds of resolution, because the agent scrapes at
sixty. Write down which method you used — §6.5 sets a real threshold off this
number and must not be given a precision the method cannot support.

In a third terminal, watch the alerts. **Not for timing** — for confirming
that the estate noticed:

```bash
watch -n 5 'curl -s http://localhost:9093/api/v2/alerts | python3 -c "import json,sys; [print(a[\"labels\"][\"alertname\"], a[\"labels\"].get(\"instance\",\"\")) for a in json.load(sys.stdin)]"'
```

### 5.2 Note the time, then fire it

Note the wall-clock time to the second, then in another terminal:

```bash
ssh admin@10.0.99.1 'upsmon -c fsd'
```

### 5.3 Read the order and the timings off the logs

Each loop prints a line every two seconds. The moment a column flips to `---`
and stays there is when that host stopped answering.

**The order you should see:**

1. `saruman=---` and `smaug=---`, within a few seconds of each other. Both are
   secondaries and both start halting on the same flag.
2. `morpheus=---` last, once every secondary has disconnected or `HOSTSYNC`
   has elapsed, plus `FINALDELAY`.

**Write down two intervals**, both measured from the time you noted in 5.2:

- **to `Saruman` down** — the number `HOSTSYNC` in 1.4 has to exceed.
- **to `morpheus` down** — the end-to-end time. §6.5 sets the card's
  low-battery threshold from it, and step 7 corrects `HOSTSYNC` to it.

One trap in the `prometheus` log: once `morpheus` is down, that host cannot
reach VLAN 40 at all. A `smaug=---` appearing in the same second as
`morpheus=---` is the route going away, not the NAS halting. `smaug` should
already have gone minutes earlier — if it did not, that is the finding, and
the troubleshooting section says where to look.

**What the alert terminal shows, and when.** None of it is quick enough to
time the sequence, which is the whole reason the loops exist:

| Signal | Host | When it appears | Note |
| --- | --- | --- | --- |
| `InstanceDown` | `smaug` | about 5 minutes after it halts | `for: 5m`, and the only alert inside a short window |
| `SnmpTargetUnreachable` | `morpheus` | about 10 minutes after | `for: 10m`. There is no `SnmpTargetDown` |
| `RemoteWriteJobStale` | `Saruman` | about 20 minutes after | Five minutes of lookback plus `for: 15m`. `InstanceDown` cannot see an agent that pushes, so `Saruman` never appears under it |
| `HypervisorGuestStopped` | `alexander`, `phoenix` | not during this test | `for: 1h`, and `homelab_guest_running` stops arriving the moment `Saruman` halts, so it never matures |
| `UpsOnBattery` | — | must not fire at all | Nothing in step 5 writes to the card |

**The UPS itself stays on.** `UpsOnBattery` firing here would mean something
took real power away, and that is not this test.

### 5.4 Power everything back on, in this order

1. `morpheus`, from the KVM in U6.
2. `Saruman`, from the iLO at `10.0.30.10`.
3. `smaug`, from the button on the front.

`Saruman`'s guests come back by themselves if *Start at boot* is set.

### 5.5 Check nothing leaked

Once every target is up again, re-run the tripwire command from 4.1 and the
rule-order command from 2.5.

**The tripwire count must be unchanged.** If it moved, something on CasaBonita
initiated across a segment boundary and that is a finding — stop and
investigate before step 6.

---

## Step 6 — Measure the pack

Everything running, step 5 passed, every host back up.

### 6.1 Take a baseline

```bash
for m in upsEstimatedChargeRemaining upsEstimatedMinutesRemaining upsOutputPercentLoad upsBatteryVoltage upsSecondsOnBattery; do printf '%-32s ' "$m"; curl -sG http://localhost:9090/api/v1/query --data-urlencode "query=${m}{device=\"mjolnir\"}" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "no data")'; done
```

Write the five numbers down with the time.

### 6.2 Pull the plug

**Unplug the UPS itself from the wall.** Not a host, not the PDU — the UPS.

`UpsOnBattery` should page within a minute. That is correct behaviour.

### 6.3 Read it every two minutes

Re-run the command from 6.1 every two minutes and write down each row.

**Stop when charge reaches 60%, or at twenty minutes, whichever comes first.**
Then plug the UPS back in.

Do not run it down to empty. Step 5 already proved what happens at the bottom,
and a flattened pack needs hours to recover.

### 6.4 Do the arithmetic

If charge fell from 100 to **C** over **M** minutes, the full pack at this
load is about:

```text
M × 100 / (100 − C)  minutes
```

Worked example: 100 → 64 in 18 minutes gives 18 × 100 / 36 = **50 minutes**.

### 6.5 Set the threshold to its final value

You now know two things you did not in step 0: how long the whole shutdown
takes (5.3) and what a minute of pack is worth (6.4).

Set the card's low battery duration, the same field as 0.2, to **the step 5.3
end-to-end time plus half again**, rounded up to the next whole minute.

Worked example: if 5.3 measured 3 minutes 10 seconds, set 5 minutes.

Confirm with the command from 0.3.

---

## Step 7 — Write down what is now true

| File | What to change |
| --- | --- |
| This file's status block | Built on *date*; sequence takes *N*; pack measured at *M* minutes at *L* % load |
| [`hardware.md`](../hardware.md) Rack paragraph | Replace "not measured" with the measured number |
| [`hardware.md`](../hardware.md) Accessories, UPS entry | The low battery duration you set in 6.5, and the factory value it replaced |
| [`security.md`](../security.md) mains-loss row | It no longer says nothing shuts down on the signal |
| [`fit-the-ups-battery.md`](fit-the-ups-battery.md) §5 | Whether the card's runtime series tracked your measurement |
| §1.4 of this file | `HOSTSYNC`, corrected down to the 5.3 measurement plus margin |

Then close [#574](https://github.com/Gerrrt/HomeLab/issues/574).

---

## If something goes wrong

**`upsc` says `Connection refused`.** Either `upsd` is not listening on that
address (check 1.6) or the pass rule is below the block or the catch-all
(check 2.5). Both look identical from the client.

**`upsc` says `Access denied`.** The credential in 1.4 and the one in 3.3 or
4.2 do not match. Not a firewall problem.

**`morpheus` halted before `Saruman` finished.** `HOSTSYNC` is shorter than
the guests take. The two logs from 5.1 are how you know: `morpheus=---`
appears before `saruman=---`. Raise it in 1.4 and re-run step 5.

**`smaug` did not halt.** Look at its system log under
*System → Advanced → System Log*. A slave that never saw the shutdown flag was
never connected; the block counter on CasaBonita from 2.5 says whether the
firewall refused it.

**`UpsOnBattery` did not fire within a minute in 6.2.** The scrape is every 60
seconds and the rule waits 30, so two minutes is the outside limit. Past that,
the card is not reporting the transfer — plug back in and stop.

**A real cut later ended with a host stopping uncleanly anyway.** The sequence
outgrew the window. `SmartDriveUnsafeShutdownsGrowing` is what tells you,
because a clean shutdown does not move that counter. Re-time with step 5 and
raise the threshold in 6.5. Packs weaken with age, so a margin that fitted at
install stops fitting eventually.

---

## Why it is built this way

None of this is needed to follow the steps.

### Why step 0 comes first

The card raises its low-battery signal when it estimates a set number of
minutes remain, and that signal is the starting gun: every subscriber begins
halting there, and all of them have to finish before the pack is actually
empty.

Read on 2026-09-21, `upsAdvConfigLowBatteryRunTime` was **2 minutes**, APC's
factory default, never changed on this card. The timings in 1.4 are 150
seconds before `morpheus` even begins halting, against a 120-second window,
before either guest is counted. Built against the factory value, the hosts
would lose power part-way through the shutdown that exists to prevent exactly
that.

8 minutes in step 0 is chosen to be safely too large rather than right. At 21%
load and about 47 claimed minutes it is roughly a sixth of the pack, spent
buying margin on a sequence nobody has timed. Step 6.5 sets the real value
once both unknowns are measured.

### Why the firewall runs the server

`morpheus` is the only host with an address on every segment, and it sits on
Winterfell natively, so it reaches the card with no firewall rule at all. Its
subscribers reach it without crossing a boundary either. The NUT package was
already installed on it, unconfigured, since 2026-08-20. And a firewall that
halts last is the right order anyway: a hypervisor shutting guests down still
wants DNS and a route while it does it.

### Why the rules narrow rather than open

Read with `pfctl` on 2026-09-20, the *Allow internet* catch-all on both
segments already passes traffic to the gateway's own address on every port
except HTTP, HTTPS and SSH. So both subscribers could already reach 3493 — and
so could every television on CasaBonita. The pass/block pairs in step 2 take
that away from everything except the one host per segment that needs it.

The tripwire checks in 4.1 and 5.5 exist because
[ADR-0016](../adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
requires that nothing on CasaBonita initiates across a boundary. A host talking
to its own gateway is not such a packet, and the unchanged counter is the
proof.

### Why the username and password fields are left empty in 1.3

The pfSense package builds `ups.conf` differently per UPS type. For
`Remote snmp` it writes only the driver name and the address; the *Remote
username* and *Remote password* fields are read for other types and ignored
for this one. Anything the driver needs beyond the address has to arrive
through *Extra Arguments to driver*, which the package appends inside the
`[mjolnir]` section. That is why the v3 credential goes there.

### Why `smaug` is a subscriber at all

It is in the media room, not the rack, and nothing recorded what powered it
until 2026-09-20. It runs from the rack's PDU on a long cord, so it is on the
UPS like everything else on that strip — which makes it the one host holding
irreplaceable data on spinning disks that was going to stop uncleanly every
time the pack ran out.

### What this does not prove

Whether each host powers itself back on when mains returns is a BIOS setting
per host and the card's own behaviour. Step 5 never removes power and step 6
never reaches the bottom of the pack, so neither tests it.

Whether `morpheus` should command the UPS to switch its outlets off at the end
is left open. It would make a real cut end with every host restarting when
mains returns, but it needs a write credential on the card, which nothing in
this estate holds. That is an amendment to ADR-0049, not a line here.
