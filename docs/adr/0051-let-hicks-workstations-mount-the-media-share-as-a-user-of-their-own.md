# ADR-0051: Let Hicks workstations mount the media share over `445`, as a user of their own

**Status:** Accepted · 2026-09 · adds a rule to the set
[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md) began
and a second SMB user to the share
[`build-the-nas.md`](../runbooks/build-the-nas.md) §5 created; decides
[#523](https://github.com/Gerrrt/HomeLab/issues/523)

## Context

`erebor/media` has been shared as `media` since 2026-09-18, with one SMB user,
`bilbo`, who can read and write it. **No machine a person sits at can mount
it.** The Hicks passes into CasaBonita are per port, and none is `445`:
`Allow HTTPS to smaug` and `Allow 8096 to smaug` since 2026-09-16, and
`Allow 4533 to smaug` since 2026-09-22. So a Hicks workstation that
administers TrueNAS and plays films in Jellyfin gets nothing from
`\\10.0.40.30\media`. The only devices that can mount it are already on
CasaBonita, and those are televisions and consoles, which do not put films on
a NAS. This was found by trying, on 2026-09-19. The test clip for ADR-0040's
transcode test went in through the console shell with `curl` instead, and
that is still the only way a file reaches the library. That works for a clip,
not for 18 TB.

This is not a fault in the share or in ADR-0016. That ADR opened CasaBonita
inward on named ports for named consumers, and "a workstation writing to the
library" was never named. The consumer was missing from the list; no rule was
added wrong.

The issue weighed two alternatives before this one:

- **A pull from the NAS side.** Something on `smaug` fetches from a
  workstation. That breaks ADR-0016's other half, that nothing on 40
  initiates, and it would need a listener on every workstation instead of
  one on the NAS. Rejected.
- **Loading over the console, and calling the share television-only.** This
  is honest, and it is what the estate does today. It fails on volume, and it
  puts a root shell in the path of every film.

The issue also asked what `bilbo` is for once a workstation can mount the share.
Today it is a credential held by televisions. If workstations used it too,
the password stored in a TV's settings and the one typed on a laptop would be
the same secret, revoked together or not at all.

## Decision

1. **A pass: `vlan50 net → 10.0.40.30:445/tcp`**, described
   **`Allow SMB to smaug`**, above *Block access to CasaBonita* on Hicks
   (`igc0.50`). It has the same shape as the three Hicks passes that exist: a
   rule of its own, host-scoped, port-scoped, and not a port added to another
   rule, because §0.6 matches on the description. It is named for the service,
   as `Allow HTTPS` and `Allow SSH` are, because `445` is a well-known port.
   The named consumer that
   [ADR-0012](0012-publish-only-ports-with-an-off-host-consumer.md) requires is
   **a Hicks workstation loading files into the library.**

2. **`445` only.** Every client this estate has speaks SMB 2 or 3 directly
   over TCP on `445`. NetBIOS on `137`–`139` is for name browsing and SMB1,
   and neither crosses a routed segment usefully. The share is reached by
   address, `\\10.0.40.30\media` or `smb://10.0.40.30/media`, not discovered.
   SMB1 stays off on the NAS, and §5 checks it once the rule exists.

3. **A second SMB user, `samwise`, for workstations. `bilbo` stays the
   televisions' credential, unchanged.** `samwise` gets `bilbo`'s shape: SMB
   on, and TrueNAS access, shell, SSH and sudo all off. Its password is typed
   on workstations and never goes into a television. It gets write access the
   way `bilbo` did, by joining `builtin_users`, which the share's preset ACL
   already grants Modify. Neither credential can be revoked by accident when
   the other is. Making `bilbo` read-only was considered and deferred: it
   means changing the share's ACL, which is a separate change with its own
   test.

4. **Created by hand, then proved, in the order the other passes were.** Make
   `samwise` first, then create the rule and check its position from
   `morpheus`. Then mount from a Hicks workstation and confirm the monitoring
   host is still refused on `445`. [`build-the-nas.md`](../runbooks/build-the-nas.md)
   §5 is the procedure. The documents describe the rule as specified until
   that has been done, as they did for `4533`.

## Consequences

- **All of Hicks can reach one more service on the NAS, and it is one that
  writes.** The source is `vlan50 net`, like the other Hicks passes, and not
  one workstation's address, because the workstations take DHCP leases and a
  pass pinned to a lease is a pass that breaks quietly. Everything on Hicks
  could already reach the TrueNAS UI on `443`, so who can reach the NAS does
  not change. What changes is that a second authenticated service sits behind
  the same boundary. That includes the corporate laptop, which `security.md`
  places on VLAN 50 with no management access. It can now reach an SMB login
  prompt, as it already reaches the TrueNAS one.
- **A workstation holding `samwise`'s password can delete or encrypt the
  library.** That is what write access to a share means, and it is the reason
  for the second user: the credential that does this lives on machines a
  person uses, not on televisions. `erebor/media` is not in the nightly
  snapshot, which covers `erebor/apps` only (§4.1). ADR-0008 accepts that the
  library is replaceable, so this is accepted. Snapshotting `erebor/media`
  would be a separate decision, and it is not made here.
- **The monitoring host cannot probe `445`**, as with `8096`, `4533` and
  `13378`. The Winterfell passes are `9100` and `22` only. Nothing alerts if
  the SMB service stops. Someone trying to copy a file finds out.
- **CasaBonita's terminal property is unchanged.** Hicks initiates, state
  carries the replies, and the `igc0.40` tripwire's packet count stays zero.
  ADR-0016's *Reaches* column does not move.
- **This does not settle [#446](https://github.com/Gerrrt/HomeLab/issues/446).**
  That issue is the ISO store for `Saruman`: the same share shape reached from
  VLAN 30, with its own consumer and its own rule. #523 said the two should be
  created in one sitting if both are created. #446 is not ready, so this one
  goes first, alone.
- **ADR-0016 is not superseded.** Its rule set grows by one row of the kind it
  already has, and it gains a pointer here, as it did for ADR-0050.
