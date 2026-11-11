# ADR-0113: Patch pyatv's unicast scan locally until upstream ships a fix

**Status:** Accepted · 2026-11

## Context

[ADR-0099](0099-control-the-homepods-from-home-assistant-and-leave-their-audio-out.md)
decided that Home Assistant controls the four HomePods on Skids through the
core Apple TV integration, adding each one by address. The network side is in
force: the HomePods hold reservations at `10.0.20.21`–`.24`, `morpheus` passes
`10.0.99.40` to them, and Skids NATs that traffic to its own address. The
integration still cannot add a HomePod.

The Apple TV integration finds a device with pyatv, 0.18.0 in the pinned
image. To add one by address, and on every later connect or reconnect, it
calls pyatv's `scan` with the address and Home Assistant's shared zeroconf
instance, which runs `ZeroconfUnicastScanner`. When nothing for that address
is in the zeroconf cache, which is always the case across subnets, the
scanner falls back to unicast PTR queries for the service types it is still
missing. pyatv 0.18.0 takes that list from a per-host table built in the
scanner's `__init__`, before the protocols register their service types. The
table holds only device info and the sleep proxy, so the fallback asks the
device for `_device-info._tcp` alone. The HomePods answer `_airplay`,
`_companion-link` and `_raop`, and do not answer `_device-info`, so the scan
finds nothing (postlund/pyatv#2929).

The fix, postlund/pyatv#2930, builds the list from the service types
registered when the fallback runs. It is nine lines in one method, and has
been open since 2026-10-21 with no review: its CI waits for a maintainer's
approval. pyatv has had no commit since the 0.18.0 release on 2026-06-19.
Home Assistant 2026.11.1, the pinned image, and its `dev` branch both pin
`pyatv==0.18.0`.

ADR-0101 settled how this repository carries a fix upstream has not shipped:
as a custom component written and reviewed here, gated on the library version
it was written for, mounted read-only, and deleted when the fix arrives.
ADR-0110 added a second patch the same way.

## Decision

**Carry #2930 as a second custom component, `pyatv_scan_guard`, scoped to
pyatv 0.18.0, and delete it when a fixed release reaches Home Assistant.**

- `stacks/sensitive/home-assistant/custom_components/pyatv_scan_guard/`,
  loaded by `packages/pyatv_scan_guard.yaml`. It uses the read-only
  `custom_components` mount ADR-0101 added, so the compose file gains no
  mount.
- It replaces one method, `ZeroconfUnicastScanner._lookup_services_and_models`,
  with 0.18.0's body and #2930's change: the fallback asks for every
  registered service type except the sleep proxy that the scanner has not
  found yet. Nothing else in pyatv changes. When multicast works, the cache
  answers first and the fallback never runs.
- It applies only when pyatv is 0.18.0. On any other version it patches
  nothing and logs a warning to delete it.
- It reloads nothing. The config flow scans when a HomePod is added. An entry
  that set up before the component loaded found nothing and keeps retrying in
  its connect loop, first after 15 seconds and then never more than five
  minutes apart, and those retries scan with the patch in place.
- A separate component, not a third patch in `ring_push_guard`: the two have
  nothing in common but the mount, and each retires on its own.
- [#1393](https://github.com/Gerrrt/HomeLab/issues/1393) tracks the removal.

Tested before merge, in the pinned image:

- **In a container with no network,** a scan by address with the cache empty
  sends unicast PTR queries for `_device-info._tcp` only when unpatched. When
  patched it also asks for `_airplay`, `_companion-link`, `_raop` and the
  protocols' other types, never the sleep proxy. Applying the patch twice is
  a no-op, and another pyatv version is left unpatched with the warning.
- **Against the HomePods,** from a container on `sensitive_sensitive` with a
  started zeroconf instance, as Home Assistant's is: unpatched, the scan of
  `10.0.20.21`–`.23` found none of them in 3 runs. Patched, it found `.21` and
  `.23` in each of 6 runs. `.22` answered no mDNS at all that day, not even
  pyatv's plain unicast query, so it was asleep or offline, not missed by
  the scan.

## Alternatives considered

- **Wait for upstream.** The HomePods stay out of Home Assistant until a
  pyatv release with #2930 and then a Home Assistant release that pins it.
  pyatv has released nothing in five months, and #2930 has had no review.
  Declined.
- **Install a patched pyatv into the image,** from a fork or a wheel. It is a
  second package source outside `compose.yaml`'s digest pin, in the tier that
  holds every device credential, and it means building our own Home Assistant
  image. Declined, as ADR-0101 declined HACS.
- **A copy of the Apple TV integration as a custom component** with its own
  pyatv requirement. Home Assistant would install that pyatv at run time,
  which is the same trade. Declined.
- **Carry the HomePods' multicast to Winterfell** with an mDNS reflector, so
  the cache fills and the fallback never runs. It would bring every Skids
  device's announcements onto the most trusted segment, and Home Assistant,
  on Docker's bridge network as ADR-0099 keeps it, would not receive them
  anyway. Declined.

## Consequences

- **We own a copy of upstream code:** 0.18.0's method, about forty lines with
  #2930's change. If 0.18.0 is replaced by another version, the patch stops
  applying and says so.
- **The fallback asks for more types,** about nine instead of one. That is
  one query packet per host per scan, sent only when the cache did not
  answer.
- **Reopened by:** a Home Assistant release that pins a pyatv with #2930 or
  an equivalent, which retires this component (#1393). Or a pyatv change that
  moves the scan to another method, which the version gate catches first.
