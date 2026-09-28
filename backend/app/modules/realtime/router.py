"""``POST /v1/rt/tickets``: a one-time ticket for opening the realtime WebSocket.

A ticket is 32 random bytes (base64url), kept in Redis for 30 s as ``{uid, sid, roles, dev}``
and consumed by the gateway with ``GETDEL`` on ``hello``. It never goes in a URL.

It isn't behind the update and maintenance gates: a player with an old build or during
maintenance still needs a socket to finish a live match (the gateway decides the rest).
"""

import hashlib
import secrets

import orjson
from fastapi import APIRouter, Depends
from sqlalchemy import select

from app.core.config import SettingsDep
from app.core.db import SessionDep
from app.core.ratelimit import rate_limit
from app.core.redis import RedisDep
from app.core.schemas import ApiModel
from app.core.security import CurrentAuth
from app.modules.auth.models import DeviceSession
from app.modules.realtime import keys

TICKET_BYTES = 32

router = APIRouter(tags=["realtime"])


class TicketOut(ApiModel):
    ticket: str
    expires_in: int


def device_hash(install_id: str) -> str:
    """What matchmaking compares to never pair two accounts on one phone."""
    return hashlib.sha256(install_id.encode()).hexdigest()[:16]


@router.post(
    "/rt/tickets",
    dependencies=[
        Depends(rate_limit("rt.tickets", capacity=20, refill_per_sec=20 / 60, scope="user"))
    ],
)
async def create_ticket(
    auth: CurrentAuth, db: SessionDep, redis: RedisDep, settings: SettingsDep
) -> TicketOut:
    install_id = await db.scalar(
        select(DeviceSession.install_id).where(DeviceSession.id == auth.session_id)
    )
    ticket = secrets.token_urlsafe(TICKET_BYTES)
    payload = {
        "uid": str(auth.user_id),
        "sid": str(auth.session_id),
        "roles": sorted(auth.roles),
        "dev": device_hash(install_id or str(auth.session_id)),
    }
    await redis.set(keys.rt_ticket(ticket), orjson.dumps(payload), ex=settings.rt_ticket_ttl_s)
    return TicketOut(ticket=ticket, expires_in=settings.rt_ticket_ttl_s)
