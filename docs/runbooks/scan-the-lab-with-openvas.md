# Runbook: Scan the lab domain with OpenVAS, from `garuda`

**Target:** the lab domain's six, `10.0.30.50`–`.55`, scanned by OpenVAS/GVM on
`garuda` (`10.0.30.62`).

**Time:**

- **Setup, once:** an hour or two, mostly the feed sync.
- **A scan:** start, an hour or so of scanning, then a read of the report.

**You will need:** a shell on `garuda`, and its desktop (the console from
Hicks) for the web UI.

This is
[ADR-0093](../adr/0093-run-openvas-on-garuda-on-demand-scoped-to-the-domain-by-nftables.md)
for [#921](https://github.com/Gerrrt/HomeLab/issues/921)'s phase 3. The rules:

- **Scope.** The scope is the six and nothing else, enforced by nftables, not
  only by the target list.
- **On demand.** GVM is off unless a scan is running.
- **No silence.** No alert is silenced for a scan.

---

## 0. What is decided, and why

| | Decision | Why |
| --- | --- | --- |
| Software | Kali's `gvm` packages | They update with Kali like garuda's other tools, and add no images to pin (ADR-0093) |
| Running | On demand: `gvm-start`, scan, stop | Kali ships every GVM unit disabled at boot. Stopped, it holds no RAM and can point nowhere |
| Scope | `10.0.30.50`–`.55` only | The domain is the exercise. The firewall, the iLO, the hypervisor and the lab's own services are out |
| Fence | nftables, on `ospd-openvas.service`'s cgroup | The scanner runs as root through `sudo`, so only the cgroup holds it. A target outside the six fails closed |
| UI | gsad on `127.0.0.1:9392`, from garuda's desktop | Nothing is published |
| Silences | None | A scan of the six stays inside VLAN 30, where no estate alert looks. `LabSegmentReachedInternalNetwork` would mean the fence failed, so it must page |

## 1. Install and set up, once

As root on `garuda`:

```bash
apt-get update && apt-get -y install gvm
gvm-setup          # PostgreSQL, the gvmd database, the feeds, an `admin` user
gvm-check-setup    # must end with "It seems like your GVM-… installation is OK."
```

**Expect it to take a while.** `gvm-setup` returns once the feeds are
downloaded. gvmd then imports them into its database for an hour or more, and
there are no scan configs until the GVMD_DATA feed lands. *Administration →
Feed Status* shows the import.

`gvm-check-setup` warns that `/etc/gvm/pwpolicy.conf` is empty. That only
means no password policy is enforced on GVM's own accounts, and there is one
account.

`gvm-setup` prints the `admin` password once, in its output. Sign in at
`https://127.0.0.1:9392` from garuda's desktop and change it there (*My
Settings*). Don't use `gvmd --new-password`, which puts the password on a
command line.

## 2. Install the fence, once

From the repository on `garuda` (`~/code/Gerrrt/HomeLab`):

```bash
sudo install -D -m 0644 stacks/analyst/gvm/gvm-scope.nft /etc/nftables.d/gvm-scope.nft
sudo install -D -m 0644 stacks/analyst/gvm/ospd-openvas-scope.conf \
  /etc/systemd/system/ospd-openvas.service.d/scope.conf
sudo systemctl daemon-reload
systemctl cat ospd-openvas | grep -A1 'scope.conf'   # the ExecStartPre must show
```

Every start of `ospd-openvas` now loads the table first. Check that the
path the rule names is the service's own:

```bash
sudo systemctl start ospd-openvas
systemctl show -p ControlGroup ospd-openvas    # /system.slice/ospd-openvas.service
sudo nft list table inet gvm_scope
```

## 3. Prove the fence, once and after any change to it

The proof uses the real path: a GVM task, through `ospd-openvas` and
`sudo openvas`, against a host the fence must refuse.

1. `sudo gvm-start`. Then, in the UI, create a target named *fence proof*:
   one out-of-scope host, `10.0.30.40` (`alexander`). Use the port list
   *All IANA assigned TCP*, and set *Alive test* to *Consider Alive*, so that
   the scanner really sends.
2. Note the counter: `sudo nft list chain inet gvm_scope scanner` (the
   `counter packets N` on the drop rule).
3. Create a task with that target and the *Discovery* config, and start it.
4. When it ends, the counter must have grown by many packets. The log is
   rate-limited, so `journalctl -k | grep "gvm-scope drop"` shows a sample,
   naming `DST=10.0.30.40`. The report must show no open port on `.40`.
5. Delete the task and the target. Record the counter's before and after,
   and the report's result, in §7.

If the counter did not move, the scanner is not in the cgroup the rule
names. Stop, and don't scan anything until it is understood.

## 4. A scan

1. **Start.** `sudo gvm-start`. Wait for the UI at `https://127.0.0.1:9392`,
   and let the feed status (*Administration → Feed Status*) show current.
2. **The target is the six:** `10.0.30.50-10.0.30.55`, named *lab domain*,
   created once. Never add an address to it outside the six. The fence would
   drop the traffic, and ADR-0093 would have to change first.
3. **Run.** *Full and fast*, unauthenticated, unless an exercise says
   otherwise. An authenticated scan takes a domain credential from
   `ansible/population/`'s seed, stored in GVM's credential store. It never
   goes on a command line.
4. **Watch the SOC while it runs.** This is the purpose:
   - `odin`'s Wazuh, for what the six's agents and garuda's own raised;
   - Zeek on `fenrir`, in the lab's Grafana.

   A scan of the six is noisy there on purpose. Don't tune it away.
5. **Read the report** in the UI. Export what is worth keeping into a case:
   `mkcase <name>` from `dotfiles-Defense`, in `~/cases/`. Never into a
   repository.
6. **Stop.** `gvm-stop`, then the services it leaves running:

   ```bash
   sudo gvm-stop
   sudo systemctl stop postgresql redis-server@openvas mosquitto
   ```

## 5. After a Kali upgrade

A `full-upgrade` can move gvmd's database schema or the feed layout. Before
the next scan:

```bash
sudo gvm-check-setup
```

Do what it asks, such as a `gvmd --migrate` or a feed resync. Then start
`ospd-openvas` once, and confirm `nft list table inet gvm_scope` still loads
(§2). If a packaging change renamed the unit, the rule fails to load and the
scanner fails to start, which is the safe direction. Rename the path in
`gvm-scope.nft`, then prove the fence again (§3).

## 6. Take it out

```bash
sudo gvm-stop; sudo systemctl stop postgresql redis-server@openvas mosquitto
sudo rm /etc/systemd/system/ospd-openvas.service.d/scope.conf /etc/nftables.d/gvm-scope.nft
sudo nft delete table inet gvm_scope
sudo apt-get -y purge gvm && sudo apt-get -y autoremove
```

Reports go with the database. Copy anything wanted into `~/cases/` first.

## 7. As run

**2026-10-10/11, setup and the fence proof**
([#1166](https://github.com/Gerrrt/HomeLab/pull/1166)).

- **§1.** `apt-get install gvm` exited 0. `gvm-setup` exited 0 and created
  `admin`. `gvm-check-setup` reported "It seems like your GVM-25.04.0
  installation is OK", plus the empty-password-policy warning above.
  - Kali ships every GVM unit disabled at boot: `gsad`, `gvmd`,
    `ospd-openvas`, `notus-scanner`, PostgreSQL, `redis-server@openvas`,
    Mosquitto.
  - The feeds take about 2.6 GB (`/var/lib/gvm` 1.3 GB, `notus` 705 MB,
    `openvas` 638 MB). Running, GVM holds about 1.9 GB of RAM; stopped, that
    comes back.
  - The scan configs were empty for over an hour after setup, while gvmd
    imported SCAP, CERT and GVMD_DATA. The first proof attempt timed out
    waiting for *Discovery*, and the second waited it out.
- **§2.** `ospd-openvas`'s ControlGroup is
  `/system.slice/ospd-openvas.service`, as the rule names. Kali's
  `/etc/pam.d/sudo` includes `common-session-noninteractive`, which has no
  `pam_systemd`, so `sudo openvas` stays in that cgroup.
  - **The first start with the drop-in failed closed.** The service runs as
    `_gvm`, so `nft` ran as `_gvm` and got "Operation not permitted", and the
    scanner did not start. The drop-in now uses `ExecStartPre=+`, root for
    that one command only. The table then loaded against the service's
    cgroup, with its counter at 0.
- **§3, the proof, through GVM's API (`gvm-cli` on gvmd's socket).** The admin
  password was in a root-only temporary config, never on a command line.
  - The task: target `10.0.30.40` (`alexander`), *All IANA assigned TCP*,
    *Consider Alive*, the *Discovery* config, the default OpenVAS scanner.
    Ran 01:46:07 to 01:56:26 UTC, *Done*.
  - **Drop counter 0 → 11,681.** Every logged drop was `DST=10.0.30.40`, a
    TCP SYN from `eth0`.
  - **The report:** one host (assumed alive), **0 open ports**, 3 results.
    The task and the target were deleted.
  - **Then the log was rate-limited.** 11,681 kernel lines for one scan
    would flood the journal and Wazuh. The counter still counts every packet,
    and the log is now 5 a second.
  - **Re-checked from inside the cgroup.** A connection to `10.0.30.40:22`
    was refused (counter 0 → 5), and one to `10.0.30.50:135`, in scope,
    connected.
- **Stopped afterwards** with `gvm-stop` and §4's extra `systemctl stop`. All
  seven units inactive and disabled; about 850 MB of RAM back.
- **For Garrett:** change `admin`'s password in the UI (*My Settings*). The
  generated one is in `/root/gvm-install.log` on `garuda`, root-only. Delete
  that file once it is changed.
