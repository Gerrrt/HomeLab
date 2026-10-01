# Changelog

What happened, and what it found, in the order it happened. Newest first.

An entry is written on the day and carries its date, and it is never
rewritten: a correction is a new entry that names the one it corrects. That
is what keeps this file from going stale — every sentence here is a claim
about a date, not about now. What is *outstanding* is the other file,
[`roadmap.md`](roadmap.md), and the shape of it; status is on the issue.

Everything below the first heading was moved out of `roadmap.md` on 2026-09-20
under [#577](https://github.com/Gerrrt/HomeLab/issues/577), verbatim. Each
block is filed under the latest date it names; a block that names no date is
filed under the date of the commit that wrote it. So "above" and "below" inside
an older entry, and a line like "the #414 paragraph above", refer to the
roadmap as it read that day, and the *Done* entries keep the shape they had
there. `check_docs.py` does not check this file, for the reason its module
docstring gives: it is a record, not a claim about now.

## 2026-10-01

- **[#455](https://github.com/Gerrrt/HomeLab/issues/455): whose key opens the
  household's copy is decided, and the drive is here**
  ([ADR-0073](adr/0073-carry-the-household-copy-on-a-drive-the-holder-keeps.md)).
  - **The drive.** The WD Elements arrived on 2026-09-29. It cost $236.70,
    against the ~$150 the issue estimated. Both are in `hardware.md`, which
    closes that entry's one gap.
  - **The key.** The copy is encrypted to the household holder's key, with
    ADR-0024's technical second as a fallback. If they turn out to be one
    person, it is one recipient. The technical second's key alone is rejected,
    because then the household could recover only through a technician.
  - **Where the keys live.** In `stacks/sensitive/household.recipients`, with
    a role per key, and not in the sensitive sops rule. That rule would also
    open the tier's passwords. `scripts/household-recipients.sh` reads the
    file. It refuses a malformed line, a wrong Bech32 checksum, and a file with
    no fallback key. One person in both roles is written once as
    `household-and-technical-second`. `check_sops_rules.py` now fails if a
    household key appears in any rule, or if a fallback key there is not the
    catch-all's.
  - **What changes on `trinity`.** `backup-library.sh` encrypts each Immich
    set to the sensitive rule's recipients plus that file's. Today that adds
    the technical second, so the first set made after this reaches `trinity`
    is the first that `trinity`'s key does not hold alone. `oracle`'s copies
    open with the same keys.
  - **What is still open.** The holder is not chosen. The drive is exFAT with
    age archives because nobody knows what device that person uses. The proof
    from their device, without the operator, is condition two and still
    #455's. The carry to the drive and its deadline alert are the next change.
    ADR-0064 stays the stand-in until that proof is run.
- **The ISO store is built, and `Saruman` mounts it**
  ([#446](https://github.com/Gerrrt/HomeLab/issues/446),
  [ADR-0072](adr/0072-put-the-iso-store-on-smaug-over-nfs-to-saruman-alone.md)).
  It follows the earlier entry below, *The ISO store is decided*, which had
  only the dataset.
  - **On `smaug`.** `pippin` (uid `3003`, gid `3002`) owns
    `/mnt/erebor/iso`. The NFS share admits `10.0.30.110` alone and maps
    root to `pippin`. Record size reads `1M`.
  - **The pass.** `Allow NFS from Saruman to smaug`,
    `10.0.30.110 → 10.0.40.30:2049`, printed directly above `igc0.30`'s
    *Block access to CasaBonita* in `pfctl -sr -vv` on `morpheus`. That
    block is now named in `network.md`'s ImaginationLAN notes, as
    `build-the-backup-guest.md` §4 asked.
  - **On `Saruman`.** An `fstab` mount at `/mnt/smaug-iso` shows `500G`,
    which is the quota. The `dir` storage `smaug-iso` is active. A web-UI
    upload of `virtio-win-0.1.302.iso` landed owned by `3003:3002`, not
    root, in about 330 MiB on disk under lz4.
  - **The scope.** `alexander` and the monitoring host are both refused on
    `2049`, and the `igc0.40` tripwire reads **0 packets** after 260,980 evaluations.
  - **Found on the way.** An `alloy` upgrade on `Saruman` had been left
    half-configured, and the step's `apt install` finished it. dpkg asked
    about `/etc/default/alloy`. Keeping the installed file (`N`) was right,
    because it is `scripts/deploy-agent.sh`'s and holds the push endpoints.
    Alloy was `active` afterwards.
- **A PR whose close keywords sit in prose now fails
  ([#672](https://github.com/Gerrrt/HomeLab/issues/672)).**
  - **The gap.** GitHub closes an issue for a close keyword anywhere in a PR
    body or a commit that lands on main. Eight issues were closed by prose
    that said they stayed open, and three sat closed with the work undone
    until the 2026-09-26 pass. A ninth, #776, was named by #780 on 2026-09-30
    as "Refs" and as closing in the same body. Checking
    `closingIssuesReferences` by hand had not been enough.
  - **Now.** `scripts/check_close_keywords.py` runs on every PR from its own
    workflow, `close-keywords.yml`, which re-runs when the body is edited. It
    reads the title, body, commits and `closingIssuesReferences` over GraphQL
    and fails when a close keyword is not the first word of its sentence,
    when its sentence says not, nothing or stays open, or when an issue the
    merge will close is also named with `Refs`. The issues the merge will
    close go to the job summary either way. An intended close is written
    `Closes #N.` as a sentence of its own.
  - **Proved against the record.** Run read-only on the PRs that did it: #319,
    #252, #382, #521, #545, #652, #664, #758 and #780 all fail; #781 and #743
    pass and list what they closed. Each phrase is also a fixture in the
    script's `--self-test`.
  - **Drafts.** `--text FILE` (or `-` for stdin) lints a PR body or commit
    message before it is pushed.

- **`stacks/scratch` authored, a disposable copy of the SOC stack**
  ([#438](https://github.com/Gerrrt/HomeLab/issues/438),
  [ADR-0071](adr/0071-run-disposable-investigations-on-a-guest-that-is-destroyed.md)).
  It is for detonations and one-off questions, so that their noise never spends
  `odin`'s shard budget or enters its record.
  - **Where it runs.** On `diabolos` (`10.0.30.61`, VMID 161), a guest built per
    investigation and destroyed with `qm destroy --purge`
    ([`run-a-scratch-investigation.md`](runbooks/run-a-scratch-investigation.md)).
    The stack is authored and CI-validated ahead of the guest, as `stacks/soc`
    and `stacks/sensor` were.
  - **What it runs.** soc's four services on soc's digests, with soc's
    configuration mounted rather than copied.
  - **What it leaves out.** No ISM policy, Alloy, scrape or backup.
  - **Lifecycle.** `scripts/collect-guest-state.sh` now also reads each guest's
    `qm config` and reports `homelab_guest_disposable`, from the Proxmox tag,
    and `homelab_guest_created_timestamp_seconds`, from `meta: ctime`.
    - A new estate rule, `DisposableGuestOutlived`, fires when a guest tagged
      `disposable` is more than a fortnight old, running or stopped.
    - `HypervisorGuestStopped` no longer fires for such a guest.
    - `GuestConfigUnreadable` fires when a guest's config has been unreadable
      for an hour, from a per-guest `homelab_guest_config_readable`. Without it,
      a failed read would silently blind the age rule.
    - Run read-only on `Saruman` the same day, the collector reported all ten
      guests with a creation time and none disposable, in 14.5 s.
  - **Secrets.** The guest gets its own `.sops.yaml` rule above the catch-all,
    with a placeholder that stays in git. Its encrypted secrets file is
    gitignored and never committed.
- **Convergence reported "converged" over rules it had never deployed.**
  - **The finding.** After #781 merged, the deployment checkout on
    `prometheus` was already at the merge, but Prometheus was serving the
    pre-merge rules: none of #781's four `Guest*` rules were loaded. The timer's
    last run predated the merge, so the checkout had been moved some other way,
    most likely a `git pull` by hand. `make converge` then found HEAD equal to
    `main`, printed `converged`, recorded `behind=0`, and ran no `make up`. It
    would have done the same every hour.
  - **Why nothing fired.** Every deploy alert reads HEAD, and HEAD was right.
    Found by reading the Rules page. Fixed by hand with `make reload`.
  - **A second case, same cause.** A `make up` that failed after a
    fast-forward left HEAD at `main`, so the next hourly run reported
    `converged` and never retried it.
  - **Now.** `make up` ends by recording the revision it applied
    (`scripts/record-applied.sh`). `converge.sh` deploys any checkout whose
    HEAD differs from that record, so a hand pull or a failed deploy clears on
    the next run. `homelab_deploy_unapplied` and `DeployUnapplied` (two hours,
    warning) cover the cases it cannot fix: report-only mode, and `make up`
    failing every time. The first run after this ships has no record and
    redeploys once.
- **The ISO store is decided, and its dataset exists**
  ([#446](https://github.com/Gerrrt/HomeLab/issues/446),
  [ADR-0072](adr/0072-put-the-iso-store-on-smaug-over-nfs-to-saruman-alone.md)).
  `erebor/iso` was created through the TrueNAS API: lz4, atime off, a 500 GiB
  quota, POSIX ACLs, and no snapshot task, because ISOs are replaceable. It
  will be exported over NFSv4 to `10.0.30.110` alone, with root mapped to
  `pippin`, through `Allow NFS from Saruman to smaug` on `2049`. None of
  that exists yet: the user, the share, the pass and `Saruman`'s mount are
  not done.
  [`build-the-nas.md`](runbooks/build-the-nas.md) §5b is the procedure. The
  NFS service on `smaug` was not running on this date, and neither was
  `golem`'s share. Proxmox's NFS storage type checks the portmapper on `111`
  before it probes `2049`, so `Saruman` mounts the share from `fstab` and
  adds it as a `dir` storage instead.

- **JA4+ is vendored into `stacks/sensor`, and not yet deployed**
  ([#776](https://github.com/Gerrrt/HomeLab/issues/776),
  [ADR-0069](adr/0069-vendor-the-ja4-scripts-into-the-sensor-stack-rather-than-build-an-image.md)).
  - **What.** FoxIO's `ja4-zeek-scripts` at
    `8bf9feca52790ae8c926c6a8d79a3547ac19541a`, in `stacks/sensor/zeek/ja4/`.
    Its btest suite and traces are left out. `LICENSE`, `LICENSE-JA4` and a
    NOTICE of our own say what covers what. The directory is mounted read-only
    and `@load`ed from `local.zeek`. No image is built.
  - **How it changes.** `scripts/vendor-ja4.sh <sha>` replaces the tree at a
    full SHA, keeping NOTICE and rewriting VENDORED. `--check` re-fetches that
    commit and diffs byte for byte. It passed.
  - **One EditorConfig exclusion.** Upstream has trailing spaces and missing
    final newlines in 15 files, and editing them would make every re-vendor's
    diff partly ours. With the exclusion, `editorconfig-checker` v4.0.2 (the
    pinned version) passes the tree. Without it, the same files fail with 80
    errors.
  - **Proved on `fenrir`, offline.** On the pinned `zeek/zeek:9.0.0`,
    `zeek -a` parsed `local.zeek` with the package loaded. A replay of a TLS
    session captured from Saruman to Cloudflare wrote `ja4`
    `t13d3013h1_1d37bd780c83_8537cf56674e` and `ja4s` to `ssl.log`, and
    `ja4t`, `ja4ts`, `ja4l` and `ja4ls` to `conn.log`.
  - **Not yet live, so #776 stays open.** Its done-criteria are a JA4 from a
    guest's outbound TLS on `fenrir` and a Loki query returning it. This
    change is only an offline replay, so it refers to #776 rather than closing
    it. The stack deploys from `main`. Until then, the sensor keeps building
    the "before" half of ADR-0069's measurement on the corrected baseline:
    0.0% `percent_lost` since the GRO fix (#782), not the 8.1% first recorded.
    After deployment, the "after" half is `capture_loss.log` and `stats.log`
    for a week.
- **`fenrir`'s 8% capture loss was GRO reordering, not loss, and is fixed**
  ([#437](https://github.com/Gerrrt/HomeLab/issues/437) follow-up;
  [ADR-0069](adr/0069-vendor-the-ja4-scripts-into-the-sensor-stack-rather-than-build-an-image.md)
  recorded it as a baseline).
  - **Where the gaps were.** About 17 of 17.5 MB of `missed_bytes` were on
    flows to Saruman itself: Hicks to `:8006`, and the replies to Saruman's own
    outbound HTTPS. Every gap was in data travelling toward Saruman. Guest
    flows had none: 3 gapped connections in 1,185 inbound to guests.
  - **Nothing was dropped.**
    - The mirred actions showed 0 dropped.
    - `tap190i1` sent 576,935 packets and `ens19` received 577,007, with no
      drops on either side.
    - Zeek's `pkts_dropped` was 0.
    - A capture on `tap190i1` during a 10 MB download to Saruman found every
      segment present and in order. The same flow in Zeek had 69,504 bytes
      missed.
  - **The cause.** GRO on `ens19`, in the guest. It holds a flow's data to
    merge it but passes the opposite direction straight through. Saruman ACKs
    within microseconds, so its ACKs overtook the held data. Guests ACK through
    a VM, too slowly to overtake, which is why only host-bound flows gapped.
  - **The proof.** Measured on the same 10 MB download from the same server:
    - Saruman with GRO on: 50,680 and 69,504 bytes missed, histories with `g`.
    - `alexander` with GRO on: 0.
    - Saruman with `ethtool -K ens19 gro off rx-gro-hw off`: 0, history
      `ShADadtttFf`.
    - After two reboots of `fenrir`: still 0.
  - **Kept by `capture-offloads.service` on `fenrir`.** Its first version was
    wanted by the `ens19` device and did not run on reboot. Ubuntu 26.04's
    dracut initramfs brings `ens19` up before switch-root, so the device unit
    is already active and its `Wants=` is never pulled in. It hangs off
    `multi-user.target` now. The runbook's §3 carries the unit.
  - **Also seen.** In that initramfs window, dracut's catch-all
    `zzzz-dracut-default.network` gives `ens19` an IPv6 link-local address for
    about five seconds until netplan's config takes over. That accounts for the
    nine packets `ens19` had sent despite being set never to speak. They reach
    nothing, because `vmbr1` has no other port and no address.

- **A lab guest's disk now pages ([#778](https://github.com/Gerrrt/HomeLab/issues/778)).**
  This follows on from "odin's root disk was at 98%" below.
  - **The gap.** The lab rules that entry added show in the lab's Grafana and
    page nobody (ADR-0020), so a filling SOC disk was still noticed only by
    someone already looking.
  - **The decision.**
    [ADR-0070](adr/0070-let-guest-disk-capacity-cross-read-through-the-hypervisor.md)
    lets a guest's filesystem capacity cross. `Saruman` reads it through each
    guest's agent with `qm guest cmd <vmid> get-fsinfo`, so no network path is
    added. It amends ADR-0028's table and narrows ADR-0007, with a note on
    each. The agent's answer is treated as hostile input.
  - **Now.**
    - `scripts/collect-guest-disk-state.sh` runs every ten minutes on
      `Saruman`.
    - The estate's `GuestDiskCritical` (below 10% free) and
      `GuestDiskWillFillIn24h` are both critical, so they reach a phone.
    - `GuestAgentSilent` and `GuestDiskStateStale` warn when the reading
      itself stops.
    - The promtool tests use odin's numbers from that morning: 622 MB free of
      30 GB.
  - **Installed on `Saruman` and run once, before the rules deployed.** That run
    read all ten running VMs, and nine agents answered. `phoenix` has no agent,
    so it stays quiet. The run also caught a defect: each Windows guest's two
    ISO drives (`CDFS` and `UDF`) report 0% free, and the collector would have
    turned them into twelve critical pages. The fstype filter now skips both,
    case-insensitively, and the self-test carries `bahamut`'s real answer.
    Install with `make install-agent-collectors AGENT=root@10.0.30.110
    ARGS='--only guest-disk-state'`, because the Mac cannot resolve `Saruman`.
- **The lab domain's six guests are documented as built.** `docs/architecture.md`
  still called `bahamut`, `leviathan`, `titan` and `ramuh` **not built yet**,
  and `carbuncle` and `siren` **built, not joined**. In fact the domain was
  built by hand on 2026-09-24 and 2026-09-25
  ([#414](https://github.com/Gerrrt/HomeLab/issues/414)), and the lab
  Prometheus has scraped all six since 2026-09-26.
  - **Read from each guest on 2026-10-01**, by `qm guest exec` from `Saruman`.
    All six report `PartOfDomain` true for `ad.matrix.elysium`:
    - `bahamut` is the primary domain controller (role 5);
    - `leviathan` is the backup domain controller (role 4);
    - `titan` and `ramuh` are member servers (role 3), on Windows Server 2025
      Standard Evaluation;
    - `carbuncle` and `siren` are member workstations (role 1), on Windows 11
      Pro.

    `carbuncle` had already authenticated to `titan` as `CARBUNCLE$` over
    Kerberos in #437's check the night before.
  - **Changed.** The six architecture rows lose their markers and say when they
    were built. The four servers get rows in `docs/network.md`'s VLAN 30 table,
    and its note on the endpoints says they are joined. #414 itself stays open
    for its §6, §10 and §11.
  - Copilot's review of #774 surfaced it. It read the stale rows as "six still
    planned".

- **odin's root disk was at 98%, and nothing would have said so.**
  - **The finding.** Found by the login banner, read as 92.8% by `df`'s other
    formula. It was 28 GB used of a 30 GB OS disk, with 622 MB free. The data
    disk at `/srv/soc-data` was mounted and 13% used, so the stores the design
    puts there were where they belonged.
  - **What filled it: superseded Docker images.** 15.75 GB, of which
    7.787 GB were five images no container used: the previous digests of the
    indexer, manager, dashboard, Alloy and the certs generator. Wazuh's own
    on-disk alerts were 31 MB, not the cause.
  - **Fixed by hand.** `docker image prune -a -f` brought `/` to 72%, with
    7.9 GB free.
  - **Why it was invisible.** The monitoring host has pruned weekly since
    2026-09-29. No agent host did. And odin's disk was watched by nothing: the
    estate cannot see a lab guest (ADR-0007), and the lab Prometheus had no
    disk rule.
  - **Now.** `prune-images` is a row in `install-agent-collectors.sh`, a
    weekly timer on every Docker agent host. The lab has the estate's
    `HostDiskWillFillIn24h` and `HostDiskCritical`, tested, which show in the
    lab's Grafana and page nobody (ADR-0020).

- **`check_mounted_config.py` could not fail, and Alertmanager had been running
  a stale config for two days.**
  - **The cause.** The check read each container's copy of a single-file mount
    with `docker cp`. For a bind mount, `docker cp` re-resolves the mount's
    source path on the host, so it reads the file git just wrote, not the
    inode the container is pinned to. Measured on a scratch container after a
    rename: `docker exec cat` said `old`, `docker cp` said `new`. Every
    comparison was the new file against itself.
  - **How it showed up.** On 2026-09-30 it reported `blackbox.yaml` as
    matching while the blackbox exporter ran without the module #182 had just
    added.
  - **The fix.** The check now reads through the container's own mount
    namespace: `/proc/1/root/<path>`, from a helper that shares its PID
    namespace, with `SYS_PTRACE` and `DAC_READ_SEARCH`. A `--self-test`
    reproduces the rename. It passes with the new reader, and fails three of
    its five cases with the old one.
  - **What it found at once.** Alertmanager had been running the config from
    before #716, #719 and #761 since it was last recreated on 2026-09-28. The
    one functional difference was #761's inhibit (`TlsAcmeRenewalStalled`
    over `TlsAcmeRenewalLate`), so a stalled ACME renewal would have paged
    twice. Recreated, and verified with the new reader.
  - **The other hosts.** trinity's sensitive stack has 12 single-file mounts,
    and all 12 match. `oracle`'s wiki has none. The lab and SOC hosts were not
    reachable from here and are unchecked.

## 2026-09-30

- **Zeek on `fenrir` is built, and the gauge is proved by a reboot**
  ([#437](https://github.com/Gerrrt/HomeLab/issues/437), closed;
  [ADR-0068](adr/0068-mirror-the-lab-bridge-to-zeek-with-tc-not-open-vswitch.md),
  [`build-the-sensor-guest.md`](runbooks/build-the-sensor-guest.md)). Times
  are Pacific.
  - **§3 and §4, the guest.** Ubuntu 26.04.1 went on the 32 GB disk, and the
    64 GB data disk is mounted at `/srv/sensor-data` with an immutable empty
    mountpoint underneath.
    - The installer had set the capture NIC `ens19` to accept router
      advertisements, and it had an `fe80::` address. `60-capture.yaml` takes
      both away. A reboot proved the mount and the NIC.
    - The SSH that answered during the install was the installer's, with its
      own host key. Before trusting the installed system's key, `Saruman`
      confirmed that `10.0.30.90` is `fenrir`'s MAC, learned on `tap190i0`.
    - Docker comes from Docker's repository, its key checked against the
      published fingerprint. `local.zeek` parsed on the pinned `zeek/zeek:9.0.0`
      image (`zeek -a`), the first time it had been parsed at all.
    - `stacks/sensor` came up. The lab's Loki on `alexander` has 20 Zeek log
      types from it.
  - **§5, the mirror.** The mirror job's first run applied all 11 targets:
    `eno1`, nine guest taps and `vmbr0`'s own egress. The gauge read 1, with 11
    of 11 ports mirrored and 3,116 packets.
    - The installer was run from the checkout on `Saruman`, so it SSHed to
      `root@10.0.30.110` from `10.0.30.110`. That fired the critical
      `SshLoginFromUnexpectedSubnet` (18:32 login, resolved by 18:45). It was
      not a breach. The runbook now says to run the installer from Hicks.
  - **§6, the checks.**
    - **East-west traffic.** `net view \\titan` from `carbuncle` showed up as
      a Kerberos TGS from `carbuncle` to `leviathan` for `cifs/titan`, the AP
      exchange at `titan`, an `IPC$` mapping, and `srvsvc` `NetrShareEnum`.
      None of that crosses a router.
    - **TLS.** Server names were logged.
    - **Loki.** `| json` queries return fields.
    - **VLAN 99.** `fenrir`'s Alloy points only at `alexander`.
    - **The stop test took two tries.** The first was invalid: `fenrir` was
      started again at 18:45:00, 38 seconds before the gauge's first run after
      the stop, so it never read 0. The alert reported then was the SSH one
      above. The second worked:
      - stopped at 18:49:38;
      - the mirror job removed all 11 filters 19 seconds later;
      - the gauge read 0 from 18:50:18;
      - `ZeekMirrorInactive` fired at about 19:02;
      - started at 19:07:12, filters back at 19:08:17, gauge 1 at 19:10:06,
        and the alert resolved.
  - **§7, the reboot proof.** `homelab-zeek-mirror.timer` was disabled at
    19:11:31 and `Saruman` rebooted. It was up at 19:15:46.
    - The gauge read 0 on all eleven runs from 19:20 to 20:05. The guests were
      up, `fenrir`'s tap was up, 0 of 9 ports were mirrored, and the packet
      count stayed flat at 2.
    - `ZeekMirrorInactive` fired, confirmed on the estate's side.
    - The timer was re-enabled at 20:10:26. Its first run covered the 9 ports
      present. The next, at 20:11:27, added `carbuncle`'s and `siren`'s, which
      had just been started. The gauge read 1 at 20:11:31 (11 of 11, 21,461
      packets).
    - The issue's test was that a unit that silently stopped must not leave a
      healthy-looking metric behind. It did not.
  - **Cleaned up.** The temporary passwordless `sudo` for `atreus` on `fenrir`
    is removed. `carbuncle` and `siren` are `onboot=0` by design, so they came
    back only when started by hand.
  - **Still open:** JA4 fingerprints, which need a derived Zeek image.

- **`vmbr1` exists on `Saruman`**, the first host step of #437's build
  ([`build-the-sensor-guest.md`](runbooks/build-the-sensor-guest.md) §1).
  - **Applied with `ifup vmbr1`, not `ifreload -a`,** so `vmbr0` was never
    re-applied. `ifquery --check -a` passed before and after. `vmbr0` kept
    `10.0.30.110/24` and all nine guest taps, and Proxmox lists `vmbr1` as a
    bridge with no ports.
  - **It got an IPv6 link-local address on creation.** That would have made
    the hypervisor reachable from the capture network. `ipv6-addrgen off` was
    added to the stanza and removed the address the same minute. The runbook
    now includes that option.
  - **ifupdown2 crashed under the session's `PATH`**, with
    `No module named 'systemd'`, because mise's Python came first. Run with
    the system `PATH`, it worked. The runbook now says to use it.
  - The original file is kept on the host as
    `/etc/network/interfaces.bak-437-20260930`.

- **`fenrir` is created on `Saruman`**, VMID 190, stopped and not yet
  installed ([`build-the-sensor-guest.md`](runbooks/build-the-sensor-guest.md)
  §2, as written). `net0` is on `vmbr0` and `net1` on `vmbr1`, both
  `firewall=0`. The disks are 32 and 64 GiB on `large_data`, and `onboot` is 1.
  The ISO is `ubuntu-26.04.1-live-server-amd64.iso`, the one on the host,
  which is what the other Linux guests run. The runbook named 24.04, and now
  names 26.04.1.

- **The offline medium carries the wiki's database too**
  ([#251](https://github.com/Gerrrt/HomeLab/issues/251),
  [ADR-0065](adr/0065-pull-the-wikis-database-to-prometheus-as-a-dump.md)).
  `backup-offsite.sh` gains a fourth kind: the newest `backups/wiki/` set
  travels into `backups/wiki/` on the medium. It is held to the same
  recipients check as the NAS set, so a set one key cannot open is not
  copied. A visit without a wiki set records no proof, the way a missing
  NAS set already did. It leaves the house on the medium's next visit.

- **#437's mirror is `tc`, not Open vSwitch, and the repository half is
  authored** ([#437](https://github.com/Gerrrt/HomeLab/issues/437), still open;
  [ADR-0068](adr/0068-mirror-the-lab-bridge-to-zeek-with-tc-not-open-vswitch.md)).
  - **The issue's premise was wrong.** It said port mirroring needs Open
    vSwitch. Read on `Saruman`: `vmbr0` is a Linux bridge on `eno1` with nine
    guest taps, `tc` is installed, and OVS is not. A `clsact` qdisc with a
    `matchall` `mirred` filter on each port's ingress mirrors every frame once.
    `vmbr0` is not converted, and the management plane never moves.
  - **Proved in a network namespace on `Saruman`, not on the bridge.** The
    ensurer applied three ports, and was idempotent on the second run. The
    collector read `active=1` with packets moving and `active=0` when the
    counter was flat. Recreating the capture tap left every filter as
    `Egress Mirror to device *`: `mirrored=0/3`, with no error anywhere. The
    next ensurer run repaired all three, and removing the tap removed all
    three filters. That failure is why the ensurer runs every minute and
    matches the tap by name.
  - **Authored:**
    - `scripts/zeek-mirror.sh` and `scripts/collect-zeek-mirror-state.sh`, with
      `--self-test` fixtures;
    - their units under `systemd/agent/`, and two rows in
      `install-agent-collectors.sh`;
    - `ZeekMirrorInactive` and `ZeekMirrorStateStale`, with promtool tests;
    - `stacks/sensor` (Zeek 9.0.0 and Alloy, logs to `alexander`, no secrets);
    - [`build-the-sensor-guest.md`](runbooks/build-the-sensor-guest.md).
  - **Not built.** `fenrir` does not exist yet, and nothing was applied to
    `vmbr0`. Run from the checkout on `Saruman`, the collector's `--print`
    reports that VM 190 does not exist and publishes nothing. That is
    deliberate: a sensor never built is not a sensor that is down, and
    installing the collector early must not page. #437 closes on the
    runbook's §7 reboot proof, not on this.
  - **JA3/JA4 are not in the stock Zeek image.** Fingerprints need a zkg
    package baked into a derived image, which is a follow-up rather than part
    of this change.

- **The ingest ports want a token**
  ([#182](https://github.com/Gerrrt/HomeLab/issues/182),
  [ADR-0067](adr/0067-authenticate-the-ingest-ports-with-a-token-per-client.md)).
  Authored, not yet deployed.
  - **The proxy.** Prometheus and Loki move to `127.0.0.1`. A Caddy service
    holds `10.0.99.20:9090` and `:3100` in their place. It serves a push to
    one bearer token per agent (`oracle`, `trinity`, `Saruman`) and a query to
    one reader token (Homepage, Home Assistant, the deploy script). It serves
    the admin, lifecycle and delete APIs to nobody.
  - **Measured on the pinned image** with stand-in upstreams, across 26
    requests. Agent tokens pushed and could not read. The reader read and
    could not push. No token, a wrong token, a `Bearer` with no token and a
    lowercase `bearer` were all refused. So were admin, `/-/quit`,
    `/-/reload`, the UI, Loki's delete and the compactor, for every token.
    The access log wrote the header as `REDACTED`.
  - **Two findings from that boot.** First, `cap_drop: [ALL]` alone makes the
    kernel refuse to exec Caddy, which carries `cap_net_bind_service` as a
    file capability, so `NET_BIND_SERVICE` stays in the bounding set. Second,
    Alloy with `INGEST_TOKEN` unset sends no Authorization header at all.
    That was read off a listener, and it is why the in-stack, lab and SOC
    agents needed no change.
  - **Proof the control is on.** `IngestAuthNotEnforced` pages if the
    published address answers a token-less query, or Loki's delete, with
    anything but the proxy's 401.
  - **Proof data is arriving.** `deploy-agent.sh` now requires samples and a
    log line newer than the deploy, and exits non-zero without them, since a
    refused agent stays listed for minutes and looks healthy from its side.

- **The sensitive tier's expiry rules are a pair, in hours**
  ([#426](https://github.com/Gerrrt/HomeLab/issues/426)). #718 had already
  shipped the tier-CA blackbox module, kept `renewal: acme` targets out of the
  30- and 7-day rules and added `TlsAcmeRenewalStalled` (critical, under 36h).
  What the issue still asked for was the warning half and its inhibit.
  `TlsAcmeRenewalLate` warns under 48h, about eight hours after Caddy should
  have renewed at ~56h. Alertmanager inhibits it under the critical rule by
  `name`, the same shape as the days pair, so a stalled renewal pages once.

- **Hicks' pass to `oracle` is narrowed to `80/tcp`**
  ([#251](https://github.com/Gerrrt/HomeLab/issues/251)). It admitted 443
  too, to a port the old wiki container published and nothing answered on;
  `stacks/wiki` publishes 80 alone. Changed in pfSense's UI and exported
  with `make backup-firewall` the same day. The empty anonymous volume the
  old container left is removed, after a set taken from `wiki-db` passed
  `--prove`.

- **The wiki is cut over to `stacks/wiki`**
  ([#251](https://github.com/Gerrrt/HomeLab/issues/251)). A first set was
  taken from the old container and proven by a restore (pages=108 users=4).
  The secret went to `0400`, and the hand-run `wiki` and `db` were replaced
  by the compose stack, which adopted `pgdata`: about a minute of downtime.
  The update companion, the dead node-exporter and `wikinet` are gone. The
  timer's primed run before the cutover was refused, correctly, but it left
  an empty `backups/wiki/` that failed `verify-backups`;
  [#757](https://github.com/Gerrrt/HomeLab/pull/757) takes the lock after
  the preflight so a refused run leaves nothing. The record is in
  `stacks/wiki/README.md`.

- **SMART series are keyed on the port a drive is cabled to, not its letter**
  ([#745](https://github.com/Gerrrt/HomeLab/issues/745),
  [ADR-0066](adr/0066-key-smart-series-on-the-port-not-the-letter.md)).
  - **The collector adds `slot`** to every per-device series. It is the
    drive's `/dev/disk/by-path` name, and the device label where there is
    none.
  - **The baseline is keyed on it.** `smaug`'s row is
    `pci-0000:00:17.0-ata-6`, the S3520's port. `SmartDriveBadSectors` joins
    `on(host, slot)`, and a series from an older collector uses its `device`
    as the slot, so `oracle`'s row still names `/dev/sda`.
  - **A second bug went with it.** `SmartDriveBadSectorsGrowing` matched a
    series to itself a week back by letter, so a drive with 4 sectors landing
    on a letter that had held 0 would have read as growth. It had not fired
    yet.

- **Navidrome is deployed on `smaug`**
  ([#141](https://github.com/Gerrrt/HomeLab/issues/141), closing;
  [`build-the-nas.md`](runbooks/build-the-nas.md) §6.6).
  - **It had run since 2026-09-23.** Its admin, `gerrrt`, was made from the
    web form that evening. The `pending` row pulled `navidrome-data` into
    every NAS set from `20260926T034052Z` on. The Done block records it and
    names the cause: a bare `up -d` starts every service whose directories
    exist.
  - **The 4533 pass is proven from Hicks**, eight days after it was made.
    `/ping` answered a workstation, and a Subsonic app on a phone played a
    track: a generated test tone, because the library holds no music yet.
    The monitoring host is still refused.
  - **One admin.** A second one made from the shell was deleted.
    `POST /auth/createAdmin` with no body answers 422, not 403, so
    `navidrome user list` is the check.
  - **Backed up and required.** The set `20260930T131627Z` holds all three
    media archives and verified on `atropos`. `navidrome-data` is now
    `required` in `backup-nas.sh`.
  - **The `igc0.40` tripwire still reads zero.**
- **`SmartDriveBadSectors` fired for `smaug` on the boot SSD's recorded
  four**, the letter-drift [#745](https://github.com/Gerrrt/HomeLab/issues/745)
  describes. The TrueNAS middleware placed the S3520 on `sdb` and the Exos
  on `sda` and `sdc`, with `erebor` ONLINE and no errors. Rerunning the
  collector by hand wrote `sdb` 4 and both Exos 0. On the monitoring host,
  `make smart-state` rendered the baseline as `/dev/sdb` 4. That matches
  the live count, so the rule does not fire. The alert's `device` label was
  not captured, so which side held the stale letter is probable rather than
  proven.
- **The wiki is in the repository, and its database has a backup**
  ([#251](https://github.com/Gerrrt/HomeLab/issues/251),
  [ADR-0065](adr/0065-pull-the-wikis-database-to-prometheus-as-a-dump.md)).
  Reading `oracle` first changed the size of the problem:
  - The anonymous volume ADR-0015 named was **empty**. `/wiki/data/content`
    has held nothing since the image was built.
  - Everything the wiki knows beyond its pages is in an 18 MB Postgres:
    108 pages, 780 revisions and 4 users.
  - The running images were Wiki.js 2.5.314 and Postgres 17.6, pulled by
    the `2` and `17` tags. Both tags have since moved to other digests.

  `stacks/wiki` pins exactly those digests, hardened. It was rehearsed on
  `oracle` against a scratch restore of the live database: the bootstrap
  of an empty cluster, the restore, a read-only boot and a page render. The
  update companion, which held the Docker socket and recreated the wiki from
  a floating tag, is not carried over. `scripts/backup-wiki.sh` pulls a
  `pg_dump` to `prometheus` nightly, the first dump in the repository. The
  cutover on `oracle` is next, recorded in the stack's README.

- **`backup-library`'s first timed run failed, and the unit is fixed**
  ([#132](https://github.com/Gerrrt/HomeLab/issues/132),
  [ADR-0064](adr/0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)).
  The timer was installed at 02:25 UTC, and the primed run exited 2 because
  tar could not `stat` `./thumbs/.immich`: "Function not implemented". The
  cause was `RestrictSUIDSGID=`, copied from `backup-sensitive`'s unit. Its
  seccomp filter returns ENOSYS to the host tar's `stat` of a plain-file
  operand, while directory operands pass. It was confirmed by
  `systemd-run` with each property alone. `backup-sensitive` never met it
  because its tar runs in a container. With the property removed, the script
  wrote a set under the rest of the unit's sandbox. The incomplete set the
  failed run left had no `MANIFEST`, and it was removed by hand.
- **`WAN_DHCP6` is monitored at an address that answers.**
  `GatewayMonitorUnreliable` on `morpheus` stopped at the cause, not at a
  silence. It had fired since 2026-09-07.
  - **The cause.** `dpinger` pinged Comcast's link-local gateway, which
    never answers ICMPv6 echo, so pfSense called a working uplink down.
  - **The fix.** In pfSense, the gateway's Monitor IP was set to
    `2606:4700:4700::1111`, the same anycast address
    `collect-gateway-state.sh` probes v6 with.
  - **The reading.** `make gateway-state` read
    `homelab_gateway_status{gateway="WAN_DHCP6"} 1`, a delay of 0.0144 s,
    and `homelab_gateway_forwarding{family="inet6"} 1`.
  - **The docs.** `security.md` now describes the monitor as fixed.

## 2026-09-29

- **Audiobookshelf is deployed on `smaug`**
  ([#140](https://github.com/Gerrrt/HomeLab/issues/140), closing;
  [ADR-0050](adr/0050-add-audiobookshelf-to-the-media-tier-behind-a-fifth-hicks-pass.md);
  [`build-the-nas.md`](runbooks/build-the-nas.md) §6.5).
  - **Brought up before the 03:00 snapshot**, so
    `erebor/apps@auto-2026-09-29_03-00` was the first to hold
    `audiobookshelf/` and the backup check ran the same day.
  - **The 13378 pass is live**, the seventh to smaug. A Hicks workstation
    read `/status` as `2.36.1`, the pinned tag, with `root` already created.
  - **Progress follows the listener:** a second device, signed in as the
    same user, resumed where the first stopped. That is the property the
    issue was opened for.
  - **Backed up and required.** `frodo` read the directory out of the
    snapshot, the set listed both `jellyfin-config` and
    `audiobookshelf-state`, and `verify-backups` passed. The archive is now
    `required` in `backup-nas.sh`. The set stamp was not recorded.
  - **The `igc0.40` tripwire still reads zero.**
  - **Navidrome answers on 4533 too**, brought up by the same `up`. §6.6
    still records it as not deployed, and its admin step is the one to check
    ([#141](https://github.com/Gerrrt/HomeLab/issues/141)).

- **Immich's library has a copy off its disk: nightly to `oracle`, off-host
  and not off-estate**
  ([#132](https://github.com/Gerrrt/HomeLab/issues/132),
  [ADR-0064](adr/0064-copy-immichs-library-to-oracle-until-the-off-estate-copy-exists.md)).
  This corrects "the USB disk is the only copy of the originals" in the
  rehearsal entry below, and closes nothing in
  [#455](https://github.com/Gerrrt/HomeLab/issues/455).
  - **What was built.** `scripts/backup-library.sh` (`make backup-library`,
    timer `homelab-backup-library`, 05:15) writes one age archive of
    `upload/`, `library/`, `profile/` and Immich's own dumps. It sources
    `backup-volumes.sh` for `verify()` and the copy to `oracle`, as
    `backup-nas.sh` does, and stops nothing. Two sets are kept on each side.
    A `df` preflight refuses a set that would leave oracle's root LV with less
    than 15 GiB, and that refusal is ADR-0064's expiry.
  - **First run.** Set `20260929T232136Z`: 615 originals, 1.5 GB. It was
    written in 68 s and copied and hash-checked on `oracle` in about three
    minutes. `ARGS=--prove` streamed it against the live database and read
    `ok=615 bad=0`.
  - **Restored from `oracle`.** The set was pulled back, checked against its
    `MANIFEST` sha256 and unpacked into a tmpfs. Its own 02:00 dump restored
    into a scratch `immich-db` before the server started, and v3.2.4 came up
    initialised and onboarded with `ok=615 bad=0`. Thumbnails and transcodes
    regenerated from *Jobs* with *All*, not *Missing*.
  - **Found on the way.** A schema-drift warning in the first minute was the
    geodata import mid-flight, and `schema-check` then read clean. 121 of the
    615 assets are in Immich's trash, which the thumbnail job skips.
  - **Not yet:** the timer is not installed (`make install-timers
    PROFILE=sensitive`). Every set is encrypted to `trinity`'s key alone.
    ADR-0023's copy is still #455's.
- **`smaug` has 32 GB**
  ([#599](https://github.com/Gerrrt/HomeLab/issues/599), closing).
  - **The fit.** The three Samsung `M391A1G43EB1-CPB` went into the empty
    slots in a shutdown of their own, after the disk swap's scrub (below).
  - **What it read.** POST reported 32768 MB at 2133 MHz. `dmidecode`
    shows four matched modules, *Single-bit ECC*, all configured at 2133
    MT/s. EDAC reads 0 corrected and 0 uncorrected. The exporter reports
    33,379,954,688 bytes. The pool stayed healthy throughout.
  - **Two findings from the same boot, each with an issue of its own.**
    - **The drive letters moved again with no disk changed**
      ([#745](https://github.com/Gerrrt/HomeLab/issues/745)). The boot SSD
      went from `sdc` to `sdb` and `ZVTBS4NL` from `sdb` to `sdc`. So on
      the chipset a `/dev/sdX` is not a stable name, and the SMART baseline
      row keyed on one goes stale at a reboot. The row moved to `/dev/sdb`
      in the same PR, before the next daily collector run could page on
      it. This also supports, without proving, the reading given below for
      the afternoon's `SmartDriveBadSectors`.
    - **A clean shutdown counts as unsafe on the S3520**
      ([#746](https://github.com/Gerrrt/HomeLab/issues/746)). Its counter went
      522 → 523 across one *System → Shut Down*. So
      `SmartDriveUnsafeShutdownsGrowing`'s premise, that a clean stop does
      not move it, is false for `smaug`'s boot disk. The rule would page on
      every planned reboot, including the clean UPS halt ADR-0049 built.
  - **The Compute table reads 32 GB.** The new disk's extended self-test
    (about 28 hours) starts on the final hardware, after this.

- **`erebor` is a whole mirror again, and the MegaRAID is out**
  ([#558](https://github.com/Gerrrt/HomeLab/issues/558) and
  [#571](https://github.com/Gerrrt/HomeLab/issues/571), both closing;
  [ADR-0052](adr/0052-cable-smaugs-pool-to-the-chipset-and-take-the-megaraid-out.md);
  [`replace-the-nas-disk.md`](runbooks/replace-the-nas-disk.md) steps 5
  and 6).
  - **The replacement is `ZVTLQEZ7`**, the refurbished Exos X20 bought on
    2026-09-24 after the return came back as a refund. It runs firmware
    `SN06`. Seagate's lookup says *contact the place of purchase*, so the
    warranty is eBay's. FARM read **0 power-on, spindle and head-flight
    hours**, with 0 on every error count across all 20 heads, before the
    drive was used.
  - **The chipset move first.** `ZVTBS4NL` went onto a chipset port on a
    new SATA cable, and the card came out with its breakout. The pool
    imported `DEGRADED` exactly as it had been on the card, so the fallback
    was not needed. The Exos are on `ata1` and `ata2` at 6.0 Gbps.
  - **Resilver and scrub.** The Replace (the UI button is *Manage VDEVs*,
    not the *Manage Devices* the runbook said) resilvered 1.99 GiB in 23 s,
    finishing at 13:52 PDT. The scrub repaired 0 B with 0 errors at 13:56.
    The pool holds 1.91 GiB, which is why both took seconds.
  - **Step 6 read true.** The exporter reports the pool online. No silence
    is left. The five NAS backup sets are complete on the monitoring host
    and on `oracle`, and the timer is installed.
  - **One alert the runbook did not predict.** `SmartDriveBadSectors`
    fired for `/dev/sdb` about 30 minutes after the boot, while the live
    `sdb` read 0 on every count. The textfile the exporter served had been
    written by the 08:30 cron under the pre-swap letters. Rewriting it by
    hand cleared the alert, and step 5 now says to do that at every swap.
    Which series in the old file tripped the rule was not captured, so that
    part is probable rather than proven.
  - **The optical drive went back in** on `ata5`, for burning discs.
  - **Still to read:** the new disk's extended self-test, about 28 hours,
    whose result goes in `hardware.md`.

- **Actual is deployed on `trinity`**
  ([#142](https://github.com/Gerrrt/HomeLab/issues/142), closed;
  [ADR-0062](adr/0062-add-actual-to-the-sensitive-tier.md)). This corrects the
  "not deployed" entry below.
  - **Not by `make up`.** It was brought up on its own, and did not touch the
    rest of the stack: first `scripts/seed-actual-password.sh`, then
    `docker compose up -d --no-deps actual`. The running Caddy already had
    the site and the alias, from the Stirling-PDF `make up` earlier the same
    day, so it was not recreated.
  - **It was never reachable unclaimed.** The seed claimed the empty
    `actual-data` volume with `--network none` before the service first
    started, and reported "claimed with the SOPS password before first
    start". After the start, `--check` reported that the SOPS password logs
    in.
  - **Through Caddy**, as a phone on Hicks reaches it:
    `https://actual.matrix.elysium` answers 200, and the leaf verifies against
    the tier root. `/account/needs-bootstrap` reports it claimed, with
    password login only. Caddy's log shows the certificate was obtained.
  - **The `actual` host override on `morpheus`** was added the same day. It
    resolves to `10.0.99.40`.
  - **Not yet:** a nightly set with `actual-data` in it, and a real budget,
    which waits on [#404](https://github.com/Gerrrt/HomeLab/issues/404)
    step 10 like the rest of the tier.
- **linkding and Mealie are deployed on `trinity`**
  ([#144](https://github.com/Gerrrt/HomeLab/issues/144),
  [#146](https://github.com/Gerrrt/HomeLab/issues/146)). This corrects their
  entries below that say they are not yet deployed. Both sessions that
  authored them had ended, so the deploy was run once from the Stirling-PDF
  session, after linkding's sentinel fix
  ([#738](https://github.com/Gerrrt/HomeLab/pull/738)) had merged.
  - **A dry run first.** `docker compose up -d --remove-orphans --dry-run`
    listed only the two containers and their two volumes as new. Nothing
    running was recreated, Caddy included. `make up STACK=sensitive` then
    passed its own checks: `check_container_health.py` reported all twenty
    services with a healthcheck healthy.
  - **Through Caddy.** step-ca issued the leaves for `links.matrix.elysium`
    and `recipes.matrix.elysium`, and both verify against the tier's root.
    linkding answers with the 302 to its login page, and Mealie answers 200.
  - **The backup loads.** `backup-volumes.sh --inventory` lists
    `linkding-data` and `mealie-data` with no sentinel refusal.
  - **Mealie's public default admin was live until it was changed.**
    `changeme@example.com` / `MyPassword` logged in (200) from the moment
    the container started. It was renamed and re-passworded minutes later,
    and the default login then answered 401. Self sign-up refuses a
    well-formed request with 403, *"User Registration is Disabled"*. A
    Mealie deploy should change that login before anything else. The window
    was minutes, and on Hicks only.
  - **linkding's first login** with the SOPS superuser password is the
    operator's, and is not recorded here.

- **The sensitive backup would have stopped before archiving anything,
  from the first run after linkding merged**
  ([#144](https://github.com/Gerrrt/HomeLab/issues/144)).
  - **Cause.** #731 gave `linkding-data` the sentinel `./db.sqlite3`, which is
    `vaultwarden-data`'s, and `load_inventory()` refuses a table where two
    volumes share one. That is the same failure #734 fixed for Miniflux the
    same day.
  - **Why it was not fixed the same way.** Miniflux's fix, a nested cluster
    directory, is not open to linkding: its application lives in
    `/etc/linkding`, so the volume can only be mounted at `data/`.
  - **The fix.** Linkding's sentinel is now `./secretkey.txt`, and
    `./db.sqlite3` moves to its companions: #468's soft-hit rule, as
    `loki-data` and `paperless-data` share `./index`.
  - **Measured on the pinned 1.47.0 image:** `secretkey.txt` exists before
    the first healthy check and was unchanged after a restart and a clean
    stop. No volume on `trinity` has one at its top level.
  - **Proved with `verify()` on synthetic archives:** each archive verifies
    under its own name, and each is refused under the other's.
  - **Timing.** It was caught about twelve hours before the first 04:30 run
    that would have hit it, on the checkout the timer runs from.

- **Miniflux and Memos are deployed on `trinity`**
  ([#147](https://github.com/Gerrrt/HomeLab/issues/147),
  [#145](https://github.com/Gerrrt/HomeLab/issues/145)). This corrects the
  two entries below that say "not yet deployed". One `make up` brought both
  up, and all sixteen containers reported healthy. Both names answer 200
  through Caddy on leaves from the tier's CA.
  - **The first attempt stopped at the backup, not the deploy.** The two
    Postgres volumes, Miniflux's and Paperless's, shared the sentinel
    `./18/docker/PG_VERSION`, and `backup-volumes.sh` refused the whole run.
    [#734](https://github.com/Gerrrt/HomeLab/pull/734) gave Miniflux's
    cluster `PGDATA=.../18/miniflux` before its volume existed, so nothing
    moved.
  - **Memos took ADR-0059, not 0057 or 0058.** Miniflux and HomeBox's decline
    merged first. Parallel Tier extras branches each numbered their ADR from
    the same main.
  - **Both host overrides are in**, and both names resolve to `10.0.99.40`.
    **Still open for Memos:** closing registration at first login. Neither
    service holds real data yet.
- **Stirling-PDF is deployed on `trinity`**
  ([#143](https://github.com/Gerrrt/HomeLab/issues/143),
  [ADR-0063](adr/0063-add-stirling-pdf-to-the-sensitive-tier-and-keep-its-documents-in-memory.md)). Only `stirling-pdf` and `caddy` were brought up
  (`docker compose up -d --no-deps`), after `make render`, so the extras
  authored beside it and not yet deployed stayed down. Caddy was recreated
  for the new alias and site block, which took the tier's HTTPS away for a
  few seconds.
  - **Healthy in 42 s**, both containers. `check_mounted_config.py`,
    `reload-config.sh` and `check_container_health.py` passed for everything
    running. The three failures were Actual, linkding and Mealie, which are
    authored and have never been started.
  - **`stirling-pdf/smoke.sh` passed against the live container.** It
    logged in as the admin seeded from SOPS, inside the container, so the
    password never left it, and merged two pages through pdfium. The log
    showed *"LibreOffice sandbox active (lo-sandbox: landlock ABI 8, seccomp
    active)"* and no `UnsatisfiedLinkError`, and no job file was left in
    `/tmp/stirling-pdf` afterwards.
  - **Through Caddy, with the tier's root:**
    - step-ca issued the leaf for `DNS:pdf.matrix.elysium` over tls-alpn-01
      and it verified;
    - `/api/v1/info/status` answered 200;
    - a tool called without a session answered 401;
    - a 300 MB upload was refused with 413 at the 256 MB cap.
  - **786 MiB** at rest, under the 3 GiB limit.
  - **The `pdf` host override was added on `morpheus` the same day.** Through
    it, `pdf.matrix.elysium` resolves to `10.0.99.40` and answers 200 on a
    leaf that verifies against the tier's root.
  - **TOTP is enrolled on the admin**, at first login from Hicks, before any
    real document. Stirling logged the forced enrolment as satisfied
    (`Set MFA required=false for user admin`). That is ADR-0022's floor, and
    the last step of #143.

- **`oracle`'s cell is replaced, and #531 closes**
  ([#531](https://github.com/Gerrrt/HomeLab/issues/531),
  [`replace-the-laptop-cell.md`](runbooks/replace-the-laptop-cell.md#reusing-this-page-on-oracle)).
  The Dell M5Y1K went in at 16:24 UTC, a latch swap with the machine off for
  two and a half minutes.
  - **The serial proves it.** `SMP-Sanyo2` / `DELL VN3N047` / `1650` became
    `LGC-LGC2.8` / `DELL 7PY0D` / `88`, and the label reads M5Y1K. The old
    pack went for recycling the same day.
  - **The clock survived**, which is the datum
    [#519](https://github.com/Gerrrt/HomeLab/issues/519) was short of. The
    coin cell is separate on this machine, and the new boot opened at the
    true time.
  - **The silence was expired by hand at about 17:00**, half an hour after
    the alert had already stopped. That is late again, as on the two battery
    runbooks before it, and harmless only because the new pack read `1`
    from its first scrape.
  - **The mains pull ran at 17:08.** `HostOnBattery` fired for `oracle`
    alone and reached the phone at 17:11. It drew 0.54 Ah/h, about 5.2 hours
    from full. It ran 35 minutes against a 20-minute bound, because the call
    to plug back in was missed.
  - **Step 2 was skipped on this laptop too**, and `charge_full` reads
    exactly its design figure, not yet a learned one.

- **Actual is decided and authored for the sensitive tier, not deployed**
  ([#142](https://github.com/Gerrrt/HomeLab/issues/142),
  [ADR-0062](adr/0062-add-actual-to-the-sensitive-tier.md)). It is the fifth
  service beyond ADR-0008's nine, after Miniflux, Memos, Mealie and linkding.
  It was chosen over Firefly III because it is one container on SQLite and
  keeps working when the server is down.
  - **The pinned image has no password setting.** A fresh server is claimed
    by whoever sets the first password. `scripts/seed-actual-password.sh`
    claims it from SOPS inside the pinned image with `--network none`, before
    its first start, and `make up` runs it every time. It was proved against a
    throwaway volume: fresh, already claimed, a live check, and a wrong
    password.
  - **Every device shares one session, and a password change does not end
    it.** Measured on 26.9.0, the token issued before a change validated
    after it. The stack README has the sign-out, which was proved the same
    way.
  - **Measured on 26.9.0-alpine:**
    - It runs as the image's own uid 1001, read-only, with no capabilities,
      and writes nothing outside `/data`.
    - It boots with no network.
    - 279 MiB idle and 329 MiB at peak.
    - Five failed logins per client per fifteen minutes.
  - **Booted from `compose.yaml` itself** on `trinity`, on an internal
    network with a spare subnet, because the live stack holds the fixed one:
    healthy, read-only, all capabilities dropped, as 1001. CI's hardened boot
    runs it on the real subnet.
  - **Not done:** the deploy and a restore.

- **linkding is decided and authored for the sensitive tier; it is not
  deployed** ([#144](https://github.com/Gerrrt/HomeLab/issues/144),
  [ADR-0061](adr/0061-add-linkding-to-the-sensitive-tier-behind-one-factor.md)).
  It is the fourth service beyond ADR-0008's nine, after Miniflux, Memos and Mealie. It is behind
  one factor because linkding has no other, and it is named in `security.md`
  with Immich, AdGuard Home, Miniflux, Memos and Mealie.
  - **Hardening needs four capabilities.** Measured on the pinned 1.47.0
    image: the bootstrap needs root with `CHOWN`, `DAC_OVERRIDE`, `SETUID` and
    `SETGID`, and every process that serves runs as uid 33 with no
    capabilities.
  - **The second boot is the one that finds `DAC_OVERRIDE`.** Without it,
    `migrate` failed with "attempt to write a readonly database" and the
    container still reported healthy.
  - **Memory:** 77 MiB idle, and 188 MiB peak importing 3,000 bookmarks.
  - **Background tasks are off**, so no third party is asked for a favicon for
    each bookmarked site.
  - **The `links` host override is on `morpheus`**, added the same day as an
    additional name on `trinity`, ahead of the deploy. It resolves to
    `10.0.99.40`, and the reverse entry is still `trinity`. HTTPS to it fails
    at the handshake until `make up` gives Caddy the site.
- **HomeBox is declined**
  ([#148](https://github.com/Gerrrt/HomeLab/issues/148), closed). Every job
  it was filed for already had a home: serials and warranty dates in
  `hardware.md`, receipts and manuals in Paperless-ngx, licence keys in
  Vaultwarden. The one thing left was a list of household objects, and that
  does not earn a place on Winterfell.
  [ADR-0058](adr/0058-decline-homebox-because-hardware-md-and-paperless-already-hold-its-records.md)
  records the reasoning and what would reopen it.

- **Miniflux is authored for the sensitive tier, the first service beyond
  ADR-0008's nine**
  ([#147](https://github.com/Gerrrt/HomeLab/issues/147),
  [ADR-0057](adr/0057-add-miniflux-to-the-sensitive-tier-with-its-fetcher-kept-off-winterfell.md)).
  It is authored and validated here, and not yet deployed on `trinity`.
  - **Measured on the pinned image first.** It runs as 65534, read-only with
    no tmpfs, at 13 MiB idle.
  - **The fetcher refused `miniflux-db` by name and `localhost`** as private
    addresses, which is the property that makes a URL-fetching service
    tolerable on Winterfell.
  - **The REST API answered 200 to the admin's password over basic auth**, so
    it is off.
  - **There is no TOTP, and its passkeys are not a second step.** Miniflux
    is named beside Immich and AdGuard as single-factor.
- **Mealie is decided and authored for the sensitive tier, as
  `recipes.matrix.elysium`** ([#146](https://github.com/Gerrrt/HomeLab/issues/146),
  [ADR-0060](adr/0060-add-mealie-to-the-sensitive-tier-as-recipes.md)). It is
  another *Tier extra*, beside Miniflux. It was measured on the pinned image
  before the file was written.
  - `/app/data` is root's. `PUID=0` turns the entrypoint's chown and gosu into
    a no-op, so it runs as capless root, read-only, in Vaultwarden's shape.
    Nothing was written outside the volume.
  - SQLite in rollback-journal mode, with its signing secrets generated into
    the volume, so there is no SOPS secret.
  - With sign-up off, `/api/users/register` answers `403`.
  - It uses 224 MiB idle and 396 MiB at the peak of three URL imports, under
    a ceiling of 1024m.
  - There is no second factor in the code. It is named beside Immich and
    AdGuard.
  - The bundled `change_password.py` reset the admin on a running container.
    The old password then answered `401`.
  - **URL import does not fetch inward.** A recipe page served on the same
    network, by name and by address, and `127.0.0.1`, `10.0.99.1`,
    `10.0.99.20:9090` and `169.254.169.254` each failed with
    `InvalidDomainError`, and none of those requests arrived. With the host on
    `HTTP_ALLOW_LIST`, the same page imported. The list is written out empty.

  The issue's "existing 50→99 rule" is, since ADR-0031, the Hicks pass to
  `10.0.99.40:443`. A new name behind it needs no new rule. Not deployed: the
  host override, `make up` and the first login are the build runbook's new
  *Deploy a later service*.
- **Stirling-PDF is decided and authored for the sensitive tier, not yet
  deployed** ([#143](https://github.com/Gerrrt/HomeLab/issues/143),
  [ADR-0063](adr/0063-add-stirling-pdf-to-the-sensitive-tier-and-keep-its-documents-in-memory.md)). It is the sixth service beyond ADR-0008's nine, after Miniflux, Memos, Mealie, linkding and Actual. The
  pinned image (`3.0.0`) was booted on `trinity` beside the live stack, on an
  internal network of its own, read-only, as uid 1001, with every capability
  dropped. It ran OCR, conversion, merge, rotate, split and compress, and three
  things were found by running it:
  - **The entrypoint dies on a read-only root.** It `ln -s`es diagnostics
    shortcuts into `/usr/local/bin` under `set -e`. `/dev/null` mounted over
    the script it links makes it skip that step.
  - **A `noexec` `/tmp` breaks every pdfium tool while the container stays
    healthy.** The PDF engine unpacks its libraries there, and merge answered
    500 with *failed to map segment from shared object*. So that tmpfs is
    `exec`.
  - **The image writes a heap dump to `/configs` on OOM**, and a dump would
    hold the document. It is turned off.

  Memory: 790 MiB idle and 1.4 GiB at peak through a 40-page 300 dpi OCR,
  under a 3 GiB limit that also holds the 1 GiB of document tmpfs.

- **Memos is the second *Tier extras* service decided, and authored**
  ([#145](https://github.com/Gerrrt/HomeLab/issues/145),
  [ADR-0059](adr/0059-add-memos-to-the-sensitive-tier-for-notes-and-keep-documentation-in-docs.md)).
  It is notes, not documentation: `docs/` stays the record, and #124 is not
  answered by it. Measured on the pinned image, read-only with every
  capability dropped: it runs as its own `10001` with no root step, idles at
  15 MiB, and needs no secret. Two things differ from what #145 assumed:
  - **It is not one file.** Attachments are written under `./assets`, and
    while it runs the database's writes sit in `memos_prod.db-wal` (a clean
    stop checkpoints them). The backup names all three.
  - **Sign-up cannot be closed from compose.** It is a setting in the
    database, so the first login has to close it.

  Not yet deployed on `trinity`.

- **`prometheus`'s disk was two to three days from full, and is not now.**
  `HostDiskCritical` had been firing since 27 Sep: 5.3 GiB free on `/`, having
  lost 28.5 GiB since 15 Sep in steps of 1–5 GiB.
  - **Half the SSD was never in use.** `/` was Ubuntu's guided-LVM default,
    a 100 GiB logical volume on a 230.7 GiB volume group. It was grown online
    with `lvextend -r -l +100%FREE`: 226.5 GiB, 128.7 GiB free. The lab guest's
    build runbook already carried this step, and the monitoring host never
    got it.
  - **Images were most of the growth.** 91 images, 47.8 GB, 42.6 GB
    reclaimable, because nothing ever removed a superseded digest and
    `make validate` pulls every stack's pinned images. A weekly
    `prune-images` job now does, Mondays 04:00, under the `backups` lock.
  - **`/home` holds 24 GiB**, not yet broken down. The backup sets are the
    suspect, and are capped at seven.

- **The alert path runs through the in-house ntfy, and has been seen failing
  over** ([#136](https://github.com/Gerrrt/HomeLab/issues/136), closed).
  The cutover in
  [`verify-the-alert-path.md`](runbooks/verify-the-alert-path.md#cutting-over-to-the-in-house-ntfy)
  was run across both hosts with both phones in hand, and its table has the
  times.
  - **Both halves observed.** A synthetic page arrived in-house over Wi-Fi,
    and on the ntfy.sh copy over mobile data. With ntfy stopped on
    `trinity`, `EndpointUnreachable` paged through ntfy.sh at 03:18, six
    minutes after the stop.
  - **Alerts now read as a title and a line** on both copies, with priority
    taken from severity
    ([#716](https://github.com/Gerrrt/HomeLab/pull/716),
    [#719](https://github.com/Gerrrt/HomeLab/pull/719)). Before that, the
    phones got whole paragraphs, or raw JSON from ntfy.sh.
  - **Three things only the cutover could find.**
    - The tier's seven-day leaves tripped the estate's 7-day expiry rule on
      the first probe
      ([#718](https://github.com/Gerrrt/HomeLab/pull/718)).
    - `make secrets-edit` leaves the deployment checkout dirty, and that
      stopped convergence on `prometheus` for about four hours
      ([#717](https://github.com/Gerrrt/HomeLab/pull/717),
      [#720](https://github.com/Gerrrt/HomeLab/pull/720)).
    - A secrets edit reaches Alertmanager only after `make render`.
  - **Not run:** the runbook's lowered-Watchdog check and the
    `category=security` page. They are recorded as open in the runbook.

## 2026-09-28

- **ntfy is authored for the sensitive tier, and Alertmanager is repointed
  at it** ([#136](https://github.com/Gerrrt/HomeLab/issues/136)). It is not
  deployed, and the issue stays open until the cutover in
  [`verify-the-alert-path.md`](runbooks/verify-the-alert-path.md) has been seen
  working on both phones.
  - **The decision #136 asked for.** The in-house topics replace ntfy.sh for
    all three real channels, and `urgent` and `security` send to their ntfy.sh
    topics as well. A phone away from home cannot reach `trinity`: nothing on
    the tier is exposed, and the WireGuard path goes to the lab. So an
    in-house-only page would wait for Wi-Fi. The heartbeat stays on
    healthchecks.io (#408), and `check_alert_channels.py` now fails a heartbeat
    pointed at any `.matrix.elysium` host.
  - **The auth.** ntfy is deny-all, with two users. `alertmanager` may only
    write the three topics, by token; `phone` may only read them. Users, ACLs
    and the token come from `NTFY_AUTH_*` in the environment, built from SOPS.
    Measured on the pinned image (v2.28.0) under the compose file's hardening:
    - Anonymous requests got 403 either way.
    - The token could publish and got 403 on read.
    - `phone` could read and got 403 on publish.
    - A rotated token and a changed hash each turned the old credential into
      a 401 after a restart.

    That last result is why `ntfy-data` is skipped by the backup rather than
    archived.
  - **Only the iPhone's wake-up leaves the house.** `upstream-base-url` sends
    ntfy.sh the SHA-256 of the topic's URL, read off the image's own log, and
    not the alert.
  - **A dead ntfy still pages.** A blackbox probe verifies the tier's root with
    the new `http_2xx_tier_ca` module. It is written out and enabled at
    cutover. `AlertmanagerNotificationsFailing` and `EndpointUnreachable` are
    critical, so they reach `urgent` and its ntfy.sh copy. `validate.sh` now
    pins the `correctness` route alongside `availability`.
  - **One thing the first boot taught.** ntfy exits at start on a malformed
    bcrypt hash or token. `seed-validation-env.sh`'s `validation-only` would
    have failed the new CI boot, so the ntfy seeds are well formed.
    `check_hardened_boot.sh` could not run on `trinity` itself, because the
    live stack owns the subnet. The same boot was run there under a throwaway
    project with the subnet moved, and it came up healthy.
- **Immich's restore is rehearsed on `trinity`, and the first real photos
  came before the gate that was meant to precede them**
  ([#132](https://github.com/Gerrrt/HomeLab/issues/132)). Two accounts
  uploaded 615 assets at 16:59–17:01 UTC. At that point the off-estate copy
  ([#455](https://github.com/Gerrrt/HomeLab/issues/455)), ADR-0022's record
  and ADR-0023's *Independent* test were all still open, so the USB disk is
  the only copy of the originals. That evening the restore was rehearsed
  against copies of that library, by both routes:
  - **Immich's `pg_dump`** went into a fresh `immich-db`, restored before the
    server first started.
  - **The `immich-db` volume** came out of the new set `20260928T203415Z`,
    which the same run copied to `oracle`.
  - **Result:** on both routes the server came up with no drift and no
    onboarding, and all 615 originals hashed to their database checksum.
  - **Upstream's hard rule is soft on v3.2.2:** a same-version dump restored
    cleanly over a database the server had already initialised. The order is
    kept anyway, because the gap serves *create the first admin* on VLAN 99.
    → [runbook](runbooks/restore-the-sensitive-tier.md#restore-immich)
- **Plex declined** ([#139](https://github.com/Gerrrt/HomeLab/issues/139)).
  ADR-0016's test was run: the LG OLED, a console, and the household's phones
  and tablets all play from Jellyfin, and the Xumo box is not used for the
  library. No screen used for media lacks a Jellyfin client, so the deferral
  becomes a decline,
  [ADR-0056](adr/0056-decline-plex-because-every-screen-on-casabonita-plays-jellyfin.md), and
  ADR-0008's list loses Plex. The media tier stays without secrets, and Plex
  Pass leaves the purchase list.
- **The sensitive tier's backup is on a nightly timer**
  ([#404](https://github.com/Gerrrt/HomeLab/issues/404) step 9, the
  acceptance item on [#131](https://github.com/Gerrrt/HomeLab/issues/131)).
  - **What runs.** `homelab-backup-sensitive` runs `make backup STACK=sensitive`
    on `trinity` at 04:30 every night. Each run already copies the set to
    `oracle` ([#535](https://github.com/Gerrrt/HomeLab/issues/535)), so the
    copy off the host was done. What was missing was anything that took a set
    unless someone typed the command.
  - **Why daily.** The estate's backup is weekly. This one is daily because it
    holds the password vault, and a week of lost vault edits is the wrong
    default.
  - **How it is installed.** It is a second profile of `install-timers.sh`,
    with its own table and its own `systemd/sensitive/` directory.
    - The units carry `@DEPLOY_ROOT@` and `@RUN_USER@`, because the build
      runbook writes `trinity`'s operator as `<you>`.
    - `--check` verifies the rendered units everywhere, CI included.
    - `--check` fails if a job name appears in both tables. The alert rules
      join on the name alone, so a name on two hosts would make every join
      many-to-many.
  - **Alerts.** `ScheduledJobStale` now names `{{ $labels.instance }}` rather
    than "the monitoring host". A promtool case pins the two-host join.
  - **What it does not do.** `oracle` is in the same room, so this is still
    not ADR-0023's copy off the estate. That copy is step 10.

- **`trinity` is built, and the sensitive tier runs on it**
  ([#404](https://github.com/Gerrrt/HomeLab/issues/404)). Ubuntu 26.04.1,
  not the planned 24.04, because the installer stick carried it; it was kept
  on purpose.
  - **Disks.** Both are LUKS2, and the root is enrolled in the TPM against
    PCR 7 ([ADR-0054](adr/0054-encrypt-trinitys-disks-and-seal-the-root-key-to-the-tpm.md)).
    26.04's dracut made that `systemd-cryptenroll` rather than Clevis. Two
    reboots with nobody at the console came back unlocked, the photo disk
    mounted.
  - **Stack.** All twelve containers are healthy on overlay2. Every name
    serves a seven-day leaf from the tier's own CA, minted on `prometheus`;
    its root key never travelled.
  - **The I226 card never left.** #686 recorded it back in the drawer. The
    build found it in the second M.2 slot as `enp1s0`, and it stays there,
    unconfigured.
- **The first start found five things the stack could not show on paper.**
  All are fixed in [#689](https://github.com/Gerrrt/HomeLab/pull/689):
  - Caddy's pinned `172.28.99.2` sat inside Docker's range, and Vaultwarden
    took it first.
  - `reload-config.sh` restarted an Alloy this stack does not run.
  - Home Assistant 2026.9 imports its `http:` YAML once, as a pending config,
    and reverts it unless an admin confirms it within five minutes. Every
    proxied request got a 400 until it was promoted by hand.
  - The backup's 512-byte floor refused Paperless's real, still-empty library.
  - The backup stopped AdGuard, which by then was the house's only DNS
    forwarder.
- **The house forwards DNS to AdGuard alone**
  ([ADR-0055](adr/0055-forward-to-adguard-alone.md)). With the public
  resolvers beside it, as ADR-0010 designed, Unbound spread lookups by RTT
  and 38 of 60 blocked names leaked. With AdGuard alone, 60 of 60 were
  blocked. Blocked names answer `SERVFAIL`, because Unbound's DNSSEC
  validation rejects AdGuard's unproven block answers. `AdGuardNotAnswering`
  is now critical at five minutes.
- **The Hue bridge is `bifrost` at `10.0.20.20`**, reserved below Skids's
  pool, with Home Assistant's one pass into Skids in force. ADR-0035 named
  `.104`, but the bridge had drifted to `.113` and another device held `.104`.
  All four #223 tripwires read 0 after pairing.
- **pfSense's GUI certificate was replaced.** A case-insensitive search of
  `config.xml` printed the old *GUI default* private key into a Claude Code
  transcript. `pfSsh.php playback generateguicert` made a new one, and the old
  one was deleted. The new one expires 2027-04-16; the same command renews it.
- **Hicks reaches `trinity` on 443**, the eleventh named pass above *Block
  access to Winterfell*.
- **Caddy passed its acceptance on `trinity`**
  ([#129](https://github.com/Gerrrt/HomeLab/issues/129)). All six names
  returned `Verify return code: 0` from Hicks against
  `certificates/tier-ca.pem`, each with a seven-day leaf from the tier
  intermediate that Caddy holds under step-ca's ACME directory. Nothing is
  mounted from `gen-certs.sh`. Only Caddy's `443/tcp` and AdGuard's
  `10.0.99.40:53` are published. The host's other listeners are `sshd` on 22
  and loopback-only services: systemd-resolved, chrony, and the Alloy agent's
  `127.0.0.1:12345`.
- **step-ca passed its acceptance on `trinity`**
  ([#130](https://github.com/Gerrrt/HomeLab/issues/130)). Caddy logged
  `certificate obtained successfully` six times, once per name, between
  04:32:18 and 04:32:20 UTC, from `step-ca:9000-acme-acme-directory`. The
  lines came from Loki, because the container log did not survive Caddy's
  16:25 restart. Each leaf runs seven days, 2026-09-28 to 2026-10-05, and
  verifies against `certificates/tier-ca.pem`. The provisioner in `ca.json`
  carries ADR-0037's claims: `tls-alpn-01` only, 168 hours default and
  maximum. The `step-ca-data` volume holds both certificates and the
  intermediate's key, and `root_ca_key` is nowhere on the host. The bundle
  was shredded after `--install`. The tier's root is
  `SHA256 4C:C3:06:81:…:56:5E`. The expiry rule for seven-day leaves is still
  [#426](https://github.com/Gerrrt/HomeLab/issues/426).
- **Home Assistant passed its acceptance on `trinity`**
  ([#134](https://github.com/Gerrrt/HomeLab/issues/134)). Container flavour,
  with no USB radio, as ADR-0035 decided. `bifrost`'s reservation, the pass
  and the tripwire read are the `bifrost` bullet above. The leaf and the
  `morpheus` override are the Caddy bullet's: `homeassistant.matrix.elysium`
  is one of its six names. TOTP is enrolled on the one owner account, the only
  account that is not system-generated. No long-lived access token exists, so
  nothing is owed to SOPS. The hardening boot re-runs in CI on every change,
  under #646.
- **Paperless-ngx passed its acceptance on `trinity`**
  ([#133](https://github.com/Gerrrt/HomeLab/issues/133)). The load was
  synthetic, on purpose: five one-page scans and one of 50 pages, all 300 dpi,
  image-only and noised so Tesseract did real work. Each single page took
  about 16 s; the 50 pages took 3 min 54 s. The container's `memory.peak` was
  1716 MiB of its 3072m, with no OOM kill. It used 3.0 cores at the busiest
  minute and was throttled for 0.2 s in all, so `THREADS_PER_WORKER=3` does the
  limiting and `cpus: 4` is only the backstop. Nothing else went unhealthy,
  and Vaultwarden through Caddy never took longer than 19 ms. Both limits
  stand; the one-month `container_memory_rss` re-derivation still applies.
  - **A backup interrupted the first run.** Another session's
    `STACK=sensitive make backup` stopped the tier 90 seconds into the 50
    pages. The file stayed in `consume/` and was consumed from scratch after
    the restart, so the numbers above come from fresh cgroup counters. That
    backup, `20260928T203415Z`, holds the five one-page test documents in its
    `paperless-media` archive.
  - **The test documents were deleted afterwards.** The shell's hard delete
    removed the rows but not the files, so the 18 files under `media/` went
    by hand. The index was rebuilt, and `document_sanity_checker` reports no
    issues.
- **Backup set `20260928T203415Z` was deleted**, correcting the Paperless-ngx
  bullet above that says it holds the five test documents. It is gone from
  `trinity` and from `oracle`. Rewriting its archives would have meant editing
  `paperless-db-data` as well as `paperless-media`, and a backup edited after
  the fact is no longer what was captured. Nothing real went with it:
  `20260928T204939Z` was taken fifteen minutes later, after the cleanup, with
  an empty Paperless library. Before the deletion, its eleven files were
  checked byte-identical on both sides. The three sets left are the same on
  both hosts.

## 2026-09-26

- **Both Windows 11 Pro keys are bought and in use.** They were bought on
  2026-09-25 and activated on `carbuncle` and `siren`. That was the last
  row in the roadmap's buy table, so the table is empty. The one purchase
  left is `ifrit`, later.
  [`architecture.md`](architecture.md) now lists the two endpoints as built
  but not joined. The domain they join is not built yet
  ([#414](https://github.com/Gerrrt/HomeLab/issues/414)).
- **The faulted Exos was refunded, not replaced, so `smaug`'s new drive is a
  purchase.** Return 5329627831 reached the carrier on 2026-09-23. A
  refurbished `ST18000NM003D` from a different seller was bought on
  2026-09-24 for $551.49 all in, and it is in transit
  ([#558](https://github.com/Gerrrt/HomeLab/issues/558)). `erebor` stays one
  disk until it is fitted and resilvered.
- **`smaug`'s memory shipped on 2026-09-25** by FedEx, the same day the
  identity check cleared ([#599](https://github.com/Gerrrt/HomeLab/issues/599)).
- **The off-estate drive is late.** Amazon moved its estimate on 2026-09-22
  and refunded the delivery fee. The delay went to Amazon customer service
  today ([#455](https://github.com/Gerrrt/HomeLab/issues/455)).
- **Unchanged:** `oracle`'s Dell pack (eBay's estimate now reads 2026-09-28)
  and the CRS326's 24HPOW are still in transit.
- **The pfSense installer stick is in hand**, so nothing gates
  [#92](https://github.com/Gerrrt/HomeLab/issues/92)'s rehearsal now.
- **A pass over every issue, open and closed, found three that were closed by
  accident.** Each was closed by a close keyword GitHub matched inside prose
  that said the issue should stay open, and each is reopened:
  [#182](https://github.com/Gerrrt/HomeLab/issues/182) (by #319, "would close
  #182 by accident"), [#251](https://github.com/Gerrrt/HomeLab/issues/251) (by
  #252, "filed rather than fixed: #251") and
  [#571](https://github.com/Gerrrt/HomeLab/issues/571) (by #652, "Closes nothing
  yet… closes #571 with #558"). The ingest ports are still unauthenticated,
  the wiki is still outside the repository, and #571 closes with #558's swap.
  The roadmap had kept #294, #573 and #604 under *Nothing blocks these*
  after they closed on 2026-09-22 and 2026-09-23, and they have been taken
  out. #604 was delivered by #627.

## 2026-09-25

- **The I226 card arrived and is fitted in `trinity`.** It went into the
  second M.2 slot, which was found free on 2026-09-15, so the fit question
  in `hardware.md` is answered. That leaves the installer stick as the only
  thing [#92](https://github.com/Gerrrt/HomeLab/issues/92)'s rehearsal
  waits on. The card's part number and MAC are still unread. Whether the
  card comes up as `igc0` is for the rehearsal to show.
- **`smaug`'s memory has not shipped.** Memory.NET held the 2026-09-22
  order for an identity check. It was answered today, so `hardware.md` no
  longer says the modules are in transit
  ([#599](https://github.com/Gerrrt/HomeLab/issues/599)).

## 2026-09-23

- **[#485](https://github.com/Gerrrt/HomeLab/issues/485): the build runbook
  for `golem`.** `build-the-backup-guest.md` turns ADR-0053 into steps. It
  covers the VM from the PBS ISO; `erebor/pbs` with `atime` on, owned by uid
  34, and an NFSv4 share mapping root to `backup`; the daily snapshot task;
  and the `2049` pass, placed above a VLAN 30 block the repository has never
  named, so §4 reads it off `morpheus` first. Then the mount, guarded by
  `chattr +i` as `odin`'s data disk is; the prune, garbage-collection and
  verify schedules; a token-only PVE user; and encrypted storage on
  `Saruman`, with the key copied into `secrets/lab.sops.yaml` and onto
  paper. The first proof is a one-off backup and restore of `phoenix`,
  because neither guest ADR-0053 protects exists yet. The one missing
  piece, the collector that puts verify results in front of the lab's
  Prometheus, is written as its own change once a real PBS exists, and
  #485 stays open until then.

- **The offsite medium's key could not open two of the three things it
  carried, and the copy proved it green.** Found on the first visit (#573).
  Archives are encrypted to the recipients the secrets file listed when each
  backup ran, and the volume set `20260920T033007Z` predated the medium's
  key, `age19mkg76v0…`. That one was caught and replaced in the sitting. The
  firewall export was worse and was missed: `backup-firewall.sh` passed
  `sops --age` the **first** key of its rule only, and an explicit `--age`
  replaces the rule's list. So every export since the second recipient was
  added on 2026-09-09 opened with `age1yrdu996…` alone. `recipients()` now
  returns every key in the rule, and the script has its first `--self-test`,
  which also asserts the live `.sops.yaml` gives exports more than one key.
  `backup-offsite.sh` now reads who each set and export is encrypted to, from
  the MANIFEST's `recipient` line and the export's own `sops:` block, without
  decrypting anything. It refuses to copy one that any current recipient
  cannot open, names it `NOT held`, and records no proof. `--verify-only`
  fails on such a set on the medium, and a copy run replaces it rather than
  being blocked by it. Seven fixtures cover it. #573's closing comment said
  the export opened with the medium's key. It did not, and that is corrected
  on the issue.

- **[#485](https://github.com/Gerrrt/HomeLab/issues/485): PBS runs on
  `Saruman`, with its datastore on `smaug` over NFS.** ADR-0027's trigger
  had fired, but its sync job needed a second PBS instance, and on TrueNAS
  that means a VM on `smaug`'s 8 GB (#599).
  [ADR-0053](adr/0053-run-pbs-on-saruman-with-its-datastore-on-smaug-over-nfs.md)
  runs one PBS guest, `golem` at `10.0.30.80`. Its only datastore is
  `erebor/pbs` over NFSv4, with `atime` on for garbage collection, and daily
  TrueNAS snapshots kept for fourteen days replace the second instance as
  the copy PBS cannot prune. Backups are encrypted on `Saruman`, and the
  key is kept in `secrets/lab.sops.yaml`. It takes one more CasaBonita
  pass, `10.0.30.80 → 10.0.40.30:2049`. What gets backed up is ADR-0027's
  table, unchanged. ADR-0027 carries a note; the roadmap, `build-the-nas.md`
  and `build-the-soc-guest.md` point at the decision. Nothing is built yet.

- **[#439](https://github.com/Gerrrt/HomeLab/issues/439): Velociraptor gets
  a removal procedure and `odin` gets a data disk, both before `odin`
  exists.** `build-the-soc-guest.md` §13 takes Velociraptor out in the order
  that leaves nothing behind: the clients first, while the server can still
  confirm they stopped checking in, then the server, then the CA's private
  key shredded, so a missed client can never be taken over by a server built
  later. `odin` is now built with a 32 GB OS disk and a 96 GB data disk at
  `/srv/soc-data`, mounted by UUID. The indexer's data and Velociraptor's
  datastore move onto it through bind-backed named volumes in
  `stacks/soc/compose.yaml`. The empty mountpoint is `chattr +i`, so with
  the disk unmounted `make up` fails instead of filling `/`. That failure was
  tried on Docker locally: a bind-backed volume whose directory is missing
  is refused with *no such file or directory*, and nothing is created.

- **[#571](https://github.com/Gerrrt/HomeLab/issues/571): `smaug`'s pool
  moves to the chipset and the MegaRAID comes out, at the swap.** The Exos
  pair has sat behind a 9340-8i in JBOD since the build, and its firmware's
  error path is what `ZVTBSDL3`'s fault ran through. Five of the chipset's
  six SATA ports are free.
  [ADR-0052](adr/0052-cable-smaugs-pool-to-the-chipset-and-take-the-megaraid-out.md)
  decides against IT-mode firmware, which would be a crossflash on the
  pool's only controller with no spare card. The move needs two plain SATA
  cables, since the only tray cable is the card's own mini-SAS breakout.
  `replace-the-nas-disk.md` §5 now moves the surviving drive first, alone,
  with the card and breakout going back in if the pool does not import on
  `ahci`. §6 adds the SMART baseline re-check the new enumeration needs.
  Nothing has moved yet; the pool is still one disk, waiting for a
  replacement.

- **[#574](https://github.com/Gerrrt/HomeLab/issues/574): steps 0 to 4 of
  `shut-down-on-the-ups.md` are built. The shutdown sequence is armed and
  not yet proved.** `morpheus` serves NUT from `mjolnir` over SNMPv3 (`apcc`
  MIB, `OL`, `battery.runtime.low` 480). Four rules narrow the listener to
  `Saruman` and `smaug`, confirmed blocked from `phoenix`. Both subscribers
  are logged in. The tripwires read 0 on every interface. Steps 5 to 7, the
  halt, the pull and the write-up, wait for a window. Running it found six
  errors in the runbook, all corrected there:
  - The card's access list admitted the SNMPv3 user from `10.0.99.20` only,
    so the driver on `10.0.99.1` was ignored until the card got a
    read-only entry for it. That is the new step 1.0, and ADR-0049 has a note.
  - 1.6's readback printed the package's `local-monitor` password: the
    `MONITOR` line carries it without the word "password". Saving the page
    rotated it the same evening, and the command now drops that line.
  - The runbook expected `MODE=netserver`, but pfSense leaves `MODE=none`.
  - `pfctl` prints port 3493 as `nut`, so 2.5 now greps for that.
  - The card already held an 8-minute low-battery duration before step 0.
  - `Saruman` has no `sudo`.

- **[#523](https://github.com/Gerrrt/HomeLab/issues/523): a Hicks
  workstation mounts the media share.** `samwise` exists on `smaug`, and
  `Allow SMB to smaug` (Hicks → `10.0.40.30:445`) was created on `morpheus`.
  A Windows PC on Hicks mounted `\\10.0.40.30\media` as `samwise`. Read
  from `morpheus` afterwards, the pass sits above *Block access to
  CasaBonita* on `igc0.50` and has matched 463 packets. The monitoring host
  is still refused on `445`, and the #223 tripwire on `igc0.40` still reads
  0 packets. Six Hicks and Winterfell passes to `smaug` now exist, so
  Audiobookshelf's `13378` will be the seventh. `network.md`, `security.md`,
  `architecture.md`, `stacks/media/README.md` and `build-the-nas.md` §5 move
  from *specified* to *created*.

- **[#523](https://github.com/Gerrrt/HomeLab/issues/523): workstations
  get the media share, by
  [ADR-0051](adr/0051-let-hicks-workstations-mount-the-media-share-as-a-user-of-their-own.md).**
  Since 2026-09-18 nothing a person sits at could mount `\\10.0.40.30\media`,
  because none of the Hicks passes is `445`. The decision is a Hicks pass,
  `vlan50 net → 10.0.40.30:445`, described `Allow SMB to smaug`, and a second
  SMB user, `samwise`, for workstations. `bilbo` stays the televisions'
  credential, so the two can be revoked separately. A pull from the NAS side
  was rejected, because it would make CasaBonita initiate. Loading over the
  console was rejected because it does not scale. Making `bilbo` read-only
  was deferred as its own ACL change. Only documents changed. The rule and
  the user are `build-the-nas.md` §5's *Workstations* steps, and until those
  are done every document calls the pass specified, not created.

- **[#534](https://github.com/Gerrrt/HomeLab/issues/534): Home Assistant's
  hardened boot is re-proved on every change to it.** It had been proved once,
  on 2026-09-09, against a digest Dependabot has since moved twice. A new CI
  job, `Boot hardened services`, runs `scripts/check_hardened_boot.sh`. The
  script boots the one service from the real `compose.yaml` on a network with
  no route out, waits for its own healthcheck, and reads the hardening back
  from the running container. Removing `read_only` makes it fail, which was
  tried locally on the pinned 2026.9.3 digest; with the hardening in place it
  was healthy in 12 s on a warm image. The proof is cached on the service's
  inputs, as #602 did for `--probe`, so only a change to the service, its
  config or the check pulls the image.

- **Two gaps in #637's sweep of dead copies on the offsite medium.** The
  sweep said it ran under the `backups` lock. The copy does, because the
  Makefile wraps it, but `--prune` runs outside the wrapper and
  `backup-offsite.sh` took no lock of its own. So a prune in a second terminal
  during a copy would have deleted the copy's live `.part` as a leftover.
  `--prune` now takes the same lock file itself.
  The sweep also left one leftover behind: since #612 an export's `.sha256` is
  written before its rename, so a copy that died between the two left a
  sidecar with no export. Retention removes only the sidecars of exports it can
  list, so that file stayed forever. The sweep now removes a sidecar whose
  export is absent. Both have fixtures, and each fixture fails against the
  previous script.

- **[#562](https://github.com/Gerrrt/HomeLab/issues/562): `alexander`'s
  root filesystem now fills its disk, and nobody had grown the disk.** `/`
  was 48 GB on a 100 GiB disk. The installer log from 2026-09-04
  (`curtin-install.log`) shows the disk was already 100 GiB at install, so
  the runbook's `local-lvm:64` was never what ran. Ubuntu's guided LVM layout
  had given `ubuntu-lv` exactly half the volume group. `lvextend -r -l
  +100%FREE` grew it online to 97G. `build-the-lab-guest.md` now records
  100 GiB on `large_data`, gives the `--scsi0` line a rebuild should run, and
  adds an installer step so the next build gets the whole disk.

- **[#529](https://github.com/Gerrrt/HomeLab/issues/529) confirmed on the
  host; this corrects the entry below, which called the attribute-177
  mapping provisional.** With `smart-state` installed on `Saruman`, the
  first `--print` read both SM863a through the P440ar as `/dev/sda:cciss,2`
  and `cciss,3`, and left out the spindles. Both drives report healthy,
  with 0 reallocated and 0 pending sectors, at 30 and 32 °C. Wear is **6 %
  and 4 % used**, taken from `Wear_Leveling_Count`, so the mapping holds and
  `SmartDriveWearHigh` reads these drives. The drives show 66,090 and
  60,443 power-on hours from their previous life. The collector's comment
  and its Smart Array fixture now carry these readings.

- **[#529](https://github.com/Gerrrt/HomeLab/issues/529): `Saruman`'s SSDs
  get wear readings through `hpsa`.** The iLO and the P440ar report no wear
  for the two SM863a drives. `collect-smart-state.sh` now detects a SCSI host
  whose driver is `hpsa`. It probes `smartctl -d cciss,0..15` through the
  first logical drive and keeps only drives reporting no rotation, labelling
  each `/dev/sda:cciss,N`. The spindles stay with the iLO. Samsung's
  `Wear_Leveling_Count` (177) maps to `homelab_smart_percentage_used` from its
  normalised column, so the existing `SmartDriveWearHigh` reads these drives.
  That mapping is provisional until `--print` on `Saruman` shows the
  attribute. Nine new fixtures cover the Smart Array renderer and discovery
  against a fake `/sys`. `schedule-maintenance.md` no longer says `Saruman`
  takes `patch-state` only. Nothing is on the host yet.

- **[#576](https://github.com/Gerrrt/HomeLab/issues/576): the firewall
  collector now reads `policy_in`, and `PveFirewallPolicyAccept` fires on
  it.** #639's collector header named the gap: with `policy_in: ACCEPT` in
  `cluster.fw`, `pve-firewall status` reads `enabled/running`, `host.fw` can
  keep all four rules, and the whole segment still reaches 8006. Nothing
  read that setting. `collect-pve-firewall-state.sh` now writes
  `homelab_pve_firewall_policy_drop` from the `[OPTIONS]` section, treating
  an unset key as Proxmox's default of DROP. The new rule is critical and
  routed to security like `PveFirewallDisabled`. It fires only while the
  firewall is on, so a firewall that is both off and permissive pages once.
  Its ten minutes cover §4's enable-then-flip, so following the runbook does
  not page.

## 2026-09-22

- **[#570](https://github.com/Gerrrt/HomeLab/issues/570): a hung exporter
  on `smaug` is left to `InstanceDown` and a manual restart, and this is now
  written down.** On 2026-09-19, `media-node-exporter` read `healthy` for
  2 h 40 min while `/metrics` never answered. Docker marks health but never
  restarts on it, so a fix that actually recovers the exporter needs a
  sidecar or a root cron on a host ADR-0040 keeps thin. This was accepted
  instead. The healthcheck comment in `stacks/media/compose.yaml` states
  what `healthy` does and does not mean. `replace-the-nas-disk.md` §1 now
  says to restart the container whatever `docker ps` reports. Only comments
  and documents changed; no configuration did.
- **[#612](https://github.com/Gerrrt/HomeLab/issues/612) and
  [#613](https://github.com/Gerrrt/HomeLab/issues/613): a copy that dies
  no longer poisons the medium for later visits.** `backup-offsite.sh`'s
  `copy_export` now writes the `.sha256` sidecar before the `sync`, where it
  used to write it after. This is the order `copy_set` already used, so a
  medium pulled early can no longer hold an export with no proof beside it.
  That export would have failed the next visit's verify and stopped all
  three kinds. `sets_in` no longer counts a `<stamp>.part` holding a
  `MANIFEST` as a set. Before, such a leftover made `verify_medium` refuse
  its name, and every visit after it was refused until someone deleted it by
  hand. Every copy run and `--prune` now removes `.part` leftovers of any
  stamp, before the room check, so dead bytes stop counting against the next
  copy. There are four new self-test fixtures, and all four fail against the
  previous script. The runbook's error table gains a row for `refusing to
  check a set with an unexpected name`.
- **[#616](https://github.com/Gerrrt/HomeLab/issues/616) `check-versions`
  stops failing on a NAS that runs exactly what the documents say.** TrueNAS
  SCALE's `node_os_info` is its Debian base, so `TrueNAS 25.10` was compared
  against `Debian GNU/Linux 12` every week, and `ScheduledJobFailed` fired
  for three days over it. The fix follows #311's pattern for `Saruman`, in
  two halves. First, `check_versions.py` now has a table of appliance
  products (Proxmox VE and TrueNAS) whose only source is `node_os_info`, and
  skips such a host with the remedy named. The job goes green on merge, and
  the skip clears itself. Second, `scripts/collect-truenas-version.sh` reads
  `/etc/version` (`25.10.7`, read off the host) and writes
  `truenas_version_info` from a root cron job in TrueNAS's UI, the way
  ADR-0047 runs SMART there. It is not pulled over `frodo`'s SSH, which is
  the backup's alone. `build-the-nas.md` §6.7 turns it on. Tested against
  the host as it is: a `--print` run on `smaug` read the real file, and a
  mocked series for 25.10 passed both documents while a mocked 26.04 failed
  both.

- **[#141](https://github.com/Gerrrt/HomeLab/issues/141) Navidrome is
  authored into `stacks/media`, and the issue was wrong twice.** It said no
  new firewall rule would be needed; the `50 → 40` it leaned on is two
  port-scoped passes, `443` and `8096`, and the phones Navidrome serves are on
  Hicks — so another pass, `50 → 10.0.40.30:4533`, is written into
  `build-the-nas.md` §0.5. It said nothing about backup; playlists and play
  counts are music's watch history, so `navidrome-data` joins the archive
  table #140 gave `backup-nas.sh` below, `pending` beside Audiobookshelf's.
  This was written in parallel with #140 and merged after it: both had
  rewritten the pull for more than one archive, and #140's table — with its
  `pending` state, which this one lacked — is the one kept.

  **The pinned image decided three lines.** It has no `/cache`, and a named
  volume mounted there as root kills the process a second after it reports
  ready, so the cache is a `65534`-owned tmpfs. Plugins are off, which keeps
  a `0700` directory out of what the backup user reads. And an admin made
  with `navidrome user create --admin` from the TrueNAS shell closes the web
  form that would otherwise hand the admin to the first visitor — so the
  stack still has no secrets file (#528). Not deployed: the mirror is one
  disk until [#558](https://github.com/Gerrrt/HomeLab/issues/558). The 4533
  pass was created the same day, ahead of it and of Audiobookshelf's 13378,
  so it is the fifth that exists and 13378 will be the sixth; it was read in
  position from `morpheus` with the `igc0.40` tripwire still at zero.

- **[#266](https://github.com/Gerrrt/HomeLab/issues/266) `odin` goes on
  `large_data`, before anyone runs its runbook.** `build-the-soc-guest.md`
  was written before [#527](https://github.com/Gerrrt/HomeLab/issues/527)
  and still created the guest on `local-lvm` — "the same spindles as
  everything else" — while the heaviest writer ADR-0007 names would have been
  the only guest left on them. §1 now creates it on the SSD pool with
  `ssd=1`, rewritten in place because the page has never been run, and
  installs `qemu-guest-agent`, which `alexander`'s build found missing on
  2026-09-20. ADR-0030 gets a dated note: its `refresh_interval` row was
  priced on ~90 IOPS, the pool measured 7,952, and `30s` stays on the
  segment-churn half of the argument. Nothing in `stacks/soc` changes. #266
  still closes on the six agents, behind
  [#414](https://github.com/Gerrrt/HomeLab/issues/414).

- **[#140](https://github.com/Gerrrt/HomeLab/issues/140) Audiobookshelf is
  authored for `stacks/media`, and the issue's one-line firewall claim was
  wrong.** It said no rule beyond #138's 50→40 would be needed; there is no
  such rule, only `443` and `8096` passes, one per port, and the phones are on
  Hicks. So the service brings a fifth pass, `Allow 13378 to smaug`, created
  when it is deployed rather than now.
  [ADR-0050](adr/0050-add-audiobookshelf-to-the-media-tier-behind-a-fifth-hicks-pass.md)
  records that, and records audiobooks only, with podcasts deferred behind a
  read-only library mount. It also records that `scripts/backup-nas.sh`
  pulls a table of archives, not one path, all from one snapshot. Without
  that, the database holding every listener's position would have been
  snapshotted nightly and never left the NAS.

  **Measured on the pinned image before a line was written.** It binds port
  80 by default, which a capability-less non-root process cannot. `/config`
  and `/metadata` don't exist in the image. Its entrypoint is `tini`. The
  database is in rollback-journal mode, not WAL. Idle RSS is 91 MiB. The
  admin reset was proved on a scratch boot rather than described from
  upstream: clear `root`'s hash, sign in blank, and the old password is
  refused.

  **The pull learned to wait for a deploy.** The mirror is degraded (#558),
  and the deploy waits on it. A pull that demanded Audiobookshelf's directory
  would therefore have failed every Saturday's Jellyfin set until then. The
  row is `pending`: skipped by name while its directory is absent, pulled
  strictly once it is present, and flipped to `required` by §6.5's Done
  commit. Verification now reads each set against its own MANIFEST, so the
  two retained Jellyfin-only sets still verify. Both were re-verified with
  the new script, and a bench pull against a fake snapshot tree on `oracle`
  covered all three branches: skipped, refused for a missing sentinel with no
  MANIFEST, and two archives verified.

- **[#455](https://github.com/Gerrrt/HomeLab/issues/455) The off-estate drive
  is bought, and buying it settles less than the row implied.** A WD Elements
  Portable 5 TB, `WDBU6Y0050BBK-WESN`, bus-powered USB 3.2 Gen 1. The second
  row leaves the buy table the same day as the first; README's count goes to
  one. 5 TB against a 2 TB source — Immich's originals plus Paperless's
  documents — so capacity is answered outright rather than sized to today.

  **It was chosen for what it does not have.** ADR-0023 requires the copy be
  encrypted with a key that is *not* the one only the operator holds, and a
  drive's own password is a single-holder secret behind a vendor utility —
  the estate's failure mode moved one shelf away, which is the thing that ADR
  was written about. So vendor encryption was a reason to reject a drive here,
  not to pay for one, and this drive has none.

  **What the purchase does not close.** Both of ADR-0023's conditions are
  open and no drive satisfies either: whose key opens the copy — ADR-0024's
  second recipient or a separate one — and the path being opened once from
  the other person's device, signed into their own account, without the
  operator present. The roadmap entry for #455 is rewritten to say so, because
  "buy the off-estate drive" stopped being what that issue is about the moment
  the drive was bought.

  **Three things the fit checks rather than assumes**, all recorded in
  [`hardware.md`](hardware.md): the drive ships formatted for Windows and the
  filesystem has to suit whoever must read it without the operator; its cable
  is USB 3.0 Micro-B at the drive end, so the cable travels with the drive or
  the drive is a brick at the other address; and a 5 TB 2.5" drive of this
  class is shingled, fine for an archive written in one pass and not fine as a
  live target. **The price is not recorded**, which is the entry's one gap and
  named there rather than left to be noticed.

- **[#442](https://github.com/Gerrrt/HomeLab/issues/442) The estate has a
  remote path, and it reaches the lab and nothing else.** WireGuard terminating
  on `phoenix`, designed by
  [ADR-0042](adr/0042-terminate-the-remote-path-on-the-lab-and-route-it.md) and
  given an endpoint by
  [ADR-0044](adr/0044-answer-the-endpoint-with-dynamic-dns-from-morpheus.md):
  one UDP `rdr` on `morpheus`, the first inbound pass that WAN has ever
  carried, answering at a dynamic DNS record created 2026-09-21. One peer,
  `laptop-01`, pinned to `172.31.0.2/32`. Routed rather than masqueraded, so a
  peer keeps its own address across the jumpbox and a `filterlog` line names
  which device tried — measured, not asserted: 264 packets to Winterfell, 26 to
  CasaBonita and 17 to Hicks were blocked and attributed to `172.31.0.2`, with
  **zero** passed toward the house. `alexander` answered at `ttl=63`, the
  decrement that proves the jumpbox forwarded rather than answered. Sequenced
  behind [#566](https://github.com/Gerrrt/HomeLab/issues/566) deliberately,
  because until `Saruman`'s own firewall was on a peer would have reached the
  hypervisor's login page. ADR-0022's second trigger was spent recording this
  in advance rather than discovering it afterwards, and ADR-0042's two
  residuals still stand: a peer is a credential with no revocation mechanism,
  and the one externally reachable host reports to the store no house alert
  reads. → [runbook](runbooks/open-the-remote-path.md)
- **ADR-0042's forwarding mechanism does not work on Ubuntu 26.04, and it fails
  reporting success.** The ADR scopes forwarding to the tunnel's lifetime by
  putting `sysctl` in wg-quick's `PostUp`/`PostDown`, deliberately rather than
  in `/etc/sysctl.d`. The distribution ships an AppArmor profile whose
  `wg-quick//sysctl` child denies writing `/proc/sys/net/ipv4/ip_forward`, and
  which also denies executing `bash`, so a shell workaround fails too. `sysctl`
  prints the value it did not set and `systemctl` reports the unit started
  cleanly; only `dmesg` carries `apparmor="DENIED"`. **The resulting tunnel
  looks entirely healthy**: the handshake succeeds and the jumpbox itself
  answers, because packets addressed to it need no forwarding — while every
  other lab host is unreachable and not one firewall rule can be exercised. The
  toggle moved to a systemd drop-in, which runs outside that profile and keeps
  the ADR's property intact; the decision is unamended and carries a note.
  Found by the §8 verification failing in a way that looked like success.
- **Four defects in `open-the-remote-path.md` §8, all found by building it.**
  Its positive check pinged `10.0.30.1`, which a peer can never reach because no
  rule passes a `172.31` source to the firewall's own lab address — and because
  that check always failed, it masked the forwarding bug above for an
  afternoon. Its negative checks and leak drill cannot fire at all while the
  client is correctly scoped, since those destinations are not in `AllowedIPs`
  and the packets never enter the tunnel; the drill needs the client
  temporarily widened, which ADR-0042 anticipated when it said the firewall is
  the lock this verification credits. Its `ping -W3` means milliseconds on
  macOS, so every negative check passed instantly without testing anything.
  And `-c1` cannot survive WireGuard re-handshaking after a server restart, so
  a single packet lost inside the client reads as a firewall block. The section
  now proves location from the route table rather than from intention, checks
  counters rather than pings, and says which flags differ per platform.

- **[#599](https://github.com/Gerrrt/HomeLab/issues/599) `smaug`'s memory is
  bought, to 32 GB across all four slots rather than to 32 GB with two spare.**
  Three Samsung `M391A1G43EB1-CPB` — the same 8 GB DDR4-2133 ECC UDIMM the
  machine already carries — $44 each, $147.30 with FedEx 2Day, new from
  Memory.NET with a lifetime warranty on the modules. The row entered the buy
  table on 2026-09-21 and left it on 2026-09-22 by that section's own rule: a
  part in transit is its issue's to track, and the money being spent is what
  moves it to [`hardware.md`](hardware.md).
  README's count goes back to two.

  **The row said "two slots left free" and the purchase did not honour it**,
  which is worth writing down as a decision rather than letting the record
  quietly disagree with the machine. Two 16 GB ECC unbuffered modules were
  $134 to $140 each new — more than three of these — and the 2133 module
  already fitted clocks the set either way, so the matched-set answer was
  cheaper and the speed argument was a wash. What it costs is the upgrade
  path: with four slots occupied, the board's 64 GB ceiling is a replacement
  of all four modules rather than an addition. That trade was named on the
  issue before the money was spent and is named in `hardware.md` now, because
  the second half of that ceiling was never costed and 32 GB is the number
  ADR-0040's workload was sized against.

  Bought the day after the installed module's label was photographed, which is
  what fixed the part number: `PC4-2133P-EE1-11` read off the module, `EE` for
  ECC unbuffered, against this listing's `PC4-17000P-E` for the same thing.
  Nothing in the Compute table changes yet — it reads 8 GB until the modules
  are in the slots, and the arrival checks the thing no listing can answer:
  that three strangers and the incumbent train together at 2133, and that the
  board posts with every slot filled.

## 2026-09-21

- **[#575](https://github.com/Gerrrt/HomeLab/issues/575) Silences have hygiene:
  both carry an owner, and an expiry now warns before it lapses.** Deployed and
  verified via [#587](https://github.com/Gerrrt/HomeLab/pulls/587).
  `SilenceExpiresSoon` and `SilenceWithoutIssue` are loaded and quiet, and
  `make silence-state` renders the collector's series — the remaining silence
  sits 16.96 days out, so the rule should go pending on 2026-10-01. The
  unowned one was re-posted with `amtool silence update`, which keeps the UUID,
  so the three mentions of that id in
  [`replace-the-laptop-cell.md`](runbooks/replace-the-laptop-cell.md) stayed
  true. The parser anchors the issue reference to the start of the comment, and
  a mutation test proves why: both silences cited a closed issue mid-prose, and
  a lenient parser would have called them owned. **An expired silence is
  deliberately not emitted** — Alertmanager holds one for 120 hours and
  Prometheus keeps the series for thirty days, so the history already answers
  "did a page return to a silence that ended", and emitting them would make the
  expiry rule count backwards from every lapsed one. **One step is outstanding
  and was left knowingly:** `sudo make install-timers` needs a password and has
  not run, so the collector has only ever run by hand and its staleness gauge is
  absent rather than stale, which means no `ScheduledJob` rule can fire for it.
- **[#599](https://github.com/Gerrrt/HomeLab/issues/599) Opened: memory for
  `smaug` enters the buy table, and the entry that said nothing was
  outstanding for that box is corrected.** The TS150 was bought on 2026-09-09
  as a bare NAS and read off the board on 2026-09-15 as **8192 MB in one of
  four slots** — one Samsung `M391A1G43EB1-CPBQ`, 8 GB 2Rx8 PC4-2133P, ECC
  unbuffered. Since then it has taken the mirror `erebor` (2026-09-18) and
  Jellyfin with Quick Sync (2026-09-19), and neither was weighed against that
  DIMM when the box was specced. The board holds 64 GB across four DDR4
  UDIMMs at 2133 or 2400 ([Lenovo Press LP0625](https://lenovopress.lenovo.com/lp0625-ts150-intel-xeon-e3-1200-v5-v6-core-i3-pentium-celeron-g-series)),
  so this is an add and not a replace, and the part has to be ECC
  **unbuffered** — `hardware.md` recorded that constraint on the day it read
  the stick, which is the reason this purchase needed no research to specify.
  What is decided is the type, 32 GB, and two slots left free; the vendor and
  whether the 2133 stick stays fitted are chosen on cost and recorded in
  [`hardware.md`](hardware.md) then. **It is an upgrade and says so** — not
  the consumable exception, and not inside `roadmap.md`'s prohibition, which
  names `prometheus`, `oracle` and Wazuh and does not name this machine.
  README's count moves to three, which `check_buy_list` asserts against the
  table rather than against this sentence.

- **[#85](https://github.com/Gerrrt/HomeLab/issues/85) Closed: both devices
  ADR-0036 names are on SNMPv3 authPriv, and neither answers a community.**
  SNMPv1 went off on the UPS card the same day its poll moved, and
  `snmp-verify.sh --old` reported its former community `rejected` — the
  check that proves it, because that probe is v2c whatever the device speaks
  now. The confirming verify afterwards is green, as is the whole fleet.
  The estate is mixed on purpose and the documents say which is which: the
  firewall stays on v2c because bsnmpd is the only daemon that serves the pf
  MIB, the switch until [#444](https://github.com/Gerrrt/HomeLab/issues/444)
  replaces it, and both of those polls ride on Winterfell.

  **What v3 costs, measured on the card rather than assumed** — the walk is
  58 varbinds, so one engine-discovery round trip is the whole difference:
  0.038 s over the ten minutes after the switchover against 0.031 s over the
  24 hours before it. Two transients, both explained rather than left in the
  average: the first v3 scrape took 0.188 s, and one scrape took 10.0 s at
  the moment SNMPv1 was switched off, which is the NMC restarting its network
  interface on save exactly as the runbook warns. The next scrape was 0.041 s
  and `up` never dropped. On the iLO the same measurement was 12.09 s against
  12.05 s.

- **[#85](https://github.com/Gerrrt/HomeLab/issues/85) `mjolnir` is polled
  over SNMPv3 too, and the UPS shutdown runbook was waiting on a key name
  that never existed.** The card's profile was created on 2026-09-20 beside
  the iLO's — `prometheus`, SHA, AES, an access-control entry for
  `10.0.99.20` and nothing else — and `auth_apc` became the v3 block today,
  verified against the live card before the exporter switched. Both devices
  ADR-0036 names are now encrypted; the firewall and the switch stay on v2c
  for the reasons it gives, and both of those polls ride on Winterfell. The
  card's SNMPv1 is still enabled, so §4.5 is what is left and the issue is
  still open.

  Moving it found two things. The
  [shutdown runbook](runbooks/shut-down-on-the-ups.md), written while the
  card was still on v2c, named the v3 keys `SNMP_AUTHPASS_MJOLNIR` /
  `SNMP_PRIVPASS_MJOLNIR` — names that have never existed, because every
  tool derives them from the auth label, `auth_apc`, and not from the device.
  Someone building the NUT server would have searched SOPS for a key that is
  not there. And §4.5 gained the check
  [ADR-0049](adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md)
  asked it for: anything else holding the device's community moves before v1
  goes off, because a consumer left on v2c is what keeps v2c enabled, and it
  fails silently — the exporter stays green throughout. That consumer does
  not exist yet here, so there was nothing to move.
  → [runbook §4](runbooks/rotate-snmp-community.md#4-move-a-device-to-snmpv3)

## 2026-09-20

- **[#566](https://github.com/Gerrrt/HomeLab/issues/566) `Saruman`'s Proxmox
  firewall is on, and ADR-0014's rule is true for the first time.** The rule
  existed only in a runbook. Enabling it found a second thing: Proxmox had been
  admitting the whole segment through a `management` set derived from the
  node's own subnet, so narrowing `local_network` is what makes the ADR true
  rather than the switch alone.
  [#576](https://github.com/Gerrrt/HomeLab/issues/576) is the gauge and the
  rule that keep it on.
- **[#483](https://github.com/Gerrrt/HomeLab/issues/483) `smaug`'s SMART
  arrives, and its patch state is declined on the record.**
  [ADR-0047](adr/0047-collect-smaug-smart-through-a-root-cron-and-the-textfile-collector.md)
  puts SMART under the scrape by a root cron job on the host and the textfile
  collector; patch state is declined for an appliance rather than left as a
  silent gap. The boot disk's reallocated count is a confirmed baseline. So the
  cost ADR-0016's scrape-don't-push reversal carried is now the logs alone
  ([#255](https://github.com/Gerrrt/HomeLab/issues/255)), not SMART and patch
  state with them.
- **[#574](https://github.com/Gerrrt/HomeLab/issues/574) Decided: the estate
  shuts down on `mjolnir`'s signal from a NUT server on the firewall.**
  [ADR-0049](adr/0049-shut-down-on-the-ups-from-a-nut-server-on-the-firewall.md),
  not built. The issue found that nothing subscribed to the card for the one
  thing a UPS is for, and that no document said what powers `smaug` — read at
  the rack, it is the PDU by a long cord to the media room, so it is on the UPS
  with `morpheus`, `Saruman` and `neo`, and `hardware.md` now carries a
  *Powered by* column. It costs no purchase and no new path: the pfSense NUT
  package has been installed since 2026-08-20 and never configured, the
  firewall reaches the card with no rule, and both subscribers already reach
  their gateway on 3493 under the catch-all — the two pass/block pairs
  *narrow* that to one host per segment. The S3520's unsafe-shutdown counter
  measures any cut the sequence misses, and
  `SmartDriveUnsafeShutdownsGrowing` reads it over ADR-0047's cron job.
- **[#573](https://github.com/Gerrrt/HomeLab/issues/573) Decided: the backup
  sets ride with the second age recipient.**
  [ADR-0048](adr/0048-carry-the-estates-backup-sets-with-the-second-recipient.md).
  The newest set of each kind goes on the medium holding the second recipient,
  carried by `make backup-offsite` on the ninety-day visit that medium already
  owes, re-verified and hashed there, and nagged by `OffsiteCopyStale` past
  ninety days. Everything that can be built is; the one thing that cannot is
  the visit, so `ScheduledJobNeverRan` names the job, which is the honest
  state. This retires the "off-host is not offsite" residual that #92 and the
  volume sets had carried since 2026-09-19: it is owned now rather than
  accepted.
- **[#85](https://github.com/Gerrrt/HomeLab/issues/85) `shiva` is polled over
  SNMPv3.** The user exists on the iLO, `auth_ilo` is the v3 block,
  *SNMPv1 Request* is off, and the iLO refuses its own former community over
  v2c — the whole of §4 including §4.5, proved with `--old` and recorded on
  the issue. The v3 discovery round trip cost nothing measurable: 12.09 s
  averaged over the hour after the move against 12.05 s over the day before
  it. `mjolnir` is next, same procedure, device first. The MokerLink's UI is not
  checked for a v3 user page after all: it stays on v2c until
  [#444](https://github.com/Gerrrt/HomeLab/issues/444) replaces it, and
  [ADR-0041](adr/0041-run-the-crs326-on-routeros-and-keep-neo-and-its-switch-lan.md)
  commissions the CRS326 with an authPriv user by the same runbook.
  → [runbook §4](runbooks/rotate-snmp-community.md#4-move-a-device-to-snmpv3)

**2026-09-20: the SSD pair is measured and carrying `alexander`.** What the
paragraph above called not finished is: logical drive 2 on 2026-09-19,
`ssacli` on the host that evening, both arrays measured at 4 KiB queue depth
1 — the 7.2K mirror 741 IOPS, the SSD mirror 7,952 — and the lab guest moved
across and rebooted from flash on 2026-09-20.
[#527](https://github.com/Gerrrt/HomeLab/issues/527) closed on it; the
numbers are in [`hardware.md`](hardware.md) and the reasoning that used the
old number carries dated notes. Nothing here was bought.

- **[#95](https://github.com/Gerrrt/HomeLab/issues/95) Plan and build the NAS on
  VLAN 40.** [ADR-0016](adr/0016-open-casabonita-inward-and-keep-it-terminal-outward.md)
  answers the four questions #95 raised. **The box is bought**, 2026-09-09,
  tracked under [#413](https://github.com/Gerrrt/HomeLab/issues/413) since #95
  closed on the decision: a Lenovo ThinkServer TS150 — Xeon E3-1225 v6, 8 GB
  ECC, four 3.5" bays, no drives, no OS. Not the "quiet N100-class" chassis the
  ADRs pictured, and the difference is worth stating rather than smoothing: a
  73 W desktop Xeon in a tower against a 6 W part in a shoebox, so it draws and
  makes more, and it will not rack. What it has that an N100 box does not is
  ECC memory under a ZFS mirror, four real bays, and a Kaby Lake iGPU whose
  Quick Sync is what #138's transcoding needs. The drives were bought on
  2026-09-11 — two Seagate Exos X20 18 TB, chosen on cost per terabyte per
  the ADR — and the boot disk with them, an Intel DC S3520 240 GB, with the
  bracket and the tape that carry it in the optical bay bought the same day.
  This paragraph said a bracket was the only thing left to buy, which had not
  been true since 2026-09-11. **The box landed 2026-09-15**, and the boot disk,
  the bracket and the tape with it. The
  OS is decided, and **it is TrueNAS, not Ubuntu Server** — this line said the
  opposite until 2026-09-15, when the operator said aloud what was about to be
  installed and it turned out ADR-0016 had decided against the only OS ever
  intended for this box
  ([ADR-0040](adr/0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)).
  The media stack stays in this repository either way, as a compose file
  TrueNAS launches rather than catalogue apps, so Dependabot and the image-pin
  check keep reaching it; what leaves CI's reach is the pool and share layout.
  **The host is built and the pool is not** — this paragraph said "nothing is
  configured" until 2026-09-16, and on that day
  [`build-the-nas.md`](runbooks/build-the-nas.md) §0 was completed end to end:
  the BIOS flashed, AMT found on Intel's factory-default credential and
  unprovisioned, the optical drive swapped for the boot SSD and its SMART read
  **before** the install, TrueNAS 25.10 installed, the static and the Kea
  reservation both set, and the inbound rules created and verified. **The
  drives landed 2026-09-18**, both at zero hours by the FARM log and not only
  by SMART, and the rest followed: the mirror `erebor`, its two datasets, the
  household share `media`, and the stack running under TrueNAS's Docker with
  the scrape live on 2026-09-19. **ADR-0040's reopen condition is closed**:
  the render node reaches the container, the process carries the render
  group, and a forced transcode ran through VAAPI and `h264_qsv` at about
  five times real time the same day. The stack stays on this host.
  Reading the enforced ruleset first changed two of the answers, and both were
  borne out when the rules were created. **50→40 is not simply a rule to add**:
  Hicks and Winterfell each carry an explicit *Block access to
  CasaBonita* above their catch-all, so the pass has to be ordered in front of a
  deny, and one appended where new rules naturally land would match nothing —
  the same fault ADR-0013 found in *Allow Hicks access to ImaginationLAN*. That
  is why position was verified from `morpheus` with `pfctl` rather than from
  the web UI, where an appended rule looks present while matching nothing. And
  **one rule is not enough**: every other host in the estate is monitored and
  backed up by pushing, so a NAS built like the others would have its Alloy
  agent initiating 40→99, the first upward path in the estate and the end of the
  property ADR-0008 claims to keep. The ADR reverses the direction instead —
  scraped rather than Alloy pushing, the metadata backup pulled
  by `prometheus` rather than sent — which costs the NAS its logs, because Loki
  has no pull and its ingest is unauthenticated, and costs it its SMART and its
  patch state for the same reason
  ([#255](https://github.com/Gerrrt/HomeLab/issues/255),
  [#483](https://github.com/Gerrrt/HomeLab/issues/483)). ADR-0016 wrote down
  three rules, all inbound, all host- and port-scoped, and deliberately did not
  create them: a `pass` to an address with nothing behind it is a rule nobody
  can test. **Four exist since 2026-09-16**, because the Hicks pass is split
  into two rather than carrying a port list, and Hicks reaches `443` and not
  the `22` that ADR-0016's table names — that port assumed a box administered
  over SSH, which was an operating-system decision inside a firewall table, and
  ADR-0040 carries the correction against its own text. Port 22 survives on the
  Winterfell rule and was **inert** until 2026-09-19, when
  [`build-the-nas.md`](runbooks/build-the-nas.md) §6.2 switched SSH on for
  the backup pull — decided by
  [ADR-0045](adr/0045-pull-jellyfins-state-from-a-snapshot-over-ssh.md),
  built under [#484](https://github.com/Gerrrt/HomeLab/issues/484), and
  deployed by hand on `smaug`, where nothing pulls from `main`; the first set
  landed on 2026-09-20. The scrape target is
  **`node_exporter` on `9100`**, settled by
  [#256](https://github.com/Gerrrt/HomeLab/issues/256) on 2026-09-17 — the pass
  that exists and a dashboard built entirely on `node_*` series, against an
  alternative the repository had never measured and which would have cost a
  fifth rule. The job and the target file are written, and the target has been
  live since 2026-09-19 (#522); #256 closed on it the same day. Terminal survives
  in the direction that carries it — CasaBonita stopped being terminal inbound
  on 2026-09-16 and stays terminal outbound, with #223's tripwire untouched and
  reading zero packets. Capacity buys a
  four-bay chassis with two bays filled, because the bay count is the half that
  cannot be changed later and the library's size is a number nobody has; the
  two filled trays have held the Exos pair since 2026-09-19, and `erebor` is
  their mirror. **One of them faulted on 2026-09-19**, a day in, with the
  exporter hung ahead of it and nothing yet pulling `erebor/apps` off the
  box; [#558](https://github.com/Gerrrt/HomeLab/issues/558) carries the
  swap, the return, and the rule that now reads pool state.
  → [runbook](runbooks/replace-the-nas-disk.md)

- **[#101](https://github.com/Gerrrt/HomeLab/issues/101) Build ADR-0007's
  defended estate on `Saruman`** — a Windows domain, Wazuh, Velociraptor, PBS
  and a second observability stack. The umbrella. The observability half is
  built and the security half is decided but not yet racked; the work is split
  seven ways, which is what moved it out of *Decided but not built* below.
  [ADR-0020](adr/0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)
  answered the two questions ADR-0007 left open, and both of them blocked the
  first line of work. `stacks/lab/` runs in a **guest**, not on the hypervisor:
  `Saruman` is the one host in the estate that must not run Docker, because
  ADR-0014 leans on its own firewall and Docker rewrites iptables — which is
  why #88 deployed the native `.deb` there rather than a container. And the
  stack carries its own **Prometheus**: ADR-0007 named three services while
  saying in the same sentence that `config.alloy` is reused with only the two
  `*_URL` variables changed, and that file has two sinks, so a lab without a
  Prometheus points the second one at `10.0.99.20` and inverts the isolation
  the ADR exists for.
  [#264](https://github.com/Gerrrt/HomeLab/issues/264) is built **and
  running**: `stacks/lab/` is deployed on `alexander`
  ([#262](https://github.com/Gerrrt/HomeLab/issues/262), 2026-09-05), the guest
  on `Saruman` that ADR-0020 called for. Four services, its own age key, its own
  leaf from the estate's CA, and three Loki log sources confirmed on the host —
  the check the Ubuntu-over-Debian decision exists for.
  → [runbook](runbooks/build-the-lab-guest.md) Building it made the tooling stack-aware
  (`render-config.sh` derives its required keys per stack rather than demanding
  the estate's ten, `reload-config.sh` skips services a stack does not declare,
  `bootstrap.sh` refuses to give one age key both stacks) and gave `.sops.yaml`
  the lab rule ADR-0020 asked for. [#263](https://github.com/Gerrrt/HomeLab/issues/263)
  followed it: `scripts/stacks.sh` is now the single definition of what a stack
  is, and `validate.sh`, `ci.yml`, `pin-digests.sh` and the Python checkers all
  read it instead of carrying `stacks/observability`. Both stacks are checked,
  each line says which, and a directory under `stacks/` with no compose.yaml
  fails rather than being skipped — a stack nothing checks being the defect the
  list exists to prevent. Two guards got stronger on the way: rules without
  `promtool` unit tests are now a failure rather than an absence nobody
  measured (#63), and the reload/ABSENT_BINARIES cross-checks gained a
  cross-stack mode, because "not in this compose file" stopped meaning "in no
  stack at all" the moment there were two.
  [#265](https://github.com/Gerrrt/HomeLab/issues/265) decided the domain and
  closed on the decision; [#414](https://github.com/Gerrrt/HomeLab/issues/414)
  is the build, and it is what everything else is pointed at — **not built**
  as of 2026-09-09: six VMs, the runbook's eleven sections, evenings at
  `Saruman` from a Hicks workstation, nothing to buy until the endpoints. It is
  sized by
  [ADR-0029](adr/0029-size-the-lab-domain-and-separate-its-namespace-and-clock.md)
  rather than by taste: six guests on the `.50` decade, because NTLM relay needs
  a destination that is not the origin and, since Windows 11 24H2 requires
  inbound SMB signing where Server 2025 does not, the only relayable host in a
  DC-plus-workstations domain is the DC itself. The servers run continuously and
  the endpoints per session, because a 7.2K mirror serves about ninety random
  write IOPS and six idle Windows guests would be most of them — the number
  #418's SSDs were bought against, and the one their *fit* re-derived on
  2026-09-20: the mirror does **741** random write IOPS at queue depth 1, not
  ninety, because the controller cache the derivation assumed absent is
  present, and the SSD pair does **7,952** — so the six guests go on
  `large_data`, and continuous-versus-per-session is a choice this build
  makes for its own reasons, not one the array makes for it. ADR-0029's
  duty cycle stands as written under a dated note; what it costs #266 to
  run the endpoints continuously is now a question, not a constraint.
  Three things
  that ADR left explicit because they fail quietly: the DC takes its clock from
  the gateway, not `time.windows.com` — ADR-0014 named that failure and did not
  fix it, and the alert reads the *sync source* rather than the offset, because
  the offset reads zero for exactly the case where w32time has fallen back to
  the CMOS clock; the domain answers its own names inward only, with no
  delegation on Unbound, which is the one documented exception to ADR-0010's
  "clients receive the gateway as their only resolver"; and the domain is
  **scraped, not published**, reversing four comments in `stacks/lab` that
  expected the `ports:` block to open here — an unauthenticated remote-write
  receiver on the segment that exists to hold attackers hands a delete-series
  API to the thing it is meant to be recording.
  [#266](https://github.com/Gerrrt/HomeLab/issues/266) Wazuh and
  [#267](https://github.com/Gerrrt/HomeLab/issues/267) Velociraptor are one
  decision, and
  [ADR-0030](adr/0030-give-the-security-tooling-its-own-guest-and-its-own-stack.md)
  makes it: both in `stacks/soc/` on `odin`, a second guest, because
  `alexander` is 8 GiB and Wazuh's stated minimums are six before the dashboard
  — and because a second host means a second directory under `stacks/`, which is
  what ADR-0004 says rather than something it forbids. It also corrects #266's
  own premise. Six agents make about 21 GB of alerts a quarter, which the disks
  do not notice; what runs out is heap-per-shard, at OpenSearch's
  twenty-five-shards-per-GiB against one daily index each, so retention is
  thirty days because that is what a 2 GiB heap buys. `stacks/soc/` was
  authored and CI-validated in #434 on 2026-09-10, ahead of `odin` the way
  `stacks/lab` was ahead of `alexander`; what it cannot do
  before #414 is say anything, because an agentless Wazuh has nothing to
  report.
  [#268](https://github.com/Gerrrt/HomeLab/issues/268) PBS was **decided and
  deferred** by
  [ADR-0027](adr/0027-defer-proxmox-backup-server-until-there-is-somewhere-to-send-it.md):
  a hypervisor backing up its own guests to itself is not a backup, `smaug`
  did not exist, and PVE already does the snapshots the local-only answer needs
  — so PBS would add a service for a capability that exists. That deferral
  named its own trigger — *"PBS follows the NAS answering on `10.0.40.30`, not
  the box arriving"* — and **the trigger has fired**: `smaug` has held that
  address since 2026-09-16. This paragraph said the trigger had moved from a
  purchase to a build, which was right, and then the build happened.
  The blocker cleared on 2026-09-19 as well: `erebor` is ONLINE, so there is
  somewhere to send it. What is left is that ADR-0027's sync job was designed against
  a Linux host rather than TrueNAS — on TrueNAS it is PBS in a VM or a change
  to an NFS/SMB datastore, which are not the same answer.
  [#485](https://github.com/Gerrrt/HomeLab/issues/485) carries the re-read,
  because a fired trigger whose tracker closed on the decision is how an
  accepted ADR quietly becomes a rejected one. The lab has **revert and not
  backup** until it lands, and the ADR names what gets backed up when it does —
  which is also why ADR-0029 gives PBS no disk on this pool: there is nothing
  to give it yet, and that stops being true on the day this is built. Liveness
  stays where it already was, with
  [#257](https://github.com/Gerrrt/HomeLab/issues/257): ADR-0020 decides only
  that no Alertmanager goes *inside* the stack, and the lab is otherwise being
  built to go quiet.

- **[#418](https://github.com/Gerrrt/HomeLab/issues/418) Fit the two SSDs in
  `Saruman`, and [#527](https://github.com/Gerrrt/HomeLab/issues/527) do
  everything the fit left.** Two Samsung SM863a 960 GB SATA enterprise
  drives, bought 2026-09-09, delivered 2026-09-11, fitted 2026-09-18, and
  **since 2026-09-19 logical drive 2 with the thin pool `large_data` on it,
  measured and carrying `alexander` since 2026-09-20**. #418 closed at the
  bays; #527 carried steps 5–11 of the runbook and closed on the numbers.
  ADR-0007's constraint — "the
  fleet is sized against spindles, not RAM" — became a number in ADR-0029,
  about ninety random write IOPS for the whole machine, and that number sized
  the lab domain's duty cycle and #266's indexer. The SSDs raise the ceiling.

  **Two of the three questions the issue left to the fit are now answered, and
  the one that matters is not.** The layout is decided: the SSDs become a
  *second* logical drive on the P440ar, RAID 1, Smart Array managed, with the
  7.2K mirror keeping Proxmox, the ISOs and the backups. That is the smaller
  change, it keeps a spindle for the things that do not need IOPS, and it
  leaves `IloDrivePredictiveFailure`, `IloDriveSmartUnreadable` and the
  `replaceDriveSSDWearOut(4)` state reading `cpqida.mib` exactly as they do
  today — so #351's decision to skip `smart-state` on this host stays right
  rather than needing re-checking. #76's cache is **read and handed over, not
  changed**: `modify cacheratio=` is controller-wide and would land on the
  array holding every guest, so the runbook takes the `ssacli` reading nobody
  has ever taken on this machine and #76 owns what to do about it.

  **The trays blocked it for a day, the fit stopped at the bays, and the
  array came the day after.** A Gen9 bay holds a drive only in a SmartDrive
  carrier; two `651687-001` were bought 2026-09-11, had not arrived on the
  morning of 2026-09-17, and were in the chassis with a drive in each by
  20:11 UTC on 2026-09-18 — both drives present, `Bay 3` and `Bay 4`,
  different serials, solid-state, SMART `ok`, `notConfigured`, and nothing
  alerted. Three predictions were wrong on the day and are corrected in the
  runbook — the iLO names the drive `SAMSUNG` and not by part number, the
  walk did not get slower, and the serials were read back through the iLO
  rather than off the labels first; the label check was then not done, and
  the window for it closed with the array. On 2026-09-19 the drives became
  **logical drive 2** — RAID 1, `915683` MB, index `2` as predicted, `ok`
  from the first scrape with no sync the iLO ever showed — made through the
  offline Smart Storage Administrator, the runbook's path 3, because `ssacli`
  is still not on the host and neither way of getting it there was tried.
  The thin pool on it is **`large_data`**, made that afternoon; the runbook's
  `ssd` is renamed throughout. Two things that path cost: the controller has
  still never been read from the host, so the cache reading #76 has waited on
  since 2026-09-02 is still owed and needs `ssacli` or a second SSA session;
  and the session was a fourteen-and-a-half-hour power-off rather than the
  twenty-minute reboot the runbook priced, so `RemoteWriteJobStale`,
  `GuestStateStopped` and `PatchStateStopped` all fired with nothing silenced,
  which the runbook now says how to avoid. One reading is worse than hoped
  and is now confirmed: the wear and endurance columns are blank on both SSDs
  **with the drives configured**, as they are on the HDDs, so wear monitoring
  on the newest drives in the estate needs `smartctl` through the `hpsa`
  path — [#529](https://github.com/Gerrrt/HomeLab/issues/529), filed against
  exactly that condition, is no longer gated on anything. A thin pool is also
  not a filesystem, so `HostDiskCritical` cannot see `large_data` fill;
  [#538](https://github.com/Gerrrt/HomeLab/issues/538) is that blind spot,
  opened while the pool was still empty.

  **The rest ran on the evening of 2026-09-19 and the small hours of
  2026-09-20, and the number the purchase was for is measured.** `ssacli`
  went on through path 1 after all — HPE publishes a `trixie` suite, which
  the runbook had said it did not — and read the controller for the first
  time from the host: `Cache Ratio: 10% Read / 90% Write`, battery-backed,
  LD 1 `Caching: Enabled`. That is #76's answer, and it is **(a)**: the iLO's
  cache columns are not populated on this hardware, the ratio was set all
  along, and the change #76 would have owned does not exist. The spinners
  are SATA, not SAS, which `hardware.md` now says. The SSD array is on Smart
  Path, which excludes the controller cache and is the controller's design
  point for it. Then fio at 4 KiB, queue depth 1, on a thin volume in each
  pool: **the 7.2K mirror does 741 IOPS** idle and 734 with the guest live —
  nine times ADR-0029's derived 83, because the derivation assumed no write
  cache and there is one — and 712 at queue depth 32, so ~700 is the array's
  sustained rate; **the SSD mirror does 7,952** at queue depth 1 and 51,600
  at queue depth 32. `alexander`'s 100 GiB disk mirrored across online in
  7 min 28 s, `ssd=1` went on, and the guest rebooted from flash at about
  02:58 UTC. No silence was created or needed for any of it. Two things the
  run cost are in the runbook: a capitalised pool name that had fio
  benchmark RAM for a block, and a guest built with `--agent enabled=1` and
  no agent installed. ADR-0029, ADR-0007 and ADR-0017 carry dated notes
  rather than edits — ADR-0001 makes them immutable — and the #414 paragraph
  above says what the number now is.
  → [runbook](runbooks/fit-the-saruman-ssds.md)

- **[#436](https://github.com/Gerrrt/HomeLab/issues/436) Build a deployment
  jumpbox on ImaginationLAN, and decide where the CA lives.** Decided by
  [ADR-0043](adr/0043-keep-the-ca-on-prometheus-and-build-phoenix-as-the-deployment-host.md);
  the guest was built 2026-09-20. The host is `phoenix`, `10.0.30.70`, a guest on
  `Saruman` that holds the estate's first Proxmox API credential and the SSH
  key the toolchain will inject into what it builds — the prerequisite for
  the Packer, OpenTofu and Ansible issues, which today have nowhere to run
  from. The CA question the issue carried was answered by reading the root
  first: the issue's premise — that the tier's step-ca already sits beneath
  the estate's CA — is the sentence ADR-0037 retracted, and the estate's
  root is `pathlen:0`, so the only question was where one key file sits. It
  stays on `prometheus`, because the host that holds credentials for every
  other host must not also hold the key every other host trusts, and
  because VLAN 30 is the segment ADR-0014 built to hold attackers. Two things
  the issue did not count: the Proxmox firewall on `Saruman` admits `8006`
  from Hicks only, so the build widens ADR-0014's rule by one address on one
  port, recorded as a marked amendment there and on ADR-0039; and
  `certificates/ca-key.pem` has no backup or custody story at all, unlike
  the age key and the tier's root — found, named in the ADR with what the
  answer is not, and carried by
  [#496](https://github.com/Gerrrt/HomeLab/issues/496) — delivered on
  2026-09-19 as a proved offline copy and `CaKeyBackupUnproven`
  (→ [runbook](runbooks/back-up-the-ca-key.md)). The same host is
  where [ADR-0042](adr/0042-terminate-the-remote-path-on-the-lab-and-route-it.md)
  terminates the remote path; that ADR left the `8006` question to this issue,
  and it is taken here.
  → [runbook](runbooks/build-the-jumpbox.md)

- **[#527](https://github.com/Gerrrt/HomeLab/issues/527) `Saruman`'s
      SSDs measured, cached-or-not settled, and `alexander` moved onto them.**
      2026-09-20. Steps 2, 3, 6, 8, 9, 10 and 11 of the fit runbook, run from
      the Mac between 22:50 UTC on 2026-09-19 and 03:03 UTC on 2026-09-20.
      `ssacli 6.60` installed from HPE's `trixie` suite in one `apt-get`
      (path 1; the runbook had believed no such suite existed). The
      controller, read from the host for the first time: `Cache Ratio: 10%
      Read / 90% Write`, `1.8` GB battery-backed, LD 1 `Caching: Enabled`, LD 2
      on Smart Path with caching refused for that reason — so #76's reading
      is branch (a), the iLO's cache columns are blind on this hardware, and
      no rule may be written on them. Both spinners `Interface Type: SATA`.
      fio, 4 KiB random write at queue depth 1 on a thin volume per pool: HDD
      mirror **741** IOPS idle (734 loaded; 712 at queue depth 32), SSD mirror
      **7,952** (51,600 at queue depth 32). `alexander`'s 100 GiB disk moved
      online in 7 min 28 s, `unused0` removed after the guest answered,
      `ssd=1`, rebooted: `ROTA 0`. No silence created; none needed. Two
      costs: `Large_data` for `large_data` had fio write 8 GB into devtmpfs
      and report RAM's numbers for a block, and `qemu-guest-agent` was never
      installed in the guest, so `qm reboot` needed it first. `hardware.md`
      carries the numbers and loses the word SAS; ADR-0029, ADR-0007 and
      ADR-0017 carry dated notes; the #414 paragraph says what the number is
      now. → [runbook](runbooks/fit-the-saruman-ssds.md)

## 2026-09-19

**2026-09-18: the cell is fitted, and the issue stayed open.** The A1437 went
into `prometheus` the day it was delivered; the host was down from 14:53 to
about 18:12 UTC. The new pack reads `charge_full` 6.889 Ah of 6.8 Ah design at
one cycle, and both of its design figures differ from the old pack's — an
aftermarket cell reports its own, which is the only proof of a changed part on
a machine that exports no serial number. **The buy table does not move**: the
cell left it on 2026-09-13, and fitting is not buying. What was still owed was
the mains pull on the charged pack and the runtime it measures; that ran on
2026-09-19 — 2.72 Ah/h, about 2.5 hours from full — and
[#454](https://github.com/Gerrrt/HomeLab/issues/454) closed on it, with its
*Done* entry below.

**2026-09-19: the second cell is identified and enters the list.** `oracle`'s
pack is a Dell M5Y1K — 14.8 V, 40 Wh, four cells, the latched pack the
Inspiron 15-3565 takes — read off the machine's own `model_name` rather than
off a listing, and recorded in [`hardware.md`](hardware.md) before any money
is spent, which is the order
[#531](https://github.com/Gerrrt/HomeLab/issues/531) asks for. The table goes
from two rows to three, and the row is the same consumable exception the
A1437 was: this cell reads 72 % of design, `HostBatteryHealthLow` has fired
for it since 2026-09-14, and it sits under a silence that expires 2026-10-08 —
the date that makes it *now* rather than *later*. Second in line stays
second: `prometheus`'s was bought first because that host dying is the estate
going blind. What closes #531 is not the cell landing but the fit and the
test after it, as with #454, and the silence deleted rather than left to
expire.

**2026-09-19, later the same day: the second cell is bought.** The M5Y1K for
`oracle`, from the listing recorded in [`hardware.md`](hardware.md), sold as
genuine Dell and recorded as the listing's claim until the pack is in hand.
The row leaves the table the day it joined it — three rows back to two, and
neither of them a part again: two licences and a drive kept at another
address. What closes [#531](https://github.com/Gerrrt/HomeLab/issues/531) is
unchanged: the fit, step 8's mains pull, and the silence deleted.

**The one exception, and it narrows this line rather than reversing it:** a
**consumable whose failure is a safety or availability event** is not an
upgrade. `prometheus`'s battery is the worked example
([#454](https://github.com/Gerrrt/HomeLab/issues/454)) — the estate's
mains-cut path depends on it, `host.rules.yaml` has measured it since
2026-09-12 — 94 % of design after 108 cycles, on the cell that was there then —
and the failure mode of a thirteen-year-old cell is a fire on a shelf. **That
cell was bought 2026-09-13 and fitted 2026-09-18**, so this is the exception
being exercised rather than restated; the new pack reads 101 % of its design
capacity at one cycle, and the runtime it was bought for was measured on 2026-09-19: about 2.5 hours from full at the stack's load. `oracle` has the same kind of cell and it measures
worse, 72 %, so `HostBatteryHealthLow` fires for it first; it stays second in
line only because `prometheus` is the host whose death is the estate going
blind. The cell for `prometheus` was bought on 2026-09-13, and `oracle`'s on
2026-09-19, the day it was identified
([#531](https://github.com/Gerrrt/HomeLab/issues/531)); nothing else about
either machine is.

- **[#67](https://github.com/Gerrrt/HomeLab/issues/67)** No dead man's switch on
  the notification path — a 200 into a dead topic is a successful notification.
  The awkward half of it — the watcher has to be somewhere other than this
  host — is answered: [ADR-0015](adr/0015-give-oracle-the-off-host-jobs.md)
  puts it on `oracle`. What that buys is bounded, and the ADR says so: it
  catches a silently dead notification path, and it cannot report a mains cut,
  because the switch between the two laptops has no battery (#110).

  **That last clause has been stale since 2026-09-08 and is corrected rather
  than swapped.** The switch was racked in U4 on UPS power by
  [#110](https://github.com/Gerrrt/HomeLab/issues/110), and each laptop rides a
  cut on its own cell — measured since 2026-09-12 and, on `prometheus`, replaced
  on 2026-09-18 ([#454](https://github.com/Gerrrt/HomeLab/issues/454)). So the
  off-host check *can* report a mains cut, for exactly as long as `prometheus`
  stays up on its cell — about 2.5 hours from full, measured on 2026-09-19
  ([#454](https://github.com/Gerrrt/HomeLab/issues/454)).

- **[#92](https://github.com/Gerrrt/HomeLab/issues/92) Rehearse the firewall
  restore on `trinity`.** Retitled 2026-09-19 — it used to read *Get the
  firewall backup off `prometheus`, and buy a spare ProDesk*; the copy is done
  and the buy was withdrawn by ADR-0034. Half done. Since 2026-09-03
  `make backup-firewall` copies every export to `oracle` — ciphertext only, the
  key stays here — and exits non-zero if it cannot, so the nightly job's metric
  says "stopped leaving this host" rather than "fine". Off-host, not offsite:
  both laptops share a shelf and a roof, and nothing copies anywhere a fire
  would not reach. The copy needs a one-time key exchange between the two
  laptops before its first run can succeed, and fails on purpose until then.
  That copy shipped defaulting to the wrong account — `robo@10.0.99.30`, where
  the login is `atropos` — so every nightly run would have failed on
  `Permission denied` from the first one, the local export written and verified
  and the copy step dead. It was invisible for a day only because the checkout
  the timer runs from was behind the commit that added it, which is its own
  lesson: a default nobody has executed is a guess. Retention landed with the
  fix, because until then both sides kept every export ever taken, nightly,
  forever; `FW_KEEP` (default thirty, and deliberately not `KEEP`, which
  `make backup` already owns in the shared environment file) bounds each side,
  never evicts the newest, never touches a file the script did not write, and
  clears the `.part` fragments a died copy leaves on `oracle`. Both sides
  converge in one run from any divergence. The far side's login shell is zsh,
  where an unmatched glob is fatal rather than literal, so the prune deletes by
  explicit basename and sends no pattern over the wire at all.
  What remains is the rehearsal, which is what turns
  [`restore-the-firewall.md`](runbooks/restore-the-firewall.md) from a
  hypothesis into a runbook; it now carries the bench procedure to follow and
  what to record. **The box to rehearse on is bought**, 2026-09-08 — the same
  ProDesk 600 G4 model, i5-8500T, 32 GB — and [ADR-0034](adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)
  decides it is not a cold spare on a shelf: it is rehearsed on first, then
  wiped and built as the sensitive tier's host ([#404](https://github.com/Gerrrt/HomeLab/issues/404)), and it is the
  firewall's spare hardware in a disaster at the cost of the tier being down
  until a replacement arrives. The powered-off shelf spare is deferred to the
  day that cost is unacceptable. **The box is in hand, and proving it has a
  deadline the rehearsal does not**: it was sold refurbished with a one-year
  warranty and a thirty-day return, and that return closes **2026-10-08**. The
  spec, the serial and the NIC count are still the listing's word rather than
  the machine's, and the step that would settle them — installing pfSense over
  the Windows 11 Pro it arrived with — is also the step that ends the return.
  So the machine gets proved before 2026-10-08 whether or not the card has
  landed by then, which is the one part of this issue that is not waiting on a
  package. Writing that procedure found the runbook's own decrypt
  command had never been run: it passed `--input-type binary`, which sops
  rejects on the first byte of a real export, so a restore following the
  runbook would have stopped at step one. Fixed, and it is the kind of thing
  the rehearsal exists to find. Preparing for it found two more on 2026-09-09,
  by reading `morpheus` rather than the documents: the runbook said the spare
  needs a USB NIC, and the shopping list had one on it, but the box has none —
  its second interface is an Intel I226-V on an M.2 adapter, `igc0`, carrying
  the management LAN and every VLAN, and a USB adapter would have come up
  under another name and put the restore into the interface-assignment
  dialogue the same-model rule exists to avoid. And the version the verify
  prints is the config schema (`24.6`), not the release (pfSense CE 2.9.0);
  the runbook told the reader to match it to an installer, which cannot be
  done. Both fixed, the release recorded in `hardware.md`, and the shopping
  list names the card. The volume sets `make backup` writes left the host they
  protect on 2026-09-19: [#535](https://github.com/Gerrrt/HomeLab/issues/535)
  built the copying that [ADR-0015](adr/0015-give-oracle-the-off-host-jobs.md)
  decided — every weekly run copies the set to `oracle` beside the firewall
  exports and fails if it cannot, the daily verify hashes the far side, and the
  restore runbook starts from that copy. Unlike the firewall, the sets have been
  restored — the whole stack was brought up on a restored set on 2026-08-29 and
  verified — but not yet from the copy on `oracle`. What remains for the sets is
  what remains for the export: off-host is not offsite.

- **[#454](https://github.com/Gerrrt/HomeLab/issues/454) Replaced
      `prometheus`'s battery, watched it, and proved the mains-cut path on it.**
      2026-09-19. Opened for a thirteen-year-old cell that nothing monitored and
      no document named as a dependency. The collector it proposed was never
      needed — Alloy exported `node_power_supply_*` all along, and the family is
      `charge_*`, not the `energy_*` the issue wrote — so #461 wrote three rules
      against what existed. The A1437 was bought 2026-09-13 as the one exception
      the *Never* line above names, fitted 2026-09-18, and on 2026-09-19 the
      brick was pulled on the full pack: the host stayed up, `HostOnBattery`
      fired for it alone inside three minutes, and the draw measured 2.72 Ah/h —
      about 2.5 hours from full, the first runtime figure the estate has had.
      Left behind as issues of their own: the RTC reset the disconnect caused
      (#519), `oracle`'s cell at 72 % (#531), and continuous watching of
      runtime and cell temperature (#532).

- **[#94](https://github.com/Gerrrt/HomeLab/issues/94) Decide what `oracle`
      is for.** 2026-09-03,
      [ADR-0015](adr/0015-give-oracle-the-off-host-jobs.md). The issue's four
      options were answered by first checking the machine, which made one of
      them impossible: `oracle` has run the Lemmiwinks wiki and its Postgres
      since 2025-11-12, ADR-0011 depends on it, and blackbox has been probing
      it twice on `host: oracle` all along. Three places in the repository said
      it had no role at the same time — the host table in `architecture.md`,
      the VLAN 99 notes in `network.md`, and `backup-firewall.sh`'s header
      ("It has no role (#94)"). `check_docs.py` reads that architecture row for
      the word "Alloy" and for a `stacks/` path and never for what it claims
      the host does, which is how the wrong sentence sat next to a checked one.

      **Decided:** it stays powered, and its role is the small off-host jobs —
      work whose value is that it is not on the monitoring host. The wiki and
      the firewall export copy it already has; the volume backup sets (#535,
      built 2026-09-19) and the dead man's switch watcher (#67) are added,
      decided here and built under their own issues. **Rejected:** a second age recipient *on `oracle`*,
      because a private key there would put the backups and the means to open
      them on one disk and retire the property the off-host copy exists to
      have — narrowed by
      [ADR-0024](adr/0024-hold-a-second-age-recipient-and-prove-each-one-separately.md),
      which keeps that rejection and makes a second recipient held *off* the
      estate the design (#106); its holder was decided on 2026-09-08 under
      [#294](https://github.com/Gerrrt/HomeLab/issues/294). Also rejected: the ADR-0007 stack, the
      ADR-0008 tier, bringing `wlp22s0` up to give the watcher an independent
      path — that dual-homes a VLAN 99 host onto an untrusted segment — and
      switching the machine off, which was never really on offer: the wiki had
      been running there for nine months when the issue was filed.

      Measured rather than quoted, 2026-09-03: 3785 MiB of RAM with 2549
      available under the wiki, its database and Alloy; a 465.8 GB 5400 rpm
      disk carrying one 100 GB LV with 67 GB free and 362 GB unallocated; and a
      NIC that advertises 10/100 only, so the link is 100 Mb/s and no cable
      will change that. A 867 MB backup set is 75 seconds of wire time there;
      seven of them are 6.1 GB, and they are already `age` ciphertext before
      they leave this host.

## 2026-09-18

**2026-09-13, later the same day: the battery is bought.** An A1437 cell for
`prometheus`, new, recorded in [`hardware.md`](hardware.md) — the consumable
the exception to *Never* below was written for, and the one row on this list
whose case was safety before availability
([#454](https://github.com/Gerrrt/HomeLab/issues/454)). The table goes from
three rows to two, and neither of them is a part: two licences and a drive
kept at another address. What closes #454 is not the cell landing but the fit
and the test after it — `charge_full` at or near design, a low cycle count,
and mains pulled with the host staying up — which
[`replace-the-laptop-cell.md`](runbooks/replace-the-laptop-cell.md) names.
This paragraph pointed at
[`fit-the-ups-battery.md`](runbooks/fit-the-ups-battery.md) until 2026-09-18 —
the rack pack in `mjolnir`, not this cell — which is the same wrong pointer
[#506](https://github.com/Gerrrt/HomeLab/pull/506) corrected in the alert's own
description. `oracle`'s cell, the one that measures worse, stays unbought and
second in line, as that issue ranked it.

**Already paid for and still moving**: the I226 card on its M.2 adapter that a
restore onto `trinity` needs
([#404](https://github.com/Gerrrt/HomeLab/issues/404)) and the pfSense
installer stick — between them, the whole of what the rehearsal now waits on;
the two Exos X20 18 TB drives for `smaug`'s mirror
([#413](https://github.com/Gerrrt/HomeLab/issues/413)); the CRS326 that
replaces `neo` ([#444](https://github.com/Gerrrt/HomeLab/issues/444)). The
A1437 cell for `prometheus` was on this list until 2026-09-18 and is on neither
now: it is fitted ([#454](https://github.com/Gerrrt/HomeLab/issues/454)). The
two SFF drive trays for `Saruman` left it the same day, and took the SM863a
pair off the paragraph above with them — see the 2026-09-18 note below. These
two paragraphs track money that has not yet become a working part, and that
has.

**2026-09-18: the trays arrived and both SSDs are in the bays.** Confirmed at
the bays, as the paragraph above asked: the iLO reports two new drives at
`Port 1I Box 1 Bay 3` and `Bay 4` from 20:11 UTC, with different serials, so
the pair was a pair. Fitted is not finished — the drives are in no logical
drive, nothing has moved to them, and the measurement the purchase exists for
has not been taken; [#418](https://github.com/Gerrrt/HomeLab/issues/418)
carries that. Neither the SSDs nor the trays appear in either paragraph above
now: they are parts, and [`hardware.md`](hardware.md) has them.

- **[#286](https://github.com/Gerrrt/HomeLab/issues/286) Alloy tails the backup
  archiver's tar stream into Loki.** Done 2026-09-04. Found while sizing #114,
  and it is the reason `loki`'s ceiling is 1536M rather than about 512M:
  `backup-volumes.sh` writes each volume's gzip stream to a container's stdout
  and `discovery.docker` tails every container on the socket, so one
  `make backup` put 765 MB of binary through the log pipeline in three minutes
  — roughly three days of the estate's real logs, into a `loki-data` volume
  that is not encrypted where the archives deliberately are.

  **The fix this entry proposed would have broken log collection.** Filtering
  on `__meta_docker_container_label_com_docker_compose_project` and dropping
  what does not carry it reads as the tidy answer, but that label is empty for
  every container on `oracle` — `wiki`, `db` and the agent itself are all plain
  `docker run` — so it would have silently stopped collecting logs for the one
  service in this estate anybody uses. Checked against `container_last_seen`
  across both hosts before writing any of it. What landed instead is
  `--log-driver none` on the archiver runs, so Docker discards the stream at
  source, plus an opt-out label (`homelab.logs=off`) that Alloy drops on before
  opening a stream at all.

  Opt-out is a weaker guarantee than the allow-list this entry wanted, and the
  gap is named rather than papered over: a future throwaway container that sets
  neither flag is still tailed. Bounding *that* is a per-stream ingestion limit
  in Loki, which trades a flood for silently dropped lines and is its own
  decision. `loki`'s `mem_limit` is unchanged until a fortnight without the
  flood exists to re-derive from — 2026-09-18.

## 2026-09-17

**Already paid for and on hand**, as of 2026-09-17: the ProDesk 600 G4 —
`trinity`, the tier's host and the firewall's spare hardware
([#404](https://github.com/Gerrrt/HomeLab/issues/404)); the TS150 NAS and its
boot SSD with the bracket and tape that mount it in the optical bay
([#413](https://github.com/Gerrrt/HomeLab/issues/413)); the 2 TB USB drive
that becomes the photo library's disk on `trinity`; two SM863a SSDs for
`Saruman` ([#418](https://github.com/Gerrrt/HomeLab/issues/418)); and the
removable medium the second age recipient lives on.

**2026-09-17: the trays were bought on 2026-09-11 and are only now written
down.** They were paid for in the same sitting as the I226 card, the Exos pair
and the boot disk's bracket, and unlike every one of those they got no entry in
[`hardware.md`](hardware.md) and no line here. This section's rule is that a
purchase is recorded when the money is spent; six days of silence is that rule
failing, and it was caught by reading a delivery notice for a different issue
rather than by anything this repository does. Nothing here checks the list
against what was actually bought, which is the gap the omission found.

**2026-09-17: the two SM863a SSDs are on hand.** They were delivered
2026-09-11 and carried above as still moving for six days. Delivery is recorded
against the order, which was one order for the pair; that both drives were in
it is not separately proved and is
[#418](https://github.com/Gerrrt/HomeLab/issues/418)'s to confirm at the bays.

- **[#421](https://github.com/Gerrrt/HomeLab/issues/421) Buy `ifrit` and build
  the range** — only after the main network is finished. This entry was keyed to
  [#96](https://github.com/Gerrrt/HomeLab/issues/96) until 2026-09-17, and #96
  closed on the decision and the runbook on 2026-09-04: the purchase it ended
  by naming had no tracker at all for five days, and this file
  went on pointing at the closed issue for another eight after #421 was opened —
  the same shape as #102 → #404 and #95 → #413. The isolation mechanism ADR-0007
  deferred is settled by ADR-0014: `ifrit` is single-homed on ImaginationLAN,
  the targets sit on a bridge with no physical port on a subnet the firewall
  does not route, the attack VM does not forward, and the hypervisor management
  planes close at the host. ADR-0017 settles the rest — buy for IOPS and quiet
  rather than for threads, because the range's whole operation is
  snapshot-and-revert and `Saruman`'s complaint is already spindles; socketed
  RAM, because `prometheus`'s is soldered; `172.30.30.0/24` on the isolated
  bridge with no gateway anywhere on it; and no backups, no monitoring and no
  patching for the guests, so the least important part of the lab joins none of
  the estate's loops. "After the main network is finished" named three issues
  when that sentence was written, and **two of them have closed since**:
  [#234](https://github.com/Gerrrt/HomeLab/issues/234)'s tripwire was armed and
  verified on 2026-09-08, and
  [#235](https://github.com/Gerrrt/HomeLab/issues/235) was decided the same day
  — the iLO stays, [ADR-0033](adr/0033-keep-the-ilo-on-the-lab-segment.md) —
  with the hardening that decision owed done on 2026-09-09. Both are recorded in
  full under *Done* below, which is why this paragraph does not restate them.
  What is left of the gate is
  [#101](https://github.com/Gerrrt/HomeLab/issues/101), and it is an umbrella
  rather than a thing anyone builds: what it means here is the domain
  ([#414](https://github.com/Gerrrt/HomeLab/issues/414)) and the SOC stack
  ([#266](https://github.com/Gerrrt/HomeLab/issues/266) Wazuh and
  [#267](https://github.com/Gerrrt/HomeLab/issues/267) Velociraptor), because an
  attack VM pointed at an uninstrumented estate teaches nothing. This paragraph
  ended "what is left is the purchase itself and the build" until 2026-09-17,
  which read as though the money were the next thing to spend. **The purchase is
  gated on #414 being built, and it is the last purchase on the estate's list,
  not the next** — which is what *Everything still to buy* at the top of this
  file has said since #421 was opened, and what this entry now agrees with
  rather than contradicts.
  → [runbook](runbooks/build-the-playground.md)

- **[#441](https://github.com/Gerrrt/HomeLab/issues/441) Alerted on a sensor
      that stops logging, and closed the Zeek half by deciding it elsewhere.**
      2026-09-17. `SuricataLogsStopped` landed on 2026-09-12 in
      `loki/rules/security.rules.yaml`: `absent_over_time({app="suricata"}[9h])`,
      aggregate across both interfaces, `for: 0s` like the two absence rules it
      copies. The window was read rather than picked — 22 days of the stream, in
      which the longest silence across both interfaces was 75 minutes — which is
      what the issue asked for, because the thirty minutes it opened with would
      have paged about twice a day.

      **Re-measured on 2026-09-17 over 27.7 days and it holds.** Worst aggregate
      silence 80 minutes, six gaps past an hour, none past two, so nine hours
      keeps nearly seven times the headroom `DhcpLeaseLogsStopped` settled on.
      The aggregate design earned its keep in the interval: `igc0.10` alone went
      quiet for more than nine hours **seven times**, worst 47.5 hours, so a
      per-interface rule would have paged seven times in a fortnight. The
      short-gap counts are not comparable between the two measurements — 135
      over thirty minutes here against 54 on 2026-09-12, a difference in method,
      not in Suricata — and the rule's comment says so rather than presenting
      one series.

      **The Zeek half was not built, and will not be as the issue described it.**
      `ZeekLogsStopped` was to be the same shape against the lab's Loki once
      [#437](https://github.com/Gerrrt/HomeLab/issues/437) existed. Three things
      make that the wrong instrument. #437 puts Zeek's logs on `alexander` and
      never on `10.0.99.20`, which ADR-0007 requires;
      [ADR-0020](adr/0020-run-the-lab-stack-in-a-guest-with-its-own-prometheus.md)
      gives that stack no Alertmanager on purpose, and `stacks/lab/loki/` ships
      no ruler and no `rules/` because *"a ruler with nowhere to deliver
      evaluates rules and discards the result, which reads as coverage and is
      not"*; and
      [ADR-0028](adr/0028-let-guest-liveness-cross-but-not-guest-telemetry.md)
      revisited that exact boundary and kept it. #437 already carries the right
      mechanism — a `homelab_zeek_mirror_active` textfile gauge read on the
      hypervisor, crossing as guest state under ADR-0028 — so Zeek's liveness is
      a metric question answered where Zeek is built, and this issue closes
      rather than holding a slot behind a Wave 2 dependency that itself waits on
      [#414](https://github.com/Gerrrt/HomeLab/issues/414).

      What this proves and what it does not, unchanged from the merge: Loki
      rules still have no unit-test harness, so `check_loki_rules.sh` shows the
      rule parses and the ruler evaluates it, not that it fires. The live ruler
      reports it `health=ok` and `state=inactive`, which is the good state and
      not evidence of detection.

## 2026-09-16

**What those boxes actually are was read off them** on 2026-09-15 and
2026-09-16, which this paragraph listed as still owed: the TS150's machine
type-model, serial, CPU and the single DIMM in four slots; the boot SSD's model
and serial and its `smartctl -a` taken **before** the install rather than
after; and `trinity`'s 512 GB SSD, which is an **M.2 stick**, so there is no
2.5" drive carrier and the second M.2 slot is free for the I226 card that was
the thing this sentence was worried about
([#404](https://github.com/Gerrrt/HomeLab/issues/404)).
[`hardware.md`](hardware.md) carries each of them as a reading now rather than
as a debt.

## 2026-09-15

Four things crossed from the second paragraph to the first: the TS150, the
ProDesk, the boot SSD, and the bracket and tape that mount it. All four were
recorded here as **2026-09-15**; the ProDesk's is now **2026-09-14**, from the
carrier's own notice, and the other three are unaudited. They were written in
the same commit, that evening, and dated by UTC after it had turned over — so
the same day may be out by one for each of them. Checking is
[#413](https://github.com/Gerrrt/HomeLab/issues/413)'s, not this section's, and
nothing here depends on which day it was.

**No row on the table above moves** — arriving is not buying, and this section
tracks money. Nothing was racked, fitted or built by it either. What it changed
is one sentence: the two builds stopped waiting on a van for their machines,
and wait only for the parts named above.

## 2026-09-14

- **[#470](https://github.com/Gerrrt/HomeLab/issues/470) The wiki's drift
      check is watched.** 2026-09-14. `Gerrrt/Lemmiwinks/.claude/tools/drift-check`
      reads the wiki's machine-checkable claims against the machine and files a
      wiki issue when they disagree; since the morning of 2026-09-14 it ran
      from `atropos`'s crontab on `oracle` with no metric, which is #400's
      shape — a check that stops looks like a wiki with nothing wrong. Shipped
      as the fifth agent collector: `scripts/collect-drift-check.sh` runs the
      checker as the wiki maintainer's user from a root unit that exists to
      write the textfile directory, records when it ran, how it exited and the
      four claim counts, and `DriftCheckStopped` fires on a timestamp more
      than a day old. The checker stays in the wiki's repository, because its
      claims are that wiki's sentences; this repository watches that it runs.

- **[#468](https://github.com/Gerrrt/HomeLab/issues/468) The backup verifier
      mistook every Loki archive for a Paperless one.** 2026-09-14. Both
      `backup-volumes` and `verify-backups` exited 2 from 2026-09-13, and
      every `loki-data` archive on the host — five sets that had verified clean
      the day before — failed the same line: *this archive carries the
      sentinel of paperless-data*. #133 gave `paperless-data` the sentinel
      `./index`; a Loki data volume has a top-level `./index` of its own, listed
      as a `loki-data` companion two tables down in the same script, and the
      change reached the host with the 2026-09-12 revision. The archives were
      intact; no manifest was written after 2026-09-06 and nothing was pruned.

      Found from the wiki side, by reading the units' journal out of Loki
      (`Gerrrt/Lemmiwinks#279`). The fix keeps `./index` — it is the measured
      marker — and makes `verify()` treat a foreign sentinel that is one of the
      volume's own companions as evidence only when the volume's own sentinel
      is also missing, in `--hot` as well; a Paperless archive mislabelled
      `loki-data` still fails on both counts. `load_inventory()` now refuses a
      table in which two volumes share a sentinel outright, the case
      `verify()` cannot recover from. Applied by hand on the host after merge,
      since converge is report-only; the next Sunday set is the proof.

## 2026-09-13

**2026-09-13: the switch is bought.** A used MikroTik CRS326-24G-2S+RM,
recorded in [`hardware.md`](hardware.md) — bought for the TLS management
interface, which is the one argument the correction on
[#444](https://github.com/Gerrrt/HomeLab/issues/444) left standing, with
[#84](https://github.com/Gerrrt/HomeLab/issues/84) riding along. The table
goes from four rows to three, and nothing on it now touches the rack: two
licences, a drive kept at another address and a battery. What closes #84 and
ADR-0018's residual is a cabling window, not money — `neo` carries every VLAN,
so the swap waits for a rack visit it can share.

Two things left this list because the decision got taken: the **MokerLink
replacement**, now [#444](https://github.com/Gerrrt/HomeLab/issues/444), and
**off-estate storage**, now [#455](https://github.com/Gerrrt/HomeLab/issues/455).
Both moved into the first table above; the switch has since left it by being
bought, on 2026-09-13, and the drive is still there. Neither is deleted from
the record — moving up is what taking the decision looks like, and leaving is
what buying looks like.

- **[#84](https://github.com/Gerrrt/HomeLab/issues/84) Retire the MokerLink
  switch's previous SNMP community.** The rows were overwritten and the
  switch rebooted on 2026-09-12, and the measurement that followed changed the
  issue: `neo` serves GETBULK to *any* community of sixteen characters or
  fewer without checking the table, which is what every earlier sighting of
  the stock `public` and `private` answering had been — and every `STILL
  ACCEPTED` for the old one. Over GET, which it does check, both stock
  strings and a junk string are refused; the previous community's row is
  unverified rather than retired, because the string was not to hand in the
  window and is not recoverable — it was the shared value purged from history.
  So this closes by the hardware leaving, not by a measurement. `snmp-verify.sh`
  probes with GET since that date and sends junk strings over both PDUs weekly,
  `WARN` for the switch. Accepted residual, larger than before and recorded in
  `SECURITY.md`; what closes it is the replacement switch — bought 2026-09-13,
  delivery estimated 2026-09-23 — and the window that racks it, not another
  window on this one. Nothing further is owed on the MokerLink: the overwrite
  §2.5 prescribes was done on 2026-09-12 and persisted. →
  [runbook](runbooks/rotate-snmp-community.md#the-mokerlink-switch-overwrite-the-row)

## 2026-09-11

**2026-09-11 emptied the hardware half of this list.** The two NAS drives, the
boot SSD, the bracket and the double-sided tape that carry it in the TS150's
5.25" optical bay, and the I226 card the firewall rehearsal needs were all
bought that day — the table goes from seven rows to four. Nothing left on it is
a part for a machine: two licences, a switch, a drive kept at another address
and a battery. So **neither [#413](https://github.com/Gerrrt/HomeLab/issues/413)
nor the rehearsal in [#404](https://github.com/Gerrrt/HomeLab/issues/404) is
blocked on money any more** — each is waiting on parts landing and a
build. The tape was never a
row and does not get one now; it is part of the bracket purchase, recorded in
[`hardware.md`](hardware.md) with it, because the rule is that a purchase edits
this section and not that only listed purchases do.

## 2026-09-10

Revised 2026-09-10 against a costed shopping list, which is what the rule above
is for: it found four things this section had wrong or missing — `smaug`'s boot
disk was never listed, two deferred items had been decided, ADR-0017's 32 GB is
not what the candidate machines ship with, and the *Never* line forbade a
battery it was never written about.

**32 GB is a spec the candidate machines do not meet as shipped**, which was
found by pricing them rather than by reading the ADR. The SFF boxes in the
class ADR-0017 describes — ThinkCentre Tiny, EliteDesk Mini and their
relatives — ship with 16 GB in two slots at this price. So a SO-DIMM kit is
**part of that purchase and not a later contingency**, and the bullet below
that used to say otherwise has been corrected. The model, the CPU and the disk
capacity are still chosen at the till and recorded in
[`hardware.md`](hardware.md) afterwards, per the ADR — nothing is named here
before it is bought.

The switch's row was narrower than the bullet it replaced, and deliberately.
That bullet named #84, the switch half of #85 and ADR-0018's residual as three
things one purchase would close;
[ADR-0036](adr/0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md)
has since removed the middle one — the switch answers v3 on the wire and was
never the blocker. **A purchase justified by three residuals when one of them
has gone is the shape this section exists to prevent**, so it was bought for
the TLS management interface, and #84 rides along.

## 2026-09-09

The one list. It exists because purchases kept appearing one at a time in
issues, ADRs and runbooks, and the person paying for them found out about each
by surprise — the sensitive tier's host had no line anywhere until one box had
been bought for two jobs ([ADR-0034](adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)).
Compiled on 2026-09-09 from every ADR, runbook, open issue and document in
this repository. **The rule from here: nothing enters the first list without a
decision the operator made, and a PR that implies a purchase edits this section
in the same commit.**

- **[#85](https://github.com/Gerrrt/HomeLab/issues/85) Move to SNMPv3 authPriv
  where the hardware supports it.** Decided by
  [ADR-0036](adr/0036-poll-the-ilo-and-the-ups-card-over-snmpv3-and-keep-the-firewall-on-bsnmpd.md):
  per poll, by where the poll travels, and mixed on purpose. The iLO first —
  its poll is delivered into the lab segment, layer-2 adjacent to the attack
  VM, so its community is the one an adversary is meant to be able to try for
  — then the UPS card on the same procedure. The firewall stays on v2c
  because bsnmpd is the only daemon that serves the pf MIB and pfSense writes
  no v3 user for it; that was the issue's "three can", checked on the box on
  2026-09-09, and the switch was never what blocked it. The switch stays on
  v2c and its UI gets checked once for a v3 user page — its agent answers v3
  on the wire, which ADR-0018 did not know. The tooling is done: a device's
  version and key names come from its auth block in `generator.yaml`, and
  `snmp-verify.sh` speaks v3. What is left is the device side, one at a time,
  device first — [runbook §4](runbooks/rotate-snmp-community.md#4-move-a-device-to-snmpv3).

- **[#102](https://github.com/Gerrrt/HomeLab/issues/102) Build ADR-0008's
  sensitive tier on VLAN 99.** One box running Vaultwarden, Immich,
  Paperless-ngx and Home Assistant behind Caddy and step-ca, with AdGuard Home,
  ntfy and Homepage alongside. **The box is bought and nothing is built.** It
  is the ProDesk 600 G4 of 2026-09-08, by [ADR-0034](adr/0034-run-the-sensitive-tier-on-the-prodesk-and-make-it-the-spare-hardware.md)
  — the one purchase this tier needed, made under #92's name because the
  tier's host had no issue and no place in the shopping sentence after this
  issue split; [#404](https://github.com/Gerrrt/HomeLab/issues/404) is the tracker it lost. The placement is not the
  outstanding part — ADR-0008 settled it, and
  [ADR-0010](adr/0010-keep-the-resolver-on-the-gateway.md) has since been
  decided on top of it. What is outstanding is the build under #404, the rest
  of a stack, and four firewall rules the ADR counted as two. `stacks/sensitive/`
  exists since 2026-09-09 with its foundation — Caddy as the only published
  port, step-ca as a certificate authority of the tier's own issuing to Caddy
  over ACME — authored ahead of the hardware the way `stacks/lab` was, and
  checked by everything `make validate` runs, `caddy validate` included. The
  foundation first claimed step-ca would be an intermediate beneath the lab
  CA; that root carries `pathlen:0` and cannot have one, which
  [ADR-0037](adr/0037-give-the-sensitive-tier-its-own-root-and-issue-beneath-it-over-acme.md)
  measured before deciding, along with where the root key lives (the
  monitoring host, never `trinity`) and why the leaves are seven days. The
  ACME path was proved on the monitoring host under a throwaway project;
  what remains for [#130](https://github.com/Gerrrt/HomeLab/issues/130) is
  the mint and install on the real host, under #404, and a TLS-expiry rule
  sized for seven-day leaves ([#426](https://github.com/Gerrrt/HomeLab/issues/426)).
  AdGuard Home joined it the same day
  ([#135](https://github.com/Gerrrt/HomeLab/issues/135)), in the shape
  ADR-0010 decided and not the one the service assumes: the blocklist set is
  a tracked file copied in on every start, the admin hash is in SOPS, port 53
  is published on the host's own address and answered for the firewall and
  the blackbox prober only, and the default 20 qps per-client rate limit —
  which would have throttled the whole house through its one client — is
  off. The half on `morpheus` waits for the host:
  [`forward-dns-to-adguard.md`](runbooks/forward-dns-to-adguard.md) is the
  forwarding-mode change below, its verification, and the deliberate-failure
  test ADR-0010 asks for. So did Vaultwarden
  ([#131](https://github.com/Gerrrt/HomeLab/issues/131)) — the service whose
  restore path mattered more than its deployment: `make backup` and
  `make restore` learned the tier's volumes and now encrypt to the stack's own
  recipients rather than the first key in `.sops.yaml`, which is the pair of
  defects [#428](https://github.com/Gerrrt/HomeLab/issues/428) names, and the
  round trip was rehearsed on the monitoring host with a seeded vault before
  the host exists
  ([`restore-the-sensitive-tier.md`](runbooks/restore-the-sensitive-tier.md)).
  Immich followed the same day as well
  ([#132](https://github.com/Gerrrt/HomeLab/issues/132)): four containers
  behind Caddy, pinned by digest, each under a memory limit, booted once on
  the monitoring host to find where the images write. What that landing
  turned up is that the off-estate copy ADR-0023 makes the precondition on
  the first real photo still has no destination — #132 stays open for it.
  Paperless-ngx followed ([#133](https://github.com/Gerrrt/HomeLab/issues/133)):
  the document archive behind Caddy, with a Postgres and a Valkey of its own,
  running as the operator with every capability dropped and a CPU ceiling —
  the estate's first — and its volumes in `backup-volumes.sh`'s sentinel
  table, alongside entries for the foundation's, Home Assistant's, AdGuard's
  and Immich's, which had none; #428's recipient half landed with Vaultwarden
  the same day. Booted from the pinned images before the file was written, on
  the monitoring host, since the tier's is not built; the limits are stated as
  unmeasured on the hardware they are for.

  **ADR-0010 costs more to implement than it reads, measured 2026-09-04.**
  Unbound on `morpheus` is recursive and DNSSEC-validating with zero
  `forward-zone` blocks, so "put AdGuard first in the forwarder list" is a
  resolution-mode change rather than an edit to a list that already exists — and
  it hands a query stream that currently reaches no third party to AdGuard,
  Cloudflare and Google. Worth accepting deliberately when this build happens,
  not by ticking *Enable Forwarding Mode*. The ADR carries the detail.

  **All four are insertions above a deny, and none of them is an addition.**
  ADR-0008 named 50→40 and 99→20 and said the estate's count "rises from three
  to five"; [ADR-0013](adr/0013-segment-access-as-implemented.md) retired the
  count precisely because a number cannot say *where in the order* a rule goes,
  and when these land they belong in that ADR's list rather than in a new total.
  ADR-0016 then read the ruleset and turned 50→40 into three — one on the Hicks
  tab and two on Winterfell's, each above a *Block access to CasaBonita* — and
  #95 carries those with the hardware, because a `pass` to an address with no
  NAS behind it is a rule nobody can test.

  **99→20 was the row nobody had read. It is read now.** `pfctl -sr` on
  `morpheus`, 2026-09-04: Winterfell blocks every other VLAN explicitly above
  its egress pass, *Block access to Skids* (`10.0.99.0/24 → 10.0.20.0/24`)
  among them, so Home Assistant's rule is the fourth insertion and not an
  append. It goes beside the two SNMP passes that already sit above that stack.
  Skids as a source is untouched — it blocks all five other VLANs, carries
  #223's tripwire, then egresses — and the return traffic for a session Home
  Assistant opens is carried by state and never reaches the ruleset. So **Skids
  stops being terminal inbound and stays terminal outbound**, the same trade
  ADR-0016 made for CasaBonita and with the same test: the tripwire's counter,
  zero today, must not move.

  **What the firewall cannot tell you is how wide the rule should be.** The
  other three are host- and port-scoped. This one has a source that does not
  exist yet, and a destination that is a whole segment unless the IoT devices
  are given statics — which would be a segment-wide grant of the kind #228
  exists to close, this time out of Winterfell and into the VLAN whose stated
  assumption is that everything on it is already compromised. Worth settling in
  the same sitting: Home Assistant discovers devices over mDNS, which is
  link-local and does not cross a VLAN boundary, so nothing on 20 appears by
  itself however the pass is written.

  **Settled 2026-09-09, and narrower than the row read.**
  [ADR-0035](adr/0035-scope-the-99-to-20-rule-to-the-hue-bridge.md) read the
  Skids inventory for what Home Assistant would actually open a connection to
  and found one device: the Hue bridge. Ring, the Echos, the HomePods, the
  litter robot and the white-noise machine are all reached through a vendor's
  cloud or not at all. So the pass is `10.0.99.40 → 10.0.20.104:80,443/tcp` —
  the two ports the `aiohue` code uses, 80 once at pairing and 443 after —
  above *Block access to Skids*, and it waits on two things: `trinity`, and a
  Kea reservation for the bridge, because Skids has none and its pool holds
  every address on the segment. **Home Assistant itself is authored**
  ([#134](https://github.com/Gerrrt/HomeLab/issues/134)): the Container
  flavour, no Supervisor and no add-ons, as an ordinary member of the tier's
  network behind Caddy — not `network_mode: host`, which exists for discovery
  that cannot cross a VLAN anyway — booted read-only with every capability
  dropped against the pinned image before it was committed. Its credentials
  are the one place the tier steps outside SOPS, and the ADR says why. No
  USB radio, so where the box sits is not this service's concern.

  **Two of the three things said to be waiting on this tier are not waiting on
  it.** [#67](https://github.com/Gerrrt/HomeLab/issues/67)'s watcher went to
  `oracle` under ADR-0015 and needs no self-hosted ntfy;
  [#97](https://github.com/Gerrrt/HomeLab/issues/97)'s host override was never
  downstream of AdGuard, which ADR-0018 says outright and ADR-0010 is the reason
  for. [#98](https://github.com/Gerrrt/HomeLab/issues/98) is the one that
  stands — there is no eero integration until there is a Home Assistant. What
  moving ntfy in-house *does* change is the alert path: the heartbeat's whole
  value is that it leaves the house, and an endpoint on a network with no
  external exposure cannot reach a phone that is not on it. Whether the
  in-house ntfy replaces the external topics or sits beside them is a decision
  this build makes, not a detail of it.

  **One of the four services arrives with monitoring already written for it.**
  [#126](https://github.com/Gerrrt/HomeLab/issues/126) shipped the DNS probes
  and rules that catch a silently-dead AdGuard, with the two targets disabled in
  `stacks/observability/prometheus/targets/blackbox-dns.yaml` because there is
  nothing to probe yet. Uncommenting them is part of this build, not a separate
  task: the file carries the address assumption to correct — `10.0.99.40`, the
  next free reservation — and the two commands to verify the probes against the
  running exporter, including the negative one, since a filtering probe that
  cannot go red is measuring nothing. Blocking mode has to be Default/Null IP,
  which the module pins deliberately.

  **Two purchases where the plan assumed zero, and this is the first.** `oracle`
  cannot host it — ADR-0015 measured 2549 MiB available behind a 5400 rpm disk
  and a 100 Mb/s NIC — and ADR-0007 keeps household services off the lab
  hypervisor. The SSO this box deliberately does not get is
  [#103](https://github.com/Gerrrt/HomeLab/issues/103), and as of
  [ADR-0022](adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md)
  it does not get it *until this box holds real data* rather than indefinitely —
  which puts two things on this build: TOTP enrolled on the three services that
  can carry it, and a disk encryption decision made here rather than inherited.

## 2026-09-08

- **[#110](https://github.com/Gerrrt/HomeLab/issues/110) Racked the shelf
      switch in U4, on UPS power.** 2026-09-08. The 1U vented shelf, the
      TP-Link that `prometheus` and `oracle` hang off moved onto it with its
      uplink back on port 3 of `neo`, and its power onto a UPS-fed outlet —
      the step that actually closes the gap, since a relocated switch on a
      wall socket is tidier and no better protected. The two laptops now keep
      their network on a mains cut as well as their batteries, which is what
      #93's pack was always half of. Bought with that pack on 2026-08-27 and
      closed the same day by a commit message that quoted "closes #110" —
      twice, the second time by the commit documenting the first — while every
      document said the shelf was on hand and not racked; reopened 2026-09-08
      and done the same afternoon.

- **[#234](https://github.com/Gerrrt/HomeLab/issues/234) Armed the lab
      tripwire on ImaginationLAN.** 2026-09-08. The firewall rule arrived on
      2026-09-06 with the untagged-LAN blocks, pointed at `Internal_Segments` —
      which names the lab's own subnet — and logged 1,239 DNS queries to the
      lab gateway in three days and nothing else. Moved to a `House_Segments`
      alias (every segment but 30) on 2026-09-08: sixteen minutes later the
      rule showed 26 evaluations and 0 packets, the lookups still reaching it
      and no longer matching. `LabSegmentReachedInternalNetwork` reads VLAN 30
      as a source and excludes it as a destination, so it was right through
      the noisy days and fired on none of them; the restore runbook expects
      four tripwires and checks the lab's alias by name; the security dashboard
      charts the lab boundary beside the terminal one. Loki rules still have no
      unit-test harness, so the rule is proven to parse and evaluate, not to
      fire — the 1,239 lines were, accidentally, the proof for its source half.

- **[#235](https://github.com/Gerrrt/HomeLab/issues/235) Decided: the iLO
      stays on the lab segment.** 2026-09-08.
      [ADR-0033](adr/0033-keep-the-ilo-on-the-lab-segment.md). `shiva` is the
      BMC of the box being attacked, and a BMC compromise in the lab costs the
      lab; that is accepted and recorded in `SECURITY.md`. Two facts the issue
      predated settled it: since ADR-0031 a workstation reaches Winterfell on a
      named list, so a BMC there would need three more Hicks passes for its web
      UI and console — the issue's "console access unchanged" no longer held —
      and the management segment should not accumulate a device whose firmware
      line has ended. What follows is hardening on the iLO itself, by hand, and
      one firewall follow-up: the `10.0.30.10 → 10.0.99.20/udp` "return path"
      rule is redundant with pf state and is the BMC's only path to Alloy's
      syslog listener, so it goes. Both done 2026-09-09: the rule deleted with
      the scrape watched through it — one failed scrape at the reload, clean
      since, zero packets ever matched — and the BMC hardened.

- **[#228](https://github.com/Gerrrt/HomeLab/issues/228) Decided: Hicks
      reaches management on a named list, and reaches the lab entire.**
      2026-09-08. [ADR-0031](adr/0031-narrow-hicks-to-a-named-list-on-winterfell-and-leave-the-lab-open.md).
      Option 3 with the enumeration done: ten host- and port-scoped passes into
      Winterfell — SSH, the pfSense UI, DNS, NTP, ping, the wiki, Grafana, the
      UPS card — above a logged *Block access to Winterfell*, applied on
      `morpheus` 2026-09-02 and read back for the ADR on 2026-09-08 (28 packets
      dropped by the block, about two million passed by SSH alone). `50 → 30`
      stays wholesale by a rule on the Hicks interface, because ADR-0014
      consumes it and the list that would narrow it does not exist until the
      lab does. Two deviations recorded rather than tidied: the lab pass is
      TCP-only, and the DNS/NTP passes to `10.0.99.1` carry nothing. The
      Winterfell half had been on the firewall for six days before any
      document called it a decision — `architecture.md` still described the
      catch-all — which is the gap this entry closes.

## 2026-09-06

- **[#153](https://github.com/Gerrrt/HomeLab/issues/153) Decided: the
      documents stay hand-written, and are checked where the truth is.**
      2026-09-06. [ADR-0026](adr/0026-check-the-documents-where-the-truth-is.md).

      **The answer was already built and never recorded.** #153 offered three
      ways to close — adopt a tool, write a CI cross-check, or accept
      hand-maintenance and say why — and `check_docs.py` landed on 2026-08-26,
      the same day the issue was filed, following the pattern
      `snmp-targets.sh --check` set on 2026-08-17. It now carries seven
      assertions. So the middle option won by default and nothing said so, which
      is the state #153 warned about in its own last line: *"leaving it
      undecided is what produced the list at the top."*

      No discovery tool. NetBox is, as the issue says itself, "a source of truth
      you maintain, not a discovery tool" — it moves the hand-maintenance rather
      than removing it, and brings a Postgres-backed Django app for four SNMP
      devices. Scanopy is closer to the want and worse for this estate: a
      discovery tool that can see every VLAN is by construction a device that
      violates the segmentation model.

      **The residual is prose about the firewall, and this session produced two
      instances of it in one day** — ADR-0013's stale claim
      ([#344](https://github.com/Gerrrt/HomeLab/issues/344)) and the correction
      for it asserting something that had been false for four days
      ([#229](https://github.com/Gerrrt/HomeLab/issues/229)). Both passed
      `check_docs.py` correctly: it has nothing to compare them against, because
      `config.xml` carries rule bodies, the WAN address and password hashes, and
      `backup-firewall.sh` explains at length why that stays out of the
      repository. Committing it so CI could read it would trade a documentation
      defect for *"one age-key compromise hands over the complete blueprint"*.

      So the firewall wants a deploy-time check rather than a CI one, in the
      family this estate already has — `check_loki_coverage.py`,
      `check_alert_channels.py --live`, `check_versions.py`,
      `check_mounted_config.py`. Tracked as
      [#363](https://github.com/Gerrrt/HomeLab/issues/363).

- **[#229](https://github.com/Gerrrt/HomeLab/issues/229) The switch LAN's
      default-allow was replaced four days before anyone wrote it down.**
      2026-09-06. Read off `pfctl -sr` rather than taken from the issue: the
      interface carries six logged blocks — one per VLAN — above an egress rule
      renamed *Allow internet*, with DNS and NTP to the gateway the only passes
      above them. Exactly the shape #229 proposed, done on **2026-09-02**,
      datable because pfSense rule identifiers are creation timestamps.

      **This corrects a claim I introduced an hour earlier.** ADR-0025 and three
      places in `network.md` said the switch LAN "still reaches every segment
      outbound". That was ADR-0013's claim carried forward without being checked,
      restated with a "still" that turned a quotation into a fresh assertion —
      which is the exact failure mode ADR-0025 exists to fix, committed while
      fixing it. `security.md` said the same. All four corrected, and ADR-0025
      carries the correction rather than a quiet edit, per ADR-0001.

      **One residual, latent rather than live.** The stock *Default allow LAN
      IPv6 to any* rule is still there with no IPv6 blocks above it, while every
      other interface carries paired `inet`/`inet6` blocks — the 2026-09-02 work
      was IPv4 only. `igc0` has only a link-local address, which does not route,
      so nothing can use it today. Worth closing when IPv6 is decided
      ([#353](https://github.com/Gerrrt/HomeLab/issues/353)).

- **[#152](https://github.com/Gerrrt/HomeLab/issues/152) The estate knows how
      far behind its own packages are — on one host.** 2026-09-06. Images are
      tagged, digest-pinned, CI-enforced and Dependabot-bumped; the kernel
      underneath was patched when somebody remembered.

      **Cheapest thing that closes the gap, which is what the issue asked for:**
      *"the point of the issue is the gap, not the tool. A four-host estate
      probably wants the exporter, not another web UI."* No new service, no new
      image, and **no root** — `/usr/lib/update-notifier/apt-check` runs
      unprivileged, `/var/run/reboot-required` is a world-readable flag, and the
      textfile directory is already owned by the user the timers run as. That
      matters because every richer option wanted privilege the job table does not
      have (#339, #351).

      Two rules. `SecurityUpdatesPending` is **security** updates only, not all
      pending upgrades — a host three ordinary packages behind is not a finding
      and alerting on it is how this becomes noise. Its `for: 7d` is load-bearing
      rather than cautious: unattended-upgrades applies security updates on its
      own, so anything still pending after a week is held, phased or waiting on a
      reboot. `RebootRequired` waits three days, because rebooting this host
      blinds the estate and the alert is a reminder rather than an instruction.

      **A test fixture taught me something about the rules I had just written.**
      The first firing case used samples an hour apart and failed with `got:[]`
      against a correct rule: an instant vector only looks back 5 minutes, so an
      hourly fixture is stale for 55 minutes of every hour and the `for` clock
      resets each time. Production is unaffected — the collector writes daily but
      the textfile is scraped every 60s — and the fixture has to imitate the
      SCRAPE interval, not the collection interval.

      **It covers this host alone, and that is written down rather than implied.**
      `oracle` is Ubuntu and would need it shipped by `deploy-agent.sh`;
      `Saruman` is Proxmox and the same; `morpheus` is FreeBSD with no apt at
      all. Tracked in [#360](https://github.com/Gerrrt/HomeLab/issues/360).

- **[#193](https://github.com/Gerrrt/HomeLab/issues/193) Alloy reaches the
      Docker API through a read-only proxy.** 2026-09-06. The socket is no longer
      mounted into Alloy at all.

      `:ro` on a socket mount is close to decorative — it applies to the socket
      FILE, not the API behind it, and anything that can talk to that API can
      `POST /containers/create` with `/` bound read-write, which is root on this
      host and the age key with it. #188 took Alloy's capabilities and closed the
      direct read off `/rootfs`; this closes the larger half.

      **Proven, not assumed.** Through the proxy,
      `POST /containers/create` returns `403 Forbidden` and
      `GET /containers/json` works.

      **The allowlist was wrong on the first attempt, and only measurement found
      it.** `discovery.docker` calls `/networks` to compute the network labels it
      puts on every target, so with `NETWORKS: 0` the component failed with a
      403, container log collection stopped entirely, and *the agent stayed
      healthy while cAdvisor carried on unaffected* —
      `loki_source_docker_target_entries_total` sat at 0 and nothing else looked
      wrong. That is exactly the #62/#63 shape #193 predicted for a too-narrow
      allowlist and the reason it insisted on before/after numbers. With
      `NETWORKS: 1` the flow resumed: 864 entries streamed, 450 lines in two
      minutes.

      Before and after on this host, cAdvisor unaffected throughout:
      `container_last_seen` 10 → 11 (the proxy is a container),
      `cadvisor_version_info` 1 → 1, and the named set unchanged apart from the
      proxy arriving and two of my own throwaway test containers leaving.

      **One container is deliberately not `read_only`,** which is the exception
      #186 asked to have recorded rather than skipped. The image generates
      `haproxy.cfg` from its environment at every start, and a tmpfs over that
      directory shadows the template it ships — both observed by running it, not
      predicted. It still drops every capability, takes `no-new-privileges`,
      holds no secret, and publishes nothing.

      Said plainly in `SECURITY.md` and `docs/security.md`: this **moves** the
      trust boundary rather than removing it. The proxy holds the socket now.
      What it buys is that Alloy — network listener, rootfs mount, largest
      surface in the stack — has no path to POST.

      `oracle` still mounts the socket directly. `docker.alloy` reads
      `DOCKER_API` and falls back to the socket when unset, so one config file
      still deploys to every host and that one keeps working until it gets a
      proxy of its own.

- **[#344](https://github.com/Gerrrt/HomeLab/issues/344) ADR-0013's title
      became half false; ADR-0025 supersedes it.** 2026-09-06.
      `Gerrrt/Lemmiwinks#177` added a logged block from Winterfell to
      `10.7.7.0/24`, so default deny now holds there with SNMP as the one pass
      above it — the exact thing ADR-0013 said the switch LAN lacked.

      **The issue declined to fix it because "superseding versus amending is a
      call for whoever owns the decision record". ADR-0001 already makes that
      call:** *"ADRs are immutable once accepted. A decision that changes gets a
      new ADR that supersedes the old one, and the old one is marked Superseded
      rather than edited."* ADR-0002 → ADR-0013 is the precedent, and its
      Superseded note is careful to say which claim fell — ADR-0013's now does
      the same.

      A note would have been the wrong instrument. ADR-0013 already carries one
      for a table row added later, which is right for a table gaining an entry;
      a *title* that has become false is not that.

      Read off the firewall rather than taken from the issue: `pfctl -sr` shows
      the block as rule 174 with the interface catch-all at 175, and the SNMP
      pass above at 159.

      **That reading also found a hole the issue only suspected.** The
      `10.0.99.20 → 10.7.7.2:80/tcp` pass, added to keep the `switch-ui` blackbox
      probes alive while the block landed, is still on the firewall — and those
      probes were removed in
      [#343](https://github.com/Gerrrt/HomeLab/pull/343). Verified there is no
      consumer: nothing probes `10.7.7.2`, and `targets/blackbox.yaml` names it
      zero times. Removing it is a firewall change on the Lemmiwinks side and is
      recorded in ADR-0025's consequences rather than silently left.

- **[#355](https://github.com/Gerrrt/HomeLab/issues/355) A deploy no longer
      reports success over a stale config.** 2026-09-06. Found the same day, when
      #166 deployed clean — `make converge` fine, `make up` fine,
      `reload-config.sh` reporting `reloaded prometheus`,
      `check_container_health.py` reporting prometheus healthy — and its three
      latency targets never appeared. Prometheus was running the previous config.

      `compose.yaml` bind-mounts four config files individually, and a
      single-file bind mount is pinned to the inode. `git merge` writes a
      temporary file and renames it over the target, so the container keeps the
      old inode and `POST /-/reload` returns 200 having faithfully re-read the
      pre-merge bytes. `docker compose up -d` recreates a container only when its
      service definition changes, so a config-only commit recreates nothing and
      the stale mount survives — which is most changes here. It went unnoticed
      until #166 only because the deploys before it happened to change
      `compose.yaml` too (#187, #330, #186) and recreated everything.

      `reload-config.sh` already knew this shape: it records that
      `render-config.sh` truncates with `>` to keep the inode, and that
      write-temp-then-mv "would leave the mount pointing at the old inode". That
      covers the files this repository writes. It never covered the files git
      rewrites, which is every committed config.

      **Bytes, not inodes**, which is a change from what the issue first
      proposed. Comparing inodes detects this one mechanism and cries wolf on
      another: a file rewritten with identical content has a new inode and
      nothing wrong with it. Verified — after restoring the original bytes
      through a fresh inode, the content check correctly reported a match where
      an inode check would have reported staleness. Comparing bytes also works
      on `loki`, whose distroless image has no shell at all, because `docker cp`
      needs neither a shell nor `/proc`.

      `make up` runs it with `--fix`, before the reload rather than after,
      because the reload is not what is broken. It recreates only the services
      that actually diverged and then asserts the recreate worked, so a
      force-recreate that rebound nothing cannot report success.

      Reproduced end to end rather than reasoned about: `blackbox.yaml` rewritten
      the way git does it, the check failing and naming the service, `--fix`
      recreating it, and the new bytes confirmed inside the container. The live
      stack was restored afterwards and its eleven probes re-verified.

- **[#166](https://github.com/Gerrrt/HomeLab/issues/166) Measure latency, and
      say where it is.** 2026-09-06. Three targets, a `blackbox-latency` job and
      two rules, so the estate can answer the question #166 opened over — *"is
      the internet bad right now, and is it us or the ISP?"*

      **`tcp_connect`, not ICMP.** #166 called `NET_RAW` "the one wrinkle". Since
      it was written, blackbox-exporter gained `cap_drop: [ALL]`, uid 65534 and a
      read-only root filesystem (#187, #330, #186) — so an `icmp` module would
      hand exactly one container back a capability the rest of the stack just
      gave up. A TCP connect is also the better measurement, not merely the
      cheaper one: ISPs routinely deprioritise ICMP, so a ping time is not what a
      game or a call experiences.

      **Thresholds measured, not chosen.** Twelve samples each from `10.0.99.20`:

      | target | min | median | max |
      | --- | --- | --- | --- |
      | `10.0.99.1:53` | 0.40 | 0.52 | 0.66 ms |
      | `1.1.1.1:443` | 8.01 | 13.66 | 16.13 ms |
      | `8.8.8.8:53` | 7.72 | 13.71 | 28.72 ms |

      10 ms for the gateway is twenty times its median; 100 ms for the anchors is
      seven times theirs and well clear of that 28.72 outlier — which is exactly
      what an instantaneous threshold would have fired on. Both rules average
      over ten minutes and then wait ten more, because #166 asked for precisely
      that: *"a probe that alarms on one bad RTT will alarm constantly and be
      muted within a week"*. A unit test holds a single 500 ms sample and
      requires silence.

      Two anchors on different networks, and two rules rather than one, because
      the diagnosis is the point: gateway slow means the house, anchors slow with
      the gateway fine means beyond it, one anchor slow means that provider.

      **A separate job**, like `blackbox-dns` and for a related reason:
      `EndpointUnreachable` is critical and routes to `urgent`, and an ISP blip
      reaching `1.1.1.1` is not a 2 a.m. page.

      **The second half of #166 is answered rather than built.** It asked whether
      pfSense's own `dpinger` was absent from Loki because monitoring was off,
      logging was off, or the syslog selector excluded it. Asked the firewall
      directly: `dpinger` is running, `WAN_DHCP` reports 12.486 ms / 0.0% loss to
      `1.1.1.1` — which independently corroborates the 13.66 ms baseline measured
      from this host — and it logs to syslog only on a state change, so a stable
      gateway writes nothing. Nothing was broken; there was nothing to ship.

      That same command found `WAN_DHCP6` **down at 100% loss**, which nothing in
      the estate knew. Filed as
      [#353](https://github.com/Gerrrt/HomeLab/issues/353), deliberately without
      a fix: nothing in the documents mentions IPv6 at all, so whether it is
      wanted has to be decided before it is repaired.

- **[#151](https://github.com/Gerrrt/HomeLab/issues/151) SMART on the drives
      that matter, with no new collection.** 2026-09-06. The issue asked to
      choose between Scrutiny and `smartctl_exporter`. Working it turned up that
      **the disks it said mattered most were already being scraped.**

      `Saruman`'s two SAS drives sit behind an HPE Smart Array, and the `ilo`
      module already walks `1.3.6.1.4.1.232.2`. `cpqDaPhyDrvSmartStatus` was
      there all along, reading `ok(2)` for both. It had no rule.

      The distinction is the whole issue. `IloHardwareDegraded` already reads
      `cpqDaPhyDrvCondition > 2` — the drive's CURRENT condition, which moves
      once redundancy is spent. `cpqDaPhyDrvSmartStatus` is SMART's PREDICTION,
      and it moves while the array still says everything is fine. On a RAID 1
      mirror that gap is exactly what #151 was worried about: the mirror keeps
      serving reads through a dying disk, and the failure only becomes visible
      when the second one goes.

      Enumeration read out of `cpqida.mib` rather than assumed, in HPE's own
      words: `replaceDrive(3)` is *"a S.M.A.R.T predictive failure error"*,
      `replaceDriveSSDWearOut(4)` is approaching the write limit, and `other(1)`
      is the agent being unable to determine anything.

      Two rules, because "replace this drive" and "I can no longer tell" want
      different actions. `IloDrivePredictiveFailure` is `> 2` and **warning, not
      critical** — `IloHardwareDegraded` is critical because redundancy is
      already spent, this fires before that, and paging at the same level for
      both would make the critical one mean less. `IloDriveSmartUnreadable` is
      `== 1` with `for: 1h`, so a controller initialising does not page, and so
      the predictive check cannot go blind quietly — the #63 shape.

      Five test cases, including `ok(2)` staying quiet (both drives read 2
      today, so without it the rule would pass its test while firing for a
      healthy array) and `other(1)` staying quiet for the predictive rule, which
      is what stops someone widening it to `!= 2`.

      **The rest of the estate is still unwatched and that is
      [#351](https://github.com/Gerrrt/HomeLab/issues/351).** Neither option
      #151 proposed fits any more: Scrutiny is a service with its own datastore,
      which ADR-0004 argues against, and `smartctl_exporter` as a container needs
      raw device access — it would be the one container reversing `cap_drop`,
      non-root and `read_only` all at once, to read something the host reads for
      free. The fit is node_exporter's textfile collector, and the catch is that
      it needs root while every timer in the `JOBS` table runs as `robo`.

- **[#214](https://github.com/Gerrrt/HomeLab/issues/214) Catch a broken
      notification path without using it.** 2026-09-06.
      `scripts/check_alert_channels.py`, in three parts, because the question has
      three different homes.

      The failure it exists for: 471 of 493 notifications failed over ten and a
      half hours on 2026-08-31, every receiver at once, because all four read
      their URL from the same directory and it was unreadable inside the
      container. `AlertmanagerNotificationsFailing` fired correctly and could not
      be delivered — the alert about the broken delivery path travelled the
      broken delivery path. `IloBatteryCondition` was firing and undeliverable
      through the whole window.

      **The static half now runs in CI**, which is the part that was missing.
      `render-config.sh` already asserted that every `url_file` has a matching
      `AM_CHANNELS` entry, but only at render time on the monitoring host — so
      "added a receiver, forgot the renderer" failed a deploy rather than a pull
      request. That half needs no secret and no host, so it is pure text and it
      gates a PR. It checks both directions: a `url_file` nothing renders is the
      #214 failure waiting to happen, and a rendered file nothing reads is a
      secret written for no reason.

      `--files` adds **non-empty**, which the existing assertion did not. A SOPS
      key that is present but blank renders zero bytes, passes an `-f` test, and
      makes Alertmanager POST to the empty string.

      `--live` is the one that would actually have caught #214, and it is the
      reason this is a check rather than an alert: it asks what the CONTAINER
      can open, because there the files were present on this host and absent
      inside the container. `make up` runs it after every deploy.

      Deliberately does not ask Alertmanager whether it is healthy, and
      deliberately sends no test notification. A check that depends on the
      delivery path inherits the blind spot that made this last ten hours. Every
      assertion reads a file. The dead man's switch is the other half of the
      answer; it was armed and then tripped on purpose on 2026-09-09 — #288.

      All three failure paths were exercised rather than assumed: a `url_file`
      with no renderer, a rendered-but-empty file, and a container that cannot
      see one. The `wc -c` probe returns 1 on a missing file, so the checker
      reports it rather than crashing on empty output — checked, because that
      branch is the one that runs on the bad day.

- **[#341](https://github.com/Gerrrt/HomeLab/issues/341) Loki is not losing
      log data.** 2026-09-06. The issue — which I filed — said Loki was
      discarding ~185,000 entries a week. Both halves of that were wrong.

      **The arithmetic.** It summed `max_over_time` of a *cumulative* counter
      over 7 days, which includes everything accumulated before the window.
      113,630 of the 146,867 predated it. The true in-window increase was 33,237,
      in a single event.

      **The conclusion.** Every discard was an Alloy restart replaying history,
      in three flavours of one event: `greater_than_max_sample_age` is the docker
      source re-reading a container's log from the start — oracle's `db` has been
      up nine months, so the replay carried an entry stamped 2026-08-11 against a
      168h limit; `too_far_behind` is the journal source replaying its 24h
      `max_age` against a stream already current; `rate_limited` is the same
      replay arriving faster than Loki's default ingestion limit.

      The timings settle it. oracle's agent started 02:37:07 on 09-04 and Loki
      logged its rejection at 02:38:21; this host's started 02:54:07 and its
      rejection landed at 02:54:15. The replayed entries are duplicates already
      in the store, so nothing was lost — Loki refusing them is the system
      working. Nothing has moved since: `greater_than_max_sample_age` flat for
      two days, `rate_limited` zero over 15m, 1h and 3h.

      `LogEntriesDropped` is reshaped around **duration rather than reason**. It
      previously excluded `too_far_behind` by name, which was the wrong axis: it
      silenced one flavour of a benign event, left the other two to page after
      every deploy, and would have hidden a genuine persistently-behind stream.
      A restart burst keeps `rate()` positive for the drain plus fifteen minutes;
      `for: 1h` cannot be satisfied by that and is satisfied by loss that keeps
      happening, so every reason stays in scope.

      The regression test took two attempts to be worth anything. A single-step
      fixture passes under both forms — the rate from one step is positive for
      exactly the window length, one minute short of `for: 15m`. The committed
      fixture climbs over six minutes, which is what a real replay does, and it
      fails at `for: 15m` and passes at `for: 1h`.

- **[#249](https://github.com/Gerrrt/HomeLab/issues/249) Watch the UPS
      self-test schedule.** 2026-09-06. `#93` set `mjolnir` to test itself every
      fortnight and nothing in the stack could see that setting, so the control
      keeping `upsTestResultsSummary` meaningful was itself unmonitored.

      **The vendor MIB turned out not to be the cost the issue expected.** #249
      framed adding PowerNet as "a pinning decision, not a URL" — Schneider
      distribute it as a versioned download rather than a git ref, so the
      options looked like vendoring 2.2 MB into the tree or trusting a moving
      vendor path. Neither was needed: the observium commit this repository
      **already pins** for UPS-MIB carries `mibs/apc/PowerNet-MIB` too. The line
      added is a path against an existing pin, inheriting its argument unchanged.

      One subtree, `1.3.6.1.4.1.318.1.1.1.7.2`, never the enterprise root — the
      `pfTablesAddrTable` lesson one vendor along. Measured against the live
      card: 7 rows, 2 GETBULKs, 0.07s to walk, and end to end the scrape goes
      from 3 packets / 51 PDUs / 56 series to 4 / 58 / 63.

      Two rules, and they are a pair on purpose. `UpsSelfTestScheduleOff` is the
      fast signal, true the moment the card reads `never(5)`;
      `UpsSelfTestStale` is the backstop for a card that says it is scheduled
      and is not. Either alone leaves half the failure.

      The enumeration was read out of the MIB rather than assumed, because an
      older PowerNet enumeration stopping at `twelveWeeks(7)` is in circulation
      and would read this card's `8` as out of range — the real definition runs
      to `fiftytwoWeeks(12)`. A unit test pins `8` as quiet for exactly that
      reason: a rule that fired for the estate's correct setting would be worse
      than no rule.

      `UpsSelfTestStale` counts distinct series over 21 days rather than using
      `for:`, because `upsAdvTestLastDiagnosticsDate` is a DisplayString and
      snmp_exporter renders it as a value-1 gauge carrying the date as a label —
      so "the date changed" is "a second series appeared", and no date parsing
      is needed. It is gated on `up{job="snmp"}` because a dead exporter
      produces no new series either and would otherwise read as a card that
      stopped testing.

      **`tests/ups.test.yaml` did not exist**; nine rules were syntax-only,
      which is the standing #63 objected to. It does now, with seven cases
      covering both new rules — including the dead-exporter trap and the
      long-schedule case that stops someone tidying the expression into
      `<= 5 or >= 10`.

      **A false positive shipped with it and was caught on the live stack twenty
      minutes later.** `UpsSelfTestStale` fired immediately on deploy: a metric
      that has just appeared has exactly one distinct value by construction, so
      "one date in 21 days" was true with one sample in the window. The rule is
      now also gated on `present_over_time(...[1d] offset 20d)`, so the count
      only means what it claims once there are twenty days of history, with a
      regression test. The cost is stated: it says nothing for the first twenty
      days after the metric appears or after a Prometheus wipe, which is correct
      because before then there is genuinely no evidence.

      Still outstanding and not a monitoring question: the proof the schedule
      *runs* rather than merely being set is the date advancing with nobody at
      the card, due around 2026-09-11. As of 2026-09-06 it still reads
      `08/28/2026`. `UpsSelfTestStale` is now what will say so if it does not.

- **[#194](https://github.com/Gerrrt/HomeLab/issues/194) The journal is not
      under-delivered; the measurement was.** 2026-09-06. The issue reported
      Alloy shipping ~1.5% of the host journal. It ships all of it.

      The 1.5% came from `{job="/var/log/journal"}`, and the stream carries
      `job="loki.source.journal.journal"` — Alloy overrides `job` with its own
      component name, so the configured value survives only on `component`. The
      query counted one label set and missed the other. #194's own last "worth
      checking" bullet asked whether the count compared like with like; it did
      not.

      Compared like with like — `journalctl --output=json` entries against Loki
      entries over identical windows — delivery is **100%** (6/6 over 10m, 59/59
      over 1h, 2581/2581 over 6h) and was **98.8%** on 2026-08-31, the day the
      issue measured 1.5%: 28,801 of 29,154 entries. An hourly reconstruction of
      that day matches the host almost exactly once the `count_over_time[1h]`
      one-hour stamp offset is accounted for.

      **What the search did find**, and the reason the issue was worth working
      rather than closing: Loki had been discarding around 185,000 entries a
      week and nothing said so —
      `greater_than_max_sample_age` 146,867, `too_far_behind` 26,398,
      `rate_limited` 11,704. Tracked as
      [#341](https://github.com/Gerrrt/HomeLab/issues/341); the root cause wants
      splitting by source before any limit is changed.

      #194's second acceptance box — "if the journal is genuinely
      under-collected, something detects it" — is closed by two rules in
      `stack.rules.yaml`, both with paired firing and quiet unit tests.
      `LogEntriesDropped` fires on any rejection, with no tolerance band,
      because a dropped line is evidence that no longer exists — except
      `too_far_behind`, which is excluded and which is the difference between a
      usable alert and one that fires on every deploy. An Alloy with no position
      file replays up to 24h of journal on start and Loki rejects nearly all of
      it against a stream that is already current: +19,490 discards from one
      agent start, measured while testing #186. Those entries are duplicates the
      previous agent already delivered. The cost of the exclusion, stated: a
      stream persistently behind rather than briefly replaying is real and this
      will not see it — that is the other half of #341.
      `JournalSourceStopped` asserts `== 0` rather than a tuned threshold, and
      that is only honest because the quietest host was measured: `Saruman`
      reads 3.1 entries an hour at its slowest over 24h, against 37.6 here and
      70.2 on `oracle`. The quiet test fixture is deliberately as slow as
      `Saruman` really is, so a rule written as `< 5/hour` would fail it.

- **[#309](https://github.com/Gerrrt/HomeLab/issues/309) Check shiva's iLO
      firmware against the documents.** 2026-09-06. `check_versions.py` grows an
      `OUT_OF_BAND` table for devices that have a checkable version but are not
      hosts, and `shiva` is its only entry.

      A table rather than a third bespoke comparison, which is what #309 asked
      for and the reason is arithmetic: `morpheus` already needs its own
      extraction because pfSense packs two versions into one string, this is the
      second, and a fourth is how a script ends up unreadable.

      The generic parser genuinely cannot do it. `os_key()` takes the first word
      as the family and the first number as the version, so
      `'Integrated Lights-Out 4 2.82 Feb 06 2023'` becomes `('integrated', '4')`
      against the document's `('ilo', '2.82')` — both halves disagree, and the
      running side is wrong in the way that matters, because the `4` is the iLO
      generation and `2.82` is the firmware.

      Proved it can fail, not just pass: with `network.md` edited to `iLO 2.79`
      it exits 1 with *"says shiva runs 'iLO 2.79'; sysDescr reports 2.82"*, and
      with an unreadable cell it says so rather than passing quietly.

      `neo` stays out, and the reason changed underneath the issue: #309 said the
      switch answers no `sysDescr`, and #310 gave it one. The answer is the
      literal string `"Switch"` — no version — so there is still nothing to
      compare, and a row would produce a permanent SKIP.

- **[#339](https://github.com/Gerrrt/HomeLab/issues/339) Fail when a
      declared timer is not actually installed.** 2026-09-06. `make
      check-timers` now asks `systemctl is-enabled` for every job in the `JOBS`
      table and fails naming the ones that are not.

      Found while landing #335, and the finding was not the new job:
      **`check-versions` had been declared since #292, had a correct unit file,
      and had never been installed.** The weekly documented-versions check
      simply never ran, for two weeks, and nothing said so.

      Nothing *could* say so. `ScheduledJobNeverRan` is exactly the rule for
      "declared but never ran" — `max_age unless on(homelab_job) last_success` —
      and `max_age` is written by `--install`. A job added to the table and
      never installed has NEITHER series, both sides of the `unless` are empty,
      and there is nothing to alert on. The alerting was keyed on the installed
      state while the table is what a pull request reviews, so a row merged
      green and the job did not exist. Checks 1-5 compare the table against the
      `.timer` files, which were present and correct throughout.

      Read-only — `systemctl is-enabled` queries and changes nothing — so it is
      safe inside `make validate`. It can only mean something on the deployment
      checkout, so elsewhere it goes through `skip_offhost()` for the same
      reason check 5 does: a CI runner failing because it has not installed the
      monitoring host's timers would be nonsense. The header comment claiming
      "there is exactly one" such skip was corrected in the same commit.

- **[#335](https://github.com/Gerrrt/HomeLab/issues/335) Run the Loki
      coverage check on a schedule.** 2026-09-06.
      `homelab-loki-coverage.{service,timer}`, daily at 07:45, plus a row in the
      `JOBS` table in `install-timers.sh`. No alert rule was edited: the
      staleness rules join against `homelab_job_max_age_seconds`, so a timer is
      a row in that table and nothing else — the property #99 tested and this
      confirms a second time.

      **Daily, not the weekly the issue proposed, and the window went 7d -> 24h.**
      #335 worried that a 7-day window against a weekly interval barely overlaps,
      so a gap opening and closing inside a week could be missed. That framing
      was wrong twice. The window is not a sensitivity dial — both sides of the
      comparison use it, so a host that goes quiet leaves the denominator as well
      as the numerator and the check goes vacuous rather than wrong. What it
      actually sets is DETECTION LAG: `reach` counts lines over the window, so a
      selector blinded an hour ago still looks reached until the last
      pre-breakage line ages out, and 7d hides a new gap for a week. And the
      overlap worry does not apply to the defect class at all — a rule going
      blind is configuration, it persists until somebody fixes it, so tiling 24h
      windows daily is enough.

      24h is as short as the estate allows, measured rather than picked. Lines
      per host: `Saruman` 15/hour and 186/day against `morpheus` 89,340/day, so
      the quietest host is comfortably present. The cost, stated rather than
      glossed: a host whose *subject* lines are rare — `Saruman` produced two SSH
      accepts in seven days — has none inside 24h, so a real gap there reports as
      a latent WARN instead of a live FAIL. Checked both ways against the
      pre-#261 rules, where 24h still exits 1 on `morpheus`.

      Verified end to end through the wrapper the timer actually calls:
      `run-scheduled.sh --job loki-coverage` exits 0 in 2s and writes the four
      `homelab_job_*` series, and a forced failure advances `last_run` while
      leaving `last_success` behind — which is what lets the staleness rule fire
      on repeated failures rather than only on a stopped timer.

- **[#327](https://github.com/Gerrrt/HomeLab/issues/327) Fail when a Loki
      rule is blind to a host.** 2026-09-06.
      `scripts/check_loki_coverage.py`, against the live Loki, outside `make
      validate` — `check_loki_rules.sh` boots the pinned image against a
      throwaway config with no data and asks whether the rules parse, which is
      the right question for CI and a different question from this one.

      **No expectation table**, which #327 called the hard part and it is: a
      table of which rule should see which host drifts, and a drifting table is
      the defect this exists to catch. Two derived questions instead. Do the
      rule's own stream selectors, unioned across its `or` branches, reach every
      host shipping logs? And for a host they miss, do lines matching what the
      rule *hunts* exist there anyway? The second grades the first — blind to a
      host producing those lines is a live hole, blind to a quiet one is latent
      — and it makes `useradd` never matching on FreeBSD `morpheus` answer
      itself rather than need a row.

      The subject query keeps the rule's positive filters (`|~`, `|=`) and drops
      its negative ones (`!=`, `!~`), and that is load-bearing rather than
      tidy. The negatives are policy — `SshLoginFromUnexpectedSubnet` excludes
      `10.0.50.` and `10.0.99.` — and with them the rule matches nothing
      anywhere, which is indistinguishable from being blind. Keeping them made
      an earlier draft pass over #261.

      Verified both ways against the live store. Against the rules as they stood
      before #261 was fixed it exits 1 on `SshLoginFromUnexpectedSubnet`,
      naming `Saruman` (journal, 2 lines) and `morpheus` (syslog, 46) and
      warning that the four sibling rules cannot reach those hosts either.
      Against the rules as they are now, all eight host-scoped rules reach all
      four hosts.

      The candidate selector is `{log_type=~".+", log_type!="docker"}` and
      #327's trap is why. Loki logs its own query text, so `{host=~".+"}` makes
      a rule match the string of its own line filter: 43,913 lines for
      `SudoFailure`'s pattern over seven days against 2 real ones, 30,365 of the
      difference being `service_name="loki"`. The label is required to be
      *present* rather than only non-docker because 11,721 more are container
      logs from before a labelling change that carry no `log_type` at all, and
      `!=` matches a stream where the label is absent.

- **[#310](https://github.com/Gerrrt/HomeLab/issues/310) Ask the switch what
      it is.** 2026-09-06. `sysDescr` joins the `mokerlink` module; `ifType` was
      walked and deliberately left out. The issue proposed both and named its own
      failure condition for the second — *"26 identical values would answer
      nothing"* — which is exactly what came back: `.1.3.6.1.2.1.2.2.1.3.N = 117`
      on all 26 ports, IANAifType `gigabitEthernet`, uplinks included. It does
      not distinguish the SFP cages, so it costs 26 varbinds a scrape and carries
      no information, and on this switch scrape volume is a safety property.
      Recorded in `generator.yaml` so nobody walks it a third time; the question
      it was for is answered by looking at the rack.

      `sysDescr` went in, and the honest note is that it says nothing either:
      `.1.3.6.1.2.1.1.1.0` is the literal string `"Switch"` with a trailing NUL.
      No model, no firmware, no hardware revision. It is there because the
      switch was the only SNMP target reporting no `sysDescr` at all, and
      because it lights up on its own if a firmware bump ever populates it.

      Measured rather than argued, twice. `snmp-walk.sh` first at the module's
      request shape, per the note that file carries — 1 row, 2 requests, 0.53s,
      the overshoot being `sysObjectID` answering `.1.3.6.1.4.1.27282` rather
      than the zero-length OBJECT IDENTIFIER that makes this switch's
      `ifSpecific` poison a whole response. Then end to end, because a walk
      probe is not a scrape: the pinned exporter run against the live switch
      with the regenerated config, beside a control container on the committed
      one, three interleaved rounds each and identical every time — 31 packets,
      131 PDUs, 1.46s and 136 series with it, against 30, 130, 1.45s and 135
      without.

## 2026-09-04

- **[#103](https://github.com/Gerrrt/HomeLab/issues/103) Give ADR-0008's SSO
  deferral an expiry.** Answered by
  [ADR-0022](adr/0022-expire-the-sso-deferral-when-the-tier-holds-real-data.md):
  the deferral ends on a state rather than a date — the first real secret, photo
  or document in the sensitive tier, any reachability from outside the house, or
  a third account holder, whichever comes first. At the first of those a
  decision gets recorded. Re-accepting is allowed; arriving at the same place by
  never looking is what the expiry removes.

  **Writing it turned up that ADR-0008's substitute for SSO does not exist for
  half the tier.** Per-application TOTP is available on Vaultwarden,
  Paperless-ngx and Home Assistant, and on none of Grafana, Immich or AdGuard
  Home — Grafana OSS has no MFA in any edition, Immich's upstream has declined
  it and points at OAuth, and AdGuard has one password-only admin. Grafana is
  the only one of the six deployed, so the thing ADR-0008 offered *in place of*
  SSO has never been available here, and for those three an identity provider is
  the only route to a second factor rather than a heavier alternative to one.
  What is outstanding belongs to #102: TOTP enrolled at first login on the three
  that can carry it, and the mini PC's disk encryption decided at build time
  rather than inherited from `prometheus` — a vault behind one factor on an
  unencrypted disk is not the bet `SECURITY.md` accepted for a metrics
  dashboard.

- **[#122](https://github.com/Gerrrt/HomeLab/issues/122) Settle who reaches the
  family's credentials, photos and documents when the estate is down.** Answered
  by [ADR-0023](adr/0023-keep-the-household-recovery-path-outside-the-estate.md),
  and the answer is that **no sensitive-tier service has to stay reachable** —
  one mini PC cannot be made highly available, and every way of pretending
  otherwise adds components that can take it down. The constraint is on the path
  instead: nothing the household needs in an emergency may have the estate on its
  only route. Four classes, falling due on ADR-0022's triggers — the household's
  own credentials recoverable without Vaultwarden and opened once from the other
  person's device; an encrypted off-estate copy of Immich and Paperless-ngx whose
  staleness is visible; nothing on the break-glass card depending on a
  certificate this estate issues; and nothing physical operable only through Home
  Assistant.

  **Writing it turned up that off-host is not off-estate.** `oracle` holds the
  firewall export precisely so it is not on the machine it protects (ADR-0015,
  #92) — and it is on the same VLAN, rack, power feed and room as the mini PC
  would be, so every failure this issue is about reaches both in one event. Two
  smaller findings went the other way: ADR-0010 already keeps name resolution
  alive when the mini PC dies, which is a dependency of every out-of-estate path
  and is met by accident of a decision made for other reasons; and ADR-0011's
  break-glass card already says "where credentials are", a sentence that goes
  false the day Vaultwarden holds anything real. Nothing here is built — the
  preconditions land on #131, #132, #133 and #134.

- **[#114](https://github.com/Gerrrt/HomeLab/issues/114) Set memory limits on
  the six services.** Done 2026-09-04, on seven — `blackbox-exporter` joined the
  stack after the issue was written. The gate this entry named was explaining
  the 2026-08-29 hour in which `loki` and `alloy` both peaked, and that is what
  unblocked it: Loki's RSS tracks the ingest rate through it minute for minute
  — ~100 MiB at 3 lines/s until 06:15, 461 MiB the minute 5,501 lines/s
  arrived, 1,015 MiB at 06:29, and back to 107 MiB nine minutes after the flow
  stopped. The source is [#286](https://github.com/Gerrrt/HomeLab/issues/286):
  `make backup` pipes each volume's gzip stream to a container's stdout, and
  Alloy tails every container on the socket, so the archives come back through
  the log pipeline. The compactor cycling and the 400s in the logs are a Loki
  shedding load, not the cause — which is the reading that has to be got right,
  because it is the difference between a ceiling sized for a self-healing blip
  and one sized for a recurring bug. It recurs: 577 MiB on 09-04.
  The other half was the method. `3x every peak` did not fit the machine because
  it was being read off the working set, which includes reclaimable page cache:
  `alloy`'s 512 MiB peak is 221 MiB of anonymous memory and the rest cache from
  walking `/rootfs`, and `mem_limit` bounds a cgroup the kernel reclaims cache
  from before it kills anything. Sized from `container_memory_rss` instead, with
  the multiplier chosen per service rather than flat, the seven limits sum to
  5120 MiB against 7816 MiB of RAM. `loki` gets the loosest ratio and the
  largest number for the reason above; the issue had listed it among the
  low-risk services to start with, on a 152 MiB peak from a six-hour window.
  `memswap_limit` equals `mem_limit` everywhere, so the stack cannot page into
  the unencrypted `/swap.img` — left unset it defaults to twice `mem_limit`,
  which would have made that exposure worse rather than better.
  Enforcement and detection stay uncoupled, which is the whole reason
  [#63](https://github.com/Gerrrt/HomeLab/issues/63) is a separate issue:
  `ContainerHighMemory` still measures against `machine_memory_bytes`, and the
  limit-relative `ContainerNearMemoryLimit` is a complement with its own
  `promtool test rules` cases — including one that fails if the numerator is
  ever "simplified" from RSS to working set, and one that fails if the
  divide-by-zero guard is dropped.
  [#71](https://github.com/Gerrrt/HomeLab/issues/71) had already taken the half
  that was sizeable without any of this: `pids_limit`, because tens of threads
  against a 10,000-thread abort is two orders of magnitude of daylight, and a
  byte ceiling on the TSDB, which is at a measurable steady state at day 28
  of 30.

- **[#102](https://github.com/Gerrrt/HomeLab/issues/102) Turn on the AdGuard
  probe once the machine exists.** The failure
  [ADR-0010](adr/0010-keep-the-resolver-on-the-gateway.md) chose on purpose:
  filtering fails open, so losing it costs advertisements rather than
  connectivity and nobody in the house reports it. That is
  [#90](https://github.com/Gerrrt/HomeLab/issues/90)'s shape one service over —
  a filter that is dead and one that is merely quiet look identical from
  outside — and the mechanism is the blackbox exporter that now exists.

  **The detection is written, and it is the target that is blocked, not the
  work.** [#126](https://github.com/Gerrrt/HomeLab/issues/126) — the same
  failure, filed twice — landed the two `dns` modules, `AdGuardNotAnswering`,
  `AdGuardNotFiltering` and their unit tests on 2026-09-04, with all four states
  measured against a real AdGuard Home first. The entry above was right that a
  probe cannot go through `morpheus`, right that "answering" and "filtering" are
  two questions, and wrong about only one thing: what could not be written today
  was the *target*, not the rules. It sits commented out in
  [`targets/blackbox-dns.yaml`](../stacks/observability/prometheus/targets/blackbox-dns.yaml)
  under its own scrape job, because
  [#102](https://github.com/Gerrrt/HomeLab/issues/102) has not bought the
  machine and Unbound is not forwarding to it — a target written before then is
  red from the moment the file loads, which is the check
  [`targets/blackbox.yaml`](../stacks/observability/prometheus/targets/blackbox.yaml)
  has already agreed not to ship. Uncommenting it is two lines and a verify,
  and it belongs to #102.

  **This entry was headed #123 until 2026-09-04**, and is re-headed rather than
  deleted because the work outlived the issue. #123 asked whether moving DNS off
  the gateway adds a quiet way to lose the internet; ADR-0010 and the
  verification appended to it answered that, and #123 closed. #126 was the same
  detection filed separately and closed with it. What survived both is the
  paragraph above, which is #102's to land — so it is filed under #102 here
  rather than left pointing at a closed issue, which is the failure this file
  keeps finding in itself.

  What is left outside this repository: one line for the family runbook in
  `Gerrrt/Lemmiwinks` covering *filtering is down and the internet is fine*,
  which presents as advertisements returning rather than as an outage. Held
  until the machine exists, for the same reason the target is — today there is
  no filtering to lose, so it would describe a symptom that cannot occur. Two
  edits there come due in the same sitting: the "there isn't a Pi-hole" bullet
  in `runbooks/dns_is_broken` stops being true as written, and that page's
  source note deserves a line saying this was the one thing that did need
  writing. A note to whoever maintains those pages, not a tenth step in the walk.

- **[#309](https://github.com/Gerrrt/HomeLab/issues/309) Check `shiva`'s iLO
  firmware version too.** [#292](https://github.com/Gerrrt/HomeLab/issues/292)
  scoped `check_versions.py` to the Compute table in `hardware.md`, which is the
  list of hosts rather than of devices. `shiva` is not in it — correctly, being
  the BMC on the same physical box as `Saruman` — but since #292 it is the only
  device outside that table with both halves of a checkable claim: `network.md`
  gives it `iLO 2.82`, and its `sysDescr` is already scraped, answering
  `Integrated Lights-Out 4 2.82 Feb 06 2023`. So the only thing keeping it
  unchecked is a scoping line. **It is not a one-line change**, because the
  generic parser misreads both sides — `os_key` takes the first word and the
  first number, giving `('integrated', '4')` against the documented
  `('ilo', '2.82')`, and that `4` is the iLO *generation*, not the firmware. It
  needs a per-device extraction rule, the way `morpheus` already has one. Worth
  doing because a BMC that can power-cycle the hypervisor and mount virtual
  media, on the segment ADR-0014 exists to contain, is the first thing anyone
  checks against an advisory.

- **[#311](https://github.com/Gerrrt/HomeLab/issues/311) Collect the Proxmox VE
  version from `Saruman`.** The other host #292 left uncovered, and a different
  problem from #309: that one is parsing, this one is collection. Nothing on the
  wire carries the number `hardware.md` claims. `node_os_info` reports `Debian
  GNU/Linux 13 (trixie)` — the base PVE 9 is built on, unrelated numbering — and
  `node_uname_info` reports `7.0.14-12-pve`, which confirms Proxmox and gives
  the *kernel* version. So `Proxmox VE 9` is currently unfalsifiable, which is
  the condition #292 existed to remove. The documents are not wrong: recording
  `Debian 13` would not tell a reader what the box is. **The collection is the
  easy half** — the textfile collector is already enabled in `config.alloy` and
  `deploy-agent.sh` already creates its directory on agent hosts, so a `.prom`
  file reaches Prometheus through the agent already there. The awkward half is
  where the thing that writes it lives: the monitoring host cannot reach VLAN 30
  — TCP/22 to `10.0.30.110` does not open — so this cannot be another entry in
  the `JOBS` table, and wants a local timer on a host this repository can only
  reach through a person.

- **[#98](https://github.com/Gerrrt/HomeLab/issues/98) Device joins as events.**
  Answered by
  [ADR-0019](adr/0019-read-device-joins-from-the-dhcp-server.md), which keeps
  the issue's landing site and changes its source. The events belong in Loki
  and in `security.rules.yaml` — that part was right. But "the eero API" is a
  cloud API: there is no local one, the integration everyone means is a HACS
  component polling `api-user.e2ro.com` every 120 seconds, and it cannot log in
  with an Amazon-linked account. Routing a question about this network's own
  wire through Amazon makes the answer late and makes it disappear whenever the
  WAN does. **`morpheus` already knows.** The eeros are bridged, Kea serves
  every segment, and 1,200 lease lines a day are one pfSense checkbox from the
  1514 listener that already carries filterlog. Three rules land in the `dhcp`
  group: first lease on Hicks in seven days (warning), the same on Winterfell
  (critical, and zero in 13 days of logs), and `DhcpLeaseLogsStopped`, because
  the other two fail silently. Measured cost on Hicks: about one alert every
  three days, and every one of the five in the sample was worth a look — two of
  them an OUI the inventory places on Skids. **No longer blocked behind
  ADR-0008's sensitive tier**, and leaves are dropped rather than deferred: 9
  releases against 4,732 allocations in four days, and a departure is not a
  security event. What is left is ticking **DHCP Events** on `morpheus` —
  before the rules deploy, or `DhcpLeaseLogsStopped` fires truthfully — and
  reading the first week, which is one alert per device and therefore an
  inventory check.
  → [runbook](runbooks/ship-firewall-logs.md)

- **[#292](https://github.com/Gerrrt/HomeLab/issues/292) Detect pfSense
      version drift from the box.** 2026-09-04. `sysDescr` joins the `pfsense`
      SNMP module and `scripts/check_versions.py` compares what the documents
      claim against what the hosts report, weekly. The drift that prompted it —
      `morpheus` recorded as pfSense CE 2.8.1 on FreeBSD 15 in eleven places
      while running 2.9.0-RELEASE on FreeBSD 16.0-CURRENT — was corrected by
      hand in [#283](https://github.com/Gerrrt/HomeLab/pull/283) after a human
      noticed, which is the standing this file says is not good enough.

      **pfSense sets `sysDescr` explicitly**, so one string carries both
      versions: `pfSense morpheus.matrix.elysium 2.9.0-RELEASE FreeBSD
      16.0-CURRENT amd64`. It was absent only because the OID was not in the
      module. Probed with `snmp-walk.sh` first, per the mokerlink note — 1 row,
      1 request, 0.47s — and the generator resolves it to a GET of `.0`, so no
      GETBULK is issued at scrape time. Regeneration added exactly one metric.

      The check is deliberately out of `check_docs.py` and out of `make
      validate`: that script compares documents to repo files and runs in CI,
      which has no route to the stack. It compares release lines rather than
      full strings, because the tables record `Ubuntu 24.04 LTS` where the hosts
      report `24.04.4` and a check that fires the day after every update is one
      that gets switched off. It also covers the single live version claim in
      prose — `enable-suricata.md`'s "morpheus now runs 2.9.0-RELEASE" — which
      #283 introduced while fixing this very drift.

      **Deploying it found a bug that no stub could have.** `sysDescr` is not
      `morpheus`-only: the `ilo` module walks it too, so the query returns two
      series and `shiva` sorts first. The runbook check took the first series
      carrying a three-part version, which is correct only because the iLO
      firmware is `2.82` — two parts. An iLO numbered `2.82.1` and it would have
      reported the BMC's firmware under the firewall's name: a confident,
      specific, wrong finding, which is worse than no check.
      [#306](https://github.com/Gerrrt/HomeLab/pull/306) selects by device
      instead. Verified against the running stack after convergence: `morpheus`
      moved from SKIP to PASS on both table rows and the prose claim.

      What it does not cover is tracked rather than assumed:
      [#309](https://github.com/Gerrrt/HomeLab/issues/309) for `shiva` and
      [#311](https://github.com/Gerrrt/HomeLab/issues/311) for `Saruman`.

- **[#105](https://github.com/Gerrrt/HomeLab/issues/105) Confirm the
      unconfigured Snort package actually went.** 2026-09-04. It did.
      `pkg info` on `morpheus` lists `pfSense-pkg-suricata` and `suricata` and
      no Snort of any kind, so ADR-0006's line 49 was describing a fact and the
      runbook prerequisite asking for the removal was describing a job already
      done. The prerequisite is gone from
      [`enable-suricata.md`](runbooks/enable-suricata.md) §0; the ADR stands as
      written.

      **What "removed" left behind is worth knowing before the next package is
      uninstalled.** pfSense removed the package but honoured
      `forcekeepsettings`, so `config.xml` kept a `<snortglobal>` stanza — and
      inside it `snort_alerts:col2:open`, a widget record pointing at a
      `snort_alerts` widget no longer on disk; only `suricata_alerts.widget.php`
      is there. `/var/log/snort/` also survived, holding one 111-byte
      rules-update log from 2025-10-30. The `snort`-named keys under
      `<suricata>` — `snortcommunityrules`, `enable_snort_custom_url` — are not
      residue at all: they are Suricata's own names for the Snort Community
      ruleset options, both `off`, and were left alone.

      **Both are now cleared.** `config_del_path()` and `write_config()` over
      SSH for the stanza, `rm -rf` for the log directory, with an encrypted
      off-host export taken either side. Not because the residue was dangerous
      — nothing ran, updated or listened, and the live dashboard reads
      `<widgets><sequence>`, which never referenced `snort_alerts`, so nothing
      was even visibly broken. It went because of the one line in the stanza
      that was not inert: `<forcekeepsettings>on</forcekeepsettings>` is what a
      future `pkg install pfSense-pkg-snort` would have read its settings back
      out of, so leaving it meant a reinstall resurrecting a half-configured
      Snort rather than starting clean — the 1am mistake this issue was opened
      about, deferred rather than closed.

      Verified after the write: 88 user-defined rules, the same count the
      pre-change export recorded; `<widgets><sequence>` byte-identical;
      Suricata still on `igc0.20` and `igc0.10` under the same PIDs, never
      restarted; web UI answering 200. `write_config()` leaves its own audit
      line in the config revision log, so the word `snortglobal` still appears
      once in `config.xml` — as the description of the change that removed it.

- **[#97](https://github.com/Gerrrt/HomeLab/issues/97) Work out DNS for the
      MokerLink management UI** so it is not reached by IP. 2026-09-04. Answered
      by [ADR-0018](adr/0018-name-the-switch-and-leave-its-ui-on-plain-http.md),
      which splits the issue in two and grants one half. The name is a host
      override like any other — `neo` → `10.7.7.2` — and was never blocked
      behind ADR-0008, because ADR-0010 keeps the overrides on Unbound whatever
      AdGuard does. **The certificate half is closed as unavailable rather than
      pending:** the switch has no TLS listener and no way to import one,
      checked against the device on 2026-09-04. That is its third firmware limit
      after #84 and #85, and the argument for replacing it — where TLS
      management belongs in the selection criteria next to SNMPv3.

      Both halves were already settled when this file still listed the granted
      one as outstanding. Confirmed while verifying
      [#123](https://github.com/Gerrrt/HomeLab/issues/123): `neo` → `10.7.7.2`
      is one of six host overrides read off `morpheus` on 2026-09-04, and the
      `via: dns` twin probes green from the running exporter (`probe_success 1`,
      `probe_http_status_code 200`, lookup 0.9 ms). The entry outlived the work
      by a day, which is the failure this section exists to prevent.

- **[#100](https://github.com/Gerrrt/HomeLab/issues/100) Automate the Grafana
      dashboard export step.** 2026-09-04. `make dashboards-export` pulls every
      dashboard back by uid and writes it over the file, so the loop is edit →
      one command → `git diff` rather than a hand copy out of the JSON Model
      panel — manual, and therefore skipped under pressure, which is what this
      file said about it.

      **The issue's design could not work as written, and finding out why is
      most of what this was.** The plan was to pull each dashboard from the API
      and write it back. But `allowUiUpdates` was `false`, and that does not
      mean what the issue assumed it meant: Grafana does not discard a UI edit
      at the next restart, it refuses to *store* one at all —
      `POST /api/dashboards/db` answers `400 Cannot save provisioned
      dashboard`. So the API could only ever return the file it was provisioned
      from. Every export would have been a clean no-op over the very edit it
      existed to capture, exiting zero and writing nothing while `git diff`
      reported no change to something plainly different on the screen. Measured
      against the running stack before anything was built: the API's copy of
      `homelab-docker` was identical to the committed file in every field but
      `id` and `version`.

      So `allowUiUpdates` is now `true`. The JSON stays the source of truth —
      a file change re-provisions over Grafana's copy — but an edit now survives
      long enough to be exported. What `false` bought for free was that the
      running dashboard and the committed one could not disagree, and that is
      bought back rather than dropped: `ARGS=--check` writes nothing and exits
      non-zero when Grafana holds an edit git does not, and the daily
      `dashboards-drift` timer runs it, so forgetting to export ages into a
      stale job with an alert behind it. The rules in `backup.rules.yaml` join
      against the `JOBS` table rather than naming jobs, so it needed no rule.

      Two things found on the way, both of which would have made the diffs
      unreadable. Grafana serialises keys **alphabetically** at every level,
      while these files put `uid`, `title` and `description` first — a naive
      write-back would have reordered every key in all seven and buried the one
      line that changed, so the committed order is preserved and only new keys
      are appended. And Grafana persists whatever the browser was showing at
      save time, so the time picker's range and each variable's selection are
      read back out of the file rather than taken from the API: without that,
      one person's afternoon of debugging silently becomes everyone's default
      time range. Those fields are the one thing the round trip will not write,
      and the dashboards README says so.

      The round-trip check the issue asked for boots the pinned Grafana image,
      provisions the committed JSON into it and reads it back, which is what
      keeps an export from arriving as noise. It also asserts that a save to a
      provisioned dashboard is still accepted — the condition the whole feature
      depends on and the one it cannot detect for itself, since flipping the
      flag back breaks the export silently. Verified in both directions: with
      `allowUiUpdates: false` the check fails and names the setting.
      → [`grafana/dashboards/README.md`](../stacks/observability/grafana/dashboards/README.md)

- **[#126](https://github.com/Gerrrt/HomeLab/issues/126) Notice when the
      house stops filtering DNS.** 2026-09-04. Also the monitoring half of
      [#123](https://github.com/Gerrrt/HomeLab/issues/123), which describes the
      same failure and whose entry under Monitoring has been corrected: the
      rules were writable today, only the target was not.
      [ADR-0010](adr/0010-keep-the-resolver-on-the-gateway.md) left the public
      upstreams in Unbound's forwarder list so that a dead AdGuard costs
      filtering rather than connectivity, and that trade converts a loud
      failure into a silent one: the only symptom is advertisements
      reappearing, which nobody reports. Two `dns` modules in
      `blackbox/blackbox.yaml` and two rules in a new `dns.rules.yaml`.
      `AdGuardNotAnswering` asks whether it answers at all; `AdGuardNotFiltering`
      asks whether it is still *blocking*, which is the quieter failure — a
      blocklist that silently stopped updating leaves a perfectly healthy
      service filtering nothing. Both `warning`, so they route to `default`
      rather than `urgent`: nothing is down and nobody is blocked.

      **The whole design is in where the probe is aimed.** A query through the
      normal resolver path always passes, because the fallback is doing its
      job, so both probes go straight at port 53 on the filter under their own
      scrape job — separate from `blackbox` because `EndpointUnreachable` is
      critical and routes to `urgent`, and because `EndpointNameNotResolving`
      joins on `name` in a way that means nothing when the target is itself a
      resolver. `AdGuardNotFiltering` carries an `and on (name)` join so a
      stopped AdGuard raises one alert and not two, and `tests/dns.test.yaml`
      asserts that silence — the #63 hazard, since a join that stops matching
      passes `promtool check rules`.

      All four states were measured against a real AdGuard Home running the
      default filter before either rule was written: healthy, blocklists not
      loaded, blocking mode changed, and stopped — plus the trap itself,
      Unbound at `10.0.99.1`, which answers the liveness probe and fails the
      filtering one. The canary is `doubleclick.net`, a real blocklist entry
      rather than a rule of our own, because a custom rule would keep working
      while every downloaded list failed to load.

      **The targets are written out and disabled**, the same call #91 made for
      the iLO and pfSense UIs: AdGuard does not exist until #102 buys the mini
      PC, and a probe enabled today would report a service down from the moment
      the file loaded. The scrape job ships anyway, so turning them on is a
      file_sd append with no restart. Enabling them belongs to #102.

## 2026-09-03

- **[#249](https://github.com/Gerrrt/HomeLab/issues/249) Scrape the UPS
  self-test schedule.** [#93](https://github.com/Gerrrt/HomeLab/issues/93) left
  `mjolnir` testing itself every fortnight and nothing able to see that it does.
  The schedule, the last-test date and the last result are all PowerNet OIDs and
  the `apc_ups` module walks the standard UPS-MIB only, so a card that reverts
  to `never(5)` produces no alert and no changed metric — `upsTestResultsSummary`
  holds `1` (donePass) forever. The missing pack was visible in a MIB already
  walked; the missing schedule is not, which is the same failure one level up.
  The real cost is not the two rules but a pinning decision for APC's MIB in
  `scripts/snmp-mibs.sh`, which has no first-party git ref to point at.
  → [runbook](runbooks/fit-the-ups-battery.md)

- **[#251](https://github.com/Gerrrt/HomeLab/issues/251) Put the wiki on
  `oracle` into the repository, and back up its database.** ADR-0015 ratified a
  host whose main service is not described anywhere here: `wiki` and its
  Postgres were created by hand in November, the content volume is anonymous,
  nothing copies either volume anywhere, and `/etc/wiki/.db-secret` is mode
  664. The pages survive a disk failure because Wiki.js syncs from the
  Lemmiwinks repository; the accounts, history and configuration do not.

- **[#93](https://github.com/Gerrrt/HomeLab/issues/93) Replace the UPS
      battery, delete the silence, put the card under scheduled test.**
      2026-09-03. The first two steps were done on 2026-08-28: an APCRBC115 into
      `mjolnir`, `upsTestResultsSummary` `4` (aborted) → `1` (donePass) at
      22:45 UTC, and the `UpsSelfTestFailed` silence
      `54f1715c-e57b-4322-8a6d-5435bc8e1bd8` deleted at 23:14 rather than left
      to lapse on 2026-09-20 — nine minutes after the proving reading instead
      of before it, which is the inversion the runbook exists to prevent and
      which cost nothing only because the test passed.

      The third step turned out to need checking rather than doing. The card
      reads `upsAdvTestDiagnosticSchedule` `8` (biweeklySinceLastTest), with
      `upsAdvTestDiagnosticsResults` `1` (ok) and
      `upsAdvTestLastDiagnosticsDate` `08/28/2026`. Six files had been asserting
      the opposite since the fit; they now say what the device says. Whether the
      schedule was set at the rack or has been the default all along, the NMC
      will not say after the fact.

      **Nothing watches it.** All three are PowerNet OIDs and the `apc_ups`
      module walks the standard UPS-MIB only, so a card that reverts to
      `never(5)` produces no alert and no changed metric — `upsTestResultsSummary`
      would simply hold `1` forever. Closing that means adding APC's MIB to
      `scripts/snmp-mibs.sh`, which is a new vendor source with its own pinning
      decision; it is filed as
      [#249](https://github.com/Gerrrt/HomeLab/issues/249) rather than done
      here. Until it is, the check is
      `scripts/snmp-walk.sh --device mjolnir 1.3.6.1.4.1.318.1.1.1.7.2`, and
      what proves the schedule *runs* rather than merely being set is that date
      advancing unattended, due around 2026-09-11.

      Two smaller findings. `upsBasicBatteryLastReplaceDate` still reads
      `08/15/2026` for a pack fitted on the 28th, so the card's battery-age
      accounting is keyed to a date on which its own self-test was still
      aborting over an empty bay. And runtime is a poor proof of a real pack on
      this UPS: since the fit it has sat on exactly `63` — the fabricated
      value — for 744 of 764 samples. Voltage moving across `540`-`549` is the
      comparison that actually discriminates.
      → [runbook](runbooks/fit-the-ups-battery.md)

- **[#91](https://github.com/Gerrrt/HomeLab/issues/91) Probe the services
      this was filed for, and probe TLS expiry.** 2026-09-03. Seven named, five
      probed, plus the one the sentence about "four devices" implied: Grafana
      by name and by address through a new `http_2xx_lab_ca` module that
      verifies the chain against `certificates/ca.pem` (now mounted into
      blackbox-exporter, CA only); Prometheus and Loki at the address the
      agents push to, so a mis-set `BIND_ADDR` fails the probe while every `up`
      stays green; Alertmanager on the compose network, the only network it is
      on; the switch UI, which is plain http and drops 443; and the APC card,
      https-only with a self-signed certificate, through `http_2xx_self_signed`.
      `TlsCertificateExpiringSoon` at 30 days and `TlsCertificateExpiryImminent`
      at 7 read `probe_ssl_earliest_cert_expiry` off the handshake, aggregated
      per certificate so Grafana's two URLs raise one alert, the critical
      inhibiting the warning. Every enabled target was probed through the new
      modules from a throwaway exporter on the compose network before landing,
      and the lab-CA module was checked to *refuse* the APC card's certificate.

      Two of the seven are written into `targets/blackbox.yaml` and disabled.
      From `10.0.99.20` the iLO and the pfSense UI both time out, and neither
      is a fault: VLAN 99 → 30 passes SNMP and nothing else, and "Block HTTPS to
      pfSense" on igc0.99 is an explicit rule. Each needs one pass on the
      Winterfell interface, written out beside the target, and each is a
      segmentation decision to record in ADR-0013's table when made — the
      pfSense one hands a host with two unauthenticated push ports a path to
      the firewall's login page. #235 kept the iLO on the lab segment
      (ADR-0033), so the iLO probe still needs its `99 → 30:443` pass.

- **[#90](https://github.com/Gerrrt/HomeLab/issues/90) Detect Suricata
      being dead.** 2026-09-03. The roadmap line said the SNMP module does not
      expose a heartbeat; the firewall's agent already did. `bsnmpd` on
      `morpheus` loads `snmp_hostres.so`, so HOST-RESOURCES-MIB `hrSWRunTable`
      is served — 94 rows, 0.04s for a full walk — with one `suricata` row per
      interface and the interface in `hrSWRunParameters` (`-i igc0.20 …`),
      indexed by pid+1 and renewed on every rule update. The `pfsense` module
      now fetches those rows and nothing else from the table, through a
      dynamic filter on `hrSWRunName`, with a `DisplayString` override because
      both string columns are `InternationalDisplayString` and would otherwise
      arrive as hex. `SuricataStopped` in `prometheus/rules/ids.rules.yaml` is
      "declared but not running" per interface, gated on the scrape being up,
      unit-tested against the rows as morpheus read them. It proves the process
      is alive, not that it detects; the runbook's test alert still owns that.

      Proved live the same day. The Degens instance was stopped at 04:49:59
      UTC; `SuricataStopped` for `igc0.10` alone went firing at 05:00:49
      (10m50s) and reached the `security` receiver, Skids stayed quiet. Started
      again at 05:01:12, resolved at 05:03:00 with the row back under index
      `90324` for pid `90323`. A full package restart at 05:03:23 — the shape
      of the daily rule update — never reached firing. Scrape cost for the
      module went from nothing measurable to 0.26s.

## 2026-09-02

- **[#89](https://github.com/Gerrrt/HomeLab/issues/89) Extend Suricata to
      Degens (VLAN 10).** 2026-09-02. Second interface, twelve days after the
      first, alert-only on both. Its alerts are told apart from Skids' by the
      syslog facility — the one per-interface setting pfSense puts on the wire
      — which `syslog.alloy` maps to `interface`; both Loki rules and the
      dashboard split on it. Proven per interface with the §4 test rules: the
      first real alert arrived two seconds after the engine started, labelled,
      and was the same stream-timestamp signature that is 79% of Skids.

      Two things the pipeline test found on the way. *Restart* on the
      interface left the process stopped until started by hand, and loading
      the ruleset then took 35 seconds — a test visited in that window fires
      nothing and looks like a broken pipeline. And a guest iPhone with
      iCloud Private Relay produced no plaintext DNS or HTTP at all, so neither
      test rule could fire from it; the engine's own `alerts.log` on the box is
      what separates "never fired" from "fired and lost". Both are in the
      runbook now. The fortnight comparison of that shared signature is dated
      2026-09-16 there. → [runbook](runbooks/enable-suricata.md)

- **[#76](https://github.com/Gerrrt/HomeLab/issues/76) Replace `shiva`'s
      Smart Storage Battery.** 2026-09-02. Spare `815983-001` fitted;
      `Saruman` was off 22:30–22:58 UTC. The first scrape after it came back
      read chassis 0 battery 1 at `cpqHeSysBatteryCondition` `2` (ok) and
      `cpqHeSysBatteryStatus` `1` (noError), down from `4` and `13`, with serial
      `6EZBN0FB2431YM` where the failed pack was `6EZBN0CB29N3YZ` — a different
      part being read, not the old one reading differently. The Smart Array
      re-enabled its cache on the same scrape: `cpqDaAccelStatus` `5` → `3`
      (enabled), `cpqDaAccelBackupPowerSource` `1` → `4` (smartbattery),
      `cpqDaAccelBattery` `6` → `2`, and the three controller rollups that had
      read `3` (degraded) since 2026-08-18 back to `2`. `cpqDaAccelBadData`
      stayed `2`: nothing dirty was lost at either end.

      The silence `bfdfff66-d9c3-4df4-9495-f1f38ebf93c1` was deleted at 23:11
      UTC rather than left to expire on 2026-10-01, so `IloBatteryCondition`
      and `IloWriteCacheDisabled` are live again over the new part. Deleted
      nine minutes *after* the proving reading, not before — the UPS
      inversion again. It cost nothing because both rules carry a `for:`
      longer than nine minutes, which is the rule shape being kind, not the
      procedure working.

      **Two readings did not move, and neither is alerted on.**
      `cpqDaAccelWriteCachePercent` / `ReadCachePercent` still read `0` / `0`
      ten minutes in, where a P440ar normally reports a ratio; the controller
      says the cache is enabled and reports no split. And
      `cpqDaAccelFailedBatteries` still reads `1`, unchanged from the failed
      pack. Both are named in the runbook with the `ssacli` check on `Saruman`
      that resolves the first; the metrics before 2026-09-02 show the failed
      pack and a write-through array, which any range crossing that date will
      include.

      **The `ssacli` check ran on 2026-09-19, seventeen days later, and the
      first reading is a blind spot, not a fault.** `Cache Ratio: 10% Read /
      90% Write`, `Battery Backed Cache Size: 1.8`, LD 1 `Caching: Enabled` —
      while `cpqDaAccelWriteCachePercent` and its three siblings still read
      `0`. The iLO does not populate those columns on this hardware; the
      ratio was set and the cache was absorbing writes all along, which the
      fit's fio then showed as a 7.2K mirror completing 4 KiB writes in 1.3
      ms. No `modify cacheratio=` was ever needed. `cpqDaAccelFailedBatteries`
      `1` is still unexplained and still not alerted on. Recorded by #527;
      this issue stays closed.
      → [runbook](runbooks/replace-the-smart-storage-battery.md)

- **[#88](https://github.com/Gerrrt/HomeLab/issues/88) Deploy Alloy to
      `Saruman` and `oracle`.** 2026-09-02. One script,
      `scripts/deploy-agent.sh`, for both: the compose service written out as
      `docker run` for a Docker host, and the `.deb` matching the compose tag
      for a host that should not run Docker, which a Proxmox hypervisor is. The
      agent config became a directory of three files so the native package
      loads no Docker components and opens no syslog port on the hypervisor's
      real interface.

      `oracle` turned out to have been the actual gap. It was deployed by hand
      on 2026-08-30 and by 2026-09-01 was running a version behind compose, as
      `--privileged`, with the config it was copied with — no self-scrape, so
      `oracle-alloy` never existed and nothing said so — and no volume for its
      WAL. The runbook's verification could not fail: Alloy logs to stderr and
      the grep read stdout. Redeployed with the script; three jobs now.

      `Saruman` needed a decision, not a deploy: ADR-0007 said it does not
      remote-write to Winterfell and ADR-0012 assumed it does. Resolved for the
      hypervisor's own telemetry only, over one unlogged pass above the
      ADR-0014 tripwire; both ADRs carry a note. The rule and the run are the
      operator's, from Hicks, since 99 → 30 is closed.

      Two more things found on the way, neither fixed here. Since #188 every
      Docker-host agent logs cAdvisor's `rootDiskErr` every few minutes —
      root without `DAC_READ_SEARCH` cannot always size overlay layers —
      partial, nothing charted depends on it, and nobody wrote it down; the
      deploy gate ignores exactly that line. And a throwaway `alloy run` on the monitoring host resolves
      `prometheus` through the host's DNS and pushes into the live stores:
      four `instance="smoke"` series and a silenced `RemoteWriteJobStale`,
      because there is no admin API to delete them.

## 2026-09-01

- **[#229](https://github.com/Gerrrt/HomeLab/issues/229) The switch LAN still
  carries pfSense's stock *Default allow LAN to any*.** `10.7.7.0/24` reaches
  every VLAN; `network.md` said "Nothing". Bounded by that segment holding only
  the switch — which is also the device whose SNMP agent serves GETBULK to any
  short community (#84) and stays on v2c until #444 replaces it — ADR-0036
  moved #85 to the iLO and the UPS card, and the switch is no longer in that
  issue. Lower risk than #228: getting it wrong
  costs SNMP polling of `neo`, which is monitored.

- **[#87](https://github.com/Gerrrt/HomeLab/issues/87) Add `ifXTable` (64-bit
      counters) to the `mokerlink` module.** Swapped in rather than added: the
      64-bit `ifHCInOctets`/`ifHCOutOctets` replaced the 32-bit pair, so the walk
      stayed at five columns and the load on a switch that has wedged under
      polling stayed where it was. Each column was fetched first with the new
      `scripts/snmp-walk.sh`, at the exporter's own request shape, and the low
      32 bits matched the live counters on every busy port.

      Two things found on the way went with it. `SwitchCounterWrapSuspected`
      could never fire — `rate()` never goes negative — so it was deleted, not
      re-pointed. And no switch metric had ever carried an `ifDescr` label: the
      generator comment said "label lookup" but no lookup existed, so every
      port name in the dashboard and the `SwitchInterfaceDown` summary rendered
      blank. One `lookups` stanza fixed both.

- **[#86](https://github.com/Gerrrt/HomeLab/issues/86) Decide whether the
      lab VLAN needs egress filtering.** No. ADR-0014. The question and #96's
      deferred isolation mechanism were one decision, and the fact that
      decided it is that the techniques the estate exists to detect are layer
      2 — poisoning, spoofing, rogue DHCP — and do not cross a router. So the
      attacker shares the segment with the Windows domain, and the vulnerable
      targets get no route at all: a bridge inside `ifrit` with no physical
      port, on a subnet the firewall does not know. A port allowlist would
      have passed C2 on 443 and broken Kerberos by blocking NTP; a range VLAN
      would have routed every scan through the box that runs the house and
      hidden the layer-2 techniques from the estate.

      Two things it found and did not decide: the iLO of the defended estate
      is now on the attackers' segment (#235), and the segment gets a log-only
      tripwire like the three terminal ones (#234).

- **[#104](https://github.com/Gerrrt/HomeLab/issues/104) A superseding ADR
      for 0002's rule count.** ADR-0013. The issue asked for the third rule and
      the current total; reading the enforced ruleset instead of recounting the
      prose showed the total was the wrong thing to ask for.

      Default deny holds for 99, 30, 40, 20 and 10. It does not hold for Hicks,
      which blocks 40/20/10 and then passes to `any` — so it reaches all of
      Winterfell and all of ImaginationLAN, wholesale, which no rule grants and
      no rule denies. Nor for the switch LAN, which still carries pfSense's stock
      *Default allow LAN to any* and reaches every segment while `network.md`
      said "Nothing". One explicit rule — *Allow Hicks access to ImaginationLAN*
      — sits on the ImaginationLAN interface, where Hicks traffic never arrives,
      and matches nothing.

      Four documents held four different counts. They now hold a list.
      `network.md` had Hicks right the whole time.

- **[#223](https://github.com/Gerrrt/HomeLab/issues/223)
      `TerminalSegmentReachedInternalNetwork` could not fire.** The firewall
      logged blocks only, and the rule matches `action="pass"`, so the alert
      the segmentation design depends on could not fire for any input — the
      #63 shape, found while building #82's dashboard.

      Armed with three tripwire rules rather than by logging passes broadly.
      The obvious fix does not work: every inter-VLAN pass rule is sourced from
      an internal segment, so none can carry a terminal-VLAN packet. Logging
      the terminal `→ any` egress rules does work and costs ~12.6M lines a day,
      about 142× current volume. The tripwires — `pass` + `log` for
      `<terminal net> → Internal_Segments` on `igc0.10/20/40`, below the blocks
      and above `→ any` — cost nothing while segmentation holds and match only
      if the blocks are removed or reordered.

      The logging path was proven rather than assumed: 49 of 49 pass lines put
      the source where the alert's regex reads it, and the destination half
      already matched 2058 block lines.

- **[#82](https://github.com/Gerrrt/HomeLab/issues/82) A dashboard for the
      Suricata and firewall-log labels.** `homelab-security`, 21 panels, all
      from labels `config.alloy` was already extracting and five Loki rules were
      already firing on. It charts blocks per second by `interface` and
      `direction`, top blocked sources — parsed out of the line at query time,
      because ADR-0003 keeps addresses out of the index — Suricata by
      `classification` and `priority`, and terminal-segment violations, which
      is the rule the segmentation design exists to enforce and which had no
      view but the alert.

      It also closed a gap it walked into: dashboard PromQL had been parsed by
      promtool since #78, and dashboard LogQL had been parsed by nothing, so a
      typo in a Loki panel rendered an empty panel and read as quiet traffic.
      `check_dashboards.py --emit-logql` now feeds every panel query to the
      Loki that `check_loki_rules.sh` already boots — 28 expressions, including
      the eleven in `homelab-logs` that had been unchecked since it landed.

      Not captured by `make screenshots`, and never will be, for the reason
      `homelab-logs` is not: three of its panels exist to show real addresses.

## 2026-08-31

- **[#182](https://github.com/Gerrrt/HomeLab/issues/182) Authenticate the
  Prometheus and Loki ingest ports.** Both are published and unauthenticated, so
  anything that can route to `10.0.99.20` can read every metric and log line,
  inject metrics and delete log ranges. They stay published because `oracle`'s
  agent pushes to them and has no other path, which is why #70 could close
  Alertmanager and not these. Firewall default-deny is the whole control.
  Accepted residual, recorded in `SECURITY.md`.

- **[#81](https://github.com/Gerrrt/HomeLab/issues/81) A dashboard for the
      observability stack itself.** `homelab-stack`, 33 panels, all from metrics
      already collected. The argument in the issue was that two of the three
      faults found while verifying #12 would have been visible on it
      immediately, and the panels that would have shown them are the two the
      dashboard is really built around: *Samples returned per scrape*, where
      cAdvisor collapsing from hundreds of series to one is a step change while
      `up` stays 1, and the Alloy remote-write lag, where a stale address shows
      as a climbing line rather than as nothing at all.
      Three things came with it because the dashboard could not be honest
      without them. The five rules watching the stack's own components were
      carrying `component: containers` and so were filed under *Container
      alerts* on the Docker dashboard; they are now `stack.rules.yaml` on
      `component: stack`, a relabel with the expressions untouched. Each Alloy
      agent now scrapes itself and remote-writes the result, because
      `prometheus.yaml` could only ever reach the agent on this host —
      `oracle` publishes Alloy's port on loopback and there is no address to
      point at. And `check_docs.py` was matching spelled counts in lowercase
      only, so "Five dashboards are provisioned" was unguarded while "There are
      five dashboards" two files away was checked; both were stale together.
      One thing the dashboard made obvious was that **`up` is not a liveness
      signal for the jobs that arrive by remote_write**: a pushing agent that
      dies stops pushing, so its series ages out rather than falling to 0, and
      `InstanceDown` is `up == 0`. `RemoteWriteJobStale` closes that, and is
      worth reading for how it is written rather than what it covers. The
      obvious form, a threshold on the staleness the dashboard graphs, is
      unfireable for the same reason #63 was — an instant selector stops
      returning a sample after the lookback delta, so the difference never
      reaches the threshold. Both that form and the version with the guard
      dropped were run against the tests and both fail them. What ships asks
      which jobs were reporting in the last 24 hours and are not reporting now.
      It was then watched working rather than argued: the agent on the
      monitoring host was stopped for six minutes with the rule silenced, and
      the alert went pending at t+282s having returned nothing at all for the
      four and a half minutes before that — the lookback delta, and the real
      blind window on any remote-written target.
      The residual is in the 24-hour window: an agent away longer than a day
      resolves the alert falsely, having notified at least twice first. That is the price
      of matching on the job-name convention instead of a list, and the list is
      what would silently miss `Saruman` when it arrives (#88).
      Two panels were added afterwards, which is what closed the issue. The
      Alloy row charted throughput, lag, component health and forwarded lines
      but not the WAL, which the issue had asked for by name — *WAL size and
      append rate* and *WAL replay and corruption* now do, and the replay one
      earns its place by dating an agent restart to the minute, the context
      that is missing when the lag panel jumps and nothing says why.
      Adding them also found that the screenshot this dashboard has been
      waiting for could never have worked. `homelab-stack` renders 4582px tall
      against a `BROWSER_MAX_HEIGHT` of 3000, so a capture would have come back
      cropped at the Alertmanager row — with the Alloy panels, the reason to
      shoot it at all, off the bottom — and reported success. The ceiling is
      raised in `compose.yaml` and in the script together, and the dashboard is
      in `DASHBOARDS`; it is still unshot, because the window wants a clean day
      behind it rather than the hour after a deploy.

- **[#77](https://github.com/Gerrrt/HomeLab/issues/77) Schedule something.**
      Four systemd timers *are written* to run `make backup` weekly,
      `make backup ARGS='--verify-only --all'` and `make backup-firewall` nightly,
      and `make snmp-verify` weekly; `make check-digests` runs weekly in GitHub
      Actions, which is the only one of the five that is genuinely off-host.
      **Installing them on the monitoring host is a separate step
      (`make install-timers`) and it was missed** — for the first days of this
      entry's life the sentence above was in the present tense and simply untrue,
      no unit was installed, and no scheduled job had ever run
      ([#215](https://github.com/Gerrrt/HomeLab/issues/215)). `make validate`
      passed throughout, because the check it ran compared two copies of the
      schedule that both live in git. It now also asks the host.
      Every run records its outcome as a metric, so five rules in
      `backup.rules.yaml` alert on a job having *stopped being run* rather than
      only on one that failed — which was the actual ask.
      `make secrets-verify-backup` deliberately has no timer: it needs a human to
      mount removable media, so it gets a ninety-day deadline and an alert
      instead. What this does **not** solve is that the host still verifies its
      own backups — #535 sends the sets to `oracle` and hashes them there, but
      the judge is still this host; that is #99, still open.
      → [runbook](runbooks/schedule-maintenance.md)

## 2026-08-21

- **[#12](https://github.com/Gerrrt/HomeLab/issues/12) Capture dashboard
  screenshots.** `make screenshots` does five of the seven; the Logs and
  Security dashboards are deliberately excluded.
  → [`images/README.md`](images/README.md)

Two collection faults of the same kind were fixed in
[#62](https://github.com/Gerrrt/HomeLab/pull/62): the agent was answering to the
name of the server, and cAdvisor could only see its own cgroup. Both ran healthy
and produced nothing.

[#63](https://github.com/Gerrrt/HomeLab/issues/63) was the same fault one layer
up. `ContainerHighMemory` divided by a memory limit no service sets and guarded
on it being non-zero, so it could not fire for any input while showing as loaded
and healthy. It now measures against the host total instead. `promtool check
rules` had passed it the entire time — it parses PromQL and never asks whether
an expression can be true — so the fix came with the first `promtool test rules`
unit tests in the repo, which fail if the rule stops being able to fire. They
cover that one rule. The other 33 are still syntax-checked only, so the same
class of fault could be sitting in any of them and would look just as healthy.

It was, in the rule directly above it.
[#305](https://github.com/Gerrrt/HomeLab/issues/305) is `ContainerRestartLoop`,
which counted `changes()` of `container_start_time_seconds` — a metric that
reports the container's *creation* time and therefore does not move when Docker
restarts one in place, which is what `restart: unless-stopped` does to every
service here. Where a start time would genuinely differ, a recreate, it is a new
container id and so a new series carrying a different constant, and `changes()`
is per-series. Measured against a deliberately crash-looping container: 38
restarts, and the expression returned six series every one of which was `0`,
against a threshold of `3`. Nothing else cAdvisor exports moves either — the
cgroup scope is reused across restarts, so the CPU counter does not reset. What
moves is the series identity, because cAdvisor synthesises a `restartcount`
label and emits it only while non-zero, so the fix counts generations rather
than changes. Found while measuring for #114 rather than by looking, which is
the uncomfortable part: two of the four rules in that file could not fire, and
both were found by accident.
Setting the memory limits themselves is
[#114](https://github.com/Gerrrt/HomeLab/issues/114), deliberately separate: a
limit enforces, a rule detects, and making the second depend on the first is
what left this one unfireable for months.

- **[#99](https://github.com/Gerrrt/HomeLab/issues/99) Move deployment from
  `make up` over SSH to something pull-based**, so the host converges on the repo
  rather than being pushed to. Answered by
  [ADR-0021](adr/0021-converge-on-a-timer-instead-of-deploying-over-ssh.md): an
  hourly timer running `scripts/converge.sh`, on #77's existing wrapper and
  alert machinery. The issue's stated blocker — an age key on a host that pulls
  from a public repository — turned out not to be one, because the key was
  already on that host and *public* means readable. The real question was
  unattended execution, and the answer is a pinned signing fingerprint plus a
  record of every revision deployed. What is deliberately left out: `oracle` and
  `saruman` are still pushed to with `deploy-agent.sh`, and nothing tracks
  unifying that.

- **Enable Suricata on `morpheus`.** Running on Skids (VLAN 20) alert-only
      since 2026-08-21; alerts reach Loki with classification and priority parsed
      into labels, verified against real traffic. First tuning decision made from
      measurement rather than prediction: sid 2200121 "Ethertype unknown" was
      100% of alerts and turned out to be LLDP from `neo`, suppressed by
      signature rather than by disabling the whole `decoder-events` category.
      → [runbook](runbooks/enable-suricata.md) · ADR-0006

- **Turn on remote logging on `morpheus`.** The firewall now ships filterlog
      to Loki, so `TerminalSegmentReachedInternalNetwork` and
      `IoTAttemptedLateralMovement` have input for the first time. pfSense saved
      the settings without restarting `syslogd` and sent nothing until the page
      was saved a second time — the runbook now says so, and says to confirm on
      the wire with tcpdump before believing an empty query.
      → [runbook](runbooks/ship-firewall-logs.md)

- Add alerting (34 rules) and Alertmanager routing

## 2026-08-20

- Settle the `10.0.30.10` question. It is the iLO BMC on its dedicated port;
      the Proxmox host is `Saruman` at `10.0.30.110`. The SNMP target's
      `hypervisor-bmc` role label was correct all along — the inventory was not

## 2026-08-19

- Replace the CA and leaf certificates that leaked, and add tooling so
      issuing one is a command rather than a research project

- Serve Grafana over TLS with that CA, verified end to end — Prometheus
      scrapes it with `ca_file` and `server_name` rather than
      `insecure_skip_verify`

- Point Alertmanager at a real receiver. The webhook was the
      `ntfy.example.invalid` placeholder for the entire life of the stack, so
      no alert had ever been delivered

- Surface firing alerts on the dashboards. Forty rules and one routing tree
      existed with nothing showing them; four dashboards now carry a table of
      their own component's alerts

- Stop the UPS dashboard reporting a battery that is not there — the
      management card fabricates charge, runtime and status

- Purge the shared SNMP community, the inline Grafana password and the
      TLS private keys under `certificates/` from git history, and delete the
      `.gitleaksignore` that acknowledged them

- Give every SNMP device its own community and rotate all four on the
      hardware, confirming pfSense, the APC NMC and iLO each refuse the old
      shared string. The switch accepts its new one but also still holds its
      previous community — an accepted residual, recorded in `SECURITY.md`

## 2026-08-02

- Bridge mode on the ISP gateway

- Lock down guest VLAN firewall rules

- Move IoT devices onto their own SSID and VLAN

- Stand up Prometheus, Grafana, Loki, snmp-exporter and Alloy

- Consolidate five broken compose files into one working stack

- Provision Grafana datasources and dashboards from files

- Move secrets to SOPS + age

- Add CI: lint, config validation, secret scanning

- Pin every image by digest, not just tag, with drift detection in CI

- Add SECURITY.md with a disclosure policy and known-exposure summary

- Loki alerting rules (13) for auth, SSH brute force and disk/OOM events,
      validated in CI by booting the pinned Loki image against them
