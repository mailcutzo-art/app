"""Coach tips: short instructions with one button, computed on request.

The rules are ``app.modules.coach.tips.build_tips``; ``tips_engine()`` is the one place that
connects them. Everything around the rules is here: the inputs (``inputs.load_coach_data``), a
10-minute cache so the list doesn't jump around, hiding tips the user dismissed (7 days) or acted
on (24 h), and picking the tip for a finished session.
"""

import uuid
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any

import orjson
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.coach import tips as rules
from app.modules.coach.inputs import AreaStats, CoachData, load_coach_data
from app.modules.coach.models import TipHiddenReason, UserTip
from app.modules.coach.schemas import TipItemOut, TipOut, TipsOut
from app.modules.practice.models import PracticeMode, PracticeSession

CACHE_TTL_S = 600
MAX_TIPS = 5
DISMISSED_FOR = timedelta(days=7)
ACTED_FOR = timedelta(hours=24)


@dataclass(frozen=True, slots=True)
class TipsResult:
    unlocked: bool
    answers_needed: int | None
    tips: list[TipItemOut] = field(default_factory=list)


TipsEngine = Callable[[CoachData], TipsResult]


# How a category reads in a tip: "Practise more Physics numericals."
CATEGORY_NAMES = {
    "concept": "concept questions",
    "numerical": "numericals",
    "factual": "fact questions",
    "application": "application questions",
}


def tips_engine() -> TipsEngine | None:
    """The tip rules (``app.modules.coach.tips``)."""
    return run_tip_rules


def _rule_area(area: AreaStats) -> rules.AreaStats:
    name = area.name
    if area.kind == "category":
        name = f"{area.subject_name} {CATEGORY_NAMES.get(area.key, area.key)}"
    return rules.AreaStats(
        kind=rules.AreaKind(area.kind),
        key=area.key,
        name=name,
        subject=area.subject,
        chapter_key=area.chapter,
        attempts=area.attempts,
        correct=area.correct,
        fast=area.fast,
        slow=area.slow,
        even=area.even,
        typical_compared=area.typical_compared,
        typical_ratio=area.typical_ratio,
        fast_wrong=area.fast_wrong,
        easy_attempts=area.easy_attempts,
        easy_correct=area.easy_correct,
    )


def run_tip_rules(data: CoachData) -> TipsResult:
    """Map the player's numbers to the rules' inputs, and their tips to the API's."""
    areas: dict[tuple[str, str, str], rules.AreaStats] = {}
    for area in data.areas:
        # Content keeps topic slugs unique within a subject; never let a slip break tips.
        areas.setdefault((area.kind, area.subject, area.key), _rule_area(area))
    chapters = [area for area in data.areas if area.kind == "chapter"]
    tips = rules.build_tips(
        rules.TipInputs(
            total_answers=data.total_answers,
            overall_attempts=sum(area.attempts for area in chapters),
            overall_correct=sum(area.correct for area in chapters),
            areas=list(areas.values()),
            reviews_due=data.reviews_due,
            untried_chapters=[(c.subject, c.slug, c.name) for c in data.untried_chapters],
        )
    )
    needed = rules.answers_until_unlock(data.total_answers)
    return TipsResult(
        unlocked=needed == 0,
        answers_needed=needed,
        tips=[
            TipItemOut(
                key=tip.key,
                rule=tip.rule.value,
                message=tip.message,
                action=tip.action.value,
                params=dict(tip.params),
            )
            for tip in tips
        ],
    )


def _cache_key(user_id: uuid.UUID, goal: str) -> str:
    return f"tips:{user_id}:{goal}"


async def _computed_tips(
    db: AsyncSession,
    redis: Redis,
    engine: TipsEngine,
    user_id: uuid.UUID,
    *,
    goal: str,
    now: datetime,
) -> TipsResult:
    key = _cache_key(user_id, goal)
    cached = await redis.get(key)
    # Only unlocked tips are cached: a player still short of 20 answers may unlock them with the
    # next batch, and those few answers are cheap to read.
    if cached is not None:
        data = orjson.loads(cached)
        return TipsResult(
            unlocked=data["unlocked"],
            answers_needed=data["answers_needed"],
            tips=[TipItemOut.model_validate(tip) for tip in data["tips"]],
        )
    result = engine(await load_coach_data(db, user_id, goal=goal, now=now))
    if result.unlocked:
        payload = {
            "unlocked": result.unlocked,
            "answers_needed": result.answers_needed,
            "tips": [tip.model_dump() for tip in result.tips],
        }
        await redis.set(key, orjson.dumps(payload), ex=CACHE_TTL_S)
    return result


async def forget_tips(redis: Redis, user_id: uuid.UUID, *, goal: str) -> None:
    """Drop the cached tips, so a finished session's answers count straight away."""
    await redis.delete(_cache_key(user_id, goal))


async def current_tips(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, *, goal: str, now: datetime
) -> TipsOut:
    """Up to five tips, in the rules' order, without the ones the user hid."""
    engine = tips_engine()
    if engine is None:
        return TipsOut(unlocked=False, answers_needed=None, tips=[])
    result = await _computed_tips(db, redis, engine, user_id, goal=goal, now=now)
    hidden = set(
        await db.scalars(
            select(UserTip.tip_key).where(UserTip.user_id == user_id, UserTip.hidden_until > now)
        )
    )
    tips = [tip for tip in result.tips if tip.key not in hidden][:MAX_TIPS]
    return TipsOut(unlocked=result.unlocked, answers_needed=result.answers_needed, tips=tips)


def _plain(tip: TipItemOut) -> TipOut:
    return TipOut(key=tip.key, message=tip.message, action=tip.action, params=tip.params)


async def top_tip(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, *, goal: str, now: datetime
) -> TipOut | None:
    tips = (await current_tips(db, redis, user_id, goal=goal, now=now)).tips
    return _plain(tips[0]) if tips else None


def _relevance(tip: TipItemOut, session: PracticeSession) -> int:
    """How closely a tip's target matches what the session practised (higher is closer)."""
    settings = session.settings
    params = tip.params
    if params.get("topic") and params.get("topic") == settings.get("topic"):
        return 3
    if params.get("chapter") and params.get("chapter") in settings.get("chapters", []):
        return 2
    if params.get("subject") and params.get("subject") == settings.get("subject"):
        return 1
    return 0


async def session_tip(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, session: PracticeSession, *, now: datetime
) -> TipOut | None:
    """The one tip most relevant to a finished session."""
    goal = str(session.settings.get("goal", ""))
    tips = (await current_tips(db, redis, user_id, goal=goal, now=now)).tips
    if not tips:
        return None
    best = max(tips, key=lambda tip: _relevance(tip, session))  # first of the best
    return _plain(best)


async def _hide(
    db: AsyncSession,
    user_id: uuid.UUID,
    key: str,
    *,
    until: datetime,
    reason: TipHiddenReason,
) -> None:
    """Hide a tip until ``until``; a longer existing hide wins."""
    statement = insert(UserTip).values(
        user_id=user_id, tip_key=key, hidden_until=until, reason=reason.value
    )
    await db.execute(
        statement.on_conflict_do_update(
            index_elements=["user_id", "tip_key"],
            set_={"hidden_until": statement.excluded.hidden_until, "reason": reason.value},
            where=UserTip.hidden_until < statement.excluded.hidden_until,
        )
    )


async def dismiss_tip(db: AsyncSession, user_id: uuid.UUID, key: str, *, now: datetime) -> None:
    await _hide(db, user_id, key, until=now + DISMISSED_FOR, reason=TipHiddenReason.DISMISSED)


def session_carries_out(tip: TipOut, settings: Mapping[str, Any]) -> bool:
    """Whether a new practice session is what the tip's button would have started."""
    params = tip.params
    mode = settings.get("mode")
    one_chapter = settings.get("chapters") == [params.get("chapter")]
    same_subject = settings.get("subject") == params.get("subject")
    match tip.action:
        case "practice" | "timed_practice":
            if tip.action == "timed_practice" and not settings.get("timed"):
                return False
            if params.get("topic"):
                return (
                    mode == PracticeMode.TOPIC
                    and same_subject
                    and settings.get("topic") == params["topic"]
                )
            return mode == PracticeMode.CHAPTER and same_subject and one_chapter
        case "practice_category":
            return (
                mode == PracticeMode.CATEGORY
                and same_subject
                and settings.get("category") == params.get("category")
            )
        case "review":
            return mode == PracticeMode.REVIEW
        case "start_chapter" | "practice_medium":
            difficulty = "easy" if tip.action == "start_chapter" else "medium"
            return (
                mode == PracticeMode.CHAPTER
                and same_subject
                and one_chapter
                and settings.get("difficulty") == difficulty
            )
    return False


async def mark_acted(
    db: AsyncSession,
    redis: Redis,
    user_id: uuid.UUID,
    session: PracticeSession,
    *,
    now: datetime,
) -> None:
    """Hide for 24 h the tips whose button this new session carries out."""
    if tips_engine() is None:
        return
    goal = str(session.settings.get("goal", ""))
    for tip in (await current_tips(db, redis, user_id, goal=goal, now=now)).tips:
        if session_carries_out(tip, session.settings):
            await _hide(db, user_id, tip.key, until=now + ACTED_FOR, reason=TipHiddenReason.ACTED)
