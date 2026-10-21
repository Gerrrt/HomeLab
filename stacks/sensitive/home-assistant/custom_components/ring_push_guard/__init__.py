"""Keep the Ring integration's push receiver alive (ADR-0101).

ring_doorbell 0.9.14 parses each Ring push with
``RingEventListener._get_ring_event``, which reads ``event["ding"]["id"]``.
Since about July 2026 some Ring pushes have no ``ding.id``, and the parser
raises ``KeyError``. firebase_messaging shuts the push receiver down after
three errors in a row, and from then on no Ring motion or doorbell event
reaches Home Assistant until the integration restarts
(python-ring-doorbell/python-ring-doorbell#537). The fixes, #540 and #556,
are open upstream and unreleased.

This replaces that one method, for 0.9.14 only, with the same parser plus
the fallbacks those PRs use: ``ding.id``, else ``eventito.timestamp``
(#556), else ``created_at`` in milliseconds (#540). Anything it still
cannot parse is skipped and logged at debug level rather than raised, so a
malformed push can no longer stop the receiver.

Any other ring_doorbell version is left alone, with a warning, because a
newer one is expected to carry the fix. Then this component and its
package are to be deleted.
"""

from __future__ import annotations

import json
import logging
from importlib import metadata
from typing import Any

from homeassistant.config_entries import ConfigEntryState
from homeassistant.core import HomeAssistant
from homeassistant.helpers.typing import ConfigType

DOMAIN = "ring_push_guard"
PATCHED_VERSIONS = frozenset({"0.9.14"})

_LOGGER = logging.getLogger(__name__)


def _event_id(event: dict[str, Any], created_seconds: float) -> int:
    """Return a stable id for the event, as the upstream fixes do."""
    ding = event["ding"]
    if ding.get("id") is not None:
        return int(ding["id"])
    timestamp = (event.get("eventito") or {}).get("timestamp")
    if timestamp is not None:
        return int(timestamp)
    return int(created_seconds * 1000)


def build_parser(listener_module: Any) -> Any:
    """Return a replacement for RingEventListener._get_ring_event.

    The body is 0.9.14's, with the id taken from ``_event_id`` and every
    parse failure turned into ``None``, which the caller already treats as
    "unknown event".
    """
    mod = listener_module

    def _get_ring_event(self: Any, msg_data: dict) -> Any:
        try:
            if (android_config_str := msg_data.get("android_config")) is None or (
                data_str := msg_data.get("data")
            ) is None:
                return None
            android_config = json.loads(android_config_str)
            data = json.loads(data_str)
            event_kind = mod.PUSH_NOTIFICATION_KINDS.get(android_config["category"], "Unknown")
            device = data["device"]
            event = data["event"]
            created_at = event["ding"]["created_at"]
            created_seconds = mod.parse_datetime(created_at).timestamp()
            return mod.RingEvent(
                _event_id(event, created_seconds),
                device["id"],
                device_name=device.get("name"),
                device_kind=device.get("kind"),
                kind=event_kind,
                now=created_seconds,
                expires_in=mod.DEFAULT_LISTEN_EVENT_EXPIRES_IN,
                state=event["ding"]["subtype"],
            )
        except (KeyError, TypeError, ValueError, AttributeError) as err:
            _LOGGER.debug("Skipped a Ring push it could not parse: %r", err)
            return None

    return _get_ring_event


def apply_patch() -> bool:
    """Patch the listener if the installed ring_doorbell is a known one."""
    try:
        version = metadata.version("ring_doorbell")
    except metadata.PackageNotFoundError:
        _LOGGER.warning("ring_doorbell is not installed; nothing to patch")
        return False
    if version not in PATCHED_VERSIONS:
        _LOGGER.warning(
            "ring_doorbell is %s, not one this patch was written for (%s). "
            "Not patched. If that release fixes the missing ding.id, delete "
            "ring_push_guard (ADR-0101)",
            version,
            ", ".join(sorted(PATCHED_VERSIONS)),
        )
        return False

    from ring_doorbell.listen import eventlistener

    listener = eventlistener.RingEventListener
    if getattr(listener._get_ring_event, "_ring_push_guard", False):
        return True
    patched = build_parser(eventlistener)
    patched._ring_push_guard = True  # type: ignore[attr-defined]
    listener._get_ring_event = patched
    _LOGGER.info("Patched ring_doorbell %s RingEventListener._get_ring_event", version)
    return True


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Apply the patch, and restart a Ring listener that started before it."""
    if not await hass.async_add_executor_job(apply_patch):
        return True
    # If Ring set up first, its listener may already have met a malformed
    # push and stopped. One reload starts it again with the patch in place.
    for entry in hass.config_entries.async_entries("ring"):
        if entry.state is ConfigEntryState.LOADED:
            _LOGGER.info("Reloading the Ring integration so its listener uses the patch")
            hass.async_create_task(hass.config_entries.async_reload(entry.entry_id))
    return True
