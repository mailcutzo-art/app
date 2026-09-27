"""Coach tips: every rule at its threshold and just below, then ordering, limits and unlock."""

from typing import Any

import pytest

from app.modules.coach.tips import (
    AreaKind,
    AreaStats,
    Tip,
    TipAction,
    TipInputs,
    TipRule,
    answers_until_unlock,
    build_tips,
)


def topic(key: str, chapter: str = "kinematics", **stats: Any) -> AreaStats:
    name = key.replace("-", " ").capitalize()
    return AreaStats(AreaKind.TOPIC, key, name, "physics", chapter_key=chapter, **stats)


def chapter(key: str, **stats: Any) -> AreaStats:
    return AreaStats(AreaKind.CHAPTER, key, key.capitalize(), "physics", **stats)


def category(key: str, **stats: Any) -> AreaStats:
    return AreaStats(AreaKind.CATEGORY, key, f"Physics {key}s", "physics", **stats)


def tips_for(
    *areas: AreaStats,
    overall: tuple[int, int] = (100, 58),  # smoothed overall accuracy 0.577
    total: int = 100,
    reviews: int = 0,
    untried: tuple[tuple[str, str, str], ...] = (),
    dismissed: frozenset[str] = frozenset(),
) -> list[Tip]:
    return build_tips(
        TipInputs(
            total_answers=total,
            overall_attempts=overall[0],
            overall_correct=overall[1],
            areas=areas,
            reviews_due=reviews,
            untried_chapters=untried,
            dismissed=dismissed,
        )
    )


def keys(tips: list[Tip]) -> list[str]:
    return [tip.key for tip in tips]


# 1. WEAK_TOPIC


def test_weak_topic_at_half_accuracy() -> None:
    # Smoothed (3 + 2) / (6 + 4) = 0.5.
    [tip] = tips_for(topic("projectile-motion", attempts=6, correct=3))

    assert tip == Tip(
        key="weak_topic:physics:projectile-motion",
        rule=TipRule.WEAK_TOPIC,
        target="physics:projectile-motion",
        message="Focus on Projectile motion. You got 3 of 6 right.",
        action=TipAction.PRACTICE,
        params={"subject": "physics", "topic": "projectile-motion", "count": "10"},
        priority=1,
    )


@pytest.mark.parametrize(
    "area",
    [
        topic("projectile-motion", attempts=6, correct=4),  # 0.6: above half, near average
        topic("projectile-motion", attempts=4, correct=0),  # too few answers
    ],
)
def test_no_weak_topic_just_below_the_thresholds(area: AreaStats) -> None:
    assert tips_for(area) == []


def test_weak_topic_fifteen_points_below_the_users_average() -> None:
    # Overall (83 + 2) / (96 + 4) = 0.85; topic (12 + 2) / (16 + 4) = 0.70.
    [tip] = tips_for(topic("vectors", attempts=16, correct=12), overall=(96, 83))
    assert tip.rule is TipRule.WEAK_TOPIC
    assert tip.message == "Focus on Vectors. You got 12 of 16 right."

    # Overall 0.84: only 14 points below.
    assert tips_for(topic("vectors", attempts=16, correct=12), overall=(96, 82)) == []


# 2. FAST_BUT_WRONG


def test_fast_but_wrong_at_forty_percent() -> None:
    [tip] = tips_for(topic("chemical-bonding", attempts=10, correct=6, fast_wrong=4))

    assert tip.rule is TipRule.FAST_BUT_WRONG
    assert tip.message == (
        "You answer Chemical bonding questions quickly but often miss. Read all four options first."
    )
    assert tip.action is TipAction.PRACTICE
    assert tip.params == {"subject": "physics", "topic": "chemical-bonding", "count": "10"}


@pytest.mark.parametrize(
    "area",
    [
        topic("chemical-bonding", attempts=10, correct=6, fast_wrong=3),  # 30%
        topic("chemical-bonding", attempts=5, correct=3, fast_wrong=2),  # too few answers
    ],
)
def test_no_fast_but_wrong_just_below_the_thresholds(area: AreaStats) -> None:
    assert tips_for(area) == []


# 3. SLOW_VS_OPPONENTS


@pytest.mark.parametrize("area", [topic("kinematics-graphs"), chapter("kinematics")])
def test_slow_against_opponents_at_sixty_percent(area: AreaStats) -> None:
    slow = AreaStats(
        area.kind, area.key, area.name, area.subject, area.chapter_key, fast=1, slow=3, even=1
    )

    [tip] = tips_for(slow)

    assert tip.rule is TipRule.SLOW_VS_OPPONENTS
    assert tip.message == (
        f"You're often slower than your opponents in {area.name}. Try a timed practice set."
    )
    assert tip.action is TipAction.TIMED_PRACTICE
    assert tip.params == {"subject": "physics", area.kind.value: area.key, "count": "10"}


@pytest.mark.parametrize(
    "counts",
    [
        {"fast": 2, "slow": 3, "even": 1},  # 50% slow
        {"fast": 2, "slow": 2, "even": 0},  # too few compared
        {"fast": 0, "slow": 2, "even": 1},  # not enough slow answers
    ],
)
def test_no_slow_tip_just_below_the_thresholds(counts: dict[str, int]) -> None:
    assert tips_for(topic("kinematics-graphs", **counts), chapter("kinematics", **counts)) == []


def test_a_chapter_speed_tip_gives_way_to_tips_on_its_topics() -> None:
    tips = tips_for(
        topic("vectors", chapter="kinematics", attempts=6, correct=1),  # weak
        chapter("kinematics", slow=5),
        chapter("optics", slow=5),
        topic("lenses", chapter="optics", attempts=12, correct=12),  # strong, doesn't count
    )

    assert keys(tips) == [
        "weak_topic:physics:vectors",
        "slow_vs_opponents:physics:optics",
        "strength:physics:lenses",
    ]


def test_categories_are_not_judged_against_opponents() -> None:
    assert tips_for(category("numerical", slow=5)) == []


# 4. SLOW_CATEGORY


def test_slow_category_at_thirty_percent_longer() -> None:
    [tip] = tips_for(category("numerical", typical_compared=8, typical_ratio=1.3))

    assert tip == Tip(
        key="slow_category:physics:numerical",
        rule=TipRule.SLOW_CATEGORY,
        target="physics:numerical",
        message="Practise more Physics numericals. You take about 30% longer than other students.",
        action=TipAction.PRACTICE_CATEGORY,
        params={"subject": "physics", "category": "numerical", "count": "10"},
        priority=4,
    )


@pytest.mark.parametrize(
    "area",
    [
        category("numerical", typical_compared=8, typical_ratio=1.29),
        category("numerical", typical_compared=7, typical_ratio=2.0),
        category("numerical", typical_compared=50, typical_ratio=None),
        category("numerical", typical_compared=50, typical_ratio=float("inf")),
    ],
)
def test_no_slow_category_just_below_the_thresholds(area: AreaStats) -> None:
    assert tips_for(area) == []


@pytest.mark.parametrize(
    ("ratio", "percent"), [(1.34, 30), (1.35, 40), (1.44, 40), (1.45, 50), (2.0, 100)]
)
def test_slow_category_percent_is_rounded_to_the_nearest_ten(ratio: float, percent: int) -> None:
    [tip] = tips_for(category("numerical", typical_compared=8, typical_ratio=ratio))

    assert f"about {percent}% longer" in tip.message


def test_slow_categories_of_different_subjects_are_different_areas() -> None:
    chemistry = AreaStats(
        AreaKind.CATEGORY,
        "numerical",
        "Chemistry numericals",
        "chemistry",
        typical_compared=9,
        typical_ratio=1.8,
    )

    tips = tips_for(category("numerical", typical_compared=8, typical_ratio=1.4), chemistry)

    assert keys(tips) == ["slow_category:chemistry:numerical", "slow_category:physics:numerical"]


# 5. REVIEW_DUE


@pytest.mark.parametrize(
    ("due", "message"),
    [(1, "1 question is waiting for review."), (5, "5 questions are waiting for review.")],
)
def test_review_due(due: int, message: str) -> None:
    [tip] = tips_for(reviews=due)

    assert (tip.key, tip.message, tip.action, tip.params) == (
        "review_due:all",
        message,
        TipAction.REVIEW,
        {},
    )


def test_no_review_tip_without_due_reviews() -> None:
    assert tips_for(reviews=0) == []


# 6. UNTRIED_CHAPTER


def test_only_the_first_untried_chapter_is_suggested() -> None:
    untried = (("physics", "gravitation", "Gravitation"), ("physics", "optics", "Optics"))

    [tip] = tips_for(untried=untried)

    assert tip == Tip(
        key="untried_chapter:physics:gravitation",
        rule=TipRule.UNTRIED_CHAPTER,
        target="physics:gravitation",
        message="You haven't tried Gravitation yet. Start with 10 easy questions.",
        action=TipAction.START_CHAPTER,
        params={
            "subject": "physics",
            "chapter": "gravitation",
            "difficulty": "easy",
            "count": "10",
        },
        priority=6,
    )


def test_a_dismissed_untried_chapter_makes_way_for_the_next() -> None:
    untried = (("physics", "gravitation", "Gravitation"), ("physics", "optics", "Optics"))

    tips = tips_for(untried=untried, dismissed=frozenset({"untried_chapter:physics:gravitation"}))

    assert keys(tips) == ["untried_chapter:physics:optics"]


# 7. LEVEL_UP


def test_level_up_at_85_percent_of_easy_questions() -> None:
    [tip] = tips_for(chapter("genetics", easy_attempts=20, easy_correct=17))

    assert (tip.rule, tip.message, tip.action, tip.params) == (
        TipRule.LEVEL_UP,
        "You've got the basics of Genetics. Try medium questions.",
        TipAction.PRACTICE_MEDIUM,
        {"subject": "physics", "chapter": "genetics", "difficulty": "medium", "count": "10"},
    )


@pytest.mark.parametrize(
    "area",
    [
        chapter("genetics", easy_attempts=20, easy_correct=16),  # 80%
        chapter("genetics", easy_attempts=9, easy_correct=9),  # too few easy answers
        topic("genetics", easy_attempts=20, easy_correct=20),  # topics don't level up
    ],
)
def test_no_level_up_just_below_the_thresholds(area: AreaStats) -> None:
    assert tips_for(area) == []


# 8. STRENGTH


def test_strength_at_eighty_percent() -> None:
    # Smoothed (14 + 2) / (16 + 4) = 0.8.
    [tip] = tips_for(topic("laws-of-motion", attempts=16, correct=14))

    assert (tip.rule, tip.message, tip.action, tip.params, tip.priority) == (
        TipRule.STRENGTH,
        "You're strong in Laws of motion. Test it in a rated battle.",
        TipAction.BATTLE,
        {"subject": "physics", "chapter": "kinematics"},
        8,
    )


@pytest.mark.parametrize(
    "area",
    [
        topic("laws-of-motion", attempts=16, correct=13),  # 0.75
        topic("laws-of-motion", attempts=9, correct=9),  # too few answers
        chapter("laws-of-motion", attempts=30, correct=30),  # chapters aren't praised
    ],
)
def test_no_strength_just_below_the_thresholds(area: AreaStats) -> None:
    assert tips_for(area) == []


# Ordering, limits and unlock


EVERY_RULE = (
    topic("weak", attempts=10, correct=2),
    topic("rushed", attempts=10, correct=6, fast_wrong=5),
    chapter("slowpoke", slow=4, even=1),
    category("numerical", typical_compared=10, typical_ratio=1.6),
    chapter("basics", easy_attempts=10, easy_correct=10),
    topic("strong", chapter="basics", attempts=10, correct=10),
)


def test_rules_come_in_priority_order_and_at_most_five() -> None:
    tips = tips_for(*EVERY_RULE, reviews=2, untried=(("physics", "optics", "Optics"),))

    assert [tip.rule for tip in tips] == list(TipRule)[:5]
    assert [tip.priority for tip in tips] == [1, 2, 3, 4, 5]


def test_later_rules_follow_when_earlier_ones_are_dismissed() -> None:
    dismissed = frozenset(
        {
            "weak_topic:physics:weak",
            "fast_but_wrong:physics:rushed",
            "slow_vs_opponents:physics:slowpoke",
        }
    )

    tips = tips_for(
        *EVERY_RULE, reviews=2, untried=(("physics", "optics", "Optics"),), dismissed=dismissed
    )

    assert [tip.rule for tip in tips] == list(TipRule)[3:]


def test_within_a_rule_the_worse_case_comes_first_then_key_order() -> None:
    tips = tips_for(
        topic("b-weak", attempts=10, correct=2),
        topic("a-weak", attempts=10, correct=2),
        topic("weakest", attempts=10, correct=0),
        chapter("slower", slow=5),
        topic("slow", fast=2, slow=3),
    )

    assert keys(tips) == [
        "weak_topic:physics:weakest",
        "weak_topic:physics:a-weak",
        "weak_topic:physics:b-weak",
        "slow_vs_opponents:physics:slower",
        "slow_vs_opponents:physics:slow",
    ]


def test_the_strongest_areas_come_first_among_strengths_and_level_ups() -> None:
    tips = tips_for(
        topic("good", attempts=20, correct=18),
        topic("best", attempts=20, correct=20),
        chapter("basics", easy_attempts=20, easy_correct=18),
        chapter("easy", easy_attempts=10, easy_correct=10),
    )

    assert keys(tips) == [
        "level_up:physics:easy",
        "level_up:physics:basics",
        "strength:physics:best",
        "strength:physics:good",
    ]


def test_one_tip_per_area_keeps_the_most_important() -> None:
    weak_and_rushed = topic("vectors", attempts=10, correct=2, fast_wrong=6, slow=5)

    assert keys(tips_for(weak_and_rushed)) == ["weak_topic:physics:vectors"]


def test_a_dismissed_tip_lets_the_next_one_for_that_area_through() -> None:
    weak_and_rushed = topic("vectors", attempts=10, correct=2, fast_wrong=6)

    tips = tips_for(weak_and_rushed, dismissed=frozenset({"weak_topic:physics:vectors"}))

    assert keys(tips) == ["fast_but_wrong:physics:vectors"]


def test_tips_unlock_after_twenty_answers() -> None:
    assert tips_for(reviews=3, total=19) == []
    assert keys(tips_for(reviews=3, total=20)) == ["review_due:all"]
    assert [answers_until_unlock(n) for n in (0, 19, 20, 500)] == [20, 1, 0, 0]


def test_duplicate_areas_are_rejected() -> None:
    with pytest.raises(ValueError, match="unique"):
        tips_for(topic("vectors"), topic("vectors", attempts=3))


def test_the_same_slug_in_two_subjects_gives_two_tips() -> None:
    physics = topic("vectors", attempts=6, correct=1)
    maths = AreaStats(
        AreaKind.TOPIC, "vectors", "Vectors", "maths", chapter_key="vector-algebra", attempts=6
    )

    tips = tips_for(physics, maths)

    assert keys(tips) == ["weak_topic:maths:vectors", "weak_topic:physics:vectors"]
    assert [tip.params["subject"] for tip in tips] == ["maths", "physics"]


def test_every_practice_action_names_its_subject() -> None:
    tips = tips_for(*EVERY_RULE, untried=(("physics", "optics", "Optics"),))
    dismissed = frozenset(tip.key for tip in tips)
    rest = tips_for(*EVERY_RULE, untried=(("physics", "optics", "Optics"),), dismissed=dismissed)

    for tip in [*tips, *rest]:
        assert tip.params.get("subject") == "physics", tip.key
