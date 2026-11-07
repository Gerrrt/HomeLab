# Runbook: Recover a container without its ports

A container is running and healthy, and nothing can reach it: Docker started
it before an address it publishes on existed. This page is where
`ContainerNetworkingMissing` points, and it is also how the monitoring host's
boot ordering is installed and checked
([ADR-0105](../adr/0105-hold-docker-until-the-monitoring-hosts-address-exists.md)).

---

## Why this exists

The move into the 32U rack power-cycled every host. `prometheus` booted at
23:46 on 2026-11-05 with no carrier on its USB NIC.
`systemd-networkd-wait-online` gave up after its two minutes, at 23:48:26.
`network-online.target` was reached anyway and dockerd started the
observability stack. Two services publish ports on `10.0.99.20` specifically:
`alloy` (6514, syslog) and `ingest-proxy` (9090 and 3100, every agent's
metrics and logs). Docker logged

```text
failed to bind host port 10.0.99.20:3100/tcp: cannot assign requested address
```

and started both with no networks and no published ports. `docker ps` said
`Up (healthy)` for both, because a healthcheck runs inside the container on its
own loopback, and that part still worked.

The link came up at 21:02 the next evening and the address at 22:28. The two
containers stayed broken, and `docker restart` did not change that. A restart
reuses the container's failed network setup. Only
`docker compose up -d --force-recreate` on 2026-11-07 brought them back. The
firewall, Suricata and DHCP logs, and the 9090 and 3100 endpoints, were dark
for about 25 hours.

---

## If `ContainerNetworkingMissing` is firing

1. **Check that the address exists now.** The fix cannot work before it does.

   ```bash
   ip -4 -o addr show to 10.0.99.20
   ```

   An empty answer means the problem is the link or the DHCP reservation, not
   Docker. Check the cable, the switch port and `morpheus`'s lease first.

2. **See what Docker thinks the container has.** The first map is what it was
   created to publish. The second is what it got. The count is its networks.

   ```bash
   docker inspect <name> --format '{{json .HostConfig.PortBindings}} | {{json .NetworkSettings.Ports}} | {{len .NetworkSettings.Networks}}'
   ```

3. **Recreate it.** Not `docker restart`, which keeps the broken state. From
   the deployment checkout, with the service name from compose (`ingest-proxy`
   is service `caddy`):

   ```bash
   cd ~/code/Gerrrt/HomeLab/stacks/observability && docker compose up -d --force-recreate <service>
   ```

4. **Confirm.** Rerun step 2, or `make port-state` and read
   `homelab_container_ports_missing` in Prometheus. The alert clears after the
   next run of the 15-minute job.

---

## Install the boot ordering

Once per host, and again whenever `systemd/host/` changes. The units are
self-contained, so this may run from any checkout:

```bash
make install-host-units
```

It installs `homelab-wait-address.service` and a drop-in for
`docker.service`, reloads systemd and enables the waiter. It does **not**
restart docker. The ordering applies from the next boot.

Then prove it:

```bash
./scripts/install-host-units.sh --status
```

`docker.service` should list the drop-in under `DropInPaths` and
`homelab-wait-address.service` under both `After` and `Wants`.
`./scripts/install-host-units.sh --check` asserts the same, and `make validate`
runs it.

`./scripts/install-host-units.sh --prove-ordering` shows that systemd honours
the ordering. It needs no root and does not touch the real docker. It loads
the committed waiter and drop-in into your user systemd manager, in front of a
stand-in docker unit. With an address the host does not hold, the stand-in's
start job must sit `waiting`. With `10.0.99.20` held, both must finish.

---

## After a boot without the address

The waiter holds docker for as long as the address is missing, however long
that is. The rest of the boot does not wait, so SSH and the console work.

```bash
journalctl -b -u homelab-wait-address
```

This prints one line when the wait starts and one every five minutes. The last
line says how long the wait took. While it waits, `docker ps` hangs and every
scheduled job that needs docker fails, which `ScheduledJobStale` reports in
time. Nothing can page during the wait anyway: with no address, nothing on
this host reaches the network.

If the address will not come back (a renumbering, say), change
`HOMELAB_WAIT_ADDRESS` in `systemd/host/homelab-wait-address.service` and
`INGEST_BIND_ADDR`'s default in `stacks/observability/compose.yaml` together,
and reinstall. To start docker before that, as a one-off:

```bash
sudo systemctl stop homelab-wait-address && sudo systemctl start docker
```

Stopping the waiter cancels docker's queued start, so docker has to be started
again by hand. Any container that publishes on the missing address comes up
in exactly the state this page is about.
