"""Daily missions: three a day, progress from events, rewards credited automatically.

**Generation.** The first request or event of an IST day creates the user's three rows (``ON
CONFLICT DO NOTHING``, so concurrent requests agree), chosen deterministically from
``hash(uid, day)``:

- practice: answer 10, 20 or 30 practice questions (+20 XP);
- play: play 1 rated battle or tournament game (+25 XP), never "win";
- review: review 5 weak questions (+30 XP) when at least 5 questions are in review, else answer
  10 questions in the weakest chapter, or in any chapter for a player with no data yet.

**Progress** comes from ``record`` with an ``event_id``; each event counts once per user and
kind. A mission that reaches its target is done at once: its XP is awarded and a
``mission_done`` notice sent. Finishing all three adds ``BONUS_XP`` and ``BONUS_COINS``. Every
reward carries an idempotency key, so nothing is paid twice.

**Swap.** One free swap a day replaces a mission that isn't done with another one of its slot
(progress starts again).
"""

import hashlib
import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.core.errors import Conflict, NotFound
from app.modules.analytics.service import track
from app.modules.content.models import Chapter, Question, QuestionKind, Subject
from app.modules.content.queries import practice_pool, subjects_of_goal, suits_goal
from app.modules.economy.models import CoinReason, RefKind
from app.modules.economy.service import Ref, credit
from app.modules.notifications.service import notify
from app.modules.practice.models import UserChapterStats, UserQuestion
from app.modules.progression import achievements
from app.modules.progression.models import (
    DailyMission,
    Metric,
    MissionDef,
    MissionKind,
    MissionSlot,
    ProgressEventDedupe,
    XpSource,
)
from app.modules.progression.xp import award_xp
from app.modules.users.models import User

BONUS_XP = 100
BONUS_COINS = 25
BONUS_TITLE = "Daily missions bonus"
# The review mission needs this many questions in review; below it the chapter fallbacks apply.
REVIEW_MIN_ITEMS = 5
# A chapter counts as "weakest" only after this many answers in it.
WEAK_CHAPTER_MIN_ANSWERS = 5
SLOT_ORDER = (MissionSlot.PRACTICE, MissionSlot.PLAY, MissionSlot.REVIEW)
# Defs that need something to exist before they can be given.
REVIEW_DEF = "review_5"
WEAK_CHAPTER_DEF = "weak_chapter_10"
ANY_CHAPTER_DEF = "any_chapter_10"


class SwapUsed(Conflict):
    default_code = "SWAP_USED"
    default_message = "You've already used today's free swap."


class NoSwap(Conflict):
    default_code = "NO_SWAP"
    default_message = "There's no other mission to swap this one for today."


class MissionDone(Conflict):
    default_code = "MISSION_DONE"
    default_message = "This mission is already done."


@dataclass(frozen=True, slots=True)
class WeakChapter:
    chapter_id: int
    chapter: str  # slug
    subject: str  # slug
    name: str


def ist_day(now: datetime) -> date:
    return now.astimezone(IST).date()


def _pick(user_id: uuid.UUID, day: date, salt: str, count: int) -> int:
    digest = hashlib.sha256(f"{user_id}:{day.isoformat()}:{salt}".encode()).digest()
    return int.from_bytes(digest[:8], "big") % count


def action_of(mission: DailyMission) -> dict[str, Any]:
    """Where tapping the mission takes the app."""
    match MissionKind(mission.kind):
        case MissionKind.PRACTICE_ANSWER:
            return {"route": "/learn", "params": {}}
        case MissionKind.REVIEW_ANSWER:
            return {"route": "/learn", "params": {"mode": "review"}}
        case MissionKind.CHAPTER_ANSWER if mission.params.get("chapter"):
            return {
                "route": f"/learn/{mission.params['subject']}",
                "params": {"chapter": mission.params["chapter"]},
            }
        case MissionKind.CHAPTER_ANSWER:
            return {"route": "/learn", "params": {}}
        case MissionKind.RATED_GAME:
            return {"route": "/battle", "params": {"mode": "rated"}}
        case MissionKind.BATTLE_FINISHED:
            return {"route": "/battle", "params": {}}


# --- What a player can be given --------------------------------------------------------------


async def _review_items(db: AsyncSession, user_id: uuid.UUID, goal: str | None) -> int:
    """Questions in review that a review session could serve."""
    statement = (
        select(func.count())
        .select_from(UserQuestion)
        .join(Question, Question.id == UserQuestion.question_id)
        .where(
            UserQuestion.user_id == user_id,
            UserQuestion.review_box.is_not(None),
            Question.kind == QuestionKind.MCQ_SINGLE.value,
            practice_pool(),
        )
    )
    if goal is not None:
        statement = statement.where(suits_goal(goal))
    return await db.scalar(statement) or 0


async def weakest_chapter(
    db: AsyncSession, user_id: uuid.UUID, goal: str | None
) -> WeakChapter | None:
    """The active chapter with the lowest smoothed accuracy ``(c+2)/(n+4)`` among those with
    at least ``WEAK_CHAPTER_MIN_ANSWERS`` answers (in the player's exam)."""
    smoothed = (UserChapterStats.correct + 2) * 1.0 / (UserChapterStats.attempts + 4)
    statement = (
        select(Chapter.id, Chapter.slug, Subject.slug, Chapter.name)
        .join(UserChapterStats, UserChapterStats.chapter_id == Chapter.id)
        .join(Subject, Subject.id == Chapter.subject_id)
        .where(
            UserChapterStats.user_id == user_id,
            UserChapterStats.attempts >= WEAK_CHAPTER_MIN_ANSWERS,
            Chapter.is_active,
        )
        .order_by(smoothed, Chapter.id)
        .limit(1)
    )
    if goal is not None:
        statement = statement.where(Chapter.subject_id.in_(subjects_of_goal(goal)))
    row = (await db.execute(statement)).first()
    return WeakChapter(*row) if row else None


@dataclass(slots=True)
class _Options:
    """What the day's review-slot defs depend on, loaded once."""

    review_items: int
    weak: WeakChapter | None

    def feasible(self, definition: MissionDef) -> bool:
        if definition.id == REVIEW_DEF:
            return self.review_items >= REVIEW_MIN_ITEMS
        if definition.id == WEAK_CHAPTER_DEF:
            return self.weak is not None
        return True


async def _options(db: AsyncSession, user_id: uuid.UUID) -> _Options:
    goal = await db.scalar(select(User.goal).where(User.id == user_id))
    return _Options(
        review_items=await _review_items(db, user_id, goal),
        weak=await weakest_chapter(db, user_id, goal),
    )


def _values(definition: MissionDef, options: _Options) -> dict[str, Any]:
    """The row fields a def fills in: title, kind, target, XP and chapter params."""
    params: dict[str, Any] = {}
    title = definition.title
    if definition.id == WEAK_CHAPTER_DEF and options.weak is not None:
        weak = options.weak
        params = {"chapter_id": weak.chapter_id, "chapter": weak.chapter, "subject": weak.subject}
        title = title.replace("{chapter}", weak.name)
    return {
        "def_id": definition.id,
        "kind": definition.kind,
        "title": title,
        "target": definition.target,
        "xp": definition.xp,
        "params": params,
    }


def _choose_review(defs: Sequence[MissionDef], options: _Options) -> MissionDef:
    """The review slot falls back in a fixed order: review, weakest chapter, any chapter."""
    by_id = {d.id: d for d in defs}
    for def_id in (REVIEW_DEF, WEAK_CHAPTER_DEF, ANY_CHAPTER_DEF):
        definition = by_id.get(def_id)
        if definition is not None and definition.generate and options.feasible(definition):
            return definition
    return next(d for d in defs if d.generate and options.feasible(d))


async def _defs(db: AsyncSession) -> list[MissionDef]:
    return list(await db.scalars(select(MissionDef).order_by(MissionDef.sort, MissionDef.id)))


# --- The day's missions ----------------------------------------------------------------------


def _ordered(missions: Sequence[DailyMission]) -> list[DailyMission]:
    return sorted(missions, key=lambda m: SLOT_ORDER.index(MissionSlot(m.slot)))


async def _load(
    db: AsyncSession, user_id: uuid.UUID, day: date, *, lock: bool = False
) -> list[DailyMission]:
    statement = (
        select(DailyMission)
        .where(DailyMission.user_id == user_id, DailyMission.ist_day == day)
        .order_by(DailyMission.id)
        .execution_options(populate_existing=True)
    )
    if lock:
        statement = statement.with_for_update()
    return _ordered((await db.scalars(statement)).all())


async def todays_missions(
    db: AsyncSession, user_id: uuid.UUID, *, now: datetime, lock: bool = False
) -> list[DailyMission]:
    """The user's three missions for the IST day of ``now``, created on first use."""
    day = ist_day(now)
    missions = await _load(db, user_id, day, lock=lock)
    if len(missions) == len(SLOT_ORDER):
        return missions
    defs = await _defs(db)
    options = await _options(db, user_id)
    rows = []
    for slot in SLOT_ORDER:
        candidates = [d for d in defs if d.slot == slot.value]
        if slot == MissionSlot.REVIEW:
            chosen = _choose_review(candidates, options)
        else:
            generated = [d for d in candidates if d.generate]
            chosen = generated[_pick(user_id, day, slot.value, len(generated))]
        rows.append(
            {"user_id": user_id, "ist_day": day, "slot": slot.value, **_values(chosen, options)}
        )
    await db.execute(insert(DailyMission).values(rows).on_conflict_do_nothing())
    return await _load(db, user_id, day, lock=lock)


def all_done(missions: Sequence[DailyMission]) -> bool:
    return bool(missions) and all(m.done_at is not None for m in missions)


def swap_available(missions: Sequence[DailyMission]) -> bool:
    return not any(m.swapped for m in missions) and not all_done(missions)


async def swap(
    db: AsyncSession, user_id: uuid.UUID, mission_id: uuid.UUID, *, now: datetime
) -> list[DailyMission]:
    """Replace one of today's unfinished missions with another of its slot (once a day)."""
    missions = await todays_missions(db, user_id, now=now, lock=True)
    mission = next((m for m in missions if m.id == mission_id), None)
    if mission is None:
        raise NotFound("This mission isn't one of today's.", code="MISSION_NOT_FOUND")
    if mission.done_at is not None:
        raise MissionDone()
    if any(m.swapped for m in missions):
        raise SwapUsed()
    options = await _options(db, user_id)
    candidates = [
        d
        for d in await _defs(db)
        if d.slot == mission.slot and d.id != mission.def_id and options.feasible(d)
    ]
    if not candidates:
        raise NoSwap()
    day = ist_day(now)
    chosen = candidates[_pick(user_id, day, f"swap:{mission.slot}", len(candidates))]
    for field, value in _values(chosen, options).items():
        setattr(mission, field, value)
    mission.progress = 0
    mission.swapped = True
    await db.flush()
    return missions


# --- Progress --------------------------------------------------------------------------------


def _counts(mission: DailyMission, kind: MissionKind, chapter_id: int | None) -> bool:
    if mission.done_at is not None or mission.kind != kind.value:
        return False
    if kind == MissionKind.CHAPTER_ANSWER:
        wanted = mission.params.get("chapter_id")
        return wanted is None or wanted == chapter_id
    return True


async def record(
    db: AsyncSession,
    user_id: uuid.UUID,
    kind: MissionKind,
    *,
    count: int,
    event_id: str,
    now: datetime,
    chapter_id: int | None = None,
) -> list[DailyMission]:
    """Count an event towards today's missions (once per ``event_id`` and kind); returns the
    missions it completed."""
    if count <= 0:
        return []
    claimed = await db.scalar(
        insert(ProgressEventDedupe)
        .values(user_id=user_id, kind=kind.value, event_id=event_id)
        .on_conflict_do_nothing()
        .returning(ProgressEventDedupe.event_id)
    )
    if claimed is None:
        return []
    missions = await todays_missions(db, user_id, now=now, lock=True)
    completed = []
    for mission in missions:
        if _counts(mission, kind, chapter_id):
            mission.progress = min(mission.target, mission.progress + count)
            if mission.progress >= mission.target:
                mission.done_at = now
                completed.append(mission)
    if not completed:
        return []
    await db.flush()
    for mission in completed:
        await _complete(db, user_id, mission, now=now)
    if all_done(missions):
        await _bonus(db, user_id, ist_day(now), now=now)
    return completed


async def _complete(
    db: AsyncSession, user_id: uuid.UUID, mission: DailyMission, *, now: datetime
) -> None:
    await award_xp(
        db,
        user_id,
        mission.xp,
        source=XpSource.MISSION,
        source_key=f"mission:{mission.id}",
        ref_id=mission.id,
        now=now,
    )
    await notify(
        db,
        user_id,
        kind="mission_done",
        title="Mission complete",
        body=f"{mission.title} · +{mission.xp} XP",
        icon="mission",
        action={"route": "/home", "params": {}},
        key=f"mission_done:{mission.id}",
    )
    await track(db, "mission_completed", user_id, {"mission": mission.def_id}, now=now)


async def _bonus(db: AsyncSession, user_id: uuid.UUID, day: date, *, now: datetime) -> None:
    await award_xp(
        db,
        user_id,
        BONUS_XP,
        source=XpSource.MISSION,
        source_key=f"missions_bonus:{day.isoformat()}",
        ref_id=None,
        now=now,
    )
    await credit(
        db,
        user_id,
        BONUS_COINS,
        reason=CoinReason.MISSION_BONUS,
        title=BONUS_TITLE,
        key=f"missions:{user_id}:{day.isoformat()}:bonus",
        ref=Ref(RefKind.MISSION, day.isoformat()),
    )
    await notify(
        db,
        user_id,
        kind="mission_done",
        title="All missions done!",
        body=f"Today's bonus: +{BONUS_XP} XP and {BONUS_COINS} coins",
        icon="mission",
        action={"route": "/home", "params": {}},
        key=f"missions_bonus:{day.isoformat()}",
    )
    await achievements.signal(
        db, user_id, Metric.MISSION_DAYS, amount=1, event_id=f"missions:{day.isoformat()}"
    )


def item_out(mission: DailyMission) -> dict[str, Any]:
    """One mission in Home's ``missions.items`` (and ``GET /v1/me/missions``)."""
    return {
        "id": str(mission.id),
        "slot": mission.slot,
        "title": mission.title,
        "progress": mission.progress,
        "target": mission.target,
        "xp": mission.xp,
        "done": mission.done_at is not None,
        "swapped": mission.swapped,
        "action": action_of(mission),
    }


def settled_item(mission: DailyMission) -> dict[str, Any]:
    """One mission in ``match.settled.missions``."""
    return {
        "id": str(mission.id),
        "title": mission.title,
        "progress": mission.progress,
        "target": mission.target,
        "done": mission.done_at is not None,
    }
