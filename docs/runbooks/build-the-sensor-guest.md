# Runbook: Build `fenrir`, the Zeek sensor on a mirror of the lab bridge

**Target:** `fenrir`, a guest on `Saruman` on ImaginationLAN (VLAN 30), plus
the mirror on `Saruman` that feeds it.

**Time:** about an evening. The reboot proof in §7 takes another half hour,
and it takes the whole lab down while it runs.

**You will need:**

- a shell on `Saruman` (root, SSH from Hicks, or the KVM or `shiva` for §1);
- an Ubuntu Server ISO;
- a checkout on a host that can SSH to `Saruman` as root, for §5;
- the estate's Alertmanager or Grafana, for §7.

**Before this:** the domain ([#414](https://github.com/Gerrrt/HomeLab/issues/414)),
built 2026-09-25. A sensor on a segment with one guest has nothing to say.

This builds what
[ADR-0068](../adr/0068-mirror-the-lab-bridge-to-zeek-with-tc-not-open-vswitch.md)
decided for [#437](https://github.com/Gerrrt/HomeLab/issues/437): Zeek on its
own guest, fed by a `tc` mirror of every port of `vmbr0`. The domain's
east-west traffic crosses no router, so Suricata on `morpheus` never sees it,
and nothing else in the estate does either.

It follows [`build-the-soc-guest.md`](build-the-soc-guest.md). Where a step is
the same, this runbook points there rather than keeping a second copy that
drifts.

---

## 0. What is decided, and why

| | Decision | Why this and not the obvious alternative |
| --- | --- | --- |
| Name | `fenrir` | Continues the segment's summons |
| Address | `10.0.30.90/24` | A static below `.100`, the next free decade after `golem`'s planned `.80` |
| VMID | `190` | The last octet is legible from `qm list`. `scripts/zeek-mirror.sh` and the collector default to it: the capture tap is `tap190i1` |
| NICs | **Two.** `net0` on `vmbr0` and `net1` alone on `vmbr1` | `net0` is the guest's own traffic, including its log shipping to `alexander`. `net1` receives only the mirror's copies and reaches nothing (ADR-0068) |
| Firewall | `firewall=0` on both | As on every guest here: the isolation is the bridge (`build-the-playground.md` §4). A Proxmox firewall bridge on `net1` would also put an `fwbr` between the tap and the mirror |
| vCPU / RAM | 4 / 8 GiB | Zeek is one process per interface, and the lab's traffic is a trickle beside what one core handles. Most of the RAM is page cache for the logs. It is a bound, and gets re-derived after a fortnight |
| Disk | **Two: 32 GB OS, 64 GB data**, both on `large_data` | The data disk at `/srv/sensor-data` holds the current logs and the hourly archive, kept for the retention `homelab-zeek-archive-prune` sets (§4). The lab's Loki keeps 360 h of what Alloy ships; the archive is the local copy for the days after that |
| Mirror | `tc`, not Open vSwitch | ADR-0068 |
| Role | **An appliance.** It holds the sensor stack, the agent collectors, the repository checkout `make up` deploys from, and the stack's age key, and nothing else | It sees every frame on `vmbr0`, on the segment built to be attacked, so taking it should give nothing beyond that traffic. No dotfiles, development packages, `gh` login, password manager or AI tooling: that work runs from Hicks, against `fenrir` over SSH. Decided 2026-11-17 |

## 1. The capture bridge, on `Saruman`

This adds a bridge. It does **not** touch `vmbr0` or the address the host is
reached on. Done on 2026-09-30, as written here.

**Use the system `PATH` for every ifupdown2 command.** `ifquery`, `ifup` and
`ifreload` are Python, and in a shell whose `PATH` puts another Python first
(mise, pyenv) they crash with `No module named 'systemd'` before doing
anything:

```bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
```

First, confirm the running network matches the file, so that nothing but the
new stanza is about to be applied:

```bash
ifquery --check -a
cp -p /etc/network/interfaces /etc/network/interfaces.bak-437
```

Every line must read `[pass]`. Then append to `/etc/network/interfaces`:

```text
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    ipv6-addrgen off
#   Zeek capture only (#437, ADR-0068). No port, no address, no VLANs.
```

**`ipv6-addrgen off` is not optional.** Without it the kernel gives `vmbr1` an
IPv6 link-local address the moment it comes up, and the hypervisor is then
reachable from the capture network. That breaks the "reaches nothing" the
ADR relies on. It happened on the first build and was removed the same
minute.

Then bring up **that bridge alone**, and check that nothing else moved:

```bash
ifup vmbr1
ip -br addr show vmbr0
ip -br addr show vmbr1
cat /proc/sys/net/ipv6/conf/vmbr1/addr_gen_mode
ls /sys/class/net/vmbr1/brif
ifquery --check -a
```

- `vmbr0` must still show `10.0.30.20/24`.
- `vmbr1` must show **no address at all**, not even an `fe80::`.
- `addr_gen_mode` must read `1`.
- `brif` stays empty until §2's VM starts.
- `ifquery --check` must pass for both bridges.

`ifup vmbr1` rather than `ifreload -a`, because `ifreload` re-applies the whole
file. If `vmbr0`'s stanza has been edited by hand since the last reload, that
edit would apply too, on the interface the host is reached through. `ifup`
touches the named interface only.

## 2. Create the VM

On `Saruman`. Every flag is as `alexander`'s §1 explains; only the numbers,
the second NIC and the ISO differ:

```bash
qm create 190 \
  --name fenrir \
  --ostype l26 \
  --cpu host --cores 4 --sockets 1 \
  --memory 8192 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 large_data:32,discard=on,iothread=1,ssd=1 \
  --scsi1 large_data:64,discard=on,iothread=1,ssd=1 \
  --net0 virtio,bridge=vmbr0,firewall=0 \
  --net1 virtio,bridge=vmbr1,firewall=0 \
  --agent enabled=1 \
  --onboot 1 \
  --ide2 local:iso/ubuntu-26.04.1-live-server-amd64.iso,media=cdrom \
  --boot order='scsi0;ide2'
```

`--onboot 1` is what makes §7 a test of the mirror and not of whether anyone
remembered to start the sensor.

## 3. Install Ubuntu Server

Follow `odin`'s §2, with **hostname `fenrir`** and address `10.0.30.90/24` on
the first NIC. Every log line this guest ships is labelled with the hostname.
Install onto the 32 GB disk only.

**The data disk** is `odin`'s §2 again, with `sensor-data` for `soc-data` and
64G for 96G. That includes the `chattr +i` guard on the empty mountpoint.
Then create the one directory the stack needs:

```bash
sudo install -d -m 0755 -o root -g root /srv/sensor-data/zeek
```

**The capture NIC.** The installer configures only the NIC it was given.
Bring the second one up with no address, so that it listens and never speaks:

```bash
ip -br link            # the second virtio NIC: normally ens19
sudo tee /etc/netplan/60-capture.yaml >/dev/null <<'YAML'
network:
  version: 2
  ethernets:
    ens19:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
YAML
sudo chmod 600 /etc/netplan/60-capture.yaml && sudo netplan apply
ip -br addr show ens19   # UP, and no address
```

If the name is not `ens19`, it changes in **every** place this section
names it:

- the netplan file above;
- `capture-offloads.service` below: its `BindsTo=`, `After=` and `ExecStart=`
  lines, and the `ethtool -k` check after it;
- `ZEEK_INTERFACE` in `stacks/sensor/.env`.

Missing the unit is the quiet failure. It fails to start, GRO stays on, Zeek
still runs, and host-bound flows show gaps again (#782).

**Turn off receive offloads on the capture NIC, and keep them off.** With GRO
on, the guest kernel holds a flow's data segments to merge them, but hands a
packet going the other way straight to Zeek. Saruman acknowledges data sent to
it within microseconds, so its ACK reaches Zeek before the data. Zeek then logs
a content gap on every busy flow to or from the hypervisor, even though nothing
was dropped. The first build ran at about 8% `percent_lost` this way.

```bash
sudo tee /etc/systemd/system/capture-offloads.service >/dev/null <<'UNIT'
# fenrir's capture NIC: no receive offloads (#437, ADR-0068).
#
# With GRO on, the kernel holds a flow's data segments to merge them but hands
# a packet of the opposite direction straight to the tap. Saruman ACKs data
# sent to it within microseconds, so its ACK overtook the held data and Zeek
# logged "ACK above a hole": a content gap on every busy host-bound flow,
# ~8% capture_loss, with nothing actually dropped. Zeek's own guidance is the
# same: no offloads on a capture interface.
[Unit]
Description=Disable receive offloads on the Zeek capture NIC (ens19)
BindsTo=sys-subsystem-net-devices-ens19.device
After=sys-subsystem-net-devices-ens19.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ethtool -K ens19 gro off rx-gro-hw off

# multi-user.target, not the device: Ubuntu 26.04's dracut initramfs brings
# ens19 up before switch-root, so its device unit is already active when the
# real system starts and a device-level Wants= is never pulled in. That was
# measured: the first version of this unit did not run on the first reboot.
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable --now capture-offloads.service
ethtool -k ens19 | grep -E 'generic-receive|rx-gro-hw'   # both: off
```

It hangs off `multi-user.target`, not the device. Ubuntu 26.04's dracut
initramfs brings `ens19` up before the real system starts, so a unit wanted by
the device never fires. Reboot once and check `ethtool` again.

**Keep `ens19` silent while it boots, too.** The netplan file takes effect only
once the real system is up. Before that, `ens19` speaks twice:

- **In the initramfs.** Ubuntu 26.04's dracut carries systemd-networkd and a
  catch-all, `zzzz-dracut-default.network`, that runs DHCP on every interface.
  `ens19` sends a DHCPv4 Discover with its MAC and the hostname, and IPv6
  duplicate-address detection and multicast listener reports. `ens18` takes a
  lease from the lab pool before the static `.90` applies.
- **Just after switch-root.** networkd brings `ens19` up, and the kernel gives
  it an IPv6 link-local address. netplan's `link-local: []` then removes it,
  but not before more multicast listener reports have gone out.

A capture on `tap190i1` from `Saruman` found nine such frames at the reboot of
2026-11-17. Nothing receives them, because `vmbr1` has no other port and no
address, but a sensor that announces itself is not one that only listens.
The root disk is local, so the initramfs needs no network at all. Leave it
out, the way dracut's own `no-network` profile does, and turn IPv6 off on
`ens19` before anything can bring it up. udev applies a sysctl for an
interface as the interface appears, so this one lands before networkd starts:

```bash
sudo tee /etc/dracut.conf.d/10-homelab-no-network.conf >/dev/null <<'CONF'
# fenrir: no networking in the initramfs (build-the-sensor-guest.md §3).
# The root disk is local. With systemd-networkd in the image, its catch-all
# DHCPs every interface, the capture NIC included, before netplan applies.
# Same line as dracut's own dracut.conf.d/no-network profile.
omit_dracutmodules+=" net-lib systemd-networkd "
CONF
sudo tee /etc/sysctl.d/60-capture-nic.conf >/dev/null <<'CONF'
# fenrir: the capture NIC never speaks IPv6 (build-the-sensor-guest.md §3).
# Applied by udev as ens19 appears, before networkd brings the link up.
net.ipv6.conf.ens19.disable_ipv6 = 1
CONF
ls /var/run/reboot-required 2>/dev/null && echo 'reboot first'
k="$(uname -r)"
sudo cp -p "/boot/initrd.img-$k" "/boot/initrd.img-$k.pre-no-network"
sudo update-initramfs -u -k "$k"
sudo lsinitrd -m "/boot/initrd.img-$k" | grep -E 'net-lib|systemd-networkd'   # nothing
```

If `reboot first` prints, the running kernel may not be the one the next boot
uses. Reboot, then run the last four lines, so that the image rebuilt and checked is
the one the next boot uses. On 26.04, `update-initramfs` is dracut's wrapper,
and every later kernel is built with the file in place.

`update-initramfs` prints `dracut[E]: Module 'dyn-netconf' depends on module
'systemd-networkd', which can't be installed`, here and at every later
kernel. That is the omit working, not a failure. `dyn-netconf` comes with
`cloud-initramfs-dyn-netconf`, which the ISO installs, and all it does is
configure the network in the initramfs. The `lsinitrd` line is the check.

The copy is the way back, and it does not depend on a second kernel being
installed. If the new image does not boot, open VM 190's console in the
Proxmox web UI (*Saruman → 190 → Console*; the VM has no serial port, so
`qm terminal` cannot reach GRUB). Reset the VM and hold Esc to show GRUB's
menu, which Ubuntu hides by default. Press `e` on the first entry, add
`.pre-no-network` to the end of the file name on the `initrd` line, and boot
with Ctrl-X. Then remove the dracut file and run
`sudo update-initramfs -u -k "$(uname -r)"` again. Once the proof below has
passed, delete the copy. To prove the result, reboot with a capture
running on `Saruman` that sees only frames `ens19` sends:

```bash
tcpdump -ni tap190i1 -Q in ether src "$(qm config 190 | sed -n 's/^net1: virtio=\([^,]*\).*/\1/p')"
```

Then, back on `fenrir`:

```bash
cat /sys/class/net/ens19/statistics/tx_packets     # 0
sysctl net.ipv6.conf.ens19.disable_ipv6            # 1
```

The capture must stay empty, and `tx_packets` must read 0.

Install `qemu-guest-agent` as `odin`'s §1 says. `qm guest exec 190 -- uptime`
from `Saruman` is the check. The agent is also what lets this guest's disks
page (ADR-0070): `qm guest cmd 190 get-fsinfo` should list `/` and
`/srv/sensor-data`.

**Make SSH key-only, for one user.** `fenrir` listens on `22` on the
segment that exists to hold attackers, and it has no host firewall to narrow
who reaches that port. The installer leaves
`/etc/ssh/sshd_config.d/50-cloud-init.conf` behind, and that file can set
`PasswordAuthentication yes`. `sshd` keeps the **first** value it reads
for each setting, and drop-ins are read in name order, so this file is `10-`
to come before cloud-init's. Then remove cloud-init's file as well. The `10-`
drop-in already outranks it, but a 27-byte file that reads
`PasswordAuthentication yes` is what the audit of 2026-11-13 had to guess
from without sudo, and it is the first thing the next one would flag.
cloud-init writes it once per instance, not at each boot: on `fenrir` it kept
its install date across four reboots, so it stays gone.

```bash
sudo tee /etc/ssh/sshd_config.d/10-homelab.conf >/dev/null <<'SSHD'
# fenrir: key-only SSH for one user (build-the-sensor-guest.md §3).
# Named 10- so it is read before 50-cloud-init.conf: sshd keeps the first
# value it reads for each setting.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
AllowUsers atreus
SSHD
sudo chmod 644 /etc/ssh/sshd_config.d/10-homelab.conf
sudo rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo sshd -t && sudo systemctl reload ssh
sudo sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|x11forwarding|allowusers) '
```

All five must read `no`, apart from `allowusers atreus`, and
`ls /etc/ssh/sshd_config.d/` must list only `10-homelab.conf`. **Keep the session
you ran this from open**, and log in from a second terminal before you close
it. If that login fails, VM 190's console in the Proxmox web UI is the way
back in. The VM has no serial port, so `qm terminal 190` is not.

**Keep `authorized_keys` to the machines that administer this guest.** Do not
fill it with `ssh-import-id gh:<user>`. That installs every key on the GitHub
account, and each one can then log in to the sensor. List what is there, and
what has actually logged in:

```bash
ssh-keygen -lf ~/.ssh/authorized_keys
sudo journalctl -u ssh --since -30d | grep -o 'Accepted publickey .* SHA256:[^ ]*' | sort | uniq -c
```

Remove every key that is not the operator's workstation, or a host this
repository logs in from (Hicks, for §4's `install-agent-collectors`).

**Take out what the install adds that an appliance does not use.** cloud-init
puts the first user in `lxd`. LXD is not installed, but membership of `lxd` is
root as soon as it is. And 26.04 installs the `hwctl` snap, whose daemon
listens on a socket as root. Neither is anything the sensor runs:

```bash
sudo gpasswd -d atreus lxd
sudo snap remove --purge hwctl
id -nG atreus
snap list
```

`id` must not list `lxd`, and `snap list` must show only `core24` and
`snapd`. Leave those two, and Docker's idle `docker0`, which the daemon
recreates at every start.

## 4. Docker, the repository, and the stack

Install Docker, `sops`, `age` and `make`, and clone the repository, as
`alexander`'s §3 describes, into `~/code/Gerrrt/HomeLab`. That is the path
`fenrir` has, and the one the commands below use.

The stack has one secret: `fenrir`'s token for the lab's ingest proxy
([#834](https://github.com/Gerrrt/HomeLab/issues/834)). Before it, the stack
had none and was brought up with plain `docker compose`. Create the key and
the file **on `fenrir`**:

```bash
cd ~/code/Gerrrt/HomeLab
make secrets-init STACK=sensor
```

```bash
make secrets-edit STACK=sensor
```

Set `INGEST_TOKEN` to `INGEST_TOKEN_FENRIR` from `secrets/lab.sops.yaml` on
`alexander`, read there with `make secrets-get STACK=lab NAME=INGEST_TOKEN_FENRIR`.
Then commit `.sops.yaml`, which now carries `fenrir`'s public key, and the new
`secrets/sensor.sops.yaml`, through a pull request.

Before the first start, check that the site policy parses on the pinned
image:

```bash
make render STACK=sensor
docker compose -f stacks/sensor/compose.yaml run --rm --no-deps zeek \
  zeek -a local /zeek/site/local.zeek && echo parses
```

Then bring it up:

```bash
make up STACK=sensor
docker compose -f stacks/sensor/compose.yaml ps
```

Both containers should be running, and Zeek should be writing into
`/srv/sensor-data/zeek`. With no mirror yet, it sees nothing: only
`reporter.log` and `stats.log` appear.

Once SSH crosses the lab's edge, `reporter.log` also carries
`Failed to open GeoIP location database (lookup_location(SSH::lookup_ip))`.
That is expected, and `local.zeek` says why: Zeek's stock site policy loads
`protocols/ssh/geo-data`, and the image ships no GeoLite database.
`ssh.log`'s `remote_location` stays empty, and nothing else is lost.

**Prune the archive**, because nothing else will. The prune is a timer shipped
from the repository,
[`homelab-zeek-archive-prune`](../../systemd/agent/homelab-zeek-archive-prune.service),
daily at 03:17, and the retention is set in that unit and nowhere else
(`ZEEK_ARCHIVE_RETENTION_DAYS`). It runs through `run-scheduled.sh`, so its
outcome is a `.prom` file that this guest's Alloy ships to the lab's
Prometheus, where `ScheduledJobFailed`, `ScheduledJobStale` and
`ScheduledJobNeverRan` read it (#850).

That file needs the textfile directory, which `make up STACK=sensor` creates
(`scripts/ensure-textfile-dir.sh`). The installer also needs the archive
directory, which Zeek creates only at its first hourly rotation. Create both
now, on `fenrir`. The first already exists if the stack is up, and
`install -d` leaves it as it is:

```bash
sudo install -d -m 0755 -o root -g root /var/lib/node_exporter/textfile_collector /srv/sensor-data/zeek/archive
```

Then install the timer from the checkout on Hicks, as §5 does for `Saruman`.
Log in as `atreus`, `fenrir`'s user; the installer asks for its sudo password
once:

```bash
make install-agent-collectors AGENT=atreus@10.0.30.90 ARGS='--only zeek-archive-prune'
```

It must end with `zeek-archive-prune.prom written, mode 644`.

**Prune unused images**, weekly, so an image a bump replaced does not stay on
the 30 GB root. The audit of 2026-11-13 found `homelab-prune-images` on this
guest only because a full installer run had once put it there; nothing in this
runbook did, so a rebuilt `fenrir` would not have had it. It runs `docker
image prune -a` on Mondays at 04:00 and writes no `.prom`, so the installer
checks the service's last result instead. Same checkout, same login:

```bash
make install-agent-collectors AGENT=atreus@10.0.30.90 ARGS='--only prune-images'
```

It removes only images no container uses. If `make validate` has been run
here, its tool images are among them; §0 keeps that work on Hicks.

**Report patch state**, so that a pending reboot or a held security update
reaches someone. The lab's `RebootRequired`, `SecurityUpdatesPending` and
`PatchStateStopped` read `apt-patch-state.prom`, and a guest without the timer
is invisible to all three, `PatchStateStopped` included: it fires only for a
guest that was reporting. Nothing reboots this guest by itself. Same checkout,
same login:

```bash
make install-agent-collectors AGENT=atreus@10.0.30.90 ARGS='--only patch-state'
```

It must end with `apt-patch-state.prom written, mode 644`. Until 2026-11-17
this step was missing, and a libc6 upgrade waited four days for a reboot with
nothing saying so.

**Check that the guest stays an appliance** (#1577). `homelab-appliance-state`
reads, hourly, what §0 and §3 leave: `sshd`'s settings, the authorized keys,
root's keys, `sudoers.d`, the login accounts, `atreus`'s groups, user units and
lingering, the snaps, the apt sources, what listens in the host's network
namespace, and the size of `$HOME`. The lab's `ApplianceCheckFailed` names a
check that fails. It catches drift by accident; whoever has root here can make
it read clean, and the collector's header says so.

The keys check needs to know which keys are allowed, and that list stays on the
guest. After §3 has trimmed `authorized_keys` to the machines that administer
the guest, record their fingerprints, on `fenrir`:

```bash
sudo install -d -m 0755 /etc/homelab
ssh-keygen -lf ~/.ssh/authorized_keys | awk '{print $2}' \
  | sudo tee /etc/homelab/appliance-key-fingerprints >/dev/null
sudo chmod 0644 /etc/homelab/appliance-key-fingerprints
```

Then, from the checkout on Hicks:

```bash
make install-agent-collectors AGENT=atreus@10.0.30.90 ARGS='--only appliance-state'
```

It must end with `appliance-state.prom written, mode 644`, and every check must
read 1:

```bash
cat /var/lib/node_exporter/textfile_collector/appliance-state.prom
```

A key added later is a change to that file in the same sitting, or the check
fails within the hour, which is the point.

**On a `fenrir` built before #850**, remove the cron line the timer replaces,
so the two do not both prune:

```bash
sudo rm -f /etc/cron.d/zeek-archive-prune
```

## 5. The mirror and its gauge, on `Saruman`

Both ship through the agent-collector installer. **Run it from a checkout on
Hicks**, which can SSH to `Saruman` as root.

Run from the checkout on `Saruman` itself, the installer SSHes to
`root@10.0.30.20` from `10.0.30.20`. That login is from VLAN 30, so it fires
the critical `SshLoginFromUnexpectedSubnet`, which clears ten minutes later.
That is what happened on the first build. Also, `Saruman`'s own host key is not
in root's `known_hosts` there: compare `ssh-keyscan -t ed25519 10.0.30.20`
against `/etc/ssh/ssh_host_ed25519_key.pub` before adding it.

```bash
make install-agent-collectors AGENT=root@10.0.30.20 ARGS='--only zeek-mirror'
```

```bash
make install-agent-collectors AGENT=root@10.0.30.20 ARGS='--only zeek-mirror-state'
```

The first installs `scripts/zeek-mirror.sh` as `/usr/local/bin/homelab-zeek-mirror`
and enables its one-minute timer. The second installs the read-only collector
and its five-minute timer. Each verifies itself, and both must PASS.

On `Saruman`, read the result back:

```bash
journalctl -u homelab-zeek-mirror -n 3 --no-pager
tc filter show dev eno1 ingress pref 437
homelab-collect-zeek-mirror-state --print
```

- The journal must show `applied=` equal to `targets=` on the first run, and
  `already=` equal to it after that.
- The filter must say `Egress Mirror to device tap190i1`. **`device *` means
  the filter outlived the tap it pointed at**, and the next run replaces it.
- `--print` must show `homelab_zeek_mirror_active` at 1, with
  `ports_mirrored` equal to `ports_expected`.

## 6. Verify — including the things that fail quietly

1. **East-west traffic is seen.** Make the domain do something that never
   leaves the segment. From `carbuncle`, open `\\titan\` in Explorer. Then, on
   `fenrir`:

   ```bash
   grep -h '"id.resp_p":445' /srv/sensor-data/zeek/conn.log | tail -2
   tail -2 /srv/sensor-data/zeek/kerberos.log
   ```

   Both must show `10.0.30.54`. If `conn.log` has traffic only to and from
   `10.0.30.1`, the mirror is on `eno1` alone, and `ports_mirrored` will say
   so.
2. **TLS metadata is logged.** `ssl.log` carries `server_name` for a guest's
   outbound HTTPS, and `x509.log` the subjects and issuers.
3. **It reaches the lab's Loki.** In the lab's Grafana on `alexander`,
   `{host="fenrir", job="zeek"}` must return streams with a `log_type` label.
   `{host="fenrir", job="zeek", log_type="conn"} | json` must parse.
4. **Nothing reaches VLAN 99.** Only `homelab_zeek_mirror_*` from `Saruman`
   does. In the estate's Prometheus, `{host="fenrir"}` must be empty.
5. **The gauge reaches the estate.** In the estate's Prometheus,
   `homelab_zeek_mirror_active{host="Saruman"}` must read 1.
6. **Stopping the sensor is seen.** Run `qm shutdown 190`. Within fifteen
   minutes `ZeekMirrorInactive` must fire. Within a minute the ensurer's
   journal must show `sensor=absent removed=`. Then `qm start 190`: within six
   minutes the gauge must be back to 1 and the alert resolved.

## 7. The reboot proof — what closes #437

The issue's test for the gauge is that it is not decorative. The mirror does not
survive a reboot. With the unit that rebuilds it disabled, the independent
collector must report that, and the estate must page.

On `Saruman`:

```bash
systemctl disable --now homelab-zeek-mirror.timer
reboot
```

After it comes back, with the guests up again, on `Saruman`:

```bash
tc filter show dev eno1 ingress pref 437        # empty: the mirror is gone
homelab-collect-zeek-mirror-state --print | grep -E 'active|mirrored'
```

The gauge must read 0 and `ports_mirrored` 0. Within fifteen minutes of the
first collector run, **`ZeekMirrorInactive` must fire** on the estate's
Alertmanager. Record the time it fired. Then restore the ensurer:

```bash
systemctl enable --now homelab-zeek-mirror.timer
```

Within six minutes the gauge must read 1 and the alert must resolve.

**If the gauge reads 1 with the timer disabled, or the alert never fires,
stop.** The unit is decorative, and #437 says so in as many words. Find out
why before closing anything.

## 8. Write it down

On the same day:

- In `docs/architecture.md`, drop **Not built yet** from `fenrir`'s row.
- In `docs/network.md`, give `fenrir` a row in the VLAN 30 table and rewrite
  its note in the past tense. `scripts/check_docs.py` fails until both are
  done.
- Add a `docs/changelog.md` entry with the §6 results and the §7 times, the
  gauge falling and the alert firing and resolving.
- In `docs/roadmap.md`, mark #437 done. Close #437 with a link to that entry.

## 9. Take it out

In the reverse order to the build, so that the gauge never reports a sensor
that has already gone.

1. On `Saruman`, stop both timers:
   `systemctl disable --now homelab-zeek-mirror.timer homelab-zeek-mirror-state.timer`.
2. Remove the filters. Run `qm stop 190`, then run
   `/usr/local/bin/homelab-zeek-mirror` once: with no capture tap, it removes
   every `pref 437` filter and says how many. Then delete the four units from
   `/etc/systemd/system`, the two scripts from `/usr/local/bin`, and
   `zeek-mirror-state.prom` from the textfile directory.
3. `qm destroy 190`, then run `ifdown vmbr1` with §1's `PATH` and remove the
   `vmbr1` stanza. `ifdown` touches that bridge alone, as `ifup` did.
4. Remove the two rules and their tests from `host.rules.yaml`, the rows from
   `install-agent-collectors.sh`, and the stack. Then let
   `scripts/check_docs.py` say which sentences are left.
