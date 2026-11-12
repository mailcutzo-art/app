"""Recommended practice: which questions a student should do next.

The content side (``app.modules.content.priority``) ranks every topic once: importance, a tier
(core, standard, extra) and a study order. This module personalises a session on top of it, in
three steps (see ``docs/recommendation.md``):

1. **Reviews first in line.** Mistakes that are due for review take up to 20% of the session.
2. **Split the rest across topics.** Each topic in scope gets a weight:
   ``sqrt(questions) * need``, where need grows with the share of its core set the student
   hasn't got right yet, with how weak they are in it (smoothed accuracy), and with how long ago
   they practised it. If there are at least as many slots as topics every topic gets one, and
   the rest go by the Sainte-Laguë rule on the weights; otherwise a weighted random draw picks
   which topics this session visits, so the next session visits others.
3. **Pick within each topic.** Unseen questions first: core before standard before extra, then
   the question whose difficulty is closest to the student's level in the topic, preferring
   ideas (clusters: subtopic, or tag) they haven't met and not repeating one in a session
   while others are left. A little randomness keeps two sessions from being identical. When a
   topic has no unseen questions left, it serves those answered wrong last time, then the
   longest ago.

The session is then ordered: new questions from easy to hard with the topics interleaved, then
the reviews, then the refreshers.

Everything here is pure (no database) so it can be tested on its own; ``selection.py`` loads the
inputs.
"""

import math
import random
import uuid
from collections import defaultdict
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime

# Up to this share of a session is spent on mistakes due for review.
REVIEW_SHARE = 0.2

# Topic need: base + core left + weakness + staleness.
NEED_BASE = 0.3
NEED_CORE_LEFT = 0.9
NEED_WEAKNESS = 0.6
NEED_STALE = 0.3
STALE_DAYS = 7
NO_UNSEEN_FACTOR = 0.5  # a topic with only refreshers left matters less

# Question scores within a topic (unseen questions).
TIER_POINTS = {1: 2.0, 2: 1.0, 3: 0.0}
IMPORTANCE_POINTS = 0.5  # times importance / 100
FIT_POINTS = 0.6  # times difficulty fit (1 = exactly the student's level)
NEW_CLUSTER_POINTS = 0.3  # an idea the student hasn't met yet
SESSION_REPEAT_PENALTY = 0.8  # per earlier pick of the same cluster in this session
JITTER = 0.15


@dataclass(frozen=True, slots=True)
class TopicState:
    """A topic in scope, as far as this student is concerned."""

    topic_id: int
    available: int  # questions that match the request
    unseen: int  # of them, never answered by the student
    core_total: int  # core questions among them
    core_left: int  # core questions the student hasn't answered correctly yet
    attempts: int = 0  # the student's answers in this topic, every mode
    correct: int = 0
    last_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class Candidate:
    """A question that matches the request, with the student's history of it."""

    id: uuid.UUID
    topic_id: int
    cluster: str | None  # the idea it tests (subtopic, or a tag)
    difficulty: int
    category: str
    tier: int
    rank: int  # study order within the topic
    importance: int
    attempts: int = 0
    correct: int = 0
    last_at: datetime | None = None
    last_outcome: str | None = None

    @property
    def seen(self) -> bool:
        return self.attempts > 0


@dataclass(frozen=True, slots=True)
class Pick:
    question: Candidate
    order: int  # position among the picks of its topic, from 0


def review_slots(count: int, due: int) -> int:
    """How many of ``count`` slots go to the ``due`` reviews."""
    if due <= 0:
        return 0
    return min(due, max(1, round(REVIEW_SHARE * count)))


def smoothed_accuracy(attempts: int, correct: int) -> float:
    return (correct + 2) / (attempts + 4)


def target_difficulty(attempts: int, correct: int) -> float:
    """The difficulty (1-5) that suits the student's level: 2.3 for a newcomer, 5 at 90%."""
    accuracy = smoothed_accuracy(attempts, correct)
    return 1 + 4 * min(1.0, max(0.0, (accuracy - 0.3) / 0.6))


def topic_need(state: TopicState, now: datetime) -> float:
    core_left = state.core_left / state.core_total if state.core_total else 0.0
    weakness = 1 - smoothed_accuracy(state.attempts, state.correct)
    if state.last_at is None:
        stale = 1.0
    else:
        stale = min(1.0, max(0.0, (now - state.last_at).total_seconds() / 86400 / STALE_DAYS))
    need = NEED_BASE + NEED_CORE_LEFT * core_left + NEED_WEAKNESS * weakness + NEED_STALE * stale
    return need if state.unseen else need * NO_UNSEEN_FACTOR


def topic_weight(state: TopicState, now: datetime) -> float:
    return math.sqrt(state.available) * topic_need(state, now)


def allocate(
    topics: Sequence[TopicState], slots: int, *, now: datetime, rng: random.Random
) -> dict[int, int]:
    """How many questions each topic gets (topics that get none are left out)."""
    open_ = [t for t in topics if t.available > 0]
    if slots <= 0 or not open_:
        return {}
    weights = {t.topic_id: topic_weight(t, now) for t in open_}
    capacity = {t.topic_id: t.available for t in open_}
    if slots < len(open_):
        # Weighted sampling without replacement (Efraimidis-Spirakis): key = u ** (1 / w).
        keys = {
            topic_id: rng.random() ** (1 / weight) if weight > 0 else 0.0
            for topic_id, weight in weights.items()
        }
        chosen = sorted(keys, key=lambda topic_id: (-keys[topic_id], topic_id))[:slots]
        return dict.fromkeys(chosen, 1)
    given = {t.topic_id: 1 for t in open_}
    left = slots - len(open_)
    while left > 0:
        spare = [topic_id for topic_id in given if given[topic_id] < capacity[topic_id]]
        if not spare:
            break
        best = min(
            spare, key=lambda topic_id: (-weights[topic_id] / (2 * given[topic_id] + 1), topic_id)
        )
        given[best] += 1
        left -= 1
    return given


def pick_in_topic(
    candidates: Sequence[Candidate],
    take: int,
    *,
    target: float,
    rng: random.Random,
) -> list[Candidate]:
    """``take`` questions of one topic: unseen ones by score, then refreshers."""
    met = {c.cluster for c in candidates if c.seen}
    unseen = [c for c in candidates if not c.seen]
    jitter = {c.id: rng.random() * JITTER for c in unseen}
    in_session: dict[str | None, int] = defaultdict(int)
    chosen: list[Candidate] = []

    def score(c: Candidate) -> float:
        fit = 1 - abs(c.difficulty - target) / 4
        points = TIER_POINTS.get(c.tier, 0.0) + IMPORTANCE_POINTS * c.importance / 100
        points += FIT_POINTS * fit + jitter[c.id]
        if c.cluster is not None and c.cluster not in met:
            points += NEW_CLUSTER_POINTS
        if c.cluster is not None:
            points -= SESSION_REPEAT_PENALTY * in_session[c.cluster]
        return points

    while unseen and len(chosen) < take:
        best = max(unseen, key=lambda c: (score(c), -c.rank))
        unseen.remove(best)
        chosen.append(best)
        in_session[best.cluster] += 1
    if len(chosen) < take:
        refreshers = sorted(
            (c for c in candidates if c.seen),
            key=lambda c: (c.last_outcome == "correct", _timestamp(c.last_at), c.rank),
        )
        chosen.extend(refreshers[: take - len(chosen)])
    return chosen


def choose(
    allocation: Mapping[int, int],
    candidates: Iterable[Candidate],
    states: Mapping[int, TopicState],
    *,
    rng: random.Random,
) -> list[Pick]:
    """The questions for each topic's slots."""
    by_topic: dict[int, list[Candidate]] = defaultdict(list)
    for c in candidates:
        by_topic[c.topic_id].append(c)
    picks: list[Pick] = []
    for topic_id in sorted(allocation):
        state = states.get(topic_id)
        target = target_difficulty(state.attempts, state.correct) if state else 2.5
        chosen = pick_in_topic(by_topic[topic_id], allocation[topic_id], target=target, rng=rng)
        picks.extend(Pick(question, order) for order, question in enumerate(chosen))
    return picks


def order_session(picks: Sequence[Pick], reviews: Sequence[uuid.UUID]) -> list[uuid.UUID]:
    """New questions easy to hard with topics interleaved, then reviews, then refreshers."""
    new = sorted(
        (p for p in picks if not p.question.seen),
        key=lambda p: (p.question.difficulty, p.order, p.question.topic_id),
    )
    refresh = sorted(
        (p for p in picks if p.question.seen),
        key=lambda p: (_timestamp(p.question.last_at), p.question.topic_id),
    )
    return [p.question.id for p in new] + list(reviews) + [p.question.id for p in refresh]


def _timestamp(moment: datetime | None) -> float:
    return moment.timestamp() if moment is not None else 0.0
