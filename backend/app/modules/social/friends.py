"""Friend requests and friendships.

Rules (docs/plan.md, Phase 7): at most 20 requests sent per IST day, 100 pending and 500
friends. The recipient's ``friend_requests`` privacy setting may refuse a request (403
``NOT_ALLOWED`` with ``details.reason``). Asking someone who already asked you accepts their
request. Everything between two players is serialized by a transaction-scoped advisory lock on
the pair, so two requests crossing each other can't both stay pending.
"""

import uuid
from datetime import datetime, time

from redis.asyncio import Redis
from sqlalchemy import delete, func, or_, select, tuple_, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.core.errors import Conflict, Forbidden, NotFound, ValidationFailed
from app.core.ids import new_id
from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel, Lax
from app.modules.notifications.service import notify
from app.modules.social.activity import record_activity
from app.modules.social.cards import cards, cards_for
from app.modules.social.models import ActivityKind, FriendRequest, Friendship, RequestStatus
from app.modules.social.presence import get_presence_many
from app.modules.social.privacy import (
    ChallengesFrom,
    FriendRequestsFrom,
    can_be_reached,
    have_played,
    privacy_many,
    privacy_of,
)
from app.modules.social.relations import (
    are_blocked,
    are_friends,
    count_friends,
    friend_ids_query,
    not_blocked_with,
    pair,
)
from app.modules.social.schemas import (
    Direction,
    FriendOut,
    FriendRequestOut,
    FriendRequestsOut,
    FriendsOut,
)
from app.modules.users.models import HIDDEN_STATUSES, User, UserStatus

DAILY_REQUESTS = 20
MAX_PENDING = 100
MAX_FRIENDS = 500
REQUESTS_LISTED = 100


def not_allowed(reason: str, message: str) -> Forbidden:
    return Forbidden(message, code="NOT_ALLOWED", details={"reason": reason})


def limit_reached(limit: str, maximum: int, message: str) -> Conflict:
    return Conflict(message, code="LIMIT_REACHED", details={"limit": limit, "max": maximum})


def user_not_found() -> NotFound:
    return NotFound("That player was not found.", code="USER_NOT_FOUND")


def request_not_found() -> NotFound:
    return NotFound("That friend request was not found.", code="FRIEND_REQUEST_NOT_FOUND")


async def lock_pair(db: AsyncSession, a: uuid.UUID, b: uuid.UUID) -> None:
    """Serialize everything between two players until the transaction ends."""
    lo, hi = pair(a, b)
    await db.execute(
        select(func.pg_advisory_xact_lock(func.hashtextextended(f"social:{lo}:{hi}", 0)))
    )


def ist_day_start(now: datetime) -> datetime:
    return datetime.combine(now.astimezone(IST).date(), time(0), IST)


# --- Sending, accepting, declining, cancelling -----------------------------------------------


async def send_request(
    db: AsyncSession, sender_id: uuid.UUID, target_id: uuid.UUID, *, now: datetime
) -> FriendRequest:
    """Ask ``target_id`` to be friends. Asking again returns the pending request; asking
    someone whose request is pending accepts it (the result is then ``accepted``)."""
    if sender_id == target_id:
        raise ValidationFailed(
            "You can't add yourself.", details={"fields": {"user_id": "You can't add yourself."}}
        )
    await lock_pair(db, sender_id, target_id)
    target = await db.get(User, target_id)
    if target is None or not can_be_reached(target, now):
        raise user_not_found()
    if await are_blocked(db, sender_id, target_id):
        raise user_not_found()
    sender = await db.get_one(User, sender_id)
    if sender.status == UserStatus.RESTRICTED:
        raise not_allowed("restricted", "Your account can't send friend requests right now.")
    if await are_friends(db, sender_id, target_id):
        raise Conflict("You're already friends.", code="ALREADY_FRIENDS")

    existing = await _pending(db, sender_id, target_id)
    if existing is not None:
        return existing
    reverse = await _pending(db, target_id, sender_id)
    if reverse is not None:
        await _accept(db, reverse, now=now)
        return reverse

    privacy = await privacy_of(db, target, now=now)
    if privacy.friend_requests == FriendRequestsFrom.NOBODY:
        raise not_allowed("nobody", f"{target.display_name} isn't accepting friend requests.")
    if privacy.friend_requests == FriendRequestsFrom.PLAYED_WITH and not await have_played(
        db, sender_id, target_id
    ):
        raise not_allowed(
            "played_with",
            f"{target.display_name} only accepts friend requests from people they've played.",
        )
    await _check_send_limits(db, sender_id, target_id, now=now)

    request = FriendRequest(id=new_id(), from_id=sender_id, to_id=target_id, created_at=now)
    db.add(request)
    await db.flush()
    await notify(
        db,
        target_id,
        kind="friend_request",
        title="Friend request",
        body=f"{sender.display_name} (@{sender.handle}) wants to be friends.",
        icon="friends",
        action={"route": "/social", "params": {"tab": "requests"}},
        key=f"friend_request:{request.id}",
    )
    return request


async def _check_send_limits(
    db: AsyncSession, sender_id: uuid.UUID, target_id: uuid.UUID, *, now: datetime
) -> None:
    sent_today = await db.scalar(
        select(func.count()).where(
            FriendRequest.from_id == sender_id, FriendRequest.created_at >= ist_day_start(now)
        )
    )
    if (sent_today or 0) >= DAILY_REQUESTS:
        raise limit_reached(
            "daily", DAILY_REQUESTS, "You've sent 20 friend requests today. Try again tomorrow."
        )
    pending = await db.scalar(
        select(func.count()).where(
            FriendRequest.from_id == sender_id,
            FriendRequest.status == RequestStatus.PENDING.value,
        )
    )
    if (pending or 0) >= MAX_PENDING:
        raise limit_reached(
            "pending",
            MAX_PENDING,
            "You have 100 requests waiting for an answer. Cancel some to send more.",
        )
    await _check_friend_limits(db, sender_id, target_id)


async def _check_friend_limits(db: AsyncSession, me: uuid.UUID, other: uuid.UUID) -> None:
    if await count_friends(db, me) >= MAX_FRIENDS:
        raise limit_reached("friends", MAX_FRIENDS, "You already have 500 friends.")
    if await count_friends(db, other) >= MAX_FRIENDS:
        raise limit_reached("their_friends", MAX_FRIENDS, "Their friends list is full.")


async def _pending(db: AsyncSession, from_id: uuid.UUID, to_id: uuid.UUID) -> FriendRequest | None:
    return await db.scalar(
        select(FriendRequest)
        .where(
            FriendRequest.from_id == from_id,
            FriendRequest.to_id == to_id,
            FriendRequest.status == RequestStatus.PENDING.value,
        )
        .with_for_update()
    )


async def accept_request(
    db: AsyncSession, user_id: uuid.UUID, request_id: uuid.UUID, *, now: datetime
) -> FriendRequest:
    """Accept a request sent to ``user_id`` (accepting twice is fine)."""
    request = await _request_to(db, user_id, request_id, lock=False)
    # The pair lock comes before the row lock, in the same order as ``send_request``.
    await lock_pair(db, request.from_id, request.to_id)
    await db.refresh(request, with_for_update=True)
    if request.status == RequestStatus.ACCEPTED:
        return request
    _require_pending(request)
    sender = await db.get(User, request.from_id)
    if sender is None or not can_be_reached(sender, now):
        raise request_not_found()
    await _accept(db, request, now=now)
    return request


async def _accept(db: AsyncSession, request: FriendRequest, *, now: datetime) -> None:
    """Make the two friends and tell the sender. The pair is locked by the caller."""
    await _check_friend_limits(db, request.to_id, request.from_id)
    lo, hi = pair(request.from_id, request.to_id)
    await db.execute(
        insert(Friendship).values(lo=lo, hi=hi, created_at=now).on_conflict_do_nothing()
    )
    request.status = RequestStatus.ACCEPTED.value
    request.decided_at = now
    await db.flush()
    accepter = await db.get_one(User, request.to_id)
    await notify(
        db,
        request.from_id,
        kind="friend_accepted",
        title="New friend",
        body=f"{accepter.display_name} accepted your friend request.",
        icon="friends",
        action={"route": f"/u/{accepter.handle}", "params": {}},
        key=f"friend_accepted:{request.id}",
    )
    for user_id, friend_id in ((request.from_id, request.to_id), (request.to_id, request.from_id)):
        await record_activity(
            db,
            user_id,
            ActivityKind.FRIEND,
            {"friend_id": str(friend_id)},
            key=f"friend:{friend_id}:{request.id}",
        )


async def decline_request(
    db: AsyncSession, user_id: uuid.UUID, request_id: uuid.UUID, *, now: datetime
) -> FriendRequest:
    """Decline a request sent to ``user_id``; the sender isn't told."""
    request = await _request_to(db, user_id, request_id)
    if request.status == RequestStatus.DECLINED:
        return request
    _require_pending(request)
    request.status = RequestStatus.DECLINED.value
    request.decided_at = now
    await db.flush()
    return request


async def cancel_request(
    db: AsyncSession, user_id: uuid.UUID, request_id: uuid.UUID, *, now: datetime
) -> None:
    """Withdraw a request ``user_id`` sent (cancelling twice is fine)."""
    request = await db.scalar(
        select(FriendRequest)
        .where(FriendRequest.id == request_id, FriendRequest.from_id == user_id)
        .with_for_update()
    )
    if request is None:
        raise request_not_found()
    if request.status == RequestStatus.CANCELLED:
        return
    _require_pending(request)
    request.status = RequestStatus.CANCELLED.value
    request.decided_at = now
    await db.flush()


async def _request_to(
    db: AsyncSession, user_id: uuid.UUID, request_id: uuid.UUID, *, lock: bool = True
) -> FriendRequest:
    """A request addressed to ``user_id``; anyone else's is "not found"."""
    statement = select(FriendRequest).where(
        FriendRequest.id == request_id, FriendRequest.to_id == user_id
    )
    request = await db.scalar(statement.with_for_update() if lock else statement)
    if request is None:
        raise request_not_found()
    return request


def _require_pending(request: FriendRequest) -> None:
    if request.status != RequestStatus.PENDING:
        raise Conflict(
            "That friend request has already been answered.",
            code="REQUEST_CLOSED",
            details={"status": request.status},
        )


async def cancel_pending_between(
    db: AsyncSession, a: uuid.UUID, b: uuid.UUID | None, *, now: datetime
) -> None:
    """Cancel pending requests between two players (``b=None``: every request to or from
    ``a``), for blocks and account deletion."""
    involved = or_(FriendRequest.from_id == a, FriendRequest.to_id == a)
    if b is not None:
        involved = or_(
            (FriendRequest.from_id == a) & (FriendRequest.to_id == b),
            (FriendRequest.from_id == b) & (FriendRequest.to_id == a),
        )
    await db.execute(
        update(FriendRequest)
        .where(involved, FriendRequest.status == RequestStatus.PENDING.value)
        .values(status=RequestStatus.CANCELLED.value, decided_at=now)
    )


async def remove_friend(db: AsyncSession, user_id: uuid.UUID, friend_id: uuid.UUID) -> None:
    """End a friendship (a no-op if there is none)."""
    lo, hi = pair(user_id, friend_id)
    await db.execute(delete(Friendship).where(Friendship.lo == lo, Friendship.hi == hi))


# --- Lists ----------------------------------------------------------------------------------


async def list_requests(db: AsyncSession, user_id: uuid.UUID) -> FriendRequestsOut:
    """Pending requests both ways, newest first, with players the viewer may see."""

    async def pending(direction: Direction) -> list[FriendRequestOut]:
        mine, theirs = (
            (FriendRequest.to_id, FriendRequest.from_id)
            if direction == Direction.INCOMING
            else (FriendRequest.from_id, FriendRequest.to_id)
        )
        rows = (
            await db.execute(
                select(FriendRequest, User)
                .join(User, User.id == theirs)
                .where(
                    mine == user_id,
                    FriendRequest.status == RequestStatus.PENDING.value,
                    User.status.not_in(HIDDEN_STATUSES),
                    not_blocked_with(user_id, theirs),
                )
                .order_by(FriendRequest.created_at.desc(), FriendRequest.id.desc())
                .limit(REQUESTS_LISTED)
            )
        ).all()
        pairs = list(rows)
        card_of = await cards_for(db, [other for _, other in pairs])
        return [
            FriendRequestOut(
                id=request.id,
                user=card_of[other.id],
                direction=direction,
                status=request.status,
                created_at=request.created_at,
            )
            for request, other in pairs
        ]

    return FriendRequestsOut(
        incoming=await pending(Direction.INCOMING), outgoing=await pending(Direction.OUTGOING)
    )


async def request_out(
    db: AsyncSession, viewer_id: uuid.UUID, request: FriendRequest
) -> FriendRequestOut:
    incoming = request.to_id == viewer_id
    other = request.from_id if incoming else request.to_id
    return FriendRequestOut(
        id=request.id,
        user=(await cards(db, [other]))[other],
        direction=Direction.INCOMING if incoming else Direction.OUTGOING,
        status=request.status,
        created_at=request.created_at,
    )


class FriendCursor(ApiModel):
    name: str
    id: Lax[uuid.UUID]


async def list_friends(
    db: AsyncSession,
    redis: Redis,
    user_id: uuid.UUID,
    *,
    cursor: str | None,
    limit: int,
    now: datetime,
) -> FriendsOut:
    """Friends by name, with presence (as they allow) and whether they can be challenged."""
    friends = friend_ids_query(user_id)
    sort_name = func.lower(User.display_name)
    statement = (
        select(User, friends.c.since, sort_name)
        .join(friends, friends.c.friend_id == User.id)
        .where(User.status.not_in(HIDDEN_STATUSES))
        .order_by(sort_name, User.id)
        .limit(limit + 1)
    )
    if cursor is not None:
        position = decode_cursor(cursor, FriendCursor)
        statement = statement.where(tuple_(sort_name, User.id) > tuple_(position.name, position.id))
    rows = list((await db.execute(statement)).all())
    page = rows[:limit]
    users = [user for user, _, _ in page]
    card_of = await cards_for(db, users)
    presence = await get_presence_many(
        redis, [user.id for user in users], db=db, viewer_id=user_id, now=now
    )
    privacy = await privacy_many(db, users, now=now)
    viewer = await db.get_one(User, user_id)
    may_challenge = viewer.status != UserStatus.RESTRICTED
    items = [
        FriendOut(
            **card_of[user.id].model_dump(),
            presence=presence[user.id],
            friends_since=since,
            can_challenge=may_challenge
            and privacy[user.id].challenges != ChallengesFrom.NOBODY
            and not user.ban_in_force(now),
        )
        for user, since, _ in page
    ]
    next_cursor = None
    if len(rows) > limit:
        last, _, last_name = page[-1]
        next_cursor = encode_cursor(FriendCursor(name=last_name, id=last.id))
    return FriendsOut(items=items, next_cursor=next_cursor)
