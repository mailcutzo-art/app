"""Ranking a topic's questions: importance, coverage-first order and tiers."""

import random
from collections import Counter

from app.modules.content.priority import (
    CORE,
    EXTRA,
    STANDARD,
    PriorityInput,
    band,
    clusters,
    importance,
    plan_priorities,
    plan_topic,
    tier_size,
)


def question(
    key: str,
    subtopic: str | None = "a",
    *,
    group: str = "physics/kinematics",
    difficulty: int = 3,
    category: str = "concept",
    format: str | None = "direct",
    ncert: bool | None = True,
    has_diagram: bool = False,
) -> PriorityInput:
    return PriorityInput(
        key=key,
        group=group,
        subtopic=subtopic,
        difficulty=difficulty,
        category=category,
        format=format,
        ncert=ncert,
        has_diagram=has_diagram,
    )


def topic(sizes: dict[str, int]) -> list[PriorityInput]:
    """Questions spread over subtopics, with varied traits."""
    categories = ["concept", "numerical", "factual", "application"]
    out = []
    for name, size in sizes.items():
        for i in range(size):
            out.append(
                question(
                    f"{name}-{i:03d}",
                    name,
                    difficulty=1 + i % 5,
                    category=categories[i % 4],
                    ncert=i % 3 != 0,
                )
            )
    return out


def test_tier_sizes_are_a_fifth_of_the_topic_and_at_least_three() -> None:
    assert tier_size(500) == 100
    assert tier_size(60) == 12
    assert tier_size(8) == 3
    assert tier_size(2) == 2


def test_a_500_question_topic_has_100_core_and_100_standard_questions() -> None:
    plan = plan_topic(topic({f"s{i}": 50 for i in range(10)}))

    tiers = Counter(p.tier for p in plan.values())
    assert tiers == {CORE: 100, STANDARD: 100, EXTRA: 300}
    assert sorted(p.rank for p in plan.values()) == list(range(1, 501))
    # Ranks follow the tiers.
    assert all(p.rank <= 100 for p in plan.values() if p.tier == CORE)


def test_every_subtopic_is_covered_before_any_gets_a_second_question() -> None:
    questions = topic({"big": 40, "medium": 9, "small": 1, "tiny": 2})
    plan = plan_topic(questions)
    by_rank = sorted(questions, key=lambda q: plan[q.key].rank)

    assert {q.subtopic for q in by_rank[:4]} == {"big", "medium", "small", "tiny"}
    core = Counter(q.subtopic for q in questions if plan[q.key].tier == CORE)
    assert core["big"] > core["medium"] >= core["small"]  # more turns, not proportionally more
    assert core["big"] < 40 / 52 * sum(core.values())


def test_the_core_set_keeps_the_topics_mix() -> None:
    questions = topic({f"s{i}": 25 for i in range(8)})
    plan = plan_topic(questions)
    core = [q for q in questions if plan[q.key].tier == CORE]

    categories = Counter(q.category for q in core)
    assert set(categories) == {"concept", "numerical", "factual", "application"}
    assert max(categories.values()) - min(categories.values()) <= 3
    assert {band(q.difficulty) for q in core} == {"easy", "medium", "hard"}


def test_importance_prefers_ncert_medium_exam_pattern_questions_from_big_subtopics() -> None:
    best = question("a", difficulty=3, format="assertion-reason", ncert=True)
    plain = question("b", difficulty=5, format="direct", ncert=False)
    figure = question("c", difficulty=3, format="diagram", ncert=True, has_diagram=True)

    assert importance(best, 20, 20) > importance(plain, 20, 20)
    assert importance(best, 20, 20) > importance(figure, 20, 20)
    assert importance(best, 20, 20) > importance(best, 1, 20)  # yield
    assert 0 <= importance(plain, 1, 20) <= importance(best, 20, 20) <= 100


def test_the_ranking_is_deterministic_and_per_topic() -> None:
    questions = topic({"x": 12, "y": 7}) + [
        question(f"other-{i}", group="physics/vectors") for i in range(6)
    ]
    shuffled = list(questions)
    random.Random(4).shuffle(shuffled)  # noqa: S311

    plan = plan_priorities(questions)

    assert plan == plan_priorities(shuffled)
    assert sorted(plan[f"other-{i}"].rank for i in range(6)) == list(range(1, 7))


def test_questions_without_a_subtopic_share_one_bucket() -> None:
    plan = plan_topic([question(f"q{i}", None, difficulty=1 + i % 5) for i in range(8)])

    assert Counter(p.tier for p in plan.values()) == {CORE: 3, STANDARD: 3, EXTRA: 2}


def test_one_subtopic_per_question_falls_back_to_tags() -> None:
    questions = [
        PriorityInput(
            key=f"q{i:02d}",
            group="physics/kinematics",
            subtopic=f"A subtopic describing question {i}",
            difficulty=3,
            category="numerical",
            format="direct",
            ncert=None,
            has_diagram=False,
            tags=("trap", "average-speed" if i < 12 else "relative-velocity"),
        )
        for i in range(16)
    ]

    buckets = clusters(questions)
    plan = plan_topic(questions)

    assert {name: len(group) for name, group in buckets.items()} == {
        "average-speed": 12,
        "relative-velocity": 4,
    }  # "trap" labels a trick, not an idea
    first_two = sorted(questions, key=lambda q: plan[q.key].rank)[:2]
    assert {q.tags[1] for q in first_two} == {"average-speed", "relative-velocity"}


def test_ncert_only_counts_for_concepts_and_facts() -> None:
    def score(category: str, ncert: bool) -> int:
        return importance(question("q", category=category, ncert=ncert), 5, 5)

    assert score("factual", True) > score("factual", False)
    assert score("numerical", True) == score("numerical", False)
