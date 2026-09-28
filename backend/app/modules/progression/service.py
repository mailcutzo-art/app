"""Progression's entry points for other features: events, Home's missions and settlement.

``record_event`` is how anything that happened reaches missions, streaks and achievements:

- ``practice_answer``: the practice missions and the ``answers`` achievements (the streak reads
  answers from ``user_daily_stats``);
- ``review_answer``: the review mission and ``review_answers``;
- ``chapter_answer`` (``meta.chapter_id``): the chapter missions;
- ``rated_game``, ``tournament_game``: the play mission;
- ``battle_finished``: the "any battle" mission, today's finished battles for the streak, and
  ``battles``;
- ``battle_answer``: ``answers``; ``battle_won``: ``wins``; ``perfect_battle``:
  ``perfect_battles``;
- ``tournament_finished``, ``tournament_podium``, ``tournament_won``: ``tournaments``,
  ``podiums``, ``tournament_wins``;
- ``friend_made``: ``friends``.

Each ``(user, kind, event_id)`` counts once. Achievements are applied by the outbox consumer
(``progression.achievement``) unless the caller asks for them now.
"""

import uuid
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Any

from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.progression import achievements, missions, streaks
from app.modules.progression.achievements import Earned
from app.modules.progression.levels import GameKind, GameOutcome
from app.modules.progression.models import (
    DailyMission,
    Metric,
    MissionKind,
    ProgressEventDedupe,
    UserProgress,
)
from app.modules.progression.xp import xp_rules


class EventKind(StrEnum):
    PRACTICE_ANSWER = "practice_answer"
    REVIEW_ANSWER = "review_answer"
    CHAPTER_ANSWER = "chapter_answer"
    RATED_GAME = "rated_game"
    TOURNAMENT_GAME = "tournament_game"
    BATTLE_FINISHED = "battle_finished"
    BATTLE_ANSWER = "battle_answer"
    BATTLE_WON = "battle_won"
    PERFECT_BATTLE = "perfect_battle"
    TOURNAMENT_FINISHED = "tournament_finished"
    TOURNAMENT_PODIUM = "tournament_podium"
    TOURNAMENT_WON = "tournament_won"
    FRIEND_MADE = "friend_made"


_MISSION_KIND: Mapping[EventKind, MissionKind] = {
    EventKind.PRACTICE_ANSWER: MissionKind.PRACTICE_ANSWER,
    EventKind.REVIEW_ANSWER: MissionKind.REVIEW_ANSWER,
    EventKind.CHAPTER_ANSWER: MissionKind.CHAPTER_ANSWER,
    EventKind.RATED_GAME: MissionKind.RATED_GAME,
    EventKind.TOURNAMENT_GAME: MissionKind.RATED_GAME,
    EventKind.BATTLE_FINISHED: MissionKind.BATTLE_FINISHED,
}
_METRIC: Mapping[EventKind, Metric] = {
    EventKind.PRACTICE_ANSWER: Metric.ANSWERS,
    EventKind.REVIEW_ANSWER: Metric.REVIEW_ANSWERS,
    EventKind.BATTLE_FINISHED: Metric.BATTLES,
    EventKind.BATTLE_ANSWER: Metric.ANSWERS,
    EventKind.BATTLE_WON: Metric.WINS,
    EventKind.PERFECT_BATTLE: Metric.PERFECT_BATTLES,
    EventKind.TOURNAMENT_FINISHED: Metric.TOURNAMENTS,
    EventKind.TOURNAMENT_PODIUM: Metric.PODIUMS,
    EventKind.TOURNAMENT_WON: Metric.TOURNAMENT_WINS,
    EventKind.FRIEND_MADE: Metric.FRIENDS,
}


@dataclass(slots=True)
class EventResult:
    missions_done: list[DailyMission] = field(default_factory=list)
    achievements: list[Earned] = field(default_factory=list)


async def record_event(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    kind: EventKind | str,
    count: int = 1,
    event_id: str,
    now: datetime,
    meta: Mapping[str, Any] | None = None,
    apply_achievements: bool = False,
) -> EventResult:
    """Count something that happened, in the caller's transaction.

    ``event_id`` names the occurrence (``match:{id}``, ``practice:{session}:{position}``...);
    recording it again changes nothing. ``meta``: ``chapter_id`` for ``chapter_answer``.
    ``apply_achievements`` awards achievements now instead of through the outbox.
    """
    kind = EventKind(kind)
    result = EventResult()
    if count <= 0:
        return result
    if kind == EventKind.BATTLE_FINISHED:
        claimed = await db.scalar(
            insert(ProgressEventDedupe)
            .values(user_id=user_id, kind="streak:battle", event_id=event_id)
            .on_conflict_do_nothing()
            .returning(ProgressEventDedupe.event_id)
        )
        if claimed is not None:
            await streaks.record_battle(db, user_id, now=now)
    mission_kind = _MISSION_KIND.get(kind)
    if mission_kind is not None:
        chapter = (meta or {}).get("chapter_id")
        result.missions_done = await missions.record(
            db,
            user_id,
            mission_kind,
            count=count,
            event_id=f"{kind.value}:{event_id}",
            now=now,
            chapter_id=int(chapter) if chapter is not None else None,
        )
    metric = _METRIC.get(kind)
    if metric is not None:
        metric_event = f"{kind.value}:{event_id}"
        if apply_achievements:
            result.achievements = await achievements.apply(
                db, user_id, metric, amount=count, event_id=metric_event, now=now
            )
        else:
            await achievements.signal(db, user_id, metric, amount=count, event_id=metric_event)
    return result


async def missions_summary(db: AsyncSession, user_id: uuid.UUID, now: datetime) -> dict[str, Any]:
    """Home's ``missions`` section data (also ``GET /v1/me/missions``)::

    {"day", "items": [{"id", "slot", "title", "progress", "target", "xp", "done", "swapped",
     "action"}], "bonus": {"xp", "coins", "done"}, "swap_available",
     "streak": {"days", "today_done", "freezes"}}
    """
    today = await missions.todays_missions(db, user_id, now=now)
    streak = await streaks.evaluate(db, user_id, now=now)
    return {
        "day": missions.ist_day(now).isoformat(),
        "items": [missions.item_out(m) for m in today],
        "bonus": {
            "xp": missions.BONUS_XP,
            "coins": missions.BONUS_COINS,
            "done": missions.all_done(today),
        },
        "swap_available": missions.swap_available(today),
        "streak": streak.home(),
    }


@dataclass(frozen=True, slots=True)
class SettlementProgress:
    missions: list[dict[str, Any]]
    streak: dict[str, Any]
    achievements: list[dict[str, str]]

    def fragment(self) -> dict[str, Any]:
        """The ``missions``, ``streak`` and ``achievements`` fields of ``match.settled``."""
        return {"missions": self.missions, "streak": self.streak, "achievements": self.achievements}


async def settlement_progress(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    mode: GameKind | str,
    result: GameOutcome | str,
    match_id: uuid.UUID,
    now: datetime,
    answered: int = 0,
    perfect: bool = False,
) -> SettlementProgress:
    """Everything a finished game does for one player's missions, streak and achievements.

    Call inside the settlement transaction, after ``award_game_xp`` (so level achievements see
    the new level). ``answered`` is how many questions the player answered, ``perfect`` whether
    they got all of them right. Wins and perfect games against the Practice Bot don't count
    toward achievements. Safe to repeat: a replay counts nothing twice, and reports the same
    missions and achievements already earned are not listed again.
    """
    kind, outcome = GameKind(mode), GameOutcome(result)
    event = f"match:{match_id}"
    events: list[tuple[EventKind, int]] = [(EventKind.BATTLE_FINISHED, 1)]
    if kind == GameKind.QUICK_RATED:
        events.append((EventKind.RATED_GAME, 1))
    elif kind == GameKind.TOURNAMENT:
        events.append((EventKind.TOURNAMENT_GAME, 1))
    if answered > 0:
        events.append((EventKind.BATTLE_ANSWER, answered))
    if kind != GameKind.BOT and outcome == GameOutcome.WIN:
        events.append((EventKind.BATTLE_WON, 1))
    if kind != GameKind.BOT and perfect:
        events.append((EventKind.PERFECT_BATTLE, 1))
    earned: list[Earned] = []
    for event_kind, count in events:
        recorded = await record_event(
            db,
            user_id,
            kind=event_kind,
            count=count,
            event_id=event,
            now=now,
            apply_achievements=True,
        )
        earned += recorded.achievements
    streak = await streaks.evaluate(db, user_id, now=now)
    # The streak and level signals are queued; count them now so this result can list them.
    earned += await achievements.apply(
        db,
        user_id,
        Metric.STREAK,
        amount=streak.days,
        event_id=f"settled:{match_id}",
        now=now,
    )
    progress = await db.get(UserProgress, user_id)
    level = xp_rules().progress(progress.xp if progress else 0).level
    earned += await achievements.apply(
        db, user_id, Metric.LEVEL, amount=level, event_id=f"settled:{match_id}", now=now
    )
    today = await missions.todays_missions(db, user_id, now=now)
    return SettlementProgress(
        missions=[missions.settled_item(m) for m in today],
        streak={"days": streak.days, "extended": streak.extended},
        achievements=[e.fragment() for e in earned],
    )
