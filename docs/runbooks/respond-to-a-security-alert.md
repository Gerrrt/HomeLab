# Respond to a security alert

What to do when a critical security alert fires. Each alert's `runbook_url`
links to its section here
([#842](https://github.com/Gerrrt/HomeLab/issues/842)).

Most of these alerts are evaluated by the Loki ruler from logs
(`stacks/observability/loki/rules/security.rules.yaml`); the rest come from
Prometheus. The queries below go in Grafana's **Explore**, Loki data source,
at `https://grafana.matrix.elysium:3000`, from a Hicks workstation.

## Before anything else

These hold for every section below.

1. **Do not silence it first.** A silence is a decision that the alert is
   wrong. Look at the evidence before deciding that, and when you do silence
   one, its comment names the issue that explains it (`docs/observability.md`,
   Silences).
2. **Capture the evidence before you change anything.** Run the section's
   query over a window starting well before the alert, and save the result,
   in Explore → Inspect → Data → Download CSV. Loki keeps 30 days, and a fix
   that changes the firewall changes what new logs will say.
3. **Decide whether to isolate.** Isolating something on the house's own
   segments costs the household that device. Isolating a lab guest costs
   nothing. When unsure, isolate the lab and investigate the house.
4. **Write it down.** Open an issue: what fired, what you found, what you
   changed. The changelog entry comes from it.

## SshBruteForceSevere

More than 100 failed SSH authentications on one host in five minutes.

```logql
{host="<host>"} |~ "(?i)failed (password|publickey)"
```

- **Where is it coming from?** The source address is in each line. A source
  on VLAN 30 is the lab, where attack tooling is expected. Confirm it was an
  exercise you are running. A source on VLAN 50 or 99 is a house machine
  doing this, so treat that machine as compromised.
- **Did any attempt succeed?** Query
  `{host="<host>"} |~ "Accepted (password|publickey)"` over the same window.
  An accepted login from the same source is
  [SshLoginFromUnexpectedSubnet](#sshloginfromunexpectedsubnet)'s territory,
  and is the urgent half.
- **Stop it where the traffic actually flows.**
  - **Same VLAN as the target:** pfSense cannot help. For example, a VLAN 99
    source attacking `prometheus`, `oracle` or `trinity` is switched locally
    and never crosses the firewall. Cut the source off at the switch (disable
    its port on neo) or power it down.
  - **Another VLAN:** the traffic is routed, so add a pfSense block for the
    source on its interface (Firewall → Rules), above the pass rules. Then
    kill its existing states (Diagnostics → States, filter on the source,
    Kill), because a block does not end connections already open.
  - **A lab guest:** stop it on `Saruman` (`qm stop <vmid>`). That is faster
    and reversible.

## SshLoginFromUnexpectedSubnet

An SSH login was **accepted** from outside VLAN 50 and VLAN 99.

```logql
{host="<host>"} |~ "Accepted (password|publickey)" != "10.0.50." != "10.0.99."
```

- **Was it you?** A login from the lab (10.0.30.x) or the WireGuard peers
  (172.31.x) may be legitimate work. If so, the rule's source ranges are stale,
  and fixing them is the follow-up, not a silence.
- **If it was not you, treat the host as compromised.** On the host, `who -u`
  and `last -i` show the session and its source. Kill **that session only**:
  find its sshd process (`ps -ef | grep 'sshd: <user>@'`) and `kill` that PID.
  Do not `pkill -u <user>`. For root on morpheus or `Saruman`, that kills the
  firewall's or the hypervisor's own processes, and your access with them.
  Then revoke the credential it used: its line in `~/.ssh/authorized_keys`,
  or the account's password. Then ask how the source reached
  port 22 at all. That is a segmentation question, and
  [TerminalSegmentReachedInternalNetwork](#terminalsegmentreachedinternalnetwork)
  explains how to read it from the firewall.

## TerminalSegmentReachedInternalNetwork

pfSense **passed** a packet from VLAN 10, 20 or 40 toward VLAN 30, 50 or 99,
or the switch LAN. ADR-0002 says that path does not exist.

```logql
{app="filterlog", action="pass"} |~ `,10\.0\.(10|20|40)\.[0-9]+,(10\.0\.(30|50|99)|10\.7\.7)\.[0-9]+,`
```

- **Which rule passed it?** Each filterlog line carries the rule's tracker
  number. In pfSense, Firewall → Rules on the interface named in the alert;
  hover a rule to see its tracker.
- **What changed?** Check `make check-firewall` on the monitoring host first.
  It diffs `docs/firewall-claims.yaml` against the live ruleset and names the
  drift. Then Diagnostics → Backup & Restore → Config History shows who
  changed what and when.
- **Put it back.** Revert to the last good revision from Config History, or
  follow [`restore-the-firewall.md`](restore-the-firewall.md) if the config
  itself is suspect. Then check that the tripwire is silent again.
- **Then ask what crossed.** The destination addresses in the captured lines
  are where to look next.

## LabSegmentReachedInternalNetwork

pfSense passed a packet from VLAN 30, or from the WireGuard peers, toward the
house. This is the same failure as above, from the segment that holds attack
tooling, so it is the more serious of the two.

```logql
{app="filterlog", action="pass"} |~ `,(10\.0\.30|172\.31\.0)\.[0-9]+,(10\.0\.(10|20|40|50|99)|10\.7\.7)\.[0-9]+,`
```

- **Contain first.** Until the rule is fixed, stop the source guest on
  `Saruman` (`qm stop <vmid>`), or for a 172.31.x source, stop WireGuard on
  `phoenix` (`systemctl stop wg-quick@wg0`).
- **Then follow the section above.** Find the rule, check
  `make check-firewall` and Config History, and revert. A 172.31.x source
  also means the ADR-0042 blocks are missing, or ordered below the
  catch-all ([`open-the-remote-path.md`](open-the-remote-path.md)).

## UnknownDeviceOnManagementSegment

A MAC address took a DHCP lease on VLAN 99 for the first time in seven days.
Everything that belongs there has a reservation.

```logql
{app="kea-dhcp4"} |= "<mac>"
```

- **Did you just plug it in?** If so, give it a reservation and add it to
  `docs/network.md`
  ([`add-monitored-device.md`](add-monitored-device.md)), and the alert has
  done its job.
- **If not, find it.** In pfSense, Status → DHCP Leases shows the address
  it got. The switch's MAC table, at neo's management UI on 10.7.7.2 (from
  Hicks), shows the port it is on.
- **Cut it off** by disabling that switch port, and delete its lease. Then
  check what it talked to: query filterlog for its address.

## SuricataHighPriorityAlert

A priority-1 signature fired on a watched interface.

```logql
{app="suricata", priority="1"}
```

- **igc0.20 (Skids, IoT):** treat the device as compromised until shown
  otherwise. That segment exists on the assumption that its devices already
  are. Identify it from the source address, then cut it off at the switch or
  remove it from the IoT SSID.
- **igc0.10 (Degens, guest):** the segment has no route inward (ADR-0013).
  Drop the device from the guest SSID; there is nothing to hunt for.
- **A signature you believe is wrong** gets suppressed in Suricata, not
  silenced in Alertmanager
  ([`enable-suricata.md`](enable-suricata.md)), with the reason recorded.

## IngestAuthNotEnforced

The ingest proxy on 10.0.99.20 answered a request with no token with
something other than its own 401. Until this is fixed, anything that can route
there can read, write or delete metrics and logs.

- **Check what each port is bound to.** On the monitoring host, run
  `docker ps --format '{{.Names}}  {{.Ports}}'`. Healthy looks like this:
  - `prometheus` and `loki` on `127.0.0.1:9090` and `127.0.0.1:3100`;
  - `ingest-proxy` on `10.0.99.20:9090` and `10.0.99.20:3100`.

  Prometheus or Loki on `0.0.0.0` or `10.0.99.20` is the direct exposure.
- `make logs SERVICE=caddy` shows whether the proxy is up and what it is
  answering.
- **Before redeploying, find out what changed.** `make up` deploys whatever
  the checkout holds, so if a local edit caused this, it would redeploy the
  edit.
  1. Run `git status` and `git diff` in the deployment checkout.
  2. Save the diff as evidence (`git diff > ~/ingest-auth-diff.txt`).
  3. Restore the committed files (`git checkout -- <file>`), then `make up`.

  If the committed config is itself the problem, the fault is in
  `stacks/observability/compose.yaml` or `stacks/observability/Caddyfile`
  (ADR-0067).

## PfNotRunning

pf, the packet filter, is disabled on morpheus. No inter-VLAN rule is being
enforced, so every segment can reach every other.

- In pfSense, Diagnostics → Command Prompt: `pfctl -s info` shows the state.
  `pfctl -e` enables it.
- If it was disabled in the config (System → Advanced → Firewall & NAT,
  *Disable all packet filtering*), untick it. If it will not stay enabled,
  [`restore-the-firewall.md`](restore-the-firewall.md).
- Afterwards, check whether anything crossed while it was off: query filterlog
  for the window. With pf disabled there may be no log lines at all, and that
  is the answer.

## The rest

Three more critical security-category alerts have their own runbooks, which
their `runbook_url`s point at:

- `PveFirewallDisabled` and `PveFirewallPolicyAccept`:
  [`build-the-playground.md`](build-the-playground.md) §4.
- `IsoChecksumMismatch`:
  [`build-the-lab-templates.md`](build-the-lab-templates.md).
