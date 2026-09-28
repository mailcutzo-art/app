"""Shares: a player posts a battle result or their progress to their friends' activity feed.

The client only says *what* to share (``{"kind": "match_result", "match_id"}`` or
``{"kind": "progress"}``); there is no text or image field. The server builds the payload from
its own records, so a share can't claim a win, a level or a streak that isn't real.

Battle results come from the realtime engine, which owns matches. It plugs in with::

    register_share_source("match_result", source)

where ``source(db, user_id, match_id) -> dict | None`` returns the result of ``user_id``'s own
match once it has ended, as the fields of ``SharedResult`` (validated here), and None for a
match that is unknown, someone else's, or not over (answered as 404). Until a source is
registered, sharing a result answers 404 with a message saying so.

A match can be shared once; progress up to 3 times per IST day. The item goes to the player's
friends' feeds and their own (``activity.friends_activity``).
"""

import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, Field, ValidationError
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import Conflict, NotFound
from app.core.schemas import ApiModel, Lax
from app.modules.practice.models import UserDailyStats
from app.modules.progression import levels, streaks
from app.modules.progression.models import UserProgress
from app.modules.social.activity import record_activity, render_activity
from app.modules.social.friends import ist_day_start, limit_reached
from app.modules.social.models import ActivityEvent, ActivityKind
from app.modules.social.profiles import provided_section
from app.modules.social.relations import friend_ids
from app.modules.social.schemas import ActivityOut

DAILY_PROGRESS_SHARES = 3
MAX_QUESTIONS = 50

# (db, user_id, ref_id) -> the payload, or None if the user can't share that thing.
ShareSource = Callable[[AsyncSession, uuid.UUID, str], Awaitable[dict[str, Any] | None]]

SOURCE_KINDS = ("match_result",)
_SOURCES: dict[str, ShareSource] = {}


def register_share_source(kind: str, source: ShareSource) -> None:
    """Supply the data behind a share kind (only ``match_result`` takes a source)."""
    if kind not in SOURCE_KINDS:
        raise ValueError(f"unknown share source {kind!r}")
    _SOURCES[kind] = source


# --- Request bodies -------------------------------------------------------------------------


class ShareMatchIn(ApiModel):
    kind: Literal["match_result"]
    match_id: Lax[uuid.UUID]


class ShareProgressIn(ApiModel):
    kind: Literal["progress"]


ShareIn = Annotated[ShareMatchIn | ShareProgressIn, Field(discriminator="kind")]


# --- Payloads --------------------------------------------------------------------------------


class SharedResult(ApiModel):
    """What a ``match_result`` source returns: the sharing player's view of their match."""

    match_id: Lax[uuid.UUID]
    mode: Literal["quick_rated", "quick_casual", "friend", "bot", "group", "tournament"]
    result: Literal["win", "draw", "loss"]
    subject: str = Field(min_length=1, max_length=64)
    chapter: str | None = Field(default=None, max_length=120)
    score: int = Field(ge=0)
    # The opponent's score; in a group battle, the best other player's.
    opponent_score: int = Field(ge=0)
    # The opponent (the best other player in a group battle): a person's id, or a bot's name.
    # People are never stored by name; the feed shows their current card if the viewer may
    # see them.
    opponent_id: Lax[uuid.UUID] | None = None
    opponent_name: str | None = Field(default=None, max_length=64)
    # The player's answers in order.
    questions: list[Literal["correct", "wrong", "skipped"]] = Field(max_length=MAX_QUESTIONS)
    # Settlement, when the match has settled (null otherwise or when it doesn't apply).
    rating_change: int | None = None
    coins: int | None = None
    xp: int | None = None

    def payload(self) -> dict[str, Any]:
        data = self.model_dump(mode="json")
        if self.opponent_id is not None:
            data.pop("opponent_name")
        return data


def not_found(message: str) -> NotFound:
    return NotFound(message, code="NOT_FOUND")


async def _match_payload(
    db: AsyncSession, user_id: uuid.UUID, match_id: uuid.UUID
) -> dict[str, Any]:
    source = _SOURCES.get("match_result")
    if source is None:
        raise not_found("Battle results can't be shared yet.")
    raw = await source(db, user_id, str(match_id))
    if raw is None:
        raise not_found("That battle was not found, or it hasn't ended yet.")
    try:
        result = SharedResult.model_validate(raw)
    except ValidationError as error:
        raise ValueError(f"invalid match_result share payload: {error}") from error
    if result.match_id != match_id or result.opponent_id == user_id:
        raise ValueError("match_result share source answered for a different match or player")
    return result.payload()


async def progress_payload(
    db: AsyncSession, user_id: uuid.UUID, *, now: datetime
) -> dict[str, Any]:
    """Level and XP, streak, questions answered and accuracy, and ratings when provided."""
    xp = await db.scalar(select(UserProgress.xp).where(UserProgress.user_id == user_id)) or 0
    level, into_level, span = levels.progress(xp)
    streak = await streaks.evaluate(db, user_id, now=now)
    answered, correct = (
        await db.execute(
            select(
                func.coalesce(func.sum(UserDailyStats.attempts), 0),
                func.coalesce(func.sum(UserDailyStats.correct), 0),
            ).where(UserDailyStats.user_id == user_id)
        )
    ).one()
    return {
        "level": level,
        "xp": xp,
        "xp_into_level": into_level,
        "xp_for_level": span,
        "streak": {"current": streak.days, "best": streak.best},
        "answered": int(answered),
        "correct": int(correct),
        # Whole percent, or null before the first answer.
        "accuracy": round(100 * int(correct) / int(answered)) if answered else None,
        "ratings": _ratings(await provided_section(db, user_id, user_id, "ratings")),
    }


def _ratings(section: Any) -> list[dict[str, Any]]:
    """``[{"scope", "rating"}]`` from the profile's ratings section (empty without one)."""
    if not isinstance(section, list):
        return []
    ratings = []
    for item in section:
        if isinstance(item, BaseModel):
            item = item.model_dump(mode="json")
        if not isinstance(item, dict):
            continue
        scope, rating = item.get("scope"), item.get("rating")
        if isinstance(rating, dict):  # {"value", "display", "provisional"}
            rating = rating.get("value")
        if isinstance(scope, str) and isinstance(rating, int | float):
            ratings.append({"scope": scope, "rating": round(rating)})
    return ratings


async def _lock_shares(db: AsyncSession, user_id: uuid.UUID) -> None:
    """Serialize one player's shares until the transaction ends (for the daily limit)."""
    await db.execute(
        select(func.pg_advisory_xact_lock(func.hashtextextended(f"shares:{user_id}", 0)))
    )


async def _event(db: AsyncSession, user_id: uuid.UUID, key: str) -> ActivityEvent | None:
    return await db.scalar(
        select(ActivityEvent).where(ActivityEvent.user_id == user_id, ActivityEvent.key == key)
    )


async def share(
    db: AsyncSession,
    user_id: uuid.UUID,
    body: ShareMatchIn | ShareProgressIn,
    *,
    request_key: str,
    now: datetime,
) -> ActivityOut:
    """Post a share and return it as the player's feed shows it.

    ``request_key`` is the request's Idempotency-Key: a progress share retried with the same
    key returns the first one. 404 ``NOT_FOUND`` for a match that can't be shared, 409
    ``ALREADY_SHARED`` for a match shared before, 409 ``LIMIT_REACHED`` (``limit: "daily"``)
    after 3 progress shares in an IST day.
    """
    await _lock_shares(db, user_id)
    if isinstance(body, ShareMatchIn):
        key = f"share:match:{body.match_id}"
        existing = await _event(db, user_id, key)
        if existing is not None:
            raise Conflict(
                "You've already posted this battle.",
                code="ALREADY_SHARED",
                details={"activity_id": str(existing.id)},
            )
        kind, payload = ActivityKind.SHARED_RESULT, await _match_payload(db, user_id, body.match_id)
    else:
        day = ist_day_start(now)
        key = f"share:progress:{day.date().isoformat()}:{request_key}"
        existing = await _event(db, user_id, key)
        if existing is not None:
            return await _out(db, user_id, existing, now=now)
        today = await db.scalar(
            select(func.count()).where(
                ActivityEvent.user_id == user_id,
                ActivityEvent.kind == ActivityKind.SHARED_PROGRESS.value,
                ActivityEvent.created_at >= day,
            )
        )
        if (today or 0) >= DAILY_PROGRESS_SHARES:
            raise limit_reached(
                "daily",
                DAILY_PROGRESS_SHARES,
                "You've posted your progress 3 times today. Try again tomorrow.",
            )
        kind, payload = ActivityKind.SHARED_PROGRESS, await progress_payload(db, user_id, now=now)
    await record_activity(db, user_id, kind, payload, key=key, now=now)
    # Recorded just now, under the lock.
    event = (
        await db.scalars(
            select(ActivityEvent).where(ActivityEvent.user_id == user_id, ActivityEvent.key == key)
        )
    ).one()
    return await _out(db, user_id, event, now=now)


async def _out(
    db: AsyncSession, user_id: uuid.UUID, event: ActivityEvent, *, now: datetime
) -> ActivityOut:
    friends = await friend_ids(db, user_id)
    (item,) = await render_activity(db, user_id, [event], friends=friends, now=now)
    return item
