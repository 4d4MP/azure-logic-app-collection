"""AbuseIPDB enrichment shard for the ``blob-review`` playbook.

One HTTP-triggered function, ``POST /api/enrich-ips``. The Logic App splits the
blocklist blob into five shards and calls this endpoint five times in parallel;
each invocation checks its own shard against AbuseIPDB with ``concurrency``
in-flight lookups (default 10), so the API gateway sees 5 x 10 = 50 concurrent
requests.

The *filter* lives in the request, not in this code: the caller supplies
``vendorKeywords`` and ``extraInternalCidrs``, so the criteria can be changed by
editing a Logic App parameter without redeploying the function.

Request body::

    {
      "shard": 1,                                   optional, echoed back
      "ips": ["1.2.3.4", "10.0.0.0/8", ...],        required
      "vendorKeywords": ["lufthansa", "lido", ...], optional
      "extraInternalCidrs": ["203.0.113.0/24"],     optional
      "maxAgeInDays": 90,                           optional
      "concurrency": 10                             optional
    }

Response body::

    {
      "shard": 1,
      "counts": {"requested": n, "checked": n, "internal": n, "vendor": n,
                 "findings": n, "skipped": n, "invalid": n, "errors": n},
      "results": [ ...finding rows only... ],
      "skipped": [...], "invalid": [...], "errors": [...],   capped, see counts
      "truncated": false
    }

``results`` carries **findings only**. ``counts`` is always the true total, so a
capped diagnostic array never hides how much was dropped.
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import os
import random
import re
from typing import Any

import azure.functions as func
import httpx

ABUSEIPDB_CHECK_URL = "https://api.abuseipdb.com/api/v2/check"

DEFAULT_CONCURRENCY = int(os.environ.get("ABUSEIPDB_MAX_CONCURRENCY", "10"))
DEFAULT_MAX_AGE_DAYS = int(os.environ.get("ABUSEIPDB_MAX_AGE_DAYS", "90"))
REQUEST_TIMEOUT_SECONDS = float(os.environ.get("ABUSEIPDB_TIMEOUT_SECONDS", "30"))
MAX_ATTEMPTS = int(os.environ.get("ABUSEIPDB_MAX_ATTEMPTS", "4"))

# Hard ceilings so one pathological shard cannot melt the gateway or the response.
CONCURRENCY_CEILING = 50
DIAGNOSTIC_ARRAY_CAP = 100

RETRYABLE_STATUS = frozenset({429, 500, 502, 503, 504})

_NON_ALNUM = re.compile(r"[^a-z0-9]+")

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)


# --------------------------------------------------------------------------- #
# Classification helpers
# --------------------------------------------------------------------------- #


def _normalise(text: Any) -> str:
    """Lower-case and collapse every non-alphanumeric run to a single space.

    ``"SITA.aero"`` and ``"sita aero"`` both normalise to ``"sita aero"``, so the
    keyword list does not have to guess punctuation.
    """
    if not isinstance(text, str):
        text = "" if text is None else str(text)
    return _NON_ALNUM.sub(" ", text.lower()).strip()


def _compile_keywords(keywords: Any) -> list[tuple[str, re.Pattern[str]]]:
    """Compile vendor keywords to whole-word patterns over normalised text.

    Word boundaries matter: a bare substring test for ``lido`` also matches
    ``lidonet`` and ``solidonet``, which would flood the ticket with noise.
    """
    compiled: list[tuple[str, re.Pattern[str]]] = []
    if not isinstance(keywords, list):
        return compiled
    for keyword in keywords:
        normalised = _normalise(keyword)
        if not normalised:
            continue
        compiled.append((str(keyword), re.compile(rf"\b{re.escape(normalised)}\b")))
    return compiled


def _parse_networks(cidrs: Any) -> list[Any]:
    networks = []
    if not isinstance(cidrs, list):
        return networks
    for cidr in cidrs:
        try:
            networks.append(ipaddress.ip_network(str(cidr).strip(), strict=False))
        except ValueError:
            logging.warning("extraInternalCidrs: ignoring unparseable entry %r", cidr)
    return networks


def _parse_entry(entry: str) -> tuple[Any, str]:
    """Return ``(object, kind)`` where kind is ``ip``, ``cidr`` or ``invalid``."""
    try:
        return ipaddress.ip_address(entry), "ip"
    except ValueError:
        pass
    try:
        network = ipaddress.ip_network(entry, strict=False)
    except ValueError:
        return None, "invalid"
    # A /32 or /128 is a single host written in CIDR form — treat it as an IP.
    if network.num_addresses == 1:
        return network.network_address, "ip"
    return network, "cidr"


def _is_internal(obj: Any, extra_networks: list[Any]) -> bool:
    """RFC1918 and friends via ``ipaddress.is_private``, plus any extra CIDRs.

    ``is_private`` already covers 10/8, 172.16/12, 192.168/16, 127/8, 169.254/16,
    100.64/10, ::1, fc00::/7 and fe80::/10 — no prefix-string tables needed here,
    unlike the Logic-App-only playbooks.
    """
    if obj.is_private:
        return True
    is_network = isinstance(obj, (ipaddress.IPv4Network, ipaddress.IPv6Network))
    for net in extra_networks:
        if obj.version != net.version:
            continue
        if is_network:
            if obj.subnet_of(net):
                return True
        elif obj in net:
            return True
    return False


def _vendor_haystack(data: dict) -> str:
    """Normalised ISP + domain + hostnames, the text vendor keywords match on."""
    parts: list[str] = []
    for key in ("isp", "domain"):
        value = data.get(key)
        if isinstance(value, str):
            parts.append(value)
    hostnames = data.get("hostnames")
    if isinstance(hostnames, list):
        parts.extend(h for h in hostnames if isinstance(h, str))
    return _normalise(" ".join(parts))


# --------------------------------------------------------------------------- #
# AbuseIPDB
# --------------------------------------------------------------------------- #


def _backoff_seconds(attempt: int) -> float:
    return min(2.0 ** (attempt - 1), 8.0) + random.uniform(0, 0.5)


def _retry_after_seconds(response: httpx.Response) -> float | None:
    raw = response.headers.get("Retry-After")
    if not raw:
        return None
    try:
        return max(0.0, min(float(raw), 30.0))
    except ValueError:
        return None


async def _check_ip(
    client: httpx.AsyncClient,
    semaphore: asyncio.Semaphore,
    api_key: str,
    ip: str,
    max_age_days: int,
) -> tuple[dict | None, str | None]:
    """One AbuseIPDB ``/check``. Returns ``(data, error)`` — exactly one is set."""
    params = {"ipAddress": ip, "maxAgeInDays": max_age_days}
    headers = {"Key": api_key, "Accept": "application/json"}

    async with semaphore:
        for attempt in range(1, MAX_ATTEMPTS + 1):
            try:
                response = await client.get(
                    ABUSEIPDB_CHECK_URL, params=params, headers=headers
                )
            except httpx.HTTPError as exc:
                if attempt == MAX_ATTEMPTS:
                    return None, f"{type(exc).__name__}: {exc}"
                await asyncio.sleep(_backoff_seconds(attempt))
                continue

            if response.status_code == 200:
                try:
                    payload = response.json()
                except ValueError:
                    return None, "HTTP 200 with a non-JSON body"
                data = payload.get("data")
                return (data if isinstance(data, dict) else {}), None

            if response.status_code in RETRYABLE_STATUS and attempt < MAX_ATTEMPTS:
                delay = _retry_after_seconds(response) or _backoff_seconds(attempt)
                await asyncio.sleep(delay)
                continue

            return None, f"HTTP {response.status_code}: {response.text[:200]}"

    return None, f"gave up after {MAX_ATTEMPTS} attempts"


# --------------------------------------------------------------------------- #
# Trigger
# --------------------------------------------------------------------------- #


def _json_response(payload: dict, status_code: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(payload),
        status_code=status_code,
        mimetype="application/json",
    )


def _coerce_int(value: Any, fallback: int, *, low: int, high: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return fallback
    return max(low, min(parsed, high))


@app.function_name(name="enrich_ips")
@app.route(route="enrich-ips", methods=["POST"])
async def enrich_ips(req: func.HttpRequest) -> func.HttpResponse:
    api_key = os.environ.get("ABUSEIPDB_API_KEY", "").strip()
    if not api_key:
        logging.error("ABUSEIPDB_API_KEY is not configured on the function app.")
        return _json_response(
            {"error": "ABUSEIPDB_API_KEY app setting is not configured."}, 500
        )

    try:
        payload = req.get_json()
    except ValueError:
        return _json_response({"error": "Request body must be JSON."}, 400)
    if not isinstance(payload, dict):
        return _json_response({"error": "Request body must be a JSON object."}, 400)

    entries = payload.get("ips")
    if entries is None:
        entries = []
    if not isinstance(entries, list):
        return _json_response({"error": "'ips' must be an array."}, 400)

    shard = payload.get("shard")
    keywords = _compile_keywords(payload.get("vendorKeywords"))
    extra_networks = _parse_networks(payload.get("extraInternalCidrs"))
    max_age_days = _coerce_int(
        payload.get("maxAgeInDays"), DEFAULT_MAX_AGE_DAYS, low=1, high=365
    )
    concurrency = _coerce_int(
        payload.get("concurrency"), DEFAULT_CONCURRENCY, low=1, high=CONCURRENCY_CEILING
    )

    findings: list[dict] = []
    skipped: list[dict] = []
    invalid: list[str] = []
    errors: list[dict] = []
    internal_count = 0
    vendor_count = 0

    # Pass 1 — classify locally. Internal addresses never leave this function:
    # they are findings on their own merit and must not be sent to AbuseIPDB.
    to_check: list[tuple[str, str]] = []  # (original entry, ip string)
    for raw in entries:
        entry = str(raw).strip()
        if not entry:
            continue
        obj, kind = _parse_entry(entry)
        if kind == "invalid":
            invalid.append(entry)
            continue
        if _is_internal(obj, extra_networks):
            internal_count += 1
            findings.append(
                {
                    "entry": entry,
                    "ip": str(obj),
                    "kind": kind,
                    "category": "internal",
                    "vendor": "internal",
                    "abuseConfidenceScore": None,
                    "isp": None,
                    "domain": None,
                    "hostnames": [],
                    "countryCode": None,
                    "totalReports": None,
                    "usageType": None,
                    "checked": False,
                }
            )
            continue
        if kind == "cidr":
            # AbuseIPDB /check takes a single address; /check-block is a different
            # endpoint with a different quota. Report it rather than drop it.
            skipped.append({"entry": entry, "reason": "public CIDR range, not checked"})
            continue
        to_check.append((entry, str(obj)))

    # Pass 2 — enrich the public single addresses.
    if to_check:
        limits = httpx.Limits(
            max_connections=concurrency, max_keepalive_connections=concurrency
        )
        semaphore = asyncio.Semaphore(concurrency)
        async with httpx.AsyncClient(
            timeout=REQUEST_TIMEOUT_SECONDS, limits=limits
        ) as client:
            outcomes = await asyncio.gather(
                *(
                    _check_ip(client, semaphore, api_key, ip, max_age_days)
                    for _, ip in to_check
                )
            )

        for (entry, ip), (data, error) in zip(to_check, outcomes):
            if error is not None:
                errors.append({"entry": entry, "error": error})
                continue
            data = data or {}
            haystack = _vendor_haystack(data)
            matched = next(
                (label for label, pattern in keywords if pattern.search(haystack)), None
            )
            if matched is None:
                continue
            vendor_count += 1
            findings.append(
                {
                    "entry": entry,
                    "ip": data.get("ipAddress") or ip,
                    "kind": "ip",
                    "category": "vendor",
                    "vendor": matched,
                    "abuseConfidenceScore": data.get("abuseConfidenceScore", 0),
                    "isp": data.get("isp"),
                    "domain": data.get("domain"),
                    "hostnames": data.get("hostnames") or [],
                    "countryCode": data.get("countryCode"),
                    "totalReports": data.get("totalReports"),
                    "usageType": data.get("usageType"),
                    "checked": True,
                }
            )

    counts = {
        "requested": len(entries),
        "checked": len(to_check) - len(errors),
        "internal": internal_count,
        "vendor": vendor_count,
        "findings": len(findings),
        "skipped": len(skipped),
        "invalid": len(invalid),
        "errors": len(errors),
    }
    logging.info("shard=%s counts=%s", shard, counts)

    truncated = (
        len(skipped) > DIAGNOSTIC_ARRAY_CAP
        or len(invalid) > DIAGNOSTIC_ARRAY_CAP
        or len(errors) > DIAGNOSTIC_ARRAY_CAP
    )

    return _json_response(
        {
            "shard": shard,
            "counts": counts,
            "results": findings,
            "skipped": skipped[:DIAGNOSTIC_ARRAY_CAP],
            "invalid": invalid[:DIAGNOSTIC_ARRAY_CAP],
            "errors": errors[:DIAGNOSTIC_ARRAY_CAP],
            "truncated": truncated,
        }
    )
