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

## 1. Create the six VMs

VMIDs `150`–`155`, so the last octet is legible from `qm list` — the same
reasoning that gave `alexander` VMID `140`. Storage is `local-lvm` on a stock
Proxmox install; check `pvesm status` if yours differs.

```bash
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
    --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=1 \
    --tpmstate0 local-lvm:1,version=v2 \
    --cpu host --cores 2 --sockets 1 \
    --memory "$3" --balloon 0 \
    --scsihw virtio-scsi-single \
    --scsi0 "local-lvm:$4,discard=on,iothread=1" \
    --net0 virtio,bridge=vmbr0 \
    --agent enabled=1 \
    --onboot 1 --startup "order=$5,up=120" \
    --ide2 local:iso/windows-server-2025-eval.iso,media=cdrom \
    --ide0 local:iso/virtio-win.iso,media=cdrom \
    --boot order='scsi0;ide2'
done
```

```bash
# The two endpoints. Same shape, Windows 11 media, and no --onboot: ADR-0029
# runs these per session, so they should not come back after a host reboot.
for spec in "154 carbuncle" "155 siren"; do
  set -- $spec
  qm create "$1" \
    --name "$2" \
    --ostype win11 \
    --machine q35 --bios ovmf \
    --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=1 \
    --tpmstate0 local-lvm:1,version=v2 \
    --cpu host --cores 2 --sockets 1 \
    --memory 4096 --balloon 0 \
    --scsihw virtio-scsi-single \
    --scsi0 local-lvm:64,discard=on,iothread=1 \
    --net0 virtio,bridge=vmbr0 \
    --agent enabled=1 \
    --onboot 0 \
    --ide2 local:iso/windows-11.iso,media=cdrom \
    --ide0 local:iso/virtio-win.iso,media=cdrom \
    --boot order='scsi0;ide2'
done
```

Six of those flags are worth knowing rather than copying.

- **`--machine q35 --bios ovmf` with `--efidisk0` and `--tpmstate0`.** Windows
  11 refuses to install without TPM 2.0 and Secure Boot, and **the installer's
  error does not tell you which of the three is missing.** The servers get the
  same treatment for consistency and because 2025 wants Secure Boot anyway.
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

Leave the disk cache at the Proxmox default. The Smart Array cache is enabled
and battery-backed again since the pack was fitted on 2026-09-02
([#76](https://github.com/Gerrrt/HomeLab/issues/76)) — but
[`replace-the-smart-storage-battery.md`](replace-the-smart-storage-battery.md)
records `cpqDaAccelWriteCachePercent` still reading `0`, unexplained. Until that
is understood, `writeback` here leans on a cache nobody has confirmed is
absorbing writes, and this build is the one that would notice.

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
Set-DnsServerRootHint -InputObject @()   # or clear them in the DNS console
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

```powershell
# On leviathan, after joining it to the domain.
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSDomainController -DomainName "ad.matrix.elysium" -InstallDns
Set-DnsServerForwarder -IPAddress 10.0.30.1 -UseRootHint $false
```

Leave its time configuration alone. `NT5DS` — the domain hierarchy — is the
default the moment it joins, and a second manual peer list is a second thing
that can disagree with the first.

Confirm replication before moving on, because a second DC that is not
replicating is worse than no second DC:

```powershell
repadmin /replsummary
dcdiag /test:Replications
```

## 5. Join the members, and build the tiers

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

## 6. The authentication generator

Six idle VMs produce no more Kerberos traffic than three idle VMs. The variable
is activity, not machine count, and #265 is right to say that machines alone do
not buy "realistic authentication traffic".

A scheduled task on each workstation, running as an ordinary domain user every
fifteen minutes:

```powershell
klist purge
New-PSDrive -Name S -PSProvider FileSystem -Root \\titan\share -ErrorAction SilentlyContinue
Get-ChildItem S:\ -ErrorAction SilentlyContinue | Out-Null
Remove-PSDrive S -ErrorAction SilentlyContinue
```

That produces 4768, 4769 and 4624 on the DCs and 5140 on `titan`, continuously,
for no disk and no measurable IOPS. It is what turns #266's baseline from empty
into something a deviation can stand out against.

It lives here as a code block rather than as a script in the repository, for the
same reason [`build-the-playground.md`](build-the-playground.md) carries its
sysctl file inline: nothing in this repository converges these guests, so a
tracked file would be one that drifts from the machines with nothing to notice.

## 7. `windows_exporter`, and the licence clock

Install `windows_exporter` on all six. The collector list matters:

```text
--collectors.enabled="cpu,cs,logical_disk,memory,net,os,service,system,time,textfile"
--collectors.time.enabled="ntp,system_time"
--collectors.textfile.directories="C:\ProgramData\windows_exporter\textfile"
```

> [!IMPORTANT]
> **The `time` collector is off by default, and `--collectors.time.enabled` is
> not a toggle — it takes a comma-separated list of sub-collectors, and matching
> is case-sensitive.** So there are two ways to end up with a collector that
> reports healthy and emits neither metric §9 checks: leaving `time` out of
> `--collectors.enabled`, or naming the sub-collectors wrong. A rule written
> against a collector nobody enabled is a rule that can never fire, which is
> [#62](https://github.com/Gerrrt/HomeLab/issues/62) and
> [#63](https://github.com/Gerrrt/HomeLab/issues/63) arriving for the third time
> in this repository.
>
> Both sub-collectors are named above because **upstream does not document which
> of them emits which metric**, and guessing would leave the wrong half working.
> §9 is the check, and it is the reason §9 queries the metrics rather than the
> service state.

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
textfile directory:

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

## 8. Turn on the scrape

On `alexander`, uncomment the `windows` job in
[`stacks/lab/prometheus/prometheus.yaml`](../../stacks/lab/prometheus/prometheus.yaml)
— the file names the exact lines — and reload:

```bash
make reload STACK=lab
```

Nothing is published to do this. `alexander` dials out to `9182` on six
addresses on its own segment; no `ports:` block opens, no firewall rule is
added, and the lab's Prometheus remains something that cannot be pushed to from
outside its own compose network. The argument is in ADR-0029, and it is a
deliberate reversal of what four files in `stacks/lab` used to say.

## 9. Verify — including the things that fail quietly

```bash
make validate     # on alexander; checks both stacks and names which is which
```

**The clock, read from the side that tells the truth.** On each DC:

```powershell
w32tm /query /status
```

`Source` must read `10.0.30.1`. Then the same fact from the lab's Grafana,
against the Prometheus datasource:

```promql
windows_time_clock_sync_source{instance=~"bahamut|leviathan"}
```

The series must carry `type="NTP"`. **Read the source, not the offset.**
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

Six Windows hosts on RDP, two DCs answering LDAP and Kerberos, SMB on `titan`,
and `9182` on all six — none of it newly permitted, all of it newly *present*,
because the `50 → 30` rule already grants Hicks the whole segment.

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
  goes.

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
| `Resolve-DnsName` for an AD name works from `alexander` | Somebody added the Unbound domain override. §9's caution — this is a design regression, not a configuration one |
