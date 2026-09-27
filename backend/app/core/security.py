"""Caller identity: client IP resolution and the authenticated-user dependency."""

import uuid
from collections.abc import Sequence
from ipaddress import IPv4Network, IPv6Network, ip_address
from typing import Annotated

from fastapi import Depends
from starlette.requests import HTTPConnection

from app.core.errors import Unauthorized


def client_ip(conn: HTTPConnection, trusted_proxies: Sequence[IPv4Network | IPv6Network]) -> str:
    """The client's IP address.

    ``X-Forwarded-For`` is used only when the direct peer is a trusted proxy. The chain is then
    read right to left and the first hop that is not itself a trusted proxy is the client; hops
    further left are client-supplied and can be forged.
    """
    peer = conn.client.host if conn.client else ""
    if not _is_trusted(peer, trusted_proxies):
        return peer or "unknown"
    forwarded = ",".join(conn.headers.getlist("x-forwarded-for"))
    for hop in reversed([part.strip() for part in forwarded.split(",") if part.strip()]):
        try:
            address = ip_address(hop)
        except ValueError:
            break
        if not any(address in network for network in trusted_proxies):
            return str(address)
    return peer


def _is_trusted(host: str, trusted_proxies: Sequence[IPv4Network | IPv6Network]) -> bool:
    if not trusted_proxies:
        return False
    try:
        address = ip_address(host)
    except ValueError:
        return False
    return any(address in network for network in trusted_proxies)


async def get_current_user_id() -> uuid.UUID:
    """FastAPI dependency: the authenticated user's id.

    Access-token verification lands with the auth module. Until then no request is authenticated,
    so user-scoped features (user rate limits, idempotency keys) fail closed with 401.
    """
    raise Unauthorized()


CurrentUserId = Annotated[uuid.UUID, Depends(get_current_user_id)]
