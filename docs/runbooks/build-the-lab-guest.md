# Runbook: Build `alexander`, the guest that runs `stacks/lab`

**Target:** `alexander` — a guest on `Saruman`, ImaginationLAN (VLAN 30)
**Time:** about an hour, most of it the OS installer
**You will need:** the Proxmox web UI on `Saruman` (or a shell on it through the
KVM or `shiva`), an Ubuntu Server ISO, and a shell on the monitoring host for
the certificate in §5

This builds the host [ADR-0020](../adr/0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)
called for: a guest, **not** the hypervisor, because a compose stack is Docker
and Docker would rewrite the iptables of the box whose own firewall ADR-0014
relies on. That is the same fact that put the native `.deb` agent on `Saruman`
rather than a container ([#88](https://github.com/Gerrrt/HomeLab/issues/88)).

Closes [#262](https://github.com/Gerrrt/HomeLab/issues/262). The stack it runs
is already built and validated; what is missing is somewhere to run it.

---

## 0. What is decided, and why

| | Decision | Why this and not the obvious alternative |
| --- | --- | --- |
| Name | `alexander` | A Final Fantasy summon, like `shiva` and `ifrit` already on this segment. A fortress, which is what the defended estate's own observer is |
| Address | `10.0.30.40/24` | Statics on this segment live **below `.100`**; the pool is `.100–.200`. Continues the decade spacing — `shiva` .10, `Saruman` .20 (after #96), `ifrit` .30 |
| Kind | **VM, not LXC** | `stacks/lab` uses `cgroup: host`, `cap_drop: [ALL]` and a Docker socket mount. Docker in an LXC needs nesting and keyctl workarounds, and those settings behave differently under one. A VM has no such asterisks |
| OS | **Ubuntu Server 24.04 LTS** | See below. This is the one that would have bitten quietly |
| Disk | 64 GB | Prometheus is capped at 4 GB and Loki keeps 15 days of a small estate. 64 GB leaves room without pretending the spindles are free |
| RAM | 8 GB | The estate's whole stack runs on a 2012 MacBook with 8 GB. This one is smaller and has headroom for the domain arriving |

> [!IMPORTANT]
> **Ubuntu, not Debian, and the reason is not taste.**
> `alloy/config.alloy` — which this stack mounts unchanged from
> `stacks/observability/alloy/` — tails `/var/log/auth.log` and
> `/var/log/syslog` as explicit file sources, alongside the journal. A default
> Debian 12/13 install ships **no rsyslog**: journald only, and neither file
> exists. Alloy would start cleanly, report healthy, and collect nothing from
> two of its four log sources.
>
> That is the exact failure this repository keeps paying for — #62 and #63 were
> both collectors that ran healthy and produced nothing. Ubuntu Server 24.04
> ships rsyslog, has both files, and is what `prometheus` and `oracle` already
> run, so the agent behaves identically on every Linux host in the estate.
>
> If you ever do put this on Debian, install `rsyslog` in the same breath and
> check §7 rather than assuming.

## 1. Create the VM

VMID `140`, so the last octet is legible from `qm list`. Storage is `local-lvm`
on a stock Proxmox install — check `pvesm status` if yours differs, and the ISO
name will be whatever you uploaded.

```bash
qm create 140 \
  --name alexander \
  --ostype l26 \
  --cpu host --cores 4 --sockets 1 \
  --memory 8192 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:64,discard=on,iothread=1 \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 \
  --onboot 1 \
  --ide2 local:iso/ubuntu-24.04-live-server-amd64.iso,media=cdrom \
  --boot order='scsi0;ide2'
```

Four of those are worth knowing rather than copying:

- **`--net0 ... bridge=vmbr0`, and no VLAN tag.** `Saruman` is single-homed on
  VLAN 30 with no trunk and no VLAN-aware bridge (ADR-0007), so `vmbr0` *is*
  ImaginationLAN, untagged. A `tag=` here would put the guest on a VLAN the
  switch port does not carry, and it would simply have no network.
- **`--balloon 0`.** Ballooning on a 128 GB host with an 8 GB guest buys
  nothing, and it makes the guest's own memory metrics — which this VM exists
  to collect — move for reasons that are not the workload.
- **`--onboot 1`.** Nothing converges this stack (`converge.sh` runs a bare
  `make up`, which is the estate's) and nothing outside the lab notices if it
  dies ([#257](https://github.com/Gerrrt/HomeLab/issues/257)). Coming back by
  itself after a `Saruman` reboot is the cheapest resilience available.
- **`iothread=1` with `virtio-scsi-single`.** They pair; `iothread` does
  nothing without the `-single` controller, and this is a spinning RAID 1 pair
  that benefits from not serialising behind the emulator thread.

Leave the disk cache at the Proxmox default. The DL360's Smart Array cache is
enabled and battery-backed again since the pack was fitted on 2026-09-02
([#76](https://github.com/Gerrrt/HomeLab/issues/76)) — but that runbook records
`cpqDaAccelWriteCachePercent` still reading `0`, unexplained. Until that is
understood, `writeback` here would be leaning on a cache nobody has confirmed
is absorbing writes.

## 2. Install Ubuntu Server

Nothing unusual. During the installer:

- **Hostname `alexander`.** `scripts/render-config.sh` writes `ALLOY_HOSTNAME`
  from `hostname` at render time, and every metric and log line this host
  produces is labelled with it. Getting it wrong here means relabelling a
  Loki stream later.
- **Static addressing**, not DHCP — `.40` is outside the pool and belongs to
  this host:

  | | |
  | --- | --- |
  | Address | `10.0.30.40/24` |
  | Gateway | `10.0.30.1` |
  | DNS | `10.0.30.1` — Unbound on the gateway, per [ADR-0010](../adr/0010-keep-the-resolver-on-the-gateway.md) |

- **Install OpenSSH.** Skip the snap Docker the installer offers; §3 uses the
  official repository so the version is one apt manages.

## 3. Docker, the agent, and the repository

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl git make
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Log out and back in so the group takes effect, then clone the repository. The
lab stack is deployed from a checkout **on this host** — `make render` writes
into the checkout it runs from, so rendering anywhere else produces a file no
container here mounts.

```bash
git clone https://github.com/Gerrrt/HomeLab.git ~/HomeLab
```

You also need SOPS and age on this host for §4:

```bash
sudo apt-get install -y age
```

`sops` has no Ubuntu package — take the `.deb` from its GitHub releases page and
match the version to whatever the monitoring host runs (`sops --version` there).

## 4. Its own age key

**On `alexander`, never on the monitoring host.**

```bash
cd ~/HomeLab
make secrets-init STACK=lab
make secrets-edit STACK=lab
```

`secrets-init` generates a keypair here and writes the public half into
`.sops.yaml`, into the rule that matches `secrets/lab.*` — which sits above the
catch-all precisely so this key cannot also decrypt the estate's SNMP
communities and Grafana admin password. Run on the monitoring host it would do
exactly that, so `bootstrap.sh` refuses when the key it would write is already a
recipient of another rule. If you see that refusal, you are on the wrong
machine.

`secrets-edit` wants one value, `GRAFANA_ADMIN_PASSWORD`. Generate it with
`make gen-secret`. **Not the estate's password** — two Grafanas sharing one is
one credential, and the whole reason there are two is that the lab is the one
assumed to be compromised.

Commit and push `.sops.yaml` and `secrets/lab.sops.yaml` from here; the
ciphertext belongs in the repository, the private key never does.

> [!WARNING]
> **If `secrets-edit` says `no identity matched any of the recipients`,** the
> file was encrypted to the estate's key rather than this host's. That was a
> real bug in the lab's `path_regex` — it matched nothing, so sops fell through
> to the catch-all — fixed on 2026-09-05, and
> `scripts/check_sops_rules.py` now fails CI on any rule that matches no file.
>
> Recover on this host. Nothing is lost: the file holds only the template's
> placeholder values, and it was never committed.
>
> ```bash
> cd ~/HomeLab
> rm secrets/lab.sops.yaml
> git checkout .sops.yaml
> git pull
> make secrets-init STACK=lab
> make secrets-edit STACK=lab
> ```
>
> `git checkout .sops.yaml` discards the public key `secrets-init` wrote there
> so the pull applies cleanly; the re-run puts it back, into a rule that now
> matches. Your age private key in `~/.config/sops/age/keys.txt` is untouched
> throughout — `secrets-init` reuses an existing keypair rather than minting a
> second.
>
> Confirm the separation is real before moving on:
>
> ```bash
> python3 scripts/check_sops_rules.py
> ```
>
> `secrets/lab.sops.yaml` must resolve to the `secrets/lab...` rule, not to the
> catch-all.

## 5. The certificate

**On the monitoring host**, where the CA lives:

```bash
make certs ARGS="--host grafana-lab.matrix.elysium --ip 10.0.30.40 --dns grafana"
```

Copy three files into `~/HomeLab/certificates/` on `alexander`:
`ca.pem`, `grafana-lab.matrix.elysium.pem`, `grafana-lab.matrix.elysium-key.pem`.

> [!WARNING]
> **Do not run `make certs ARGS=--ca` on `alexander`.** If the files are
> missing, `render-config.sh` stops and its error names that command as the fix
> — correct on a fresh clone with no CA, and wrong here. It would mint a
> *second* certificate authority, and this stack's Prometheus verifies Grafana
> against the first one. Copy the leaf; do not issue a new root.

The `grafana` DNS SAN is not decoration: the `grafana` scrape job connects to
the compose service name and verifies against it.

## 6. Bring it up

```bash
make render STACK=lab
make up STACK=lab
```

Then open `https://10.0.30.40:3000` from Hicks. The existing 50 → 30 rule
already permits it — no new firewall rule anywhere, which is what ADR-0007
promised. Your browser will warn until you trust `certificates/ca.pem`; see
[`generate-certificates.md`](generate-certificates.md).

## 7. Verify — including the thing that fails quietly

```bash
make validate
```

Checks both stacks and names which is which on every line.

The two log sources §0 is about, which is the check worth actually doing:

```bash
ls -l /var/log/auth.log /var/log/syslog
```

Both must exist and be `syslog:adm 0640`. If either is missing you are on a
journald-only install and Alloy will collect nothing from it while reporting
perfectly healthy.

Then confirm the agent is reading them, from the lab's own Grafana — Explore,
Loki datasource:

```logql
count by (job) (count_over_time({host="alexander"} [15m]))
```

Three jobs at minimum: `/var/log/auth.log`, `/var/log/syslog` and
`/var/log/journal`. **Two is the failure this runbook exists to prevent**, not a
quiet host.

And that the metrics path works:

```promql
up{instance="alexander"}
```

## 8. Write it down

The guest is not built until the documents say so, and the checks will tell you
if you forget:

- `docs/network.md` — a row in the ImaginationLAN table, and the note saying
  `Saruman` runs no guests is no longer true.
- `docs/architecture.md` — drop `**Not built yet**` from the `alexander` row.
  That marker is load-bearing: while it is there, `check_docs.py` requires the
  host to be **absent** from `network.md`, so adding the row without removing
  the marker fails and says the marker is stale.
- `docs/hardware.md` — removing the marker also pushes the Alloy agent count to
  four, which fails the "three Alloy agents" sentence in the same run. That is
  deliberate, and it is the moment that sentence should change.

`make check-docs` walks you through all three.
