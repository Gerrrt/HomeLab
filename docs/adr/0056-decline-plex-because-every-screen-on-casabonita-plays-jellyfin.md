# ADR-0056: Decline Plex because every screen on CasaBonita plays Jellyfin

**Status:** Accepted · 2026-09 · decides [#139](https://github.com/Gerrrt/HomeLab/issues/139)

## Context

[ADR-0008](0008-place-services-by-data-trust.md) lists the media tier as
Jellyfin "with Plex beside it for household convenience".
[ADR-0016](0016-open-casabonita-inward-and-keep-it-terminal-outward.md) built
Jellyfin alone and deferred Plex against one test: whether any screen on 40
has no working Jellyfin client. It named the two candidates most likely to
fail, the Xumo box and a console, and said that if either could only do Plex,
Plex would be installed.

[#139](https://github.com/Gerrrt/HomeLab/issues/139) set out what Plex would
cost. It is the one entry on the shortlist that awesome-selfhosted files under
`non-free.md` rather than its README, and it fails this repository's usual
tests in three ways:

1. **It phones home by design.** Clients authenticate through `plex.tv` even
   on a local network. A segment with no inbound path would take on an
   outbound dependency on a third party, and it would be the only service
   here where an outage elsewhere stops a local device playing a local file.
2. **Digest pinning buys less.** Pinning still fixes the bits, but nobody
   outside the vendor can read them. `security.md` accepts image supply-chain
   compromise as undefended, and pinning is what narrows it.
3. **It can be repriced.** Features have moved behind a subscription before,
   hardware transcoding among them.

Jellyfin has been deployed on `smaug` since 2026-09-19
([#138](https://github.com/Gerrrt/HomeLab/issues/138)), so the test could be
run. It was run by 2026-09-28:

- The **LG OLED**, the primary screen, plays from Jellyfin.
- **A console** plays from Jellyfin.
- **The household's phones and tablets** play from Jellyfin.
- **The Xumo Stream Box** (`streambox`, `10.0.40.101` in `network.md`) is on
  40, but nobody plays library media on it. A screen that no one uses for the
  library cannot be the reason for a service that serves the library.

No screen used for media lacks a working Jellyfin client.

## Decision

**Do not deploy Plex.** Its entry in ADR-0008's list is withdrawn, and
`stacks/media/` stays without it.

This is the branch #139 recommended for the case where the household did not
complain. The estate keeps the property that every service in it can be
inspected, pinned, and reasoned about. ADR-0016's deferral is resolved by its
own test, and its reasoning stands. It is not superseded.

## Consequences

- **ADR-0008's service list is amended.** ADR-0016 deferred Plex and said
  explicitly that it was not amending ADR-0008. This record is the amendment:
  the media tier is Jellyfin, Audiobookshelf and Navidrome, with no Plex
  beside them. ADR-0008's reasoning about the tiers is untouched.
- **The media tier stays without secrets.** `security.md` ends that exception
  only when a service on the tier takes a credential from outside. A Plex
  claim token and account would have been the first. Nothing here takes one.
- **No firewall change, and none was ever pending.** The 50→40 pass #139
  inherited from #138 serves Jellyfin, and no path outward is added for
  `plex.tv`.
- **Plex Pass leaves the purchase list.** Quick Sync already gives Jellyfin
  hardware transcoding for nothing
  ([ADR-0040](0040-run-truenas-on-smaug-and-keep-the-media-stack-in-this-repository.md)).
- **`roadmap.md`'s "Considered and declined" list gains an entry**, so the
  next time Plex comes up, the argument starts from this record.
- **Reopened by a screen that the household actually uses for library media
  and that has no working Jellyfin client.** That could be the Xumo box, if
  the household starts using it for the library, or a new device. Even then,
  Remote Access stays off. It exists to create an inbound path, and this
  estate has none.
