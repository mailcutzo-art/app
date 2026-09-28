"""Blocking: it ends the friendship, cancels pending requests, and hides the two players from
each other (search, profiles, lists, pairing).

Other features react through ``register_block_hook``: rooms cancel pending invites between the
two, for instance. Hooks run in the blocking transaction.
"""

import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime

from sqlalchemy import delete, select, tuple_
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ValidationFailed
from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel, Lax
from app.modules.social.cards import cards_for
from app.modules.social.friends import (
    cancel_pending_between,
    lock_pair,
    remove_friend,
    user_not_found,
)
from app.modules.social.models import Block
from app.modules.social.schemas import BlockOut, BlocksOut
from app.modules.users.models import HIDDEN_STATUSES, User

# (db, blocker, blocked, now)
BlockHook = Callable[[AsyncSession, uuid.UUID, uuid.UUID, datetime], Awaitable[None]]

_BLOCK_HOOKS: list[BlockHook] = []


def register_block_hook(hook: BlockHook) -> None:
    """Run ``hook`` whenever one player blocks another."""
    if hook not in _BLOCK_HOOKS:
        _BLOCK_HOOKS.append(hook)


async def block_user(
    db: AsyncSession, blocker_id: uuid.UUID, blocked_id: uuid.UUID, *, now: datetime
) -> None:
    """Block ``blocked_id`` (blocking twice is fine)."""
    if blocker_id == blocked_id:
        raise ValidationFailed(
            "You can't block yourself.",
            details={"fields": {"user_id": "You can't block yourself."}},
        )
    target = await db.get(User, blocked_id)
    if target is None or target.status in HIDDEN_STATUSES:
        raise user_not_found()
    await lock_pair(db, blocker_id, blocked_id)
    await db.execute(
        insert(Block)
        .values(blocker_id=blocker_id, blocked_id=blocked_id, created_at=now)
        .on_conflict_do_nothing()
    )
    await remove_friend(db, blocker_id, blocked_id)
    await cancel_pending_between(db, blocker_id, blocked_id, now=now)
    for hook in _BLOCK_HOOKS:
        await hook(db, blocker_id, blocked_id, now)


async def unblock_user(db: AsyncSession, blocker_id: uuid.UUID, blocked_id: uuid.UUID) -> None:
    """Lift a block (a no-op if there is none). The friendship doesn't come back."""
    await db.execute(
        delete(Block).where(Block.blocker_id == blocker_id, Block.blocked_id == blocked_id)
    )


class BlockCursor(ApiModel):
    at: Lax[datetime]
    id: Lax[uuid.UUID]


async def list_blocks(
    db: AsyncSession, user_id: uuid.UUID, *, cursor: str | None, limit: int
) -> BlocksOut:
    """Players ``user_id`` blocked, most recent first."""
    statement = (
        select(Block, User)
        .join(User, User.id == Block.blocked_id)
        .where(Block.blocker_id == user_id, User.status.not_in(HIDDEN_STATUSES))
        .order_by(Block.created_at.desc(), Block.blocked_id.desc())
        .limit(limit + 1)
    )
    if cursor is not None:
        position = decode_cursor(cursor, BlockCursor)
        statement = statement.where(
            tuple_(Block.created_at, Block.blocked_id) < tuple_(position.at, position.id)
        )
    rows = list((await db.execute(statement)).all())
    page = rows[:limit]
    card_of = await cards_for(db, [user for _, user in page])
    next_cursor = None
    if len(rows) > limit:
        last = page[-1][0]
        next_cursor = encode_cursor(BlockCursor(at=last.created_at, id=last.blocked_id))
    return BlocksOut(
        items=[
            BlockOut(user=card_of[user.id], created_at=block.created_at) for block, user in page
        ],
        next_cursor=next_cursor,
    )
