# Runbook: Move the estate into the 32U rack

**Target:** everything in the 9U rack, plus `trinity`, `prometheus` and
`oracle` from the shelf beside it, `smaug` from the media room, the KVM
console, `ifrit` (new), and the CRS326 that replaces `neo` — into the
four-post 32U frame planned in
[`hardware.md`](../hardware.md#planned-a-32u-rack)
**Time:** two or three evenings at the bench beforehand, then one window of
about four hours with the house offline, then an hour on the documents
**You will need:** a second person for the UPS and the DL360, a Mac on Hicks,
the age key on the monitoring host, a cage-nut tool or a flat screwdriver, a
Phillips #2, an anti-static wrist strap, a tape measure, labels, velcro ties,
and every part on the shopping list in [§0.1](#01-the-parts)

> **Status — 2026-10-06: written, not run.** Nothing below has been done. The
> frame and most parts are not bought yet. `ifrit` was bought on 2026-10-05
> and has not arrived ([#421](https://github.com/Gerrrt/HomeLab/issues/421)).
> The move is tracked in [#919](https://github.com/Gerrrt/HomeLab/issues/919).
>
> **2026-10-09:** the frame is bought, at 32U rather than the 27U this was
> written for, and is due 2026-10-16. Only the height changed. The layout
> keeps every unit where it was, and U28–U32 are spare above the screen.
>
> **2026-10-12:** the frame was built on 2026-10-11 and is set to 29" post
> to post (§1.1). The layout is redone: the console at the top (U23–U32),
> `smaug` racked on its side at U5–U9, and three single-unit gaps between
> hosts. Every unit number below is the new layout's. The CRS326 is already
> racked at U21, unpowered and uncabled.

**Do the sections in order. Each step says what to do, what you should see,
and what to do if you see something else.** The reasoning is at the end,
under [Why it is built this way](#why-it-is-built-this-way).

**The window takes the whole house offline.** It is the same window as
[`swap-the-switch.md`](swap-the-switch.md)'s Phase 2, which that runbook says
to share with another rack visit rather than giving it its own. There is no
internet, no Wi-Fi, no DNS, no DHCP and no televisions from §4 to §7. Book it
outside working hours, and tell the household when it starts and roughly when
it ends.

---

## Read this part first

**Four ways this goes wrong, and none of them is the heavy lifting.**

1. **Closing `prometheus`'s lid suspends the monitoring host.** Both laptops
   run logind's default, which suspends on lid close (checked 2026-10-06).
   On a 1U shelf they lie flat with the lid shut. §1.4 changes this, and it
   must be done and proven days before the window, not on the day.
2. **NUT is armed.** The UPS shutdown sequence
   ([ADR-0049](../adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md),
   [`shut-down-on-the-ups.md`](shut-down-on-the-ups.md)) is built and live. A
   mains blip while hosts are half-moved can start it. Shut the subscribers
   down yourself, in §4's order, before the UPS is touched.
3. **`smaug` moves into the rack in the window.** Today it is a tower in
   the media room on a long cord from the rack's PDU, so moving the PDU cuts
   it anyway. It is shut down cleanly in §4, carried in at §5, and racked on
   its side at U5–U9. Its long cord is retired.
4. **The switch runbook says U9; this one says U21.** The CRS326 was racked
   at U21 on 2026-10-12. Follow [`swap-the-switch.md`](swap-the-switch.md)
   Phase 2 for everything except racking it, which is already done. Its
   Phase 1 bench work still needs it powered: run an extension lead to it
   in the frame, since the frame's PDU is not live until the window.

---

## 0. Before you start

### 0.1 The parts

Every part below must be in the house before the window is booked. The
ones not yet on hand are also in the roadmap's
[*Everything still to buy*](../roadmap.md#everything-still-to-buy).

| Part | Qty | For |
| --- | --- | --- |
| 32U four-post open frame, adjustable depth to at least 30" | 1 | The frame. Bought 2026-10-09, built 2026-10-11 at 29" |
| VESA 100 × 100 rack mount for a 17–19" screen (sold as 4U) | 1 | The ViewSonic N1700W, U25–U32. On hand, 2026-10-13 |
| 1U sliding keyboard drawer, front-rail mount | 1 | U24. On hand and mounted, 2026-10-15 |
| 1U mount for a Lenovo ThinkCentre Tiny, holding its power brick | 1 | `ifrit`, U18. On hand and mounted, 2026-10-15 |
| 1U ProDesk Mini tray (the same one as `morpheus`'s) | 1 | `trinity`, U16. On hand, 2026-10-13 |
| 1U vented four-post shelf, square-hole, adjustable to 29" | 3 | `prometheus` U10, `oracle` U12 and the KVM at U23, whose own ears are half-height ([`hardware.md`](../hardware.md#planned-a-32u-rack)) |
| Four-post shelf, adjustable to 29", at least 17" deep, rated for 50 lb or more | 1 | `smaug` on its side, U5–U9 (about 20 lb) |
| 1U horizontal cable manager | 1 | U20 |
| 1U vented blank | 1 | U22, the air gap over the CRS326 |
| Adjustable 1U four-post support rails, a pair, spanning 29" | 2 | The keyboard drawer at U24 and `ifrit`'s Tiny tray at U18: both front-mounted, both wobble with every ear screw tight |
| 2 × 16 GB DDR4 SO-DIMM (DDR4-2933 or faster) | 1 kit | `ifrit` |
| 1 TB NVMe, M.2 2280 | 1 | `ifrit`, replacing its 256 GB drive |
| Factory-made Cat6 patch cables, short | a pack | Every switch-to-panel run. The XB7-to-`morpheus` cable is [#923](https://github.com/Gerrrt/HomeLab/issues/923)'s, fitted before the window rather than in it |
| Spare M6 cage nuts and screws | 1 pack | Frames never ship with enough |
| 16 GB DDR4 RDIMM, dual-rank, matched to a fitted stick's label | 8 | `Saruman`, to 256 GB: fitted in §6 while it is out of the rack ([`hardware.md`](../hardware.md#compute)) |

The current shelf for the TP-Link, `morpheus`'s tray, the KVM, the PDU, the
patch panel, the UPS's rack mount, the DL360's rails and the CRS326 all move
over.

### 0.2 Checklist

- [ ] Every part in §0.1 is here, and the frame is unboxed and complete.
- [ ] [`swap-the-switch.md`](swap-the-switch.md) Phase 1 is finished at the
      bench: the MokerLink's config and **full port map are captured**, and
      the CRS326 is configured, certified and tested. The repository has no
      port map of its own, so that capture is the only record of what plugs
      where.
- [ ] §1 is done: `ifrit` has its RAM and SSD, the monitor is off its stand,
      the frame is built, and the laptops ignore their lids.
- [ ] A fresh volume backup exists: `make backup` on `prometheus`, then
      `make verify-backups`. The window powers everything off. Nothing should
      be lost, but this is when you find out.
- [ ] The household knows the window's start and end, and Mekenna is not
      working.

---

## 1. At the bench, on the days before

None of this takes anything offline.

### 1.1 Measure the old rack's depth

Measure from the outside face of the front posts to the outside face of the
rear posts on the 9U frame. Write it down. The DL360's rails and the TP-Link's
shelf already fit that spacing, so setting the new frame to the same depth
means both carry over unchanged.

**Measured 2026-10-12: 29".** The DL360's rails and the TP-Link's shelf fit
it already. Any shelf bought new must fit a 29"-deep rack, which its listing
states. When mounting, each one bolts to front and rear posts without
forcing; if one will not reach, see the recovery table.

### 1.2 Build the frame

1. Assemble it per its manual, with the posts set to §1.1's depth. Every post
   must be at the same depth, or the rails bind: measure top and bottom on
   both sides, and get all four within about 1/8" before tightening.
2. Put it where it will live. Leave room to stand behind it, and keep the
   back at least 30 cm from a wall: the DL360 exhausts hot air backwards.
3. **Lock the casters, or lower the levelling feet, before anything heavy
   goes in.** A loaded frame on free casters can roll when a server slides
   out.
4. Mark U1, U5, U10, U15, U20, U25 and U30 on a front post with tape. Counting
   holes in the dark is how a device ends up straddling two units.

**Built 2026-10-11, at 29".** It wobbled at first; the cause was screws not
yet tightened, and tightening them fixed it. If it still sways once loaded,
anchor it to the wall: the DL360 slides out on its rails and moves the weight
forward.

**One unit is three holes.** Every device sits within its own three, aligned
to the unit boundary marks on the post. Cage nuts go in from the inside of
the post, hooked edge first, and are squeezed in with the tool, not your
thumb.

### 1.3 Fit `ifrit`'s RAM and SSD

The M80q (first generation) takes **DDR4-2666/2933 SO-DIMMs, two slots,
64 GB maximum**, and has **one M.2 2280 SSD slot** (PCIe 3.0 x4). The other
M.2 slot is for Wi-Fi. This is from Lenovo's PSREF spec sheet. So the 1 TB
drive **replaces** the 256 GB one; there is nowhere to fit both.

1. Unplug the power brick, then hold the power button for five seconds to
   drain it.
2. Wear the wrist strap, clipped to bare metal on the chassis, and work on a
   hard surface, not carpet.
3. Open the case as the **ThinkCentre M80q Hardware Maintenance Manual**
   describes (on `support.lenovo.com`, under the model). Tiny chassis vary by
   generation, so follow the manual, not a video of a different model.
4. Take out both 8 GB SO-DIMMs and fit the two 16 GB ones. Each goes in at
   an angle until its gold edge is fully seated, then presses down until both
   clips click.
5. Take out the 256 GB SSD, fit the 1 TB one, and fasten it with the same
   screw. **Keep the 256 GB drive with the machine's spare parts.** It holds
   whatever the refurbisher installed.
6. Close the case, power on, and enter the BIOS (F1 on ThinkCentres).

**You should see** 32768 MB (or 32 GB) of memory and the 1 TB NVMe drive.

**If you see 16 GB:** one module is not seated. Power off, unplug, and reseat
it. **If you see no drive:** the SSD is not fully seated in its slot, or its
screw is holding it at an angle.

Leave the operating system to
[`build-the-playground.md`](build-the-playground.md) §1, after the move.

### 1.4 Make both laptops ignore their lids

On `prometheus` and on `oracle`:

```bash
sudo mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' \
  | sudo tee /etc/systemd/logind.conf.d/10-lid-ignore.conf
sudo systemctl restart systemd-logind
```

**Then prove it, one laptop at a time.** Close its lid for ten minutes, then
check from the other one:

```bash
curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=up{instance=~".*(prometheus|oracle).*"}'
```

**You should see** `1` for the host whose lid is closed, and no gap in its
series. **If you see a gap,** it suspended: open the lid, and confirm that
`systemd-analyze cat-config systemd/logind.conf` shows the three lines.

### 1.5 Take the monitor off its stand

1. Lay the N1700W face down on a towel.
2. Remove the four screws holding the stand, then the four rubber plugs
   under them. **The VESA 100 × 100 holes are underneath** (from its manual).
3. **The bare panel's height: measured 2026-10-12, 13" (about 330 mm).**
   That fits the 8U (355.6 mm) reserved for it at U25–U32, so nothing
   below it moves. With the stand off, check that the VESA holes sit near
   the panel's vertical centre: the top edge must not rise above U32.
4. Fit the rack mount's bracket to the VESA holes. Do not rack it yet.

### 1.6 Label everything

Label **both ends** of every cable that will be unplugged in the window.
Use the host name, and the switch port from the captured port map. Patch
leads keep their VLAN colour per
[ADR-0009](../adr/0009-colour-vlans-by-cable-not-by-trust.md): red 99, orange 50,
yellow 40, green 30, blue 20, purple 10. Ten minutes here saves an hour of
tracing in §6.

### 1.7 Count the outlets

The PDU has ten outlets. Write down what will plug into it:

| Device | Outlets |
| --- | --- |
| `morpheus` (brick) | 1 |
| `trinity` (brick) | 1 |
| `ifrit` (brick) | 1 |
| DL360 (one per power supply fitted) | 1–2 |
| KVM | 1 |
| CRS326 (DC adapter) | 1 |
| N1700W (12 V brick) | 1 |
| `smaug` (racked at U5–U9; the long cord is retired) | 1 |
| Both laptops' chargers | 0: on the UPS's own outlets, beside the TP-Link |

That is **8–9 of 10**, by the outlet map in
[`hardware.md`](../hardware.md#console-and-power-maps). The laptops'
chargers go on the UPS's own outlets in either case: with two DL360
supplies the PDU would be at eleven, and the laptops carry their own
batteries, so they need its outlets least. Do not daisy-chain a power strip
off the PDU.

---

## 2. Silence the estate

**On `prometheus`, at the start of the window.** The shutdowns below would
otherwise page `urgent` once for every host, and the DNS and gateway rules
pile in once `morpheus` goes.

```bash
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u -d '+6 hours' +%Y-%m-%dT%H:%M:%SZ)
```

```bash
curl -sS -X POST http://localhost:9093/api/v2/silences -H 'Content-Type: application/json' --data "$(printf '{"matchers":[{"name":"alertname","value":"Watchdog","isRegex":false,"isEqual":false}],"startsAt":"%s","endsAt":"%s","createdBy":"#919 move into the 32U rack","comment":"#919 Planned whole-estate outage for the rack move and #444 Phase 2. Everything except Watchdog is suppressed. Delete at 7.1, not on expiry."}' "$START" "$END")" | python3 -m json.tool
```

**Record the UUID it returns.** §7.1 deletes it.

- **Unlike the UPS runbook's silence, this one does not exempt
  `category=power`.** The UPS itself is switched off and moved, so its alerts
  are expected and would page for nothing.
- **`Watchdog` is still excluded,** so the dead man's switch keeps arriving
  for as long as there is internet. The comment begins `#919` because
  `SilenceWithoutIssue` fires on one that does not.

**Pause the external heartbeat check.** Once `morpheus` goes down, no
heartbeat leaves the house. The external check would then report the
monitoring path dead, which is true and expected. Pause it in the
healthchecks.io dashboard now, and resume it in §7.1.

---

## 3. Stop what writes on its own

On `prometheus`, pause the converge timer, so a merge during the window
cannot start a deploy against a half-moved estate:

```bash
echo 'HOMELAB_CONVERGE_APPLY=0' | sudo tee -a /etc/default/homelab-timers
```

§7.3 removes that line. `DeployApplyDisabled` is an info alert after six
hours, so it will not fire inside a normal window.

---

## 4. Shut down, in this order

**Use addresses, not names, from here on.** DNS goes with `morpheus`.

| Order | Host | How | You should see |
| --- | --- | --- | --- |
| 1 | `Saruman` and its guests | The Proxmox UI at `https://10.0.30.110:8006` from the Mac on Hicks (`10.0.30.20` once [`build-the-playground.md`](build-the-playground.md) §3 has run), *node → Shutdown*. It stops its guests first | The iLO at `10.0.30.10` shows the server off |
| 2 | `smaug` | The TrueNAS UI, *Power → Shut Down* | The tower's power light goes out. `erebor` is exported on the way down |
| 3 | `trinity` | `ssh rabbit@10.0.99.40 sudo systemctl poweroff` | The ProDesk's light goes out. **AdGuard goes with it**: from here, the house cannot resolve outside names |
| 4 | `morpheus` | The pfSense console on the KVM, option *Halt system* | The house loses internet, DNS and DHCP |
| 5 | The MokerLink `neo` | Unplug its power | |
| 6 | The UPS `mjolnir` | Its front panel: off, then unplug it from the wall | Every outlet on it is dead |

**`prometheus` and `oracle` stay running on their own batteries** through the
move. They are the last things moved and the first back on the network.

**If `Saruman` will not shut down** within five minutes, a guest is hanging
on to it. Shut that guest down from its own console first. Do not hold the
power button on a hypervisor with running guests.

---

## 5. Unload the old rack, top down

**Two people for the UPS and the DL360.** The UPS is the heaviest thing in
the house that is not furniture. **Take its battery pack out first**, as in
[`fit-the-ups-battery.md`](fit-the-ups-battery.md), and move the two parts
separately.

1. Unplug every cable from each device as you reach it. They are labelled
   (§1.6).
2. Unload top down: MokerLink (U9), patch panel (U8), PDU (U7), KVM (U6),
   `morpheus` on its tray (U5), the TP-Link shelf (U4), the DL360 off its
   rails (U3), then the UPS (U1–U2).
3. The DL360: pull it out until the rails lock, press the release tabs on
   both sides, and lift it clear with one person on each side. Then remove
   the rails from the old posts.
4. Lay everything on a clear floor, in the order it goes back in.
5. **Bring `smaug` from the media room.** Unplug its network lead and its
   long cord, and carry it upright with its drives in; it weighs about
   20 lb. Retire the long cord. If its feet come off, take them off now: it
   lies on its side in the rack.

The MokerLink stays cabled and powerable on the bench until
[`swap-the-switch.md`](swap-the-switch.md) Phase 3 passes. That is the
switch runbook's rollback.

---

## 6. Load the new rack, bottom up

**Heaviest at the bottom, every time.** Mount each device in its marked
units (§1.2), then the next one up.

| Order | U | Device | Notes |
| --- | --- | --- | --- |
| 1 | U1–U2 | UPS, on its rack mount | Battery pack back in once it is seated. Do not plug it into the wall yet |
| 2 | U3 | DL360 | **First, on the floor, its eight new RDIMMs**: lid off, wrist strap on, one more per channel in the slots the lid's diagram marks for each CPU's second DIMM per channel. Then rails, at U3 on all four posts, and slide the server in until it clicks |
| 3 | U4 | PDU | Its plug goes to the UPS |
| 4 | U5–U9 | `smaug` on its side, on its four-post shelf | The shelf at U5, then the tower on it, on a side with no vents. About 1.5" stays clear above it |
| 5 | U10 | Shelf with `prometheus`, flat, lid closed | Only after §1.4 is proven |
| 6 | U12 | Shelf with `oracle`, flat, lid closed | Only after §1.4 is proven. U11 stays empty |
| 7 | U14 | The TP-Link on its shelf | It feeds the two laptops below it. U13 stays empty |
| 8 | U15 | `morpheus` on its tray | |
| 9 | U16 | `trinity` on the new ProDesk tray | Its USB photo disk too: see §6.1 |
| 10 | U18 | `ifrit` on its Tiny mount, with its brick | U17 stays empty. **Rails first:** a pair of four-post support rails in U18, then the tray's rear fastened to them (§6.1) |
| 11 | U19 | Patch panel | |
| 12 | U20 | Cable manager | |
| 13 | U21 | CRS326 | Already racked on 2026-10-12. [`swap-the-switch.md`](swap-the-switch.md) Phase 2, step 2 is done; carry on from step 3 |
| 14 | U22 | Vented blank | The air gap over the passive switch |
| 15 | U23 | KVM, on its vented shelf | Its half-height ears take two of a unit's three holes; the shelf takes all three |
| 16 | U24 | Keyboard drawer | Front rails only, plus a pair of four-post support rails in U24 under it; the drawer's slider rears are fastened to them before the screen goes on above (§6.1) |
| 17 | U25–U32 | N1700W on its VESA mount | The bracket bolts to 4U. The screen in front of it covers 8U |

### 6.1 Cable it

- **Data on one side, power on the other.** Run patch leads through the cable
  manager on the left and power cords down the rear right, or the reverse,
  but never bundled together.
- **Every patch lead is factory-made.** A hand-crimped plug in the XB7 was
  the fault [#914](https://github.com/Gerrrt/HomeLab/issues/914) traced ([#923](https://github.com/Gerrrt/HomeLab/issues/923)): it cost two
  days of 2 Mbit/s downloads before reseating it fixed them.
- **Leave a small service loop** behind each device, enough to slide it out
  10 cm without unplugging anything.
- **Velcro, not zip ties.** Zip ties crush cable and are cut, not undone.
- Move the switch's leads by the captured port map, per
  [`swap-the-switch.md`](swap-the-switch.md) Phase 2, step 3. `morpheus`'s
  `igc0` goes to port 1. `ifrit` gets a free green access port, untagged
  VLAN 30, per [`build-the-playground.md`](build-the-playground.md) §1. Not
  the TP-Link.
- **`smaug`'s lead goes straight to the CRS326,** on the port that takes
  the MokerLink's port 15 role in the captured map: untagged, VLAN 40
  ([`network.md`](../network.md)). The house run that carried it from the
  media room is then free.
- **`trinity`'s 2 TB USB photo disk goes on `trinity`'s tray**, beside it,
  strapped down with velcro so it cannot slide off or hang by its cable. Plug
  it back in before `trinity` powers up in §7: it holds Immich's originals.
- **The XB7 to `morpheus`'s `em0`:** a factory cable, seated until the latch
  clicks, in the XB7's striped 2.5 Gbit port.
- KVM: one lead set each, **by the port map in
  [`hardware.md`](../hardware.md#console-and-power-maps)**: `morpheus` on 1,
  `trinity` on 2, `Saruman` on 3, `smaug` on 4 if the TS150's rear VGA is
  used, `ifrit` on 5. The lead sets reach from U23 down to `Saruman` at U3,
  checked 2026-10-12.
- Power cords **by the PDU outlet map** in the same section: the DL360's
  supplies on 1 and 2, then up the rack, the external bricks together on 6–9
  and the KVM on 10. Both laptops' chargers go on the UPS's own outlets
  beside the TP-Link, not on the PDU (§1.7).
- **The two cantilevered trays get their rails before anything is loaded
  above them.** The keyboard drawer and the Tiny tray are front-mounted and
  wobble with all six ear screws tight; a pair of adjustable four-post
  support rails in each unit gives their rears a ledge. Fasten each tray's
  rear to its rails: a screw through the slider or the tray's lip into the
  rail where there is a hole, a velcro strap round rail and tray where there
  is not. Then push each tray: the frame should not move with it.
- **Read which UPS outlet group the PDU's cord is on**, and which the
  TP-Link and the chargers are on. The Smart-UPS X's outlets are in groups
  the card can switch and sequence separately, and no document records
  which group feeds what. Check each group's turn-off and turn-on settings
  against ADR-0049's shutdown and §7's power-up order, and write the groups
  into `hardware.md` in §8.

---

## 7. Power up, in this order

| Order | What | You should see |
| --- | --- | --- |
| 1 | UPS into the wall, then on | Its panel reports on line. The PDU is live |
| 2 | CRS326 | [`swap-the-switch.md`](swap-the-switch.md) Phase 2, steps 4–8. **If 4–6 fail, its rollback applies:** the MokerLink comes back, by the same map |
| 3 | `morpheus`, from the KVM | The console reaches its menu. The house gets DHCP and internet. `nc -z -w2 10.0.99.1 22` from `prometheus` succeeds |
| 4 | `trinity` | It boots unattended: the TPM unseals its root disk ([ADR-0054](../adr/0054-encrypt-trinitys-disks-and-seal-the-root-key-to-the-tpm.md)). Moving it changes nothing the TPM measures. **If it stops at a passphrase prompt,** something changed its firmware settings. Type the recovery passphrase, and read ADR-0054 before re-sealing |
| 5 | `Saruman`, from the iLO at `10.0.30.10` | Its guests start on their own. The iLO's memory page shows sixteen DIMMs and 256 GB, all healthy; note the speed they trained at |
| 6 | `smaug`, from its front button | `erebor` imports. The NAS's shares are back |
| 7 | `prometheus` and `oracle` on the network | Their leads into the TP-Link |

`ifrit` stays off until [`build-the-playground.md`](build-the-playground.md)
§1.

### 7.1 Delete the silence first, then read

**Delete before reading.** That is the standing rule from
[`fit-the-ups-battery.md`](fit-the-ups-battery.md) §3: an alert that is
still silenced cannot prove anything is fixed.

```bash
curl -sS -X DELETE http://localhost:9093/api/v2/silence/<UUID from §2>
```

Then **resume the healthchecks.io check** you paused in §2.

### 7.2 Verify

On `prometheus`:

```bash
make ps
make ps STACK=sensitive
make check-firewall
make snmp-verify
curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=up == 0'
curl -sS http://localhost:9093/api/v2/alerts | python3 -c 'import json,sys; [print(a["labels"]["alertname"], a["labels"].get("instance","")) for a in json.load(sys.stdin)]'
```

**You should see** every container healthy, and no target `up == 0` five
minutes after the last host came back. The only alerts left should be the
standing ones from before the window. Note those in §2, before you start.

Then the WAN: the speed test at the next :00 or :30 should read about
900 Mbit/s or more down, and `WanReceiveErrors` should stay quiet. A re-seated
WAN cable is exactly what that alert was written for.

### 7.3 Resume what §3 paused

```bash
sudo sed -i '/^HOMELAB_CONVERGE_APPLY=0$/d' /etc/default/homelab-timers
```

---

## 8. Write down what is now true

In one PR, per [#919](https://github.com/Gerrrt/HomeLab/issues/919):

- [`hardware.md`](../hardware.md): the Rack table becomes the 32U layout as
  built, and "Planned: a 32U rack" is removed or marked done. Include the
  bare panel's measured height from §1.5. `Saruman`'s row in the Compute
  table becomes 256 GB, with the trained speed.
- [`roadmap.md`](../roadmap.md#everything-still-to-buy): the rows bought for
  this move leave the buy table, and README's count with them.
- [ADR-0049](../adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md)'s
  *What is on the UPS* records: `trinity` and `ifrit` are now on the PDU,
  `smaug` is on it directly rather than by the long cord, and §1.7's outlet
  table.
- [`network.md`](../network.md): the port map, now that it was captured and
  moved, the KVM port map from §6.1, and `smaug`'s location, which is the
  rack, not the media room.
- [`shut-down-on-the-ups.md`](shut-down-on-the-ups.md): it sends you to
  `smaug`'s power button in the media room, and to the KVM in U6.
- `hardware.md`'s other mentions of `smaug` in the media room, on its long
  cord.
- [`swap-the-switch.md`](swap-the-switch.md) Phase 3, and its own documents.

---

## If something goes wrong

| What | Do |
| --- | --- |
| The CRS326 fails its checks (switch runbook Phase 2, steps 4–6) | Its rollback: the CRS326 comes out of U21 and the MokerLink goes in, by the same map. Finish the move around it |
| A rail will not reach the rear post | The frame's depth differs from §1.1's 29". Loosen the rear posts, set them to 29", and tighten them again. Do not force the rail |
| `trinity` asks for a passphrase | See row 4 in §7. Do not re-seal the TPM in the window |
| The house has internet but no names resolve | `trinity`'s AdGuard is not answering. The documented stopgap is in [`forward-dns-to-adguard.md`](forward-dns-to-adguard.md): add `1.1.1.1` under *System → General Setup* on pfSense, and remove it once AdGuard answers |
| The mains drops mid-move | NUT runs the shutdown sequence on whatever is still up. Wait for mains, then resume at §7 |
| Out of time | Stop at a clean point: `morpheus` and the switch up, everything else racked but off. Finish another day, with the silence extended |

---

## Why it is built this way

- **One window, shared with the switch swap.**
  [`swap-the-switch.md`](swap-the-switch.md) already takes the house offline.
  Two house-wide outages a week apart cost twice as much goodwill as one.
- **The bench work is not optional.** Everything in §1 could be done in the
  window, but each item there is also something that can go wrong: a
  mis-seated SO-DIMM, a lid that suspends a host, a rack depth that does not
  fit the rails. Finding those with the house online costs nothing.
- **Bottom up and heaviest first** keeps the frame's centre of gravity low
  while it is being loaded, and leaves the light, fiddly units for last, when
  the frame is already stable.
- **Height does not matter for airflow.** An open frame has no sides, so
  height does not trap air. Each device draws from its own front and exhausts
  out its own back. What decides how hot things run is the room's temperature
  and the space behind the frame (§1.2), not its height. The one place that
  needs a gap — over the fanless CRS326, especially with two S+RJ10 modules —
  has one at U22. The other three gaps are single units over each
  closed-lid laptop and between `trinity` and `ifrit`. The total heat is
  modest: one DL360, one tower NAS, three small PCs, two laptops and a
  passive switch.
- **The console is at the top, by choice (2026-10-12).** The first plan put
  the keyboard at U19, about 90 cm up, and left five units spare above the
  screen. Moving the screen to the very top puts the keyboard at about
  112 cm, and lets the 32U frame take `smaug` as well. A frame that tall
  holds the whole estate, so the NAS's long cord goes.
