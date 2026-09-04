# Runbook: Add a host override

Give an internal name an address, so that `lemmiwinks.matrix.elysium` resolves
instead of returning NXDOMAIN.

---

## Why this exists

Every internal name this estate documents was written down before any of them
resolved. On 2026-08-30 a blackbox probe of the wiki failed at the resolver
rather than at the connection, and a sweep found the same thing across the
board:

| Name | Answer |
| --- | --- |
| `morpheus.matrix.elysium` | `10.0.99.1` |
| `lemmiwinks.matrix.elysium` | NXDOMAIN |
| `oracle.matrix.elysium` | NXDOMAIN |
| `prometheus.matrix.elysium` | NXDOMAIN |
| `grafana.matrix.elysium` | NXDOMAIN |

The resolver is healthy — it answers for external names, and `morpheus` resolves
because it is the firewall's own hostname. What was missing is the overrides.

This matters more than a convenience usually would. `lemmiwinks.matrix.elysium`
is printed on the break-glass card on the fridge, which is the one copy of the
documentation that cannot be corrected remotely. And this stack issues a TLS
certificate for `grafana.matrix.elysium`, so Grafana presents a certificate for
a name nothing can look up.

---

## Before you start

**Take a configuration backup.** *Diagnostics → Backup & Restore → Download
configuration as XML.* This is a small change to the machine every other machine
depends on, and the restore procedure has never been rehearsed — see
[`restore-the-firewall.md`](restore-the-firewall.md), which says so on its face.

Have console access available if you are doing anything beyond the steps here.
The KVM in the rack is that access.

---

## Add the override

*Services → DNS Resolver → Host Overrides → Add.* One entry per name:

| Host | Domain | IP Address | Description |
| --- | --- | --- | --- |
| `lemmiwinks` | `matrix.elysium` | `10.0.99.30` | Wiki — the name on the printed card |
| `oracle` | `matrix.elysium` | `10.0.99.30` | The machine the wiki runs on |
| `prometheus` | `matrix.elysium` | `10.0.99.20` | Monitoring host |
| `grafana` | `matrix.elysium` | `10.0.99.20` | Dashboards — matches the certificate's CN |
| `neo` | `matrix.elysium` | `10.7.7.2` | The switch — ADR-0018. Note the subnet: this one is not `10.0.99.x` |

`morpheus` needs no entry. It already resolves — and note it answers with **two**
addresses, `10.0.99.1` and `10.7.7.1`, because pfSense registers the firewall's
own hostname on each interface. That is not a misconfiguration, and a `dig` that
shows one or the other is round-robin rather than drift.

> [!NOTE]
> **The first four were applied on 2026-08-30 and verified.** The procedure below
> is what was run; it is kept for the next name, not because those four are
> outstanding. `neo` is the fifth and was added later, by
> [ADR-0018](../adr/0018-name-the-switch-and-leave-its-ui-on-plain-http.md) —
> check it with the `dig` below rather than assuming, since it is the one row
> here that has not been true for as long as the others.

**`oracle` and `lemmiwinks` share an address on purpose.** One machine, two
names: the wiki is a container on Oracle. Either add two entries or add one for
`oracle` and put `lemmiwinks` in *Additional Names for this Host* — both work,
and the alias form makes the shared identity visible to whoever reads the list
next.

Then **Save**, then **Apply Changes**. Unbound reloads on apply.

> [!IMPORTANT]
> **Host Overrides, not Domain Overrides.** They sit next to each other on the
> same page and do opposite things. A host override answers a name locally; a
> domain override forwards an entire zone to a different server. Putting
> `matrix.elysium` in the wrong box sends every internal lookup somewhere that
> has never heard of this estate, and the symptom is that everything stops
> resolving rather than one thing.

---

## Verify

From a machine that uses pfSense as its resolver:

```bash
dig +short @10.0.99.1 lemmiwinks.matrix.elysium
dig +short @10.0.99.1 oracle.matrix.elysium
dig +short @10.0.99.1 prometheus.matrix.elysium
dig +short @10.0.99.1 grafana.matrix.elysium
dig +short @10.0.99.1 neo.matrix.elysium
```

**Five answers, three distinct addresses** — match each against the table above
rather than counting them. `oracle` and `lemmiwinks` both answer `10.0.99.30`,
and `grafana` and `prometheus` both answer `10.0.99.20`, because each pair is
two names for one machine. A duplicate here is the expected result, not a
copy-paste error in the override table.

Query `@10.0.99.1` explicitly rather than relying on the client's configured
resolver — otherwise a wrong answer from a local cache looks like a wrong answer
from Unbound.

`neo` is the one worth reading carefully: it should answer `10.7.7.2`, and it is
the only one of the five that does not land in `10.0.99.x`. An answer on the
management subnet means the row was typed from muscle memory.

> [!IMPORTANT]
> **A name that failed before may keep failing for a while after you fix it.**
> Unbound caches negative answers, and so does every client that already asked.
> If a name still returns nothing a minute after Apply, that is expected and not
> a reason to start editing again.
>
> Clear it rather than waiting: `resolvectl flush-caches` on a systemd Linux
> client, and *Diagnostics → DNS Lookup* on pfSense itself, which bypasses the
> client entirely and is the honest test of whether the override took.

---

## What this does not do

**It does not give every name a reverse entry — the first one wins.** pfSense
writes a `local-data-ptr` alongside the forward record, but only for the *first*
override that claims a given address. Adding `lemmiwinks` and then `oracle`, both
on `10.0.99.30`, produces a PTR for `lemmiwinks` and none for `oracle`:

```text
local-data-ptr: "10.0.99.30 lemmiwinks.matrix.elysium"
local-data: "lemmiwinks.matrix.elysium. A 10.0.99.30"
local-data: "oracle.matrix.elysium. A 10.0.99.30"
```

So **the order you add two names for one machine decides which one shows up in
reverse lookups**, and therefore in anything that logs by PTR. Add the name you
want to read in logs first. Changing your mind later means deleting both and
re-adding them in the other order — editing the second one does not promote it.

**It does not make a service reachable.** A name resolving means only that the
address is known. If the service behind it is down, the failure simply moves one
step later — from "no such host" to "connection refused" — which is progress but
is not the same as being fixed.

---

## Adding another name later

The same steps. Two things worth doing at the same time:

- Add it to the blackbox probe targets so the name is watched from the moment it
  exists — `stacks/observability/prometheus/targets/blackbox.yaml`, hot-reloaded,
  no restart. (That file arrives with
  [#168](https://github.com/Gerrrt/HomeLab/pull/168); skip this step until it
  has merged.)
- Write it down in `docs/network.md` if it is a host that belongs in the
  inventory. A name that only exists in the firewall's configuration is a name
  nobody will find when it stops working.

Reaching the MokerLink management interface by name
([#97](https://github.com/Gerrrt/HomeLab/issues/97)) is this procedure and
nothing more — `neo` is in the table above. This paragraph used to say the
override was "not solved by an override alone" because `10.7.7.2` "sits outside
every documented subnet". Both halves were wrong.

The address is documented — [`network.md`](../network.md) has a LAN section for
it — it is only outside the `10.0.x` convention, which is a memory problem and
not a routing one. And the certificate that was supposed to be the harder half
is not hard, it is unavailable: the switch has no TLS listener to point one at.
[ADR-0018](../adr/0018-name-the-switch-and-leave-its-ui-on-plain-http.md)
records the check and closes that half. The UI stays at
`http://neo.matrix.elysium/`, and `10.7.7.2` stays written down beside it,
because the name needs `morpheus` and the switch is what you reach for when
`morpheus` is the suspect.
