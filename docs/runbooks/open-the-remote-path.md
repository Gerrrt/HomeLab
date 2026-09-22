# Runbook: Open the remote path

**Target:** WireGuard on the jumpbox, ImaginationLAN (VLAN 30); one static
route, one port forward and seven rules on `morpheus` (`10.0.99.1`) — six
blocks and a tripwire, which pf loads as twelve
**Time:** ninety minutes, across the jumpbox, the firewall GUI and one client
**You will need:** a shell on the jumpbox, the pfSense GUI, a client device to
enrol, and a dynamic DNS account — §0 turns it into **the endpoint**, which
used to be the step this runbook could not do for you
**Before this:** the jumpbox exists
([#436](https://github.com/Gerrrt/HomeLab/issues/436)), `Saruman`'s own
firewall is on ([#566](https://github.com/Gerrrt/HomeLab/issues/566)) so that
a peer which reaches the lab does not reach `8006`, and
[ADR-0042](../adr/0042-terminate-the-remote-path-on-the-lab-and-route-it.md)
is read rather than skimmed

> **Status — 2026-09-22: the tunnel is up, and it reaches the lab and nothing
> else.** §0's record was created 2026-09-21; the tunnel came up the next day.
>
> One peer, `laptop-01`, pinned to `172.31.0.2/32`. The endpoint is ADR-0044's
> dynamic DNS record, verified by resolving it against a public resolver from
> `morpheus` itself and comparing to the live WAN address, which is stronger
> than the typed check §0 used to ask for. #566 was closed first, on
> 2026-09-20, so the hypervisor's login surface was never reachable from a
> peer.
>
> Measured, from a laptop on a phone hotspot: `alexander` answered at
> `ttl=63`, one hop below its default, which is the proof that `phoenix`
> forwarded rather than answered. Peer traffic toward the house was **blocked
> and attributed** — 264 packets to Winterfell, 26 to CasaBonita, 17 to Hicks,
> and `filterlog` carried 307 blocked lines with a `172.31.0.2` source and
> **zero** passed. The tripwire stayed at 0, which is correct: the blocks catch
> everything above it.
>
> **Four things in this runbook were wrong, and the build found them by
> failing.** §3's `PostUp` cannot work on Ubuntu 26.04 at all; §8's positive
> test named an address a peer can never reach; §8's negative tests and leak
> drill cannot fire while the client is correctly scoped; and its commands are
> Linux-flavoured in ways that silently no-op on a macOS client. All four are
> fixed below. The forwarding one is the serious one, because it failed while
> reporting success.

This opens the estate's **first inbound path from the internet**. It terminates
on the lab and reaches the lab, and the thing that keeps it there is the
firewall's default deny rather than the jumpbox's configuration — but the
jumpbox's configuration is what decides whether the firewall is ever asked. Two
mistakes here do not announce themselves: a client `AllowedIPs` wider than the
lab, and a `MASQUERADE` rule copied in from a tutorial.

> [!CAUTION]
> **There is no `MASQUERADE` in this design, anywhere.** Every guide you will
> find while doing this has one. ADR-0042 §3 is why this one does not: NAT
> would make every peer indistinguishable from the jumpbox, which holds a
> Proxmox token and an SSH key, and would hand every peer the jumpbox's
> standing at the firewall. If you find yourself adding `-j MASQUERADE` to make
> something work, the missing piece is the static route in §5, not the NAT.

## What moves where, and what never does

| Artefact | Made on | Lives on | Travels? |
| --- | --- | --- | --- |
| The server private key | The jumpbox | The jumpbox, in `/etc/wireguard/` at `0600` | **Never.** Generated where it is used |
| The server public key | The jumpbox | Every peer's config | Yes, freely. Public |
| Each peer's private key | **That peer's own device** | That device | **Never**, including not to the jumpbox |
| Each peer's public key | That device | `wg0.conf` on the jumpbox | Yes, freely. Public |
| The preshared key, one per peer | Either end, with `wg genpsk` | Both ends of that one peer | Once, over a channel that is not email |
| The endpoint hostname and listen port | §0 | `docs/security.md`'s withheld list | **Not into this repository** |

Generating a peer's key *on the jumpbox* and sending it to the device is the
obvious shortcut and it is the one thing this table exists to forbid. A private
key that has been on two machines is a key you cannot reason about later.

---

## 0. The endpoint — dynamic DNS on `morpheus`

WireGuard needs a stable address and port to dial. The WAN address is
ISP-assigned by DHCP and sticky in practice, and
[ADR-0044](../adr/0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md)
decided how it gets a name: a dynamic DNS record in a free provider's zone,
kept current by the client pfSense ships. ADR-0042 §5 had recorded this as the
one prerequisite its runbook could not solve; it is solved here, and this
section is the first step rather than a stop sign.

1. **Confirm the address is still a public one.** On `morpheus`, *Status →
   Interfaces* shows the WAN address; from `prometheus`,
   `curl -s https://ifconfig.me/ip` shows what the internet sees. They must
   match, and neither may be in `100.64.0.0/10` — see the note below. Checked
   on 2026-09-19 and true then; check again, because this is the fact every
   later step rests on.
2. **Create the provider account and its token, off this repository.** The
   provider is the one on `security.md`'s withheld list, chosen by ADR-0044's
   criteria: native support in the pfSense client, a token scoped to the one
   record, no renewal nag, no charge. Pick a hostname nobody would guess from
   the estate's names. The account, the token and the hostname go on the
   withheld list the moment they exist.
3. **Add the client on `morpheus`.** *Services → Dynamic DNS → Dynamic DNS
   Clients → Add*: the provider; interface **WAN**; the hostname; the token in
   the field the provider's entry labels for it; *Verbose logging* on for the
   first week. Save, then *Force update* on the row it creates. The row turns
   green with the cached address when the provider has accepted it; a red row
   means the token or the hostname, and *Status → System Logs → System →
   General* says which.
4. **Verify from outside the house, not from inside it.** Unbound would answer
   the name from its own cache and prove nothing. From `prometheus`, ask a
   public resolver directly and compare it to step 1:

   ```bash
   dig +short <HOSTNAME> @1.1.1.1
   ```

   Then the same query from a phone on mobile data. Both must print the WAN
   address. A stale answer within the record's TTL is normal for a few
   minutes after a forced update; a stale answer an hour later is the client.
5. **Pick a listen port** that is not a well-known one. It goes on
   `security.md`'s withheld list beside the hostname and the WAN address, not
   into a commit message.

Nothing in this section is written into this repository: the provider, the
hostname, the token and the port are all withheld, and the client's
configuration lives in `config.xml`, which
[`backup-firewall.sh`](../../scripts/backup-firewall.sh) already treats as
secret. A restore onto the spare hardware carries the client with it, so the
record follows the new address the spare's MAC is given — check step 4 after
any restore anyway.

> [!NOTE]
> Behind CGNAT none of this works, and no amount of firewall configuration
> fixes it — an inbound port forward needs an address the ISP actually routes
> to you. If the WAN address is in `100.64.0.0/10`, or step 1's two addresses
> differ, stop here: ADR-0044's reopening clause names this case, and the
> answer is [#447](https://github.com/Gerrrt/HomeLab/issues/447)'s relay or an
> outbound-only overlay, which is a different ADR.

## 1. Install WireGuard on the jumpbox

```bash
# The distro package, not a container. The jumpbox runs no compose stack, and
# a kernel-module datapath in Docker would need privileges worth more than the
# convenience.
sudo apt-get update && sudo apt-get install --yes wireguard

# Expect a version, and no error. The module loads on first use, not now.
wg --version
```

> [!NOTE]
> **If this host ever runs Docker, pin its address pools first.** Docker walks
> `172.16/12` upward from `172.17` when it allocates a bridge network, and
> `172.31.0.0/24` is at the very top of that walk — the last thing it would
> take, and still something it can take. A collision here is a tunnel that
> stops routing the day someone runs `docker compose up` on the toolchain host.
> Set `default-address-pools` in `/etc/docker/daemon.json` to a base that
> excludes it.

## 2. Generate the server keypair, on the jumpbox

```bash
# umask FIRST. wg genkey writes through your shell's redirect, and the default
# umask leaves the private key world-readable for the instant before chmod.
sudo install -d -m 0700 /etc/wireguard
( umask 077 && wg genkey | sudo tee /etc/wireguard/server.key >/dev/null )
sudo chmod 0600 /etc/wireguard/server.key
sudo sh -c 'wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub'

# The public half, for the peer configs in §4.
sudo cat /etc/wireguard/server.pub
```

Verify the mode before moving on — this is the one file whose permissions
matter and the one people fix later:

```bash
sudo stat -c '%a %n' /etc/wireguard/server.key
# expect: 600 /etc/wireguard/server.key
```

## 3. The server configuration

`/etc/wireguard/wg0.conf`, mode `0600`. Substitute the bracketed values; the
listen port is the one from §0.

```ini
[Interface]
# The router's own address inside the tunnel. /24 here is the interface's
# subnet, not a grant to anybody.
Address    = 172.31.0.1/24
ListenPort = <LISTEN_PORT>
PrivateKey = <contents of /etc/wireguard/server.key>

# Forwarding is a capability scoped to the tunnel's lifetime, not a permanent
# property of the host (ADR-0042). Nothing here is in /etc/sysctl.conf, and
# nothing here translates an address.
#
# BUT NOT HERE, on Ubuntu 26.04. See the CAUTION below: AppArmor denies
# wg-quick both the sysctl write and exec of a shell, so these two lines fail
# silently and the service still reports success. The toggle lives in a systemd
# drop-in instead, and these lines are replaced by a comment pointing at it.

[Peer]
# laptop-01. One block per device, and the comment is how you will know which
# key to delete in a year.
PublicKey    = <that device's PUBLIC key>
PresharedKey = <output of `wg genpsk`, unique to this peer>
# On the SERVER, AllowedIPs is an ACCESS CONTROL LIST: the only source address
# this peer is permitted to present. One /32 per device. A /24 here would let
# any peer impersonate any other.
AllowedIPs   = 172.31.0.2/32
```

```bash
sudo chmod 0600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
```

> [!CAUTION]
> **`PostUp` cannot set a sysctl on Ubuntu 26.04, and it fails looking like it
> worked.** Found 2026-09-22 building this
> ([#442](https://github.com/Gerrrt/HomeLab/issues/442)). The distribution
> ships an AppArmor profile for `wg-quick`; its `wg-quick//sysctl` child denies
> writing `/proc/sys/net/ipv4/ip_forward`, and the profile denies executing
> `bash`, so a shell workaround fails too. What you see is this:
>
> ```text
> [#] sysctl -w net.ipv4.ip_forward=1
> sysctl: permission denied on key "net.ipv4.ip_forward", ignoring
> net.ipv4.ip_forward = 1
> ```
>
> It prints the value it did not set, and `systemctl` reports the unit started
> successfully. The kernel records the real reason in `dmesg` as
> `apparmor="DENIED" ... profile="wg-quick//sysctl"`.
>
> **The symptom is a tunnel that looks entirely healthy.** The handshake
> succeeds, and the jumpbox itself is reachable, because a packet addressed to
> `phoenix` terminates there and needs no forwarding. Every *other* lab host is
> unreachable, and so is every blocked destination — which means the §8
> verification below cannot exercise a single firewall rule. That is how this
> hid.

Set the toggle in a systemd drop-in, where it runs outside that profile. This
keeps ADR-0042's property exactly: the capability appears with the tunnel and
disappears with it, and it is nowhere in `/etc/sysctl.d`.

```bash
SYSCTL="$(command -v sysctl)" && sudo install -d -m 0755 /etc/systemd/system/wg-quick@wg0.service.d && sudo tee /etc/systemd/system/wg-quick@wg0.service.d/ip-forward.conf >/dev/null <<EOF
[Service]
ExecStartPost=$SYSCTL -w net.ipv4.ip_forward=1
ExecStopPost=$SYSCTL -w net.ipv4.ip_forward=0
EOF
sudo systemctl daemon-reload && sudo systemctl restart wg-quick@wg0
```

Prove it from zero, because setting the value by hand first would make the
next check pass for the wrong reason:

```bash
sudo sysctl -w net.ipv4.ip_forward=0 \
  && sudo systemctl restart wg-quick@wg0 && sysctl net.ipv4.ip_forward \
  && sudo systemctl stop wg-quick@wg0 && sysctl net.ipv4.ip_forward \
  && sudo systemctl start wg-quick@wg0 && sysctl net.ipv4.ip_forward
# expect 1, then 0, then 1
```

## 4. The client configuration

On the **client device**, generate its own keypair and build this. Send the
public key to the jumpbox for §3; the private key stays where it was made.

```ini
[Interface]
Address    = 172.31.0.2/32
PrivateKey = <this device's PRIVATE key, generated here>

[Peer]
PublicKey    = <the server public key from §2>
PresharedKey = <the same preshared key as this peer's block on the server>
Endpoint     = <ENDPOINT>:<LISTEN_PORT>
# On the CLIENT, AllowedIPs is a ROUTE: the CIDRs that go down the tunnel.
# This is the lab and nothing else. 0.0.0.0/0 here would pull all of the
# device's traffic through the house, which is not what this is for and is the
# failure ADR-0042 says will not announce itself.
AllowedIPs   = 10.0.30.0/24
PersistentKeepalive = 25
```

> [!IMPORTANT]
> **`AllowedIPs` means opposite things on the two ends, and both are on this
> page.** Server: an ACL, `/32`, "who may this peer claim to be". Client: a
> route, `10.0.30.0/24`, "what goes down the tunnel". Reading §3's value into
> §4 gives a peer that can reach nothing; reading §4's into §3 gives a peer
> that can present any source address in the tunnel subnet.

## 5. The route back, on `morpheus`

Without this, lab hosts receive tunnel packets and answer them to their default
gateway, which has never heard of `172.31.0.0/24`. This is the step that
replaces the NAT rule.

*System → Routing → Gateways → Add* — a gateway on the ImaginationLAN
interface pointing at the jumpbox:

| Field | Value |
| --- | --- |
| Interface | ImaginationLAN |
| Address Family | IPv4 |
| Name | `JUMPBOX_TUNNEL` |
| Gateway | the jumpbox's lab address |
| Disable Gateway Monitoring | **checked** — it is a host, not an uplink, and a failed ping should not mark it down |

Then *System → Routing → Static Routes → Add*:

| Field | Value |
| --- | --- |
| Destination network | `172.31.0.0/24` |
| Gateway | `JUMPBOX_TUNNEL` |
| Description | `WireGuard peers — ADR-0042` |

**Save**, then **Apply Changes**.

## 6. The inbound pass, on the WAN

*Firewall → NAT → Port Forward → Add*:

| Field | Value |
| --- | --- |
| Interface | WAN |
| Protocol | **UDP** |
| Destination | WAN address |
| Destination port range | the listen port, from and to |
| Redirect target IP | the jumpbox's lab address |
| Redirect target port | the same listen port |
| Description | `WireGuard — ADR-0042` |
| Filter rule association | **Add associated filter rule** |

**Save**, then **Apply Changes**. This is the `rdr` and the WAN pass that
[ADR-0011](../adr/0011-keep-the-wiki-internal.md)'s 2026-08 measurement said
did not exist; its update note records that this is what changed it.

## 7. Teach the segmentation about the second subnet

**This section is not optional, and skipping it is worse than having used
NAT.** Routed mode puts a second source subnet on `igc0.30`. Every existing
block rule and the tripwire are scoped `from <OPT4__NETWORK>` — that is
`10.0.30.0/24` and it does not match a tunnel peer. Left as-is, tunnel traffic
misses every block above the catch-all and the catch-all passes it to every
segment in the house.

First, *Firewall → Aliases → IP → Add*:

| Field | Value |
| --- | --- |
| Name | `Tunnel_Peers` |
| Type | Network(s) |
| Network | `172.31.0.0/24` |
| Description | `WireGuard peers — ADR-0042` |

Then on *Firewall → Rules → ImaginationLAN*, mirror the existing lab rules for
this source, keeping the established order — blocks, then the tripwire, then
the egress catch-all:

1. **A block per house segment**, `Tunnel_Peers → <segment>`, logged, placed
   immediately beside the existing `10.0.30.0/24` blocks. On 2026-09-22 there
   were six: Winterfell, Hicks, CasaBonita, Skids, Degens and the switch LAN.
   The quickest way is to copy each existing IPv4 block and change only the
   source; the destinations are then right by construction. **Tick `Log` on
   every one, even though five of the six originals are unlogged** — §8's leak
   drill reads blocked `filterlog` lines, so a silent block makes the drill
   return nothing, which is indistinguishable from the packet never being sent.
   IPv6 counterparts are unnecessary: the tunnel carries IPv4 only.
2. **One tripwire**, `pass` + `log`, `Tunnel_Peers → House_Segments`, directly
   below those blocks and above the `→ any` egress rule.

The tripwire points at `House_Segments`, **not** `Internal_Segments` — the
latter names `10.0.30.0/24` itself, and against it every DNS query from a peer
to the lab gateway logs as a crossing. That mistake cost 1,239 false lines in
three days when the lab's own tripwire was created
([#234](https://github.com/Gerrrt/HomeLab/issues/234)); do not repeat it here.

Then widen the alert that watches it —
`stacks/observability/loki/rules/security.rules.yaml`,
`LabSegmentReachedInternalNetwork` — so a tunnel source counts as the lab
reaching the house. The rule and its unit test are changed in the same commit
as this runbook; `make check-loki-rules` proves it.

## 8. Verify — up, and then down

The tunnel being up proves almost nothing. What has to be proved is that it
reaches the lab, that it reaches nothing else, and that the capability goes
away with it.

```bash
# On the jumpbox, with the tunnel up. The handshake is the only proof the keys
# and the endpoint agree; an interface can exist and be useless.
sudo wg show wg0
# expect: a peer, a recent handshake, and non-zero transfer in both directions
```

```bash
# THE CHECK THIS RUNBOOK EXISTS FOR. Read AllowedIPs off the RUNNING
# interface, not off the file you think you deployed.
sudo wg show wg0 allowed-ips
# expect exactly one /32 per peer, all inside 172.31.0.0/24.
# Anything wider — a /24, or 0.0.0.0/0 — is the segmentation failure.
```

### Before any client check: prove where you are, from the route table

"Test from off-estate" is an intention. The route table is a fact, and on
2026-09-22 a laptop silently rejoined the house Wi-Fi mid-test and produced a
page of results that meant nothing. macOS prefers Wi-Fi over tethering, so
**turn Wi-Fi off** rather than merely connecting to a hotspot, then:

```bash
route -n get 10.0.30.70 | grep -E 'interface|gateway'
# expect a utun interface. A gateway of 10.0.50.1 means you are on Hicks, and
# every check below would pass whether or not the tunnel works (ADR-0031).
```

```bash
netstat -rn -f inet | grep utun<N>
# THIS IS THE CLIENT-SIDE CONFINEMENT PROOF, and it is better than any ping:
# it shows the whole set of what the tunnel carries, not one address. Expect
# 10.0.30/24 and nothing else from 10.0.0.0/8.
```

> [!IMPORTANT]
> **On macOS, `ping -W` is milliseconds, not seconds.** Every `-W3` below is
> three thousandths of a second on a Mac, so the ping fails instantly whatever
> the firewall does, and the negative checks appear to pass while testing
> nothing. Use `-t 3` on macOS. This cost an hour on 2026-09-22.

### The positive check: a lab host, not the gateway

```bash
# From the client. NOT 10.0.30.1 — a peer cannot reach the firewall's own lab
# address, because no rule passes a 172.31 source to it and it falls to default
# deny. The original version of this runbook told you to ping it, which always
# failed, which is exactly what hid the forwarding bug in §3 for an afternoon.
ping -c2 -t3 10.0.30.40        # alexander. macOS; use -W3 on Linux
# expect a reply at ttl=63, one below its default. That decrement is the proof
# that phoenix FORWARDED it rather than answering for itself, which is the only
# thing that distinguishes a working jumpbox from one that only reaches itself.
```

### The negative check, and why it needs the client widened

**A correctly scoped client cannot test the firewall.** With
`AllowedIPs = 10.0.30.0/24`, a packet for `10.0.99.20` never enters the tunnel:
it leaves by whatever default route the client has and dies in the carrier's
network. The result is identical to a firewall block, and identical to the
tunnel being switched off. ADR-0042 says the firewall is the lock this
verification credits and the client config is only the second one, so the test
has to bypass the second to measure the first.

So **temporarily** widen the client, run the checks, and put it back:

```ini
AllowedIPs = 10.0.30.0/24, 10.0.99.0/24, 10.0.50.0/24, 10.0.40.0/24
```

Toggle the tunnel off and on, confirm the route landed
(`route -n get 10.0.99.20` must name the utun interface), then:

```bash
# SUSTAINED, not -c1. WireGuard drops packets while re-establishing a
# handshake, so a single packet after any server restart is lost inside the
# client and reads as a firewall block. Ten seconds each, then control-C.
ping -i 1 10.0.99.20   # Winterfell
ping -i 1 10.0.50.10   # Hicks
ping -i 1 10.0.40.30   # CasaBonita
```

All must fail. **Then read the firewall, because the client cannot tell you
why they failed.** On `morpheus`, per-destination counters for the §7 rules:

```bash
pfctl -vsr | awk '/^block .* inet from <Tunnel_Peers> to </ {
  match($0, /to <[A-Za-z0-9_]+>/); d=substr($0, RSTART+3, RLENGTH-3);
  getline; match($0, /Packets: [0-9]+/); print d, substr($0, RSTART+9, RLENGTH-9) }'
# expect non-zero on each destination you probed. A zero everywhere means the
# packets never arrived, NOT that they were blocked — see the table below.
```

**Put `AllowedIPs` back to `10.0.30.0/24` afterwards** and re-check
`netstat -rn` shows only the lab. The widening is a test instrument and must
not outlive the test.

### Down, and the capability with it

```bash
sudo systemctl stop wg-quick@wg0

# Forwarding is off, because ExecStopPost turned it off (see §3's CAUTION —
# PostDown cannot do this here).
sysctl net.ipv4.ip_forward
# expect: net.ipv4.ip_forward = 0

# NO MASQUERADE RULE EXISTS — with the tunnel down or up. This is the check
# #442 asks for by name. Both must print nothing at all.
sudo iptables-save 2>/dev/null | grep -i masquerade
sudo nft list ruleset 2>/dev/null | grep -i masquerade
```

And from the client, with the tunnel down, the lab is gone:

```bash
ping -c1 -t3 10.0.30.40
# expect: failure. If this succeeds, check the route table above — you are on
# the house network, and Hicks reaches the lab with no tunnel at all.
```

### The leak drill

`build-the-playground.md` gives the range a drill that proves a leak would
report itself. The tunnel gets the sibling, and for the same reason: routed
mode means a peer's address appears on the wire, so a packet that escapes the
lab carries a source that cannot be anything else.

With the tunnel up, from the client, aim one packet at a segment the tunnel
must not reach — `ping -c3 -W3 10.0.99.20` — and then, on the monitoring host:

```bash
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (src) (count_over_time({app="filterlog", action="block"} | regexp `,(?P<src>\d+\.\d+\.\d+\.\d+),(?P<dst>\d+\.\d+\.\d+\.\d+),` | src =~ "172\\.31\\..+" [15m]))' \
  | jq '.data.result'
```

A row with a `172.31.x` source is the property working: the firewall stopped it
*and* said which peer tried. **An empty result is not a pass** — it means
either the packet never left the client (check the client's `AllowedIPs`
route), or the jumpbox never forwarded it, and you should find out which before
concluding the boundary held.

Addresses are parsed at query time rather than indexed
([ADR-0003](../adr/0003-observability-stack-selection.md)), which is why this
reaches for `regexp` rather than a label.

> [!IMPORTANT]
> **Test from off-estate, once, properly.** Every check above passes from a
> Hicks workstation whether or not the tunnel works, because Hicks reaches
> ImaginationLAN anyway (ADR-0031). A verification that cannot fail has not
> verified anything.

## Rollback

In reverse, and safe at every step — the estate's posture before this runbook
is strictly more closed than after it.

1. `sudo systemctl disable --now wg-quick@wg0` on the jumpbox. The inbound path
   is dead from here; everything below is tidying.
2. Delete the port forward and its associated filter rule (§6).
3. Delete the static route and the gateway (§5).
4. Delete the `Tunnel_Peers` rules and the alias (§7).
5. Revert the Loki rule change.
6. `sudo shred -u /etc/wireguard/server.key /etc/wireguard/wg0.conf`.

Removing **one peer** rather than the tunnel is a `wg0.conf` edit and
`sudo systemctl reload wg-quick@wg0`. ADR-0042 records that this does not scale
and that the first lost device is when it stops being proportionate.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| No handshake, ever | The port forward is not reaching the jumpbox, or the dynamic DNS record is stale | `sudo tcpdump -ni any udp port <LISTEN_PORT>` on the jumpbox while the client retries. No packets means §6 or the record — run §0 step 4, and *Force update* on the client if the name and the WAN address differ; packets but no handshake means the keys |
| Handshake succeeds, nothing routes | The static route in §5 is missing — replies are going to the lab's default gateway, which has never heard of the tunnel subnet | Add it. **Do not add a NAT rule to make this work** |
| Handshake succeeds, the jumpbox is reachable, no other lab host is | Forwarding is off. On Ubuntu 26.04 `PostUp` **cannot** set it and says it did | `sysctl net.ipv4.ip_forward` — expect 1 with the tunnel up. Then §3's CAUTION and its drop-in; `journalctl -u wg-quick@wg0` shows `permission denied on key` |
| Every §8 negative check "passes" and the firewall counters are all zero | The packets never reached the firewall. Either the client is correctly scoped (so they never entered the tunnel) or forwarding is off | Widen the client per §8, and check the counters rather than the ping. Zero everywhere is *not* a pass |
| Negative checks fail from a Mac in milliseconds | `ping -W` is milliseconds on macOS | `-t 3` instead. See §8's note |
| A single `-c1` ping fails right after a server restart | WireGuard drops packets while re-handshaking | Sustained `ping -i 1`, not `-c1`. §8 |
| The client reaches the lab but the firewall logs nothing at all | The blocks in §7 were copied without ticking **Log**, so the leak drill and `LabSegmentReachedInternalNetwork` are both blind | Re-check the Log column on all six. §7 |
| The client reaches the whole internet through the house | `AllowedIPs = 0.0.0.0/0` on the client | §4. This is the wide-`AllowedIPs` failure, and it is silent |
| The client reaches Winterfell | A block in §7 is missing or ordered below the catch-all | Check rule order on the ImaginationLAN interface. Treat as a live segmentation failure and read the tripwire log |
| `LabSegmentReachedInternalNetwork` fires | Either a real breach, or the rule was widened without the blocks | Both are urgent. Read the `filterlog` line: a `172.31.0.x` source is a peer, a `10.0.30.x` source is the lab |
| Everything works from the sofa and nothing from a hotel | You tested from inside the house | See §8's note. Hicks reaches the lab without any tunnel |
| Results that contradict each other across one test run | The client rejoined the house Wi-Fi partway through; macOS prefers Wi-Fi over tethering | Turn Wi-Fi **off**, and re-read the route table before each measurement rather than trusting where you think you are |

## What this does not do

- **It does not reach Winterfell, and it must not.** ADR-0022's second trigger
  ends the SSO deferral the moment the sensitive tier is reachable from outside
  the house. Terminating on 99, or routing the tunnel to the tier, fires it —
  that is a new ADR and an identity provider, not a rule change.
- **It does not authenticate a person.** A peer is a device with a key. There
  is no second factor and no account behind it; losing the device is losing the
  credential.
- **It does not revoke.** See Rollback.
- **It does not watch the WAN.** Suricata is not on that interface and
  `docs/security.md` says it deliberately never will be. The tunnel's inside is
  watched by the §7 tripwire; its outside is not watched at all.
- **It does not give the lab a route to the peers.** Traffic is initiated from
  the peer. Nothing on ImaginationLAN can open a connection to a device on the
  tunnel, and nothing should want to.
