# Runbook: Build `phoenix`, the deployment host

**Target:** `phoenix` — a guest on `Saruman`, ImaginationLAN (VLAN 30)
**Time:** about an hour, most of it the OS installer
**You will need:** the Proxmox web UI on `Saruman` (or a shell on it through
the KVM or `shiva`), an Ubuntu Server ISO, the pfSense UI on `morpheus` for one
reservation, a shell on `alexander` for §5,
and the Mac for §6 — it is the only machine that reaches this segment with a
checkout in hand
**After this:** [`open-the-remote-path.md`](open-the-remote-path.md), if the
remote path is wanted —
[ADR-0042](../adr/0042-terminate-the-remote-path-on-the-lab-and-route-it.md)
terminates the WireGuard tunnel on this host, and its runbook begins where
this one ends

> **Status — 2026-09-20: `phoenix` is built and its agent is pushing to
> `alexander`.**
>
> Ubuntu 26.04 LTS, `10.0.30.70`, VMID 170, `bc:24:11` OUI, ISO
> `ubuntu-26.04.1-live-server-amd64.iso`. §4's `curl`: *(pending the §4
> report)*. §7 passed: `make validate` green in the guest's own checkout (16
> host-specific skips — no Docker, no age key, by design), both
> `up{instance="phoenix"}` jobs at `1`, and four Loki jobs — `auth.log`,
> `syslog`, `/var/log/*.log` and the journal — so 26.04.1 ships rsyslog as
> 26.04 did. The lab's ports were opened ahead of the guest by #543 and
> applied on `alexander` in §5, the first time `deploy-agent.sh`'s
> `--monitoring-host` flag was used. Two things the first run found and this
> runbook now carries: `VM.Monitor` is not a privilege on PVE 9, and the node
> is `Saruman`, capitalised — and one it could not fix, #566: the hypervisor's
> firewall was never on, so the `8006` line was not written.

This builds the host [ADR-0043](../adr/0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md)
decided: the one machine whose purpose is to hold credentials for other
machines — a Proxmox API token, an SSH key, a checkout — so that the Packer,
OpenTofu and Ansible issues that follow
[#436](https://github.com/Gerrrt/HomeLab/issues/436) have somewhere to run
from. It is the shape of [`build-the-lab-guest.md`](build-the-lab-guest.md)
and leans on it: where a step is identical, this says so and points there
rather than carrying a second copy that drifts. Where this guest differs, it
differs in what it does **not** get: no compose stack, no Docker, no age key,
and no certificate authority.

---

## 0. What is decided, and why

| | Decision | Why this and not the obvious alternative |
| --- | --- | --- |
| Name | `phoenix` | Every named host on this segment is a Final Fantasy summon — `shiva`, `ifrit`, `alexander`, `odin`, ADR-0029's six — and this continues it. The one whose meaning fits the job: the thing that rebuilds everything else |
| Address | `10.0.30.70/24` | Static below `.100`, the next decade after `odin`'s `.60`. `.20` is reserved for `Saruman`'s own move ([`build-the-playground.md`](build-the-playground.md) §3) |
| VMID | `170` | Last octet legible from `qm list`, as `alexander` is `140` and `odin` is `160` |
| Kind | **VM, not LXC** | The toolchain will want nested virtualisation off and a kernel of its own for Packer's boot ISOs; an LXC shares the host's. Same answer as the other two guests, for a different reason |
| OS | **Ubuntu Server LTS** | Same reason as `alexander`: `config.alloy` tails `/var/log/auth.log` and `/var/log/syslog`, and a journald-only install collects nothing from either while reporting healthy. §7 is the check |
| vCPU | 2 | Packer waits on other machines; OpenTofu plans. Neither is compute |
| RAM | 4 GiB | Enough for Packer to hold a boot ISO in the page cache while a build runs. Bounded, not measured |
| Disk | 32 GB | A checkout, a few ISOs, the toolchain's binaries. `discard=on` so a deleted ISO returns its space to `local-lvm` |
| Stack | **none** | It runs no compose stack and no Docker at all. The Alloy agent is the native package, deployed by `scripts/deploy-agent.sh` the way `Saruman`'s is |
| Pushes to | `alexander`, `10.0.30.40` | Never `10.0.99.20`: guests get no pass into Winterfell (ADR-0007), and everything this host needs is on its own segment |
| Remote path | **Not here** | ADR-0042 terminates the WireGuard tunnel on this host, and [`open-the-remote-path.md`](open-the-remote-path.md) builds it — after this runbook, starting with the dynamic DNS record its §0 creates under [ADR-0044](../adr/0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md) |

> [!CAUTION]
> **`certificates/ca-key.pem` does not come here, and ADR-0043 is why.** This
> is the host that holds credentials for every other host on the segment, and
> — once ADR-0042's tunnel is built — the host the estate's only inbound path
> from the internet terminates on. The
> key every other host trusts stays on `prometheus`, the same rule
> [`build-the-lab-guest.md`](build-the-lab-guest.md) §5 gives for `alexander`.
> If the toolchain ever needs a certificate for a guest it built, the leaf is
> issued on the monitoring host and carried here the way that runbook carries
> it — never the key, and never `make certs ARGS=--ca` on this machine.

## 1. Create the VM

On `Saruman`, as for `alexander` (§1 there explains every flag; nothing about
them changes except the numbers):

```bash
qm create 170 \
  --name phoenix \
  --ostype l26 \
  --cpu host --cores 2 --sockets 1 \
  --memory 4096 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:32,discard=on,iothread=1 \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 \
  --onboot 1 \
  --ide2 local:iso/ubuntu-26.04-live-server-amd64.iso,media=cdrom \
  --boot order='scsi0;ide2'
```

The ISO name is whatever `pvesm list local --content iso` prints; `alexander`
runs 26.04 and the same image serves. `--onboot 1` is for the day `Saruman`
reboots under a maintenance window: a deployment host that stays down is a
toolchain nobody can run, and nothing else brings it back.

## 2. Install Ubuntu Server

As `alexander`'s §2, with these values. **Hostname `phoenix`** —
`deploy-agent.sh` takes the host label from `hostname` on the target, and it
becomes `instance` and `host` on every series and line this guest ships.

| | |
| --- | --- |
| Address | `10.0.30.70/24` |
| Gateway | `10.0.30.1` |
| DNS | `10.0.30.1` — Unbound on the gateway ([ADR-0010](../adr/0010-keep-the-resolver-on-the-gateway.md)) |

Install OpenSSH. **Install no Docker** — not the snap the installer offers,
not the repository package afterwards. There is nothing here for it to run,
and `deploy-agent.sh` reads the absence as its cue to install the native
package.

## 3. The reservation on `morpheus`

Read the guest's MAC from the hypervisor:

```bash
qm config 170 | grep net0
```

Then one reservation on `morpheus`, under *Services → DHCP Server →
ImaginationLAN*, mapping it to `10.0.30.70`.

> [!IMPORTANT]
> **The reservation is not what protects an address below `.100`.** The pool
> is `.100–.200` and this address sits outside it, so nothing was going to
> lease it anyway. The reservation is there so the address is recorded where
> a reader looks for it — the static is set on the host, the reservation on
> the server, and both are done because either alone is a single point of
> drift. [`build-the-lab-domain.md`](build-the-lab-domain.md) §2 says the same
> for the domain's six.

## 4. The Proxmox user, the role, the token — and the door

**On `Saruman`.** This is the estate's first hypervisor API credential, and
the role is its own so that what it can do is a list rather than
`PVEAdmin`:

```bash
pveum role add PhoenixBuilder --privs \
  "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit \
   VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network \
   VM.Config.Options VM.Console VM.PowerMgmt VM.Audit VM.Snapshot \
   Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit SDN.Use"
pveum user add phoenix@pve --comment "deployment host, ADR-0043"
pveum acl modify /vms --users phoenix@pve --roles PhoenixBuilder
pveum acl modify /storage/local --users phoenix@pve --roles PhoenixBuilder
pveum acl modify /storage/local-lvm --users phoenix@pve --roles PhoenixBuilder
pveum acl modify /sdn/zones/localnetwork/vmbr0 --users phoenix@pve --roles PhoenixBuilder
pveum acl modify /nodes/Saruman --users phoenix@pve --roles PVEAuditor
pveum user token add phoenix@pve builder --privsep 0
```

Five of those are worth knowing rather than copying:

- **No `VM.Monitor`.** Packer's own permission list still names it, and the
  first run of this section copied it in; Proxmox VE 8 dropped the privilege,
  so on 9 `pveum role add` rejects the whole list and every `acl modify`
  after it fails with "role does not exist". The boot command Packer types
  goes through `sendkey`, which is `VM.Console`, already granted. A `pveum`
  error here means the role was never made — fix the list and rerun the
  role and the four ACLs; the `PVEAuditor` line and the token are unaffected.
- **`/vms`, the two storages and the bridge, and nothing under `/nodes` but
  audit.** The token that can create guests must not be able to touch the
  host firewall ADR-0014 depends on, and `PVEAuditor` on the node is
  read-only. When Packer or OpenTofu fail with `Permission check failed`,
  the fix is a privilege added to `PhoenixBuilder`, not the role granted at
  `/`.
- **`/nodes/Saruman`** is the node name as `pvesh get /nodes` prints it — the
  hostname, case and all, and the same string names the directory under
  `/etc/pve/nodes/` and the path in every API URL. This runbook first said
  lower-case and the ACL went onto a path that does not exist; `pveum acl
  modify` does not check. `pveum acl list | grep phoenix` is the check.
- **`--privsep 0`** is the issue's choice: the token carries the user's
  permissions and there is no second set to keep in step. The trade is that
  it is exactly as powerful as the user, which is why the user is this narrow.
- **The secret prints once.** Copy it now; it cannot be shown again, only
  regenerated. Copy it into the file in the next block and nowhere else — a
  session transcript or a chat is a log, and a secret pasted into one is
  rotated, not kept. `pveum user token remove phoenix@pve builder` and the
  `token add` line again is the whole rotation.

**Then the door — which, on the day, had no wall.** ADR-0014 closes `8006`
on `Saruman` to `10.0.50.0/24` and this guest is not on it. ADR-0043 admits
one address, on this port and no other. The line is, in
`/etc/pve/nodes/Saruman/host.fw`, beneath the three rules ADR-0014 wrote:

```ini
IN ACCEPT -source 10.0.30.70 -p tcp -dport 8006 -log nolog
```

> [!CAUTION]
> **Check before writing it:** `pve-firewall status` and
> `ls /etc/pve/firewall/cluster.fw /etc/pve/nodes/Saruman/host.fw`. On
> 2026-09-20 the answer was `disabled/running` and neither file — ADR-0014's
> rules had never been applied on `Saruman`, because the runbook that applies
> them, [`build-the-playground.md`](build-the-playground.md) §4, is gated on
> #101 and had not run. Do not turn the firewall on as a side effect of this
> line: a `DROP` input policy with the rules unrendered locks you out of a
> machine whose console is a KVM switch away. **The line above was not
> written**; [#566](https://github.com/Gerrrt/HomeLab/issues/566) carries
> enabling the firewall with all four rules, with the console to hand, and
> until it is done every address on this segment reaches `8006`.

**On `phoenix`**, the credential and the key:

```bash
install -d -m 700 ~/.config/proxmox
umask 077
cat > ~/.config/proxmox/phoenix.env <<'EOT'
PROXMOX_URL=https://10.0.30.110:8006/api2/json
PROXMOX_TOKEN_ID=phoenix@pve!builder
PROXMOX_TOKEN_SECRET=<paste the secret>
EOT
ssh-keygen -t ed25519 -C phoenix -f ~/.ssh/id_ed25519
git clone https://github.com/Gerrrt/HomeLab.git ~/HomeLab
```

That file is mode 600, on this host, and **not in the repository** — a
stated deviation from #436's "credential into `secrets/`", and ADR-0043
records why it is forced: `check_sops_rules.py` proves every `.sops.yaml`
rule against the stack directories, so a `phoenix` rule fails CI until a
`stacks/phoenix` exists. The toolchain issue that consumes the token defines
the encrypted file; this runbook does not guess its shape. The SSH key is the
one the toolchain will inject into every guest it builds. It is generated
here and goes nowhere else. The checkout holds **no age key**: `make render`
fails here by design, and this host converges nothing — ADR-0021 owns what
happens to a machine after it exists.

Prove the door and the token together, from `phoenix`:

```bash
set -a; . ~/.config/proxmox/phoenix.env; set +a
curl -sk -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "${PROXMOX_URL}/nodes/Saruman/qemu" | python3 -m json.tool | grep '"name"'
```

`alexander` and `phoenix` at minimum. A connection timeout is the door — the
`host.fw` line is missing or the firewall was not reloaded (`pve-firewall
compile` shows what it thinks the rules are) — or, while #566 is open, the
network, because there is no door to be shut. A `401` is the token. An empty
list with a `200` is the ACL: the user can reach the node and see no guests,
which is also what a `PVEAuditor` grant on a mis-cased node path looks like.

## 5. Open the lab's doors

This guest's Alloy pushes to the lab's Prometheus and Loki. The two `ports:`
blocks in `stacks/lab/compose.yaml` and the two port lines in
`stacks/lab/.env.example` landed commented, waiting for a client with no
scrape alternative, and this guest is the one that came first: the change
that publishes all four is in the repository
([#436](https://github.com/Gerrrt/HomeLab/issues/436), 2026-09), ahead of the
guest by days so the agent has somewhere to push on first boot.
[`build-the-soc-guest.md`](build-the-soc-guest.md) §7 now only confirms it.
What is left is applying it where the stack runs, **on `alexander`**:

```bash
cd ~/HomeLab
git pull
make up STACK=lab
ss -ltn '( sport = :9090 or sport = :3100 )'
```

Both lines must show `10.0.30.40` or `0.0.0.0`. Then from `phoenix`:

```bash
nc -zv -w 3 10.0.30.40 9090 3100
```

Both open: on to §6. Nothing on `morpheus` is involved — the path is
intra-segment.

Being scraped by `alexander` instead, the way ADR-0029's six Windows machines
are, would have needed no `ports:` change at all. It loses because a
deployment host's value in an incident is its logs — what it did, to which
guest, when — and a scrape carries nothing to Loki. That is why this step
exists rather than a `scrape_configs` entry.

## 6. The Alloy agent, from the Mac

The script's native path needs root or passwordless sudo on the target
(`deploy-agent.sh` refuses otherwise, and says so). On `phoenix`, for the
installer's first user:

```bash
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/deploy >/dev/null
sudo chmod 440 /etc/sudoers.d/deploy
```

That is a trade, and it is the same one every host `deploy-agent.sh` ships to
natively makes: a redeploy after an image bump is one command from a laptop
rather than an evening, and the account it runs as already holds a key that
can build every guest on the segment.

Then from a checkout **on the Mac** — Hicks reaches this segment and
`prometheus` does not, and the script's header says it is safe from macOS:

```bash
./scripts/deploy-agent.sh --runtime native --monitoring-host 10.0.30.40 <user>@10.0.30.70
```

Two flags, both load-bearing:

- **`--monitoring-host 10.0.30.40`** is the lab's stack on `alexander`. The
  flag defaults to `10.0.99.20`, which from this segment is the wrong stack
  *and* an unreachable address, and omitting it fails in a way that reads as
  a firewall problem. This is the first use of the flag in the estate.
- **`--runtime native`** is a statement, not an autodetect: there is no Docker
  here to detect, and if one day there is, this line still says which was
  meant.

The script's own arrival check queries `10.0.30.40` afterwards. If it warns
*"is the pass to 10.0.30.40:9090 in place?"* the answer is that there is no
pass to place — go back to §5, because that message was written for hosts on
another VLAN and this one is not.

## 7. Verify — including the thing that fails quietly

```bash
make validate
```

From the Mac's checkout; it does not need the guest. Then the things it
cannot see, in the **lab's** Grafana at `https://10.0.30.40:3000/` — not the
estate's, which this host never reaches. Explore, Prometheus datasource:

```promql
up{instance="phoenix"}
```

Two jobs, `phoenix-metrics` and `phoenix-alloy`, both `1`. Three on a Docker
host is the count `alexander` shows; two is right here, because there is no
cAdvisor to scrape and nothing for it to report on. Loki datasource:

```logql
count by (job) (count_over_time({host="phoenix"} [15m]))
```

Three jobs at minimum: `/var/log/auth.log`, `/var/log/syslog` and
`/var/log/journal`. **Two is the failure this section exists to catch**, not a
quiet host — a journald-only install, and `sudo apt-get install -y rsyslog`
on `phoenix` fixes it. Check it on the host too:

```bash
ls -l /var/log/auth.log /var/log/syslog
```

And the door, once more, from `phoenix` — §4's `curl` — because §6 may have
rebooted nothing but §5 may have restarted the lab stack, and an API that
answered an hour ago is the one thing in this runbook with a firewall between
it and this host.

## 8. Write it down

The guest is not built until the documents say so, and `make check-docs`
walks you through the first three:

- `docs/network.md` — a row for `phoenix` in the ImaginationLAN table, and the
  planned-guest note in that section becomes a description. Say in it that
  this is the one address on the segment with a path to `8006`, because
  `firewall-claims.yaml` cannot say it for you.
- `docs/architecture.md` — drop `**Not built yet**` from the `phoenix` row.
  The marker is load-bearing: while it stands, `check_docs.py` requires the
  host to be **absent** from `network.md`, so the row and the marker cannot
  coexist.
- `docs/hardware.md` — removing the marker raises the Alloy agent count, and
  the sentence there that states it fails until it says the new number.
- `docs/network.md`'s WAN note, which says the jumpbox does not exist — it
  does now. The endpoint is decided
  ([ADR-0044](../adr/0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md));
  whether its dynamic DNS client is configured yet is
  [`open-the-remote-path.md`](open-the-remote-path.md) §0's business, not this
  runbook's.
- `docs/observability.md` — the sentence that says what pushes to `alexander`
  gains a host, and the one that says the lab's ports are shut stops being
  true, if §5 was yours.
- [#436](https://github.com/Gerrrt/HomeLab/issues/436) closes on the day this
  section is done — not on the day the guest comes up.
