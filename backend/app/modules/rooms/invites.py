"""In-app invites to a room (``docs/api-play.md``, "Rooms and invites").

- **Who.** Any member of an open room may invite a friend whose ``challenges`` privacy setting
  allows it and who hasn't blocked them (either way). A friend who is busy (queued, playing,
  in a room, or needed by a tournament) gets no invite: the sender sees ``BUSY``.
- **Delivery.** ``invite.received`` live on the friend's ``u`` channel, an ``invite`` inbox item
  and a push (which respects quiet hours: the friend didn't start this).
- **Lifetime.** Pending for 2 minutes. Accepting, declining, cancelling (by the sender) and
  expiring each send ``invite.updated`` to both sides; expiry is an outbox message due when the
  invite runs out, so it happens exactly once even with no rt node around. Blocking cancels
  pending invites between the two; a room that closes expires its pending invites.
"""

import uuid
from datetime import datetime, timedelta
from typing import Any

import structlog
from redis.asyncio import Redis
from sqlalchemy import and_, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import Conflict, NotFound, ValidationFailed
from app.modules.notifications.service import notify
from app.modules.outbox.service import OutboxContext, enqueue, register
from app.modules.realtime import protocol
from app.modules.rooms import live
from app.modules.rooms.busy import busy_elsewhere
from app.modules.rooms.models import InviteStatus, Room, RoomInvite
from app.modules.rooms.schemas import (
    InviteAcceptedOut,
    InviteCreatedOut,
    InviteIn,
    InviteOut,
    InvitesOut,
)
from app.modules.rooms.service import (
    Busy,
    Gone,
    NotAllowed,
    RoomNotFound,
    longest_game_ms,
    socket_card,
)
from app.modules.social.cards import cards
from app.modules.social.privacy import can_challenge
from app.modules.social.relations import are_friends

log = structlog.stdlib.get_logger(__name__)

TOPIC_EXPIRE = "rooms.invite_expire"
TOPIC_UPDATED = "rooms.invite_updated"
MAX_PENDING_PER_ROOM = 20


def _ms(moment: datetime) -> int:
    return int(moment.timestamp() * 1000)


def invite_expired() -> Gone:
    return Gone("This invite has expired.", code="INVITE_EXPIRED")


async def _publish_updated(redis: Redis, invite: RoomInvite, now: datetime) -> None:
    for user_id in (invite.from_id, invite.to_id):
        await protocol.publish_to_user(
            redis,
            str(user_id),
            "invite.updated",
            {"invite_id": str(invite.id), "status": invite.status},
            ts=_ms(now),
        )


async def create_invite(
    db: AsyncSession,
    redis: Redis,
    settings: Settings,
    sender: uuid.UUID,
    body: InviteIn,
    *,
    now: datetime,
) -> InviteCreatedOut:
    target = body.to_user_id
    rid = str(body.room_id)
    if target == sender:
        raise ValidationFailed(
            "You can't invite yourself.", details={"fields": {"to_user_id": "Pick a friend."}}
        )
    current = await live.read(redis, rid)
    room = await db.get(Room, body.room_id)
    if current is None or current["status"] == "closed" or room is None:
        raise RoomNotFound()
    state = current["state"]
    members = {member["uid"] for member in state["members"]}
    if str(sender) not in members:
        raise NotAllowed("Join the room first.")
    if str(target) in members:
        raise Conflict("Your friend is already in the room.", code="ALREADY_IN_ROOM")
    if len(members) >= state["capacity"]:
        raise NotAllowed("The room is full.", details={"reason": "full"})
    if not await are_friends(db, sender, target):
        raise NotAllowed("You can only invite friends.", details={"reason": "not_friends"})
    if not await can_challenge(db, sender, target, now=now):
        raise NotAllowed(
            "Their settings don't allow invites from you.", details={"reason": "privacy"}
        )
    until = now + timedelta(
        milliseconds=longest_game_ms(settings, state["kind"], state["settings"])
    )
    active = await busy_elsewhere(db, redis, target, until=until)
    if active is not None:
        raise Busy(active, "Your friend is busy right now.")
    existing = await db.scalar(
        select(RoomInvite).where(
            RoomInvite.room_id == body.room_id,
            RoomInvite.from_id == sender,
            RoomInvite.to_id == target,
            RoomInvite.status == InviteStatus.PENDING.value,
            RoomInvite.expires_at > now,
        )
    )
    if existing is not None:
        return InviteCreatedOut(invite_id=existing.id, expires_at=existing.expires_at)
    invite = RoomInvite(
        room_id=body.room_id,
        from_id=sender,
        to_id=target,
        created_at=now,
        expires_at=now + timedelta(seconds=settings.invite_ttl_s),
    )
    db.add(invite)
    await db.flush()
    card = await socket_card(db, sender)
    subject = state["settings"]["subject"]
    title = "Play with Friend" if state["kind"] == "friend" else "Group Battle"
    await notify(
        db,
        target,
        kind="invite",
        title=f"{card['display_name']} invited you",
        body=f"{title} · {subject.title()}. The invite lasts 2 minutes.",
        icon="battle",
        action={
            "route": f"/battle/room/{rid}",
            "params": {"invite_id": str(invite.id), "room_id": rid},
        },
        key=f"invite:{invite.id}",
    )
    await enqueue(
        db,
        TOPIC_EXPIRE,
        {"invite_id": str(invite.id)},
        key=f"{TOPIC_EXPIRE}:{invite.id}",
        available_at=invite.expires_at,
    )
    await protocol.publish_to_user(
        redis,
        str(target),
        "invite.received",
        {
            "invite_id": str(invite.id),
            "from": card,
            "kind": state["kind"],
            "room_id": rid,
            "subject": subject,
            "expires_at": _ms(invite.expires_at),
        },
        ts=_ms(now),
    )
    log.info("room.invited", invite_id=str(invite.id), room_id=rid)
    return InviteCreatedOut(invite_id=invite.id, expires_at=invite.expires_at)


async def list_invites(db: AsyncSession, user_id: uuid.UUID, *, now: datetime) -> InvitesOut:
    rows = (
        await db.execute(
            select(RoomInvite, Room)
            .join(Room, Room.id == RoomInvite.room_id)
            .where(
                or_(RoomInvite.to_id == user_id, RoomInvite.from_id == user_id),
                RoomInvite.status == InviteStatus.PENDING.value,
                RoomInvite.expires_at > now,
                Room.closed_at.is_(None),
            )
            .order_by(RoomInvite.created_at.desc())
        )
    ).all()
    people = {invite.from_id for invite, _ in rows} | {invite.to_id for invite, _ in rows}
    card_of = await cards(db, people)
    incoming, outgoing = [], []
    for invite, room in rows:
        item: dict[str, Any] = {
            "invite_id": invite.id,
            "room_id": room.id,
            "kind": room.kind,
            "subject": room.settings.get("subject", ""),
            "expires_at": invite.expires_at,
        }
        if invite.to_id == user_id:
            incoming.append(InviteOut(**item, from_=card_of.get(invite.from_id)))
        else:
            outgoing.append(InviteOut(**item, to=card_of.get(invite.to_id)))
    return InvitesOut(incoming=incoming, outgoing=outgoing)


async def _locked(db: AsyncSession, invite_id: uuid.UUID) -> RoomInvite | None:
    return await db.get(RoomInvite, invite_id, with_for_update=True, populate_existing=True)


def _not_found() -> NotFound:
    return NotFound("This invite isn't available.", code="INVITE_NOT_FOUND")


async def _expire_if_due(db: AsyncSession, redis: Redis, invite: RoomInvite, now: datetime) -> bool:
    if invite.status == InviteStatus.PENDING and invite.expires_at <= now:
        invite.status = InviteStatus.EXPIRED.value
        invite.responded_at = now
        await db.flush()
        await _publish_updated(redis, invite, now)
        return True
    return invite.status == InviteStatus.EXPIRED


async def accept_invite(
    db: AsyncSession,
    redis: Redis,
    settings: Settings,
    user_id: uuid.UUID,
    invite_id: uuid.UUID,
    *,
    now: datetime,
) -> InviteAcceptedOut:
    invite = await _locked(db, invite_id)
    if invite is None or invite.to_id != user_id:
        raise _not_found()
    if await _expire_if_due(db, redis, invite, now) or invite.status != InviteStatus.PENDING:
        if invite.status == InviteStatus.ACCEPTED:
            room = await db.get_one(Room, invite.room_id)
            if room.closed_at is None:
                return InviteAcceptedOut(room_id=room.id, code=room.code)
        raise invite_expired()
    room = await db.get_one(Room, invite.room_id)
    current = await live.read(redis, str(room.id))
    if room.closed_at is not None or current is None or current["status"] == "closed":
        invite.status = InviteStatus.EXPIRED.value
        invite.responded_at = now
        await db.flush()
        await _publish_updated(redis, invite, now)
        raise invite_expired()
    until = now + timedelta(milliseconds=longest_game_ms(settings, room.kind, room.settings))
    active = await busy_elsewhere(db, redis, user_id, until=until, allow=f"r:{room.id}")
    if active is not None:
        raise Busy(active)
    invite.status = InviteStatus.ACCEPTED.value
    invite.responded_at = now
    await db.flush()
    await _publish_updated(redis, invite, now)
    return InviteAcceptedOut(room_id=room.id, code=room.code)


async def decline_invite(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, invite_id: uuid.UUID, *, now: datetime
) -> None:
    await _answer(db, redis, user_id, invite_id, InviteStatus.DECLINED, now=now)


async def cancel_invite(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, invite_id: uuid.UUID, *, now: datetime
) -> None:
    await _answer(db, redis, user_id, invite_id, InviteStatus.CANCELLED, now=now)


async def _answer(
    db: AsyncSession,
    redis: Redis,
    user_id: uuid.UUID,
    invite_id: uuid.UUID,
    status: InviteStatus,
    *,
    now: datetime,
) -> None:
    invite = await _locked(db, invite_id)
    mine = invite is not None and (
        invite.to_id == user_id if status == InviteStatus.DECLINED else invite.from_id == user_id
    )
    if invite is None or not mine:
        raise _not_found()
    if await _expire_if_due(db, redis, invite, now) or invite.status != InviteStatus.PENDING:
        return  # already answered: nothing changes
    invite.status = status.value
    invite.responded_at = now
    await db.flush()
    await _publish_updated(redis, invite, now)


# Expiry, blocks and closed rooms (outbox: exactly when the change commits)


async def _expire(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    invite = await _locked(ctx.db, uuid.UUID(payload["invite_id"]))
    if invite is not None:
        await _expire_if_due(ctx.db, ctx.redis, invite, max(ctx.now, invite.expires_at))


async def _updated(ctx: OutboxContext, payload: dict[str, Any]) -> None:
    invite = await ctx.db.get(RoomInvite, uuid.UUID(payload["invite_id"]))
    if invite is not None:
        await _publish_updated(ctx.redis, invite, ctx.now)


async def cancel_between(db: AsyncSession, a: uuid.UUID, b: uuid.UUID, now: datetime) -> None:
    """``social.blocks.register_block_hook``: pending invites between the two are cancelled."""
    cancelled = await db.scalars(
        update(RoomInvite)
        .where(
            RoomInvite.status == InviteStatus.PENDING.value,
            or_(
                and_(RoomInvite.from_id == a, RoomInvite.to_id == b),
                and_(RoomInvite.from_id == b, RoomInvite.to_id == a),
            ),
        )
        .values(status=InviteStatus.CANCELLED.value, responded_at=now)
        .returning(RoomInvite.id)
    )
    for invite_id in cancelled.all():
        await enqueue(
            db, TOPIC_UPDATED, {"invite_id": str(invite_id)}, key=f"{TOPIC_UPDATED}:{invite_id}"
        )


register(TOPIC_EXPIRE, _expire)
register(TOPIC_UPDATED, _updated)
