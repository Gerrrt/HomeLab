# ADR-0109: Patch firebase_messaging's header parsing locally until upstream ships a fix

**Status:** Accepted · 2026-11

## Context

[ADR-0101](0101-patch-ring-doorbells-push-parser-locally-until-upstream-ships-a-fix.md)
patched `ring_doorbell`'s push parser so that Ring pushes without a `ding.id`
could no longer stop the receiver. It was not enough. On 2026-11-10 the Ring
`event.*` entities on `trinity` had recorded no real motion or doorbell event
in the recorder's ten days, back to 2026-10-31. The log held a different
failure, one layer down:

```text
ERROR [firebase_messaging.fcmpushclient] Unknown error: Incorrect padding, shutting down FcmPushClient.
```

`ring_doorbell` receives Ring's pushes through `firebase_messaging`, 0.4.5 in
the pinned image. Before decrypting a push, it takes the key and the salt out
of the `crypto-key` and `encryption` headers by position: `[3:]` to drop
`dh=`, `[5:]` to drop `salt=`. Both headers are lists of `;`-separated
parameters in no fixed order (RFC 8188 §2.1, RFC 8291 §4). Some Ring pushes
now carry `dh=<key>; p256ecdsa=<key>`, and the slice leaves the second
parameter attached. Decoding fails with `binascii.Error: Incorrect padding`,
or with `ValueError: Invalid EC key` if the length happens to fit.
firebase_messaging treats either as an unknown error and shuts the client
down for good. ADR-0101's patch runs later, on decrypted pushes, so it never
sees this.

The failure comes before the push is acknowledged, so FCM sends it again on
every reconnect, and the client dies again within seconds of logging in. A
restart does not clear it. Upstream knows: sdb9696/firebase-messaging#44
describes this exact header, and #40 and #42 the same symptom. Home Assistant
users report it in home-assistant/core#173915 and #189885. The fix,
firebase-messaging#43 (look parameters up by name and restore the padding),
and the wider #46 are open. firebase-messaging has released nothing since
0.4.5 in May 2025.

## Decision

**Add a second patch to `ring_push_guard`, scoped to firebase_messaging
0.4.5, and delete it when a fixed release reaches Home Assistant.**

- `custom_components/ring_push_guard/fcm_patch.py` wraps
  `FcmPushClient._handle_data_message`. It adds nothing to the mount, the
  package or the compose file: it is a second module in the component
  ADR-0101 decided on.
- Before the original runs, the wrapper rewrites the two headers to the one
  parameter each slice expects. It looks up `dh` and `salt` by name and
  restores their base64 padding, as #43 does. The original then decrypts as
  it always has.
- If handling a push still raises, the wrapper logs *Dropped a push it could
  not decrypt*, with the header lengths and parameter names but no key
  material, and returns. The caller then acknowledges the push as usual, so
  FCM does not send it again. A push that cannot be read is lost either way.
  Dropping it costs one event, and stopping on it cost every event after it.
- It applies only when `firebase_messaging` is 0.4.5. On any other version it
  patches nothing and logs a warning to delete it.
- The component already reloads the Ring entry once at start, so a client
  this bug has already stopped restarts with the patch in place.
- [#1383](https://github.com/Gerrrt/HomeLab/issues/1383) tracks the removal.
  The two patches retire separately. When both have gone, the component and
  its package go with them.

Tested in the pinned image, against its own firebase_messaging 0.4.5, with
pushes encrypted by `http_ece` for a generated key:

- **Unpatched,** a push whose `crypto-key` is `dh=…; p256ecdsa=…` raises
  `binascii.Error: Incorrect padding`, as in the log on `trinity`.
- **Patched,** that push, a plain `dh=…` push, and one with `p256ecdsa`
  first all decrypt and reach the callback. A push whose key cannot be
  decoded is logged and dropped, without raising. Applying the patch twice
  is a no-op.

## Alternatives considered

- **Wait for upstream.** Every real-time Ring event stays dead in the
  meantime, and firebase-messaging has gone eighteen months without a
  release. Declined.
- **Patch only the padding.** It turns `Incorrect padding` into `Invalid EC
  key`, because the second parameter is still attached. #43 shows this in
  detail. Declined.
- **Only catch the error, without reading the headers by name.** The client
  survives, but it drops every two-part push, and Ring sends real events in
  that shape. Declined.
- **A separate custom component.** A second mount and package for the same
  receiver, with no gain. Declined.

## Consequences

- **We own a second copy of upstream code:** #43's header parser, about
  twenty lines. If 0.4.5 is replaced by another version, the patch stops
  applying and says so.
- **A push that still cannot be decrypted is dropped and acknowledged,** not
  retried. The warning in the log is the record of it. 0.4.5 would have
  dropped it too, and then stopped.
- **Reopened by:** a Home Assistant release that pulls a firebase-messaging
  with #43 or an equivalent, which retires this patch (#1383). Or a
  *Dropped a push* warning that names a header shape this does not read,
  which would be worth an upstream report.
