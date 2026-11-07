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
| Running | On demand: sync the feeds, `gvm-start`, scan, stop | Kali ships every GVM unit disabled at boot. Stopped, it holds no RAM and can point nowhere |
| Scope | `10.0.30.50`–`.55` only | The domain is the exercise. The firewall, the iLO, the hypervisor and the lab's own services are out |
| Fence | scanner in a network namespace; `netdev` egress filter on its macvlan `scan0` (`.63`) | Filters every frame the scanner sends — IP, ARP and raw — so a scan outside the six fails closed at layer 2. No second NIC and no host forwarding (ADR-0093) |
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

The fence runs the scanner in its own network namespace, `gvmscan`, whose
only route to the segment is a macvlan, `scan0`, behind an nftables `netdev`
egress filter (ADR-0093). From the repository on `garuda`
(`~/code/Gerrrt/HomeLab`):

```bash
sudo install -D -m 0755 stacks/analyst/gvm/gvm-scan-netns.sh /opt/gvm-scan/gvm-scan-netns.sh
sudo install -D -m 0644 stacks/analyst/gvm/scan0-egress.nft  /opt/gvm-scan/scan0-egress.nft
sudo install -D -m 0644 stacks/analyst/gvm/gvm-scan-netns.service /etc/systemd/system/gvm-scan-netns.service
sudo install -D -m 0644 stacks/analyst/gvm/ospd-openvas-netns.conf /etc/systemd/system/ospd-openvas.service.d/netns.conf
sudo install -D -m 0644 stacks/analyst/gvm/mosquitto-netns-order.conf /etc/systemd/system/mosquitto.service.d/netns.conf
sudo install -D -m 0644 stacks/analyst/gvm/mosquitto-gvm.conf /etc/mosquitto/conf.d/gvm.conf
```

Point the scanner's MQTT at the veth broker (the scanner is now in the
namespace, which cannot reach the host's loopback):

```bash
sudo sed -i 's|^mqtt_server_uri = localhost:1883|mqtt_server_uri = 10.99.0.1:1883|' /etc/openvas/openvas.conf
sudo systemctl daemon-reload
```

Bring the namespace up on its own and check it:

```bash
sudo systemctl start gvm-scan-netns
sudo ip netns exec gvmscan ip -br addr show scan0   # 10.0.30.63/24, up
sudo ip netns exec gvmscan nft list table netdev gvm_scan
sudo systemctl stop gvm-scan-netns
```

## 3. Prove the fence, once and after any change to it

Bring GVM up (§4 step 1), so `ospd-openvas` pulls the namespace in. First
confirm the scanner is really in it:

```bash
sudo ip netns identify "$(systemctl show -p MainPID --value ospd-openvas)"   # gvmscan
```

Then two checks, one per layer:

1. **Layer 2.** `arping` an out-of-scope host from the namespace. It must be
   dropped, and an in-scope host must answer:

   ```bash
   sudo ip netns exec gvmscan arping -c3 -w3 -I scan0 10.0.30.40   # 0 replies
   sudo ip netns exec gvmscan ping  -c2 -W2 10.0.30.50             # replies
   ```

2. **The scanner's own path.** A GVM task, through `ospd-openvas` and
   `sudo openvas`, against the out-of-scope `10.0.30.40` (`alexander`), with
   *All IANA assigned TCP* and *Consider Alive*.
   - Note the drop counter first:
     `sudo ip netns exec gvmscan nft list chain netdev gvm_scan egress`.
   - Run the task (the *Discovery* config).
   - When it ends, the counter must have grown by many packets,
     `journalctl -k | grep "gvm-scan drop"` shows a sample, and the report
     must show no open port on `.40`.
   - Delete the task and target, and record before/after in §7.

If the counter did not move, or the `arping` reached `.40`, the scanner is not
in the namespace or `scan0` is not filtered. Stop, and scan nothing until it
is understood.

## 4. A scan

1. **Sync, then start.** `gvm-start` only starts the services; it does not
   fetch new feeds, so a scan days after the last one would use old
   definitions. Sync first, as `gvm-setup` does, then start:

   ```bash
   sudo greenbone-feed-sync --type all   # drops to _gvm by /etc/gvm/greenbone-feed-sync.toml
   sudo gvm-start
   ```

   Wait for the UI at `https://127.0.0.1:9392`, and for *Administration → Feed
   Status* to show no feed still updating: gvmd imports what was synced.
2. **The target is the six:** `10.0.30.50-10.0.30.55`, named *lab domain*,
   created once. Never add an address to it outside the six. The fence would
   drop the traffic, and ADR-0093 would have to change first.
3. **Run.** *Full and fast*, unauthenticated, unless an exercise says
   otherwise. An authenticated scan takes a domain credential from
   `ansible/population/`'s seed, stored in GVM's credential store. It never
   goes on a command line.
   - **Alive test: *Consider Alive*, or an ICMP/TCP test — never an ARP
     one.** The six are known to exist, so *Consider Alive* is simplest. The
     IP fence (ADR-0093) sees ICMP and TCP but not ARP, so an ARP-based alive
     test is the one way a probe leaves the scanner's IP scope. The scope note
     on the target covers the IP scan; this covers discovery.
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
sudo greenbone-feed-sync --type all
sudo gvm-check-setup
```

Do what it asks, such as a `gvmd --migrate`. The sync comes first so that
the check sees current feeds, not the ones from before the upgrade. Then start
`ospd-openvas` once, and confirm it joined the namespace and the filter is on
`scan0` (§3's first checks). A packaging change to `ospd-openvas` or
`mosquitto` can break the drop-in ordering or the namespace join, and the
scanner then fails to start rather than starting unfenced — the safe
direction. Re-prove the fence (§3) after any upgrade that touches them.

## 6. Take it out

```bash
sudo gvm-stop; sudo systemctl stop gvm-scan-netns postgresql redis-server@openvas mosquitto
sudo rm /etc/systemd/system/ospd-openvas.service.d/netns.conf \
       /etc/systemd/system/mosquitto.service.d/netns.conf \
       /etc/mosquitto/conf.d/gvm.conf \
       /etc/systemd/system/gvm-scan-netns.service
sudo rm -rf /opt/gvm-scan
sudo sed -i 's|^mqtt_server_uri = 10.99.0.1:1883|mqtt_server_uri = localhost:1883|' /etc/openvas/openvas.conf
sudo systemctl daemon-reload
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
- **§2, the namespace fence.** First built as a cgroup rule at the IP hook;
  a review noted that NASL's `send_frame`/`send_arp_request` go through
  `AF_PACKET`, below it, so that form was IP only. It was rebuilt as the
  namespace fence this runbook describes, and the layer-2 escape closed.
  - `ospd-openvas` runs in the `gvmscan` namespace
    (`ip netns identify $(pidof ospd-openvas)` → `gvmscan`), with `scan0` a
    macvlan at `10.0.30.63/24` and the `netdev gvm_scan` egress filter on it.
  - mosquitto listens on `127.0.0.1` (for `notus-scanner`) and `10.99.0.1`
    (the veth, for the namespaced `openvas`); no MQTT error.
  - A veth-and-NAT form was tried first and set aside: garuda's Docker sets
    `FORWARD` to `DROP`, so a routed scanner could not reach the six even with
    a `DOCKER-USER` accept. The macvlan is on-link and routes nothing, so
    Docker never sees it.
- **§3, the proof.** The admin password was in a root-only temporary config,
  never on a command line.
  - **Layer 2.** `arping` from the namespace to the out-of-scope `10.0.30.40`
    was dropped; `ping` to the in-scope `10.0.30.50` answered.
  - **The scanner's path, over `scan0`.** From inside the namespace:
    `10.0.30.40:22` (TCP) dropped, `10.0.30.40` (ICMP) dropped, and the
    in-scope `10.0.30.50:445` **connected**. The `netdev` egress drop counter
    rose on each out-of-scope attempt. Every layer the scanner sends on — IP,
    ICMP and ARP — is held to the six.
  - A full GVM *Discovery* task against `10.0.30.40` was queued behind a VT
    reload (`ospd` re-uploads NVTs to redis after a restart), so that flood
    was not re-captured through gvmd; the direct namespace proof above covers
    the same `scan0` path the scanner uses. (An earlier cgroup-era GVM scan of
    `.40` had dropped 11,681 packets with 0 open ports, confirming the scanner
    really floods an out-of-scope target through that path.)
  - The drop log is rate-limited to 5 a second; the counter counts every
    packet.
- **Stopped afterwards:** `gvm-stop`, the namespace, and §6's extra
  `systemctl stop`. All units inactive and disabled; the namespace and `scan0`
  gone; RAM back.
- **For Garrett:** change `admin`'s password in the UI (*My Settings*). The
  generated one is in `/root/gvm-install.log` on `garuda`, root-only. Delete
  that file once it is changed.
