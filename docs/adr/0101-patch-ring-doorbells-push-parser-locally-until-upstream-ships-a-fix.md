# ADR-0101: Patch ring_doorbell's push parser locally until upstream ships a fix

**Status:** Accepted · 2026-10

## Context

Home Assistant receives Ring's motion and doorbell events through the core
`ring` integration, which uses the `ring_doorbell` library (0.9.14 in the
pinned image). The library listens for Ring's pushes with `firebase_messaging`
and parses each one in `RingEventListener._get_ring_event`, which reads
`event["ding"]["id"]`.

Since about July 2026 some Ring pushes arrive without `ding.id`. The parser
raises `KeyError: 'id'`. firebase_messaging catches the exception, and after
three in a row it logs *"Shutting down push receiver due to 3 sequential
errors"* and stops. From then on **no Ring motion or doorbell event reaches
Home Assistant**, for any device, until the integration restarts. On `trinity`
the receiver died at 13:12 and again at 14:09 on 2026-10-21, the second time
seconds after a restart, because the restart replayed queued pushes. The log
held 29 such errors in 72 hours. The doorbell alerts in
`packages/doorbell.yaml` cannot fire while this lasts.

Upstream knows: python-ring-doorbell/python-ring-doorbell#537 and #552 report
it, and two fixes are open, #540 (fall back to `created_at`) and #556 (fall
back to `eventito.timestamp`, ignore the event if neither exists). The project
has released nothing since 0.9.14 on 2026-02-28. Other Home Assistant users run
a community custom component, `ring_push_fix`, that patches the library at
start.

Until now, Home Assistant here has run core integrations only, with no add-ons,
no HACS and no custom components. #134 and the roadmap's declines rule out a
second, unpinned supply chain running inside the tier that holds every device
credential.

## Decision

**Carry our own patch, as one custom component in this repository, scoped to
the version it was written for, and delete it when a fixed release reaches
Home Assistant.**

- `stacks/sensitive/home-assistant/custom_components/ring_push_guard/`, about
  a hundred lines, mounted read-only at `/config/custom_components` and loaded
  by `packages/ring_push_guard.yaml`. Nothing is installed into that directory
  at run time. It is code reviewed in this repository, like the packages.
- It replaces one method, `RingEventListener._get_ring_event`, with 0.9.14's
  body. The id is taken as `ding.id`, else `eventito.timestamp` (#556), else
  `created_at` in milliseconds (#540). Anything still unparseable is skipped
  and logged at debug level rather than raised. Three raised errors are what
  kill the receiver, and a skipped push cannot cause one.
- It applies only when `ring_doorbell` is 0.9.14. On any other version it
  patches nothing and logs a warning to delete it.
- If the Ring integration has set up or is setting up when it loads, it
  reloads the Ring entry once, so a receiver already stopped by a replayed
  push restarts with the patch in place. Ring starts its receiver during
  setup, while the entry still reads `SETUP_IN_PROGRESS`. The reload takes
  the entry's setup lock, so one asked for mid-setup waits for setup to
  finish.
- [#1240](https://github.com/Gerrrt/HomeLab/issues/1240) tracks the removal.

Tested in the pinned image before merge:

- **The original parser** raises `KeyError 'id'` on an id-less push.
- **The patched parser** keeps the real id on a normal push and takes the
  `eventito` or `created_at` fallback on an id-less one. It returns nothing,
  without raising, on a push with no `ding` or that isn't a Ring alert.
- **The real `_on_notification`,** fed three id-less pushes and a malformed
  one, raised nothing and delivered the three events. The library's repeat
  detection still marks the second of two identical pushes as an update.

## Alternatives considered

- **The community `ring_push_fix`.** It does the same thing, but it is code
  from outside this repository running in the most trusted tier, and is
  installed and updated outside `compose.yaml`. That is the trade the no-HACS
  rule refuses.
- **Reload the Ring integration on a timer, or when its events go quiet.**
  Events are lost until each reload, and a reload replays queued pushes that
  can kill the receiver again at once. Declined.
- **Wait for upstream.** Real-time Ring events stay dead in Home Assistant for
  an unknown time, and upstream has shipped nothing in eight months. Declined.
- **Edit the library in the image.** Lost on the next image update, and
  invisible in this repository. Declined.

## Consequences

- **The first custom component on the tier.** It is ours, small, version-gated
  and read-only, and it is no channel for others: the mount is one directory
  of reviewed code. Home Assistant marks it as a custom integration in its log
  at start.
- **We own a copy of upstream's parser.** If 0.9.14 is replaced by another
  version, the patch stops applying and says so. It will not silently patch
  code it was not written against.
- **Event ids for id-less pushes are ours.** They match what #540 and #556
  produce, so moving to the upstream fix changes nothing visible.
- **Reopened by:** a Home Assistant release that pins a fixed `ring_doorbell`,
  which retires this ADR and the component (#1240); or a different parse
  failure that the debug log shows being skipped, which would be worth an
  upstream report.
