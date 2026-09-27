"""Coach tips: short plain-language instructions, each with one action.

A rule-based engine over the user's answer statistics. Accuracy is smoothed as (c + 2) / (n + 4)
so a couple of answers can't swing it, while messages quote the raw counts. ``TipRule`` lists
the rules in priority order. Tips unlock after 20 answers; the user sees at most 5, at most one
per area.
"""

import math
from collections.abc import Iterator, Mapping, Sequence
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal
from enum import StrEnum
from fractions import Fraction

UNLOCK_ANSWERS = 20
MAX_TIPS = 5
PRACTICE_COUNT = "10"


class AreaKind(StrEnum):
    TOPIC = "topic"
    CHAPTER = "chapter"
    CATEGORY = "category"


class TipRule(StrEnum):
    """Tip rules, most important first."""

    WEAK_TOPIC = "weak_topic"
    FAST_BUT_WRONG = "fast_but_wrong"
    SLOW_VS_OPPONENTS = "slow_vs_opponents"
    SLOW_CATEGORY = "slow_category"
    REVIEW_DUE = "review_due"
    UNTRIED_CHAPTER = "untried_chapter"
    LEVEL_UP = "level_up"
    STRENGTH = "strength"


class TipAction(StrEnum):
    PRACTICE = "practice"
    TIMED_PRACTICE = "timed_practice"
    PRACTICE_CATEGORY = "practice_category"
    REVIEW = "review"
    START_CHAPTER = "start_chapter"
    PRACTICE_MEDIUM = "practice_medium"
    BATTLE = "battle"


@dataclass(frozen=True, slots=True)
class AreaStats:
    """Answer statistics for a topic, a chapter or a category within a subject.

    Topic and chapter keys are ids; a category's key is the category itself, and ``subject``
    tells categories of different subjects apart. ``fast``/``slow``/``even`` count answers
    labelled against opponents. ``typical_ratio`` is the geometric mean of the user's time over
    the typical time across ``typical_compared`` answers. ``fast_wrong`` counts wrong answers
    labelled fast; ``easy_*`` count answers to easy questions.
    """

    kind: AreaKind
    key: str
    name: str
    subject: str
    chapter_key: str | None = None
    attempts: int = 0
    correct: int = 0
    fast: int = 0
    slow: int = 0
    even: int = 0
    typical_compared: int = 0
    typical_ratio: float | None = None
    fast_wrong: int = 0
    easy_attempts: int = 0
    easy_correct: int = 0


@dataclass(frozen=True, slots=True)
class TipInputs:
    """Everything the rules read; ``untried_chapters`` holds (key, name) in suggestion order."""

    total_answers: int
    overall_attempts: int
    overall_correct: int
    areas: Sequence[AreaStats] = ()
    reviews_due: int = 0
    untried_chapters: Sequence[tuple[str, str]] = ()
    dismissed: frozenset[str] = frozenset()


@dataclass(frozen=True, slots=True)
class Tip:
    """One instruction; ``key`` ("rule:target") stays the same while the tip applies."""

    key: str
    rule: TipRule
    target: str
    message: str
    action: TipAction
    params: Mapping[str, str]
    priority: int  # 1 is the most important


@dataclass(frozen=True, slots=True)
class _Candidate:
    tip: Tip
    area: tuple[str, str]  # (kind, target): at most one tip each
    rank: tuple[int, Fraction, str]  # priority, then the worse case first, then target
    topic_chapter: str | None = None  # a topic tip's chapter


_PRIORITY: Mapping[TipRule, int] = {rule: i for i, rule in enumerate(TipRule, start=1)}
_TOPIC_RULES = frozenset({TipRule.WEAK_TOPIC, TipRule.FAST_BUT_WRONG, TipRule.SLOW_VS_OPPONENTS})


def answers_until_unlock(total_answers: int) -> int:
    """How many more answers the user needs before tips appear."""
    return max(0, UNLOCK_ANSWERS - total_answers)


def build_tips(inputs: TipInputs) -> list[Tip]:
    """Up to 5 tips, most important first; none before 20 answers.

    Rules, in priority order (acc is smoothed accuracy):

    1. WEAK_TOPIC: a topic with >= 5 answers and acc <= 0.5, or 0.15 below the overall acc.
    2. FAST_BUT_WRONG: a topic with >= 6 answers, at least 40% of them fast but wrong.
    3. SLOW_VS_OPPONENTS: a topic or chapter with >= 5 compared answers, >= 3 of them and at
       least 60% slow. A chapter gives way when one of its topics has a tip from rules 1-3.
    4. SLOW_CATEGORY: a category with >= 8 typical-time comparisons and a ratio >= 1.3.
    5. REVIEW_DUE: questions waiting in the review queue.
    6. UNTRIED_CHAPTER: the first untried chapter.
    7. LEVEL_UP: a chapter with >= 10 easy answers, at least 85% right.
    8. STRENGTH: a topic with >= 10 answers and acc >= 0.8.

    Within a rule the worse case comes first (for LEVEL_UP and STRENGTH, the stronger one),
    then target order. Dismissed tips count as never raised; then each area keeps its most
    important tip.
    """
    if inputs.total_answers < UNLOCK_ANSWERS:
        return []
    targets = [(area.kind.value, _target(area)) for area in inputs.areas]
    if len(set(targets)) != len(targets):
        raise ValueError("areas must be unique")

    overall = _smoothed(inputs.overall_correct, inputs.overall_attempts)
    candidates = [
        candidate
        for candidate in _candidates(inputs, overall)
        if candidate.tip.key not in inputs.dismissed
    ]
    tipped_chapters = {
        c.topic_chapter
        for c in candidates
        if c.tip.rule in _TOPIC_RULES and c.topic_chapter is not None
    }

    tips: list[Tip] = []
    covered: set[tuple[str, str]] = set()
    untried_suggested = False
    for candidate in sorted(candidates, key=lambda c: c.rank):
        tip = candidate.tip
        if candidate.area in covered:
            continue
        if (
            tip.rule is TipRule.SLOW_VS_OPPONENTS
            and candidate.area[0] == AreaKind.CHAPTER.value
            and tip.target in tipped_chapters
        ):
            continue  # the chapter's topics already have more specific advice
        if tip.rule is TipRule.UNTRIED_CHAPTER:
            if untried_suggested:
                continue
            untried_suggested = True
        covered.add(candidate.area)
        tips.append(tip)
        if len(tips) == MAX_TIPS:
            break
    return tips


def _candidates(inputs: TipInputs, overall: Fraction) -> Iterator[_Candidate]:
    for area in inputs.areas:
        yield from _area_candidates(area, overall)
    if inputs.reviews_due >= 1:
        n = inputs.reviews_due
        waiting = "1 question is" if n == 1 else f"{n} questions are"
        yield _candidate(
            TipRule.REVIEW_DUE,
            ("review", "all"),
            f"{waiting} waiting for review.",
            TipAction.REVIEW,
            {},
            Fraction(0),
        )
    for index, (key, name) in enumerate(inputs.untried_chapters):
        yield _candidate(
            TipRule.UNTRIED_CHAPTER,
            (AreaKind.CHAPTER.value, key),
            f"You haven't tried {name} yet. Start with 10 easy questions.",
            TipAction.START_CHAPTER,
            {"chapter": key, "difficulty": "easy", "count": PRACTICE_COUNT},
            Fraction(index),
        )


def _area_candidates(area: AreaStats, overall: Fraction) -> Iterator[_Candidate]:
    identity = (area.kind.value, _target(area))
    acc = _smoothed(area.correct, area.attempts)
    topic = area.kind is AreaKind.TOPIC
    chapter_of_topic = area.chapter_key if topic else None

    if topic and area.attempts >= 5 and (acc <= Fraction(1, 2) or overall - acc >= Fraction(3, 20)):
        yield _candidate(
            TipRule.WEAK_TOPIC,
            identity,
            f"Focus on {area.name}. You got {area.correct} of {area.attempts} right.",
            TipAction.PRACTICE,
            {"topic": area.key, "count": PRACTICE_COUNT},
            acc,
            chapter_of_topic,
        )
    if topic and area.attempts >= 6 and 5 * area.fast_wrong >= 2 * area.attempts:
        yield _candidate(
            TipRule.FAST_BUT_WRONG,
            identity,
            f"You answer {area.name} questions quickly but often miss. "
            "Read all four options first.",
            TipAction.PRACTICE,
            {"topic": area.key, "count": PRACTICE_COUNT},
            -Fraction(area.fast_wrong, area.attempts),
            chapter_of_topic,
        )
    compared = area.fast + area.slow + area.even
    if (
        area.kind in (AreaKind.TOPIC, AreaKind.CHAPTER)
        and compared >= 5
        and area.slow >= 3
        and 5 * area.slow >= 3 * compared
    ):
        yield _candidate(
            TipRule.SLOW_VS_OPPONENTS,
            identity,
            f"You're often slower than your opponents in {area.name}. Try a timed practice set.",
            TipAction.TIMED_PRACTICE,
            {area.kind.value: area.key, "count": PRACTICE_COUNT},
            -Fraction(area.slow, compared),
            chapter_of_topic,
        )
    ratio = area.typical_ratio
    if (
        area.kind is AreaKind.CATEGORY
        and area.typical_compared >= 8
        and ratio is not None
        and math.isfinite(ratio)
        and ratio >= 1.3
    ):
        yield _candidate(
            TipRule.SLOW_CATEGORY,
            identity,
            f"Practise more {area.name}. "
            f"You take about {_percent_longer(ratio)}% longer than other students.",
            TipAction.PRACTICE_CATEGORY,
            {"subject": area.subject, "category": area.key, "count": PRACTICE_COUNT},
            -Fraction(ratio),
        )
    if (
        area.kind is AreaKind.CHAPTER
        and area.easy_attempts >= 10
        and 20 * area.easy_correct >= 17 * area.easy_attempts
    ):
        yield _candidate(
            TipRule.LEVEL_UP,
            identity,
            f"You've got the basics of {area.name}. Try medium questions.",
            TipAction.PRACTICE_MEDIUM,
            {"chapter": area.key, "difficulty": "medium", "count": PRACTICE_COUNT},
            -Fraction(area.easy_correct, area.easy_attempts),
        )
    if topic and area.attempts >= 10 and acc >= Fraction(4, 5):
        battle = {"subject": area.subject}
        if area.chapter_key is not None:
            battle["chapter"] = area.chapter_key
        yield _candidate(
            TipRule.STRENGTH,
            identity,
            f"You're strong in {area.name}. Test it in a rated battle.",
            TipAction.BATTLE,
            battle,
            -acc,
            chapter_of_topic,
        )


def _candidate(
    rule: TipRule,
    area: tuple[str, str],
    message: str,
    action: TipAction,
    params: Mapping[str, str],
    severity: Fraction,
    topic_chapter: str | None = None,
) -> _Candidate:
    target = area[1]
    tip = Tip(f"{rule}:{target}", rule, target, message, action, params, _PRIORITY[rule])
    return _Candidate(tip, area, (tip.priority, severity, target), topic_chapter)


def _target(area: AreaStats) -> str:
    return f"{area.subject}:{area.key}" if area.kind is AreaKind.CATEGORY else area.key


def _smoothed(correct: int, attempts: int) -> Fraction:
    return Fraction(correct + 2, attempts + 4)


def _percent_longer(ratio: float) -> int:
    """(ratio - 1) * 100 rounded half up to the nearest 10, reading the ratio as printed."""
    tens = ((Decimal(str(ratio)) - 1) * 10).quantize(Decimal(1), rounding=ROUND_HALF_UP)
    return int(tens) * 10
