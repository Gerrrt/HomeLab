# Runbook: Build the playground on gandalf

**Target:** `gandalf` — the second hypervisor, on ImaginationLAN (VLAN 30)
**Time:** an afternoon for the host and the bridges, then as long as you like
for the guests
**You will need:** the machine itself, one Cat6 patch to `neo`'s `ether20`, the pfSense web UI on `morpheus`, and a shell on the monitoring host for
the verification in §8

This builds the offensive range
[ADR-0007](../adr/0007-defensive-estate-and-offensive-range.md) called for,
inside the isolation
[ADR-0014](../adr/0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
decided, to the shape
[ADR-0017](../adr/0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)
bought. ADR-0014 says its constraints are "checked by the build runbook rather
than assumed"; §8 is that check, and it is the reason this file exists.

> [!CAUTION]
> **The isolation here is one click from failing, and the click is easy.** A
> target NIC attached to `vmbr0` instead of `vmbr1`, or a sysctl on the attack
> VM, puts a deliberately-vulnerable machine on the same segment as the estate's
> hypervisor and its BMC, with internet. ADR-0014 names this as the real cost of
> the decision. Nothing in the firewall stops it, because there is no rule to
> stop it with — §8 and §9 are what stand in for one, and they are worth
> rerunning after any change to a guest's hardware.

---

## 0. Before you start

ADR-0017 put three things ahead of this work, and **all three are done**.
This table read as three open to-dos until 2026-09-17, by which point two of
its rows had been closed for over a week; the third was met on 2026-09-27. The tracker for the buy and the build
is [#421](https://github.com/Gerrrt/HomeLab/issues/421); #96 closed on the
decision and on this runbook.

| | State | Why it is ahead of §1 |
| --- | --- | --- |
| [#101](https://github.com/Gerrrt/HomeLab/issues/101) — the defended estate on `Saruman` | **Met 2026-09-27.** The umbrella is not a thing anyone builds: what this waited on was the lab domain ([#414](https://github.com/Gerrrt/HomeLab/issues/414), six guests built and joined 2026-09-25) and the SOC stack — [#266](https://github.com/Gerrrt/HomeLab/issues/266) Wazuh and [#267](https://github.com/Gerrrt/HomeLab/issues/267) Velociraptor, in `stacks/soc/` on `odin` per [ADR-0030](../adr/0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md), both closed 2026-09-27 with the six agents reporting in | An attack VM pointed at an estate with no Wazuh, no Velociraptor and no domain teaches nothing. This is the half that carries the value |
| [#234](https://github.com/Gerrrt/HomeLab/issues/234) — the ImaginationLAN tripwire | **Armed and verified 2026-09-08**, and nothing here re-arms it. §8 and §9 assume it is already live | The only thing watching the boundary this build creates. It is a no-op until the segment holds attackers, which is what §5 makes it |
| [#235](https://github.com/Gerrrt/HomeLab/issues/235) — whether `shiva` stays on VLAN 30 | **Decided: it stays** ([ADR-0033](../adr/0033-keep-the-ilo-on-the-lab-segment.md)), **and the hardening that decision named was done 2026-09-09** — IPMI-over-LAN, SSH and iLO Federation off, the BMC's credential shared with nothing in the house, its security log read for a baseline, and the redundant `10.0.30.10 → 10.0.99.20/udp` return-path rule deleted from `morpheus`. Read [`SECURITY.md`](../../SECURITY.md)'s row for it rather than doing it again | Before §5 puts a Kali VM in its broadcast domain, the BMC already in that domain has to be the hardened one. A decision taken afterwards is taken under a fact that is already true |

The machine is ready too. `gandalf`, a refurbished ThinkCentre M80q, was
bought on 2026-10-05 and has its 32 GB and its SATA range disk
([ADR-0096](../adr/0096-fit-ifrits-range-disk-as-a-sata-ssd-in-the-tinys-bay.md))
fitted. **§1, §2 and §3 were done on 2026-11-07**
([#421](https://github.com/Gerrrt/HomeLab/issues/421)), and the parts as
fitted are in [`hardware.md`](../hardware.md). The node is named `gandalf`,
and `ifrit` names its disabled Intel AMT
([ADR-0106](../adr/0106-name-the-range-host-gandalf-and-leave-ifrit-to-its-disabled-amt.md)).

`gandalf` is on `neo`'s **`ether20`** and PDU outlet 8. The port was read on
2026-11-07: PVID 30, VLAN 30 untagged and nothing tagged, untagged frames
only, BPDU guard on. It does **not** hang off the MokerLink at U14, which
carries the two laptops on Winterfell.

The addresses this runbook uses, all decided in ADR-0017:

| | |
| --- | --- |
| `gandalf` on ImaginationLAN | `10.0.30.30/24`, gateway `10.0.30.1` |
| The attack VM's VLAN 30 leg | DHCP, from the `.100–.200` pool |
| The attack VM on the range bridge | `172.30.30.10/24`, no gateway |
| Targets | `172.30.30.100` upward, static, no gateway |

---

## 1. Rack, cable and install

One Cat6 from the machine's single NIC to `neo`'s `ether20`, untagged
VLAN 30. **No trunk, no tagged port**: ADR-0014 applies ADR-0007's
constraint on `Saruman` to `gandalf` by name, and lists a VLAN-aware bridge
here as a reason to reopen that ADR. Before plugging it in, read the port
from `neo`'s terminal:

```text
/interface bridge port print where interface=ether20
/interface bridge vlan print where vlan-ids=30
```

**You should see** `ether20` with `pvid=30`, and in VLAN 30's untagged list
and not its tagged one.

**Firmware first** (F1 at power-on). The box arrives with Windows on it.
Never set it up: power it off from the setup screen (Shift+F10, then
`shutdown /s /t 0`) and boot the installer instead.

- **Intel AMT off.** If the firmware prompts *"Found unconfigure of Intel(R)
  ME"*, answer Y. That wipes whatever provisioning the previous owner left.
  Then confirm *Intel Manageability* reads Disabled. ADR-0014 accounts for
  no management plane on this segment, and
  [ADR-0106](../adr/0106-name-the-range-host-gandalf-and-leave-ifrit-to-its-disabled-amt.md)
  keeps the name `ifrit` for this one in case it is ever turned on.
- **WLAN and Bluetooth off**, or pull the card. ADR-0017 allows one NIC, and
  `lspci` afterwards should list the I219 alone.
- **VT-x and VT-d on**, and *Configuration Change Detection* off.
- **After Power Loss: Power Off.** `gandalf` is off between sessions (§7),
  and nothing alerts when it is left on, so a power cut must not bring it
  back by itself. A session starts at the power button.
- Secure Boot can stay on, because the Proxmox VE 9 installer is signed.

Install Proxmox VE **onto the 256 GB M.2, not the SATA SSD**
([ADR-0096](../adr/0096-fit-ifrits-range-disk-as-a-sata-ssd-in-the-tinys-bay.md)).
At the installer's target-disk step pick the M.2 by name, which it shows as
the `nvme` device, and leave the SATA drive unselected. ext4 is enough for a
root disk that holds nothing the range churns; the snapshots happen on the
other drive. Hostname `gandalf.matrix.elysium`, address `10.0.30.30/24`,
gateway and DNS `10.0.30.1`. Take the defaults otherwise.

Then make the SATA SSD the guest storage, because the installer does not.
From the node's shell, with the SSD's `by-id` name substituted. A used
drive may carry an old partition table: `wipefs -n` shows it, and
`wipefs -a` on that drive, and only that drive, clears it.

```bash
ls -l /dev/disk/by-id/ | grep -i ata- | grep -v part
wipefs -n /dev/sda
zpool create -o ashift=12 range /dev/disk/by-id/ata-<the SATA SSD>
pvesm add zfspool range --pool range --content images,rootdir --sparse 1
pvesm status
```

**You should see** `range` active beside `local` and the M.2's own
`local-lvm`. A single-disk pool with no redundancy is the point: ADR-0017
said "not a mirror", and the range is maintained by nobody. From here on,
**every template, the attack VM and every target gets its disk on `range`**:
pick it in the *Storage* field when creating each VM, and §6's `clean`
snapshot is then a ZFS snapshot on that pool. Nothing of the range goes on
the M.2.

**Cap ZFS's read cache.** The installer limits the ARC only when the root is
ZFS, and here it is not, so by default ZFS may take half of RAM: 16 GB of
the 32 the range's guests need. Four GiB is plenty for one pool:

```bash
echo 'options zfs zfs_arc_max=4294967296' > /etc/modprobe.d/zfs.conf
echo 4294967296 > /sys/module/zfs/parameters/zfs_arc_max
update-initramfs -u -k all
```

Then switch the repositories to *No-Subscription* (*gandalf → Updates →
Repositories*: disable both enterprise lines, add No-Subscription) and
upgrade. Leave the reboot until the end of §2, so that it tests that §2's
settings persist.

Record what you actually fitted in [`hardware.md`](../hardware.md). Run
`dmidecode -t memory`, `lsblk -d -o NAME,SIZE,MODEL,TRAN` and
`smartctl -A /dev/sda` on the host, so the record is what the host reads and
not the order. The memory, the disk and the SATA drive's wear are written
down afterwards, the same split
[ADR-0016](../adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
used for the NAS.

---

## 2. The two bridges

`/etc/network/interfaces` on `gandalf`. Proxmox VE 9 names the I219 `nic0`
(`ip -br link` says so). Keep the installer's file as
`/root/interfaces.installer`, write this one, and `ifreload -a`:

```text
auto lo
iface lo inet loopback

iface nic0 inet manual
        post-up /sbin/ethtool -K nic0 tso off gso off

auto vmbr0
iface vmbr0 inet static
        address 10.0.30.30/24
        gateway 10.0.30.1
        bridge-ports nic0
        bridge-stp off
        bridge-fd 0

auto vmbr1
iface vmbr1 inet manual
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        pre-up sysctl -q -w net.ipv6.conf.vmbr1.disable_ipv6=1

source /etc/network/interfaces.d/*
```

Two things in there are load-bearing and neither is obvious:

- **`bridge-ports none` on `vmbr1`.** This is the isolation. It is not a filter
  and there is nothing to configure — the bridge has no path to a physical
  interface, so a guest on it can reach the other guests on it and nothing else.
- **`iface vmbr1 inet manual`, and IPv6 off on `vmbr1`.** The host takes no
  address on the range subnet, in either family. Give `vmbr1` an address and
  the hypervisor (the box whose management plane §4 closes) becomes a live
  host on the segment holding the vulnerable machines, and their only
  unreachable neighbour stops being unreachable. `inet manual` covers IPv4
  only. Linux gives every interface that comes up an IPv6 link-local address,
  and an `fe80::` address on `vmbr1` is an on-link endpoint every target can
  reach without a gateway. The `pre-up` line stops that.

The `post-up` line is not isolation. It is the usual workaround for the
I219's e1000e transmit hang under load, which would take the range's one
link down mid-session.

```bash
ip -br addr show
ip addr show dev vmbr1 | grep -c inet
ethtool -k nic0 | grep -E 'tcp-segmentation-offload|generic-segmentation-offload'
```

**You should see** `vmbr0` with `10.0.30.30/24`, and **`vmbr1` with no
address at all**: the `grep -c` prints `0`, so no `inet` and no `inet6`.
`UNKNOWN` is what an empty bridge reports. Both offloads should read `off`.

Then reboot once, which also picks up §1's kernel, and run the same
commands again, with
`cat /sys/module/zfs/parameters/zfs_arc_max; zpool status -x`. Nothing above
should have changed. The ARC cap should read `4294967296` and the pool
should be healthy. On 2026-11-07 the offloads, the ARC cap and the pool held
across the reboot. `vmbr1` still had an `fe80::` address after that
reboot. The `pre-up` line was added the same day, from review, and after
`ifreload -a` the `grep -c` read `0`.

Then add the reservation for `10.0.30.30` on `morpheus` alongside the other
ImaginationLAN statics. `.30` is below `.100` and therefore outside the Kea
pool, so unlike `Saruman`'s the reservation is not what protects the address —
it is there so the address is recorded where a reader looks for it, and so the
protection does not depend on the pool never moving.

---

## 3. Move `Saruman` to `10.0.30.20`

> **Ran on 2026-11-07** ([#421](https://github.com/Gerrrt/HomeLab/issues/421)).
> `Saruman` is at `10.0.30.20`, and every path below was checked over the
> new address. The steps are kept as the record of how it was done, and they
> have the shape to follow if the hypervisor's address ever moves again.

ADR-0014 requires this "at the same time". At `.110`, `Saruman` was the one
fixed address in the estate inside a DHCP pool, and the attack VM leases from
that pool. Kea's reservation kept the address safe only because Kea consults
reservations on every allocation.

The runbook first listed two things that name the address: the Alloy pass
and the ISO store's pass and export. **There were six.** The NUT pass, the
host firewall's `local_network` alias, the API certificate, `phoenix`'s
endpoint and the Mac's `known_hosts` all named it as well. The alias is the
one with a security cost. Left at `.110`, it would put whatever leased
`.110` next into Proxmox's `management` set, as §4 explains, and that could
be the attack VM.

**Add the `.20` paths before you move the address, and remove the `.110`
ones only after it moves.** That way nothing breaks at the cutover.

1. **Before you start.** Check that `.20` is free: from `morpheus`, it should
   not answer a ping and should have no ARP entry. Then, on `Saruman`, copy
   `/etc/network/interfaces`, `/etc/hosts` and
   `/etc/pve/firewall/cluster.fw` to `/root/`. Record a baseline:
   - the `host` list in Loki (step 6);
   - `ssh admin@10.0.99.1 'upsc -c mjolnir@localhost'`;
   - `pvesm status --storage smaug-iso`;
   - the running guests in `qm list`.
2. **The ImaginationLAN rules on `morpheus`.** Copy each of these rules
   with source `10.0.30.20`, and place each copy directly under its original:
   - the Alloy passes to `10.0.99.20`, on 9090 and 3100, with **logging
     off**. They are documented in
     [`add-monitored-device.md`](add-monitored-device.md). If you log them,
     every push the agent makes counts as a tripwire hit;
   - `Allow NUT from Saruman` to `10.0.30.1:3493`;
   - `Allow NFS from Saruman to smaug` to `10.0.40.30:2049`.

   Every copy must sit above its block rule. `pfctl` matches the first rule
   that fits, so check the order with
   `pfctl -sr | grep -n "on igc0.30"`. On `smaug`, add `10.0.30.20` to the
   `erebor/iso` share's authorized hosts. On `morpheus`, change `Saruman`'s
   Kea reservation to `10.0.30.20`.
3. **Change the address.** Edit `/etc/hosts`,
   `address` under `vmbr0` in `/etc/network/interfaces`, and
   `local_network` in `/etc/pve/firewall/cluster.fw`. `/etc/pve` is the
   cluster filesystem, so write the file with `cp`, not `sed -i`. Then:

   ```bash
   env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/sbin/ifreload -a
   ```

   **The `env -i` is needed.** `ifreload` starts with
   `#!/usr/bin/env python3`, and root's dotfiles put mise's Python first on
   the PATH. That Python has neither Debian's `python3-systemd` nor
   ifupdown2's library path, so a plain `ifreload -a` dies with
   `ModuleNotFoundError` and changes nothing. Boot is not affected, because
   `networking.service` runs with systemd's default PATH.
   `ifquery vmbr0`, under the same `env -i`, reads the new stanza back
   without applying it.

   **Any SSH session, and any Proxmox web Shell, connected to `.110` drops
   at this point.** Restarting `pveproxy` also drops the web Shell. Use the
   iLO console, or reconnect to `.20`. The host key is unchanged, and the
   client says so: it reports the key as already known under another
   address.
4. **Reissue the API certificate** from the new `/etc/hosts`:
   `pvecm updatecerts --force && systemctl restart pveproxy`. `phoenix`
   verifies TLS, so the certificate's names must include `10.0.30.20`:

   ```bash
   echo | openssl s_client -connect 10.0.30.20:8006 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName
   ```

   Then check three more things:
   - `qm list` shows the same running guests as before;
   - after a minute, `tc filter show dev vmbr0 egress` shows the Zeek
     mirror again;
   - `pve-firewall localnet` reports `local_network: 10.0.30.20`.
5. **Change the clients.** In `~/.config/proxmox/phoenix.env` on
   `phoenix`, change `PROXMOX_URL` and `PROXMOX_VE_ENDPOINT`, then rerun the
   API check in [`provision-lab-guests.md`](provision-lab-guests.md) §1. It
   must return `200` with TLS verified. On the Mac, run
   `ssh-keygen -R 10.0.30.110` and update the host's entry in the SSH
   config. Nothing on VLAN 99 can SSH to `Saruman`, so `prometheus` has no
   `known_hosts` entry to update.
6. **Check every path over `.20`.** This list should still include the
   hypervisor:

   ```bash
   curl -s http://localhost:3100/loki/api/v1/label/host/values | jq -r '.data[]'
   ```

   `host` is `constants.hostname` as the agent sees it, so read the value
   out of the list rather than assert one. See
   [`ship-firewall-logs.md`](ship-firewall-logs.md) for why that label means
   something different on relayed logs. Also check:
   - `pfctl -ss` shows states from `.20` to `10.0.99.20`;
   - `upsc -c mjolnir@localhost` lists `10.0.30.20`;
   - after `umount /mnt/smaug-iso && mount /mnt/smaug-iso`, `smaug-iso` is
     `active`;
   - `8006` answers from Hicks and is refused from `morpheus`.

   A broken rule looks exactly like a host that is down.
7. **Remove the `.110` paths.** Delete the four `.110` rules and remove
   `.110` from the share, then run step 6 again. The copies were left with
   `(.20)` at the end of their descriptions.
8. **The documents.** Wherever a current-state document names the address,
   update it. ADRs that quote it get a note rather than an edit, per
   [ADR-0001](../adr/0001-record-architecture-decisions.md). Dated records
   are left alone: the changelog, `roadmap.md`'s Done entries and dated log
   rows.

---

## 4. Close the management plane

> **Ran on `Saruman` 2026-09-20**
> ([#566](https://github.com/Gerrrt/HomeLab/issues/566)), out of order with the
> rest of this runbook and ahead of `gandalf`, because
> [ADR-0042](../adr/0042-terminate-the-remote-path-on-the-lab-and-route-it.md)'s
> remote path was about to put a device that is not on Hicks in front of this
> hypervisor's login page. Everything below was found by doing it. `gandalf` gets
> the same treatment when it is built, including the alias.

ADR-0014: the Proxmox firewall on `Saruman` and on `gandalf` admits `8006`,
`8007` and `22` from `10.0.50.0/24` only. This is the one gap the design opens —
an attacker sharing a broadcast domain with a hypervisor — and it is closed on
the host rather than at a segment boundary, because there is no boundary between
them.

> [!CAUTION]
> **Enable with a permissive policy first, then flip it.** `pve-firewall
> compile` renders *nothing* while the firewall is disabled — empty cmdlists
> and `firewall disabled` — so "write the files and check the rules render"
> cannot be done from the off state. The order that works is: write `host.fw`,
> enable with `policy_in: ACCEPT`, read the rules back, and only then set
> `DROP`. A `DROP` policy with the rules unrendered locks you out of a machine
> whose console is a KVM switch away. Have the console to hand; `pve-firewall
> stop` is the way back.

`/etc/pve/nodes/<NODE>/host.fw`, where `<NODE>` is the name **exactly as
`pvesh get /nodes` prints it** — `Saruman` is capitalised and `gandalf` is not. A
mis-cased path is a file Proxmox never reads, which is a rule set that silently
does not exist:

```ini
[OPTIONS]
enable: 1

[RULES]
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8006 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 8007 -log nolog
IN ACCEPT -source 10.0.50.0/24 -p tcp -dport 22 -log nolog
```

On `Saruman` there is a fourth line, admitting the deployment host to the API
and to nothing else
([ADR-0043](../adr/0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)):

```ini
IN ACCEPT -source 10.0.30.70 -p tcp -dport 8006 -log nolog
```

`8007` is Proxmox Backup Server and nothing on `gandalf` listens on it — ADR-0017
gives the range no backups. The rule is written as ADR-0014 specifies rather
than narrowed here; ADR-0017's Consequences record that it admits nothing.

### The rule nobody wrote, and it is wider than the ones you did

**This is the step that makes the difference between ADR-0014 being true and
merely being written down.** Proxmox detects a "local network" from the node's
own address, puts that CIDR in a `management` IP set, and gives the set five
RETURN rules in the host input chain. `Saruman` is `10.0.30.20/24`, so the
detected value was **the entire lab segment** — and with `policy_in: DROP` in
place, every address on VLAN 30 still reached the GUI, SSH, the VNC range, the
SPICE proxy and the migration range. ADR-0014's three rules were redundant
against it, and nothing about the ruleset looked wrong.

Read what it detected:

```bash
pve-firewall localnet
```

`using detected local_network: 10.0.30.0/24` is the finding. Override it in
`cluster.fw`, which is where the alias belongs:

```ini
[OPTIONS]
enable: 1
policy_in: ACCEPT

[ALIASES]
local_network 10.0.30.20
```

Use the node's own address, and check that `localnet` now reports it as user
defined. This estate runs no Proxmox cluster
([ADR-0039](../adr/0039-decline-proxmox-clustering-while-ifrit-is-the-range.md)),
so the detected `/24` bought nothing at all; Proxmox's own documentation
advises assigning the address explicitly for a single host on a network it does
not trust, and here that network is the one built to hold an attacker.

What narrowing withdraws from the segment, and why each is right to lose:

| Port | What it is | After |
| --- | --- | --- |
| 8006 | Web UI and console proxy | Open, by ADR-0014's rule and ADR-0043's |
| 22 | SSH | Open from Hicks, by ADR-0014's rule |
| 5900-5999 | Direct VNC | Closed — the browser console rides 8006 |
| 3128 | SPICE proxy | Closed — no SPICE client in the estate |
| 60000-60050 | Cluster migration | Closed — ADR-0039 declined clustering |

ADR-0014 granted three ports. This is what stops the box from quietly granting
eight.

**Then turn the firewall off on every guest NIC** (`firewall=0`, or the
checkbox clear in the hardware tab). This is what makes ADR-0014's "guests are
unaffected" true rather than assumed: the datacenter-level enable above is what
brings the per-NIC flag to life, and that flag is set by default on any NIC
added through the GUI. A range whose hypervisor quietly filters its own guests
is a range that lies to you about what your tooling did — and the isolation
here is the bridge, not the guest firewall, so clearing it costs nothing.

> [!WARNING]
> **Do not retype `--net0` by hand.** `qm set` replaces the whole option, and a
> value without the MAC makes Proxmox mint a new one — which breaks that
> guest's DHCP reservation and the OUI column in
> [`network.md`](../network.md). Read the current value and append to it:
>
> ```bash
> for id in 140 170; do cur=$(qm config $id | sed -n 's/^net0: //p'); case "$cur" in *firewall=*) echo "$id already set";; *) qm set $id --net0 "$cur,firewall=0";; esac; done
> ```
>
> An absent `firewall=` key already means off. Setting it explicitly is so that
> a later edit in the GUI cannot flip it back without the diff showing.

### Only now, the flip

Set `policy_in: DROP`, keep the alias, and read the chain back rather than
trusting the file:

```bash
pve-firewall status
pve-firewall compile | sed -n '/^exists PVEFW-HOST-IN/,/^exists PVEFW-HOST-OUT/p'
```

Four things to see. `enabled/running`. The three or four explicit RETURN rules.
The `management` rules now reachable only by the node's own address. And a
trailing `-j PVEFW-Drop` where a bare `-j RETURN` used to be, which is the
policy in force. The IPv6 chain keeps its neighbour-discovery RETURNs above the
policy, so address resolution survives the `DROP`.

Then prove it from off the host. `10.0.30.1` is `morpheus`, which is on this
segment and is not Hicks, so it is the right prober; a second probe to a host
that should answer keeps a broken `nc` from reading as a closed port:

```bash
ssh admin@10.0.99.1 'nc -z -w 3 10.0.30.20 8006; echo "8006 exit=$?"; nc -z -w 3 10.0.30.40 3100; echo "control exit=$?"'
```

Expect `8006 exit=1` and `control exit=0`. Then confirm the hypervisor's own
telemetry is unaffected — `policy_in` does not touch outbound, and this agent
remote-writes rather than being scraped:

```promql
up{instance="Saruman"}
```

**Capitalised**, like the node. `instance="saruman"` matches no series and
reads as a failure when nothing is wrong. Both jobs, `Saruman-metrics` and
`Saruman-alloy`, should be at `1`.

**Then that it stays on.** The probe above is a thing a person does once, and
the ordinary ways the firewall goes off again — a `pve-firewall stop` while
debugging a guest, an upgrade rewriting `/etc/pve/firewall`, a rebuild that
skips this section — page nothing on their own. Install the collector that
reads it ([#576](https://github.com/Gerrrt/HomeLab/issues/576)):

```bash
make install-agent-collectors AGENT=root@10.0.30.20 ARGS='--only pve-firewall-state'
```

and read it back on `prometheus`:

```promql
homelab_pve_firewall_enabled{host="Saruman"}
homelab_pve_firewall_policy_drop{host="Saruman"}
homelab_pve_firewall_rules{host="Saruman"}
```

| Series | Expect | If not |
| --- | --- | --- |
| `homelab_pve_firewall_enabled` | `1` — `pve-firewall status` reads `enabled/running` | `PveFirewallDisabled` pages after ten minutes; this section is the way back |
| `homelab_pve_firewall_policy_drop` | `1` — `cluster.fw`'s `policy_in` is `DROP` after the flip above | `0` is the firewall on with no wall behind the rules. `PveFirewallPolicyAccept` pages after ten minutes, so do the flip inside that window |
| `homelab_pve_firewall_rules{file="host"}` | `4` on `Saruman` (ADR-0014's three and ADR-0043's one), `3` on `gandalf` | Fewer is a rule file that did not survive; `0` with the firewall on means the `policy_in` decides everything |
| `homelab_pve_firewall_rules{file="cluster"}` | `0` — `cluster.fw` carries the enable and the alias, not rules | Not a fault on its own; say why in the build notes if it changes |

Prove the alert once, on purpose, with the console to hand: `pve-firewall
stop`, wait for `PveFirewallDisabled` to fire (about fifteen minutes, with the
five-minute timer), then `pve-firewall start` and watch it resolve. A rule that
has never fired is a rule nobody knows can.

---

## 5. The attack VM

One VM, and it is the only guest with a leg on both bridges.

- **Its disk on `range`**, the SATA SSD's pool from §1, like every guest here.
- **`net0` on `vmbr0`** — ImaginationLAN, DHCP from the pool. Nothing points at
  this address, so it does not get a reservation.
- **`net1` on `vmbr1`** — `172.30.30.10/24`, **no gateway**.

Forwarding off, persistently. `/etc/sysctl.d/99-no-forward.conf`:

```ini
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
```

`sysctl --system` to load it, and note the trap: **installing Docker sets
`ip_forward=1` at daemon start**, whatever this file says, and it will do it
again on every boot. If the attack VM needs containers, the file is not enough
and §8's check is what tells you.

No NAT. There is nothing to configure to achieve that — the point is to confirm
nothing has configured it, which §8 does.

Scope the tooling on the VM itself, per ADR-0014: scans and sweeps are bounded
to `10.0.30.0/24` and `172.30.30.0/24`. "That is where a mis-scoped scan is
actually stopped — at the tool, not at a segment boundary that would let it
through on 443 anyway."

**What a Hicks workstation reaches on this machine** — write it down as you
build it, because [#228](https://github.com/Gerrrt/HomeLab/issues/228) cannot
narrow `50 → 30` without the list: Proxmox on `10.0.30.30:8006`, the C2
operator's interface on the attack VM, and whatever the lab's Grafana and RDP
into the estate already need on `Saruman`.

---

## 6. The targets

Each target attaches to **`vmbr1` and nothing else**, keeps its disk on
**`range`** (§1), takes a static address from `172.30.30.100` upward, and has
**no default route**. Every image insisting
on DHCP gets a static override before its first boot on the bridge — ADR-0017
declines to run a DHCP server here, because the obvious place to run one is the
dual-homed VM, and a DHCP server that binds the wrong interface there is rogue
DHCP on the segment holding the estate's hypervisor and its BMC.

Take a snapshot named `clean` before the first session and revert to it after
every one. The images in use are a working list and belong here rather than in
an ADR; they are expected to churn, are never patched, and are never backed up.

**A guest that acquires a domain join, a real user or a monitoring agent has
stopped being a target and become part of the estate** — which lives on
`Saruman`, where it is instrumented. That is ADR-0007's judgement turned into a
placement rule, and it is the question to ask before adding anything here.

---

## 7. Powering the range

`gandalf` is off between sessions. There is no alert for it being left on, and
ADR-0017 says why: every rule shape available says "this host is down", which is
the normal state. Nothing is watching, so the discipline is yours.

```text
on  → revert every target to `clean` → work → revert → off
```

---

## 8. Check the four properties

ADR-0014 makes four claims. Each one is checkable, and none of them is checked
by anything else in this repository.

**One — `gandalf` is single-homed, and `vmbr1` has no port.** On the host:

```bash
ip -br link show type bridge
bridge link show
```

`vmbr0` should carry exactly one physical interface. `vmbr1` should appear in
the first command and contribute **nothing but guest taps** to the second.
`ip addr show dev vmbr1 | grep -c inet` should print `0`: the host has no
address on the range in either family (§2). A
physical NIC name under `vmbr1` is the failure this whole design is built to
avoid.

**Two — no trunk, no VLAN-aware bridge.**

```bash
grep -cE 'bridge-vlan-aware|bridge-vids' /etc/network/interfaces
```

Zero. Anything else and ADR-0014 has been reopened without an ADR saying so.

**Three — the attack VM does not forward, and does not NAT.** On the VM:

```bash
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
nft list ruleset 2>/dev/null | grep -Ei 'masquerade|snat' || echo "no NAT"
iptables -t nat -S 2>/dev/null | grep -- '-j MASQUERADE' || echo "no legacy NAT"
```

Both sysctls `= 0`, and no NAT from either table — Kali's `iptables` is
nft-backed, so the two commands can disagree about a rule that exists. Run this
after installing anything that touches the network stack, not just once.

**Four — a target has no route anywhere.** On a target:

```bash
ip route
ping -c1 -W1 10.0.30.1
ping -c1 -W1 1.1.1.1
```

No `default` line in the first, and both pings failing with *Network is
unreachable* rather than timing out. A timeout means a default route exists and
something is swallowing the packets, which is a different and much worse state:
it is a filtered target rather than an unrouted one.

---

## 9. Prove that a leak reports itself

ADR-0014 claims a specific safety property: the target subnet was chosen so that
a forwarded packet "arrives at the firewall with a source outside
`10.0.30.0/24`, misses the `→ any` pass, hits default deny and is logged as a
block. A leak reports itself."

That is worth proving once, and it can only be proved by causing one. **Do this
with a throwaway Linux guest on `vmbr1`, before any vulnerable image exists on
the machine.**

1. On the attack VM, turn forwarding on for the test only —
   `sysctl -w net.ipv4.ip_forward=1`. Add **no** NAT: without it nothing comes
   back, which is what keeps this bounded.
2. On the throwaway guest, add a default route via `172.30.30.10` and send
   something outbound: `ping -c3 1.1.1.1`.
3. On the monitoring host, look for the block:

   ```bash
   curl -sG http://localhost:3100/loki/api/v1/query \
     --data-urlencode 'query=sum by (src) (count_over_time({app="filterlog", action="block"} | regexp `,(?P<src>\d+\.\d+\.\d+\.\d+),(?P<dst>\d+\.\d+\.\d+\.\d+),` | src =~ "172\\.30\\.30\\..+" [15m]))' \
     | jq '.data.result'
   ```

   A row with a `172.30.30.x` source is the property working. **An empty result
   is not a pass** — it means the leak was silent, and you should find out
   whether the packet was forwarded at all before concluding anything.
4. Turn forwarding back off, remove the route, delete the guest, and rerun §8's
   third check.

Addresses are parsed at query time rather than indexed, per
[ADR-0003](../adr/0003-observability-stack-selection.md), which is why this is a
`| regexp` over a metric query and not a label selector.

---

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| Locked out of the Proxmox UI after §4 | `policy_in: DROP` with the rules unrendered, or reaching it from somewhere other than Hicks | Console via the KVM; `pve-firewall stop` |
| §4 done, and the whole segment still reaches `8006` | The `local_network` alias was not narrowed, so the auto-detected `/24` is in the `management` IP set | `pve-firewall localnet`; §4's alias block |
| `pve-firewall compile` prints nothing but `firewall disabled` | It renders only while enabled, so this is the off state rather than a broken file | Enable with `policy_in: ACCEPT` first, per §4's CAUTION |
| `up{instance="saruman"}` returns no data after §4 | The label is capitalised; the series is `Saruman` | Not a firewall problem. Outbound is unaffected by `policy_in` |
| A target can reach the internet | Its NIC is on `vmbr0` | Move it to `vmbr1`, then §8 and §9 |
| A target can reach `10.0.30.x` but not the internet | The attack VM is forwarding | §8, check three. Look for Docker |
| The attack VM's tools see nothing on VLAN 30 | The guest firewall flag is still set on `net0` | Clear it — end of §4 |
| Everything on `vmbr1` can reach everything else and nothing outside | Working as designed | — |
| `Saruman` stops appearing in Loki after §3 | The pass rule still names `.110` | §3, step 2 |
| Kea hands `10.0.30.30` to something else | The reservation was not added | §2 |
| The §9 query returns nothing | Either the leak never happened, or firewall logs are not arriving | Check the pipeline first: [`ship-firewall-logs.md`](ship-firewall-logs.md) §7 |

---

## Also worth knowing

**The range is not monitored and not backed up, and both are decisions.**
ADR-0017 declines an Alloy agent because `gandalf` is off by design, so any rule
watching it is permanently firing or permanently silenced; and it declines PBS
because a deliberately-vulnerable image in the estate's backup store is a
supported path for it to arrive somewhere it should not be. If you find yourself
wanting to back something up here, the thing you want to keep has stopped being
range and started being estate, and it is on the wrong machine.

**The tripwire is the only thing watching.** `pass` + `log` for
`vlan30 net → Internal_Segments` on the ImaginationLAN interface, below the
blocks and the `quick` iLO pass, above the `→ any` egress rule
([#234](https://github.com/Gerrrt/HomeLab/issues/234)). It matches nothing while
this design holds. **A line in it is an incident**, not a tuning exercise:
ADR-0014 says the segment that holds attackers has reached the house, and that
the ADR was wrong somewhere.

**Reaching in is still wholesale.** A Hicks workstation reaches all of VLAN 30
on every port, because the Hicks interface blocks 40/20/10 and then passes to
`any` ([ADR-0013](../adr/0013-segment-access-as-implemented.md)). Once this
build exists, that path enters hostile layer 2: the lab domain gets its own
credentials, and none of the house's.
