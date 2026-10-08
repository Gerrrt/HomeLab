# Runbook: Build the lab domain on `Saruman`

**Target:** six Windows guests on `Saruman`, ImaginationLAN (VLAN 30)
**Time:** a day. Most of it is six Windows installers against a 7.2K mirror,
which is a real number and not pessimism — see §0
**You will need:** the Proxmox web UI on `Saruman` (or a shell on it through the
KVM or `shiva`), a Windows Server 2025 evaluation ISO, a Windows 11 ISO, **the
virtio-win ISO**, two purchased Windows 11 Pro keys, and the pfSense UI on
`morpheus` for four DHCP reservations

This builds what [ADR-0007](../adr/0007-defensive-estate-and-offensive-range.md)
called "a small Windows domain, realistic endpoints" and
[ADR-0029](../adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
sized. It is the thing every other part of the defended estate is pointed at:
[#266](https://github.com/Gerrrt/HomeLab/issues/266)'s Wazuh has nothing to read
without it, [#267](https://github.com/Gerrrt/HomeLab/issues/267)'s Velociraptor
has nothing to hunt on, and
[ADR-0014](../adr/0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)'s
entire placement argument is that the techniques worth detecting are layer 2 and
only reach a domain sharing their broadcast domain.

**Since [ADR-0077](../adr/0077-configure-the-lab-domain-with-ansible-from-phoenix.md),
this page is the explanation, and [`ansible/`](../../ansible/README.md) is the
procedure.** §2–§4 and §7 are applied by `ansible-playbook lab-domain.yml`
from `phoenix`, and §9's checks by `ansible-playbook verify.yml`. The commands
under each section still say *what* the role does and *why*. When the two
disagree, the role is what runs and this page is what is wrong. See
[*Run it from `phoenix`*](#run-it-from-phoenix) below
([#448](https://github.com/Gerrrt/HomeLab/issues/448)).

Closes [#265](https://github.com/Gerrrt/HomeLab/issues/265). The stack that
watches it is already built and running on `alexander`
([#262](https://github.com/Gerrrt/HomeLab/issues/262),
[#264](https://github.com/Gerrrt/HomeLab/issues/264)); what is missing is
anything for it to watch.

---

## 0. What is decided, and why

| | Decision | Why this and not the obvious alternative |
| --- | --- | --- |
| How many | **Six** — two DCs, two member servers, two endpoints | Derived twice. NTLM relay needs a destination that is not the origin, and since Windows 11 24H2 requires inbound SMB signing where Server 2025 requires only outbound, the sole relayable host in a DC-plus-workstations domain is the DC itself. A member server is derived, not chosen |
| Duty cycle | Servers continuous, **endpoints per session** | A 7.2K mirror serves ~90 random write IOPS for the whole machine. Four idle servers are ~40 of them; six would be most of the budget before anything useful happened |
| Server edition | Server 2025 Standard, **Desktop Experience** | Core saves ~15 GiB and capacity is not what binds. What it costs is every hour of #266 and #267 spent in Event Viewer and the GPMC |
| Licences | Endpoints **bought** (Win 11 Pro), servers **evaluated** | Client evaluation is 90 days and then shuts the machine down hourly, which is what actually kills a lab. Server evaluation is 180 days and a server rebuild is scriptable |
| Addresses | DCs static; the other four **DHCP with reservations** | Rogue DHCP is one of the five techniques this segment exists for, and a statically-addressed estate cannot be lied to by DHCP |
| DNS | Members → the DCs → `10.0.30.1`. No delegation on Unbound | A domain override would put a nameserver living on the attackers' segment into the house resolver's path |
| Clock | The DCs sync from `morpheus`, `10.0.30.1` | "Time is broken" and "the segment is broken" become one event and never two |
| Namespace | `ad.matrix.elysium`, NetBIOS `AD` | Collides with none of Unbound's six host overrides, and resolves to NXDOMAIN for anyone outside the domain |
| Telemetry | `windows_exporter`, **scraped** by `alexander` | Publishing a remote-write receiver would hand an unauthenticated delete-series API to the segment that exists to hold attackers |

The full arguments are in ADR-0029. Two of them are worth repeating here,
because this is the document you will have open while making the mistake.

> [!IMPORTANT]
> **Do not harden this domain.** Every item below is a shipped default that,
> tidied up, deletes one of the techniques ADR-0014 built the whole segment for.
> A competent person will turn several of them off by reflex.
>
> - **LLMNR stays enabled.** Not *Turn off multicast name resolution*.
> - **NetBIOS over TCP/IP stays enabled.** Not disabled on the adapter, and not
>   via DHCP option 001.
> - **IPv6 stays enabled on every guest.** Disabling it is the single thing that
>   stops mitm6, and it is the first thing people do.
> - **WPAD auto-detect stays on** in the browser settings.
> - **Leave the DNS `GlobalQueryBlockList` exactly as shipped.** Windows DNS
>   blocks `wpad` by default, so the name fails in DNS and *falls through to
>   LLMNR* — which is the exercise. Creating a `wpad` A record to "fix" the
>   failure is what kills it.
>
> The inverse is also true, and belongs in the same place: hardening that gets
> deliberately switched off is switched off **once, and recorded**. Each modern
> default turned off is a documented exercise, not a hole.

The other one is about the day itself rather than about the design, and it is
the reason the time estimate at the top of this page says "a day".

> [!IMPORTANT]
> **Six Windows installers on a mirrored pair of 7.2K disks is the slow part,
> and it is why the boot order below is staggered.** A Windows boot is a
> 300–1500 IOPS burst against a machine with roughly ninety random write IOPS.
> Left on `--onboot 1` alone, a `Saruman` reboot starts all six at once, they
> saturate the array for minutes, and services time out waiting for their own
> disk. Build them one at a time; do not install two in parallel to save an
> hour. It will not save an hour.

## Run it from `phoenix`

Ansible goes on `phoenix` once, into a venv of its own. The versions are the
ones `ansible/` pins, not whatever the distribution has:

```bash
sudo apt-get install -y python3-venv
python3 -m venv ~/.venvs/ansible
~/.venvs/ansible/bin/pip install -r ~/code/Gerrrt/HomeLab/ansible/requirements.txt
echo 'export PATH="$HOME/.venvs/ansible/bin:$PATH"' >> ~/.bashrc && . ~/.bashrc
cd ~/code/Gerrrt/HomeLab/ansible && ansible-galaxy collection install -r requirements.yml -p .collections
```

After a `git pull` that moves a pin, re-run the `pip install` line if
`requirements.txt` changed, and the `ansible-galaxy` line if
`requirements.yml` did. Then add the
two secrets to the file that already holds the token and the build password
(ADR-0077 decision 3).

For a domain built by hand, `LAB_ADMIN_PASSWORD` must be AD\Administrator's
**current** password, because the members join and `leviathan` promotes as
that account. The DSRM password is only used if a DC is promoted again, so any
long, complex value will do.

`phoenix.env` is *sourced* (`set -a; . phoenix.env`), so each value is
written single-quoted. Unquoted, a password with a space, `$`, a quote or a
backslash would be split, expanded or stripped before Ansible saw it. This
prompts for both without echoing them or leaving them in shell history. It
refuses empty input, restores the terminal if interrupted, and replaces any
earlier entries instead of adding a second pair. It works in zsh, phoenix's
login shell, and in bash:

```bash
(
  f=~/.config/proxmox/phoenix.env; umask 077; trap 'stty echo' EXIT INT TERM
  q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
  printf 'AD\\Administrator password: '; stty -echo; read -r A; echo
  printf 'New DSRM password: '; read -r D; stty echo; echo
  [ -n "$A" ] && [ -n "$D" ] || { echo 'empty input: nothing written' >&2; exit 1; }
  sed -i '/^LAB_ADMIN_PASSWORD=/d; /^LAB_DSRM_PASSWORD=/d' "$f"
  printf 'LAB_ADMIN_PASSWORD=%s\nLAB_DSRM_PASSWORD=%s\n' "$(q "$A")" "$(q "$D")" >> "$f"
)
```

`read -p` is a bash-only spelling: zsh reads `-p` as a coprocess, fails, and
a `printf` after it still appends two empty entries. Check the file the way
the playbook will read it, by sourcing it. This prints `ok` only if there is
exactly one of each entry and both load as non-empty:

```bash
(f=~/.config/proxmox/phoenix.env; set -a; . "$f"; set +a; [ "$(grep -c '^LAB_ADMIN_PASSWORD=' "$f")" = 1 ] && [ "$(grep -c '^LAB_DSRM_PASSWORD=' "$f")" = 1 ] && [ -n "$LAB_ADMIN_PASSWORD" ] && [ -n "$LAB_DSRM_PASSWORD" ] && echo ok || echo 'NOT ok')
```

For a rebuild, generate both instead:

```bash
umask 077
printf 'LAB_ADMIN_PASSWORD=%s\nLAB_DSRM_PASSWORD=%s\n' \
  "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)Aa1!" \
  "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)Aa1!" \
  >> ~/.config/proxmox/phoenix.env
```

The population ([#449](https://github.com/Gerrrt/HomeLab/issues/449)) needs a
third entry, `LAB_POPULATION_SEED`. Every population password is derived from
it and the account's name, so it is generated once and never typed. It is the
one value that gives back every population password, so treat it as one
(ADR-0078). It replaces any earlier entry:

```bash
(f=~/.config/proxmox/phoenix.env; umask 077; sed -i '/^LAB_POPULATION_SEED=/d' "$f"; printf "LAB_POPULATION_SEED='%s'\n" "$(openssl rand -hex 24)" >> "$f")
```

The skeleton (#448) adds two more. `LAB_TIER_ADMIN_PASSWORD` is the password the
three tier admins are **created** with on a fresh rebuild (the roles use
`on_create`, so existing accounts are untouched); generate one. The Wazuh
enrolment password, `LAB_WAZUH_REGISTRATION_PASSWORD`, is the manager's
`authd.pass` — the value `make secrets-edit STACK=soc` holds — so copy it
rather than generating it. Both replace any earlier entry:

```bash
(f=~/.config/proxmox/phoenix.env; umask 077; sed -i '/^LAB_TIER_ADMIN_PASSWORD=/d' "$f"; printf "LAB_TIER_ADMIN_PASSWORD='%s'\n" "$(openssl rand -base64 18)Aa1!" >> "$f")
```

```bash
(f=~/.config/proxmox/phoenix.env; umask 077; printf 'authd.pass: '; stty -echo; read -r W; stty echo; echo; [ -n "$W" ] && { sed -i '/^LAB_WAZUH_REGISTRATION_PASSWORD=/d' "$f"; printf "LAB_WAZUH_REGISTRATION_PASSWORD='%s'\n" "$(printf '%s' "$W" | sed "s/'/'\\\\''/g")" >> "$f"; }; unset W)
```

The deliberate weaknesses (#449, §5a) add a sixth, `LAB_WEAK_PASSWORD`. It is
the one entry here that is meant to be *weak*: the crackable password the
weakness accounts share (ADR-0083). Set it to something a wordlist would find —
that is the exercise — not with `openssl rand`. Only needed before you enable a
weakness, and it replaces any earlier entry:

```bash
(f=~/.config/proxmox/phoenix.env; umask 077; trap 'stty echo' EXIT INT TERM; printf 'weak password: '; stty -echo; read -r P; stty echo; echo; [ -n "$P" ] && { sed -i '/^LAB_WEAK_PASSWORD=/d' "$f"; printf "LAB_WEAK_PASSWORD='%s'\n" "$(printf '%s' "$P" | sed "s/'/'\\\\''/g")" >> "$f"; }; unset P)
```

`LAB_ENDPOINT_ADMIN_PASSWORD` is `labadmin`'s on the two endpoints. Like the
tier admins', it is only used when the account is **created**, so the
hand-built pair keep theirs. Generate one:

```bash
(f=~/.config/proxmox/phoenix.env; umask 077; sed -i '/^LAB_ENDPOINT_ADMIN_PASSWORD=/d' "$f"; printf "LAB_ENDPOINT_ADMIN_PASSWORD='%s'\n" "$(openssl rand -base64 18)Aa1!" >> "$f")
```

`lab-domain.yml` refuses to start if `LAB_ADMIN_PASSWORD`, `LAB_DSRM_PASSWORD`
or `LAB_TIER_ADMIN_PASSWORD` is missing or shorter than 14 characters. That
check runs first on every tag
([#846](https://github.com/Gerrrt/HomeLab/issues/846)).

**Host keys are checked, against `ansible/.known_hosts` only** (ADR-0085,
which amends ADR-0077 decision 2). `scripts/lab-known-hosts.sh` writes that file.
It reads each guest's `ssh_host_ed25519_key.pub` from inside the guest,
through the Proxmox guest agent, so the key is not learned from whatever
answers on VLAN 30. Run it once now, and again after any of the six is
rebuilt; until then, `ansible/` refuses that guest with `REMOTE HOST
IDENTIFICATION HAS CHANGED`. Its token needs `VM.GuestAgent.FileRead` on the
six, and nowhere else. On `/vms`, where `PhoenixBuilder` is granted, that would
let `phoenix` read any file on any guest, the SOC's included. On the six it
adds nothing: `phoenix` already holds their Administrator password. So it is a
role of its own, granted on the `lab-domain` pool, whose grant outlives a
rebuild of its guests (`provision-lab-guests.md` §2). As root on `Saruman`:

```bash
pveum role add PhoenixHostKeys --privs "VM.GuestAgent.FileRead"
pveum acl modify /pool/lab-domain --users phoenix@pve --roles PhoenixHostKeys
```

Until the six are in that pool (tofu, #448), grant it on their VMIDs
instead, **with `PhoenixBuilder` beside it**. A grant on a more specific path
replaces what the user inherits from `/vms`; it does not add to it. With
`PhoenixHostKeys` alone on `/vms/150`, `phoenix` could read files there and
nothing else: it could not even list the guest, so `lab-known-hosts.sh`
found none of the six (2026-10-07), and tofu could not have imported them.
Proxmox deletes a `/vms/<id>` grant along with the guest, so these lines
would have to be re-run after a rebuild:

```bash
for id in 150 151 152 153 154 155; do pveum acl modify /vms/$id --users phoenix@pve --roles PhoenixBuilder,PhoenixHostKeys; done
pveum user permissions phoenix@pve --path /vms/150 | grep -c -E 'VM\.Audit|VM\.GuestAgent\.FileRead'   # 2
```

A pool grant is not affected the same way: `/pool/lab-domain` and `/vms`
are different paths, and Proxmox adds what each grants.

Then, on `phoenix`:

```bash
set -a; . ~/.config/proxmox/phoenix.env; set +a
scripts/lab-known-hosts.sh       # PASS and a SHA256 fingerprint per guest
```

Then, every time. **First applied to the hand-built six on 2026-10-03**: a
run on `main` after #825 reported `changed=0` everywhere, and `verify.yml`
passed on all six (`changelog.md`, 2026-10-03).

```bash
cd ansible
set -a; . ~/.config/proxmox/phoenix.env; set +a
ansible-playbook lab-domain.yml --check --diff
ansible-playbook lab-domain.yml
ansible-playbook lab-domain.yml          # again: must report changed=0
ansible-playbook verify.yml
```

**`--check` is only a full preview against a domain that already exists.** On
a fresh rebuild, check mode cannot create the forest, so every later stage
looks at a DNS server and a domain that are not there and fails. For a first
build, preview one stage at a time and apply it before previewing the next:
`--tags base`, then `forest`, then `replica`, `join`, `exporter` and
`licence`.

| Tag | This page | What it applies |
| --- | --- | --- |
| `base` | §2 | Names, the DCs' static addresses, members' resolvers, the build password rotated to `LAB_ADMIN_PASSWORD`, and the build's `packer-winrm` certificate removed |
| `packer_cert` | §2 | Only that certificate removal, for a guest cloned from a template built before [#1031](https://github.com/Gerrrt/HomeLab/pull/1031) |
| `forest` | §3 | `bahamut`'s forest, the forwarder, the root hints removed, and the clock from `10.0.30.1`. It stops if the clock reads anything else |
| `replica` | §4 | `leviathan` promoted and left on NT5DS, then each DC's resolver set to its partner and loopback |
| `join` | §5, the join only | `titan`, `ramuh`, `carbuncle` and `siren` joined |
| `endpoint_admin` | §2 | `labadmin`, the local administrator Windows 11's setup made on each endpoint, created from `LAB_ENDPOINT_ADMIN_PASSWORD` when it is missing |
| `exporter` | §7 | `windows_exporter` at the pinned version, and the 9182 rule admitting `alexander` |
| `licence` | §7 | The weekly gauge on the four servers, and the rearm count printed in the play output |
| `population` | §5 | The people in [`population.yaml`](../../ansible/population/population.yaml): an OU per department under `OU=People`, their groups under `OU=Groups`, and the users, `authgen` among them, with passwords derived from `LAB_POPULATION_SEED` |
| `authgen` | §6 | The batch-logon right and the `Lab-AuthGenerator` task on both endpoints, as `authgen` |
| `tiers` | §5 | The five tier OUs, the three tier admins, the `Tier 0 Admins` group, and the members placed in `Servers`/`Workstations` |
| `shares` | §5 | `titan`'s `Public` and `Finance` shares, with the decoy |
| `soc` | §11 | Wazuh and Velociraptor installed on all six, in place of the deploy GPOs |
| `kerberoast` | §5a | `svc-sql`, an SPN on a crackable account, `ramuh`'s target |
| `asreproast` | §5a | `svc-backup`, Kerberos pre-auth disabled, crackable |
| `dcsync` | §5a | `svc-sync`, the two replication rights on the domain head, non-DA |
| `ucd` | §5a | Unconstrained delegation on `ramuh` |
| `cd` | §5a | `svc-web` allowed to delegate to `titan`'s CIFS (Kerberos only) |
| `rbcd` | §5a | `titan` set to trust `svc-rbcd` to act on its behalf |

The tiers, the shares and the SOC agents (the rest of §5, and §11's deployment)
are applied by the `tiers`, `shares` and `soc` tags. The last six are #449's
deliberate weaknesses ([ADR-0083](../adr/0083-give-the-lab-domain-its-deliberate-weaknesses-as-switchable-tags.md)),
each off until asked for and driven one at a time — §5a below.
`ansible-playbook population-credentials.yml` prints the population's passwords,
on `phoenix`, when you need one.

**Start the endpoints first.** `carbuncle` and `siren` are `--onboot 0`, so a
run against stopped endpoints reports them `UNREACHABLE`, not configured.

The run needs these three in place first:

- **`LAB_ADMIN_PASSWORD` and `LAB_DSRM_PASSWORD` in `phoenix.env`**, as
  above.
- **A reservation on `morpheus` for all six, by MAC.** That includes the two
  DCs at `.50` and `.51`. A rebuilt DC first boots on DHCP, and `base` then
  makes the same address static. The reservations survive a rebuild because
  [`tofu/guests.tf`](../../tofu/guests.tf) pins each guest's MAC to the one
  the hand-built six had (ADR-0077 decision 6).
- **A way in.** Every clone of the templates has `sshd`, key-only, admitting
  `phoenix` alone ([`openssh.ps1`](../../packer/windows/scripts/openssh.ps1)).
  The six built by hand on 2026-09-24/25 had none. **Each was given the same
  on 2026-10-02**, from its console. Repeat it only on a hand-built guest that
  loses it, for example after a snapshot revert to before that date. Run it as
  any member of Administrators, with the public half of `phoenix`'s key, never
  the private:

  ```powershell
  $env:PHOENIX_PUBKEY = '<the contents of ~/.ssh/id_ed25519.pub on phoenix>'
  $env:PHOENIX_ADDRESS = '10.0.30.70'
  Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/Gerrrt/HomeLab/main/packer/windows/scripts/openssh.ps1 -OutFile $env:TEMP\openssh.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\openssh.ps1
  Set-Service sshd -StartupType Automatic; Start-Service sshd
  ```

  It is the script the templates run, not a copy of it, so a hand-built guest
  and a clone cannot drift apart. What the 2026-10-02 run showed:

  - **`-UseBasicParsing` is required.** Without it, Windows PowerShell 5.1
    parses a response through Internet Explorer's engine, and neither Server
    2025 nor Windows 11 ships IE.
  - **On `carbuncle` and `siren` the fourth line takes minutes.** Windows 11
    has no OpenSSH server until `Add-WindowsCapability` downloads it. The
    console looks stuck while it does, and it is not.
  - **Paste the key itself.** Two guests first received a placeholder, and
    `sshd` started with a key nothing holds. The script now refuses anything
    that is not shaped like a public key.
  - **Windows 11 ships with the built-in Administrator disabled**, and
    Ansible logs in as `Administrator`. On a disabled account, `sshd` accepts
    the TCP connection and then drops it during key exchange. `phoenix` sees
    `Connection reset by … port 22`, and `OpenSSH/Admin` logs
    `unable to resolve user administrator`. On the two hand-built endpoints,
    run `Enable-LocalUser -Name Administrator`. The servers and every template
    clone have it enabled already.

  The licence task §7 registered by hand writes the same file the role's
  `licence-clock` task does. Delete the hand-made one after the first run, so
  that only one thing owns the file.

## Rebuild from the pipeline

[#448](https://github.com/Gerrrt/HomeLab/issues/448)'s proof, and what every
later rebuild repeats: the six are destroyed and made again from
`tpl-ws2025-eval` (912) and `tpl-win11-pro` (911) by
[`tofu/`](../../tofu/README.md), then configured by the playbook above. That
replaces §1 and the install half of §2. The rest of this page is still the
*why*.

`tofu/guests.tf` declares the six with the values the hand-built ones had:
VMID, template, memory, disk, MAC and SMBIOS UUID, and records the startup
order that root on `Saruman` sets after the apply (step 7). The MAC
keeps `morpheus`'s reservations true. The SMBIOS UUID is what the endpoints'
bought Windows 11 Pro activation is tied to, so a clone with the same UUID
should reactivate by itself.

**Before the first destroy, the six exist and the state does not know them.**
They were built by hand, so `tofu destroy` alone would remove nothing. Step 4
imports them once, so that the destroy is OpenTofu's. Every later rebuild
skips step 4.

1. **What the rebuild needs**, as for any run above, plus:
   - the `/pool/lab-domain` grant on `Saruman`
     ([`provision-lab-guests.md` §2](provision-lab-guests.md#2-what-the-token-is-missing-on-saruman));
   - `LAB_ENDPOINT_ADMIN_PASSWORD` in `phoenix.env`;
   - the two agent MSIs staged on `odin`
     ([`build-the-soc-guest.md` §11](build-the-soc-guest.md#11-agents-by-gpo--the-second-evening-and-after-414)).
     `--tags soc` fetches them from there, and stops on a fresh guest if they
     are not;
   - new `LAB_ADMIN_PASSWORD` and `LAB_DSRM_PASSWORD`, generated as above. A
     fresh forest takes whatever they say.
2. **The templates pass their smoke test.**
   `scripts/packer-smoke.sh 912` and `911`
   ([`build-the-lab-templates.md`](build-the-lab-templates.md)).
3. **A copy to go back to.** Back up 150–155 to `golem`'s PBS, and check that
   all six are listed there before going on. Anything the playbook does not
   make is on those disks and nowhere else.
4. **Once only: import the hand-built six.**

   ```bash
   cd ~/code/Gerrrt/HomeLab
   umask 077; set -a; . ~/.config/proxmox/phoenix.env; set +a
   for g in bahamut:150 leviathan:151 titan:152 ramuh:153 carbuncle:154 siren:155; do
     tofu -chdir=tofu import "module.guest[\"${g%%:*}\"].proxmox_virtual_environment_vm.this" "Saruman/${g##*:}"
   done
   tofu -chdir=tofu plan
   ```

   The plan should **replace** each of the six and **create** the
   `lab-domain` pool (an import brings in guests, not their pool), and do
   nothing else. That is the one plan where a replace is expected:
   `clone` cannot be read back from a running guest. Anything else is a stop.
5. **Destroy.** Only the guests. On a later rebuild, that leaves the pool
   and its grant in place:

   ```bash
   tofu -chdir=tofu destroy -target=module.guest
   ```

   Check on `Saruman` that `qm list` has no 150–155.
6. **The old Wazuh registrations go.** On `odin`, remove the six agents by
   name, so that the rebuilt guests' enrolment under the same names is not
   refused as a duplicate. This comes after the destroy, so a run that stops
   before it leaves the old guests still reporting.
7. **Apply.** This also creates the pool, the first time.

   ```bash
   tofu -chdir=tofu plan -out=next.tfplan
   tofu -chdir=tofu apply next.tfplan && rm tofu/next.tfplan
   ```

   Then, **as root on `Saruman`**, give the four servers their boot order.
   `tofu` cannot: Proxmox wants `Sys.Modify` on `/` to set `startup`, which
   `phoenix` is not given (ADR-0043). The first #448 apply was refused with a
   403 on exactly this. `tofu -chdir=tofu output startup_orders` lists the
   same commands by guest name; run them as written here:

   ```bash
   qm set 150 --startup order=1,up=120
   qm set 151 --startup order=2,up=120
   qm set 152 --startup order=3,up=120
   qm set 153 --startup order=4,up=120
   ```

   Check `qm config` for each one: the MAC, the `smbios1` UUID, `startup` on
   the four servers, and the pool. Start `carbuncle` and `siren` if they are
   not running.
8. **Configure, one stage at a time.** On a fresh domain `--check` cannot see
   past the forest, so apply each tag before previewing the next. Run the long
   ones detached with a log:

   ```bash
   cd ansible
   for t in base forest replica join endpoint_admin tiers gpos shares sysmon soc exporter licence population authgen; do
     ansible-playbook lab-domain.yml --tags "$t" || break
   done
   ansible-playbook lab-domain.yml        # again: must report changed=0
   ```

   `sysmon` goes before `soc`, as in `lab-domain.yml`. The Wazuh agent
   subscribes to the Sysmon channel once, when it starts, and an agent started
   before that channel exists never reads it (#1035).

9. **Verify.** All of this has to hold:
   - `ansible-playbook verify.yml` passes on all six;
   - `up{job="windows"}` is 1 for all six on `alexander`, with the right `role`
     labels;
   - Wazuh and Velociraptor list all six;
   - each endpoint reads *activated* (enter its key at the console if the
     UUID did not carry it);
   - `slmgr /dlv` on the four servers gives a new expiry. Record it in §11 and
     in the changelog, as before.

## 1. Create the six VMs

> [!NOTE]
> **This section is the hand build of 2026-09-24/25, kept as the record.** A
> rebuild does not run it: it uses
> [Rebuild from the pipeline](#rebuild-from-the-pipeline) above.

VMIDs `150`–`155`, so the last octet is legible from `qm list` — the same
reasoning that gave `alexander` VMID `140`.

> **Built by hand 2026-09-24 to 2026-09-25 for
> [#414](https://github.com/Gerrrt/HomeLab/issues/414); the commands below are
> as-run.** They put the six on `large_data`, the SSD pool measured at 7,952
> random write IOPS at queue depth 1 against the HDD mirror's 741
> ([#527](https://github.com/Gerrrt/HomeLab/issues/527)) — `large_data:` on
> every disk line and `ssd=1` on every `--scsi0`, where the first draft had
> `local-lvm:` and no `ssd=`. Check `pvesm status` if your pool is named
> differently. The boot-order stagger below was priced on the HDD mirror's
> ninety IOPS; it is kept because it costs nothing on flash and still spares a
> thundering herd on a `Saruman` reboot.

```bash
# Run under bash: `set -- $spec` below relies on word-splitting an unquoted
# variable, which zsh (a common login shell here) does not do — every field
# would land in $1 and qm would reject it. The heredoc runs bash whatever your
# shell is.
bash <<'PROXMOX'
# The two domain controllers and the two member servers.
for spec in "150 bahamut 4096 60 1" \
            "151 leviathan 4096 60 2" \
            "152 titan 6144 80 3" \
            "153 ramuh 6144 80 4"; do
  set -- $spec
  qm create "$1" \
    --name "$2" \
    --ostype win11 \
    --machine q35 --bios ovmf \
    --efidisk0 large_data:1,efitype=4m,pre-enrolled-keys=1 \
    --tpmstate0 large_data:1,version=v2.0 \
    --cpu host --cores 2 --sockets 1 \
    --memory "$3" --balloon 0 \
    --scsihw virtio-scsi-single \
    --scsi0 "large_data:$4,discard=on,iothread=1,ssd=1" \
    --net0 virtio,bridge=vmbr0,firewall=0 \
    --agent enabled=1 \
    --onboot 1 --startup "order=$5,up=120" \
    --ide2 local:iso/windows-server-2025-eval.iso,media=cdrom \
    --ide0 local:iso/virtio-win.iso,media=cdrom \
    --boot order='scsi0;ide2'
done
PROXMOX
```

```bash
# The two endpoints. Same shape, Windows 11 media, and no --onboot: ADR-0029
# runs these per session, so they should not come back after a host reboot.
# Endpoints wait on the two Windows 11 Pro keys; the four servers above do not.
bash <<'PROXMOX'
for spec in "154 carbuncle" "155 siren"; do
  set -- $spec
  qm create "$1" \
    --name "$2" \
    --ostype win11 \
    --machine q35 --bios ovmf \
    --efidisk0 large_data:1,efitype=4m,pre-enrolled-keys=1 \
    --tpmstate0 large_data:1,version=v2.0 \
    --cpu host --cores 2 --sockets 1 \
    --memory 4096 --balloon 0 \
    --scsihw virtio-scsi-single \
    --scsi0 large_data:64,discard=on,iothread=1,ssd=1 \
    --net0 virtio,bridge=vmbr0,firewall=0 \
    --agent enabled=1 \
    --onboot 0 \
    --ide2 local:iso/windows-11.iso,media=cdrom \
    --ide0 local:iso/virtio-win.iso,media=cdrom \
    --boot order='scsi0;ide2'
done
PROXMOX
```

Six of those flags are worth knowing rather than copying.

- **`--machine q35 --bios ovmf` with `--efidisk0` and `--tpmstate0`.** Windows
  11 refuses to install without TPM 2.0 and Secure Boot, and **the installer's
  error does not tell you which of the three is missing.** The servers get the
  same treatment for consistency and because 2025 wants Secure Boot anyway.
  `version=v2.0` on `--tpmstate0`, not `v2`: Proxmox 9 rejects the bare `v2`.
- **`firewall=0` on `--net0`.** `Saruman`'s Proxmox firewall is on since
  [#566](https://github.com/Gerrrt/HomeLab/issues/566), and its datacenter
  enable brings the per-NIC flag to life set-by-default on any NIC. A range
  whose hypervisor quietly filters its own guests lies to you about what your
  tooling did; the isolation here is the bridge, not the guest firewall. Set it
  explicitly so a later GUI edit cannot flip it on unseen — the same care
  `build-the-playground.md` §4 takes.
- **`--ide0` carrying the virtio-win ISO, and `ide0` specifically.** See the
  callout below for why the disc is there at all. The slot is not a free choice:
  **`q35` exposes only `ide0` and `ide2`**, because its emulated controller
  allows one unit per bus, and `--ide3` makes QEMU refuse to start the VM with
  *"Can't create IDE unit 1, bus supports only 1 units"*. Proxmox's own Windows
  guest guide puts the driver ISO on IDE 0 for this reason. This one fails
  loudly, which is the only good thing about it — the two ISOs plus a TPM and an
  EFI disk is exactly the shape that runs out of slots.
- **`--net0 ... bridge=vmbr0`, and no `tag=`.** `Saruman` is single-homed on
  VLAN 30 with no trunk and no VLAN-aware bridge (ADR-0007), so `vmbr0` *is*
  ImaginationLAN, untagged. A `tag=` here puts the guest on a VLAN the switch
  port does not carry, and it simply has no network. Identical to
  [`build-the-lab-guest.md`](build-the-lab-guest.md) §1, and identically easy to
  get wrong.
- **`--balloon 0`.** Ballooning on a 128 GB host buys nothing here, and it makes
  the guests' own memory metrics — which #266 will read — move for reasons that
  are not the workload.
- **`--startup order=N,up=120` on the servers only.** The IOPS argument above.
  The endpoints get `--onboot 0` because ADR-0029 runs them per session; a
  machine that comes back by itself is a machine that is not on demand.
- **`iothread=1` with `virtio-scsi-single`.** They pair, and `iothread` does
  nothing without the `-single` controller. It matters more here than it did for
  `alexander`, because this is four times the write load on the same spindles.

Leave the disk cache at the Proxmox default. ~~The Smart Array cache is enabled
and battery-backed again since the pack was fitted on 2026-09-02
([#76](https://github.com/Gerrrt/HomeLab/issues/76)) — but
[`replace-the-smart-storage-battery.md`](replace-the-smart-storage-battery.md)
records `cpqDaAccelWriteCachePercent` still reading `0`, unexplained. Until that
is understood, `writeback` here leans on a cache nobody has confirmed is
absorbing writes, and this build is the one that would notice.~~ Settled
2026-09-19 by the SSD fit: `ssacli` reads the controller cache at `10% Read /
90% Write`, battery-backed, and the `0` was the iLO not populating the column
([#76](https://github.com/Gerrrt/HomeLab/issues/76), via
[#527](https://github.com/Gerrrt/HomeLab/issues/527)). The setting stays the
default for a better reason: on the HDD pool the controller absorbs writes
below the hypervisor, and on `large_data` — where these six will go — the
SSDs run Smart Path with their own capacitor-backed buffers. `writeback`
would add host RAM that nothing backs, on either pool.

> [!IMPORTANT]
> **With a virtio SCSI controller, the Windows installer shows no disks at
> all.** Not a warning, not a greyed-out entry — an empty list. Choose *Load
> driver*, browse the virtio-win CD, and take `vioscsi\<version>\amd64`. The
> network adapter is likewise absent until you load `NetKVM` from the same disc,
> which you will discover later and more confusingly if you skip it now.
>
> The alternative is `--scsihw lsi` and an installer that Just Works on a
> controller with materially worse throughput on the resource this build is
> already short of. Load the driver.

## 2. Install, name and address

> **Applied by `--tags base`** ([`roles/base`](../../ansible/roles/base/tasks/main.yml)),
> except the installer itself, which a template clone replaces, and the
> reservations on `morpheus`.

Nothing unusual once the driver is loaded. During each installer:

- **Hostnames** exactly as ADR-0029 names them: `bahamut`, `leviathan`, `titan`,
  `ramuh`, `carbuncle`, `siren`. All six are within the fifteen-character
  NetBIOS limit; a rename after promotion is not a rename you want.
- **`bahamut` and `leviathan` get static addresses inside Windows** —
  `10.0.30.50` and `10.0.30.51`, `/24`, gateway `10.0.30.1`. A domain controller
  that boots without an address has nothing to register into and no way to be
  found; it is the one bootstrap dependency in the domain that points at itself.
- **The other four stay DHCP clients**, and take `10.0.30.52`–`.55` from
  reservations on `morpheus`. Do not "tidy this up" into statics — rogue DHCP is
  one of the five techniques, and an estate that does not use DHCP cannot be
  lied to by it.
- **DNS on every guest points at `10.0.30.50` and `10.0.30.51`, and nothing
  else.** Not the gateway, and not a public resolver. This is the one documented
  exception to [ADR-0010](../adr/0010-keep-the-resolver-on-the-gateway.md) in
  the estate.
- **Set IPv4 only. Do not untick IPv6 in the same dialog.** The adapter's
  Properties list puts IPv4 and IPv6 side by side, and unticking IPv6 while
  setting the address is the exact reflex §0 forbids — it is the one thing that
  disables mitm6. Leave the IPv6 box checked; you are only editing IPv4.

Then four reservations on `morpheus`, under *Services → DHCP Server →
ImaginationLAN*, mapping each guest's MAC to its address.

> [!IMPORTANT]
> **The reservation is not what protects an address below `.100`.** The pool is
> `.100–.200` and these four sit outside it, so nothing was going to lease them
> anyway. The reservation is there so the address is recorded where a reader
> looks for it, and so the protection does not depend on the pool never moving —
> the reasoning [`build-the-playground.md`](build-the-playground.md) already
> writes out, and the mistake `10.0.30.110` is still an apology for.
>
> Leave the scope's DNS setting alone. Reserved clients receive the interface
> address like everyone else; the DC addresses are set inside Windows, which is
> what keeps ADR-0010's "the DHCP scopes do not change" literally true.

## 3. Promote `bahamut`, and set the clock before anything joins

> **Applied by `--tags forest`** ([`roles/dc_forest`](../../ansible/roles/dc_forest/tasks/main.yml)).
> The play order in `lab-domain.yml` is what enforces "before anything
> joins". The role refuses to continue while `w32tm /query /source` reads
> anything but `10.0.30.1`. The `ntpq -p` check on `morpheus` below is still
> yours.

Order matters here, and it is the reverse of the intuitive one.

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest `
  -DomainName "ad.matrix.elysium" `
  -DomainNetbiosName "AD" `
  -InstallDns `
  -DomainMode WinThreshold -ForestMode WinThreshold
```

Then the forwarder and the root hints, on `bahamut`:

```powershell
Set-DnsServerForwarder -IPAddress 10.0.30.1 -UseRootHint $false
Get-DnsServerRootHint | Remove-DnsServerRootHint -Force   # -InputObject @() does not clear them
```

> [!CAUTION]
> **Disable root hints, and it is not housekeeping.** Left on, Windows DNS falls
> back to recursing against the root servers whenever the forwarder is slow — so
> the domain's resolution path silently becomes different from every other host
> in the house, at exactly the moment something is already wrong. Off, a
> forwarder problem fails immediately and locally, which is ADR-0017's reasoning
> about default routes applied to DNS.

Now the clock, **before anything joins**:

```powershell
w32tm /config /manualpeerlist:"10.0.30.1,0x8" /syncfromflags:manual /reliable:yes /update
Restart-Service w32time
w32tm /resync /rediscover
w32tm /query /status
```

The last line must report `Source: 10.0.30.1`. If it reports `Local CMOS Clock`,
stop and fix it — see §9, and see the *If something goes wrong* table.

> [!CAUTION]
> **A member that joins across a clock skew fails in a way that reads as a
> credential problem.** Kerberos' default tolerance is five minutes; past it,
> every symptom points at passwords and none of them point at time. ADR-0014
> names this as the specific quiet failure a port allowlist would have caused,
> and it is just as quiet when the cause is a DC that never synced in the first
> place.

Two things to verify rather than assume, and this is the moment:

```bash
# On morpheus — is NTP actually bound to the ImaginationLAN interface?
ntpq -p
```

```powershell
# On bahamut — does the gateway answer, and by how much are we out?
w32tm /stripchart /computer:10.0.30.1 /samples:5 /dataonly
```

pfSense binds its NTP service per interface, and a VLAN interface is not
necessarily among the selected ones. If `morpheus` will not serve it, use
`time.cloudflare.com,0x8 pool.ntp.org,0x8` — **two sources, not one**, so
w32time can discard an outlier — and note in the build record that the clock
now depends on egress, which is the dependency ADR-0029 was avoiding.

**This build adds no firewall rules.** `10.0.30.x → 10.0.30.1:123/udp` is
intra-segment and covered by nothing, and every other path in this document is
too. If you find yourself writing a rule, something has been misunderstood.

## 4. The second domain controller

> **Applied by `--tags replica`** ([`roles/dc_replica`](../../ansible/roles/dc_replica/tasks/main.yml),
> then [`roles/dc_resolvers`](../../ansible/roles/dc_resolvers/tasks/main.yml)).
> `verify.yml` runs the replication check below as `dcdiag /test:Replications`.

```powershell
# On leviathan, after joining it to the domain.
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSDomainController -DomainName "ad.matrix.elysium" -InstallDns
Set-DnsServerForwarder -IPAddress 10.0.30.1 -UseRootHint $false
```

Leave its time configuration alone. `NT5DS` — the domain hierarchy — is the
default the moment it joins, and a second manual peer list is a second thing
that can disagree with the first.

Then fix each DC's own resolver to point at its **partner first, then
loopback** — promotion leaves a DC pointing at itself only, so a DC whose own
DNS service is down can no longer resolve the domain:

```powershell
# On bahamut:
Set-DnsClientServerAddress -InterfaceAlias Ethernet -ServerAddresses 10.0.30.51,127.0.0.1
# On leviathan:
Set-DnsClientServerAddress -InterfaceAlias Ethernet -ServerAddresses 10.0.30.50,127.0.0.1
```

This is the one place the §2 rule ("every guest points at .50 and .51") does
not apply: a DC uses its partner then loopback, which is Microsoft's own
guidance and what keeps either DC resolving with the other down. Also remove
the root hints on `leviathan`, exactly as on `bahamut` above — the promotion
command here only sets the forwarder.

Confirm replication before moving on, because a second DC that is not
replicating is worse than no second DC:

```powershell
repadmin /replsummary
dcdiag /test:Replications
```

## 5. Join the members, and build the tiers

> **The join is applied by `--tags join`** ([`roles/member`](../../ansible/roles/member/tasks/main.yml)),
> **and the ordinary users by `--tags population`**
> ([`roles/population`](../../ansible/roles/population/tasks/main.yml)): forty
> people drawn by `scripts/gen_population.py` into a committed
> [`population.yaml`](../../ansible/population/population.yaml), in place of
> "five or so". The rest of this section is still
> [#449](https://github.com/Gerrrt/HomeLab/issues/449)'s and still done by
> hand.

Join `titan`, `ramuh`, `carbuncle` and `siren`. Then build the structure that
makes an intrusion *legible* — three tiers, one admin account each, five or so
ordinary users, and one service account with an SPN on a real service on
`ramuh`.

> [!IMPORTANT]
> **The tiering is not there to be secure. It is there so that a violation is an
> event.** With one admin tier every logon looks alike, and #266 has nothing to
> alert on: "Tier 0 credentials used on a Tier 2 workstation" is only a
> detection if the tiers exist. Build the GPO that denies Tier 0 interactive and
> network logon anywhere but the two DCs, and then know that you have built the
> thing the alert will key on.

`titan` gets the shares — including one obviously-interesting decoy, because a
share nobody would open is not a share anyone will be caught opening. And check
that it is still a relay target rather than assuming it:

```powershell
Get-SmbServerConfiguration | Select-Object RequireSecuritySignature, EnableSecuritySignature
```

`RequireSecuritySignature: False` is what you want on `titan` and what Server
2025 should ship. If it reads `True`, a servicing update has moved the default;
turn it off deliberately, and write down that you did.

## 5a. The deliberate weaknesses, one tag at a time

The six weaknesses #449 asks for — `kerberoast`, `asreproast`, `dcsync`, `ucd`,
`cd`, `rbcd` — are each a tag on the same playbook, each off until you ask for
it ([ADR-0083](../adr/0083-give-the-lab-domain-its-deliberate-weaknesses-as-switchable-tags.md)).
A plain run leaves every one absent.

> [!IMPORTANT]
> **The observation is the deliverable, not the compromise.** The point of each
> tag being switchable on its own is the purple-team loop: enable one, watch
> what #266, #267 and #437 actually see, then disable it and confirm the signal
> goes away. That second half is the part that teaches, and it is impossible in
> an all-or-nothing lab. Add them one at a time, never all at once.

Before the first one, two things:

- **Snapshot every guest on the hypervisor.** A weakness is a deliberate change
  to the domain; a snapshot is how you get back to clean if an exercise goes
  further than intended.
- **`LAB_WEAK_PASSWORD` in `phoenix.env`.** A sixth entry beside the others. It
  is the deliberately *crackable* password the weakness accounts share — the
  crack target for `kerberoast`/`asreproast`, and the login the `dcsync`, `cd`
  and `rbcd` exercises authenticate with. A role refuses to *enable* a weakness
  while it is unset. Set it to something a wordlist would find, on purpose.

The loop, one weakness (here `kerberoast`) at a time:

```bash
ansible-playbook lab-domain.yml --tags kerberoast -e weakness_kerberoast_state=present
ansible-playbook verify.yml      -e weakness_kerberoast_state=present   # confirm it is on
# ... run the technique, watch Wazuh / Velociraptor / Zeek see it ...
ansible-playbook lab-domain.yml --tags kerberoast                       # default absent: off
ansible-playbook verify.yml                                             # confirm it is gone
```

A plain `ansible-playbook verify.yml`, with nothing enabled, asserts all six of
these primitives are absent — the **per-primitive negative test**. It does not
collect the authorization graph, so the graph-level test #449 names — "run the
collector with the tags off and confirm the path to Domain Admin is not there" —
is a BloodHound collector run ([#451](https://github.com/Gerrrt/HomeLab/issues/451)),
not this. A lab that is always exploitable proves nothing about the tags.

| Tag | What `present` makes | What `absent` restores |
| --- | --- | --- |
| `kerberoast` | `svc-sql` in `OU=Tier1`, SPN `MSSQLSvc/ramuh…:1433`, weak password | deletes `svc-sql` |
| `asreproast` | `svc-backup`, Kerberos pre-auth disabled, weak password | deletes `svc-backup` |
| `dcsync` | `svc-sync` (non-DA) granted the two replication rights on the domain head | revokes the rights, deletes `svc-sync` |
| `ucd` | `TRUSTED_FOR_DELEGATION` set on `ramuh` | clears the flag on `ramuh` |
| `cd` | `svc-web` (its own SPN) allowed to delegate to `CIFS/titan…` | deletes `svc-web`; `titan` untouched |
| `rbcd` | `titan` set to trust `svc-rbcd` to act on its behalf | clears the trust on `titan`, deletes `svc-rbcd` |

The fixed identifiers — account names, SPNs, the delegation target and resource
— are in [`ansible/inventory/group_vars/all.yaml`](../../ansible/inventory/group_vars/all.yaml),
one source of truth the roles set and `verify.yml` proves. `cd` ships
Kerberos-only; the protocol-transition variant is an ADR-0083 note away.

## 6. The authentication generator

Six idle VMs produce no more Kerberos traffic than three idle VMs. The variable
is activity, not machine count, and #265 is right to say that machines alone do
not buy "realistic authentication traffic".

A scheduled task on each workstation, running as an ordinary domain user every
fifteen minutes:

```powershell
klist purge
New-PSDrive -Name S -PSProvider FileSystem -Root \\titan\Public -ErrorAction SilentlyContinue
Get-ChildItem S:\ -ErrorAction SilentlyContinue | Out-Null
Remove-PSDrive S -ErrorAction SilentlyContinue
```

That produces 4768, 4769 and 4624 on the DCs and 5140 on `titan`, continuously,
for no disk and no measurable IOPS. It is what turns #266's baseline from empty
into something a deviation can stand out against.

**As built on 2026-10-02**, with three things this section did not say:

- **The user is `AD\authgen`**, in the default `CN=Users` container, a
  member of `Domain Users` (its primary group) and nothing else. It is the domain's only ordinary user until
  [#449](https://github.com/Gerrrt/HomeLab/issues/449)'s population arrives,
  which waits on this domain, so this one was made by hand to break the wait.
  Its password is kept nowhere: if it is lost, reset it and register the task
  again. #449 folds it into its population rather than deleting it.
- **`titan` logs no 5140 until a GPO asks it to.** Server 2025 ships
  *Audit File Share* off. The `Lab - Audit File Share` GPO, linked to
  `OU=Servers`, sets it to Success. That is observability, not hardening, and
  §0's list is untouched. The GPO carries an `audit.csv` under
  `Machine\Microsoft\Windows NT\Audit` in SYSVOL. **Check that file has two
  lines.** A console paste fused the header and the row into one on the first
  attempt, and the extension applied nothing while reporting success.
- **Windows 11 does not grant the task's user *Log on as a batch job*.**
  `Register-ScheduledTask` with `-Password` does not add the right, and the
  task then fails every run with `0x80070569` (event 101/104 in the
  TaskScheduler log). Grant it on each endpoint before registering:

```powershell
$sid = (New-Object System.Security.Principal.NTAccount('AD\authgen')).Translate([System.Security.Principal.SecurityIdentifier]).Value
secedit /export /cfg $env:TEMP\r.inf /areas USER_RIGHTS
(Get-Content $env:TEMP\r.inf) -replace '^(SeBatchLogonRight = .*)$', "`$1,*$sid" | Set-Content $env:TEMP\r2.inf -Encoding Unicode
secedit /configure /db $env:TEMP\r.sdb /cfg $env:TEMP\r2.inf /areas USER_RIGHTS
Remove-Item $env:TEMP\r.inf, $env:TEMP\r2.inf, $env:TEMP\r.sdb
```

Then the task, on `carbuncle` and `siren`:

```powershell
$cred   = Get-Credential -UserName 'AD\authgen' -Message 'authgen password'
$body   = 'klist purge; New-PSDrive -Name S -PSProvider FileSystem -Root \\titan\Public -ErrorAction SilentlyContinue | Out-Null; Get-ChildItem S:\ -ErrorAction SilentlyContinue | Out-Null; Remove-PSDrive S -ErrorAction SilentlyContinue'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -Command `"$body`""
$trig   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)
$set    = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
Register-ScheduledTask -TaskName 'Lab-AuthGenerator' -Description 'build-the-lab-domain.md section 6' `
  -Action $action -Trigger $trig -Settings $set `
  -User 'AD\authgen' -Password $cred.GetNetworkCredential().Password -RunLevel Limited
```

`Get-ScheduledTaskInfo Lab-AuthGenerator` should read `LastTaskResult 0`.
On the DCs, 4769 names the account as `authgen@AD.MATRIX.ELYSIUM`, so match it
with `-match`, not `-contains`.

**Applied by `--tags authgen` since #449**
([`roles/authgen`](../../ansible/roles/authgen/tasks/main.yml)), which adopts the
task above by name, grants the batch right, and stores `authgen`'s derived
password in it. `authgen` itself moved into `OU=IT` with the population. The
blocks above are how it was built by hand on 2026-10-02, kept as the record of
what the role encodes. After changing `LAB_POPULATION_SEED`, run
`--tags population,authgen` together, so the task gets the password the account
now has.

## 7. `windows_exporter`, and the licence clock

**Applied by `--tags exporter` and `--tags licence`**
([`roles/exporter`](../../ansible/roles/exporter/tasks/main.yml),
[`roles/licence_clock`](../../ansible/roles/licence_clock/tasks/main.yml)).
The version, its sha256 and the collector list are pinned in
[`group_vars/all.yaml`](../../ansible/inventory/group_vars/all.yaml), so a
bump is one edit there. The MSI is installed with `REMOVE=FirewallException`,
because its own rule admits any address. The rearm count is printed on every
run.

> [!TIP]
> **When the clock runs out, the rebuild does not start from §1.**
> `tpl-ws2025-eval` (VMID 912) is a generalised Server 2025 image, built by
> [`build-the-lab-templates.md`](build-the-lab-templates.md). A full clone of
> it replaces §1 and the install half of §2, and every clone gets its own SID.
> Rebuild the template first (that runbook's §8). Whether a clone of an older
> template gets a full 180 days depends on the rearms that template has already
> spent. A fresh install has not spent any, so the rebuild settles it. Read
> `slmgr /dlv` on the clone and record it in §11, as before. The 2026-10-08
> rebuild is the evidence: clones of a template built the day before got 179.5
> days and a rearm count of **0**. A fresh template gives a full period. The
> clone cannot extend it.

Install `windows_exporter` on all six. The collector list matters:

```text
--collectors.enabled="cpu,logical_disk,memory,net,os,service,system,time,textfile"
--collectors.textfile.directories="C:\ProgramData\windows_exporter\textfile"
```

> [!IMPORTANT]
> **A stale collector name in the list is not a warning — the service refuses
> to start.** The build ran windows_exporter **v0.31.8**, where `cs` (the old
> computer-system collector) no longer exists: with it in the list the service
> installs, then exits with `unknown collector cs` and never binds `9182`, so
> the scrape is a permanent `up == 0` and the failure looks like a firewall
> problem. It was dropped above. Pin the version you install and re-check the
> collector names against its docs when you bump it; a rule written against a
> collector nobody enabled is one that can never fire
> ([#62](https://github.com/Gerrrt/HomeLab/issues/62),
> [#63](https://github.com/Gerrrt/HomeLab/issues/63)).
>
> **There is no `--collectors.time.enabled` line, and adding one breaks
> startup.** An earlier draft carried `--collectors.time.enabled="ntp,system_time"`
> from an older release. In 0.31.8 the `time` collector emits
> `windows_time_clock_sync_source` — the metric §9 reads — with only `time` in
> the enabled list, and `--collectors.time.enabled` is not a valid flag, so
> passing it is the very "refuses to start" failure above. §9 queries the
> metric rather than the service state precisely so a wrong collector config is
> caught as an absent series, not a green service.
>
> The MSI installs it (`ENABLED_COLLECTORS`, `LISTEN_PORT=9182`, `TEXTFILE_DIRS`
> map to the flags above); the guests reach `github.com` over the segment's
> egress to pull it.

Then the host firewall rule — inbound `9182/tcp`, **scoped to `10.0.30.40`**:

```powershell
New-NetFirewallRule -DisplayName "windows_exporter from alexander" `
  -Direction Inbound -Protocol TCP -LocalPort 9182 `
  -RemoteAddress 10.0.30.40 -Action Allow -Profile Domain
```

That is the difference between an endpoint found by a `/24` sweep and one you
have to go looking for. It is not a control against someone who already owns
`alexander`, and `security.md` records it as a residual rather than a
mitigation.

Finally the licence clock — a weekly scheduled task writing one gauge into the
textfile directory. **On the four servers only:** the endpoints run activated
Windows 11 Pro, where `GracePeriodRemaining` is `0`, so the gauge there would
read a misleading `0` days rather than "not an evaluation". Install
windows_exporter on all six; register this task on `bahamut`, `leviathan`,
`titan` and `ramuh`.

```powershell
$d = (Get-CimInstance SoftwareLicensingProduct |
      Where-Object PartialProductKey |
      Select-Object -First 1).GracePeriodRemaining / 1440
@(
  '# HELP windows_eval_grace_days_remaining Days left on this evaluation licence.'
  '# TYPE windows_eval_grace_days_remaining gauge'
  "windows_eval_grace_days_remaining $([math]::Floor($d))"
) | Set-Content -Encoding ascii `
    "C:\ProgramData\windows_exporter\textfile\licence.prom"
```

And read the number this ADR deliberately did not write down:

```powershell
slmgr /dlv     # "Remaining Windows rearm count" — record it in §11
```

### Sysmon, so the endpoints record what fired

**Applied by `--tags sysmon`**
([`roles/sysmon`](../../ansible/roles/sysmon/tasks/main.yml), #450,
[ADR-0080](../adr/0080-record-the-lab-domain-with-sysmon-and-capture-on-demand-with-pktmon.md)).
Windows' default logging does not record:

- the command line of a process;
- the DLLs it loads;
- the connections it makes;
- the named pipes it opens.

Kerberoasting and NTLM relay show up in those. Sysmon records them in
`Microsoft-Windows-Sysmon/Operational`, which the role sizes to 256 MiB. Its
config is sysmon-modular's balanced profile, vendored at one release.

- **To move the config to a newer release,** run
  `scripts/vendor-sysmon-config.sh configs-<commit>` and commit the diff. The
  next `--tags sysmon` run reapplies it on every guest.
- **To check the vendored copy is still upstream's,** run
  `scripts/vendor-sysmon-config.sh --check`.
- **When Microsoft ships a new Sysmon,** a rebuild fails at the zip's checksum.
  Move `sysmon_version` and `sysmon_zip_sha256` in
  [`group_vars/all.yaml`](../../ansible/inventory/group_vars/all.yaml)
  together, then apply.

Wazuh reads this channel through the `default` group's shared `agent.conf` on
`odin` ([#1035](https://github.com/Gerrrt/HomeLab/issues/1035),
[`build-the-soc-guest.md`](build-the-soc-guest.md) §11).

**For a packet capture from inside one guest,** use the two Pktmon playbooks
in [`ansible/README.md`](../../ansible/README.md#capture-on-demand). It takes
two commands, and the pcapng lands on `phoenix`.

## 8. Turn on the scrape

On `alexander`, uncomment the `windows` job in
[`stacks/lab/prometheus/prometheus.yaml`](../../stacks/lab/prometheus/prometheus.yaml)
— the file names the exact lines — and reload:

```bash
make reload STACK=lab
```

> [!IMPORTANT]
> **If the new job does not appear, it is the bind mount, not your edit.**
> `compose.yaml` mounts `prometheus.yaml` as a single file, so the container
> pins the inode it started with. An editor that writes a new inode (`sed -i`,
> most editors) leaves the container — and `make reload`'s SIGHUP — reading the
> old inode, so the uncomment looks applied on the host and Prometheus never
> sees it. `docker restart lab-prometheus` re-opens the path and picks it up;
> confirm with `up{job="windows"}` on the lab Prometheus. This is in
> `stacks/lab/README.md` too.

Nothing is published to do this. `alexander` dials out to `9182` on six
addresses on its own segment; no `ports:` block opens, no firewall rule is
added, and the lab's Prometheus remains something that cannot be pushed to from
outside its own compose network. The argument is in ADR-0029, and it is a
deliberate reversal of what four files in `stacks/lab` used to say.

## 9. Verify — including the things that fail quietly

```bash
cd ansible && ansible-playbook verify.yml     # on phoenix
```

That answers everything on the guests in one pass: the clock source on each DC,
the forwarder and root hints, replication, the secure channel, `windows_exporter`
listening, 9182 admitting `alexander` and nothing else, and every item in the
checklist at the end of this section. It is read-only, so run it whenever you
like. It does not see the boundary, the tripwire or Prometheus, which are below
and still yours.

```bash
make validate     # on alexander; checks both stacks and names which is which
```

**The clock, read from the side that tells the truth.** On each DC:

```powershell
w32tm /query /status
```

On `bahamut` — the PDC emulator — `Source` must read `10.0.30.1`. On
`leviathan`, `Source` reads `bahamut.ad.matrix.elysium`: a second DC takes its
time from the domain hierarchy, not from the gateway, and that is correct.
Then the same fact from the lab's Grafana, against the Prometheus datasource:

```promql
windows_time_clock_sync_source == 1
```

The PDC (`bahamut`) carries `type="NTP"`; the other DC (`leviathan`) carries
`type="NT5DS"`, the domain hierarchy. **What must be true of both is that
neither carries `type="Local CMOS Clock"`** — a check keyed on "both NTP" would
false-alarm on a healthy second DC. **Read the source, not the offset.**
`windows_time_computed_time_offset_seconds` is measured against whatever source
w32time has chosen — so when the peer becomes unreachable and it falls back to
the local CMOS clock, the offset reads approximately zero and the DC looks
perfectly synchronised while the domain drifts toward Kerberos failure. That is
the failure ADR-0014 named, and it is the reason there are two rules and not
one.

**Every target is answering:**

```promql
up{job="windows"}
```

Six `1`s. **Five is the failure this section exists to prevent** — a host that
never appears looks exactly like a host nobody has started, and the usual cause
is the §7 firewall rule or a collector list that omitted `time`.

**The domain is a domain**, from `siren`:

```powershell
nltest /dsgetdc:ad.matrix.elysium
Test-ComputerSecureChannel
```

**And the boundary holds.** From `alexander`, this must **fail**:

```bash
nslookup bahamut.ad.matrix.elysium 10.0.30.1
```

> [!CAUTION]
> **A success here means the trust direction has been inverted without an ADR
> saying so.** It means someone added the Unbound domain override ADR-0029
> rejects, which puts a nameserver living on the segment that exists to hold
> attackers into the resolution path of the house's own resolver. Nothing else
> in this repository performs this check, and nothing else would notice.

**The techniques are still exercisable** — a checklist, because prose here would
be read as description rather than as a test:

- `Get-DnsClientGlobalSetting` — LLMNR not disabled.
- `Get-WmiObject Win32_NetworkAdapterConfiguration | Select TcpipNetbiosOptions`
  — NetBIOS not disabled (`0` or `1`, not `2`).
- `Get-NetAdapterBinding -ComponentID ms_tcpip6` — IPv6 still bound, on all six.
- `Resolve-DnsName wpad.ad.matrix.elysium` — must **fail**. A `wpad` record
  existing means someone "fixed" the GlobalQueryBlockList.
- `Get-SmbServerConfiguration` on `titan` — `RequireSecuritySignature: False`.

**The tripwire has logged nothing.** ADR-0014's ImaginationLAN rule
([#234](https://github.com/Gerrrt/HomeLab/issues/234)), or until it lands the
interface's block log, should hold no line sourced from `10.0.30.5x`. This build
reaches no other segment and adds no rule, which makes that checkable rather
than merely intended.

## 10. What a Hicks workstation now reaches on VLAN 30

None of it is newly permitted, and all of it is newly *present*, because the
`50 → 30` rule already passes Hicks TCP to the whole segment.

**Observed on 2026-10-02** with `nmap -Pn -sT` from a Hicks laptop, against
the ports a domain answers on plus RDP, WinRM and the exporter:

| Host | Open from Hicks | Filtered |
| --- | --- | --- |
| `bahamut` `.50` | 53, 88, 135, 139, 389, 445, 464, 636, 3268, 5985 | 3389, 9182 |
| `leviathan` `.51` | 53, 88, 135, 139, 389, 445, 464, 636, 3268, 5985 | 3389, 9182 |
| `titan` `.52` | 135, 445, 5985 | everything else |
| `ramuh` `.53` | 5985 | everything else, 445 included |
| `carbuncle` `.54` | 135 | everything else |
| `siren` `.55` | 135 | everything else |

`morpheus` passes the TCP, so every *filtered* is a guest's own Windows
Firewall. The prose this table replaces was wrong in three places:

- **RDP is answered by none of the six**, not all six. It is off as Windows
  ships it: `fDenyTSConnections` is `1` and the *Remote Desktop* firewall rules
  are disabled. Read on `bahamut` and `carbuncle`.
- **WinRM (`5985`) is open on the four servers**, as Server 2025 ships it,
  and closed on the endpoints, as Windows 11 ships it. The old list did not
  mention it.
- **`ramuh` serves no SMB.** Only `titan` has shares, so only `titan` opens
  `445`.

`9182` is filtered from Hicks on all six, because §7's rule admits
`alexander` alone, as intended. `22` was not scanned: ADR-0077 scopes it to
`phoenix`.

Recorded here because [#228](https://github.com/Gerrrt/HomeLab/issues/228)
cannot narrow that rule without a list of what is actually behind it, and
[`build-the-playground.md`](build-the-playground.md) has been accumulating the
same list. Adding to it as things are built is cheaper than reconstructing it
later.

## 11. Write it down

The domain is not built until the documents say so, and the checks will tell you
if you forget:

- `docs/network.md` — six rows in the ImaginationLAN table, and the `### Notes`
  section gains the DNS paragraph: domain members resolve at the two DCs,
  everything else on the segment still resolves at the gateway, and there is no
  domain override on Unbound *by decision*.
- `docs/architecture.md` — drop `**Not built yet**` from the six rows. That
  marker is load-bearing in both directions: while it is there, `check_docs.py`
  requires the host to be **absent** from `network.md` and asserts the planned
  address clashes with nothing; once `network.md` names it, leaving the marker
  fails and says the marker is stale.
- `stacks/lab/prometheus/prometheus.yaml` — the `windows` job uncommented, as
  §8 did on the guest.
- `docs/roadmap.md` and `docs/security.md` — the build record, and the `9182`
  residual.
- **The rearm count from §7, as a number.** ADR-0029 deliberately wrote none,
  because the published sources disagree; this is the commit where the real one
  goes. **Read on 2026-10-01: 1**, on all four servers, for both *Remaining
  Windows rearm count* and *Remaining SKU rearm count*. The time-based
  expiration read 173 days on the DCs and 174 on the members, which lands
  around 2027-03-23. One rearm is one more 180-day period, not a way to skip
  the rebuild.

  **Read again on 2026-10-08, after #448's rebuild from the pipeline: 0.**
  Both counts are 0 on all four servers, which are on the `TIMEBASED_EVAL`
  channel with 179.5 days left. That lands around **2027-04-05**, and
  `LabWindowsEvaluationExpiring` fires about 2027-03-06. The clones of the
  2026-10-07 `tpl-ws2025-eval` got the full period but no rearm: generalising
  the image spends it. So there is no rearm to fall back on this time. The next
  rebuild starts from a freshly built 912, as the tip in §7 says.

`make check-docs` walks you through the first two.

## If something goes wrong

| Symptom | Cause |
| --- | --- |
| The installer shows no disks at all | The virtio SCSI driver is not loaded. §1's callout |
| Setup refuses to start on a Windows 11 ISO | TPM 2.0 or Secure Boot missing, and it will not say which. Check `--tpmstate0`, `--bios ovmf`, `--efidisk0` |
| The guest has no network after install | Either NetKVM was never loaded, or a `tag=` crept onto `--net0`. `vmbr0` is already ImaginationLAN, untagged |
| A domain join fails with a credential error | Clock skew. §3, and it is why §3 comes before §5 |
| `w32tm /query /status` reads `Local CMOS Clock` | The peer is unreachable. Check that `morpheus` serves NTP on this interface at all — §3 |
| `up{job="windows"}` is short by one | The §7 firewall rule, or a collector list that omitted `time` |
| Everything is slow for minutes after a `Saruman` reboot | Boot storm. The `--startup order=` values in §1 |
| A relay attempt does nothing against `titan` | Inbound SMB signing is required. §5's check |
| `ansible-playbook` reports a guest `UNREACHABLE` | An endpoint that is not started (`--onboot 0`), a hand-built guest that never had *Run it from `phoenix`*'s `sshd` step, or a clone whose template predates `openssh.ps1` |
| `ansible-playbook` asks for a password, or is refused | The key on the guest is not `phoenix`'s, or `administrators_authorized_keys` grants someone besides Administrators and SYSTEM, which makes `sshd` ignore it. Re-run `openssh.ps1` |
| `verify.yml` fails on "9182 admits 10.0.30.40 and nothing else" | The MSI's own any-address rule, left by a hand install. The role installs with `REMOVE=FirewallException`, but it does not reinstall a version already present. Delete the MSI's rule; the role's `windows_exporter from alexander` stays |
| `verify.yml` fails on an item from §0's list | Something hardened the domain. Find what, and turn it back. That item is an exercise, not a hole |
| `Resolve-DnsName` for an AD name works from `alexander` | Somebody added the Unbound domain override. §9's caution — this is a design regression, not a configuration one |
