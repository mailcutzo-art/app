"""Recommended practice: splitting a session across topics and picking within a topic."""

import random
import uuid
from collections import Counter
from datetime import UTC, datetime, timedelta

from app.modules.practice.recommend import (
    Candidate,
    Pick,
    TopicState,
    allocate,
    choose,
    order_session,
    pick_in_topic,
    review_slots,
    target_difficulty,
    topic_need,
)

NOW = datetime(2026, 11, 12, 12, tzinfo=UTC)


def rng(seed: int) -> random.Random:
    return random.Random(seed)  # noqa: S311


def state(topic_id: int, available: int = 60, **overrides: object) -> TopicState:
    values: dict[str, object] = {
        "topic_id": topic_id,
        "available": available,
        "unseen": available,
        "core_total": 12,
        "core_left": 12,
    }
    values.update(overrides)
    return TopicState(**values)  # type: ignore[arg-type]


def candidate(
    topic_id: int = 1,
    cluster: str | None = "a",
    *,
    difficulty: int = 3,
    tier: int = 1,
    rank: int = 1,
    importance: int = 70,
    attempts: int = 0,
    last_at: datetime | None = None,
    last_outcome: str | None = None,
) -> Candidate:
    return Candidate(
        id=uuid.uuid4(),
        topic_id=topic_id,
        cluster=cluster,
        difficulty=difficulty,
        category="concept",
        tier=tier,
        rank=rank,
        importance=importance,
        attempts=attempts,
        correct=attempts if last_outcome == "correct" else 0,
        last_at=last_at,
        last_outcome=last_outcome,
    )


def test_reviews_take_at_most_a_fifth_of_the_session() -> None:
    assert review_slots(10, 0) == 0
    assert review_slots(10, 1) == 1
    assert review_slots(10, 9) == 2
    assert review_slots(50, 30) == 10
    assert review_slots(5, 3) == 1


def test_the_target_difficulty_follows_the_students_accuracy() -> None:
    assert 2 < target_difficulty(0, 0) < 2.5  # a newcomer starts easy-to-medium
    assert target_difficulty(20, 19) > 4.5
    assert target_difficulty(20, 4) < 1.5


def test_topics_with_core_left_weak_or_stale_need_more() -> None:
    fresh = state(1)
    mastered = state(1, core_left=0, attempts=40, correct=38, last_at=NOW)
    weak = state(1, core_left=0, attempts=40, correct=10, last_at=NOW)
    stale = state(1, core_left=0, attempts=40, correct=38, last_at=NOW - timedelta(days=10))

    assert topic_need(fresh, NOW) > topic_need(weak, NOW) > topic_need(mastered, NOW)
    assert topic_need(stale, NOW) > topic_need(mastered, NOW)


def test_every_topic_gets_a_slot_and_needy_topics_get_more() -> None:
    topics = [
        state(1),
        state(2, core_left=0, attempts=50, correct=48, last_at=NOW),
        state(3, available=2, unseen=2),
    ]

    allocation = allocate(topics, 12, now=NOW, rng=rng(1))

    assert sum(allocation.values()) == 12
    assert set(allocation) == {1, 2, 3}
    assert allocation[1] > allocation[2]
    assert allocation[3] <= 2  # never more than the topic has


def test_a_short_session_draws_its_topics_by_need() -> None:
    topics = [
        state(1),
        *(state(i, core_left=0, attempts=50, correct=48, last_at=NOW) for i in (2, 3, 4, 5)),
    ]
    draws_rng = rng(7)

    draws = Counter(
        topic_id for _ in range(500) for topic_id in allocate(topics, 2, now=NOW, rng=draws_rng)
    )

    assert all(len(allocate(topics, 2, now=NOW, rng=draws_rng)) == 2 for _ in range(20))
    assert draws[1] > max(draws[i] for i in (2, 3, 4, 5))
    assert min(draws[i] for i in (2, 3, 4, 5)) > 0  # every topic still comes round


def test_allocation_stops_when_the_topics_run_out() -> None:
    assert allocate([state(1, available=3)], 10, now=NOW, rng=rng(1)) == {1: 3}
    assert allocate([], 10, now=NOW, rng=rng(1)) == {}


def test_core_questions_come_before_others_and_ideas_vary() -> None:
    core = [candidate(cluster=s, tier=1, rank=i) for i, s in enumerate("aabbc")]
    extra = [candidate(cluster="d", tier=3, rank=10 + i, importance=90) for i in range(5)]

    chosen = pick_in_topic(core + extra, 3, target=3, rng=rng(2))

    assert all(c.tier == 1 for c in chosen)
    assert sorted(c.cluster or "" for c in chosen) == ["a", "b", "c"]


def test_a_strong_student_gets_harder_questions() -> None:
    pool = [candidate(cluster=f"s{d}", difficulty=d, rank=d) for d in range(1, 6)]

    strong = pick_in_topic(pool, 2, target=target_difficulty(30, 29), rng=rng(3))
    newcomer = pick_in_topic(pool, 2, target=target_difficulty(0, 0), rng=rng(3))

    assert {c.difficulty for c in strong} == {4, 5}
    assert {c.difficulty for c in newcomer} <= {1, 2, 3}


def test_ideas_the_student_has_not_met_come_first() -> None:
    met = candidate(cluster="a", attempts=1, last_at=NOW, last_outcome="correct")
    same = candidate(cluster="a", rank=1)
    new = candidate(cluster="b", rank=2)

    chosen = pick_in_topic([met, same, new], 1, target=3, rng=rng(4))

    assert chosen == [new]


def test_refreshers_serve_mistakes_then_the_longest_ago() -> None:
    old_right = candidate(attempts=1, last_at=NOW - timedelta(days=9), last_outcome="correct")
    new_right = candidate(attempts=1, last_at=NOW - timedelta(days=1), last_outcome="correct")
    wrong = candidate(attempts=1, last_at=NOW, last_outcome="wrong")

    chosen = pick_in_topic([new_right, old_right, wrong], 3, target=3, rng=rng(5))

    assert chosen == [wrong, old_right, new_right]


def test_the_session_ramps_up_and_ends_with_reviews_and_refreshers() -> None:
    hard = candidate(1, difficulty=4)
    easy = candidate(2, difficulty=1)
    medium = candidate(1, difficulty=3)
    refresher = candidate(2, attempts=1, last_at=NOW, last_outcome="correct")
    review = uuid.uuid4()

    order = order_session(
        [Pick(hard, 1), Pick(easy, 0), Pick(medium, 0), Pick(refresher, 1)], [review]
    )

    assert order == [easy.id, medium.id, hard.id, review, refresher.id]


def test_choose_fills_each_topics_slots() -> None:
    pool = [candidate(1, f"s{i}", rank=i) for i in range(6)] + [
        candidate(2, f"t{i}", rank=i) for i in range(6)
    ]
    states = {1: state(1), 2: state(2)}

    picks = choose({1: 4, 2: 2}, pool, states, rng=rng(6))

    assert Counter(p.question.topic_id for p in picks) == {1: 4, 2: 2}
    assert len({p.question.id for p in picks}) == 6
