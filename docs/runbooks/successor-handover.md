# Handover: taking this estate over cold

**Target:** whoever is now responsible for this network and did not build it
**Time:** an hour to read, a day to verify
**You will need:** a machine on Hicks (VLAN 50), shell access to `prometheus`
(10.0.99.20), and the age private key — the last one is the item without which
none of the rest is worth starting

Every other document here assumes you already know what this estate is. This one
does not. It is written for a technical trustee or a paid MSP arriving with no
context: someone competent who has never seen this network, has no idea which of
the runbooks matters first, and needs to know what breaks on its own if nobody
touches anything.

It is an ordering of what already exists, not a replacement for any of it. Every
claim below links to the document that owns it, and that document is the
authority when the two disagree.

---

## This repository is the operator-facing one

[ADR-0011](../adr/0011-keep-the-wiki-internal.md) tiers the *household's*
documentation, each tier depending on strictly less than the one above it: a
printed break-glass card that depends on nothing, the Lemmiwinks wiki on
`oracle` that depends on the estate's own network and power, and a private
GitHub mirror of that wiki's raw Markdown that depends on the internet and a
repository grant.

None of those three is this. The wiki was built to let the family operate the
estate, and that audience cannot run pfSense and VLANs from a wiki page. **This
repository is the operator-facing one** — the configuration that actually runs,
and the reasoning behind it — and its reader is the technical second named on
that card, or a paid MSP standing in for one. It is public, so it needs no
grant, and nothing in it requires the estate to be reachable.

So: read it here, not there. If the person in front of you is *not* technical,
the card is their document and none of this will help them.

---

## What this estate is

A pfSense firewall called `morpheus` (an HP ProDesk 600 G4 Mini, rack U5) with
every segment terminating on it: six numbered VLANs plus an untagged
switch-management LAN, default deny between them, all trunked over one managed
switch called `neo`. One compose stack — Prometheus, Alertmanager, Loki, Grafana,
`snmp-exporter`, `blackbox-exporter` and a Grafana Alloy agent — runs on
`prometheus`, a 2012 MacBook Pro on a shelf, and watches the estate two ways:
Alloy agents push metrics and logs from the Linux hosts, and `snmp-exporter`
polls the four devices that cannot run an agent (firewall, switch, UPS, iLO).
A second stack exists for the lab (`stacks/lab`) and is not deployed.

Four facts that reorder everything else:

| Fact | Consequence |
| --- | --- |
| `morpheus` routes every segment, serves DHCP on every tagged interface, and is the only resolver any DHCP scope hands out ([ADR-0010](../adr/0010-keep-the-resolver-on-the-gateway.md)) | When it is down the house has no network. Not degraded — none. DNS and gateway are deliberately one failure and never two |
| `neo` carries every VLAN | Rebooting it takes the whole house offline. Pick the window deliberately |
| Nothing in the house depends on the observability stack | It can be down for a week and the only loss is the record. See [`restore-the-stack.md`](restore-the-stack.md) |
| Hicks (VLAN 50) is the segment you administer from | Since 2026-09-02 it reaches management on an enumerated list of destinations rather than wholesale. It is not the only path in — the switch LAN reaches every segment, and `Saruman` has a host-scoped pass to the monitoring host. [`network.md`](../network.md#hicks--vlan-50--trusted) holds the list |

Topology and data flow: [`architecture.md`](../architecture.md). Device
inventory and what each segment may reach: [`network.md`](../network.md). Why
the split is shaped this way: [`security.md`](../security.md).

---

## Day one, in order

Work down this list. Each step is cheap, and each one tells you whether the step
below it is even meaningful.

### 1. Confirm you can decrypt

Everything else is downstream of this. On `prometheus`, from the deployment
checkout rather than a worktree — the units and the container mounts both carry
absolute paths:

```bash
ls -l ~/.config/sops/age/keys.txt
```

```bash
make render
```

`make render` decrypts the secrets and writes the runtime config. If it fails at
decryption, this host does not hold the key, and see
[§Where the secrets are](#where-the-secrets-are) before doing anything else.

### 2. Confirm the alert path still reaches *you*

This is the step most likely to be quietly false on the day you take over. Alerts
go to webhook URLs and a heartbeat ping URL that belong to whoever set them up —
an ntfy topic, a healthchecks.io account. None of it is in this repository, and
none of it changes hands automatically.

```bash
make secrets-edit
```

That opens the decrypted file in a hardened `$EDITOR` — hardened because a vim
or neovim with `undofile` set writes the plaintext into a permanent undodir that
`sops` does not shred, which is how three live SNMP communities once came to be
sitting on this host's unencrypted disk. Read the four Alertmanager URLs,
confirm you own each destination, and re-point any you do not. Then prove the
path end to end with
[`verify-the-alert-path.md`](verify-the-alert-path.md) — including stopping
Alertmanager and watching the external check actually go red. A dead man's
switch nobody has seen trip is indistinguishable from one that does not work,
and this estate has already lived through a webhook that pointed at nothing for
the entire life of the stack.

### 3. Find out what the host is actually running

```bash
journalctl -u homelab-converge.service -n 20 --no-pager | grep homelab-deploy
```

The host fetches `main` hourly, verifies GitHub's signature, fast-forwards and
deploys itself — so a merged pull request lands within the hour. It may also be
in report-only mode, in which case it fetches and records and applies nothing,
and every merge needs a manual `make up`. `DeployApplyDisabled` firing is what
says so. Full behaviour, and every refusal it can print, in
[`converge-the-host.md`](converge-the-host.md).

### 4. Confirm the scheduled jobs are installed and reporting

```bash
systemctl list-timers 'homelab-*'
```

```bash
make validate
```

`make validate` runs everything CI runs, plus one check that is about *this
host*: whether the stack runs here while no `homelab-*` units are installed. The
schedule covers convergence, the volume backups, the firewall export, the SNMP
verification and the dashboard drift check —
[`schedule-maintenance.md`](schedule-maintenance.md) has the table and the
staleness threshold on each.

### 5. Look at what is firing

Grafana on `https://10.0.99.20:3000`, signed by the lab's own CA, so a browser
warns until you trust `certificates/ca.pem` — step 4 of
[`generate-certificates.md`](generate-certificates.md). Alertmanager binds to
loopback and is reached through Grafana; there is no separate login.

### 6. Check the certificates and the backups

```bash
make certs ARGS=--list
```

```bash
make backup ARGS=--list
```

```bash
make backup-firewall ARGS=--list
```

An expired leaf and a misconfigured one look identical from the client side, and
a backup set is complete only when it has a `MANIFEST`.

### 7. Back up the age key to somewhere you control

Do not defer this past day one. [§Where the secrets
are](#where-the-secrets-are), then
[`back-up-the-age-key.md`](back-up-the-age-key.md).

---

## What fails soonest if nobody touches anything

Ordered by how quickly it bites, and by how loudly. The pattern worth noticing:
the loud failures are watched, and the quiet ones are the ones a successor
inherits without knowing.

| What | When | How you find out |
| --- | --- | --- |
| **Alert delivery to a destination you do not own** | Immediately, and silently | You do not. This is step 2 above, and it is the reason it is step 2 |
| **The external heartbeat watcher** — a free-tier cron-monitor on somebody else's account | Whenever that account lapses | Nothing here can tell you. A watcher on this host would fail with the thing it watches, which is why it is off-host and therefore outside anything this repository can check |
| **The age key backup goes unproven** | 90 days after the last verification | `SecretsKeyBackupUnproven`, routed to the normal alert channel. Until the first verification there is no timestamp at all and `ScheduledJobNeverRan` says so instead |
| **Grafana's leaf certificate** | 825 days from issue; the APC card's own certificate expires on its own clock | `TlsCertificateExpiringSoon` at 30 days, `TlsCertificateExpiryImminent` at 7 — read off the served handshake by `blackbox-exporter`, not off a file. Let it lapse and `up{job="grafana"}` goes to 0 as well |
| **The UPS battery pack** | A pack was fitted 2026-08-28 and passed its self-test; packs are consumables and this one is on a biweekly test schedule | `UpsSelfTestFailed` and `UpsBatteryUnproven` key on the self-test result, which is the single honest signal this card emits — every charge, runtime and alarm value it reports was fabricated while the bay was empty. Two things remain open: the card's test *schedule* is unwatched ([#249](https://github.com/Gerrrt/HomeLab/issues/249)), and `upsBasicBatteryLastReplaceDate` still reads a pre-fit date, so it is not a usable record of the pack's age |
| **Mains power to the monitoring path** | Any cut | The rack is on the UPS; the switch carrying `prometheus` and `oracle` is not, so both laptops keep running and go deaf. Stated in [`security.md`](../security.md#threat-model) |
| **Container images going stale** | Continuously, once nobody merges | Dependabot proposes bumps and CI validates them, and convergence deploys a merge within the hour. An unattended estate simply stops receiving updates — nothing alerts on it |
| **The switch's previous SNMP community** | Already true, indefinitely | An accepted residual, not a pending fix: `neo`'s firmware will not persist a deletion from the community table. Recorded in [`SECURITY.md`](../../SECURITY.md), method in [`rotate-snmp-community.md`](rotate-snmp-community.md#the-mokerlink-switch-overwrite-the-row) |

> [!CAUTION]
> The three entries at the top of that table are all failures of *notification*,
> and every one of them is silent from inside the estate — there is no dashboard
> on which they look wrong. If you verify nothing else on day one, verify that a
> real alert reaches a person who is still reading.

Two things belonged on this list until recently and no longer do. They are named
here because a successor reading the older issues will find them described as
outstanding and should not go looking for work that is already done. Nothing
scheduling the maintenance jobs was
[#77](https://github.com/Gerrrt/HomeLab/issues/77), closed — the timers in
[`schedule-maintenance.md`](schedule-maintenance.md) are that work. The empty UPS
bay was [#93](https://github.com/Gerrrt/HomeLab/issues/93), closed — a pack is
fitted and proven.

---

## Where the secrets are

| What | Where | In git? |
| --- | --- | --- |
| The encrypted values | `secrets/observability.sops.yaml` | Yes, as ciphertext. Key names are left in plaintext on purpose, so the required set is discoverable without a key |
| The public recipients | [`.sops.yaml`](../../.sops.yaml) | Yes. It can only encrypt |
| **The private key** | `~/.config/sops/age/keys.txt` on `prometheus`, mode 600, plus one offline copy | **Never.** Nothing in this repository or any backup of it can recover the private half |

The encrypted file holds the Grafana admin login and renderer token, one SNMP
community per polled device, and the four Alertmanager URLs. Details in
[`secrets/README.md`](../../secrets/README.md).

**What it does not hold**, and what you will therefore have to obtain from the
outgoing operator directly:

- The pfSense, MokerLink, iLO and APC network-card **admin passwords**. None of
  them are in this repository in any form.
- The internal CA's private key. `certificates/` is gitignored and host-local, so
  a clean clone has no CA at all — reissuing is
  [`generate-certificates.md`](generate-certificates.md) step 1, and the cost is
  re-trusting the new `ca.pem` everywhere it was trusted.
- Access to whatever holds the alert webhooks and the heartbeat check.

### If you do not have the age key

Say so out loud before anything else. This is
[#106](https://github.com/Gerrrt/HomeLab/issues/106) — one key, one holder, one
copy plus the original — and it is open. Without it every encrypted value in
this repository and its history is permanently undecryptable, and the recovery
path is re-deriving each credential from the device it belongs to: four SNMP
rotations on hardware, one of which cannot persist a community deletion and
needs the switch rebooted to change. The mechanism for a second recipient costs
nothing (`.sops.yaml` takes a list, and `sops updatekeys` re-keys the file from
any host that can already decrypt); what it has always needed is somewhere to
put the second key. A handover is that somewhere.

### If you do have it

Verify the copy, do not just look at it:

```bash
make secrets-verify-backup KEY=/path/to/the/copy
```

That command refuses to run against the live key by device and inode, blanks the
environment first, and warns if the copy sits in a git working tree or a synced
folder — because the obvious hand-typed `sops -d` equivalent passes even for a
completely unrelated keypair. Restoring onto a new host is a file copy and
nothing more; **do not run `make secrets-init` to restore**, as it generates a
new keypair whose public half matches nothing.

---

## What can be switched off, and what cannot

### Safe to stop

| Thing | What you lose |
| --- | --- |
| The whole observability stack (`make down`) | The record, and only the record. Nothing in the house depends on it, dashboards and alert rules are in git, and metrics and logs re-accumulate. `grafana-data` is the exception — users, annotations and any un-exported dashboard edit live only there |
| `stacks/lab` | Nothing. It is committed and deployable and has never been deployed |
| `homelab-converge.timer` | Automatic deployment. The host stays on whatever revision it is on until someone runs `make up`, which is exactly how it worked before |
| `dashboards-drift` | The daily proof that Grafana holds no uncommitted dashboard edit |
| Suricata on the terminal segments | Detection, not connectivity. It is alert-only — `Block Offenders` is off on both interfaces and stays off. [`enable-suricata.md`](enable-suricata.md) |
| `make screenshots` and the images under `docs/images/` | Nothing operational |

### Not safe to stop

| Thing | Why |
| --- | --- |
| `morpheus` | Routing, DHCP on every tagged interface, and the only resolver every client is given. Its loss cannot be worked around from the network, because the network is what it provides. [`restore-the-firewall.md`](restore-the-firewall.md) |
| `neo` | Every VLAN crosses it. A reboot is a whole-house outage, so schedule it rather than taking it |
| The external heartbeat watcher | Turning it off does not stop alerts — it stops anything noticing that alerts have stopped, which is the failure it exists for |
| `oracle` | It serves the wiki ([ADR-0011](../adr/0011-keep-the-wiki-internal.md)) and holds the only off-host copy of the firewall export. `make backup-firewall` **fails** if it cannot reach it, by design |
| The age key, and the proof that a copy of it decrypts | Above |

### Do not change without reading first

- **DHCP on the untagged LAN interface stays disabled.** Re-enabling it races the
  DHCP servers on every tagged interface and takes the house offline
  ([`network.md`](../network.md#lan)).
- **`homelab-backup-volumes.timer` has `RandomizedDelaySec=0` on purpose.** It
  quiesces the stack weekly, which stops the heartbeat for the length of the
  archive; a randomised start would make the expected gap unstateable against the
  external watcher's grace window.
- **`repeat_interval` on the heartbeat route is coupled to the external check's
  period and grace.** Change one and the other moves with it, or you get a check
  that alarms on a healthy stack — or never alarms at all.
- **Rule files reach Prometheus only on a reload.** Loki polls its rule directory
  and updates on its own, so Loki being current is not evidence that Prometheus
  is.

---

## Reading order

1. **This page**, then the [README](../../README.md) for the shape of the
   repository and `make help` for what it can do.
2. [`architecture.md`](../architecture.md) and [`network.md`](../network.md) —
   what is where, and what may reach what. `network.md`'s *Reaches* column is
   the current state; a rule count never was.
3. [`back-up-the-age-key.md`](back-up-the-age-key.md) — and do it, rather than
   reading it.
4. [`verify-the-alert-path.md`](verify-the-alert-path.md) — and prove it.
5. [`converge-the-host.md`](converge-the-host.md) and
   [`schedule-maintenance.md`](schedule-maintenance.md) — how the host deploys
   and maintains itself, and every way it refuses.
6. [`deploy-stack.md`](deploy-stack.md) and
   [`generate-certificates.md`](generate-certificates.md) — the first-deploy
   path, which is also the rebuild path.
7. [`restore-the-firewall.md`](restore-the-firewall.md) then
   [`restore-the-stack.md`](restore-the-stack.md) — in that order, because one
   of them is the house and the other is the record.
8. [`security.md`](../security.md) and [`SECURITY.md`](../../SECURITY.md) — the
   threat model, and every residual accepted rather than fixed. Read these
   before concluding that something here is an oversight.
9. [`docs/adr/`](../adr) — when you want to know why, including the costs that
   were accepted knowingly. [`roadmap.md`](../roadmap.md) is the narrative of
   what is outstanding and why it is in that order; the tracking itself is in
   [Issues](https://github.com/Gerrrt/HomeLab/issues).

The remaining runbooks are task-shaped and are best read when you have the task:
[`add-monitored-device.md`](add-monitored-device.md),
[`add-a-host-override.md`](add-a-host-override.md),
[`rotate-snmp-community.md`](rotate-snmp-community.md),
[`ship-firewall-logs.md`](ship-firewall-logs.md),
[`fit-the-ups-battery.md`](fit-the-ups-battery.md),
[`replace-the-smart-storage-battery.md`](replace-the-smart-storage-battery.md),
[`enable-suricata.md`](enable-suricata.md),
[`build-the-lab-guest.md`](build-the-lab-guest.md),
[`build-the-playground.md`](build-the-playground.md) and
[`purge-git-history.md`](purge-git-history.md).

---

## What this page does not cover

It does not replace the outgoing operator. Three things have no representation
in this repository at all — the device admin passwords, the account holding the
alert destinations, and the offline copy of the age key — and a handover that
does not transfer those has not happened, however carefully it is documented
here.
