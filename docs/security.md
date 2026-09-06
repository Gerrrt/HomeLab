# Security

The lab is a security project, so the interesting question is not "is it
secure" but "what is it defending against, and what is it knowingly not."

## Threat model

What this network is actually built to survive:

| Threat | Control |
| --- | --- |
| A compromised IoT device pivoting to a workstation | VLAN 20 is terminal — no route to any other segment |
| A guest on the Wi-Fi enumerating the LAN | VLAN 10 is terminal, client isolation on |
| A smart TV's firmware phoning somewhere unexpected | VLAN 40 is terminal, egress only |
| A corporate laptop carrying something in from outside | Sits on VLAN 50 but has no management access |
| A lab VM escaping into the house | VLAN 30 reachable only *from* trusted, never *to* it |
| A range target with a path out | It has none — `ifrit`'s targets sit on a bridge with no physical port, on `172.30.30.0/24`, which the firewall does not route and on which nothing has a default route at all ([ADR-0014](adr/0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md), [ADR-0017](adr/0017-buy-ifrit-for-iops-and-keep-the-range-disposable.md)) |
| Someone with the trusted Wi-Fi key quietly joining | Kea's lease log reaches Loki; `UnknownDeviceOnTrustedSegment` fires the first time a MAC appears on VLAN 50 in seven days ([ADR-0019](adr/0019-read-device-joins-from-the-dhcp-server.md)) |
| Losing visibility of a failure | 72 alert rules, 30 days of metrics and logs |
| Someone on a reachable VLAN silencing an alert to hide a failure | Alertmanager binds to `127.0.0.1`; silences go through authenticated Grafana |
| Mains power loss | **The rack, yes; the monitoring path, no.** A pack fitted to `mjolnir` on 2026-08-28 passed its self-test; the switch carrying `prometheus` and `oracle` still has no battery — see below |
| The estate being down while the person who runs it is unavailable | **Documentation, yes; data, not yet.** ADR-0011 puts the emergency tier on paper; [ADR-0023](adr/0023-keep-the-household-recovery-path-outside-the-estate.md) extends the same reasoning to the sensitive tier's data before that tier exists — see below |

What it explicitly does **not** defend against: a determined attacker with
physical access to the rack, a supply-chain compromise in an upstream container
image, or a vulnerability in pfSense itself. There is no egress filtering by
domain or by port
([ADR-0014](adr/0014-put-ifrit-on-imaginationlan-and-give-the-targets-no-route.md)
says why not for the lab, and the reason generalises), and no MFA on the
internal services.

**The MFA gap has an expiry now, and it is not one gap.**
[ADR-0022](adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)
ends [ADR-0008](adr/0008-place-services-by-data-trust.md)'s SSO deferral on a
state rather than leaving it open: the first real secret, photo or document in
the sensitive tier, any reachability from outside the house, or a third account
holder — whichever comes first. Until then the floor is per-application TOTP,
and it does not reach everything. Vaultwarden, Paperless-ngx and Home Assistant
can each carry a second factor; **Grafana, Immich and AdGuard Home cannot** —
Grafana OSS has no MFA in any edition, Immich's upstream has declined it and
points at OAuth, and AdGuard has one password-only admin account. For those
three an identity provider is the only route to a second factor rather than a
heavier alternative to one. **Grafana is the only one of the six deployed
today**, which makes "no MFA" a standing property of the estate rather than a
pending piece of work — it closes when an identity provider exists and not
before.

**Availability of the data is a separate question from access to it, and it now
has an answer too.** ADR-0008's tier will hold the household's credentials,
photographs and documents on one mini PC behind a private CA, so if that box is
down and the person who runs it is unreachable, the credentials for recovering
everything else sit behind the thing that broke — and step-ca means the browser
refuses the handshake rather than degrading.
[ADR-0023](adr/0023-keep-the-household-recovery-path-outside-the-estate.md)
declines to make any of it highly available and constrains the path instead:
**nothing the household needs in an emergency may have the estate on its only
route.** The household's own credentials are recoverable without Vaultwarden;
Immich and Paperless-ngx get an encrypted copy outside the estate whose
staleness is visible, off-*estate* rather than off-*host*, because `oracle`
shares the rack and the power feed; nothing on the break-glass card depends on a
certificate this estate issues; and nothing physical may be operable only
through Home Assistant. Those fall due on ADR-0022's triggers — the first real
credential, photo or document — and none of them is built. **The copy leaving
the house is a new residual**: it is the first household data to sit in someone
else's building, reduced to an availability problem by encryption at rest with a
key that never leaves here, and accepted on that basis.

**Intrusion detection has been running** on **Skids (VLAN 20)** since
2026-08-21 and on **Degens (VLAN 10)** since 2026-09-02, one Suricata process
per interface.
Suricata sits on `morpheus` rather than the hypervisor because it is the only
device that sees the IoT and guest segments, per
[ADR-0006](adr/0006-detect-at-the-chokepoint.md). Alerts reach Loki through the
firewall's syslog pipe, with `classification`, `priority` and `interface`
parsed into labels; `SuricataHighPriorityAlert` and `SuricataAlertStorm` are
armed against them per interface, and the `homelab-security` dashboard charts
them next to the firewall's own block decisions.
[`runbooks/enable-suricata.md`](runbooks/enable-suricata.md) covers the setup
and the tuning.

Three limits, stated rather than implied:

- **It is alert-only.** `Block Offenders` is off on both interfaces and stays
  off until a fortnight of understood alerts on each, and probably not on VLAN
  20 even then — an auto-block there can take out a camera or the alarm hub.
  On VLAN 10 it would hit a guest's device whose owner cannot be told why.
- **It watches two segments.** Skids and Degens; the rest are unwatched. WAN
  deliberately never will be.
- **It sees plaintext only.** Suricata cannot inspect inside TLS, so the useful
  signal is DNS, SNI, JA3 and the diminishing share of traffic still in the
  clear.

**Suricata dying is detected as of 2026-09-03.** A quiet IDS and a stopped
one produce identical log output, so no log rule can separate them;
`SuricataStopped` in `prometheus/rules/ids.rules.yaml` reads the firewall's
process table over SNMP instead, and fires per declared interface
([#90](https://github.com/Gerrrt/HomeLab/issues/90)). It proves the process is
alive, not that it is inspecting anything: a silent `ids` alert group is now
evidence that the sensor is running, and the runbook's test alert is still the
only proof that it detects.

**Device joins are detected as of 2026-09-04**, from the DHCP server rather
than from the wireless. `morpheus` ships Kea's lease log to Loki, and the first
lease a MAC takes on Hicks or Winterfell in seven days raises an alert —
warning on the trusted segment, critical on management, where nothing has
joined in the 13 days of logs the rules were written against. The eero cloud
was rejected as the source: it is a two-minute poll of Amazon for an event the
firewall logs in the same second, and it is unavailable exactly when the WAN
is ([ADR-0019](adr/0019-read-device-joins-from-the-dhcp-server.md)).

Three limits here too. **It sees leases, not associations** — a device with a
static address never asks, and never appears. **It sees the segment, not the
radio**: on Hicks it cannot tell a new laptop on the cable from a new phone on
the Wi-Fi, and it never knows which access point. And **the noise floor is
private MAC addresses**: iOS and Android rotate them per network, so a
rotation reads as a new device, which is accepted rather than filtered out
because filtering it would blind the rule to the addresses an intruder would
present.

## Segmentation

Default deny holds for **Winterfell (99)**, **ImaginationLAN (30)**,
**CasaBonita (40)**, **Skids (20)** and **Degens (10)**. Each blocks every other
segment explicitly before its egress rule, and the narrow exceptions that exist
— SNMP to the iLO and to the switch, SSH to the firewall — are listed in
[ADR-0013](adr/0013-segment-access-as-implemented.md).

**It does not hold for Hicks (50), and it does not hold for the switch LAN.**
Hicks blocks CasaBonita, Skids and Degens and then passes to `any`, so it reaches
**all of ImaginationLAN** on every protocol and port. Nothing denies it, and what
grants it is the catch-all rather than a decision about that segment — the one
rule that names ImaginationLAN grants nothing the catch-all was not already
granting. [#228](https://github.com/Gerrrt/HomeLab/issues/228) is where that gets
decided. The switch LAN carries pfSense's stock *Default allow LAN to any*
rule and reaches every segment.

**Winterfell is the half that has since been narrowed.** On 2026-09-02 the Hicks
interface gained ten host- and port-scoped passes into 99 and a logged *Block
access to Winterfell* under them, so Hicks now reaches management on an
enumerated list — SSH and ping to the segment, the firewall's admin UI, resolver
and NTP, the wiki, Grafana, and the UPS card — and nothing else.
[`network.md`](network.md#hicks--vlan-50--trusted) holds the list and is the
document to read for it. ADR-0013 read the ruleset the day before that landed
and describes the wider state; it is left as written, per ADR-0001, and this
section is where the current posture lives.

This section previously said "three exceptions", ADR-0002 said two, and ADR-0008
said five. All three were counts, and a count cannot express "reachable because
a catch-all was reached". ADR-0013 supersedes ADR-0002 and replaces the count
with a list; the audit behind it is recorded there. **A document that overstates
a control is worse than one that admits the exception**, and this one overstated
it for as long as it was a number.

Everything else — IoT, media, guest — gets internet and nothing more.

That last sentence is now checked rather than asserted. Three **tripwire** rules
([#223](https://github.com/Gerrrt/HomeLab/issues/223)) sit on the terminal
interfaces — `pass` + `log` for `<terminal net> → Internal_Segments`, below the
block rules that stop that path and above the `→ any` egress rule. They log
nothing while the design holds, and cost nothing; if one ever logs a line,
`TerminalSegmentReachedInternalNetwork` fires on it. Before them that alert
matched `action="pass"` against a firewall that logged only blocks, so it could
not fire for any input — the control was described here and not actually
watched. Note that a firewall restore from a backup older than 2026-09-01 drops
them silently; the restore runbook checks for them. A fourth, on ImaginationLAN,
is decided by ADR-0014 and lands with `ifrit`
([#234](https://github.com/Gerrrt/HomeLab/issues/234)).

Segmentation is doing more work here than it should have to. Prometheus and Loki
publish unauthenticated ingest ports for `oracle`'s agent to use, so anything
that can route to `10.0.99.20:9090` or `10.0.99.20:3100` can write to the metric
and log stores without a credential — which is exactly the failure ADR-0002
predicted when it recorded that "a compromised workstation reaches Winterfell".
That is an accepted residual, recorded in [`SECURITY.md`](../SECURITY.md), not a
solved problem.

**What has changed is who "anything" is.** A workstation on Hicks was in that
set for as long as the catch-all was the only rule in the way; since 2026-09-02
it reaches `10.0.99.20` on `3000` only and *Block access to Winterfell* drops
the ingest ports. What remains in the set is a host already on Winterfell, and
`10.0.30.110` on ImaginationLAN, which has an explicit pass to both ports for
`Saruman`'s Alloy agent. The residual narrowed by a firewall change nobody
recorded; [#182](https://github.com/Gerrrt/HomeLab/issues/182) still owns
closing it properly, because a control that depends on one un-reviewed rule
ordering is not authentication.

What has been taken off the firewall's shoulders is Alertmanager. It had no
off-host client, so it now binds to `127.0.0.1` and reaching VLAN 99 no longer
lets anyone silence an alert; see
[ADR-0012](adr/0012-publish-only-ports-with-an-off-host-consumer.md).

The IoT segment is the one that justifies the whole exercise. It holds cameras,
a doorbell, an alarm hub, smart speakers, a baby monitor and a $20 Tuya
white-noise machine. Every one of those is a network-connected computer running
firmware nobody outside its vendor has audited, several with no update
mechanism at all. Treating them as untrusted is not paranoia; it is the only
assumption consistent with what they are.

## Secrets

- Credentials are encrypted with [SOPS](https://github.com/getsops/sops) + age
  and committed in encrypted form. See [`secrets/README.md`](../secrets/README.md).
- The private key lives at `~/.config/sops/age/keys.txt` on the deployment host
  and is never in the repository. That host's disk is not encrypted — see
  [below](#everything-above-sits-on-an-unencrypted-disk).
- That key is the single point of failure for every encrypted secret here, so it
  is copied off the host and the copy is proven to decrypt with
  `make secrets-verify-backup KEY=<copy>` — which refuses to run against the live
  key and blanks the environment first, because the obvious hand-typed
  equivalent passes even for an unrelated keypair. See
  [`runbooks/back-up-the-age-key.md`](runbooks/back-up-the-age-key.md).
- `scripts/render-config.sh` decrypts at deploy time into gitignored files.
  Nothing writes a plaintext secret into a tracked path.
- `make secrets-edit` hardens `$EDITOR` before handing it the decrypted file, so
  the editor cannot persist the plaintext in an undo file, swap file or backup
  that sops does not shred. See [`secrets/README.md`](../secrets/README.md).
- CI runs `gitleaks` with rules specifically for SNMP communities, inline
  Grafana passwords, PEM private keys and age secret keys, and separately
  asserts that every `secrets/*.sops.yaml` is genuinely encrypted.

### Known historical exposure

This repository previously committed real credentials. Removing them from `HEAD`
does not remove them from history, and anything ever pushed to a public
repository must be treated as compromised:

| What | Where | Status |
| --- | --- | --- |
| SNMP community shared across all four devices | `snmp.yaml`, from commit `ee3d443` (now rewritten) | Purged from history. Replaced with four distinct per-device values, SOPS-encrypted. Rotated on all four. `morpheus`, `mjolnir` and `shiva` verified answering the new community and refusing the old; `neo` answers the new one but still accepts its previous community — accepted risk, see [`SECURITY.md`](../SECURITY.md) and the [runbook](runbooks/rotate-snmp-community.md) |
| Grafana `admin` / `admin` with anonymous Admin access | compose file | Fixed: password from SOPS, anonymous auth disabled |
| Decrypted secrets in editor undo files | `~/.local/state/nvim/undodir/`, written by `make secrets-edit` | Found 2026-08-20: three files holding the live pfSense, APC and iLO SNMP communities in plaintext, mode 664, on an unencrypted disk. Shredded. `make secrets-edit` now hardens the editor first, so it cannot recur. Never committed, never left the host, so the communities were not rotated on that basis |
| Alertmanager webhook URL and the MokerLink SNMP community | a local Claude Code session transcript under `~/.claude/projects/` | Found 2026-08-20 by a value-level sweep of the host. Redacted in place; mode 600, never committed or synced. The webhook was rotated because it is a one-line regenerate; the switch community was not, because rotating it means the `neo` residual below all over again |
| Passphrase-encrypted TLS private keys | `certificates/`, added in `efb2632`, deleted in `647d90a` | Purged from history, and the CA replaced — see [runbook](runbooks/generate-certificates.md). Anything that trusted the old CA must be re-pointed at the new one |

CI scans both the working tree and the full history, with no ignore file. Both
must be clean unconditionally.

There was a `.gitleaksignore` listing nine historical findings, each annotated
with what it was and why it was still there. It was an acknowledgement, not a
fix, and it existed because a CI job that is permanently red for a known reason
gets ignored — and then a genuinely new leak goes unnoticed alongside it. The
purge removed what it acknowledged, so the file was deleted. A history scan
that passes with no exceptions is the evidence the purge worked.

### Everything above sits on an unencrypted disk

Every entry in that table is something that happened once. This one is a
standing property of the host, which is why it is stated separately rather than
added as a sixth row.

Measured on `prometheus` (10.0.99.20):

- `/dev/mapper` holds `control` and `ubuntu--vg-ubuntu--lv` and nothing else —
  no LUKS anywhere. The root filesystem is plain ext4 on LVM.
- `/boot` and the EFI partition are likewise plain.
- `/swap.img` is 4 GiB, unencrypted, on that same root filesystem, and in use.
  Anything the stack has held in memory can have been paged into it.

Since [#114](https://github.com/Gerrrt/HomeLab/issues/114) the containers no
longer contribute to that last line. Every service in
`stacks/observability/compose.yaml` sets `memswap_limit` equal to its
`mem_limit`, which is `memory.swap.max = 0` — the stack cannot page out at all.
Left unset, `memswap_limit` defaults to twice `mem_limit`, so setting a memory
limit without one would have *increased* what reaches this file: a constrained
container spills to swap rather than being killed, and Grafana's admin password,
Alertmanager's receiver URLs and the SNMP community string are all resident in
those processes. The measured cost of switching it off is small — peak
`container_memory_swap` over the fourteen days that sized the limits was 70 MiB
for Prometheus, 17 for Alloy, 12 for Loki and under 5 for the rest.

This narrows the exposure; it does not close it. Swap is only one of the ways
memory reaches the disk, the host's own processes still swap freely, and
anything already paged out before this change was deployed is still in
`/swap.img`. The files below remain the substance of this section.

So the age private key at `~/.config/sops/age/keys.txt`, the rendered artefacts
under `snmp-exporter/.rendered/` and `alertmanager/.rendered/`, and
`stacks/observability/.env` — the last three hold plaintext by design, because
something has to hand the containers a usable credential — are protected by
nothing but file permissions. They are all mode 600 and owned by `robo`, which
is the right setting and is also the entire control. Permissions are enforced by
the running kernel; they mean nothing to a disk read on another machine.

This is accepted, not scheduled. The threat model above already excludes an
attacker with physical access to the rack, and this is that exclusion restated
where it actually bites. Full-disk encryption on a headless host has its own
failure mode — either a passphrase nobody is present to type after a power cut,
or a key stored on the same machine, which is most of the way back to where this
started.

It is recorded because it changes the severity of things that would otherwise
look minor. The undo-file leak above is the worked example: three community
strings at mode 664 in `~/.local/state/nvim/undodir/` were a real finding
*because* the disk beneath them is readable. On an encrypted disk that is a much
smaller problem. Neither fact is interesting alone.

### The UPS reported a battery it did not have

Until 2026-08-28 `mjolnir` had no battery installed. Its Network Management Card
nonetheless reported 100% state of charge, 48.0 VDC, a battery temperature, an
hour of runtime, a 2030 replacement date, and `upsAlarmsPresent = 0`. Every one
of those values was derived rather than measured.

The single honest signal it emits is the self-test result. The management card
rendered it as **Refused — internal fault**; over SNMP it is
`upsTestResultsSummary = 4` (aborted), from the standard UPS-MIB the `apc_ups`
module already walks. No extra OIDs were needed to see it.

Any alert rule keyed on charge, runtime or alarm count therefore could not fire,
no matter how bad things got. `UpsSelfTestFailed` and `UpsBatteryUnproven` in
`ups.rules.yaml` key on the self-test instead, and are the only two rules in
that file that can detect this condition.

This is worth stating carefully: the monitoring did not fail, and neither did
the rules. The device lied, and the rules trusted it.

**A pack was fitted on 2026-08-28, and that closed this.** A card that cannot
see a pack which *is* present — badly seated, or faulty out of the box — emits
the same five fabricated values as one sitting over an empty bay, so a
healthy-looking dashboard distinguished nothing. Only a passing self-test and
readings that have left the pre-fit baseline do, and both now hold:
`upsTestResultsSummary` went `4` (aborted) to `1` (donePass), `upsBatteryVoltage`
left `480` for a float reading that varies, and the runtime estimate no longer
sits on exactly `63`. The silence on `UpsSelfTestFailed` was deleted the same day
rather than left to expire in September, so that rule is live again.

Two things outlast the fix. Stored metrics older than 2026-08-28 *are* the
fabricated values rather than measurements, so a dashboard or query whose range
crosses that date is reading fiction on one side of it. And the card's test
schedule is on but unwatched. Read off the NMC on 2026-09-03,
`upsAdvTestDiagnosticSchedule` is `8` (biweeklySinceLastTest), which is what
*should* keep `1` from being a frozen last-known result — should, because
nothing here can confirm it still does. That OID is PowerNet, and
the `apc_ups` module walks the standard UPS-MIB only. Nothing here would notice
the card reverting to `never`: `upsTestResultsSummary` would hold `1` and every
rule would stay quiet. `UpsBatteryUnproven` cannot catch it either, because it
matches `6` (noTestsInitiated) and this card reads `1`. Note the shape of that —
the missing pack was visible in a MIB already walked, and the missing *schedule*
would not be. The manual check is in
[`runbooks/fit-the-ups-battery.md`](runbooks/fit-the-ups-battery.md), and
closing the gap is
[#249](https://github.com/Gerrrt/HomeLab/issues/249).

### Why SNMPv2c is still a weak point

The devices are polled with SNMPv2c, which transmits the community string in
cleartext. Anyone with a port on the management VLAN can read it off a single
packet. Two mitigations are in place, one only partly, and one is not:

- **Done:** each device has its own community, confirmed live on all four, so
  one captured packet no longer grants read access to the whole fleet. The
  switch does still accept its own previous community as well — an accepted
  residual, recorded in [`SECURITY.md`](../SECURITY.md).
- **Done:** SNMP is reachable only on the management VLAN and the
  switch-management LAN, neither of which anything but specific trusted hosts
  can enter.
- **Not done:** SNMPv3 with authPriv. The MokerLink switch does not support it.
  Tracked in [roadmap](roadmap.md).

These communities are read-only, but "read-only" on a firewall means the
complete state table and interface topology. They are credentials.

### The switch's management UI is HTTP, and stays that way

`neo` serves its management UI on port 80 and nothing on 443 — no TLS listener,
and no way to import a certificate. Checked against the device on 2026-09-04 and
decided in
[ADR-0018](adr/0018-name-the-switch-and-leave-its-ui-on-plain-http.md), which
gave the switch a name (`neo.matrix.elysium`) and closed the certificate half of
[#97](https://github.com/Gerrrt/HomeLab/issues/97) as unavailable rather than
pending.

So the switch admin password crosses the wire in cleartext, and it is worth
being precise about where: **through `neo` itself**, which is the device the
password protects. A mirrored port or a foothold on the switch sees the
credential to the switch. This is the same shape as the SNMP argument above and
a sharper version of it, because this credential is read-write.

What holds it: the password is unique to the device, and only Hicks and
Winterfell can reach `10.7.7.0/24` at all
([ADR-0013](adr/0013-segment-access-as-implemented.md)). What does not hold it:
anything on the device, which is now carrying its third firmware limit after the
undeletable community row and the missing SNMPv3. A TLS management interface
belongs in the selection criteria whenever this switch is replaced.

## Hardening applied to the stack

- Anonymous Grafana access disabled; sign-up disabled; admin password from SOPS.
- Every service except Alloy runs as a non-root uid. Prometheus and
  blackbox-exporter run as `nobody` (65534), Loki and Grafana as their own
  unprivileged UIDs (10001, 472), and Alertmanager and snmp-exporter as the
  operator's `${RENDER_UID}` because each mounts a 0600 file that
  `scripts/render-config.sh` wrote. blackbox-exporter needs its `user:` written
  out because its image sets none — it was uid 0 until #330, which is how it
  went unnoticed for as long as it did. Alloy is uid 0 on purpose and is
  covered separately below: it reads the host's logs, and the capability drop
  rather than the uid is what bounds it.
- `snmp-exporter` is never published to a host interface — it is reachable only
  on the compose network.
- Alertmanager binds to `127.0.0.1` only. It is unauthenticated, and a silence
  is how monitoring gets switched off — quietly, since the record lives in the
  system being switched off. Nothing off-host used the port; silences are
  reached through Grafana. Prometheus and Loki are *not* in this list: they stay
  published for `oracle`'s agent and remain an accepted residual. See
  [ADR-0012](adr/0012-publish-only-ports-with-an-off-host-consumer.md).
- The Alloy debug UI binds to `127.0.0.1` only.
- The Docker socket is mounted into Alloy. It is marked `:ro`, which is worth
  less than it looks: read-only applies to the socket *file*, not to the API
  behind it, and anything that can talk to that API can start a container with
  the host filesystem mounted read-write. This is the one remaining path from a
  compromised Alloy to root on the host — see the paragraph below the list.
- Alloy holds no capabilities. It runs as uid 0 with `cap_drop: [ALL]` and
  `no-new-privileges`, so root inside it is subject to file permissions like any
  other user, and joins only the group that owns `/var/log/syslog` so the auth
  and syslog sources stay readable (#188). `scripts/deploy-agent.sh` applies
  the same flags to every Docker host it deploys to, so `oracle`'s agent is
  no longer the privileged copy it was until #88; on `Saruman` the native
  package runs as its own unprivileged `alloy` user.
- The other six services hold no capabilities either. Each carries
  `cap_drop: [ALL]` and `no-new-privileges:true` (#187). For five of them this
  is belt and braces and the honest description matters: they already ran
  non-root with an effective set of zero, so what the drop clears is the
  *bounding* set — the capabilities a process could regain, not any it held.
  What that buys is that a future image bump shipping a setuid or
  file-capability binary cannot be used to gain one, which `no-new-privileges`
  independently forecloses. None of the six pinned images contains such a
  binary today; each container's filesystem was exported and scanned for the
  setuid and setgid bits. blackbox-exporter was the exception when #187 landed:
  it was running as uid 0 with the full effective set, so there the drop removed
  something real. #330 then gave it a non-root uid as well, which puts it in the
  same belt-and-braces position as the other five — the position to be in, and
  not a reason to drop either setting.
- Every service runs under a real init (`init: true`) and a chosen task ceiling
  (`pids_limit`, 512; 1024 for Alloy) rather than the inherited systemd default
  of 9056. This was not theoretical: Grafana's https healthcheck was leaking two
  unreaped `ssl_client` children every 30 seconds and would have exhausted the
  inherited ceiling about three days after each start (#71).
- Prometheus carries a byte ceiling as well as a time one, so a change that
  quietly multiplies the series count cannot consume the disk unnoticed.
- All images are pinned to explicit versions, so an upstream compromise cannot
  arrive silently via `:latest`. Dependabot proposes the bumps; CI validates
  them.
- Grafana telemetry and update checks disabled.

Alloy no longer runs `privileged: true`. It never needed it: `cgroup: host` is
what makes cAdvisor see the host's cgroups, and dropping every capability
changed no container metric and cost six unused series —
`node_rapl_*_joules_total` and `node_cpu_{core,package}_throttles_total`, which
read root-only sysfs and which nothing here references. Before that change Alloy
ran as uid 0 with the full capability set, a read-only mount of `/`, and could
therefore read `~/.config/sops/age/keys.txt` directly. It can no longer.

What remains is the Docker socket, and it is the larger half. Read access to
that API is enough to create a container with `/` mounted read-write, which is
root on the host and the age key with it — so the paragraph in `SECURITY.md`
saying file permissions are all that protect the plaintext artefacts is true of
every process on the host *except* a compromised Alloy. Putting the socket
behind a proxy that permits only the handful of GETs cAdvisor and the log
discovery actually use is tracked separately; the privilege reduction above is
defence in depth, not a closed door.

### A writable directory inside Alloy's read scope

Scheduling the maintenance jobs ([#77](https://github.com/Gerrrt/HomeLab/issues/77))
put `/var/lib/node_exporter/textfile_collector` on the host, owned by the
deploying user and read by Alloy's textfile collector through the `/rootfs`
mount that already existed. It is `0755` with `0644` files, and it has to be:
Alloy runs as root with every capability dropped, so it obeys the mode like
anyone else and a `0600` file would simply be invisible to it.

The contents are four numeric gauges per job — timestamps, a duration and an
exit code. Nothing secret is written there, and nothing decrypted passes through
it. What it does create is a path from *write access as that user* to *arbitrary
metric names and label values in Prometheus*, since the collector will parse
whatever it finds. Two things bound that: only the deploying user can write, and
`scripts/run-scheduled.sh` constrains the one operator-supplied field to
`^[a-z][a-z0-9-]{0,30}$` before it becomes either a filename or a label value.

Anyone who can write there can already run the jobs themselves, so this adds no
privilege — but it is a new file-backed input to the metrics pipeline, and that
is worth stating rather than discovering.

## What this repository deliberately does not publish

Being able to describe a network precisely is useful; publishing a complete
fingerprint of a house is not. Withheld on purpose:

- **Full MAC addresses.** Truncated to the OUI, which keeps the useful
  information (vendor, and therefore what the device is) and drops the unique
  identifier. Full MACs enable device tracking and, on some networks, MAC-based
  access control bypass. This is also why the unknown-device rules hold no
  allowlist: the set of known devices is whatever Loki has seen in the last
  seven days, so nothing in this repository has to enumerate them.
- **Owner-linked device names.** Personal devices are listed by role
  (`laptop-01`) rather than by person, and a child's bedroom is not labelled.
- **Camera-to-room mapping.** Knowing there are seven cameras is fine. Knowing
  which one covers which door is a physical-security detail.
- **The WAN address**, firewall rule bodies, and Wi-Fi configuration.

The public IP was already redacted in the original inventory — the rest of this
is the same instinct applied consistently.

**Rack patch-cable colours are published**, and that is a deliberate exception
worth defending rather than an oversight. It is the same *shape* of information
as the camera-to-room mapping above — a physical-security detail — but not the
same *reach*. A room mapping is useful remotely: you learn which camera covers
which door straight off this page, without ever approaching the house. A cable
colour is useful only to someone already standing at the rack, who can see the
cables, read the switch port labels and reach the firewall's console port
regardless. It tells an attacker nothing their position has not already given
them, and it tells a maintainer a great deal. See
[ADR-0009](adr/0009-colour-vlans-by-cable-not-by-trust.md).
