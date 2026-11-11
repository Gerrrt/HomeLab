"""Let the Apple TV config flow find the HomePods by address (ADR-0113).

Home Assistant's Apple TV config flow adds a device by address with pyatv's
``ZeroconfUnicastScanner``. When multicast answers do not arrive, which is
always the case across subnets, the scanner falls back to unicast PTR
queries for the service types it is still missing. pyatv 0.18.0 takes that
list from a per-host table built in ``__init__``, before the protocols have
registered their service types, so the table only holds device info and
sleep proxy. The fallback then asks the device for ``_device-info._tcp``
alone. A HomePod does not answer that query, and the scan finds nothing
(postlund/pyatv#2929).

This replaces ``ZeroconfUnicastScanner._lookup_services_and_models``, for
0.18.0 only, with 0.18.0's body plus the change in postlund/pyatv#2930: the
fallback asks for every service type registered with the scanner, so
``_airplay``, ``_companion-link`` and ``_raop``, which the HomePods do
answer, are asked for too. Nothing else in pyatv is touched.

The integration scans this way in two places: the config flow, when a
HomePod is added by address, and every connect or reconnect of an entry it
has added. Nothing is reloaded after patching. An entry that set up before
this component loaded found nothing and keeps retrying in its connect loop,
the first retry after 15 seconds and never more than five minutes apart, and
the retries scan with the patch in place.

Any other pyatv version is left alone, with a warning, because a newer one
is expected to carry the fix. When a fixed pyatv reaches Home Assistant,
this component and its package are to be deleted.
"""

from __future__ import annotations

import logging
from importlib import metadata
from typing import Any

from homeassistant.core import HomeAssistant
from homeassistant.helpers.typing import ConfigType

DOMAIN = "pyatv_scan_guard"
PATCHED_VERSIONS = frozenset({"0.18.0"})

_LOGGER = logging.getLogger(__name__)


def build_lookup(scan_module: Any) -> Any:
    """Return a replacement for ZeroconfUnicastScanner._lookup_services_and_models.

    The body is 0.18.0's. The one change is how ``needed_types`` is built,
    as in postlund/pyatv#2930.
    """
    mod = scan_module

    async def _lookup_services_and_models(self: Any, zc_timeout: float) -> Any:
        """Lookup services and aggregate them by address."""
        infos = self._build_service_info_queries()
        if await self._load_from_cache_or_send_queries(infos, zc_timeout):
            return self._process_matching_service_infos()

        # Multicast is likely broken, the device is offline, or the network
        # is dropping multicast responses. Send unicast PTR queries for the
        # missing types.
        infos_by_address_type = self.infos_by_address_type
        # Ask for every service type registered with the scanner. Protocols
        # register theirs after the scanner is created, so the per-host table
        # built in __init__ only knows device info and sleep proxy (#2929).
        all_types = [f"{service_type}." for service_type in self._services]
        for host in self.hosts:
            # Sleep proxy is not asked for: it is not useful when multicast
            # is broken, and service discovery does not need it.
            if needed_types := [
                type_
                for type_ in all_types
                if type_ != mod.SLEEP_PROXY_TYPE and infos_by_address_type[host].get(type_) is None
            ]:
                mod._LOGGER.debug(
                    "%s: Multicast is broken or device offline, trying unicast PTR queries for %s",
                    host,
                    needed_types,
                )
                self._send_ptr_queries(host, needed_types)

        # There is no way to know when the PTR queries are answered, so wait
        # for the timeout, then read the cache again and refresh any
        # incomplete info.
        await mod.asyncio.sleep(zc_timeout / 1000)
        infos = self._build_service_info_queries()
        await self._load_from_cache_or_send_queries(infos, zc_timeout)
        return self._process_matching_service_infos()

    return _lookup_services_and_models


def apply_patch() -> bool:
    """Patch the unicast scanner if the installed pyatv is a known one."""
    try:
        version = metadata.version("pyatv")
    except metadata.PackageNotFoundError:
        _LOGGER.warning("pyatv is not installed; nothing to patch")
        return False
    if version not in PATCHED_VERSIONS:
        _LOGGER.warning(
            "pyatv is %s, not one this patch was written for (%s). Not "
            "patched. If that release asks for every service type in the "
            "unicast scan (postlund/pyatv#2929), delete pyatv_scan_guard "
            "(ADR-0113)",
            version,
            ", ".join(sorted(PATCHED_VERSIONS)),
        )
        return False

    from pyatv.core import scan

    scanner = scan.ZeroconfUnicastScanner
    if getattr(scanner._lookup_services_and_models, "_pyatv_scan_guard", False):
        return True
    patched = build_lookup(scan)
    patched._pyatv_scan_guard = True  # type: ignore[attr-defined]
    scanner._lookup_services_and_models = patched
    _LOGGER.info("Patched pyatv %s ZeroconfUnicastScanner._lookup_services_and_models", version)
    return True


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Apply the patch. Apple TV entries pick it up on their next connect attempt."""
    await hass.async_add_executor_job(apply_patch)
    return True
