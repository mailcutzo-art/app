"""Who is whose friend, who blocked whom, and how one player relates to others.

``are_blocked`` and ``blocked_ids`` are what matchmaking, rooms and invites call to keep two
players who blocked each other apart (either direction counts).
"""

import uuid
from collections.abc import Collection
from enum import StrEnum

from sqlalchemy import (
    ColumnElement,
    SQLColumnExpression,
    Subquery,
    and_,
    exists,
    func,
    or_,
    select,
    union_all,
)
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.social.models import Block, FriendRequest, Friendship, RequestStatus
from app.modules.users.models import HIDDEN_STATUSES, User


class Relationship(StrEnum):
    NONE = "none"
    FRIEND = "friend"
    REQUESTED = "requested"  # a friend request is pending, in either direction
    BLOCKED = "blocked"  # the viewer blocked them


def pair(a: uuid.UUID, b: uuid.UUID) -> tuple[uuid.UUID, uuid.UUID]:
    """The two ids in ``friendships`` order (``lo < hi``)."""
    return (a, b) if a < b else (b, a)


# --- Blocks ---------------------------------------------------------------------------------


async def are_blocked(db: AsyncSession, a: uuid.UUID, b: uuid.UUID) -> bool:
    """Whether either player blocked the other."""
    return bool(
        await db.scalar(
            select(
                exists().where(
                    or_(
                        and_(Block.blocker_id == a, Block.blocked_id == b),
                        and_(Block.blocker_id == b, Block.blocked_id == a),
                    )
                )
            )
        )
    )


async def blocked_ids(db: AsyncSession, user_id: uuid.UUID) -> set[uuid.UUID]:
    """Everyone the player blocked or was blocked by."""
    rows = await db.scalars(
        union_all(
            select(Block.blocked_id).where(Block.blocker_id == user_id),
            select(Block.blocker_id).where(Block.blocked_id == user_id),
        )
    )
    return set(rows)


def not_blocked_with(
    viewer_id: uuid.UUID, column: SQLColumnExpression[uuid.UUID]
) -> ColumnElement[bool]:
    """A WHERE clause: ``column`` (a user id) and the viewer haven't blocked each other."""
    return ~exists().where(
        or_(
            and_(Block.blocker_id == viewer_id, Block.blocked_id == column),
            and_(Block.blocker_id == column, Block.blocked_id == viewer_id),
        )
    )


# --- Friends --------------------------------------------------------------------------------


async def are_friends(db: AsyncSession, a: uuid.UUID, b: uuid.UUID) -> bool:
    lo, hi = pair(a, b)
    return await db.get(Friendship, (lo, hi)) is not None


def friend_ids_query(user_id: uuid.UUID) -> Subquery:
    """A subquery of the player's friends: ``friend_id`` and ``since`` (hidden accounts
    included)."""
    return union_all(
        select(Friendship.hi.label("friend_id"), Friendship.created_at.label("since")).where(
            Friendship.lo == user_id
        ),
        select(Friendship.lo.label("friend_id"), Friendship.created_at.label("since")).where(
            Friendship.hi == user_id
        ),
    ).subquery()


async def friend_ids(db: AsyncSession, user_id: uuid.UUID) -> set[uuid.UUID]:
    """The player's friends whose accounts are visible (not deleted or pending deletion)."""
    friends = friend_ids_query(user_id)
    rows = await db.scalars(
        select(User.id)
        .join(friends, friends.c.friend_id == User.id)
        .where(User.status.not_in(HIDDEN_STATUSES))
    )
    return set(rows)


async def count_friends(db: AsyncSession, user_id: uuid.UUID) -> int:
    """All friendships, hidden accounts included (they come back on restore)."""
    friends = friend_ids_query(user_id)
    return int(await db.scalar(select(func.count()).select_from(friends)) or 0)


async def relationships(
    db: AsyncSession, viewer_id: uuid.UUID, user_ids: Collection[uuid.UUID]
) -> dict[uuid.UUID, Relationship]:
    """How the viewer relates to each of ``user_ids`` (``none`` for themself)."""
    ids = [user_id for user_id in set(user_ids) if user_id != viewer_id]
    result = dict.fromkeys(user_ids, Relationship.NONE)
    if not ids:
        return result
    friends = set(
        await db.scalars(
            union_all(
                select(Friendship.hi).where(Friendship.lo == viewer_id, Friendship.hi.in_(ids)),
                select(Friendship.lo).where(Friendship.hi == viewer_id, Friendship.lo.in_(ids)),
            )
        )
    )
    requested = set(
        await db.scalars(
            union_all(
                select(FriendRequest.to_id).where(
                    FriendRequest.from_id == viewer_id,
                    FriendRequest.to_id.in_(ids),
                    FriendRequest.status == RequestStatus.PENDING.value,
                ),
                select(FriendRequest.from_id).where(
                    FriendRequest.to_id == viewer_id,
                    FriendRequest.from_id.in_(ids),
                    FriendRequest.status == RequestStatus.PENDING.value,
                ),
            )
        )
    )
    blocked = set(
        await db.scalars(
            select(Block.blocked_id).where(Block.blocker_id == viewer_id, Block.blocked_id.in_(ids))
        )
    )
    for user_id in ids:
        if user_id in blocked:
            result[user_id] = Relationship.BLOCKED
        elif user_id in friends:
            result[user_id] = Relationship.FRIEND
        elif user_id in requested:
            result[user_id] = Relationship.REQUESTED
    return result
