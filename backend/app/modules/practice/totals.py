"""Running totals per topic, chapter, subject category and IST day.

Updated in the same transaction as the answers they count, and only for answers that were
actually recorded (never for duplicates). Rows are upserted in key order so concurrent batches
of one user lock them in the same order.
"""

import math
import uuid
from collections.abc import Callable, Hashable, Iterable, Mapping
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any

from sqlalchemy import func
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import Base
from app.modules.content.models import EASY_MAX_DIFFICULTY
from app.modules.practice.models import (
    Outcome,
    UserCategoryStats,
    UserChapterStats,
    UserDailyStats,
    UserTopicStats,
)

OPPONENTS, TYPICAL = "opponents", "typical"


@dataclass(frozen=True, slots=True)
class AnswerFacts:
    """What the totals need to know about one recorded answer."""

    subject_id: int
    chapter_id: int | None
    topic_id: int | None
    category: str
    difficulty: int
    outcome: str
    time_ms: int
    speed: str | None
    speed_basis: str | None
    peer_time_ms: int | None
    first_try: bool
    answered_at: datetime
    ist_day: date


class _Sums:
    """The columns shared by topic, chapter and category totals, summed over answers."""

    def __init__(self) -> None:
        self.values: dict[str, Any] = {
            "attempts": 0,
            "correct": 0,
            "time_ms": 0,
            "correct_time_ms": 0,
            "fast": 0,
            "slow": 0,
            "even": 0,
            "typical_compared": 0,
            "typical_log_ratio_sum": 0.0,
            "fast_wrong": 0,
            "easy_attempts": 0,
            "easy_correct": 0,
        }
        self.seen = 0
        self.last_at: datetime | None = None

    def add(self, facts: AnswerFacts) -> None:
        values = self.values
        correct = facts.outcome == Outcome.CORRECT
        values["attempts"] += 1
        values["correct"] += correct
        values["time_ms"] += facts.time_ms
        values["correct_time_ms"] += facts.time_ms if correct else 0
        if facts.speed_basis == OPPONENTS and facts.speed in {"fast", "slow", "even"}:
            values[facts.speed] += 1
        if facts.speed_basis == TYPICAL and facts.peer_time_ms:
            values["typical_compared"] += 1
            values["typical_log_ratio_sum"] += math.log(max(facts.time_ms, 1) / facts.peer_time_ms)
        values["fast_wrong"] += facts.speed == "fast" and facts.outcome == Outcome.WRONG
        if facts.difficulty <= EASY_MAX_DIFFICULTY:
            values["easy_attempts"] += 1
            values["easy_correct"] += correct
        self.seen += facts.first_try
        self.last_at = max(filter(None, (self.last_at, facts.answered_at)))


def _group(
    facts: Iterable[AnswerFacts], key: Callable[[AnswerFacts], Hashable | None]
) -> dict[Any, _Sums]:
    groups: dict[Any, _Sums] = {}
    for item in facts:
        group_key = key(item)
        if group_key is not None:
            groups.setdefault(group_key, _Sums()).add(item)
    return groups


async def _upsert(
    db: AsyncSession,
    model: type[Base],
    keys: tuple[str, ...],
    rows: Mapping[Any, Mapping[str, Any]],
    counters: Iterable[str],
) -> None:
    if not rows:
        return
    table = model.__table__
    values = [{**dict(zip(keys, key, strict=True)), **row} for key, row in sorted(rows.items())]
    statement = insert(model).values(values)
    update = {name: table.c[name] + statement.excluded[name] for name in counters}
    update["last_at"] = func.greatest(table.c.last_at, statement.excluded.last_at)
    await db.execute(statement.on_conflict_do_update(index_elements=list(keys), set_=update))


async def add_to_totals(db: AsyncSession, user_id: uuid.UUID, facts: list[AnswerFacts]) -> None:
    """Count newly recorded answers into the user's running totals."""
    if not facts:
        return
    shared = list(_Sums().values)

    def rows(groups: dict[Any, _Sums], *, seen: bool = False) -> dict[Any, dict[str, Any]]:
        return {
            (user_id, *(key if isinstance(key, tuple) else (key,))): {
                **sums.values,
                **({"seen": sums.seen} if seen else {}),
                "last_at": sums.last_at,
            }
            for key, sums in groups.items()
        }

    await _upsert(
        db,
        UserTopicStats,
        ("user_id", "topic_id"),
        rows(_group(facts, lambda f: f.topic_id)),
        shared,
    )
    await _upsert(
        db,
        UserChapterStats,
        ("user_id", "chapter_id"),
        rows(_group(facts, lambda f: f.chapter_id), seen=True),
        [*shared, "seen"],
    )
    await _upsert(
        db,
        UserCategoryStats,
        ("user_id", "subject_id", "category"),
        rows(_group(facts, lambda f: (f.subject_id, f.category))),
        shared,
    )
    daily: dict[Any, dict[str, Any]] = {}
    for item in facts:
        row = daily.setdefault(
            (user_id, item.ist_day, item.subject_id),
            {"attempts": 0, "correct": 0, "time_ms": 0, "last_at": item.answered_at},
        )
        row["attempts"] += 1
        row["correct"] += item.outcome == Outcome.CORRECT
        row["time_ms"] += item.time_ms
        row["last_at"] = max(row["last_at"], item.answered_at)
    await _upsert(
        db,
        UserDailyStats,
        ("user_id", "day", "subject_id"),
        daily,
        ["attempts", "correct", "time_ms"],
    )
