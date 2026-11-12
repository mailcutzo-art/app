"""Which questions of a topic matter most: importance, tier and study order.

A chapter holds about 500 questions, more than a student can work through. The seed ranks every
topic's questions once, so practice can recommend a small set that still covers the topic:

1. **Importance** (0-100) of each question, from what the content records:
   - NCERT-based concept and factual questions score higher (NEET is set from NCERT). For
     numericals and applications the flag says whether the situation is in the book, not
     whether the skill is in the syllabus, so they get the neutral score either way;
   - medium difficulty scores higher than the extremes (the exam's centre of mass);
   - exam-pattern formats (assertion-reason, statement pairs, match...) score a little higher;
   - questions whose figure the app can't draw yet score lower;
   - and **yield**: subtopics the authors wrote many questions on are the ones the exam keeps
     coming back to, so their questions score higher (log-scaled within the topic).
2. **Coverage-first ranking.** The topic's questions are put in a study order one pick at a
   time. Each pick first chooses the subtopic whose turn it is: every subtopic gets its first
   question before any gets a second (largest subtopics first); after that the Sainte-Laguë rule
   on ``sqrt(subtopic size)`` gives big subtopics more turns than small ones, but not
   proportionally more. Within that subtopic it takes the most important question left, minus a
   penalty for repeating a category, difficulty band or format already picked there, plus a
   bonus for a category or difficulty band that is behind its share of the topic (so a prefix
   keeps the topic's mix).
3. **Tiers.** The first 20% of the order (at least 3 questions) is the **core** set (tier 1):
   what a student should do to have covered the topic. The next 20% is **standard** (tier 2);
   the rest is **extra** practice (tier 3).

**Subtopics or tags.** Ranking works on clusters of questions about the same idea. That is the
``subtopic``, unless a topic's subtopics are mostly unique (more than half as many as its
questions, as in most Physics chapters, where the subtopic describes the single question):
then the question's first tag that names an idea (not a label like ``trap`` or ``graph``) is
the cluster.

Everything here is a pure function of the content and deterministic (ties break on the question
id), so re-running the seed gives the same ranking. See ``docs/recommendation.md``.
"""

import math
from collections import defaultdict
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

# Tiers.
CORE, STANDARD, EXTRA = 1, 2, 3
# Share of a topic in the core set, and again in the standard set.
TIER_SHARE = 0.2
MIN_TIER_SIZE = 3

# Importance weights (at most 100 before clamping).
BASE = 20
NCERT_POINTS = {True: 20, None: 10, False: 0}
NCERT_CATEGORIES = frozenset({"concept", "factual"})  # others get NCERT_POINTS[None]
DIFFICULTY_POINTS = {1: 6, 2: 12, 3: 16, 4: 12, 5: 4}
EXAM_PATTERN_FORMATS = frozenset(
    {"assertion-reason", "statement-pair", "multi-statement", "statements", "match"}
)
EXAM_PATTERN_POINTS, OTHER_FORMAT_POINTS = 8, 5
YIELD_POINTS = 24
DIAGRAM_PENALTY = 10

# Diversity penalties (importance points) for repeating a trait within a subtopic.
SAME_CATEGORY_PENALTY = 6
SAME_BAND_PENALTY = 4
SAME_FORMAT_PENALTY = 3
# Balance across the topic: points per question a category or difficulty band is behind its
# share of the topic, so any prefix of the ranking keeps the topic's mix of numericals, facts...
MIX_POINTS = 12

_NO_SUBTOPIC = ""  # questions without a subtopic share one bucket per topic
# Above this many subtopics per question a topic's subtopics describe single questions, so
# questions are clustered by tag instead.
GRANULAR_SUBTOPICS = 0.5
# Tags that label a question's form or trick, not the idea it tests: never a cluster.
GENERIC_TAGS = frozenset(
    {
        "application", "assertion-reason", "calculation", "case", "classification",
        "comparison", "confused-pair", "counting", "definition", "definitions", "diagram",
        "examples", "exception", "experiment", "figure", "flowchart", "graph", "history",
        "identification", "match", "multi-concept", "multi-statement", "ncert-line",
        "numerical", "ordering", "proportionality", "ratio", "sequence", "statement-pair",
        "statements", "terminology", "terms", "trap", "units", "uses",
    }
)  # fmt: skip


@dataclass(frozen=True, slots=True)
class PriorityInput:
    key: str  # the question's stable id
    group: str  # what is ranked together: the subject and topic
    subtopic: str | None
    difficulty: int
    category: str
    format: str | None
    ncert: bool | None
    has_diagram: bool
    tags: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class Priority:
    importance: int  # 0-100
    tier: int  # 1 core, 2 standard, 3 extra
    rank: int  # 1.. within the topic: the recommended study order
    cluster: str  # the idea it tests: its subtopic, or a tag (see above)


def band(difficulty: int) -> str:
    """Easy (1-2), medium (3) or hard (4-5)."""
    return "easy" if difficulty <= 2 else "medium" if difficulty == 3 else "hard"


def tier_size(topic_size: int) -> int:
    """How many questions of a topic go into the core set (and into the standard set)."""
    return min(topic_size, max(MIN_TIER_SIZE, round(TIER_SHARE * topic_size)))


def importance(q: PriorityInput, subtopic_size: int, largest_subtopic: int) -> int:
    fmt = q.format or "direct"
    ncert = q.ncert if q.category in NCERT_CATEGORIES else None
    points: float = BASE + NCERT_POINTS[ncert] + DIFFICULTY_POINTS.get(q.difficulty, 0)
    points += EXAM_PATTERN_POINTS if fmt in EXAM_PATTERN_FORMATS else OTHER_FORMAT_POINTS
    if largest_subtopic > 1:
        points += YIELD_POINTS * math.log1p(subtopic_size) / math.log1p(largest_subtopic)
    else:
        points += YIELD_POINTS / 2
    if q.has_diagram or fmt == "diagram":
        points -= DIAGRAM_PENALTY
    return max(0, min(100, round(points)))


class _Mix:
    """How far the picks so far are from the topic's own mix of categories and bands."""

    def __init__(self, questions: Sequence[PriorityInput]) -> None:
        total = len(questions) or 1
        self.share: dict[str, float] = defaultdict(float)
        for q in questions:
            self.share["c:" + q.category] += 1 / total
            self.share["b:" + band(q.difficulty)] += 1 / total
        self.count: dict[str, int] = defaultdict(int)
        self.picks = 0

    def bonus(self, q: PriorityInput) -> float:
        """MIX_POINTS per question the trait would still be behind its share after this pick."""
        picks = self.picks + 1
        return MIX_POINTS * sum(
            self.share[trait] * picks - self.count[trait]
            for trait in ("c:" + q.category, "b:" + band(q.difficulty))
        )

    def add(self, q: PriorityInput) -> None:
        self.picks += 1
        self.count["c:" + q.category] += 1
        self.count["b:" + band(q.difficulty)] += 1


class _Subtopic:
    def __init__(self, name: str, questions: list[PriorityInput]) -> None:
        self.name = name
        self.left = questions  # not ranked yet
        self.picked: list[PriorityInput] = []
        self.weight = math.sqrt(len(questions))

    def turn(self) -> tuple[bool, float]:
        """Sort key, smallest first: uncovered subtopics, then the Sainte-Laguë quotient."""
        return (bool(self.picked), -self.weight / (2 * len(self.picked) + 1))

    def repeats(self, q: PriorityInput) -> int:
        penalty = 0
        for p in self.picked:
            penalty += SAME_CATEGORY_PENALTY * (p.category == q.category)
            penalty += SAME_BAND_PENALTY * (band(p.difficulty) == band(q.difficulty))
            penalty += SAME_FORMAT_PENALTY * (p.format == q.format)
        return penalty


def clusters(questions: Sequence[PriorityInput]) -> dict[str, list[PriorityInput]]:
    """The topic's questions grouped by the idea they test: subtopic, or tag (see above)."""
    subtopics = {q.subtopic for q in questions if q.subtopic}
    by_tag = len(subtopics) > GRANULAR_SUBTOPICS * len(questions)
    buckets: dict[str, list[PriorityInput]] = defaultdict(list)
    for q in sorted(questions, key=lambda q: q.key):
        key = q.subtopic or _NO_SUBTOPIC
        if by_tag:
            key = next((tag for tag in q.tags if tag not in GENERIC_TAGS), key)
        buckets[key].append(q)
    return buckets


def plan_topic(questions: Sequence[PriorityInput]) -> dict[str, Priority]:
    """Importance, tier and rank for the questions of one topic."""
    buckets = clusters(questions)
    largest = max((len(bucket) for bucket in buckets.values()), default=0)
    scores = {
        q.key: importance(q, len(bucket), largest) for bucket in buckets.values() for q in bucket
    }
    subtopics = [_Subtopic(name, bucket) for name, bucket in sorted(buckets.items())]
    mix = _Mix(questions)
    size = tier_size(len(scores))
    plan: dict[str, Priority] = {}
    while open_ := [s for s in subtopics if s.left]:
        # Whose turn (ties: the subtopic named first).
        subtopic = min(open_, key=lambda s: (s.turn(), s.name))
        q = min(
            subtopic.left,
            key=lambda q: (-(scores[q.key] - subtopic.repeats(q) + mix.bonus(q)), q.key),
        )
        subtopic.left.remove(q)
        subtopic.picked.append(q)
        mix.add(q)
        rank = len(plan) + 1
        tier = CORE if rank <= size else STANDARD if rank <= 2 * size else EXTRA
        plan[q.key] = Priority(
            importance=scores[q.key], tier=tier, rank=rank, cluster=subtopic.name
        )
    return plan


def plan_priorities(questions: Iterable[PriorityInput]) -> dict[str, Priority]:
    """Importance, tier and rank for every question, ranked within its group (topic)."""
    groups: dict[str, list[PriorityInput]] = defaultdict(list)
    for q in questions:
        groups[q.group].append(q)
    plan: dict[str, Priority] = {}
    for group in groups.values():
        plan.update(plan_topic(group))
    return plan
