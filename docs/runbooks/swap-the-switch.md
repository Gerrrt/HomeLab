# Runbook: Swap neo for the CRS326

**Target:** `neo` at `10.7.7.2`, Rack U9 — the MokerLink 26-port managed switch,
replaced by the MikroTik CRS326-24G-2S+RM
**Time:** about two hours at the bench, then a 30–60 minute window with the house
offline, then a pass over the documents
**You will need:** physical access to the rack, a workstation on Hicks, the age
key on the monitoring host, and the estate CA at `certificates/ca.pem`

[ADR-0041](../adr/0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md)
decided what the new switch is and how it is configured; this is how it gets
there. The switch is replaced for one property — a TLS management interface, so
the read-write admin credential stops crossing the wire in clear through the
device it protects — and
[#84](https://github.com/Gerrrt/HomeLab/issues/84)'s un-deletable SNMP community
closes with it, because it leaves with the firmware.

**`neo` carries every VLAN.** Phase 2 takes the whole house offline: no
internet, no wireless, no televisions, no cameras. Schedule it outside working
hours and share it with another rack visit rather than giving it its own.

**Do Phase 1 completely before booking the window.** Everything except the
cabling can be done on a bench with the switch on a desk, and the entire point
of the split is that the window is cabling and verification, not configuration.

---

## Read this part first

**Three ways this locks you out. Two of them are silent.**

1. **The firewall pass names port 80.** [`network.md`](../network.md) records
   the switch LAN as blocked apart from `10.7.7.2:80`. Disable plain `www` on
   the switch before widening that rule to `443` and you have a switch that is
   up, correctly configured and unreachable from the workstation you are
   standing at. **Widen first, prove the new UI, close `80` last.**
2. **Bridge VLAN filtering is one commit from a dead trunk.** On RouterOS the
   config that decides which ports carry which tags is the config the management
   path rides on. This is why ADR-0041 keeps the untagged `10.7.7.0/24` link
   from `morpheus`'s `igc0` to port 1: it is a cable, not a configuration, and it
   is the way back in. Do not put management on a tagged VLAN "while you are in
   there".
3. **A used RouterOS device arrives with its last owner's configuration**,
   users and all — the same lesson `SECURITY.md` records for `smaug`'s Intel
   AMT, where a second-hand server arrived with the factory default still set on
   a management plane nobody thought to look at. Reset it before it touches the
   network, not after.

**Silence Alertmanager before Phase 2.** Pulling the core switch is
indistinguishable from the estate burning down, and the alerts are real ones
that page a real person.

---

## Phase 1 — at the bench, before any window

Nothing here touches the running estate. The switch is on a desk, on its own
cable to a laptop.

### 1.1 Capture the MokerLink first, while it is still running

This is the step that makes the window recoverable, and it is the one most
easily skipped because the new switch is the interesting object.

**Export the MokerLink's running configuration and write down its full port map
— every port, its VLAN membership, tagged or untagged, and what is plugged into
it.** No document in this repository records it. `architecture.md` has the
topology and `network.md` has the addresses; neither has a per-port map, so if
you unplug 26 cables without one, the house comes back wrong and you will be
diagnosing it at midnight with no switch to compare against.

**Count the copper.** The MokerLink has 26 copper ports; the CRS326 has 24 ×
RJ45 plus 2 × SFP+, which do not take an RJ45 patch lead. If more than 24 copper
ports are actually populated, **an SFP+ copper module is a purchase**, and by
[`roadmap.md`](../roadmap.md)'s own rule the PR that buys it edits *Everything
still to buy* in the same commit. Establish this now, not at the rack.

Nothing in the estate uses PoE, so there is no powered-port shortfall to plan
around.

### 1.2 Intake

Confirm the OS and version it booted, the serial and the management MAC:

```text
/system/resource/print
/system/routerboard/print
/interface/print
```

Check the box for rack ears and a power supply — it is a used listing. **These
facts go into [`hardware.md`](../hardware.md)**, replacing the "in transit"
line, and that edit can land on its own before the window.

### 1.3 Reset, then RouterOS

Boot RouterOS, not SwOS. ADR-0041 records why at length; briefly, SwOS serves
HTTP only and speaks SNMP v1 and v2c only, which is both of the firmware limits
this purchase exists to escape.

Wipe whatever the last owner left:

```text
/system/reset-configuration no-defaults=yes skip-backup=yes
```

Then set a unique admin password, from the password manager, and record where it
lives in [`successor-handover.md`](successor-handover.md) alongside the others.

### 1.4 The certificate

Issue the leaf from **the estate's CA**, not the sensitive tier's — the tier's
root issues seven-day leaves over ACME for `trinity` and a switch cannot ask for
a renewal ([ADR-0037](../adr/0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md),
[`generate-certificates.md`](generate-certificates.md)). Run it **from the main
checkout on the monitoring host**, not from a worktree, so it lands in the
`certificates/` the live stack uses:

```bash
make certs ARGS="--host neo.matrix.elysium --ip 10.7.7.2"
```

Both SANs matter: the name for normal use, the address because it is the
break-glass form when `morpheus` is the thing you are diagnosing. That produces
`certificates/neo.matrix.elysium.pem` and `certificates/neo.matrix.elysium-key.pem`.

Upload both to the switch and import them, then bind `www-ssl`. **Leave plain
`www` enabled for now** — it is closed in Phase 2, after the firewall rule moves
and the new UI is proven:

```text
/certificate/import file-name=neo.matrix.elysium.pem
/certificate/import file-name=neo.matrix.elysium-key.pem
/ip/service/set www-ssl certificate=neo.matrix.elysium disabled=no
```

Confirm the browser trusts it without a warning. If it does not, the leaf is
wrong or the CA is not installed on the workstation — fix that here, where there
is no outage running.

### 1.5 SNMPv3, and no v2c

Follow §4 of [`rotate-snmp-community.md`](rotate-snmp-community.md) for the
passphrases and for the five repository files that change. RouterOS configures
v3 users under `/snmp/community` with `security=private`, which reads oddly if
you are expecting a separate user table.

**Nothing the MokerLink held is carried across.** `SECURITY.md` records that the
MokerLink's SNMP community leaked into a local session transcript on 2026-08-20
and was *deliberately not rotated*, because rotating it meant repeating the
residual — the firmware would not persist the deletion of the old one. That
reasoning expires with the hardware, but only if the value does too. Generate
the v3 passphrases fresh (`make gen-secret ARGS=--snmp` for the shape, §4.1 of
[`rotate-snmp-community.md`](rotate-snmp-community.md) for the procedure) and
derive nothing from the community the old switch used. A leaked credential that
migrates onto its replacement has survived the swap that was meant to retire it.

Restrict the agent to the scraper at `10.0.99.20` — the switch has address-based
access control and the MokerLink did not, so this is a control the estate gains
rather than one it carries across. **Configure no v2c community at all**, not
even a fresh one: ADR-0041 decision 4 turns v2c off, and the defaults `public`
and `private` go with it. Prove it with `snmp-verify.sh` pointed at the bench address before
the switch is ever racked; that proof is what closes #84, and doing it here
means the window does not have to.

### 1.6 The port map, and mirroring stays off

Build the bridge and its VLAN membership from the map captured in §1.1. Keep the
management path untagged on port 1.

**Do not configure port mirroring.** The capability is why the CRS326 met #444's
criteria, and [ADR-0006](../adr/0006-detect-at-the-chokepoint.md) decided the
sensor belongs on `morpheus` at the chokepoint with the switch's mirroring
disabled and available on demand. Buying a device that can mirror was never a
decision to mirror.

---

## Phase 2 — the window

House offline. Alertmanager silenced. The MokerLink stays on the bench, cabled
and powered, until Phase 3 passes.

1. **Widen the firewall pass to `443`** — the rule in `network.md` that admits
   `10.7.7.2:80`. Both ports open for the duration of the window.
2. Rack the CRS326 at U9. Cat6 from `morpheus`'s `igc0` to **port 1**, the
   trunk.
3. Move the patch leads, following the §1.1 map.
4. Verify **from the address before the name**: `https://10.7.7.2/` reaches the
   UI and the certificate validates. `neo.matrix.elysium` depends on Unbound on
   `morpheus`, which depends on the switch you have just replaced.
5. Walk the VLANs: internet, wireless, a camera on Skids, a host on VLAN 99, the
   lab on VLAN 30.
6. Confirm the SNMP scrape is up and the `switch-ui` probe is green.
7. **Only now**, disable plain `www` on the switch and narrow the firewall rule
   from `80` to `443`. Prove the UI again afterwards.

If any of 4–6 fails and is not fixed within the window's budget, roll back: the
MokerLink returns to U9, the patch leads go back by the same map, and the
firewall rule goes back to `80`. A failed swap that is reverted is a short
outage; a failed swap that is debugged live is not.

---

## Phase 3 — the documents and the configuration

This is where the estate stops describing a MokerLink. None of it is urgent, and
all of it is the point.

- [`network.md`](../network.md) — the LAN row, the `10.7.7.2` notes, the
  `[^MokerLink]` footnote, and the Hicks rule that now names `443`. **Rewrite
  the note explaining why the switch LAN exists**: it currently says the UI
  "will not bind to a tagged interface", which was the MokerLink's limit and is
  not the CRS326's. Left as written, the next reader correctly concludes the LAN
  can go, and removes the way back in. ADR-0041 has the replacement reasoning.
- [`hardware.md`](../hardware.md) — the Rack table at U9, and the CRS326 entry
  moves from *still moving* to on-hand with its serial and MAC.
- [`architecture.md`](../architecture.md) — the mermaid node label.
- `generator.yaml`'s `mokerlink` module and `auth_mokerlink`,
  `prometheus/targets/snmp.yaml`, and the switch block in
  `network.rules.yaml`. **Do not carry the port references across unchecked**:
  this is a 24 + 2 device replacing a 26-port one, so `ifIndex` and `ifName`
  change, and any rule or dashboard panel naming a port needs re-deriving.
- The `switch-ui` blackbox target and its `via: dns` twin, `http` → `https`,
  with a `ca_file` rather than `insecure_skip_verify` — the estate CA is already
  how blackbox verifies Grafana.
  [`blackbox.test.yaml`](../../stacks/observability/prometheus/tests/blackbox.test.yaml)
  uses `switch-ui` as its worked example of an endpoint with no dns twin; that
  needs a different subject.
- `SNMP_COMMUNITY_MOKERLINK` in `secrets/observability.sops.yaml` has no
  consumer once v2c is off, and its name is a misnomer the moment `neo` is a
  MikroTik. Retiring it touches `observability.example.yaml`,
  `render-config.sh`, `verify-key-backup.sh` and `generator.yaml`. **Run
  `make render` and `make reload` from the main checkout**, never a worktree —
  render writes into the tree it runs from, and a worktree render produces a
  file no container mounts.
- `snmp-verify.sh`'s GETBULK `WARN` becomes a `FAIL` again, now that the device
  it excused is gone.
- `snmp-walk.sh` exists because the MokerLink locks up under normal polling. If
  the CRS326 does not, the script is a workaround for a device nobody owns —
  delete it on that evidence, not on the assumption.
- `SECURITY.md` and [`security.md`](../security.md) — the GETBULK and plain-HTTP
  residuals close. Both are the accepted-residual record, so they close with the
  date and the proof, not by deletion.
- [`roadmap.md`](../roadmap.md) — #84 and #444 move to *Done*.

Close [#84](https://github.com/Gerrrt/HomeLab/issues/84) on `snmp-verify.sh`
clean over GET **and** GETBULK, against the new device and against the old
community. Then close
[#444](https://github.com/Gerrrt/HomeLab/issues/444).

---

## Also required

- The MokerLink leaves the estate carrying a community that cannot be deleted,
  that is known to have leaked, and an admin password that has crossed the wire
  in clear for its whole life. Wipe what can be wiped and do not re-home it onto
  anything that matters.
- The leaf is good for 825 days and the switch cannot renew it. Put the expiry
  in the diary — [`schedule-maintenance.md`](schedule-maintenance.md) is where
  the estate's dated obligations live.
