# Runbook: Connect the switch to Home Assistant

Give Home Assistant a read-only view of `neo`, the CRS326, through the core
MikroTik integration: CPU, temperature, uptime, each port's link state and
the RouterOS update
([ADR-0111](../adr/0111-read-the-switch-from-home-assistant-over-api-ssl.md)).

**Target:** `morpheus`'s web UI, `neo` (`10.7.7.2`) over SSH or WinBox, and
`trinity` (`10.0.99.40`) with Home Assistant's web UI
**Time:** ~30 minutes
**Needs:** Hicks, for the firewall's and the switch's admin UIs
**Reversible:** §7

---

## Why this exists

Three earlier decisions keep Home Assistant away from the switch, and this
runbook opens each one by the narrowest amount. The RouterOS API is off
([`swap-the-switch.md`](swap-the-switch.md) §1.4). Winterfell is blocked from
the switch LAN ([ADR-0025](../adr/0025-close-the-switch-lan-to-winterfell.md)).
The switch speaks TLS only
([ADR-0041](../adr/0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md)).

The integration does **not** verify the switch's certificate, whatever its
*Verify SSL certificate* box says. ADR-0111 records that as a residual. §5
is the one check that does verify it, run by hand.

The integration gives **no presence** on a switch. It finds clients in a
wireless registration table or a DHCP server's leases, and `neo` has
neither.

## 1. The firewall pass

On `morpheus`, under Firewall → Rules → Winterfell, add a pass:

| Field | Value |
| --- | --- |
| Protocol | TCP |
| Source | `10.0.99.40` |
| Destination | `10.7.7.2`, port `8729` |
| Description | *Allow HA API to LAN Switch* |

Drag it **above** *Block access to the untagged LAN*, then apply. Check the
order in the running set from the firewall's shell:

```bash
pfctl -sr | grep -n -e 'Allow HA API to LAN Switch' -e 'Block access to the untagged LAN'
```

The pass's line number is the smaller one. Nothing listens on `8729` yet,
so from `trinity` a connection should now be refused by the switch. If it
times out instead, the switch has an input filter dropping it, or the pass is
missing. Look at the firewall's log for the block before you assume the
switch:

```bash
nc -zv -w 3 10.7.7.2 8729
```

## 2. A password

On any checkout:

```bash
make gen-secret
```

It is typed twice, into the switch in §3 and into Home Assistant in §6, and
kept nowhere else. Home Assistant writes it to `/config/.storage`, where
ADR-0035 says the tier's config-flow credentials live. If it is lost, set a
new one on the switch and reconfigure the integration.

## 3. The user and the service on `neo`

In a terminal on the switch (`ssh` to `neo.matrix.elysium`, or WinBox's
terminal), create a group that can read and nothing more, and a user in it
that only `trinity` can log in as:

```text
/user/group/add name=homeassistant policy=read,api,test
/user/add name=homeassistant group=homeassistant address=10.0.99.40/32 password="<from §2>"
```

No `write`, `reboot`, `policy` or `sensitive`. Without `write` the switch
refuses the port, PoE and restart controls the integration creates. Without
`sensitive` it hides the SNMPv3 passphrases.

Turn `api-ssl` on with the leaf `www-ssl` already serves, for `trinity` only.
Plain `api` stays off:

```text
/ip/service/set api-ssl certificate=neo.matrix.elysium address=10.0.99.40/32 disabled=no
/ip/service/print where name~"api"
```

`api` reads `X` (disabled), and `api-ssl` reads port `8729`, the
certificate and the address.

## 4. Name resolution from the container

Home Assistant is given the switch by name:

```bash
docker exec sensitive-home-assistant python3 -c "import socket; print(socket.gethostbyname('neo.matrix.elysium'))"
```

It prints `10.7.7.2`.

## 5. Prove the certificate, and that the user cannot write

Run this from the repository root on `trinity`. It does two things the
integration does not. It connects with the certificate **verified** against
the estate CA and the name checked, and it tries one harmless write: setting
the switch's identity to the name it already has.

```bash
read -rs NEO_HA_PW && export NEO_HA_PW
docker exec -i -e NEO_HA_PW sensitive-home-assistant python3 - <<'EOF'
import os, ssl, librouteros
from librouteros.exceptions import TrapError
from librouteros.login import plain

host = "neo.matrix.elysium"
ctx = ssl.create_default_context(cafile="/etc/home-assistant/ca-bundle.pem")
api = librouteros.connect(
    host, "homeassistant", os.environ["NEO_HA_PW"], port=8729,
    login_method=plain,
    ssl_wrapper=lambda s: ctx.wrap_socket(s, server_hostname=host),
)
name = tuple(api.path("/system/identity"))[0]["name"]
print("verified TLS, read identity:", name)
try:
    tuple(api("/system/identity/set", name=name))
    print("FAIL: the write was accepted")
except TrapError as e:
    print("write refused:", e)
EOF
unset NEO_HA_PW
```

The expected output is `verified TLS, read identity: …` and then
`write refused: … not enough permissions …`.

- A certificate error means `api-ssl` is serving something other than the
  estate leaf. Fix §3 before going on.
- `FAIL: the write was accepted` means the group has `write`. Remove it
  before going on.

The write sets the same name, so even a wrong group changes nothing.

## 6. Add the integration

In Home Assistant: Settings → Devices & services → Add integration →
**MikroTik**.

| Field | Value |
| --- | --- |
| Host | `neo.matrix.elysium` |
| Username | `homeassistant` |
| Password | from §2 |
| Port | `8729` |
| Verify SSL certificate | **on** (in this integration this turns TLS on, and verifies nothing) |

**Do not submit the form with the box off.** The integration then logs in
in plaintext, and `librouteros` sends the `/login` request, password
included, before it reads any reply. The TLS listener refuses the session,
but the password has already crossed Winterfell and the switch LAN in
clear. If that happens, treat the password as spent: set a new one on the
switch (§2, §3) and use that.

Then, on the new device's page, disable the entities that write: every
port's switch, any PoE select, and the *Restart*, *Shutdown* and *Backup*
buttons. The switch would refuse them anyway. Disabled, they don't sit on a
dashboard looking like controls.

Keep the two update entities, *RouterOS* and *RouterBOARD*, enabled. They
are where the installed and latest versions show, and disabling them loses
that. They do offer *Install*, and the RouterOS one offers a backup first.
The switch refuses both, because the group has no `write` or `reboot`. An
upgrade is still done by hand from Hicks, as before. Hide them from
dashboards if the button is a nuisance. Leave the options at their defaults: *Force scanning
using DHCP* and *ARP ping* have nothing to read on a switch.

Check: the CPU, memory, temperature and uptime sensors have values, and
each cabled port's binary sensor reads connected.

## 7. Afterwards

- `make check-firewall` stays clean. The pass is narrow, and
  `docs/firewall-claims.yaml` tracks only wholesale reach.
- In [`network.md`](../network.md) and [`security.md`](../security.md),
  move the pass from decided to in force, with the date and #1388.

**To undo:** delete the integration in Home Assistant, then on the switch
run `/ip/service/disable api-ssl`, `/user/remove homeassistant` and
`/user/group/remove homeassistant`. Delete the pass on `morpheus` last.
