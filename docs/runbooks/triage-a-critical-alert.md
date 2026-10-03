# Triage a critical alert

What to do first when a critical alert fires that is not a security alert
([`respond-to-a-security-alert.md`](respond-to-a-security-alert.md)) and has no
runbook of its own. Each alert's `runbook_url` links to its section here
([#842](https://github.com/Gerrrt/HomeLab/issues/842)).

The alert's own description says what it measured. This page says what to
check, in what order, and where to go next. Prometheus is at
`https://grafana.matrix.elysium:3000` (Explore) and, on the monitoring host,
`localhost:9090`.

## Before anything else

1. **Is it one alert or many?** Several critical alerts at once usually share
   a cause. A host down takes its disks, its containers and its scrape with
   it. Find the one at the bottom (power, the network, the host) before
   working the ones on top. Alertmanager inhibits the obvious pairs, not all
   of them.
2. **Is it the thing, or the thing watching it?** A dead exporter makes
   everything it measured look down. `BlackboxExporterDown` and
   `SnmpExporterDown` come before the alerts that depend on them.
3. **Write down what you changed.** Open an issue if it was not routine.

## InstanceDown

Prometheus has not been able to scrape a target for five minutes.

- **Can the host be reached at all?** `ping` it from the monitoring host, and
  check its power and network. If the host itself is down, its other alerts
  are symptoms.
- **If the host is up, the exporter is not.** For a Docker host,
  `docker ps` there. For `smaug`, the media stack's node-exporter
  (`docker ps` in the TrueNAS shell).
- **A target on another VLAN** also needs its firewall pass.
  `make check-firewall` shows whether a pass the docs claim is missing.

## EndpointUnreachable

A blackbox probe has failed for five minutes. The alert names the endpoint,
the host it lives on and how it was probed (`via`).

- **Both `address` and `dns` probes failing:** the service is down. Check the
  container on the host the alert names (`make ps STACK=…`).
- **Only `dns` failing:** the service is up and its name is not resolving.
  Check the host override on morpheus
  ([`add-a-host-override.md`](add-a-host-override.md)).
- **An https endpoint:** a certificate that no longer verifies looks exactly
  like this. `make certs ARGS=--list` shows what is being served.

## BlackboxExporterDown

No probe is running, so every endpoint alert has stopped being evaluated.
`make ps` on the monitoring host, then
`docker compose logs blackbox-exporter`. A config that no longer parses keeps
it in a restart loop; `make validate` names the line.

## SnmpExporterDown

Every SNMP device (morpheus, neo, mjolnir, shiva) will look unreachable
until this is fixed, so ignore their alerts until it is. `make ps`, then
`docker compose logs snmp-exporter`. A failed render leaves it with no
`snmp.yaml`: `make render` re-renders it from the SOPS file.

## GatewayDown

dpinger and an independent probe both say the uplink is down. Check the modem
and the ISP before the firewall: power-cycle the modem, then check the ISP's
status page from a phone. `homelab_gateway_loss_ratio` shows whether it is
total or partial. Nothing in the estate needs the internet to keep running,
but the alert path does: pages reach phones over it.

## HostDiskCritical

A filesystem has less than 10% free.

- **Find what is growing:** `du -xh --max-depth=1 <mountpoint> | sort -h`
  on the host. On a Docker host, `docker system df` first: superseded images
  are the usual cause.
- **The monitoring host:** Prometheus's retention is capped by size
  (`PROMETHEUS_RETENTION_SIZE`), so it should not be Prometheus. Loki's
  chunks and the backup staging directory are the usual suspects.
- **Do not delete what you do not recognise.** `make prune-images`, and the
  backup retention in `schedule-maintenance.md`, are the safe levers.

## GuestDiskCritical

A filesystem inside a lab guest is below 10% free. The estate cannot reach the
guest directly: ssh to it from the lab, or run
`qm guest exec <vmid> -- df -h` on `Saruman`. On a Docker guest,
`docker system df` first; superseded images are what filled odin.

## GuestDiskWillFillIn24h

The same, forecast rather than reached. There is time to find the cause before
the guest goes read-only. Follow [GuestDiskCritical](#guestdiskcritical).

## ThinPoolWillFillIn24h

A thin pool on `Saruman` fills within a day. When it does, every guest on it
goes read-only at once.

- `lvs -o+data_percent` on `Saruman` shows which volume is growing.
- **Snapshots** are the usual cause and the quickest space back:
  `qm listsnapshot <vmid>`, then delete the ones nothing needs.
- **Extending the pool** is the other answer, and it is a decision. See
  [`fit-the-saruman-ssds.md`](fit-the-saruman-ssds.md) for what the disks hold.

## SmartDriveUnhealthy

A drive's own firmware says it is failing. Replace it. `smartctl -a <device>`
on the host has the attribute that tripped. For a disk in `erebor`, follow
[`replace-the-nas-disk.md`](replace-the-nas-disk.md). For any other disk,
take a backup of what it holds first (`make backup`).

## SmartDriveSpareLow

The drive is remapping faster than its reserve allows. It is not failed yet.
Plan the replacement now, and follow
[SmartDriveUnhealthy](#smartdriveunhealthy) for the swap.

## FilesystemRemountedReadOnly

The kernel remounted a filesystem read-only, almost always because the storage
under it failed. Nothing more will be written there, logs included.

- `dmesg | tail -50` on the host shows the error that triggered it.
- Treat it as a failing disk:
  [SmartDriveUnhealthy](#smartdriveunhealthy). Check `smartctl -a`, and back
  up before rebooting, because a remount read-only can become a filesystem
  that does not mount at all.

## DiskIoErrors

The kernel logged I/O errors against a disk. Same order as above:
`dmesg | tail -50`, then `smartctl -a` on the device it names. A single error
during a cable bump is survivable; repeated errors are a disk on its way out,
so follow [SmartDriveUnhealthy](#smartdriveunhealthy).

## IloHardwareDegraded

`Saruman`'s iLO reports a degraded or failed component. The iLO web UI,
reachable from Hicks, shows which. For the storage controller's battery,
[`replace-the-smart-storage-battery.md`](replace-the-smart-storage-battery.md).

## HostOnBattery

A laptop host has lost its mains adapter input. If `UpsOnBattery` is firing
too, the shelf has lost power: follow
[`shut-down-on-the-ups.md`](shut-down-on-the-ups.md). If it is not, this
host's power brick or its socket has failed. The laptop's cell is carrying it,
and [HostBatteryRuntimeLow](#hostbatteryruntimelow) is the deadline.

## HostBatteryRuntimeLow

Under thirty minutes of battery left at the current draw. Shut the host down
cleanly rather than letting the cell decide (`sudo shutdown -h now`). If it
is `prometheus`, the estate goes blind when it does. The external heartbeat
will report that, which is expected.
