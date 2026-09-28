"""User cards: how another player is shown anywhere in the app (docs/api-play.md)."""

import uuid
from collections.abc import Collection

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.schemas import ApiModel
from app.modules.progression.levels import level_for_xp
from app.modules.progression.models import UserProgress
from app.modules.users.models import User


class AvatarOut(ApiModel):
    tone: str
    symbol: str


class UserCard(ApiModel):
    id: uuid.UUID
    handle: str | None
    display_name: str
    avatar: AvatarOut
    level: int


def card_of(user: User, level: int) -> UserCard:
    return UserCard(
        id=user.id,
        handle=user.handle,
        display_name=user.display_name,
        avatar=AvatarOut(tone=user.avatar_tone, symbol=user.avatar_symbol),
        level=level,
    )


async def levels(db: AsyncSession, user_ids: Collection[uuid.UUID]) -> dict[uuid.UUID, int]:
    rows = await db.execute(
        select(UserProgress.user_id, UserProgress.xp).where(
            UserProgress.user_id.in_(list(user_ids))
        )
    )
    xp: dict[uuid.UUID, int] = {row[0]: row[1] for row in rows}
    return {user_id: level_for_xp(xp.get(user_id, 0)) for user_id in user_ids}


async def cards_for(db: AsyncSession, users: Collection[User]) -> dict[uuid.UUID, UserCard]:
    """Cards for already-loaded users (one query for their levels)."""
    by_id = {user.id: user for user in users}
    if not by_id:
        return {}
    level_of = await levels(db, by_id.keys())
    return {user_id: card_of(user, level_of[user_id]) for user_id, user in by_id.items()}


async def cards(db: AsyncSession, user_ids: Collection[uuid.UUID]) -> dict[uuid.UUID, UserCard]:
    """Cards by user id; ids with no user are left out."""
    if not user_ids:
        return {}
    users = list(await db.scalars(select(User).where(User.id.in_(list(set(user_ids))))))
    return await cards_for(db, users)
