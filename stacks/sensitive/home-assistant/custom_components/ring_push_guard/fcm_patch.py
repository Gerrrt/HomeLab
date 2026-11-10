"""Keep firebase_messaging's push client alive on Web Push headers it misreads (ADR-0109).

firebase_messaging 0.4.5 takes the decryption key and salt out of each push
by position: ``crypto-key[3:]`` to drop ``dh=`` and ``encryption[5:]`` to drop
``salt=``. Both headers are lists of ``;``-separated parameters whose order is
not fixed (RFC 8188 section 2.1, RFC 8291 section 4). Since about July 2026
some Ring pushes carry ``dh=<key>; p256ecdsa=<key>``, the slice leaves the
second parameter attached, and decoding fails with ``binascii.Error:
Incorrect padding`` or ``ValueError: Invalid EC key``. The client treats that
as an unknown error and shuts down for good. The failure comes before the
message is acknowledged, so FCM sends it again on every reconnect and the
client dies again within seconds (sdb9696/firebase-messaging#44). The fix,
firebase-messaging#43, is open and unreleased.

This wraps ``FcmPushClient._handle_data_message``, for 0.4.5 only. Before the
original runs, it rewrites the two headers to the one parameter each slice
expects, looked up by name and with its base64 padding restored, as #43 does.
If handling the message still raises, the error is logged and the message is
dropped. The caller then acknowledges it as usual, so it is not sent again.
Errors raised by the notification callback never reach this wrapper: 0.4.5
catches and counts those itself.

Any other firebase_messaging version is left alone, with a warning, because a
newer one is expected to carry the fix.
"""

from __future__ import annotations

import logging
from importlib import metadata
from typing import Any

PATCHED_VERSIONS = frozenset({"0.4.5"})
# Header name in app_data, the parameter 0.4.5's slice expects at its start.
_HEADERS = (("crypto-key", "dh"), ("encryption", "salt"))
# The Web Push parameter names (RFC 8188, RFC 8291, RFC 8292) the warning may
# name. Any other segment is logged as "<other>".
_LOGGABLE_PARAMS = frozenset({"dh", "salt", "rs", "keyid", "p256ecdsa"})

_LOGGER = logging.getLogger(__name__)


def _b64_pad(value: str) -> str:
    """Restore the ``=`` padding stripped from a base64url value."""
    return value + "=" * (-len(value) % 4)


def webpush_header_param(header: str, name: str) -> str:
    """Return one parameter of a Web Push ``Crypto-Key`` or ``Encryption`` header.

    Ported from firebase-messaging#43. The parameter is found by name, so its
    position does not matter, and its padding is restored. A header holding
    a bare value with no ``name=`` prefix is taken as that value. A header
    with parameters but not this one raises ``ValueError``.
    """
    for segment in header.split(";"):
        param, sep, value = segment.strip().partition("=")
        if sep and param == name:
            return _b64_pad(value.strip())
    bare = header.strip()
    # In base64url, "=" only ever appears as trailing padding, so a header
    # with no inner "=" cannot be a parameter list.
    if "=" not in bare.rstrip("="):
        return _b64_pad(bare)
    raise ValueError(f"no {name!r} parameter in the header")


def _normalise_headers(msg: Any) -> None:
    """Rewrite each header in place to the single ``name=value`` 0.4.5 slices."""
    for item in msg.app_data:
        for key, name in _HEADERS:
            if item.key == key:
                item.value = f"{name}={webpush_header_param(item.value, name)}"


def _param_name(segment: str) -> str:
    """Name one header segment for the log, or redact it.

    Only names on the allowlist are logged. A bare value has no name, and its
    text before any "=" is key material, so it is never echoed.
    """
    param, sep, _ = segment.strip().partition("=")
    return param if sep and param in _LOGGABLE_PARAMS else "<other>"


def _shape(msg: Any) -> str:
    """Describe the headers by length and parameter names, never by content."""
    parts = []
    for item in msg.app_data:
        if item.key in {key for key, _ in _HEADERS}:
            names = [_param_name(s) for s in item.value.split(";")]
            parts.append(f"{item.key}: len={len(item.value)} params={names}")
    return "; ".join(parts) or "no crypto headers"


def build_handler(original: Any) -> Any:
    """Return a replacement for FcmPushClient._handle_data_message."""

    def _handle_data_message(self: Any, msg: Any) -> None:
        try:
            _normalise_headers(msg)
            original(self, msg)
        except Exception as err:  # noqa: BLE001 - any error here stops the client
            _LOGGER.warning(
                "Dropped a push it could not decrypt (%s: %s; %s)",
                type(err).__name__,
                err,
                _shape(msg),
            )

    return _handle_data_message


def apply_patch() -> bool:
    """Patch the push client if the installed firebase_messaging is a known one."""
    try:
        version = metadata.version("firebase_messaging")
    except metadata.PackageNotFoundError:
        _LOGGER.warning("firebase_messaging is not installed; nothing to patch")
        return False
    if version not in PATCHED_VERSIONS:
        _LOGGER.warning(
            "firebase_messaging is %s, not one this patch was written for (%s). "
            "Not patched. If that release reads Web Push headers by name, delete "
            "the firebase_messaging patch from ring_push_guard (ADR-0109)",
            version,
            ", ".join(sorted(PATCHED_VERSIONS)),
        )
        return False

    from firebase_messaging.fcmpushclient import FcmPushClient

    if getattr(FcmPushClient._handle_data_message, "_ring_push_guard", False):
        return True
    patched = build_handler(FcmPushClient._handle_data_message)
    patched._ring_push_guard = True  # type: ignore[attr-defined]
    FcmPushClient._handle_data_message = patched
    _LOGGER.info("Patched firebase_messaging %s FcmPushClient._handle_data_message", version)
    return True
