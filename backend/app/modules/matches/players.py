"""Player cards as live games show them, and the Practice Bot's.

On the socket a player is ``{uid, handle, display_name, avatar: {tone, symbol}, level,
is_bot}``; REST cards use ``id`` instead of ``uid`` (``docs/api-play.md``, "Shared shapes").
"""

import uuid
from collections.abc import Collection, Mapping
from dataclasses import dataclass
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.progression.levels import level_for_xp
from app.modules.progression.models import UserProgress
from app.modules.users.models import User

BOT_NAME = "Practice Bot"
BOT_AVATAR = {"tone": "lavender", "symbol": "robot"}
DEFAULT_GOAL = "neet"


def bot_uid(match_id: uuid.UUID | str) -> str:
    return f"bot:{match_id}"


def is_bot_uid(uid: str) -> bool:
    return uid.startswith("bot:")


@dataclass(frozen=True, slots=True)
class PlayerInfo:
    user_id: uuid.UUID
    handle: str | None
    display_name: str
    tone: str
    symbol: str
    level: int
    goal: str

    def card(self) -> dict[str, Any]:
        return {
            "uid": str(self.user_id),
            "handle": self.handle,
            "display_name": self.display_name,
            "avatar": {"tone": self.tone, "symbol": self.symbol},
            "level": self.level,
            "is_bot": False,
        }


async def load_players(
    db: AsyncSession, user_ids: Collection[uuid.UUID]
) -> dict[uuid.UUID, PlayerInfo]:
    rows = await db.execute(
        select(User, UserProgress.xp)
        .outerjoin(UserProgress, UserProgress.user_id == User.id)
        .where(User.id.in_(list(user_ids)))
    )
    return {
        user.id: PlayerInfo(
            user_id=user.id,
            handle=user.handle,
            display_name=user.display_name,
            tone=user.avatar_tone,
            symbol=user.avatar_symbol,
            level=level_for_xp(xp or 0),
            goal=user.goal or DEFAULT_GOAL,
        )
        for user, xp in rows
    }


def bot_card(match_id: uuid.UUID | str) -> dict[str, Any]:
    return {
        "uid": bot_uid(match_id),
        "handle": None,
        "display_name": BOT_NAME,
        "avatar": dict(BOT_AVATAR),
        "level": None,
        "is_bot": True,
    }


def rest_card(card: Mapping[str, Any]) -> dict[str, Any]:
    """A socket card as a REST user card (``id``); the bot keeps ``is_bot``."""
    out = {
        "id": card["uid"],
        "handle": card.get("handle"),
        "display_name": card.get("display_name"),
        "avatar": card.get("avatar"),
        "level": card.get("level"),
    }
    if card.get("is_bot"):
        out["is_bot"] = True
    return out
