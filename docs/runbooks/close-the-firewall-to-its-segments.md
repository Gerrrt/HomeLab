# Runbook: Close the firewall to its own segments

**Target:** `morpheus`, the firewall (pfSense CE 2.9.0)
**Time:** about 40 minutes, most of it the rule edits in §2 to §5
**You will need:** the pfSense web UI from a Hicks workstation, a shell on
`prometheus`, and the console at the rack in case a step locks the UI out

[ADR-0117](../adr/0117-close-the-firewalls-own-addresses-and-take-passwords-off-its-ssh.md)
decides this. Every interface's *Block SSH/HTTPS/HTTP to pfSense* rows named
only that interface's address, so every segment reached the admin UI and `sshd`
on the firewall's WAN address, and Hicks reached them on the lab's gateway as
well. This makes the blocks name `This Firewall (self)`, adds one pass for
`prometheus`, and then turns off password login to `sshd`.

> [!CAUTION]
> **Do §1 before anything else, and do §6 last.** §6 turns off SSH passwords.
> A machine whose key is not on `admin` before then can only get back in
> through the web UI or the console.

**The way back if the UI stops answering from Hicks** is the console at the
rack: **15) Restore recent configuration**, and pick the configuration from
before your edit. The second way back is a laptop cabled into an untagged port
on `neo`, where pfSense's anti-lockout rule still passes the UI on `10.7.7.1`.

---

## 1. Put every administering key on `admin`, and prove each one

`sshd` already accepts keys. Two are authorised today: `prometheus`'s, and one
other.

1. On each machine you administer the firewall from over SSH (the Hicks
   MacBook and desktop, at least), print the key's fingerprint:

   ```bash
   ssh-keygen -lf ~/.ssh/id_ed25519.pub
   ```

2. Compare against what the firewall holds:

   ```bash
   ssh root@10.0.99.1 'ssh-keygen -lf /root/.ssh/authorized_keys' | awk '{print $2}'
   ```

3. For each machine whose fingerprint is missing, paste its **public** key
   (the `.pub` file, never the private one) under **System → User Manager →
   admin → Authorized SSH Keys**, on its own line, then **Save**.

4. From each of those machines, prove the key works with passwords out of
   the way:

   ```bash
   ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no admin@10.0.99.1 true && echo key-ok
   ```

**You should see** `key-ok` from every machine. Do not go on to §6 until
you do.

## 2. Winterfell (OPT1)

**Firewall → Rules → Winterfell.**

### 2.1 Add the pass for `prometheus`

| Setting | Value |
| --- | --- |
| Action | Pass |
| Interface | Winterfell |
| Address family | IPv4 |
| Protocol | TCP |
| Source | Address or alias, `10.0.99.20` |
| Destination | Address or alias, `10.0.99.1` |
| Destination port range | SSH (22) to SSH (22) |
| Description | `Allow SSH to pfSense from prometheus` |

### 2.2 Re-point the two blocks, and add the third

Edit *Block HTTPS to pfSense* and *Block HTTP to pfSense*, then add *Block SSH
to pfSense* (copy one of them and change the port).

| Setting | Value |
| --- | --- |
| Action | Block |
| Address family | IPv4+IPv6 |
| Protocol | TCP |
| Source | Any |
| Destination | **This Firewall (self)** |
| Destination port range | SSH (22), HTTPS (443), HTTP (80): one per row |
| Description | `Block SSH to pfSense`, `Block HTTPS to pfSense`, `Block HTTP to pfSense` |

### 2.3 Order

Drag them to the top of the interface so it opens:

1. `Allow SSH to pfSense from prometheus`
2. `Block SSH to pfSense`
3. `Block HTTPS to pfSense`
4. `Block HTTP to pfSense`

Everything else follows in the order it already had. **Apply Changes.**

Then, from `prometheus`, prove its key still gets in before going further:

```bash
ssh -o BatchMode=yes root@10.0.99.1 true && echo prometheus-ok
```

If that fails, the pass is wrong or below the block. Fix it from the UI on
Hicks, which nothing on Winterfell's tab has touched.

## 3. Hicks (OPT2)

**Firewall → Rules → Hicks.** This tab is the one that can lock you out. The
UI you are using arrives by *Allow HTTPS to pfSense on its management address*,
and that pass must stay **above** the blocks.

Edit the three existing blocks, *Block SSH to pfSense*, *Block HTTPS to
pfSense* and *Block HTTP to pfSense*, the same way as §2.2: source **Any**,
destination **This Firewall (self)**, family **IPv4+IPv6**. Then drag the three
up so the top of the tab reads:

1. `Allow SSH from Mac to WSL` (where it already is; it never reaches the
   firewall)
2. `Allow SSH to Winterfell`
3. `Allow HTTPS to pfSense on its management address`
4. `Block SSH to pfSense`
5. `Block HTTPS to pfSense`
6. `Block HTTP to pfSense`
7. `Allow DNS to the resolver`, and the rest in their existing order

What matters is that the blocks sit above *Allow Hicks access to
ImaginationLAN*, which passes TCP to the lab's gateway, `10.0.30.1`. **Apply
Changes**, then reload the UI to prove the UI still answers.

## 4. CasaBonita, ImaginationLAN, Skids and Degens

On each of these four tabs, edit the three existing blocks as in §2.2: source
**Any**, destination **This Firewall (self)**, family **IPv4+IPv6**. They
already sit above every pass that could reach the firewall, so leave the order
as it is.

On Degens the three are named *Block SSH*, *Block HTTP* and *Block HTTPS*.
Rename them to match the other tabs while you are there.

On ImaginationLAN, source **Any** rather than *ImaginationLAN net* also
covers the WireGuard peers (`Tunnel_Peers`), which arrive on that interface from
another network. **Apply Changes** once, after the last tab.

## 5. The switch LAN

**Firewall → Rules → LAN.** Add the three blocks from §2.2 with interface
**LAN**, and drag them to the top of the user rules. pfSense's generated
*anti-lockout rule* still sits above them and keeps `10.7.7.1` reachable; that
is the second way back and it is meant to stay. **Apply Changes.**

## 6. Turn off SSH passwords

Only once every machine in §1 printed `key-ok`.

**System → Advanced → Admin Access → Secure Shell:** set **SSHd Key Only** to
**Public Key Only**, then **Save**. Leave *Allow Agent Forwarding* off. Root
login stays as it is: `prometheus`'s jobs log in as `root`, by key.

## 7. Verify

From `prometheus`, in a checkout of this branch or of `main` after it merges:

```bash
make check-firewall
```

**You should see** every line `PASS`, including the three `firewall` lines per
interface. Winterfell, CasaBonita, ImaginationLAN, Skids and Degens reach none
of the firewall's addresses. Hicks reaches `Winterfell` on ssh and https. The
switch LAN reaches its own address and its link-local, through the anti-lockout
rule. A `FAIL` names the interface, the port and the address by segment. Fix
the rule it points at rather than the claims file.

Then prove it with packets, from `prometheus`. The WAN address is read off the
firewall and never typed or printed:

```bash
wan="$(ssh root@10.0.99.1 'ifconfig em0 inet' | awk '/inet /{print $2; exit}')"
curl -sk -m 5 -o /dev/null -w 'https %{http_code}\n' "https://${wan}/"
timeout 5 bash -c "</dev/tcp/${wan}/22" && echo 'ssh OPEN' || echo 'ssh blocked'
unset wan
```

**You should see** `https 000` and `ssh blocked`. On 2026-11-13 the same two
read `https 200` and an open port.

And that passwords are gone:

```bash
ssh root@10.0.99.1 "sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '"
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no admin@10.0.99.1 true
```

**You should see** `passwordauthentication no`, `kbdinteractiveauthentication
no` and `permitrootlogin yes` from the first, and `Permission denied
(publickey)` from the second.

Last, from a Hicks workstation: the UI at `https://10.0.99.1` loads, and
`ssh admin@10.0.99.1` logs in without asking for a password.

## Rollback

- **One rule wrong:** fix it in the UI from Hicks, or from `prometheus` over
  SSH if it is the Hicks tab that broke.
- **The UI unreachable from Hicks:** the console at the rack, **15) Restore
  recent configuration**, and choose the one saved just before the change.
  Or cable a laptop into an untagged port on `neo` and use `https://10.7.7.1`.
- **A key missing after §6:** set *SSHd Key Only* back to *Password or Public
  Key* from the UI, add the key, and set it again.
