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
| Disk | **Two: 32 GB OS, 64 GB data**, both on `large_data` | The data disk at `/srv/sensor-data` holds the current logs and fourteen days of hourly archive. The lab's Loki keeps 360 h of what Alloy ships; the archive is the local copy for the days after that |
| Mirror | `tc`, not Open vSwitch | ADR-0068 |

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

- `vmbr0` must still show `10.0.30.110/24`.
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
  --ide2 local:iso/ubuntu-24.04-live-server-amd64.iso,media=cdrom \
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

If the name is not `ens19`, change it in the file above and in
`stacks/sensor/.env`.

Install `qemu-guest-agent` as `odin`'s §1 says. `qm guest exec 190 -- uptime`
from `Saruman` is the check.

## 4. Docker, the repository, and the stack

Install Docker and clone the repository as `alexander`'s §3 describes.
**`sops` and `age` are not needed**: this stack has no secrets, and is brought
up without `make render` (`docs/security.md` § Secrets).

Before the first start, check that the site policy parses on the pinned
image:

```bash
cd ~/HomeLab
cp stacks/sensor/.env.example stacks/sensor/.env
docker compose -f stacks/sensor/compose.yaml run --rm --no-deps zeek \
  zeek -a local /zeek/site/local.zeek && echo parses
```

Then bring it up:

```bash
docker compose -f stacks/sensor/compose.yaml up -d
docker compose -f stacks/sensor/compose.yaml ps
```

Both containers should be running, and Zeek should be writing into
`/srv/sensor-data/zeek`. With no mirror yet, it sees nothing: only
`reporter.log` and `stats.log` appear.

**Prune the archive**, because nothing else will:

```bash
echo '17 3 * * * root find /srv/sensor-data/zeek/archive -type f -mtime +14 -delete' \
  | sudo tee /etc/cron.d/zeek-archive-prune
```

## 5. The mirror and its gauge, on `Saruman`

Both ship through the agent-collector installer, from any checkout that can
SSH to `Saruman` as root:

```bash
make install-agent-collectors AGENT=root@10.0.30.110 ARGS='--only zeek-mirror'
```

```bash
make install-agent-collectors AGENT=root@10.0.30.110 ARGS='--only zeek-mirror-state'
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
